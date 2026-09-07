package main

import (
	"errors"
	"net"
	"os"
	"sync"
	"syscall"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// The two DEFECTS the adversarial review of db1a300 confirmed, as tests.
//   D1  ENOBUFS was classified as a path error: the frame was dropped and
//       BlockedMs read ~0 in exactly the regime it exists to detect.
//   D2  the pool had no admission bound; the only bound was Trim, once per
//       PingIval, from the control goroutine.
// ---------------------------------------------------------------------------

// wrapErrno reproduces how the runtime hands a sendto errno back from
// WriteToUDP: *net.OpError wrapping *os.SyscallError wrapping syscall.Errno.
// The classifier must see through both layers, which is why it uses errors.Is
// and not a string match on err.Error().
func wrapErrno(e syscall.Errno) error {
	return &net.OpError{Op: "write", Net: "udp", Err: os.NewSyscallError("sendto", e)}
}

func mustClassify(t *testing.T, name string, err error, want sendResult) {
	t.Helper()
	if got := classifySend(err); got != want {
		t.Fatalf("classifySend(%s) = %d, want %d", name, got, want)
	}
}

// D1. ENOBUFS is BACKPRESSURE, not an error. Linux returns it when the device
// qdisc is full -- the normal shape of edge backpressure on a router with a
// small txqueuelen -- and the Go netpoller never parks on it because it is not
// EAGAIN. Classifying it as a path error dropped the frame AND left BlockedMs
// reading ~0 in precisely the regime BlockedMs exists to detect, which is
// G1/E1's edge-vs-mid discriminator.
func TestPullSendClassifiesBackpressureVsPathDown(t *testing.T) {
	mustClassify(t, "nil", nil, sendOK)

	mustClassify(t, "ENOBUFS", wrapErrno(syscall.ENOBUFS), sendBackpressure)
	mustClassify(t, "ENOMEM", wrapErrno(syscall.ENOMEM), sendBackpressure)
	mustClassify(t, "EAGAIN", wrapErrno(syscall.EAGAIN), sendBackpressure)
	mustClassify(t, "EWOULDBLOCK", wrapErrno(syscall.EWOULDBLOCK), sendBackpressure)

	mustClassify(t, "ENETUNREACH", wrapErrno(syscall.ENETUNREACH), sendPathDown)
	mustClassify(t, "EHOSTUNREACH", wrapErrno(syscall.EHOSTUNREACH), sendPathDown)
	mustClassify(t, "ENODEV", wrapErrno(syscall.ENODEV), sendPathDown)
	mustClassify(t, "EINVAL", wrapErrno(syscall.EINVAL), sendPathDown)
	mustClassify(t, "EPERM", wrapErrno(syscall.EPERM), sendPathDown)
	mustClassify(t, "non-errno", errors.New("use of closed connection"), sendPathDown)
}

// The classifier must also see a BARE errno and a singly-wrapped one: not every
// path through the net package produces the full three-layer wrapping.
func TestPullSendClassifiesUnwrappedErrno(t *testing.T) {
	mustClassify(t, "bare ENOBUFS", syscall.ENOBUFS, sendBackpressure)
	mustClassify(t, "SyscallError ENOBUFS",
		os.NewSyscallError("sendto", syscall.ENOBUFS), sendBackpressure)
	mustClassify(t, "bare ENETUNREACH", syscall.ENETUNREACH, sendPathDown)
}

// D1, second half: a backpressure refusal must not consume the frame. Every shed
// decision in the pull core lives in the pool, so Return puts the head frame
// back, at the head, on its ORIGINAL enq clock, visible again to the pool bound
// and to every other link.
func TestPullFIFOReturnRestoresHeadAndAccounting(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	f.Enqueue([]byte{0, 0, 0}, now)
	f.Enqueue([]byte{1, 1, 1}, now)
	beforeBytes, _, _, _, _ := f.ByteStats()

	fr, ok := f.Draw()
	if !ok || fr.Seq() != 0 {
		t.Fatalf("draw: ok=%v, want the head frame seq 0", ok)
	}
	midBytes, _, _, _, _ := f.ByteStats()
	if midBytes >= beforeBytes {
		t.Fatalf("draw did not debit byte occupancy: %d -> %d", beforeBytes, midBytes)
	}

	f.Return(fr, now)
	afterBytes, _, _, _, retq := f.ByteStats()
	if afterBytes != beforeBytes {
		t.Fatalf("Return did not restore byte occupancy: %d, want %d", afterBytes, beforeBytes)
	}
	if retq != 1 {
		t.Fatalf("retq=%d, want 1", retq)
	}
	got, ok := f.Draw()
	if !ok || got.Seq() != 0 {
		t.Fatalf("after Return the head is not seq 0 (ok=%v)", ok)
	}
	if !got.enq.Equal(now) {
		t.Fatalf("Return restamped the frame: enq=%v want %v", got.enq, now)
	}
	// drawn is NET of Return, so a refused frame is not counted as having left.
	_, _, enq, drawn, _ := f.Stats()
	if enq != 2 || drawn != 1 {
		t.Fatalf("enq=%d drawn=%d, want 2/1", enq, drawn)
	}
}

// A Returned frame that has gone over-age is shed by the bound rather than
// reinstated: Return re-bounds the pool like any other mutation.
func TestPullFIFOReturnIsBounded(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	f.Trim(now, 200*time.Millisecond)
	f.Enqueue([]byte{0}, now)
	fr, ok := f.Draw()
	if !ok {
		t.Fatal("draw: pool reported empty")
	}
	f.Return(fr, now.Add(10*time.Second))
	if depth, _, _, _, _ := f.Stats(); depth != 0 {
		t.Fatalf("depth=%d after returning an over-age frame, want 0", depth)
	}
}

// D2. The pool must be bounded AT ENQUEUE, not only by a Trim that runs once per
// PingIval from the control goroutine. Before this fix the pool grew without
// limit at the WG read rate between trims, and no frame younger than the hold
// was ever dropped at any depth. No Trim is called anywhere in this test.
func TestPullFIFOByteBoundAppliesAtEnqueue(t *testing.T) {
	f := NewPullFIFO()
	const payload = 100
	f.SetMaxBytes(3 * (payload + HdrLen))
	now := time.Now()
	for i := 0; i < 50; i++ {
		f.Enqueue(make([]byte, payload), now)
	}
	depth, _, enq, _, stale := f.Stats()
	bytes, _, max, qdrops, _ := f.ByteStats()
	if enq != 50 {
		t.Fatalf("enq=%d, want 50", enq)
	}
	if bytes > max {
		t.Fatalf("byte occupancy %d exceeds the bound %d", bytes, max)
	}
	if depth != 3 {
		t.Fatalf("depth=%d, want 3 (the bound), with no Trim called", depth)
	}
	if qdrops != 47 {
		t.Fatalf("qdrops=%d, want 47", qdrops)
	}
	if stale != 0 {
		t.Fatalf("stale=%d: the AGE limb shed frames the BYTE limb owned", stale)
	}
	// OLDEST-first, like the oracle's popleft: the survivors are the newest.
	for want := uint32(47); want < 50; want++ {
		fr, ok := f.Draw()
		if !ok || fr.Seq() != want {
			t.Fatalf("survivor: ok=%v, want seq %d", ok, want)
		}
	}
}

// The age limb must apply at enqueue too, once a control tick has installed a
// hold -- otherwise the bound is still only sampled at the control cadence.
func TestPullFIFOAgeBoundAppliesAtEnqueueBetweenTrims(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	f.Trim(now, 200*time.Millisecond) // the only Trim here: it installs the limb
	f.Enqueue([]byte{0}, now.Add(-400*time.Millisecond))
	f.Enqueue([]byte{1}, now.Add(-300*time.Millisecond))
	f.Enqueue([]byte{2}, now)
	depth, _, _, _, stale := f.Stats()
	if depth != 1 || stale != 2 {
		t.Fatalf("depth=%d stale=%d, want 1/2 (shed at enqueue, no second Trim)", depth, stale)
	}
	fr, ok := f.Draw()
	if !ok || fr.Seq() != 2 {
		t.Fatalf("survivor ok=%v, want seq 2", ok)
	}
}

// Before any control tick has run there is no hold to bound on, and the age limb
// must be OFF rather than dropping everything it sees.
func TestPullFIFOAgeLimbOffUntilAHoldIsKnown(t *testing.T) {
	f := NewPullFIFO()
	f.Enqueue([]byte{0}, time.Now().Add(-time.Hour))
	if depth, _, _, _, stale := f.Stats(); depth != 1 || stale != 0 {
		t.Fatalf("depth=%d stale=%d, want 1/0 before a hold is installed", depth, stale)
	}
}

// A single frame larger than the whole ceiling is ADMITTED, not discarded: the
// byte limb never empties the pool below one frame. Refusing all traffic on a box
// with a tiny wmem_default would be a worse failure than a bounded one-frame
// overshoot, and the overshoot is stated rather than hidden.
func TestPullFIFOByteBoundNeverEmptiesPoolBelowOneFrame(t *testing.T) {
	f := NewPullFIFO()
	f.SetMaxBytes(1)
	now := time.Now()
	f.Enqueue(make([]byte, MaxPayload), now)
	if depth, _, _, _, _ := f.Stats(); depth != 1 {
		t.Fatalf("depth=%d, want 1: an oversize frame must still be admitted", depth)
	}
	f.Enqueue(make([]byte, MaxPayload), now)
	if depth, _, _, _, _ := f.Stats(); depth != 1 {
		t.Fatalf("depth=%d, want 1: the bound must hold at one frame", depth)
	}
}

// Both limbs default OFF, so a pool that never installs them behaves exactly as
// it did before. That is what keeps the pre-existing exactly-once draw tests
// measuring what they were written to measure.
func TestPullFIFOBoundsDefaultOff(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	for i := 0; i < 200; i++ {
		f.Enqueue(make([]byte, MaxPayload), now.Add(-time.Hour))
	}
	depth, _, _, _, stale := f.Stats()
	_, _, max, qdrops, _ := f.ByteStats()
	if depth != 200 || stale != 0 || qdrops != 0 || max != 0 {
		t.Fatalf("depth=%d stale=%d qdrops=%d max=%d, want 200/0/0/0", depth, stale, qdrops, max)
	}
}

// The byte bound is N-generic: one pool-wide ceiling, no per-path term, and the
// conservation law still holds for every N -- every enqueued frame is either
// drawn exactly once, shed by the bound, or still in the pool.
func TestPullFIFOBoundedPoolConservesFramesForAnyN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		f := NewPullFIFO()
		const payload = 64
		const offered = 2000
		f.SetMaxBytes(16 * (payload + HdrLen))
		var mu sync.Mutex
		got := make(map[uint32]int)
		var wg sync.WaitGroup
		for d := 0; d < n; d++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for {
					fr, ok := f.Draw()
					if !ok {
						if f.Closed() {
							return
						}
						continue
					}
					mu.Lock()
					got[fr.Seq()]++
					mu.Unlock()
				}
			}()
		}
		now := time.Now()
		for i := 0; i < offered; i++ {
			f.Enqueue(make([]byte, payload), now)
		}
		time.Sleep(100 * time.Millisecond)
		f.Close()
		wg.Wait()
		_, _, _, qdrops, _ := f.ByteStats()
		depth, _, _, _, _ := f.Stats()
		mu.Lock()
		drew := len(got)
		for seq, c := range got {
			if c != 1 {
				mu.Unlock()
				t.Fatalf("N=%d: seq %d drawn %d times, want 1", n, seq, c)
			}
		}
		mu.Unlock()
		if uint64(drew)+qdrops+uint64(depth) != offered {
			t.Fatalf("N=%d: drew=%d + qdrop=%d + depth=%d = %d, want %d",
				n, drew, qdrops, depth, uint64(drew)+qdrops+uint64(depth), offered)
		}
	}
}
