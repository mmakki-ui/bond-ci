package main

import (
	"sync"
	"time"
)

// ---- per-path loss meter (reorder-tolerant, ring-skip semantics) ----------
// Per-path frame-loss %, from GENUINE gaps in the contiguous per-path fseq
// stream. It is the daemon's ONLY per-path loss signal, folded into sLossE at
// the LossIval epoch by pullrun.go:295-297.
//
// PROVENANCE (U128). This file was fec.go's tail. ADR-002 drops FEC and U128
// deleted the rest of fec.go, so the conditional this meter used to carry --
// "used ONLY at K=0, because once FEC is armed the echo comes from the
// FEC-group ledger frx.TakeRaw instead" -- no longer has a second branch: there
// is no FecRx and no parity. What is left is the K=0 branch of
// nsched_model.py's _fec_report, wSkip/(wDel+wSkip), i.e. the RING's skip
// accounting (ring.go), running unconditionally. The push tree that carried the
// other branch is preserved at tag `eif-push-reference`.
//
// Congestion taildrops DO count as loss; but REORDER does NOT. A frame that
// merely arrives LATE (path jitter, or a collapsing path draining its queue) is
// out of order, not lost: it fills its gap and is counted DELIVERED. A frontier
// gap is declared LOST only once it has blocked for longer than `hold` -- the
// ring's owd-adaptive reorder horizon (paths.go owd.Hold). This is TIME-based,
// mirroring ring.go's O(1) blockN/blockAt gap timer, and is the fix for the
// earlier frame-COUNT grace: a fixed frame grace scales its detection lag
// INVERSELY with per-path pps, so a lightly-loaded path reacted far too late
// (the S6 regression); a time horizon does not.
//
// (History: the original meter differenced maxF over a fixed 500ms window and
// counted every still-in-flight reordered frame as loss, with a lost<0 clamp
// that blocked the next window's late arrival from refunding it -> a persistent
// positive loss bias under jitter/collapse-drain reorder that spuriously armed
// and corrupted the peerloss echo. This held-gap timer removes that.)
type LossMeter struct {
	mu       sync.Mutex
	next     uint32 // lowest fseq not yet resolved (delivered or lost)
	haveNext bool
	maxF     uint32 // highest fseq observed on this path
	haveMax  bool
	seen     map[uint32]struct{} // arrived fseqs >= next awaiting contiguity
	blockOn  bool                // a frontier gap is currently being timed
	blockN   uint32              // the fseq of that gap
	blockAt  time.Time           // when it was first observed
	deliv    int                 // frames resolved-delivered this window
	lost     int                 // frames declared genuinely-lost this window
}

// Data registers a received per-path DATA fseq at time `now`; `hold` is the
// current owd-adaptive reorder horizon (the same value fed to ring.Hold).
// Out-of-order frames fill their gap and count delivered; a frontier gap is
// counted lost only after it has blocked > hold.
func (m *LossMeter) Data(fseq uint32, now time.Time, hold time.Duration) {
	m.mu.Lock()
	if !m.haveNext {
		m.next, m.haveNext = fseq, true
	}
	if !m.haveMax || int32(fseq-m.maxF) > 0 {
		m.maxF, m.haveMax = fseq, true
	}
	if int32(fseq-m.next) < 0 {
		m.mu.Unlock()
		return // already resolved (late dup / already-skipped): ignore
	}
	if m.seen == nil {
		m.seen = make(map[uint32]struct{})
	}
	m.seen[fseq] = struct{}{}
	m.drain(now, hold)
	m.mu.Unlock()
}

// drain (m.mu held) advances the contiguous frontier: it delivers buffered
// fseqs in order, and skips a frontier gap -- only when there is newer evidence
// (maxF past it) AND it has blocked longer than hold -- batching the whole
// overdue run up to the next buffered arrival (ring.go overdue-epoch parity).
func (m *LossMeter) drain(now time.Time, hold time.Duration) {
	for m.haveNext {
		if _, ok := m.seen[m.next]; ok {
			delete(m.seen, m.next)
			m.deliv++
			m.next++
			m.blockOn = false
			continue
		}
		if !m.haveMax || int32(m.maxF-m.next) <= 0 {
			return // no newer evidence yet: next is not proven behind
		}
		if !m.blockOn || m.blockN != m.next {
			m.blockOn, m.blockN, m.blockAt = true, m.next, now
			return
		}
		if now.Sub(m.blockAt) <= hold {
			return // still inside the reorder horizon: wait for a late arrival
		}
		// overdue: skip the run of genuinely-missing fseqs up to the next
		// buffered arrival (maxF is always buffered, so this terminates).
		for int32(m.maxF-m.next) > 0 {
			if _, ok := m.seen[m.next]; ok {
				break
			}
			m.lost++
			m.next++
		}
		m.blockOn = false
	}
}

// Window (loss epoch, at time `now` with horizon `hold`) drains overdue gaps
// and returns the window's genuine-loss count and resolved-total (delivered +
// genuinely-lost), then resets them. The caller folds lost/total into the
// SINGLE per-path loss EWMA (pullrun.go sLossE) -- the K=0 branch of
// nsched_model.py _fec_report, the exact analogue of the ring-skip fallback
// wSkip/(wDel+wSkip). Deliberately no internal EWMA: the smoothing lives in
// sLossE at the caller, which is where the epoch (LossIval) is.
func (m *LossMeter) Window(now time.Time, hold time.Duration) (lost, total int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.drain(now, hold)
	lost, total = m.lost, m.deliv+m.lost
	m.deliv, m.lost = 0, 0
	return
}
