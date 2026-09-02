package main

import (
	"sync"
	"time"
)

// =============================================================================
// R3 realizable owd/jit estimator (RECEIVER side) -- nsched Estr floor/jit fold.
//
// The peer echoes nothing here: THIS end is the RECEIVER of a direction. It
// measures d = arrival_local - txstamp_remote (ms, QUEUE-INCLUDED, clock-offset
// THETA included) on every DATA/PING frame and splits it with QTrack2:
//   floor  = windowed min over FLOOR_K rotating FLOOR_W-sec buckets (skew-immune,
//            no +0.02 drift -- rotation handles skew time-based)
//   q_meas = max(0, d - floor)                 (echoed as qb, 4ms-quantized)
//   qs     = 0.9*qs + 0.1*q_meas               (smoothed queue, jit-gate signal)
//   relQF/jitQF = 0.9/0.1 EWMAs of d / |d-relQF|, folded ONLY when qs is calm
//                 (qs < 15 + jitQF; bootstrap 40 until 20 folds) so congestion
//                 never contaminates jit.  jitQF echoed as jt (1ms).
// The anchored owd echo od_p = floor_p - min_j floor_j (offset-free, fastest=0)
// is computed at echo time across all paths (D3). ONE floor feeds BOTH echoes.
// nsched Estr L599-687, _recompute_owdD L973-982.
// =============================================================================

const (
	FLOOR_K     = 3    // QTrack2 rotating buckets
	FLOOR_W     = 5.0  // QTrack2 bucket window (s); FLOOR_WIN = K*W = 15s
	QF_GATE_MS  = 15.0 // jit-fold busy gate: fold iff qs < QF_GATE_MS + jitQF
	QF_BOOT_MS  = 40.0 // bootstrap qs threshold, used in place of QF_GATE_MS+jitQF until QF_BOOT_N folds (jitQF is unseeded before then)
	QF_BOOT_N   = 20   // folds before the qs<15+jitQF gate engages
	QF_W        = 0.1  // relQF/jitQF EWMA new-sample weight (0.9/0.1, mirrors OWD)
	OD_QUANT    = 2.0  // anchored owd-delta echo quantum (ms), clamp 254*2 = 508
	JT_QUANT    = 1.0  // jitQF echo quantum (ms), clamp 255
	QMEAS_QUANT = 4.0  // realizable qmeas echo quantum (ms) -- the qb byte
)

// rxEst is one path's receiver-side floor/jit estimator (nsched Estr floor half).
type rxEst struct {
	flWin     [FLOOR_K]int64
	flMin     [FLOOR_K]float64
	floor     float64 // current windowed-min floor (ms)
	floorInit bool    // any real sample folded yet
	qmeas     float64 // last q_meas = max(0, d-floor) (ms), stale-held
	qs        float64 // smoothed q_meas (jit-gate signal)
	relQF     float64 // busy-gated relative-owd EWMA (jit dev base)
	jitQF     float64 // busy-gated jitter EWMA (echoed as jt)
	relQFInit bool
	qfFolds   int
}

// RxEstSet holds the receiver estimator for all N paths of one direction.
type RxEstSet struct {
	mu   sync.Mutex
	born time.Time
	est  []rxEst
}

func NewRxEstSet(priorOwd []float64) *RxEstSet {
	n := len(priorOwd)
	s := &RxEstSet{born: time.Now(), est: make([]rxEst, n)}
	for i := range s.est {
		s.est[i].floor = priorOwd[i]
		s.est[i].relQF = priorOwd[i]
		for j := 0; j < FLOOR_K; j++ {
			s.est[i].flWin[j] = -1 // -1 sentinel = bucket never filled
		}
	}
	return s
}

