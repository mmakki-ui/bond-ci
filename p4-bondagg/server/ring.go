package main

import (
	"sync"
	"time"
)

// THE RESEQUENCER.
//
// Ring is a port of the client's reorder ring
// (p4-bondagg/daemon/ring.go). It releases in seq order, holds a gap for up to
// hold, then skips it (WireGuard absorbs the loss). Warm-up buffers for one
// hold after the first arrival and then anchors on the MINIMUM buffered seq, so
// cross-link startup reorder cannot orphan the slower link's opening window.
// Thread-safe: the RX goroutine pushes while the tick goroutine drains.
//
// TWO DELIBERATE DIVERGENCES from the client ring, both of them hardening for a
// daemon that listens on a public UDP port rather than behind the client's own
// device-bound sockets.
//
// 1. BOUNDED forward re-anchor. The client's flushTo walks next..seq one seq at
// a time, so a single frame carrying a far-future seq -- garbage, or a spoof
// that gets past the two-byte magic/ver check -- makes that walk up to 2^31
// iterations long while holding the ring lock. reanchor delivers only what is
// BUFFERED, at most mask+1 entries (Push rejects anything further ahead than
// mask before it stores), then jumps next to seq. Same observable behaviour,
// O(ring) instead of O(jump).
//
// 2. SEQ-SPACE RESYNC. If the client restarts, its seq counter restarts near 0
// while next sits at some large value, so every arrival is classified old and
// the ring goes permanently silent -- a bricked tunnel that only a server
// restart clears. If every arrival for one full hold horizon has been old, the
// peer's sequence space has moved: drop the stale buffer and re-arm on the new
// one. Two derived conditions, no new constant: the horizon is the hold itself
// (exactly how long this ring is willing to wait for order), and only a seq
// outside the ring window (more than mask behind next) counts towards the run,
// so a straggler or a late duplicate copy can never re-anchor the ring
// backwards.
//
// 3. SINGLE-LIVE-PATH ARRIVAL (U139). The hold exists to reorder ACROSS paths.
// With exactly ONE live path there is nothing to reorder across: a seq gap is a
// LOSS, not a reorder, and waiting a hold for it buys nothing and costs 150-350
// ms of head-of-line stall on every uplink loss -- a stall `direct` never pays,
// which is what would make `eco` (N=1) worse than not bonding at all. So when
// the arrival predicate says one path, the ring delivers on arrival and skips
// gaps immediately; dedup is the SAME old-seq test the hold path already uses
// (anything behind next is dropped and counted), so a duplicate copy still
// cannot be forwarded twice, and the divergence-2 resync still fires.
//
// It is MODE-BLIND, which is constraint C4: the server never learns which mode
// the client runs. The predicate is a property of the WIRE -- how many pathIDs
// have been seen inside EpMaxAge (main.go, peers.singleLiveAt, over the same
// seen[] table the downlink hint already ages) -- so a second live path restores
// the hold by itself, at the next frame, with nothing configured on this box.
// No new constant: EpMaxAge is already derived from the peer's own DeadIval.
//
// THE ONE-HOLD GRACE, and why the raw predicate is not enough (U139 fix round).
// "Exactly one pathID seen inside EpMaxAge" answers a question the ring did not
// ask. It reads TRUE in two states that are not N=1 at all, and in both of them
// arming arrival mode LOSES a frame the hold would have delivered:
//
//	COLD START. The first frame of a 2-path bond is heard from ONE path,
//	because the second has not spoken yet. Arming on it anchors next at that
//	seq, and the slower link's opening frame -- a LOWER seq, ~30 ms behind --
//	lands on the old-seq limb and is dropped. Measured on the shipped build:
//	push(1,t0), live=2, push(0,t0+30ms) -> delivered=[1], olds=1.
//
//	A DATA-QUIET LIVE PATH. With the auth gate OPEN only DATA refreshes seen[]
//	(main.go, EpMaxAge), so a still-live path carrying no DATA for 600 ms reads
//	as gone. Arrival mode then advances next past a seq still IN FLIGHT on it.
//	Measured: delivered=[0 1 3], skips=1, olds=1 -- the frame is LOST, not
//	merely skipped as an earlier write-up of this edge claimed.
//
// Both are one error: trusting a live count that has not been stable long enough
// to mean anything. TWO SEPARATE mechanisms answer them, and each is pinned by
// its own bar:
//
//	COLD START is closed by the WARM-UP being UNCONDITIONAL. Push/Tick arm
//	only once a hold has passed since firstAt, and they anchor next on the
//	MINIMUM seq seen in that window (divergence 1), so the slower link's
//	opening frame is already buffered when the anchor is chosen. Arrival mode
//	is never consulted before the ring is armed. Red without it:
//	TestRingColdStartTwoPathsKeepsSlowerOpeningFrame.
//
//	THE DATA-QUIET PATH is closed by arrivalOK's ONE-HOLD GRACE: multiAt is
//	stamped at every Push/Tick where the wire does NOT read as single, and
//	arrival mode starts only once a whole hold has passed since. A path that
//	falls out of the live count therefore keeps the ring on the hold path for
//	one more hold -- long enough to take a frame still in flight on it. Red
//	without it: TestRingDataQuietPathDoesNotLoseInflightFrame.
//
// The hold is exactly the window this ring was already willing to spend on a
// cross-path reorder, so the grace costs nothing new; what it gives up is the
// one-time early arm on the very first frame (one warm-up per ring, and one per
// resync), which was never where U139's value was.

