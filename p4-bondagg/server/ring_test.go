package main

import (
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// ---- U131: fixed slab, zero allocation on the store path ---------------------

// TestRingStoreAllocsZero pins the point of U131: Ring.store must not allocate
// per stored frame. Before the fix, `cp := make([]byte, len(data))` at
// ring.go:137 allocated on every unique seq; this measures the steady-state
// in-order Push path (store + immediate drain), which is the common case on
// the box. The Out callback is a no-op so the measurement isolates the ring's
// own allocations from the caller's.
func TestRingStoreAllocsZero(t *testing.T) {
	r := NewRing(4, 20*time.Millisecond, func(b []byte) {})
	t0 := time.Now()
	data := make([]byte, 4)

	// Arm the ring so subsequent pushes take the in-order armed path
	// (store then immediate drain), not the warm-up branch.
	r.Push(0, data, t0)
	r.Tick(t0.Add(30 * time.Millisecond))

	at := t0.Add(40 * time.Millisecond)
	seq := uint32(1)
	avg := testing.AllocsPerRun(200, func() {
		seq++
		r.Push(seq, data, at)
	})
	if avg != 0 {
		t.Fatalf("Ring.store allocates %v times/op on the steady-state store path, want 0", avg)
	}
}

// BenchmarkRingStore measures the cost of the store path directly (same
// steady-state in-order shape as TestRingStoreAllocsZero) so a future
// regression shows up as a latency change even if it stays zero-alloc.
func BenchmarkRingStore(b *testing.B) {
	r := NewRing(RingPow2, 20*time.Millisecond, func([]byte) {})
	t0 := time.Now()
	data := make([]byte, 4)
	r.Push(0, data, t0)
	r.Tick(t0.Add(30 * time.Millisecond))

	at := t0.Add(40 * time.Millisecond)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r.Push(uint32(i)+1, data, at)
	}
}

// ---- U131: the fixed arrival ring behaves like the old grow-then-truncate
// slice it replaced -----------------------------------------------------------

// TestRingOverdueEpochReleasesWholeBatch exercises the ONE code path the
// arrival-ring conversion touches that no other ring test reaches: the
// overdue-epoch branch in drain() that walks the arrival FIFO to find how far
// to release in one batch (arrFront/arrPopFront), rather than the run-skip
// fallback that TestRingSkipsAGapAfterHold covers. Interleaved loss: evens
// present, odds missing -- one hold epoch must release the whole batch, not
// hold-per-gap.
func TestRingOverdueEpochReleasesWholeBatch(t *testing.T) {
	r, got := newTestRing(40 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(50 * time.Millisecond)) // arm; delivers 0
	for s := uint32(2); s <= 10; s += 2 {
		push(r, s, t0.Add(50*time.Millisecond))
	}
	r.Tick(t0.Add(110 * time.Millisecond))
	eq(t, *got, 0, 2, 4, 6, 8, 10)
	_, skips, _, _ := r.Counts()
	if skips != 5 {
		t.Fatalf("skips = %d, want 5", skips)
	}
}

// ---- U139: one live path delivers on arrival ---------------------------------

// newSingleRing is newTestRing plus a settable live-path count, standing in for
// the peers table main() wires in (ring.SingleLive = pr.singleLiveAt). Writing
// *live is how a test makes a second path appear or die; the ring re-reads the
// predicate on every Push and Tick, so the transition needs no other event.
func newSingleRing(hold time.Duration) (*Ring, *[]uint32, *int) {
	r, got := newTestRing(hold)
	live := new(int)
	*live = 1
	r.SingleLive = func(time.Time) bool { return *live == 1 }
	return r, got, live
}