// floorUpdate: QTrack2 windowed-min over K rotating W-sec buckets. Returns
// q_meas = max(0, d - floor). O(1)/sample. nsched Estr._floor_update L653-668.
func (e *rxEst) floorUpdate(tSec, d float64) float64 {
	wn := int64(tSec / FLOOR_W)
	k := wn % FLOOR_K
	if e.flWin[k] != wn { // rotate this bucket into a new window
		e.flWin[k] = wn
		e.flMin[k] = d
	} else if d < e.flMin[k] {
		e.flMin[k] = d
	}
	lo := wn - FLOOR_K + 1 // keep only the last K FILLED windows
	haveVal := false
	mn := 0.0
	for j := 0; j < FLOOR_K; j++ {
		if e.flWin[j] >= 0 && e.flWin[j] >= lo { // >=0 excludes the -sentinel? see note
			if !haveVal || e.flMin[j] < mn {
				mn = e.flMin[j]
				haveVal = true
			}
		}
	}
	if haveVal { // non-empty -> track; empty -> hold last
		e.floor = mn
		e.floorInit = true
	}
	q := d - e.floor
	if q < 0 {
		q = 0
	}
	return q
}

// fold folds ONE realizable sample d (ms) into floor/qs/jit-gate. The jit fold
// is BUSY-GATED on the smoothed qs (fold iff qs < 15 + jitQF; bootstrap 40 until
// 20 folds) with raw deviation |d - prev_relQF|; gated out -> hold relQF/jitQF
// (starvation-safe). nsched Estr._fold_sample L670-687.
func (e *rxEst) fold(tSec, d float64) {
	qMeas := e.floorUpdate(tSec, d)
	e.qmeas = qMeas
	e.qs = 0.9*e.qs + 0.1*qMeas
	thr := QF_BOOT_MS
	if e.qfFolds >= QF_BOOT_N {
		thr = QF_GATE_MS + e.jitQF
	}
	if e.qs < thr {
		if !e.relQFInit {
			e.relQF = d
			e.relQFInit = true
		} else {
			prev := e.relQF
			e.relQF = prev*(1.0-QF_W) + d*QF_W
			dev := d - prev
			if dev < 0 {
				dev = -dev
			}
			e.jitQF = e.jitQF*(1.0-QF_W) + dev*QF_W
		}
		e.qfFolds++
	}
}

// Fold a measured sample d (ms) for path p (a DATA or PING arrival). fseq-less;
// caller supplies d = arrival - txstamp.
func (s *RxEstSet) Fold(p int, d float64) {
	tSec := time.Since(s.born).Seconds()
	s.mu.Lock()
	if p >= 0 && p < len(s.est) {
		s.est[p].fold(tSec, d)
	}
	s.mu.Unlock()
}

// Echo returns the pong bytes for path p: qb (q_meas/4, 4ms units, clamp 255),
// od (anchored floor delta in 2ms units, clamp 254), jt (jitQF in 1ms, clamp
// 255). The owd anchor is taken across ALL paths' floors at echo time (D3):
// od_p = floor_p - min_j floor_j; floors not yet learned fall back to the spec
// prior so the pre-floor ranking is sane. THETA cancels in the delta.
func (s *RxEstSet) Echo(p int) (qb, od, jt byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p < 0 || p >= len(s.est) {
		return 0, 0, 0
	}
	e := &s.est[p]
	// cross-path anchor (fastest floor = 0), over INITIALIZED floors ONLY (#5).
	// A floor not yet learned (a path DOWN at boot, floor still at its 0 prior)
	// must NOT enter the anchor: its 0 would become mn, so every learned path's
	// od = its full floor -- which still carries the clock offset THETA. THETA
	// only cancels when BOTH terms are real floors (od = flp - mn, THETA common).
	// So: anchor over learned floors, and echo od=0 when our own floor is not yet
	// learned OR no floor is (else THETA poisons owd, clamped to 508ms).
	mn := 0.0
	haveMn := false
	for i := range s.est {
		if !s.est[i].floorInit {
			continue
		}
		fl := s.est[i].floor
		if !haveMn || fl < mn {
			mn = fl
			haveMn = true
		}
	}
	odMs := 0.0
	if e.floorInit && haveMn {
		odMs = e.floor - mn
		if odMs < 0 {
			odMs = 0
		}
	}
	// quantize + clamp
	qbU := int64(e.qmeas / QMEAS_QUANT)
	qb = byte(clamp64(qbU, 0, 255))
	odU := int64(odMs/OD_QUANT + 0.5)
	od = byte(clamp64(odU, 0, 254))
	jtU := int64(e.jitQF/JT_QUANT + 0.5)
	jt = byte(clamp64(jtU, 0, 255))
	return qb, od, jt
}

func clamp64(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