// arr is one arrival on the FIFO used to age the overdue-release epoch.
type arr struct {
	seq  uint32
	when time.Time
}

// entry is one buffered frame, indexed by seq&mask.
type entry struct {
	seq   uint32
	data  []byte
	valid bool
}

// Ring is the seq-ordered release buffer. See the block comment above.
type Ring struct {
	mu  sync.Mutex
	buf []entry
	// slab is the fixed frame storage the ring owns, one [MaxFrame]byte per
	// buf slot (U131). store() slices slab[idx][:n] into entry.data instead
	// of allocating -- the array already lives in slab, so the slice header
	// costs nothing. Sized 1<<sizePow2 in NewRing (2048x1522B ~= 3.1MiB at
	// the production RingPow2=11).
	slab    [][MaxFrame]byte
	mask    uint32
	next    uint32
	armed   bool
	firstAt time.Time
	minSeq  uint32
	haveMin bool
	maxSeq  uint32
	haveMax bool
	blockN  uint32
	blockAt time.Time
	blockOn bool
	epochTo uint32
	epochOn bool
	// arrival FIFO used to age the overdue-release epoch, as a fixed ring
	// (U131): arrBuf is preallocated once in NewRing at 2x ring capacity --
	// a 4096-cap (2x ring capacity), evict-oldest-on-full policy the old grow-then-truncate
	// slice held for the production RingPow2=11 config -- and arrHead/arrCount
	// index into it. No allocation on the store path.
	arrBuf   []arr
	arrHead  int
	arrCount int
	oldAt    time.Time
	oldRun   bool
	// hold is the owd-adaptive reorder horizon. Written by SetHold under r.mu
	// from the RX goroutine; read by holdNow (whose callers already hold r.mu)
	// and by HoldDur. Never a bare field write -- that was a real data race in
	// the client ring (#7).
	hold time.Duration
	Out  func([]byte)
	// SingleLive reports whether exactly ONE path was live at `now` (U139,
	// divergence 3). Set ONCE in main() to peers.singleLiveAt, before any
	// goroutine runs, exactly like Out/OnSkip/OnOld; nil means "always hold",
	// so a Ring built without it behaves as it did before this unit.
	//
	// LOCK ORDER, because this is the one callback that takes another lock:
	// it is called with r.mu HELD and it takes peers.mu. Nothing anywhere
	// takes peers.mu and then r.mu -- rx.Handle calls peers.learn and
	// ring.Push in sequence, never nested -- so r.mu -> peers.mu is the only
	// order that exists and it cannot deadlock.
	SingleLive func(now time.Time) bool
	// multiAt is the last instant at which the wire did NOT read as exactly
	// one live path. arrivalOK requires a whole hold since multiAt before
	// arrival mode may start -- see THE ONE-HOLD GRACE above. Written and
	// read under r.mu.
	multiAt time.Time
	OnSkip  func()
	OnOld   func(seq, next uint32)
	skips   uint64
	olds    uint64
	delivs  uint64
	resyncs uint64
}

func NewRing(sizePow2 int, hold time.Duration, out func([]byte)) *Ring {
	n := 1 << sizePow2
	return &Ring{
		buf:    make([]entry, n),
		slab:   make([][MaxFrame]byte, n),
		mask:   uint32(n - 1),
		hold:   hold,
		Out:    out,
		arrBuf: make([]arr, 2*n),
	}
}

// SetHold updates the reorder horizon under r.mu.
func (r *Ring) SetHold(d time.Duration) {
	r.mu.Lock()
	r.hold = d
	r.mu.Unlock()
}

// HoldDur returns the current horizon under r.mu (stats path only).
func (r *Ring) HoldDur() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hold
}