// TestRingSingleLivePathDeliversOnArrival is U139's bar. With ONE live pathID a
// seq gap is a LOSS -- there is no second link it could still arrive on -- so
// holding for it can only ever expire. The hold here is 200 ms and the gap
// assertions are made 1-2 ms after the push: under the pre-U139 rule the ring
// would be blocked on the gap for a further 200 ms, so `eco` (N=1) would pay a
// stall per uplink loss that `direct` never pays.
//
// The opening Tick is the ONE-HOLD GRACE (fix round), not a hold on the gap:
// arrival mode may not start until the wire has read as one live path for a
// whole hold, because before that "one path" also means "the second path has
// not spoken yet" (TestRingColdStartTwoPathsKeepsSlowerOpeningFrame). That
// costs one warm-up at ring start; it costs nothing per loss, which is the
// stall this unit exists to remove.
func TestRingSingleLivePathDeliversOnArrival(t *testing.T) {
	r, got, _ := newSingleRing(200 * time.Millisecond)
	t0 := time.Now()

	push(r, 0, t0)
	eq(t, *got) // still in warm-up: the live count is not yet trustworthy
	r.Tick(t0.Add(201 * time.Millisecond))
	eq(t, *got, 0)

	// seq 1 is lost. seq 2 must go out AT ONCE, not one hold later.
	push(r, 2, t0.Add(202*time.Millisecond))
	eq(t, *got, 0, 2)
	if _, skips, _, _ := r.Counts(); skips != 1 {
		t.Fatalf("skips = %d, want 1: the lost seq must be skipped at arrival", skips)
	}

	// And the stream keeps flowing in order behind it.
	push(r, 3, t0.Add(203*time.Millisecond))
	eq(t, *got, 0, 2, 3)
}

// TestRingSecondPathRestoresHold is the other half of the mode-blind rule: the
// arrival mode is not a latch. The moment a SECOND pathID is live the ring goes
// back to holding a gap, because now the gap really can be cross-path reorder.
func TestRingSecondPathRestoresHold(t *testing.T) {
	r, got, live := newSingleRing(50 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(60 * time.Millisecond)) // warm-up + grace elapse; arrival mode
	eq(t, *got, 0)

	*live = 2 // a second pathID becomes live
	push(r, 2, t0.Add(70*time.Millisecond))
	eq(t, *got, 0) // held: seq 1 may still be in flight on the other path
	if _, skips, _, _ := r.Counts(); skips != 0 {
		t.Fatalf("skips = %d, want 0: the hold must resume with two live paths", skips)
	}

	push(r, 1, t0.Add(80*time.Millisecond)) // and it was
	eq(t, *got, 0, 1, 2)
	if _, skips, _, _ := r.Counts(); skips != 0 {
		t.Fatalf("skips = %d, want 0: the reorder was healed, nothing was lost", skips)
	}
}

// TestRingSecondPathRestoresHoldHigherSeqFirst is the variant the test above
// could not catch: it pushes seq 0 FIRST, so the warm-up anchor lands on the
// right seq whether or not the ring anchors on the minimum. Here the FASTER
// path's seq 1 arrives first and the slower path's seq 0 follows 10 ms later,
// which is the shape that actually exercises divergence 1's anchor-on-MINIMUM.
// Two live paths throughout, so this is the hold path, not arrival mode.
func TestRingSecondPathRestoresHoldHigherSeqFirst(t *testing.T) {
	r, got, live := newSingleRing(50 * time.Millisecond)
	*live = 2
	t0 := time.Now()
	push(r, 1, t0)
	push(r, 0, t0.Add(10*time.Millisecond))
	r.Tick(t0.Add(60 * time.Millisecond))
	eq(t, *got, 0, 1)
	if _, skips, olds, _ := r.Counts(); skips != 0 || olds != 0 {
		t.Fatalf("skips = %d olds = %d, want 0/0: the warm-up must anchor on the MINIMUM seq", skips, olds)
	}
}

