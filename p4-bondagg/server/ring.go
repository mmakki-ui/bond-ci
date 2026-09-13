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
	mu      sync.Mutex
	buf     []entry
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
	arrQ    []arr
	oldAt   time.Time
	oldRun  bool
	// hold is the owd-adaptive reorder horizon. Written by SetHold under r.mu
	// from the RX goroutine; read by holdNow (whose callers already hold r.mu)
	// and by HoldDur. Never a bare field write -- that was a real data race in
	// the client ring (#7).
	hold    time.Duration
	Out     func([]byte)
	OnSkip  func()
	OnOld   func(seq, next uint32)
	skips   uint64
	olds    uint64
	delivs  uint64
	resyncs uint64
}

func NewRing(sizePow2 int, hold time.Duration, out func([]byte)) *Ring {
	n := 1 << sizePow2
	return &Ring{buf: make([]entry, n), mask: uint32(n - 1), hold: hold, Out: out}
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

// ReleaseBudget caps deliveries per drain so a hold-expiry epoch emits as a
// short paced smear instead of one socket-flooding burst.
const ReleaseBudget = 256

func (r *Ring) store(seq uint32, data []byte, now time.Time) {
	if !r.haveMax || int32(seq-r.maxSeq) > 0 {
		r.maxSeq = seq
		r.haveMax = true
	}
	e := &r.buf[seq&r.mask]
	if e.valid && e.seq == seq {
		return
	}
	cp := make([]byte, len(data))
	copy(cp, data)
	*e = entry{seq: seq, data: cp, valid: true}
	r.arrQ = append(r.arrQ, arr{seq: seq, when: now})
	if len(r.arrQ) > 4096 {
		r.arrQ = r.arrQ[len(r.arrQ)-2048:]
	}
}

// Push admits one frame. data is copied, so the caller may reuse its buffer.
func (r *Ring) Push(seq uint32, data []byte, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.armed {
		if !r.haveMin {
			r.firstAt = now
			r.minSeq = seq
			r.haveMin = true
		} else if int32(seq-r.minSeq) < 0 {
			r.minSeq = seq
		}
		r.store(seq, data, now)
		if now.Sub(r.firstAt) >= r.holdNow() {
			r.armed = true
			r.next = r.minSeq
			r.drain(now)
		}
		return
	}
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
	r.drain(now)
}

// resync drops the stale buffer and restarts the warm-up anchored on seq.
// Callers MUST hold r.mu.
func (r *Ring) resync(seq uint32, now time.Time) {
	for i := range r.buf {
		r.buf[i].valid = false
		r.buf[i].data = nil
	}
	r.arrQ = r.arrQ[:0]
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
	r.arrQ = r.arrQ[:0]
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
			for len(r.arrQ) > 0 {
				h := r.arrQ[0]
				if now.Sub(h.when) <= r.holdNow() {
					break
				}
				if int32(h.seq-target) > 0 {
					target = h.seq
				}
				r.arrQ = r.arrQ[1:]
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
func (r *Ring) Tick(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.armed {
		if r.haveMin && now.Sub(r.firstAt) >= r.holdNow() {
			r.armed = true
			r.next = r.minSeq
			r.drain(now)
		}
		return
	}
	r.drain(now)
}