// Counts returns the ring's counters under r.mu. The client daemon reads its
// equivalents bare from the stats goroutine, which races the RX path; taking
// the lock here costs one uncontended acquire per second.
func (r *Ring) Counts() (delivs, skips, olds, resyncs uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.delivs, r.skips, r.olds, r.resyncs
}

// holdNow returns the effective horizon, floored so a degenerate hold cannot
// spin the gap timer. Callers MUST hold r.mu.
func (r *Ring) holdNow() time.Duration {
	if r.hold < 10*time.Millisecond {
		return 10 * time.Millisecond
	}
	return r.hold
}

// arrivalOK reports whether the ring may run in ARRIVAL mode: the wire-derived
// predicate must say exactly one live path AND it must have said so for a whole
// hold. It also stamps multiAt, so it MUST be called once per Push and once per
// Tick, before anything else looks at the answer -- the grace is measured from
// the last observation, not from a timer.
//
// On a COLD START multiAt is still the zero time, so a first observation of
// "one live path" satisfies the grace immediately. That is deliberate and safe
// only because the warm-up above it is unconditional: the ring is not armed
// yet, so nothing reads the answer until firstAt+hold. Do not move the warm-up
// behind this predicate -- that is exactly the cold-start frame loss.
//
// A Ring with no predicate wired (every unit test that predates U139, and any
// future caller that does not set it) always holds. Callers MUST hold r.mu.
func (r *Ring) arrivalOK(now time.Time) bool {
	if r.SingleLive == nil {
		return false
	}
	if !r.SingleLive(now) {
		r.multiAt = now
		return false
	}
	// `>` not `>=`: the two differ only when the elapsed grace equals the hold
	// to the nanosecond, so a bar cannot separate them on a wall clock and a
	// green on flipping it is expected. The direction is chosen, not accidental
	// -- at the tie the conservative rule (keep holding) wins, which is the
	// same tie-break the warm-up makes in the other direction (`>=` there,
	// because the warm-up ending is what releases traffic at all).
	return now.Sub(r.multiAt) > r.holdNow()
}

// ReleaseBudget caps deliveries per drain so a hold-expiry epoch emits as a
// short paced smear instead of one socket-flooding burst.
const ReleaseBudget = 256

func (r *Ring) store(seq uint32, data []byte, now time.Time) {
	if !r.haveMax || int32(seq-r.maxSeq) > 0 {
		r.maxSeq = seq
		r.haveMax = true
	}
	idx := seq & r.mask
	e := &r.buf[idx]
	if e.valid && e.seq == seq {
		return
	}
	n := copy(r.slab[idx][:], data)
	e.seq = seq
	e.data = r.slab[idx][:n]
	e.valid = true
	r.arrPush(arr{seq: seq, when: now})
}

// arrPush enqueues onto the fixed arrival ring, evicting the oldest entry
// when full (capacity 2*(mask+1), set in NewRing). Callers MUST hold r.mu.
func (r *Ring) arrPush(a arr) {
	if r.arrCount == len(r.arrBuf) {
		r.arrHead = (r.arrHead + 1) % len(r.arrBuf)
		r.arrCount--
	}
	tail := (r.arrHead + r.arrCount) % len(r.arrBuf)
	r.arrBuf[tail] = a
	r.arrCount++
}

// arrFront returns the oldest queued arrival without removing it.
// Callers MUST hold r.mu.
func (r *Ring) arrFront() (arr, bool) {
	if r.arrCount == 0 {
		return arr{}, false
	}
	return r.arrBuf[r.arrHead], true
}

// arrPopFront removes the oldest queued arrival. Callers MUST hold r.mu.
func (r *Ring) arrPopFront() {
	if r.arrCount == 0 {
		return
	}
	r.arrHead = (r.arrHead + 1) % len(r.arrBuf)
	r.arrCount--
}

// arrReset empties the arrival ring without touching its backing array --
// no allocation. Callers MUST hold r.mu.
func (r *Ring) arrReset() {
	r.arrHead = 0
	r.arrCount = 0
}

