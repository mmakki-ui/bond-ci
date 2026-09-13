package main

import (
	"sync"
	"time"
)

// =============================================================================
// CapEst + Estr -- the SENDER-side capacity estimator (nsched PART 3/4).
//
// Split from the AIMD controller (Sched.rateKb): CapEst.chat (Ĉ) is a busy-gated
// delivered-rate EWMA, NOT the controller rate (naive CapEst=rate OSCILLATES).
// The scheduler reads chat for the ETA; the AIMD stays the congestion actor and
// is untouched by this file.
//
// Estr is the lagged measurable surface the daemon builds from the REAL pong
// stream (the emulator synthesizes the lag; here it is physical): the peer
// echoes qb (q_meas), od (anchored owd delta), jt (jitQF) and a per-path
// DATA-delivered byte counter; the sender keeps its own sent-byte counter and
// dead-reckons the stale peer queue forward with the Smith predictor.
// =============================================================================

const (
	QMAX_MS         = 300.0         // per-path tail-drop bound; Smith fallback
	BP_MS           = 0.9 * QMAX_MS // EIF backpressure txdrop threshold (270ms)
	CapReport       = 0.100         // CapEst report cadence (s) = PingIval
	SilenceInflate  = 0.400         // control silence -> pessimistic q̂ inflation (s)
	SilenceDiscount = 0.60          // drain-credit withheld past the threshold
	PongQuantumKb   = 2.048         // delivered-counter byte-quantum (256B) in kb
	CapRegen        = 0.02          // Ĉ regen rate/report toward last-confirmed cap
	EifBeta         = 0.5           // β (nsched JITK): prices per-path jitter into the ETA
)

func ohK(k int) float64 { // parity overhead 1/K (nsched OH)
	if k == 0 {
		return 0.0
	}
	return 1.0 / float64(k)
}

// ---- Estr: per-path lagged measurement surface (sender side) ----------------
type Estr struct {
	mu   sync.Mutex
	born time.Time

	// sender-side counters (own, no lag). Bytes = DATA + PARITY on the path.
	sentBytes   uint64  // cumulative bytes put on path -> run_sent
	sentPrevWin uint64  // sentBytes one CAP_REPORT ago
	sentRate    float64 // kb/s

	// peer-echoed DATA-delivered surface (arrival-bucketed, 256B-quantized)
	delivUnits   uint16  // last echoed cumulative delivered (256B units)
	delivPrevWin uint16  // value one window ago
	delivRate    float64 // kb/s

	// lagged snapshot taken at each pong receipt
	qmeas      float64 // ms == raw qb*4 (NOT Sched.qEwma)
	owdD       float64 // ms  anchored floor-delta echo (od*2)
	jtEcho     float64 // ms  jitQF echo (jt)
	tMeas      float64 // s   seconds-since-born of the last measurement
	sentAtMeas uint64  // bytes cumulative sent as of the measurement
	tPong      float64 // s   last pong RECEIPT (drives control silence)
	gotPong    bool
	heardSince bool    // a fresh pong arrived since the last Report
	silence    float64 // s
}

func NewEstr() *Estr { return &Estr{born: time.Now()} }

func (e *Estr) secs(now time.Time) float64 { return now.Sub(e.born).Seconds() }

// OnSend: a frame of `bytes` (DATA or PARITY) was put on this path. Feeds
// run_sent (Smith sent-window, INCLUDES parity) and sent_rate.
func (e *Estr) OnSend(bytes int) {
	e.mu.Lock()
	e.sentBytes += uint64(bytes)
	e.mu.Unlock()
}

// OnPong: snapshot the lagged surface from a fresh pong. qbMs/odMs/jtMs are the
// de-quantized echoes; delivUnits is the peer's cumulative DATA-delivered count.
func (e *Estr) OnPong(now time.Time, qbMs, odMs, jtMs float64, delivUnits uint16) {
	e.mu.Lock()
	e.qmeas = qbMs
	e.owdD = odMs
	e.jtEcho = jtMs
	e.delivUnits = delivUnits
	e.tMeas = e.secs(now)
	e.sentAtMeas = e.sentBytes
	e.tPong = e.secs(now)
	e.gotPong = true
	e.heardSince = true
	e.mu.Unlock()
}