// TestRingColdStartTwoPathsKeepsSlowerOpeningFrame is fix-round blocker B1. On a
// 2-path bond the FIRST frame is heard from one path only, because the second
// has not spoken yet -- so the wire predicate reads single-live even though N=2.
// Arming arrival mode on it anchors next at that seq and the slower path's
// opening frame (LOWER seq, ~30 ms behind, inside the hold) is dropped as old.
// Measured on the pre-fix build with exactly these pushes: delivered=[1],
// olds=1. Both frames must be delivered, in order, and nothing counted old.
func TestRingColdStartTwoPathsKeepsSlowerOpeningFrame(t *testing.T) {
	r, got, live := newSingleRing(50 * time.Millisecond)
	t0 := time.Now()
	push(r, 1, t0) // the faster path opens; it is the only path SEEN so far
	*live = 2      // the slower path is heard from ~30 ms later
	push(r, 0, t0.Add(30*time.Millisecond))
	r.Tick(t0.Add(60 * time.Millisecond))
	eq(t, *got, 0, 1)
	if _, _, olds, _ := r.Counts(); olds != 0 {
		t.Fatalf("olds = %d, want 0: the slower path's opening frame was dropped", olds)
	}
}

// TestRingDataQuietPathDoesNotLoseInflightFrame is fix-round blocker B2. With
// the auth gate OPEN only DATA refreshes seen[] (main.go, EpMaxAge), so a path
// that is still up but carries no DATA for 600 ms reads as gone. Entering
// arrival mode on that reading advances next past a seq still IN FLIGHT on it:
// measured on the pre-fix build with exactly these pushes, delivered=[0 1 3],
// skips=1, olds=1 -- the frame is LOST, not merely skipped. The one-hold grace
// (arrivalOK) keeps the ring on the hold path long enough to take it.
func TestRingDataQuietPathDoesNotLoseInflightFrame(t *testing.T) {
	r, got, live := newSingleRing(50 * time.Millisecond)
	*live = 2
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(60 * time.Millisecond)) // warm-up elapses with two live paths
	push(r, 1, t0.Add(70*time.Millisecond))
	eq(t, *got, 0, 1)

	*live = 1                             // the second path goes DATA-quiet past EpMaxAge
	r.Tick(t0.Add(80 * time.Millisecond)) // seq 2 is still in flight on it
	push(r, 3, t0.Add(85*time.Millisecond))
	push(r, 2, t0.Add(90*time.Millisecond)) // and it lands
	eq(t, *got, 0, 1, 2, 3)
	if _, skips, olds, _ := r.Counts(); skips != 0 || olds != 0 {
		t.Fatalf("skips = %d olds = %d, want 0/0: an in-flight frame was lost when the path went quiet", skips, olds)
	}
}

// TestRingSingleLiveDedupsDuplicates pins the "with dedup only" half of the
// rule. Arrival mode advances next past every seq it delivers, so a duplicate
// copy is classified old and dropped by the same test the hold path uses -- it
// must never reach WireGuard twice, and it must not re-anchor the ring.
func TestRingSingleLiveDedupsDuplicates(t *testing.T) {
	r, got, _ := newSingleRing(50 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(60 * time.Millisecond)) // warm-up + grace: arrival mode is live
	eq(t, *got, 0)
	push(r, 1, t0.Add(61*time.Millisecond))
	push(r, 1, t0.Add(62*time.Millisecond)) // duplicate copy
	push(r, 2, t0.Add(63*time.Millisecond))
	eq(t, *got, 0, 1, 2)
	_, _, olds, resyncs := r.Counts()
	if olds != 1 {
		t.Fatalf("olds = %d, want 1: the duplicate must be counted and dropped", olds)
	}
	if resyncs != 0 {
		t.Fatalf("resyncs = %d, want 0: a duplicate re-anchored the ring", resyncs)
	}
}