// Push admits one frame. data is copied, so the caller may reuse its buffer.
func (r *Ring) Push(seq uint32, data []byte, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	single := r.arrivalOK(now)
	if !r.armed {
		if !r.haveMin {
			r.firstAt = now
			r.minSeq = seq
			r.haveMin = true
		} else if int32(seq-r.minSeq) < 0 {
			r.minSeq = seq
		}
		r.store(seq, data, now)
		// The warm-up buffers one hold so a SLOWER LINK's opening window is
		// not orphaned by the faster link's anchor. It is UNCONDITIONAL: the
		// live count cannot distinguish N=1 from "the second path has not
		// spoken yet", so an early arm here anchors on the faster link and
		// drops the slower one's opening frame (the cold-start measurement
		// above). This is the ONLY thing that closes the cold start --
		// arrivalOK's grace does not, because at cold start multiAt is the
		// zero time and the predicate reads OK on the first observation.
		//
		// The single/drain choice on THIS release (the Push that ends the
		// warm-up) is pinned by TestRingPushWarmupDeliversOnArrival: at one
		// live path the frame that arms the ring must also skip an opening
		// gap at once, exactly as a later Push would.
		if now.Sub(r.firstAt) >= r.holdNow() {
			r.armed = true
			r.next = r.minSeq
			if single {
				r.deliverArrival(now)
			} else {
				r.drain(now)
			}
		}
		return
	}
	// THIS IS ALSO THE ARRIVAL-MODE DEDUP (U139). Arrival mode advances next
	// past every seq it delivers or skips, so a second copy of an already
	// handled seq lands here, is counted old and is dropped -- "deliver on
	// arrival with dedup only" needs no separate table and no new state. The
	// resync limb below stays live in arrival mode too: at N=1 a client restart
	// would otherwise brick the tunnel exactly as divergence 2 describes.
	if int32(seq-r.next) < 0 {
		r.olds++
		if r.OnOld != nil {
			r.OnOld(seq, r.next)
		}
		// Only a seq OUTSIDE the ring window can be a restarted sequence space.
		// Anything within mask of next is an ordinary straggler or a duplicate
		// copy, and must never arm the resync -- a stalled link dribbling late
		// copies would otherwise re-anchor the ring backwards and replay.
		if r.next-seq <= r.mask {
			return
		}
		if !r.oldRun {
			r.oldRun = true
			r.oldAt = now
			return
		}
		if now.Sub(r.oldAt) <= r.holdNow() {
			return
		}
		// Divergence 2: a whole hold horizon of nothing but old seqs means the
		// peer's sequence space restarted. Re-arm the warm-up on this frame.
		r.resync(seq, now)
		r.store(seq, data, now)
		return
	}
	r.oldRun = false
	if seq-r.next > r.mask {
		r.reanchor(seq)
	}
	r.store(seq, data, now)
	if single {
		r.deliverArrival(now)
		return
	}
	r.drain(now)
}

// deliverArrival is drain's counterpart for ONE live path: release everything
// buffered up to the newest seq seen, skipping any missing seq immediately
// instead of arming the gap timer. On one path a gap is a loss -- there is no
// second link it could still arrive on -- so the hold could only ever expire,
// never be redeemed. Callers MUST hold r.mu.
//
// It clears blockOn/epochOn as it goes, so the moment a second path becomes
// live the ordinary drain() resumes from a clean gap timer rather than from a
// block armed under the other rule. NO BAR PINS THAT CLEAR, and a green on
// deleting it is EXPECTED: an arrival release that runs to completion leaves
// next past both blockN and epochTo, and drain re-arms its own gap timer
// (`!r.blockOn || r.blockN != r.next`) and exits a spent epoch on its first
// comparison. The one shape where the clear is observable needs a
// budget-exhausted release (>256 frames, TestRingArrivalReleaseIsBudgeted)
// that stops BEHIND a live epochTo and a second path returning before the next
// Tick; the clear is kept as the cheap side of that corner, not as dead code.
//
// Bounded like reanchor: Push never stores a seq more than mask ahead of next
// (it reanchors first), so the walk is at most mask+1 iterations. The same
// ReleaseBudget paces the delivery; a budget exhaustion resumes on the next
// Push or Tick -- pinned by TestRingArrivalReleaseIsBudgeted, which asserts
// both halves: at most ReleaseBudget frames leave in one release, and the
// remainder (gap included) leaves on the following Tick.
func (r *Ring) deliverArrival(now time.Time) {
	r.blockOn = false
	r.epochOn = false
	budget := ReleaseBudget
	for {
		if !r.haveMax || int32(r.next-r.maxSeq) > 0 {
			return
		}
		e := &r.buf[r.next&r.mask]
		if e.valid && e.seq == r.next {
			if budget == 0 {
				return
			}
			r.Out(e.data)
			r.delivs++
			budget--
			e.valid = false
			r.next++
			continue
		}
		r.skips++
		if r.OnSkip != nil {
			r.OnSkip()
		}
		r.next++
	}
}