// EstrSnap is the surface CapEst.Report consumes (value copy, no shared lock).
type EstrSnap struct {
	qmeas, delivRate, sentRate, jtEcho float64
}

// Report recomputes sent_rate / deliv_rate / silence over the last CAP_REPORT
// and returns the CapEst surface snapshot + whether a fresh pong was heard.
// nsched Estr.report L689-754 (sender half; the floor/jit fold is receiver-side).
func (e *Estr) Report(now time.Time) (EstrSnap, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	heard := e.heardSince
	e.heardSince = false
	// sent_rate: own counter, no lag -- valid every window regardless of pong.
	e.sentRate = float64(e.sentBytes-e.sentPrevWin) * 8.0 / 1000.0 / CapReport
	e.sentPrevWin = e.sentBytes
	// deliv_rate: only a window with a FRESH pong carries a new delivered-count.
	// A lost/jittered pong delivers NO fresh surface (delivUnits unchanged), so a
	// cumulative diff would be a spurious 0 that folds chat down ~30%/window (#3).
	// Mirror the model (nsched Estr.report L696-701): KEEP the stale delivRate and
	// do NOT advance delivPrevWin, so the next real pong's diff spans the gap.
	if heard {
		dUnits := e.delivUnits - e.delivPrevWin // uint16 subtraction wraps naturally
		e.delivPrevWin = e.delivUnits
		e.delivRate = float64(dUnits) * PongQuantumKb / CapReport
	}
	// control silence = seconds since last pong RECEIPT (not measurement age).
	nowS := e.secs(now)
	if e.gotPong {
		e.silence = nowS - e.tPong
	} else {
		e.silence = nowS + 1.0
	}
	return EstrSnap{qmeas: e.qmeas, delivRate: e.delivRate, sentRate: e.sentRate, jtEcho: e.jtEcho}, heard
}

// smithLocked: the Smith math, assumes e.mu held. nsched Estr.smith_qhat_ms.
func (e *Estr) smithLocked(nowS, chat float64) float64 {
	if chat <= 1e-6 {
		return QMAX_MS
	}
	backlogMeas := e.qmeas / 1000.0 * chat                      // kb at t_meas
	sentWin := float64(e.sentBytes-e.sentAtMeas) * 8.0 / 1000.0 // kb since (incl parity)
	elapsed := nowS - e.tMeas
	if elapsed < 0 {
		elapsed = 0
	}
	drained := chat * elapsed
	sil := 0.0
	if e.gotPong {
		sil = nowS - e.tPong
	}
	if sil > SilenceInflate {
		excess := sil - SilenceInflate
		drained -= chat * excess * SilenceDiscount
	}
	qhatKb := backlogMeas + sentWin - drained
	if qhatKb < 0 {
		qhatKb = 0
	}
	return qhatKb / chat * 1000.0
}

// SmithQhatMs: dead-reckon the stale peer queue forward by our sends. On control
// silence > SILENCE_INFLATE withhold part of the drain credit so q̂ inflates
// pessimistically (loop backs off rather than assume unconfirmed drainage).
func (e *Estr) SmithQhatMs(now time.Time, chat float64) float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.smithLocked(e.secs(now), chat)
}

// EtaTerms returns (q̂, owdD, jtEcho) in one lock, for the ETA argmin.
func (e *Estr) EtaTerms(now time.Time, chat float64) (qhat, owdD, jtEcho float64) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.smithLocked(e.secs(now), chat), e.owdD, e.jtEcho
}

// OwdD returns the last anchored owd-delta echo (ms) -- promotion tiebreak.
func (e *Estr) OwdD() float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.owdD
}

