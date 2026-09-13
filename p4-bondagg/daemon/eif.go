package main

import (
	"math"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// =============================================================================
// EIF scheduler (nsched NSim scheduling + control-plane FSM).
//
// Replaces the token bucket. Per-frame send decision = argmin_i ETA_i over paths
// that are alive AND ACTIVE, with backpressure txdrop when the winner's q̂ > BP_MS:
//   ETA_i = q̂_i(Smith) + L/C_eff_i + owd_i + β·jit_i
// owd_i = anchored floor-delta echo (offset-free, D3); jit_i = jitQF echo; C_eff
// = Ĉ (CapEst); β = EifBeta.  A control-plane FSM (roles ACTIVE/STANDBY/DEAD,
// activation EMA, deactivation dwell, primary re-rank) decides which paths are
// eligible so lightly-loaded links spin up only when demand spills.
// nsched _eif_pick L1015-1027, _eta L990-1013, _control L1156-1222.
// =============================================================================

const (
	roleStandby = 0
	roleActive  = 1
	roleDead    = 2

	actTau     = 1.00 // activation EMA time constant (~1s)
	thetaOn    = 0.30 // activation spill-demand threshold
	deactDwell = 2.00 // deactivate min-dwell + share window (s)
	rerankSusS = 3.00 // primary re-rank sustain (s)
	rerankMs   = 10.0 // re-rank absolute margin (ms)
	rerankFrac = 0.20 // re-rank relative margin

	nominalFrameBytes = 1224 // FSM ETA L/C reference frame (nsched PKT_KB=9.79kb)
	deactWindows      = 20   // int(DEACT_DWELL / CAP_REPORT)
)

type EIF struct {
	mu   sync.Mutex
	n    int
	born time.Time
	est  []*Estr
	ce   []*CapEst
	kA   []int32 // per-path FEC tier (atomic); read in ETA for OH

	alive []bool // detected liveness (pong-age gated), set from the ping loop
	role  []int  // ACTIVE / STANDBY / DEAD
	prim  int    // primary path index

	actEma      float64
	actTime     []float64 // s, activation time per path (deactivation dwell)
	rerankSince float64   // s, -1 = none
	rerankCand  int       // -1 = none

	winAssign []int       // per-report assignment counts (share bookkeeping)
	shareWin  [][]float64 // bounded ring of per-report shares (deactivation)

	activations, roleChanges int
	txdrops                  uint64
}

func NewEIF(est []*Estr, ce []*CapEst, prim int) *EIF {
	n := len(est)
	e := &EIF{
		n: n, born: time.Now(), est: est, ce: ce,
		kA: make([]int32, n), alive: make([]bool, n), role: make([]int, n),
		actTime: make([]float64, n), winAssign: make([]int, n),
		rerankSince: -1, rerankCand: -1, prim: prim,
	}
	for i := 0; i < n; i++ {
		e.alive[i] = true
		e.role[i] = roleStandby
	}
	if prim >= 0 && prim < n {
		e.role[prim] = roleActive
	}
	return e
}

func (e *EIF) secs(now time.Time) float64 { return now.Sub(e.born).Seconds() }

// SetAlive records detected liveness for path p (pong-age gated, from the ping
// loop). Kept separate from role so a revived path returns to STANDBY.
func (e *EIF) SetAlive(p int, a bool) {
	e.mu.Lock()
	if p >= 0 && p < e.n {
		e.alive[p] = a
	}
	e.mu.Unlock()
}

// SetK records the per-path FEC tier (atomic) so the ETA's OH term stays current
// without reaching across the FEC lock.
func (e *EIF) SetK(p, k int) {
	if p >= 0 && p < e.n {
		atomic.StoreInt32(&e.kA[p], int32(k))
	}
}
func (e *EIF) kOf(p int) int { return int(atomic.LoadInt32(&e.kA[p])) }

// OnTierChange applies the CapEst FEC feedforward + records the tier. Called at
// the tier-step / collapse sites; does NOT take e.mu (avoids the sched.mu ->
// eif.mu edge on the collapse path).
func (e *EIF) OnTierChange(p, kOld, kNew int) {
	if p < 0 || p >= e.n {
		return
	}
	e.ce[p].OnTierChange(kOld, kNew)
	e.SetK(p, kNew)
}

// eta computes (ETA ms, q̂ ms) for path p. active prices C_eff at Ĉ; a standby
// path prices the tier (C_eff = Ĉ*(1-OH)). Caller holds e.mu.
func (e *EIF) eta(p int, now time.Time, active bool, nBytes int) (float64, float64) {
	chat := e.ce[p].Chat()
	if chat < 1.0 {
		chat = 1.0
	}
	qhat, owdD, jt := e.est[p].EtaTerms(now, chat)
	oh := ohK(e.kOf(p))
	cEff := chat
	if !active {
		cEff = chat * (1.0 - oh)
	}
	if cEff < 1.0 {
		cEff = 1.0
	}
	eta := qhat + float64(nBytes)*8.0/cEff + owdD + EifBeta*jt
	return eta, qhat
}

// Pick: EIF send decision for a frame of nBytes. Returns the winning path index,
// or -1 to txdrop (no eligible path OR backpressure). nsched _eif_pick.
func (e *EIF) Pick(nBytes int) int {
	now := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	best := -1
	var bestEta, bestQhat float64
	for i := 0; i < e.n; i++ {
		if !e.alive[i] || e.role[i] != roleActive {
			continue
		}
		eta, qhat := e.eta(i, now, true, nBytes)
		if best < 0 || eta < bestEta-1e-9 {
			bestEta = eta
			best = i
			bestQhat = qhat
		}
	}
	if best < 0 {
		atomic.AddUint64(&e.txdrops, 1)
		return -1 // no eligible path
	}
	if bestQhat > BP_MS {
		atomic.AddUint64(&e.txdrops, 1)
		return -1 // backpressure txdrop
	}
	e.winAssign[best]++
	return best
}

func (e *EIF) TxDrops() uint64 { return atomic.LoadUint64(&e.txdrops) }

// AdmitParity gates a per-path parity frame (R2, fec-port-findings.md): parity
// rides its group's own path and is DROPPED when that path is backpressured
// (q̂ > BP_MS) or dead -- so raising K can't add offered load beyond the CC
// allowance (the RFC 9265 MUST). Was: parity forced out via a fallback path.
func (e *EIF) AdmitParity(p, nBytes int) bool {
	now := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	if p < 0 || p >= e.n || !e.alive[p] {
		return false
	}
	_, qhat := e.eta(p, now, true, nBytes)
	return qhat <= BP_MS
}

// Backup returns the best-ETA alive path != p for the suspect-window duplicate
// (D2, N-way), or -1 if none. The dup is a full data frame on that path.
func (e *EIF) Backup(p, nBytes int) int {
	now := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	best := -1
	var bestEta float64
	for i := 0; i < e.n; i++ {
		if i == p || !e.alive[i] {
			continue
		}
		eta, _ := e.eta(i, now, true, nBytes)
		if best < 0 || eta < bestEta {
			bestEta = eta
			best = i
		}
	}
	return best
}

// Prim returns the current primary path index (STAT logging).
func (e *EIF) Prim() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.prim
}

