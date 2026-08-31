package main

import (
	"log"
	"math"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

func nowMS() uint32 { return uint32(time.Now().UnixMilli() & 0xFFFFFFFF) }

// device-bound UDP socket (client side), engarde-proven mechanism
func devConn(ifname string) (*net.UDPConn, error) {
	s, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
	if err != nil {
		return nil, err
	}
	syscall.SetsockoptInt(s, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
	if ifname != "" {
		if err := syscall.SetsockoptString(s, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, ifname); err != nil {
			syscall.Close(s)
			return nil, err
		}
	}
	lsa := syscall.SockaddrInet4{Port: 0}
	if err := syscall.Bind(s, &lsa); err != nil {
		syscall.Close(s)
		return nil, err
	}
	f := os.NewFile(uintptr(s), "")
	c, err := net.FilePacketConn(f)
	f.Close()
	if err != nil {
		return nil, err
	}
	return c.(*net.UDPConn), nil
}

// OWD tracker: per-path relative one-way delay via header timestamps.
// hold = clamp(spread + 3*jitter + 250, HoldMin, HoldMax). N-path: spread is the
// max-min over all initialized paths; jitter is the max over paths.
type OWD struct {
	mu   sync.Mutex
	rel  []float64 // ewma of (arrival - txstamp), clock-offset included
	jit  []float64
	init []bool
}

func NewOWD(n int) *OWD {
	return &OWD{rel: make([]float64, n), jit: make([]float64, n), init: make([]bool, n)}
}

func (o *OWD) Sample(path int, tsms uint32) {
	d := float64(int32(nowMS() - tsms)) // relative; offset cancels in spread
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.init[path] {
		o.rel[path] = d
		o.init[path] = true
		return
	}
	prev := o.rel[path]
	o.rel[path] = prev*0.9 + d*0.1
	dev := d - prev
	if dev < 0 {
		dev = -dev
	}
	o.jit[path] = o.jit[path]*0.9 + dev*0.1
}

func (o *OWD) Hold(min, max time.Duration) time.Duration {
	o.mu.Lock()
	defer o.mu.Unlock()
	lo, hi := 0.0, 0.0
	haveSpread := false
	j := 0.0
	for p := range o.rel {
		// EIF: parked (STANDBY) paths carry no data -> never init; skip them so
		// they don't pin the hold at max. Cross-path reorder only spans the paths
		// actually delivering. (N=2 both-active is unchanged.)
		if !o.init[p] {
			continue
		}
		if !haveSpread || o.rel[p] < lo {
			lo = o.rel[p]
		}
		if !haveSpread || o.rel[p] > hi {
			hi = o.rel[p]
		}
		haveSpread = true
		if o.jit[p] > j {
			j = o.jit[p]
		}
	}
	if !haveSpread {
		return max // warm-up: nothing learned yet
	}
	spread := hi - lo
	h := time.Duration(spread+3*j+250) * time.Millisecond // +250: estimator probe-queue allowance (covers BigQ band)
	if h < min {
		h = min
	}
	if h > max {
		h = max
	}
	return h
}

// Scheduler AIMD controller (nsched Ctl / sched_model): token buckets are GONE
// (the EIF scheduler makes the send decision via ETA argmin); rateKb remains the
// CONGESTION actor -- it climbs to CeilKb on clean RTT, backs off on the peer-
// reported queue, and its SPIKE/DRAIN cuts fire OnCollapse (post-cut rate ->
// CapEst.OnCollapse + FEC collapse-coupling). Configured weights are floors.
const (
	CeilKb    = 60000.0
	CongQMs   = 40.0
	BigQMs    = 200.0
	IncKbStep = 150.0
	DecMult   = 0.85
	BigDec    = 0.7
	IncFreeze = 600 * time.Millisecond
	JitK      = 2.0 // AIMD spike jitter-normalization gain (model-validated: 5/5 A-E
	// at k=2.0 over 30 seeds; k=3.0 breaks blip scenario). Distinct from EifBeta.
)

// SPIKE/DRAIN confirmation counts ported from the measured CAND tune:
// SpikeConfirm gates the fresh-spike cut behind two consecutive over-threshold
// reports; PinDrainN forces the collapse gate open once the queue has stayed
// pinned (hqCnt) that many reports even at/above the cliff.
const (
	SpikeConfirm = 2
	PinDrainN    = 6
)

type Sched struct {
	mu        sync.Mutex
	rateKb    []float64
	floorKb   []float64
	qEwma     []float64
	qInit     []bool
	lastDec   []time.Time
	lastBig   []time.Time
	capHint   []float64
	hqCnt     []int
	reLearn   []bool
	dirtyRep  []int
	warmed    []bool
	graceLeft []int
	spCnt     []int
	qJit      []float64
	prevQ     []float64
	born      time.Time
	lastInc   time.Time
	lastPong  []time.Time
	now       func() time.Time
	// OnCollapse (optional): control-plane collapse hook, fired at the EV SPIKE
	// and EV DRAIN sites with the POST-CUT rate. Invoked while s.mu is held -- the
	// callback must NOT re-enter any Sched method (would deadlock).
	OnCollapse func(p int, postCutKb float64)
}

func NewSched(w []float64) *Sched {
	n := len(w)
	s := &Sched{
		rateKb: make([]float64, n), floorKb: make([]float64, n),
		qEwma: make([]float64, n), qInit: make([]bool, n),
		lastDec: make([]time.Time, n), lastBig: make([]time.Time, n),
		capHint: make([]float64, n), hqCnt: make([]int, n),
		reLearn: make([]bool, n), dirtyRep: make([]int, n),
		warmed: make([]bool, n), graceLeft: make([]int, n),
		spCnt: make([]int, n), qJit: make([]float64, n), prevQ: make([]float64, n),
		lastPong: make([]time.Time, n),
		born:     time.Now(), lastInc: time.Now(), now: time.Now,
	}
	for p := 0; p < n; p++ {
		// slow-start: begin at the decay floor so rttBase is learned on an
		// UNCONGESTED path; climb discovers capacity from below.
		s.rateKb[p] = w[p] * 0.25
		s.floorKb[p] = w[p]
		s.capHint[p] = w[p] // floors double as first capacity guesses
	}
	return s
}

// OnQ: one-way queue (ms) of OUR tx direction on path p, as measured and reported
// by the peer. Pure signal: reverse-path congestion invisible.
func (s *Sched) OnQ(p int, qms float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastPong[p] = s.now()
	if !s.qInit[p] {
		s.qEwma[p], s.qInit[p] = qms, true
		return
	}
	prev := s.qEwma[p]
	s.qEwma[p] = s.qEwma[p]*0.7 + qms*0.3
	s.qJit[p] = s.qJit[p]*0.9 + math.Abs(qms-s.qEwma[p])*0.1
	jit := JitK * s.qJit[p]
	now := s.now()
	if now.Sub(s.born) < 1500*time.Millisecond {
		// WARMUP: baselines still forming; startup stalls masquerade as
		// congestion. Observe, act on nothing, capture no cliff.
		return
	}
	if !s.warmed[p] {
		// First post-warmup report: re-seed like qInit so a boundary-straddling
		// startup stall can't act at exit.
		s.warmed[p] = true
		s.graceLeft[p] = 2
		s.qEwma[p] = qms
		s.qJit[p] = 0
		s.dirtyRep[p] = 0
		s.prevQ[p] = qms
		return
	}
	if s.graceLeft[p] > 0 {
		// Grace: the stall aftermath can arrive LOW-first (a stale pong byte
		// before the inflated one) -- keep updating state, act on nothing.
		s.graceLeft[p]--
		s.prevQ[p] = qms
		return
	}
	if qms >= CongQMs+jit {
		s.dirtyRep[p]++
	} else {
		s.dirtyRep[p] = 0
	}
	spikeThr := math.Max(150, s.qEwma[p]+4*s.qJit[p])
	if qms > spikeThr {
		s.spCnt[p]++
	} else {
		s.spCnt[p] = 0
	}
	if s.spCnt[p] >= SpikeConfirm && prev < 80+jit {
		// FRESH spike: instantaneous q far above a low smoothed level = probe
		// overshoot racing the reports; cut before the receiver's Hold is
		// threatened. Thresholds ride the measured jitter floor (qJit).
		if now.Sub(s.lastBig[p]) > 800*time.Millisecond {
			s.rateKb[p] *= 0.5 // emergency halving: the believed cliff may be
			// stale (cap collapse), so a relative cut beats trusting it
			if h := s.capHint[p] * 0.9; s.capHint[p] > 0 && s.rateKb[p] > h {
				s.rateKb[p] = h
			}
			if s.rateKb[p] < s.floorKb[p]*0.25 {
				s.rateKb[p] = s.floorKb[p] * 0.25
			}
			log.Printf("EV SPIKE p=%d rate=%.0f q=%.0f prev=%.0f", p, s.rateKb[p], qms, prev)
			if s.OnCollapse != nil {
				s.OnCollapse(p, s.rateKb[p])
			}
			s.lastBig[p] = now
			s.lastDec[p] = now
		}
		return
	}
	if s.qEwma[p] > CongQMs+jit {
		if prev <= CongQMs+jit && s.dirtyRep[p] >= 2 {
			// first crossing: remember where the cliff is -- confirmed by
			// consecutive dirty INSTANT reports so ewma blips can't poison.
			s.capHint[p] = s.rateKb[p] * 0.85 // detection lags the cap by
			// ~rampRate*feedback-lag; 0.85 lands the hint at/below it
			s.reLearn[p] = false
			log.Printf("EV CROSS p=%d rate=%.0f hint=%.0f", p, s.rateKb[p], s.capHint[p])
		}
		if qms > 200+jit {
			s.hqCnt[p]++
		} else {
			s.hqCnt[p] = 0
		}
		// gate: capacity-collapse hypothesis is live -- already cut far below the
		// believed cliff, or the queue stayed pinned past the pin-drain count.
		gate := s.capHint[p] == 0 || s.rateKb[p] < s.capHint[p]*0.6 || s.hqCnt[p] >= PinDrainN
		if s.hqCnt[p] >= 3 && now.Sub(s.lastBig[p]) > 800*time.Millisecond && gate {
			// DRAIN MODE: q stayed pinned even though we've cut far BELOW the
			// believed cliff -- the path's capacity collapsed. Crush hard to
			// clear the backlog; forget the cliff and re-climb (reLearn).
			pre := s.rateKb[p]
			s.rateKb[p] = s.floorKb[p] * 0.10
			if s.rateKb[p] < 100 {
				s.rateKb[p] = 100
			}
			log.Printf("EV DRAIN p=%d pre=%.0f hint=%.0f q=%.0f", p, pre, s.capHint[p], qms)
			if s.OnCollapse != nil {
				s.OnCollapse(p, s.rateKb[p])
			}
			s.capHint[p] = 0
			s.reLearn[p] = true
			s.hqCnt[p] = 0
			s.lastBig[p] = now
			s.lastDec[p] = now
		} else if s.qEwma[p] > BigQMs+jit {
			// one hard cut per drain window; jump BELOW the remembered cliff so
			// the spike collapses instead of walking down it. While q is pinned
			// AND we're already below the believed cliff, the walk escalates to
			// 300ms; in offer-overload stay at 800ms.
			cad := 800 * time.Millisecond
			if s.hqCnt[p] >= 3 && gate {
				cad = 300 * time.Millisecond
			}
			if now.Sub(s.lastBig[p]) > cad {
				s.rateKb[p] *= BigDec
				if h := s.capHint[p] * 0.9; s.capHint[p] > 0 && s.rateKb[p] > h {
					s.rateKb[p] = h
				}
				if s.rateKb[p] < s.floorKb[p]*0.25 {
					s.rateKb[p] = s.floorKb[p] * 0.25
				}
				s.lastBig[p] = now
				s.lastDec[p] = now
			}
		} else if now.Sub(s.lastDec[p]) > 200*time.Millisecond {
			if !(qms < s.prevQ[p]-5) {
				// decay only while the queue is still BUILDING; riding the ewma
				// down after a big cut just floor-grinds the rate (drainHold).
				s.rateKb[p] *= DecMult
				if s.rateKb[p] < s.floorKb[p]*0.25 {
					s.rateKb[p] = s.floorKb[p] * 0.25
				}
				s.lastDec[p] = now
			}
		}
	} else {
		s.hqCnt[p] = 0
	}
	s.prevQ[p] = qms
}

// TickIncrease: AIMD multiplicative climb, called at the 100ms report cadence
// (was called per-Pick when the token bucket owned scheduling). Self-gated to
// 200ms internally. nsched Ctl.tick.
func (s *Sched) TickIncrease() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if now.Sub(s.lastInc) < 200*time.Millisecond {
		return
	}
	s.lastInc = now
	for p := range s.rateKb {
		silent := s.qInit[p] && now.Sub(s.lastPong[p]) > 400*time.Millisecond
		if silent {
			// control starved = congestion/blackhole: decay, never climb blind
			if now.Sub(s.lastDec[p]) > 200*time.Millisecond {
				s.rateKb[p] *= DecMult
				if s.rateKb[p] < s.floorKb[p]*0.25 {
					s.rateKb[p] = s.floorKb[p] * 0.25
				}
				s.lastDec[p] = now
			}
			continue
		}
		fresh := s.qInit[p] && now.Sub(s.lastPong[p]) <= 300*time.Millisecond
		if fresh && s.qEwma[p] <= (CongQMs+JitK*s.qJit[p])*0.6 && now.Sub(s.lastDec[p]) > IncFreeze {
			step := IncKbStep
			if s.reLearn[p] {
				step = IncKbStep / 2 // post-drain: cap unknown, probe gently
			}
			if s.capHint[p] > 0 && s.rateKb[p] > s.capHint[p]*0.9 {
				step = 10 + s.rateKb[p]*0.01 // creep at/above the believed cliff
			}
			s.rateKb[p] += step
			if s.rateKb[p] > CeilKb {
				s.rateKb[p] = CeilKb
			}
		}
	}
}

// Rates snapshots per-path rate + smoothed queue for STAT logging.
func (s *Sched) Rates() (rates, q []float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rates = make([]float64, len(s.rateKb))
	q = make([]float64, len(s.qEwma))
	copy(rates, s.rateKb)
	copy(q, s.qEwma)
	return
}

// RateOf returns the current post-cut controller rate for path p (for tests /
// diagnostics; the OnCollapse callback receives it directly).
func (s *Sched) RateOf(p int) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rateKb[p]
}
