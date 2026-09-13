package main

import (
	"math"
	"testing"
	"time"
)

func approx(a, b, tol float64) bool { return math.Abs(a-b) <= tol }

// TestCapEstProbe: not-busy + near-full send rate -> probe Ĉ up 4%.
func TestCapEstProbe(t *testing.T) {
	c := NewCapEst(1000)
	c.Report(EstrSnap{qmeas: 0, delivRate: 0, sentRate: 900, jtEcho: 0}, true)
	if !approx(c.Chat(), 1040, 1.0) {
		t.Fatalf("probe: chat=%.2f want ~1040", c.Chat())
	}
}

// TestCapEstTrack: busy + evidence -> track toward delivered rate (0.7/0.3).
func TestCapEstTrack(t *testing.T) {
	c := NewCapEst(1000)
	c.Report(EstrSnap{qmeas: 100, delivRate: 800, sentRate: 900, jtEcho: 0}, true)
	if !approx(c.Chat(), 940, 1.0) {
		t.Fatalf("track: chat=%.2f want ~940", c.Chat())
	}
}

// TestCapEstRegen: not-busy, no send, starved -> regen toward prior/cmax.
func TestCapEstRegen(t *testing.T) {
	c := NewCapEst(1000)
	c.chat = 100 // starved below prior
	c.Report(EstrSnap{qmeas: 0, delivRate: 0, sentRate: 0, jtEcho: 0}, true)
	if c.Chat() <= 100 || c.Chat() >= 1000 {
		t.Fatalf("regen: chat=%.2f want (100,1000)", c.Chat())
	}
}

// TestCapEstFloorClamp: Ĉ never falls below prior*0.10.
func TestCapEstFloorClamp(t *testing.T) {
	c := NewCapEst(1000)
	c.chat = 10
	c.Report(EstrSnap{qmeas: 50, delivRate: 5, sentRate: 5, jtEcho: 0}, true) // busy+evid -> track toward 5
	if c.Chat() < 1000*0.10-0.001 {
		t.Fatalf("floor clamp: chat=%.2f want >= 100", c.Chat())
	}
}

// TestCapEstV4FoldGuard (#2): a DRAINED-pipe hangover window -- busy only via the
// stale qs_cap EWMA (not a deep standing queue NOW) with a LOW delivered rate --
// must NOT fold chat down. The pre-v4 port folded unconditionally on busy&&evid,
// dragging chat ~30% below truth for ~1.5s. With the guard (deep || deliv>=0.85*
// chat), a non-deep low-deliv window HOLDs.
func TestCapEstV4FoldGuard(t *testing.T) {
	c := NewCapEst(2000)
	c.chat = 2000
	// Warm qs_cap ABOVE the gate (15ms) without a deep spike (deep needs qmeas >
	// 2*gate = 30ms). qmeas=25ms: not deep, but repeated folds lift qs_cap>15.
	for i := 0; i < 60; i++ {
		c.Report(EstrSnap{qmeas: 25, delivRate: 2000, sentRate: 2000, jtEcho: 0}, true)
	}
	before := c.Chat()
	// Now the pipe DRAINS: qs_cap is still high (busy=true via history) but the
	// queue is not deep NOW (qmeas=25 < 30) and delivered collapses to idle
	// throughput (389, the measured N2 hangover value) << 0.85*chat. Must HOLD.
	c.Report(EstrSnap{qmeas: 25, delivRate: 389, sentRate: 389, jtEcho: 0}, true)
	if c.Chat() < before-1.0 {
		t.Fatalf("v4 fold-guard: drained-pipe hangover dragged chat %.1f -> %.1f (want HOLD)", before, c.Chat())
	}
}