// Control runs the 100ms control-plane FSM (roles / activation / deactivation /
// re-rank). Called from the ping loop after CapEst.Report. nsched _control.
func (e *EIF) Control(now time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	nowS := e.secs(now)

	// window share bookkeeping (from this report's assignments)
	tot := 0
	for i := 0; i < e.n; i++ {
		tot += e.winAssign[i]
	}
	if tot == 0 {
		tot = 1
	}
	share := make([]float64, e.n)
	for i := 0; i < e.n; i++ {
		share[i] = float64(e.winAssign[i]) / float64(tot)
		e.winAssign[i] = 0
	}
	e.shareWin = append(e.shareWin, share)
	if len(e.shareWin) > deactWindows+2 {
		e.shareWin = e.shareWin[len(e.shareWin)-(deactWindows+2):]
	}

	// DEAD handling: a dead path -> ineligible; revive -> STANDBY.
	for i := 0; i < e.n; i++ {
		if !e.alive[i] {
			if e.role[i] != roleDead {
				e.role[i] = roleDead
				if i == e.prim {
					e.promotePrimary(now)
				}
			}
		} else if e.role[i] == roleDead {
			e.role[i] = roleStandby
		}
	}

	// activation: shadow the cheapest STANDBY ETA against the cheapest ACTIVE ETA.
	haveAct, haveSb := false, false
	var actMin, sbMin float64
	sbI := -1
	for i := 0; i < e.n; i++ {
		if !e.alive[i] {
			continue
		}
		if e.role[i] == roleActive {
			eta, _ := e.eta(i, now, true, nominalFrameBytes)
			if !haveAct || eta < actMin {
				actMin = eta
				haveAct = true
			}
		} else if e.role[i] == roleStandby {
			eta, _ := e.eta(i, now, false, nominalFrameBytes)
			if !haveSb || eta < sbMin {
				sbMin = eta
				sbI = i
				haveSb = true
			}
		}
	}
	sig := 0.0
	if haveAct && haveSb && sbMin < actMin {
		sig = 1.0
	}
	a := math.Exp(-CapReport / actTau)
	e.actEma = e.actEma*a + sig*(1.0-a)
	if e.actEma > thetaOn && sbI >= 0 {
		e.role[sbI] = roleActive
		e.actTime[sbI] = nowS
		e.activations++
		e.actEma = 0.0
	}

	// deactivation: a non-primary ACTIVE path whose share stayed <2% over the
	// dwell, while the primary q̂ is low, drops back to STANDBY.
	primQhat := 0.0
	if e.role[e.prim] == roleActive {
		_, primQhat = e.eta(e.prim, now, true, nominalFrameBytes)
	}
	if len(e.shareWin) >= deactWindows {
		recent := e.shareWin[len(e.shareWin)-deactWindows:]
		for i := 0; i < e.n; i++ {
			if e.role[i] != roleActive || i == e.prim {
				continue
			}
			sh := 0.0
			for _, w := range recent {
				sh += w[i]
			}
			sh /= float64(len(recent))
			if sh < 0.02 && primQhat < 20.0 && (nowS-e.actTime[i]) > deactDwell {
				e.role[i] = roleStandby
			}
		}
	}

	e.rerank(now, nowS)

	// #1: recover from the all-paths-dead deadlock. If ALL N paths go DEAD at once
	// (age > DeadIval) then revive, the DEAD-handling loop returns every path to
	// STANDBY -- but activation needs an EXISTING ACTIVE path to shadow standby
	// ETAs against, so with zero ACTIVE the EMA never fires and Pick returns -1
	// every frame (100% txdrop until restart). If no alive path is ACTIVE yet at
	// least one is alive, promote the best alive path now (promotePrimary's
	// standby-fallback branch activates the cheapest alive path by owdD). Mirrors
	// the parallel model _control fix.
	haveActiveAlive, haveAlive := false, false
	for i := 0; i < e.n; i++ {
		if !e.alive[i] {
			continue
		}
		haveAlive = true
		if e.role[i] == roleActive {
			haveActiveAlive = true
		}
	}
	if haveAlive && !haveActiveAlive {
		e.promotePrimary(now)
	}
}