// TestRingSingleLiveStillResyncsOnPeerRestart guards the arrival path against
// re-opening divergence 2. Arrival mode drops everything behind next, so a
// client whose seq counter restarts near 0 would be dropped forever -- a bricked
// tunnel on the box with no console -- if the resync limb did not still fire.
// The trailing Tick pins the WARM-UP RESTART only: resync sets armed=false and
// firstAt=now, so the release comes one hold after the resync and not at the
// next tick. It does NOT pin arrivalOK's grace -- measured: with the grace's
// multiAt untouched by resync this test is green either way, because the
// warm-up alone holds the release. Claiming more than that here was wrong.
func TestRingSingleLiveStillResyncsOnPeerRestart(t *testing.T) {
	r, got, _ := newSingleRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 100, t0)
	r.Tick(t0.Add(25 * time.Millisecond))
	eq(t, *got, 100)

	push(r, 0, t0.Add(100*time.Millisecond)) // restarted sequence space
	push(r, 1, t0.Add(130*time.Millisecond)) // a whole hold of nothing but old
	r.Tick(t0.Add(135 * time.Millisecond))
	eq(t, *got, 100) // the resync re-armed the warm-up; 5 ms is inside it
	r.Tick(t0.Add(155 * time.Millisecond))
	eq(t, *got, 100, 1)
	_, _, olds, resyncs := r.Counts()
	if resyncs != 1 {
		t.Fatalf("resyncs = %d, want 1: a peer restart at N=1 bricks the tunnel", resyncs)
	}
	if olds != 2 {
		t.Fatalf("olds = %d, want 2", olds)
	}
}

// TestPeersSingleLiveComesFromTheSeenTable pins the wiring, not the ring: the
// live count is read off the peers table main.go already keeps (learn/seen) and
// aged by the EpMaxAge horizon that already exists, so no constant and no state
// was added for U139. Zero live paths must NOT read as single.
func TestPeersSingleLiveComesFromTheSeenTable(t *testing.T) {
	p := &peers{}
	t0 := time.Now()
	a := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}

	if p.singleLiveAt(t0) {
		t.Fatal("a server that has heard nothing must not read as single-live")
	}
	p.learn(0, 0, a, t0)
	if !p.singleLiveAt(t0) {
		t.Fatal("one learned path must read as single-live")
	}
	at := t0.Add(10 * time.Millisecond)
	p.learn(1, 0, a, at)
	if p.singleLiveAt(at) {
		t.Fatalf("two live paths must restore the hold, live = %d", p.liveLinks(at))
	}
	// Path 0 falls out of EpMaxAge: the client would already call it dead.
	old := t0.Add(EpMaxAge + time.Millisecond)
	if !p.singleLiveAt(old) {
		t.Fatalf("one path aged past EpMaxAge leaves one live, live = %d", p.liveLinks(old))
	}
}

// ---- U139 fix round 4: the three arrival call sites the earlier bars left
// unpinned ---------------------------------------------------------------------