// TestCapEstPongLossHold (#3): a report with no fresh pong (heard=false) must not
// fold chat, even when busy+evid+deep would otherwise trigger a capacity track.
// A pong-less window carries no new delivered surface. Chosen so that heard=true
// WOULD fold (deep queue, evid via sentRate) -- isolating the heard gate itself.
func TestCapEstPongLossHold(t *testing.T) {
	c := NewCapEst(1000)
	c.chat = 1000
	// deep standing queue (qmeas 100 > 2*15 gate) + evid (sentRate>0): with a
	// fresh pong this folds chat toward delivRate=100 (->730). heard=false HOLDs.
	c.Report(EstrSnap{qmeas: 100, delivRate: 100, sentRate: 500, jtEcho: 0}, false)
	if !approx(c.Chat(), 1000, 0.001) {
		t.Fatalf("pong-loss hold: chat=%.2f want 1000 (no fold on !heard)", c.Chat())
	}
	// sanity: the SAME surface WITH a fresh pong does fold it down (guard is deep).
	c.Report(EstrSnap{qmeas: 100, delivRate: 100, sentRate: 500, jtEcho: 0}, true)
	if c.Chat() >= 1000 {
		t.Fatalf("pong-loss hold: heard=true should fold chat below 1000, got %.2f", c.Chat())
	}
}

// TestEstrReportPongLoss (#3): Estr.Report with no pong this window must KEEP the
// last delivRate, not recompute a 0-diff from the unchanged delivered counter.
func TestEstrReportPongLoss(t *testing.T) {
	e := NewEstr()
	now := time.Now()
	// window 1: a pong lands with cumulative delivered = 100 units (256B each).
	e.OnPong(now, 10, 0, 0, 100)
	s1, h1 := e.Report(now)
	if !h1 || s1.delivRate <= 0 {
		t.Fatalf("window1: heard=%v delivRate=%.1f want heard + >0", h1, s1.delivRate)
	}
	// window 2: NO pong (delivUnits unchanged at 100). Must keep the stale rate,
	// NOT recompute delivRate=0 from the 0-diff.
	s2, h2 := e.Report(now)
	if h2 {
		t.Fatalf("window2: heard=true, expected no fresh pong")
	}
	if s2.delivRate != s1.delivRate {
		t.Fatalf("window2: delivRate=%.1f want stale %.1f (pong-less window zeroed it)", s2.delivRate, s1.delivRate)
	}
}

// TestCapEstTierFeedforward: Ĉ scales by (1-OH_new)/(1-OH_old) on a tier change.
func TestCapEstTierFeedforward(t *testing.T) {
	c := NewCapEst(1000)
	c.OnTierChange(0, 20) // *(1-0.05)/(1-0) = 0.95
	if !approx(c.Chat(), 950, 0.5) {
		t.Fatalf("feedforward: chat=%.2f want ~950", c.Chat())
	}
}

// TestCapEstCollapse: on_collapse only LOWERS Ĉ to the post-cut rate.
func TestCapEstCollapse(t *testing.T) {
	c := NewCapEst(1000)
	c.OnCollapse(400)
	if !approx(c.Chat(), 400, 0.5) {
		t.Fatalf("collapse cut: chat=%.2f want ~400", c.Chat())
	}
	c.OnCollapse(2000) // higher rate must not raise it
	if !approx(c.Chat(), 400, 0.5) {
		t.Fatalf("collapse must only lower: chat=%.2f want ~400", c.Chat())
	}
}

// TestSmithFallback: chat ~ 0 -> QMAX_MS.
func TestSmithFallback(t *testing.T) {
	e := NewEstr()
	if got := e.SmithQhatMs(time.Now(), 0); got != QMAX_MS {
		t.Fatalf("smith fallback: got %.1f want %.1f", got, QMAX_MS)
	}
}

// TestSmithBacklog: a fresh pong with qmeas -> q̂ ~ qmeas (no sends, no drain).
func TestSmithBacklog(t *testing.T) {
	e := NewEstr()
	now := time.Now()
	e.OnPong(now, 150.0, 0, 0, 0) // qmeas = 150ms
	got := e.SmithQhatMs(now, 1000)
	if !approx(got, 150, 5) {
		t.Fatalf("smith backlog: got %.1f want ~150", got)
	}
}