// rerank promotes a challenger primary once its active cost stays below the
// incumbent's by the margin for RERANK_SUS. nsched _rerank.
func (e *EIF) rerank(now time.Time, nowS float64) {
	if e.role[e.prim] != roleActive {
		return
	}
	primEta, _ := e.eta(e.prim, now, true, nominalFrameBytes)
	cand := -1
	var candEta float64
	for i := 0; i < e.n; i++ {
		if i == e.prim || e.role[i] != roleActive || !e.alive[i] {
			continue
		}
		eta, _ := e.eta(i, now, true, nominalFrameBytes)
		if cand < 0 || eta < candEta {
			candEta = eta
			cand = i
		}
	}
	if cand < 0 {
		e.rerankSince = -1
		e.rerankCand = -1
		return
	}
	margin := rerankMs
	if rerankFrac*primEta > margin {
		margin = rerankFrac * primEta
	}
	if candEta < primEta-margin {
		if e.rerankCand == cand && e.rerankSince >= 0 {
			if nowS-e.rerankSince >= rerankSusS {
				e.prim = cand
				e.roleChanges++
				e.rerankSince = -1
				e.rerankCand = -1
			}
		} else {
			e.rerankCand = cand
			e.rerankSince = nowS
		}
	} else {
		e.rerankSince = -1
		e.rerankCand = -1
	}
}

// promotePrimary picks the cheapest ACTIVE alive path as the new primary; if none
// is active, it activates the cheapest alive standby (owdD tiebreak). Caller holds
// e.mu. nsched _promote_primary.
func (e *EIF) promotePrimary(now time.Time) {
	cand := -1
	var candEta float64
	for i := 0; i < e.n; i++ {
		if e.role[i] == roleActive && e.alive[i] {
			eta, _ := e.eta(i, now, true, nominalFrameBytes)
			if cand < 0 || eta < candEta {
				candEta = eta
				cand = i
			}
		}
	}
	if cand < 0 { // nobody active: activate cheapest alive standby by owdD
		order := make([]int, 0, e.n)
		for i := 0; i < e.n; i++ {
			order = append(order, i)
		}
		sort.SliceStable(order, func(a, b int) bool {
			return e.est[order[a]].OwdD() < e.est[order[b]].OwdD()
		})
		for _, i := range order {
			if e.alive[i] {
				e.role[i] = roleActive
				e.actTime[i] = e.secs(now)
				e.activations++
				cand = i
				break
			}
		}
	}
	if cand >= 0 && cand != e.prim {
		e.prim = cand
		e.roleChanges++
	}
}
