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
	hold   time.Duration
	Out    func([]byte)
	OnSkip func()
	OnOld  func(seq, next uint32)
	Skips  uint64
	Olds   uint64
	Delivs uint64
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
func (r *Ring) HoldDur() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hold
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