// resync drops the stale buffer and restarts the warm-up anchored on seq.
// Callers MUST hold r.mu.
func (r *Ring) resync(seq uint32, now time.Time) {
	for i := range r.buf {
		r.buf[i].valid = false
		r.buf[i].data = nil
	}
	r.arrReset()
	r.armed = false
	r.haveMax = false
	r.blockOn = false
	r.epochOn = false
	r.oldRun = false
	r.firstAt = now
	r.minSeq = seq
	r.haveMin = true
	r.resyncs++
}

// reanchor handles a forward jump further than the ring can hold: deliver every
// buffered entry in seq order, then jump next to seq. Bounded by the ring size
// because Push never stores a seq more than mask ahead of next. Callers MUST
// hold r.mu.
func (r *Ring) reanchor(seq uint32) {
	for i := uint32(0); i <= r.mask; i++ {
		s := r.next + i
		e := &r.buf[s&r.mask]
		if e.valid && e.seq == s {
			r.Out(e.data)
			r.delivs++
			e.valid = false
		}
	}
	r.arrReset()
	r.next = seq
	r.blockOn = false
	r.epochOn = false
}

func (r *Ring) drain(now time.Time) {
	budget := ReleaseBudget
	for {
		if r.epochOn {
			for int32(r.next-r.epochTo) <= 0 {
				if budget == 0 {
					return // resume this epoch next Tick
				}
				e2 := &r.buf[r.next&r.mask]
				if e2.valid && e2.seq == r.next {
					r.Out(e2.data)
					r.delivs++
					budget--
					e2.valid = false
				} else {
					r.skips++
					if r.OnSkip != nil {
						r.OnSkip()
					}
				}
				r.next++
			}
			r.epochOn = false
			r.blockOn = false
		}
		e := &r.buf[r.next&r.mask]
		if e.valid && e.seq == r.next {
			if budget == 0 {
				return
			}
			r.Out(e.data)
			r.delivs++
			budget--
			e.valid = false
			r.next++
			r.blockOn = false
			continue
		}
		// O(1) gap timer: wait one hold for THIS missing seq, then skip.
		if !r.blockOn || r.blockN != r.next {
			r.blockOn = true
			r.blockN = r.next
			r.blockAt = now
			return
		}
		if now.Sub(r.blockAt) > r.holdNow() {
			// Overdue epoch: every buffered entry older than hold has waited
			// its turn -- release up to the newest overdue one, skipping all
			// missing seqs before it (budgeted, resumable).
			target := r.next
			for {
				h, ok := r.arrFront()
				if !ok {
					break
				}
				if now.Sub(h.when) <= r.holdNow() {
					break
				}
				if int32(h.seq-target) > 0 {
					target = h.seq
				}
				r.arrPopFront()
			}
			if target == r.next { // nothing overdue buffered: fall back to run-skip
				for {
					if !r.haveMax || int32(r.next-r.maxSeq) > 0 {
						r.blockOn = false
						return
					}
					e2 := &r.buf[r.next&r.mask]
					if e2.valid && e2.seq == r.next {
						break
					}
					r.skips++
					if r.OnSkip != nil {
						r.OnSkip()
					}
					r.next++
				}
				r.blockOn = false
				continue
			}
			r.epochTo = target
			r.epochOn = true
			continue
		}
		return
	}
}

// Tick services the gap timer. Called from the service goroutine.
//
// It re-reads the arrival predicate every tick, which is what makes the
// TRANSITION cost nothing in the direction that is safe: a second path arriving
// restores the hold at the next tick rather than at the next frame. The other
// direction is deliberately NOT symmetric -- a path going quiet only starts
// arrivalOK's one-hold grace, because a frame may still be in flight on it.
//
// Tick is also the ONLY way the ring enters arrival mode with no further Push:
// a client that opens with a gap and then stops sending is armed and released
// here, and at one live path that release must skip the gap at once instead of
// arming the gap timer. Pinned by
// TestRingTickAloneDeliversOnArrivalWithOneLivePath (the UNARMED branch: arm
// and release from a Tick, no Push after the hold elapses) and by
// TestRingArrivalReleaseIsBudgeted (the ARMED branch: a budget-exhausted
// release resumes on the next Tick and must still skip the gap). Both are red
// with `single` forced false here.
func (r *Ring) Tick(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	single := r.arrivalOK(now)
	if !r.armed {
		if r.haveMin && now.Sub(r.firstAt) >= r.holdNow() {
			r.armed = true
			r.next = r.minSeq
			if single {
				r.deliverArrival(now)
			} else {
				r.drain(now)
			}
		}
		return
	}
	if single {
		r.deliverArrival(now)
		return
	}
	r.drain(now)
}
