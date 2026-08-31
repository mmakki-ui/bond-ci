package main

import (
	"testing"
	"time"
)

// primeSched builds a Sched wound past warmup+grace with a fixed, injectable
// clock, holding path 0 in a settled high-queue state: qEwma above BigQMs, and
// hqCnt one below PinDrainN so the next pinned report tips it over. rate ==
// capHint, so the collapse gate's first two disjuncts (capHint==0 and
// rate<capHint*0.6) are BOTH false — the gate can only open via the pinDrain
// disjunct (hqCnt>=PinDrainN). That isolates exactly the pinDrain wiring at
// whichever gate site the following report reaches. bigAgo is how stale the
// last big cut is, which selects DRAIN (>800ms) vs the cad walk.
func primeSched(base time.Time, bigAgo time.Duration) *Sched {
	const n = 2
	s := &Sched{
		rateKb:    []float64{1000, 1000},
		floorKb:   []float64{2000, 2000},
		capHint:   []float64{1000, 1000},
		qEwma:     make([]float64, n),
		qInit:     make([]bool, n),
		lastDec:   make([]time.Time, n),
		lastBig:   make([]time.Time, n),
		hqCnt:     make([]int, n),
		reLearn:   make([]bool, n),
		dirtyRep:  make([]int, n),
		warmed:    make([]bool, n),
		graceLeft: make([]int, n),
		spCnt:     make([]int, n),
		qJit:      make([]float64, n),
		prevQ:     make([]float64, n),
		lastPong:  make([]time.Time, n),
		born:      base.Add(-10 * time.Second), // long past the 1.5s warmup
		now:       func() time.Time { return base },
	}
	s.qInit[0] = true
	s.warmed[0] = true
	s.graceLeft[0] = 0
	s.qEwma[0] = 400 // > BigQMs (200); prev is also 400 so SPIKE cannot arm
	s.qJit[0] = 0
	s.prevQ[0] = 400
	s.hqCnt[0] = 6 // the incoming pinned report bumps this to 7 (>= PinDrainN)
	s.lastBig[0] = base.Add(-bigAgo)
	s.lastDec[0] = base.Add(-bigAgo)
	return s
}

// TestCadSitePinDrainEscalation covers the cad-site pinDrain disjunct
// (sched_model gate line 100 feeding cad line 107). lastBig is 400ms stale —
// too fresh for DRAIN's 800ms gate — so the report falls through to the BigDec
// walk. The pinDrain disjunct must open the gate at the CAD site to escalate
// the cadence 800ms -> 300ms; 400ms > 300ms then lands a BigDec cut. A
// DRAIN-only port (gate applied at the DRAIN site only) leaves cad at 800ms,
// 400ms < 800ms, and NO cut lands — so this test fails iff the cad-site
// disjunct is missing, the exact silent-divergence the review warned about.
func TestCadSitePinDrainEscalation(t *testing.T) {
	s := primeSched(time.Unix(1000, 0), 400*time.Millisecond)
	before := s.rateKb[0]
	s.OnQ(0, 400) // pinned report: qEwma stays 400, hqCnt -> 7, gate via pinDrain
	if s.rateKb[0] >= before {
		t.Fatalf("cad-site pinDrain disjunct missing: rate stayed %.1f, want a BigDec cut from %.1f at 300ms cadence", s.rateKb[0], before)
	}
	if got, want := s.rateKb[0], before*BigDec; got != want {
		t.Fatalf("expected BigDec cut to %.1f, got %.1f", want, got)
	}
}

// TestDrainSitePinDrain covers the DRAIN-site pinDrain disjunct (gate line 100
// feeding DRAIN line 101). Same pinned state but lastBig is 900ms stale — past
// DRAIN's 800ms gate — so the pinDrain disjunct must open the gate at the DRAIN
// site and the crush fires (rate -> floor*0.10). Without the disjunct here the
// report would instead take the cad path (a milder BigDec cut), so asserting
// the exact drain-floor value pins the site.
func TestDrainSitePinDrain(t *testing.T) {
	s := primeSched(time.Unix(1000, 0), 900*time.Millisecond)
	s.OnQ(0, 400)
	if got, want := s.rateKb[0], s.floorKb[0]*0.10; got != want {
		t.Fatalf("DRAIN-site pinDrain disjunct missing: rate=%.1f, want drain floor %.1f", got, want)
	}
}