// ---- CapEst: busy-gated delivered-rate EWMA (Ĉ != controller) ---------------
type CapEst struct {
	mu    sync.Mutex
	prior float64 // per-path capacity prior (kb/s) = floorKb
	chat  float64 // Ĉ, the estimate. init = prior
	K     int     // last-seen FEC tier
	qsCap float64 // smoothed quantized qmeas echo
	cmax  float64 // decaying high-water of CONFIRMED (busy-tracked) cap
}

func NewCapEst(prior float64) *CapEst { return &CapEst{prior: prior, chat: prior} }

func (c *CapEst) Chat() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.chat
}

// Report: busy-gated delivered-rate track + probe + recovery (evidence gate,
// blip-robust busy, regen). ALL Estr-surface + prior only (no rateKb/capHint/
// role state -> the CapEst != controller separation is preserved).
// nsched CapEst.report L789-814.
func (c *CapEst) Report(e EstrSnap, heard bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.qsCap = 0.9*c.qsCap + 0.1*e.qmeas
	gate := QF_GATE_MS + e.jtEcho    // 15 + jitQF echo
	deep := e.qmeas > 2.0*gate       // a deeply STANDING backlog right now
	busy := deep || (c.qsCap > gate) // deep spike OR sustained (EWMA history)
	evid := (e.delivRate > 0.0) || (e.sentRate > 0.0)
	switch {
	case busy && evid:
		// v4 fold-guard (#2, nsched CapEst.report L804-816, commit 7a11e10):
		// a busy fold takes delivRate as a CAPACITY sample -- valid only if the
		// pipe was full at the measured horizon. When busy is only the qs_cap EWMA
		// (history) the pipe may have DRAINED, so delivRate is idle throughput and
		// folding it drags chat ~30% below truth (drained-pipe hangover). Fold ONLY
		// when the queue is deeply standing NOW (deep) OR delivRate is capacity-
		// plausible (>=0.85*chat). Plus (#3) require a fresh pong: a stale delivRate
		// from a pong-less window is not a new capacity sample -> HOLD.
		if heard && (deep || e.delivRate >= 0.85*c.chat) {
			c.chat = 0.7*c.chat + 0.3*e.delivRate // capacity track
			if c.cmax*0.999 > c.chat {
				c.cmax = c.cmax * 0.999 // confirmed high-water (decays)
			} else {
				c.cmax = c.chat
			}
		}
	case !busy && e.sentRate >= 0.85*c.chat:
		c.chat *= 1.04 // probe up
	case !busy: // idle + starved -> regen toward last confirmed cap
		tgt := c.prior
		if c.cmax > 0.0 {
			tgt = c.cmax
		}
		if c.chat < tgt {
			c.chat += CapRegen * (tgt - c.chat)
		}
	}
	// busy-but-no-evidence (parked with stale-high qmeas) -> HOLD (no crash)
	if c.chat < c.prior*0.10 {
		c.chat = c.prior * 0.10
	}
	if c.chat > CeilKb {
		c.chat = CeilKb
	}
}

// OnTierChange: FEC feedforward -- Ĉ is data-goodput, so when parity overhead
// changes the goodput ceiling moves immediately. nsched CapEst.on_tier_change.
func (c *CapEst) OnTierChange(kOld, kNew int) {
	c.mu.Lock()
	c.chat *= (1.0 - ohK(kNew)) / (1.0 - ohK(kOld))
	c.K = kNew
	c.mu.Unlock()
}

// OnCollapse: SPIKE/DRAIN cut -- only ever LOWERS chat to the post-cut
// controller rate (floored at prior*0.10). nsched CapEst.on_collapse.
func (c *CapEst) OnCollapse(ctlRate float64) {
	c.mu.Lock()
	lo := c.prior * 0.10
	target := ctlRate
	if lo > target {
		target = lo
	}
	if target < c.chat {
		c.chat = target
	}
	c.mu.Unlock()
}
