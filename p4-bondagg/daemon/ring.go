package main

import (
	"sync"
	"time"
)

// Resequencer: releases in seq order; holds gaps up to Hold; straggler
// timeout skips (WG absorbs). THREAD-SAFE (multiple RX goroutines +
// ticker). Warm-up: after the first arrival, buffer for Hold before
// anchoring next to the MINIMUM buffered seq — cross-path startup
// reorder must not orphan the slower path's opening window.
type arr struct {
	seq  uint32
	when time.Time
}

type entry struct {
	seq   uint32
	data  []byte
	when  time.Time
	valid bool
}

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
	arrQ    []arr // arrival FIFO for overdue-epoch release
	// hold: owd-adaptive reorder horizon. Written by SetHold (under r.mu) from N
	// RX goroutines; read by holdNow (which callers invoke while holding r.mu) and
	// by HoldDur (under r.mu). #7: was an exported field written bare in the RX
	// hot loop while holdNow read it under the lock -> a data race.
	hold time.Duration
	// arrival: U17a. DELIVER-ON-ARRIVAL, the `speed` delivery policy
	// (modes-max-speed-design.md sec 4.3, AGG_SCHED=speed). See SetArrival.
	// false is `max` and is the whole of the in-order machinery above.
	arrival bool
	Out     func([]byte)
	OnSkip  func()
	OnOld   func(seq, next uint32)
	Skips   uint64
	Olds    uint64
	Delivs  uint64
	// Dups counts frames suppressed by the dedup memory in ARRIVAL mode. It is
	// the counter that makes first-copy-wins visible: with E2c lightning on, a
	// duplicated frame lands twice and exactly one of the two is delivered.
	Dups uint64
}

func NewRing(sizePow2 int, hold time.Duration, out func([]byte)) *Ring {
	n := 1 << sizePow2
	return &Ring{buf: make([]entry, n), mask: uint32(n - 1), hold: hold, Out: out}
}

// SetHold updates the reorder horizon under r.mu (RX goroutines call this on
// every data frame). #7.
func (r *Ring) SetHold(d time.Duration) {
	r.mu.Lock()
	r.hold = d
	r.mu.Unlock()
}

// HoldDur returns the current horizon under r.mu (STAT logging, off the RX path).
//
// In ARRIVAL mode it reports ZERO rather than the horizon nobody is waiting on.
// That is not cosmetic: `hold=0ms` in the PSTAT line is how an operator reading a
// log tells the two aggregate modes apart at a glance, and a stale nonzero
// number there would be the same class of lie as the one U17a exists to remove.
func (r *Ring) HoldDur() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.arrival {
		return 0
	}
	return r.hold
}

// SetArrival selects the DELIVERY policy. false (the zero value) is `max`'s
// in-order ring with its hold; true is `speed`'s deliver-on-arrival.
//
// MUST be called before the first Push -- the caller sets it immediately after
// NewRing, from the same goroutine, before any RX goroutine exists. It takes the
// lock anyway so the field is never written unsynchronised, but flipping it on a
// ring that already holds buffered frames would strand them: nothing in arrival
// mode ever drains the in-order buffer. There is no reason to flip it at run
// time -- the scheduler is a start-time fact (a mode change is an agg_env byte
// change, a crumb, and a process restart: bond.dag).
//
// WHAT ARRIVAL MODE IS, and what it is not:
//   - it RELEASES the instant a frame arrives. No hold, no in-order wait, no
//     straggler timeout, no skip. Measured to dominate every hold policy on
//     every `speed` scenario -- never worse on loss, latency or freeze (design
//     sec 4.3) -- because it can neither discard an arrived frame nor
//     head-of-line stall.
//   - the ring is STILL a ring, and that is the point: it is the DEDUP memory.
//     first-copy-wins for E2c lightning duplicates needs seq memory, and seq
//     memory is all it needs. The design's own phrasing: the copy TTL "becomes,
//     in `speed`, the dedup ring's retention horizon (memory bound, not a wait)"
//     (sec 5).
//   - the retention horizon is therefore the ring's SIZE IN SEQS, not a
//     duration. len(buf) seqs of memory: a duplicate that arrives more than
//     len(buf) sequence numbers after its twin finds the slot re-used and is
//     delivered a second time. No constant is introduced -- the size is the
//     ring's existing NewRing argument -- and the bound is stated rather than
//     assumed.
//   - it hands the application OUT-OF-ORDER frames on purpose. RTP reorders in
//     its own jitter buffer; an in-order tunnel under it is a second buffer in
//     series, and a gap under in-order delivery is a visible freeze (design sec
//     4.3, and Mo's intent-level reason: this layer retransmits nothing, so a
//     hold can never RECOVER a frame, only re-sequence it).
func (r *Ring) SetArrival(v bool) {
	r.mu.Lock()
	r.arrival = v
	r.mu.Unlock()
}

