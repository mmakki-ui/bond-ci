package main

import (
	"sync"
	"time"
)

// nowMS is the truncated monotonic-ish millisecond stamp the wire header
// carries. Identical to p4-bondagg/daemon/paths.go:13 so both ends truncate the
// same way and int32 differences stay valid across the 32-bit wrap.
func nowMS() uint32 { return uint32(time.Now().UnixMilli() & 0xFFFFFFFF) }

// OWD tracks per-link relative one-way delay from the frame txstamp. Ported
// from p4-bondagg/daemon/paths.go (the OWD type). "Relative" because the two
// clocks are not synchronised: the constant offset cancels in the cross-link
// SPREAD, which is the only thing the reorder horizon needs.
//
// Sized by MaxLinks, not by a configured N: a link starts being tracked the
// first time a frame carrying its pathID arrives, and links that never carry
// data never contribute (an uninitialised link must not pin the hold at max).
// ids is the discovered link set in first-seen order, so Hold costs O(N) on the
// per-frame path instead of O(MaxLinks) -- the pathID space is 256 wide but a
// deployment has a handful of links, and Hold runs on every arrival.
type OWD struct {
	mu   sync.Mutex
	rel  [MaxLinks]float64
	jit  [MaxLinks]float64
	init [MaxLinks]bool
	ids  []byte
}

// Sample folds one arrival: d = arrival - txstamp, EWMA for the level, EWMA of
// the absolute step for the jitter. Coefficients are the client's (0.9/0.1).
func (o *OWD) Sample(link byte, tsms uint32) {
	d := float64(int32(nowMS() - tsms))
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.init[link] {
		o.rel[link] = d
		o.init[link] = true
		o.ids = append(o.ids, link)
		return
	}
	prev := o.rel[link]
	o.rel[link] = prev*0.9 + d*0.1
	dev := d - prev
	if dev < 0 {
		dev = -dev
	}
	o.jit[link] = o.jit[link]*0.9 + dev*0.1
}

// Hold returns the reorder horizon: the cross-link OWD spread plus a jitter
// margin, clamped to [min, max].
//
// hold = clamp(spread + 3*jitter, min, max), where spread is max-min of the
// per-link relative OWD over the links that have actually delivered, and jitter
// is the max per-link jitter over the same set.
//
// The client's shipping formula (paths.go:74) adds +250ms on top of that. That
// term is the EIF PUSH estimator's probe-queue allowance; the pull datapath
// deleted the estimator (ADR-002), so it is deliberately NOT inherited here and
// what remains is pure cross-link geometry. The [min, max] clamp IS inherited
// verbatim from the client (main.go HoldMin/HoldMax) so both ends hold the same
// window by construction -- see the note on HoldMinDefault in main.go for the
// standing "no arbitrary constants" debt those two carry.
func (o *OWD) Hold(min, max time.Duration) time.Duration {
	o.mu.Lock()
	defer o.mu.Unlock()
	lo, hi, j := 0.0, 0.0, 0.0
	have := false
	for _, id := range o.ids {
		if !have || o.rel[id] < lo {
			lo = o.rel[id]
		}
		if !have || o.rel[id] > hi {
			hi = o.rel[id]
		}
		have = true
		if o.jit[id] > j {
			j = o.jit[id]
		}
	}
	if !have {
		return max
	}
	h := time.Duration(hi-lo+3*j) * time.Millisecond
	if h < min {
		h = min
	}
	if h > max {
		h = max
	}
	return h
}