// TestRingTickAloneDeliversOnArrivalWithOneLivePath pins Tick's OWN arrival
// branch (ring.go, `single := r.arrivalOK(now)` in Tick). Tick is the only way
// the ring can enter arrival mode with no further Push: a client that opens
// with a gap and then goes quiet is armed and released here. Seeding that call
// site to `single := false` was green against every earlier bar, because the
// existing tests arm from a Tick with NO gap outstanding, where drain and
// deliverArrival agree. Here seq 1 is missing when the warm-up expires, and
// nothing is pushed afterwards: arrival mode must skip it and release seq 2 on
// the tick, while drain would arm the gap timer and hold seq 2 for a further
// hold that can never be redeemed at one live path.
func TestRingTickAloneDeliversOnArrivalWithOneLivePath(t *testing.T) {
	r, got, _ := newSingleRing(50 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	push(r, 2, t0.Add(5*time.Millisecond)) // seq 1 is lost; both inside the warm-up
	eq(t, *got)                            // warm-up: nothing out yet

	r.Tick(t0.Add(60 * time.Millisecond)) // the ONLY event after the hold elapses
	eq(t, *got, 0, 2)
	if _, skips, _, _ := r.Counts(); skips != 1 {
		t.Fatalf("skips = %d, want 1: the tick that arms the ring must skip the gap", skips)
	}
}

// TestRingPushWarmupDeliversOnArrival is the same question at the OTHER arming
// site: the Push that ends the warm-up (ring.go, the `if single` inside the
// !armed branch). Same shape, armed by a frame rather than by a tick.
func TestRingPushWarmupDeliversOnArrival(t *testing.T) {
	r, got, _ := newSingleRing(50 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)                          // opens the warm-up
	push(r, 2, t0.Add(60*time.Millisecond)) // arms it AND must release on arrival
	eq(t, *got, 0, 2)
	if _, skips, _, _ := r.Counts(); skips != 1 {
		t.Fatalf("skips = %d, want 1: the arming Push must skip the gap at one live path", skips)
	}
}

// TestRingArrivalReleaseIsBudgeted pins ReleaseBudget on the arrival path and,
// with it, Tick's ARMED arrival branch. 300 frames land inside the warm-up with
// seq 270 lost, so the first release has more than ReleaseBudget deliverable
// frames: it must stop at 256 (a 300-frame burst to the WireGuard socket is the
// thing the budget exists to prevent) and the REMAINDER must come out on the
// next Tick, gap skipped. Without the budget test the first tick empties the
// ring; without the armed arrival branch the second tick drains, blocks on 270
// and strands everything behind it.
func TestRingArrivalReleaseIsBudgeted(t *testing.T) {
	got := new([]uint32)
	r := NewRing(9, 50*time.Millisecond, func(b []byte) {
		*got = append(*got, binary.BigEndian.Uint32(b))
	})
	r.SingleLive = func(time.Time) bool { return true }
	t0 := time.Now()
	for i := uint32(0); i < 300; i++ {
		if i == 270 {
			continue // lost on the single live path
		}
		push(r, i, t0)
	}
	eq(t, *got) // all inside the warm-up

	r.Tick(t0.Add(60 * time.Millisecond))
	if len(*got) != ReleaseBudget {
		t.Fatalf("first release delivered %d frames, want ReleaseBudget = %d", len(*got), ReleaseBudget)
	}
	r.Tick(t0.Add(61 * time.Millisecond))
	if len(*got) != 299 {
		t.Fatalf("after the resuming tick %d frames were delivered, want 299 (300 minus the lost seq)", len(*got))
	}
	if _, skips, _, _ := r.Counts(); skips != 1 {
		t.Fatalf("skips = %d, want 1: the resuming tick must skip the lost seq, not block on it", skips)
	}
}

// TestAttachSingleLiveDrivesTheRingFromTheRealPeersTable drives the rule
// through the wiring main() actually uses (attachSingleLive, main.go) instead
// of a test stub. Deleting the assignment leaves SingleLive nil -- every gap
// held forever, the pre-U139 behaviour -- and no other bar notices, because
// every ring test above installs its own predicate.
func TestAttachSingleLiveDrivesTheRingFromTheRealPeersTable(t *testing.T) {
	r, got := newTestRing(50 * time.Millisecond)
	p := &peers{}
	attachSingleLive(r, p)
	a := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}
	t0 := time.Now()

	p.learn(0, 0, a, t0) // exactly one live pathID on the real seen[] table
	push(r, 0, t0)
	r.Tick(t0.Add(60 * time.Millisecond))
	eq(t, *got, 0)

	push(r, 2, t0.Add(61*time.Millisecond)) // seq 1 lost: out at once
	eq(t, *got, 0, 2)

	p.learn(1, 0, a, t0.Add(62*time.Millisecond)) // a second path is live again
	push(r, 4, t0.Add(63*time.Millisecond))       // seq 3 may still be in flight
	eq(t, *got, 0, 2)
}