// Arrival reports the delivery policy this ring is running.
func (r *Ring) Arrival() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.arrival
}

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
	*e = entry{seq: seq, data: cp, when: now, valid: true}
	r.arrQ = append(r.arrQ, arr{seq: seq, when: now})
	if len(r.arrQ) > 4096 {
		r.arrQ = r.arrQ[len(r.arrQ)-2048:]
	}
}

// pushArrival is the whole of the `speed` receive path (r.mu held).
//
// Deliver, unless this seq is still in the dedup memory. Nothing is buffered,
// nothing is timed, nothing is skipped, and `next` is never consulted -- the
// in-order machinery below is not merely bypassed, it is not reachable from
// here.
//
// The payload is handed to Out WITHOUT a copy. The in-order path copies because
// it RETAINS the bytes across calls; this path retains nothing, so the copy
// would be pure cost on the frame that this mode exists to deliver fastest. The
// contract that buys it is stated here because it is a real one: Out must
// consume b before it returns. The shipped Out is a synchronous
// wgSock.WriteToUDP (pullrun.go), which does.
func (r *Ring) pushArrival(seq uint32, data []byte, now time.Time) {
	e := &r.buf[seq&r.mask]
	if e.valid && e.seq == seq {
		r.Dups++
		return
	}
	// The slot IS the dedup memory. data is not stored: retaining it would make
	// the ring hold len(buf) payloads for a mode that never re-reads one.
	*e = entry{seq: seq, when: now, valid: true}
	r.Delivs++
	r.Out(data)
}

func (r *Ring) Push(seq uint32, data []byte, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.arrival {
		r.pushArrival(seq, data, now)
		return
	}
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
		r.Olds++
		if r.OnOld != nil {
			r.OnOld(seq, r.next)
		}
		return
	}
	if seq-r.next > r.mask {
		r.flushTo(seq)
	}
	r.store(seq, data, now)
	r.drain(now)
}

// holdNow returns the effective (>=10ms) horizon. Callers MUST hold r.mu (Push,
// drain, Tick all do); the single-threaded tests call it directly. #7.
func (r *Ring) holdNow() time.Duration {
	if r.hold < 10*time.Millisecond {
		return 10 * time.Millisecond
	}
	return r.hold
}

// ReleaseBudget caps deliveries per Tick so hold-expiry epochs emit as a
// short paced smear instead of one socket-flooding burst.
const ReleaseBudget = 256

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
					r.Delivs++
					budget--
					e2.valid = false
				} else {
					r.Skips++
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
			r.Delivs++
			budget--
			e.valid = false
			r.next++
			r.blockOn = false
			continue
		}
		// O(1) gap timer: wait Hold for THIS missing seq, then skip.
		if !r.blockOn || r.blockN != r.next {
			r.blockOn = true
			r.blockN = r.next
			r.blockAt = now
			return
		}
		if now.Sub(r.blockAt) > r.holdNow() {
			// Overdue epoch: every buffered entry older than Hold has
			// waited its turn — release up to the newest overdue one,
			// skipping ALL missing seqs before it (budgeted, resumable).
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
			if target == r.next { // no overdue buffered: fall back to run-skip
				for {
					if !r.haveMax || int32(r.next-r.maxSeq) > 0 {
						r.blockOn = false
						return
					}
					e2 := &r.buf[r.next&r.mask]
					if e2.valid && e2.seq == r.next {
						break
					}
					r.Skips++
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

func (r *Ring) flushTo(seq uint32) {
	for r.next != seq {
		e := &r.buf[r.next&r.mask]
		if e.valid && e.seq == r.next {
			r.Out(e.data)
			r.Delivs++
			e.valid = false
		}
		r.next++
	}
}

func (r *Ring) Tick(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// ARRIVAL mode has nothing to tick: no frame is ever buffered, so no timer
	// can expire and no gap can be overdue. The control loop still calls this on
	// its existing cadence; it is a lock and a branch.
	if r.arrival {
		return
	}
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
