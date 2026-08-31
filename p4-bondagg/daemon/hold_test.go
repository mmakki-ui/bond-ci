package main

// U13 / OBJ-B tests: the monotonic stamp and the lateness ratchet.
//
// WHAT IS AND IS NOT COVERED, said first so no reader has to infer it:
//   * The ratchet's arithmetic, its evidence rule, its floor, its reset and its
//     concurrency are covered here, including one end-to-end test driving a REAL
//     Ring so the observation is proved against ring.go's actual skip/old
//     behaviour rather than against a description of it.
//   * The two-line wiring in runPullClient is NOT covered. runPullClient has
//     never executed anywhere (pathsim.py launches only AGG_MODE=server|client),
//     there is no seam to drive it, and the tests below construct their own
//     closures over controlled clocks. UNTESTED: that pullrun.go's closures are
//     the ones these tests exercise -- they are two lines, read, not run.
//   * UNTESTED: nothing here steps the real system clock. What monotonicity buys
//     under an NTP step is argued from time.Since's monotonic reading and proved
//     only for the property that follows from it (a constant offset cancels).

import (
	"math"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// --------------------------------------------------------------------------
// monotonic stamp
// --------------------------------------------------------------------------

func TestMonoStampNeverGoesBackwards(t *testing.T) {
	prev := monoMS()
	for i := 0; i < 2000; i++ {
		n := monoMS()
		if int32(n-prev) < 0 {
			t.Fatalf("monoMS went backwards: %d -> %d at i=%d", prev, n, i)
		}
		prev = n
	}
}

func TestMonoStampAdvancesLikeWallClock(t *testing.T) {
	m0, w0 := monoMS(), nowMS()
	time.Sleep(40 * time.Millisecond)
	dm := int32(monoMS() - m0)
	dw := int32(nowMS() - w0)
	// Wide on purpose. The property is that this IS a clock advancing in
	// milliseconds, not that a sleep is precise -- a loaded runner under -race can
	// oversleep by a lot, and a flaky gate is worse than a loose one.
	if dm < 20 || dm > 20000 {
		t.Fatalf("monoMS advanced %dms over a 40ms sleep, which is not a clock", dm)
	}
	d := dm - dw
	if d < 0 {
		d = -d
	}
	// Both are millisecond truncations of the same elapsed interval, so they may
	// differ by the truncation plus a deschedule between the two reads -- but not
	// by a RATE. A wrong unit would show up as ~40000, not ~100.
	if d > 250 {
		t.Fatalf("monoMS advanced %dms while nowMS advanced %dms over the same "+
			"interval: they are not measuring the same rate", dm, dw)
	}
}

// The load-bearing property of swapping the clock: every OWD consumer takes
// int32(now - tsms) and reads only DIFFERENCES out of it, so an arbitrary
// constant offset between two stamp sources cancels.
//
// ROUND 2, AND THE CLAIM IS NARROWED BECAUSE CI FALSIFIED THE WIDE FORM. This
// test used to assert BIT-EXACT equality of the readout under any offset. It
// FAILED on the first run that ever compiled this file (run 33323080131, job
// 99288359210: "offset 60000 changed the OWD readout: spread 47.700000->47.700000
// jitter 12.000000->12.000000" -- identical to six places and unequal in the last
// ulp). The cancellation is EXACT in the int32 modular subtraction, which is where
// the offset actually lives; it is NOT exact through the float64 EWMA
// `prev*0.9 + d*0.1`, because rounding at magnitude ~|offset| does not cancel with
// rounding at magnitude ~|d|. So the honest property, and the one asserted here,
// is agreement to within the float64 representation error at the magnitudes
// involved -- with the tolerance COMPUTED from those magnitudes and the number of
// folds, not picked.
func TestMonoStampOffsetCancelsInOwdSpread(t *testing.T) {
	orig := stampMS
	defer func() { stampMS = orig }()

	// Peer stamps, and the local clock advancing between arrivals.
	path := []int{0, 1, 2, 0, 1, 2, 0, 1, 2}
	peer := []uint32{500, 500, 500, 600, 600, 600, 700, 700, 700}
	local := []uint32{1000, 1040, 1010, 1120, 1190, 1135, 1230, 1320, 1255}

	// LIMB 1 -- the part that IS exact, asserted on its own so the narrowing
	// above cannot hide a real regression: the per-sample quantity every consumer
	// actually reads, int32(stamp - tsms), shifts by EXACTLY the offset. This is
	// integer modular arithmetic and there is no tolerance.
	for _, off := range []uint32{7, 60000, 1 << 20, 0xFFFF0000} {
		for i := range path {
			d0 := int32(local[i] - peer[i])
			d := int32((local[i] + off) - peer[i])
			if d-d0 != int32(off) {
				t.Fatalf("offset %d: int32(stamp-ts) moved by %d, not by the offset; "+
					"the modular subtraction does not cancel", off, d-d0)
			}
		}
	}

	// LIMB 2 -- the readout, to within float64 rounding at these magnitudes.
	run := func(offset uint32) (sp, ji, mag float64) {
		var base uint32 = 1000
		stampMS = func() uint32 { return base + offset }
		o := newPullOWD(3)
		for i := range path {
			base = local[i]
			o.Sample(path[i], peer[i])
		}
		s, j, have := o.SpreadJit()
		if !have {
			t.Fatal("no path initialised")
		}
		o.mu.Lock()
		for _, v := range o.rel {
			if v < 0 {
				v = -v
			}
			if v > mag {
				mag = v
			}
		}
		o.mu.Unlock()
		return s, j, mag
	}
	sp0, ji0, mag0 := run(0)
	for _, off := range []uint32{7, 60000, 1 << 20, 0xFFFF0000} {
		sp, ji, mag := run(off)
		// Derived, not picked: one ulp at the largest magnitude either run
		// carried, times the number of EWMA folds (each fold is one multiply-add,
		// so at most 2 ulp of new error), times 2 because spread is a difference
		// of two independently-folded series.
		m := mag
		if mag0 > m {
			m = mag0
		}
		ulp := math.Nextafter(m, math.Inf(1)) - m
		tol := ulp * float64(4*len(path))
		if math.Abs(sp-sp0) > tol || math.Abs(ji-ji0) > tol {
			t.Fatalf("offset %d moved the OWD readout beyond float64 rounding: "+
				"spread %.9f->%.9f jitter %.9f->%.9f, tol %.3g (magnitude %.0f); "+
				"a constant clock offset must cancel to within representation error",
				off, sp0, sp, ji0, ji, tol, m)
		}
	}
}

// RingHoldFloor claims to be ring.go:147-150's own floor, "copied so the two
// cannot disagree". Round 1 asserted that with nothing enforcing it (round-2
// review item). This drives a REAL Ring across the constant and requires
// holdNow() and the ratchet's mirror to agree at every point, so the copy is
// checked rather than declared.
func TestRingHoldFloorIsTheRingsOwnFloor(t *testing.T) {
	ring := NewRing(11, 0, func([]byte) {})
	r := NewLatenessRatchet(ring.Mask())
	for _, d := range []time.Duration{
		0, time.Nanosecond, time.Millisecond, RingHoldFloor - time.Nanosecond,
		RingHoldFloor, RingHoldFloor + time.Nanosecond,
		100 * time.Millisecond, 4 * time.Second,
	} {
		ring.SetHold(d)
		ring.mu.Lock()
		want := ring.holdNow()
		ring.mu.Unlock()
		r.SetInForce(d)
		if got := r.EffHold(); got != want {
			t.Fatalf("hold %v: the Ring applies %v, the ratchet mirrors %v -- "+
				"RingHoldFloor has drifted from ring.go:147-150", d, want, got)
		}
		// And the floor is where the constant says it is, not somewhere else.
		if d < RingHoldFloor && want != RingHoldFloor {
			t.Fatalf("hold %v below RingHoldFloor but the Ring applied %v", d, want)
		}
		if d >= RingHoldFloor && want != d {
			t.Fatalf("hold %v at or above RingHoldFloor but the Ring applied %v", d, want)
		}
	}
}

// B5: link liveness must not ride the wall clock. RxAge feeds SetAlive, which
// feeds AliveSet -> SameAliveSet -> LatenessRatchet.Reset -- the only thing that
// ever lowers the derived hold. No in-process test can step the system clock, so
// what is asserted is the DISCRIMINATING structural fact: the stored value is
// milliseconds since PROCESS START, not milliseconds since the Unix epoch. The
// round-1 code stored time.Now().UnixMilli(), which is ~1.7e12 and fails this.
func TestRxAgeIsAnchoredOnTheMonotonicEpoch(t *testing.T) {
	l := NewPullLink(0, "eth0", nil, nil)
	l.MarkRx()
	got := atomic.LoadInt64(&l.lastRxMs)
	ceiling := int64(time.Since(monoEpoch)/time.Millisecond) + 1000
	if got < 0 || got > ceiling {
		t.Fatalf("lastRxMs=%d is not milliseconds since the process's monotonic "+
			"epoch (ceiling %d) -- it looks like a WALL-CLOCK Unix stamp", got, ceiling)
	}
	if age := l.RxAge(time.Now()); age < 0 || age > time.Second {
		t.Fatalf("RxAge right after MarkRx is %v", age)
	}
	// And it still measures elapsed time, on the same anchor at both ends.
	if age := l.RxAge(time.Now().Add(5 * time.Second)); age < 4900*time.Millisecond ||
		age > 5100*time.Millisecond {
		t.Fatalf("RxAge 5s after MarkRx is %v", age)
	}
}

// The round-2 atomicity blocker, stated as a test rather than as a comment: a
// goroutine that has read the hold must not be able to re-install it after a
// concurrent Reset, and the Ring must never be left holding a value the ratchet
// has discarded. InstallOn and Reset serialise on the same install lock, so after
// any interleaving the Ring's hold equals the ratchet's.
func TestInstallOnAndResetAgreeUnderConcurrency(t *testing.T) {
	ring := NewRing(11, 0, func([]byte) {})
	r := NewLatenessRatchet(ring.Mask())
	r.SetInForce(0)
	// Teach it something so Reset has work to do.
	base := time.Now()
	r.OnSkip(1, base)
	r.OnOld(1, base.Add(300*time.Millisecond))

	var wg sync.WaitGroup
	stop := make(chan struct{})
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				r.InstallOn(ring.SetHold)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 2000; i++ {
			r.Reset(ring.SetHold)
		}
	}()
	for i := 0; i < 2000; i++ {
		// A real skip/old PAIR on the same seq: OnOld is evidence only for a seq
		// the ring gave up on (hold.go OnOld, round 3).
		sq := uint32(i)
		r.OnSkip(sq, time.Now())
		r.OnOld(sq, time.Now().Add(time.Duration(i%50)*time.Millisecond))
	}
	time.Sleep(20 * time.Millisecond)
	close(stop)
	wg.Wait()
	// Quiesce: one more install with nothing else running must leave the Ring and
	// the ratchet describing the same hold.
	want := r.InstallOn(ring.SetHold)
	if got := ring.HoldDur(); got != want {
		t.Fatalf("after the race the Ring holds %v and the ratchet says %v", got, want)
	}
	r.Reset(ring.SetHold)
	if got := ring.HoldDur(); got != 0 {
		t.Fatalf("Reset left the Ring holding %v for a delivering set that changed", got)
	}
}

// --------------------------------------------------------------------------
// pullOWD
// --------------------------------------------------------------------------

func TestPullOwdParkedPathsDoNotPinTheSpread(t *testing.T) {
	orig := stampMS
	defer func() { stampMS = orig }()
	var base uint32 = 1000
	stampMS = func() uint32 { return base }

	o := newPullOWD(4)
	// Only paths 1 and 2 ever deliver. 0 and 3 are parked and never init.
	base = 1050
	o.Sample(1, 1000)
	base = 1060
	o.Sample(2, 1000)
	sp, _, have := o.SpreadJit()
	if !have {
		t.Fatal("SpreadJit reported no initialised path after two samples")
	}
	if sp != 10 {
		t.Fatalf("spread over the DELIVERING set = %.3f, want 10 (paths 0 and 3 "+
			"never delivered and must not enter it)", sp)
	}
}

func TestPullOwdEmptyIsWarmup(t *testing.T) {
	o := newPullOWD(3)
	if _, _, have := o.SpreadJit(); have {
		t.Fatal("SpreadJit claims data before any Sample")
	}
	if h := formulaHold(o, HoldMin, HoldMax); h != HoldMax {
		t.Fatalf("formulaHold in warm-up = %v, want HoldMax %v (paths.go:98-100)", h, HoldMax)
	}
}

func TestFormulaHoldClampsBothLimbs(t *testing.T) {
	orig := stampMS
	defer func() { stampMS = orig }()
	var base uint32 = 0
	stampMS = func() uint32 { return base }

	// Two paths with no spread and no jitter -> spread+3*jit+250 = 250ms, which
	// is inside [150,350] and must come back unclamped.
	o := newPullOWD(2)
	base = 1000
	o.Sample(0, 900)
	base = 1000
	o.Sample(1, 900)
	if h := formulaHold(o, HoldMin, HoldMax); h != 250*time.Millisecond {
		t.Fatalf("formulaHold with zero spread/jitter = %v, want 250ms", h)
	}
	// Floor: a min above the computed value wins.
	if h := formulaHold(o, 400*time.Millisecond, 900*time.Millisecond); h != 400*time.Millisecond {
		t.Fatalf("formulaHold did not apply the floor: %v", h)
	}
	// Ceiling: a max below the computed value wins.
	if h := formulaHold(o, 10*time.Millisecond, 100*time.Millisecond); h != 100*time.Millisecond {
		t.Fatalf("formulaHold did not apply the ceiling: %v", h)
	}
}

// --------------------------------------------------------------------------
// LatenessRatchet -- the evidence rule
// --------------------------------------------------------------------------

func TestRatchetIsZeroUntilItObservesSomething(t *testing.T) {
	r := NewLatenessRatchet(2047)
	if r.Hold() != 0 {
		t.Fatalf("a fresh ratchet holds %v; it has observed nothing and must hold nothing", r.Hold())
	}
	// A late arrival with no preceding skip epoch carries no measurable lateness.
	r.OnOld(3, time.Now())
	if r.Hold() != 0 {
		t.Fatalf("ratchet raised to %v from an OnOld with no blockAt to measure against", r.Hold())
	}
	_, _, raises, obs, _ := r.Stats()
	if raises != 0 || obs != 0 {
		t.Fatalf("un-measurable OnOld was counted: raises=%d obs=%d", raises, obs)
	}
}

// THE CORE SEMANTIC. The observation is the arrival's distance from the time the
// ring became BLOCKED, not from the time it gave up. Measuring from the give-up
// instant yields the excess over the hold in force, which makes the ratchet a
// function of its own output -- the form the rig measured as WORSE than the
// shipped formula on every cell (hold.go section 3, candidate (a)).
func TestRatchetMeasuresFromBlockStartNotFromSkipTime(t *testing.T) {
	r := NewLatenessRatchet(2047)
	r.SetInForce(100 * time.Millisecond)
	t0 := time.Now()
	// blockAt := t0 - 100ms
	r.OnSkip(4, t0)
	// the frame arrives 50ms after the ring gave up
	r.OnOld(4, t0.Add(50*time.Millisecond))
	if got, want := r.Hold(), 150*time.Millisecond; got != want {
		t.Fatalf("ratchet learned %v, want %v: the hold that would have saved the "+
			"frame is (skip - inForce) to arrival, not (skip) to arrival", got, want)
	}
}

func TestRatchetUsesTheRingFloorWhenNothingIsInstalled(t *testing.T) {
	r := NewLatenessRatchet(2047)
	// Nothing installed yet: ring.go:147-150 would still hold for RingHoldFloor,
	// so blockAt must be reconstructed with that floor, not with zero.
	t0 := time.Now()
	r.OnSkip(5, t0)
	r.OnOld(5, t0.Add(5*time.Millisecond))
	if got, want := r.Hold(), RingHoldFloor+5*time.Millisecond; got != want {
		t.Fatalf("ratchet learned %v, want %v (ring.go's own >=10ms floor)", got, want)
	}
}

func TestRatchetOnlyRises(t *testing.T) {
	r := NewLatenessRatchet(2047)
	r.SetInForce(0)
	t0 := time.Now()
	r.OnSkip(6, t0)
	r.OnOld(6, t0.Add(200*time.Millisecond))
	big := r.Hold()
	r.OnSkip(7, t0.Add(time.Second))
	// a much smaller observation
	r.OnOld(7, t0.Add(time.Second+5*time.Millisecond))
	if r.Hold() != big {
		t.Fatalf("a smaller observation lowered the hold %v -> %v; the ratchet has "+
			"no decay and must not acquire one by accident", big, r.Hold())
	}
	_, _, raises, obs, _ := r.Stats()
	if raises != 1 || obs != 2 {
		t.Fatalf("raises=%d obs=%d, want 1 and 2: both observations count, only one raises",
			raises, obs)
	}
}

// The ratchet UNDER-shoots when the drain runs late, and never over-shoots.
// hold.go section 3 states the direction; this is the assertion behind it.
func TestRatchetUnderShootsWhenTheDrainIsLate(t *testing.T) {
	t0 := time.Now()
	arrival := t0.Add(300 * time.Millisecond)
	inForce := 100 * time.Millisecond

	prompt := NewLatenessRatchet(2047)
	prompt.SetInForce(inForce)
	// the skip fires exactly when the timer expires
	prompt.OnSkip(8, t0.Add(inForce))
	prompt.OnOld(8, arrival)

	late := NewLatenessRatchet(2047)
	late.SetInForce(inForce)
	// the drain ran 80ms late
	late.OnSkip(8, t0.Add(inForce+80*time.Millisecond))
	late.OnOld(8, arrival)

	if !(late.Hold() < prompt.Hold()) {
		t.Fatalf("late drain learned %v, prompt drain learned %v: a late drain must "+
			"UNDER-estimate, never over-estimate", late.Hold(), prompt.Hold())
	}
	if got, want := prompt.Hold()-late.Hold(), 80*time.Millisecond; got != want {
		t.Fatalf("the shortfall is %v, want exactly the drain lag %v", got, want)
	}
}

func TestRatchetResetClearsTheHoldAndKeepsThePeak(t *testing.T) {
	r := NewLatenessRatchet(2047)
	r.SetInForce(0)
	t0 := time.Now()
	r.OnSkip(9, t0)
	r.OnOld(9, t0.Add(400*time.Millisecond))
	learned := r.Hold()
	if learned == 0 {
		t.Fatal("ratchet learned nothing to reset")
	}
	r.Reset(nil)
	if r.Hold() != 0 {
		t.Fatalf("Reset left the hold at %v", r.Hold())
	}
	h, peak, _, _, resets := r.Stats()
	if h != 0 || peak != learned || resets != 1 {
		t.Fatalf("after Reset: h=%v peak=%v resets=%d, want 0 / %v / 1", h, peak, resets, learned)
	}
	// And a reset must also drop the stale blockAt AND the pending skips, or the
	// next OnOld measures a pre-Reset skip against a post-Reset block from a
	// different delivering set. Both paths are exercised: seq 9's skip record is
	// gone (so the arrival is not evidence at all), and a fresh skip/old pair on
	// a new seq measures only from the NEW block start.
	r.OnOld(9, t0.Add(time.Second))
	if r.Hold() != 0 {
		t.Fatalf("an OnOld after Reset measured against a stale blockAt: %v", r.Hold())
	}
	if _, unheld := r.Filtered(); unheld != 1 {
		t.Fatalf("the pre-Reset skip record survived Reset: unheld=%d, want 1", unheld)
	}
	r.OnSkip(11, t0.Add(2*time.Second))
	r.OnOld(11, t0.Add(2*time.Second+7*time.Millisecond))
	if got, want := r.Hold(), RingHoldFloor+7*time.Millisecond; got != want {
		t.Fatalf("after Reset the ratchet learned %v, want %v -- it must measure from "+
			"the NEW block start only", got, want)
	}
}

// --------------------------------------------------------------------------
// alive-set change detection -- N-generic, no index and no count assumed
// --------------------------------------------------------------------------

func TestSameAliveSetOverN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		a := make([]bool, n)
		for i := range a {
			a[i] = true
		}
		b := append([]bool(nil), a...)
		if !SameAliveSet(a, b) {
			t.Fatalf("N=%d: identical sets reported different", n)
		}
		for i := 0; i < n; i++ {
			c := append([]bool(nil), a...)
			c[i] = false
			if SameAliveSet(a, c) {
				t.Fatalf("N=%d: a change at index %d was not detected", n, i)
			}
		}
		if SameAliveSet(a, a[:n-1]) {
			t.Fatalf("N=%d: an arity change was not detected", n)
		}
	}
}

// --------------------------------------------------------------------------
// against a REAL Ring
// --------------------------------------------------------------------------

// End to end through ring.go itself: a genuine reorder, a genuine skip, a
// genuine late arrival, and the hold the ratchet learns from them. This is what
// proves the observation is wired to ring.go's actual behaviour and not to a
// description of it.
//
// The assertions do NOT predict ring.go's drain schedule -- drain runs on Push
// and on Tick, so WHEN the skip fires depends on the traffic. The test captures
// the skip instant the ring actually produced and asserts the ratchet's rule
// against it, plus the direction of the drain-lag error.
func TestRatchetLearnsFromARealRingReorder(t *testing.T) {
	base := time.Now()
	clock := base

	var out int
	var skipAt time.Time
	var sawSkip bool
	ring := NewRing(11, 0, func(b []byte) { out++ })
	r := NewLatenessRatchet(ring.Mask())
	ring.OnSkip = func(seq uint32) {
		if !sawSkip {
			skipAt = clock
			sawSkip = true
		}
		r.OnSkip(seq, clock)
	}
	ring.OnOld = func(seq, next uint32) { r.OnOld(seq, clock) }
	// nothing installed: ring.go's own floor is what the Ring applies
	r.SetInForce(0)

	pay := []byte{1, 2, 3}
	// Arm the ring: first arrival, then a Tick past the floor so next anchors.
	ring.Push(0, pay, clock)
	clock = base.Add(30 * time.Millisecond)
	ring.Tick(clock)
	if out != 1 {
		t.Fatalf("ring delivered %d frames after arming, want 1", out)
	}
	// The ring is now blocked on seq 1, and it became blocked at this instant.
	trueBlockAt := clock

	// seq 2 arrives; seq 1 is missing.
	clock = base.Add(60 * time.Millisecond)
	ring.Push(2, pay, clock)
	// Let the gap time out.
	clock = base.Add(90 * time.Millisecond)
	ring.Tick(clock)
	if !sawSkip {
		t.Fatal("ring never skipped seq 1, so there is no blockAt to measure from")
	}
	if ring.Skips != 1 {
		t.Fatalf("ring skipped %d seqs, want exactly 1", ring.Skips)
	}
	if r.Hold() != 0 {
		t.Fatalf("the ratchet raised on a SKIP; only an arrival that was too late "+
			"is evidence. hold=%v", r.Hold())
	}

	// seq 1 finally arrives, long after the ring passed it.
	arrival := base.Add(400 * time.Millisecond)
	clock = arrival
	ring.Push(1, pay, clock)
	if ring.Olds != 1 {
		t.Fatalf("ring counted %d old arrivals, want 1", ring.Olds)
	}
	// The rule: measured from the RECONSTRUCTED block start, skip - the hold the
	// Ring was applying (its own floor here).
	want := arrival.Sub(skipAt.Add(-RingHoldFloor))
	if got := r.Hold(); got != want {
		t.Fatalf("ratchet learned %v, want %v (arrival - (skipAt - ringFloor))", got, want)
	}
	// And the direction of the drain-lag error: never longer than the truth.
	if truth := arrival.Sub(trueBlockAt); r.Hold() > truth {
		t.Fatalf("ratchet learned %v but the true wait was %v: the reconstruction "+
			"must never over-shoot", r.Hold(), truth)
	}
}

// The lock-order property the design rests on: ring.go calls OnSkip/OnOld while
// holding r.mu, and the RX/control side calls ratchet.Hold() and then
// ring.SetHold(). Holding the ratchet mutex across a Ring call would be AB-BA.
// A regression deadlocks; -race is fatal in CI (emulator-gate.yml), so a data
// race fails the job rather than this assertion.
func TestRatchetAndRingUnderConcurrentUse(t *testing.T) {
	ring := NewRing(11, 0, func(b []byte) {})
	r := NewLatenessRatchet(ring.Mask())
	ring.OnSkip = func(seq uint32) { r.OnSkip(seq, time.Now()) }
	ring.OnOld = func(seq, next uint32) { r.OnOld(seq, time.Now()) }

	var wg sync.WaitGroup
	var next int64
	pay := []byte{9}

	// Producers: real pushes with holes, so real skips and real olds happen.
	// Bounded: seqs advance monotonically and stay inside a few ring windows, so
	// no far-future seq can drive flushTo into a long walk.
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 4000; i++ {
				v := atomic.AddInt64(&next, 1)
				// every 7th seq is never pushed -> a real hole
				if v%7 == 0 {
					continue
				}
				ring.Push(uint32(v), pay, time.Now())
				if i%16 == 0 {
					ring.Tick(time.Now())
				}
			}
		}()
	}
	// Consumers: the pullrun.go pattern -- read the ratchet, then install on the
	// ring. Never holds the ratchet lock across the Ring call.
	done := make(chan struct{})
	for g := 0; g < 2; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-done:
					return
				default:
				}
				h := r.Hold()
				r.SetInForce(h)
				ring.SetHold(h)
				_ = ring.HoldDur()
				r.Stats()
			}
		}()
	}
	// And a reset racing everything, which is what an alive-set change does.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-done:
				return
			default:
			}
			r.Reset(nil)
			time.Sleep(time.Millisecond)
		}
	}()

	time.Sleep(500 * time.Millisecond)
	close(done)
	wg.Wait()
}

// --------------------------------------------------------------------------
// ROUND 3 -- an OnOld is evidence only for a seq the ring GAVE UP ON.
//
// These two are the assertions behind the fix that removed the runaway. Round 2
// counted every arrival below the frontier, so a seq the ring never held for
// raised H against an unrelated blockAt. The rig measured the size of it: on
// ring.go's real 2^11 window the unfiltered rule learns 8,213 ms where this one
// learns 525 ms (highn_battery.py, B6c CTRL `subst B6c ratchet := UNFILTERED`).
// --------------------------------------------------------------------------

func TestOnOldForASeqTheRingNeverSkippedIsNotEvidence(t *testing.T) {
	r := NewLatenessRatchet(2047)
	r.SetInForce(0)
	t0 := time.Now()
	r.OnSkip(20, t0)
	// A DIFFERENT seq arrives below the frontier, hours late. The ring never
	// blocked on it, so no hold could have saved it and it says nothing.
	r.OnOld(21, t0.Add(8*time.Second))
	if r.Hold() != 0 {
		t.Fatalf("the ratchet learned %v from a seq the ring never skipped -- that is "+
			"the round-2 runaway", r.Hold())
	}
	_, _, raises, obs, _ := r.Stats()
	if raises != 0 || obs != 0 {
		t.Fatalf("un-held arrival was counted: raises=%d obs=%d", raises, obs)
	}
	skipped, unheld := r.Filtered()
	if skipped != 1 || unheld != 1 {
		t.Fatalf("Filtered()=%d,%d want 1,1", skipped, unheld)
	}
	// The seq that WAS skipped still counts, and only once.
	r.OnOld(20, t0.Add(30*time.Millisecond))
	if got, want := r.Hold(), RingHoldFloor+30*time.Millisecond; got != want {
		t.Fatalf("the skipped seq learned %v, want %v", got, want)
	}
	r.OnOld(20, t0.Add(8*time.Second))
	if got, want := r.Hold(), RingHoldFloor+30*time.Millisecond; got != want {
		t.Fatalf("a DUPLICATE of an already-observed seq raised the hold to %v (want %v) "+
			"-- one skip must yield at most one observation", got, want)
	}
}

// The concrete mechanism, driven through a REAL Ring: ring.go:138-139 flushTo
// advances the frontier on a WINDOW OVERFLOW without skipping, so the seqs it
// passes were never held for. Their late arrival must not raise the hold.
func TestWindowFlushDoesNotFeedTheRatchet(t *testing.T) {
	ring := NewRing(4, 0, func(b []byte) {}) // 16-deep ring, mask 15
	r := NewLatenessRatchet(ring.Mask())
	ring.OnSkip = func(seq uint32) { r.OnSkip(seq, time.Now()) }
	ring.OnOld = func(seq, next uint32) { r.OnOld(seq, time.Now()) }
	r.SetInForce(0)

	base := time.Now()
	pay := []byte{1}
	// Arm on seq 0.
	ring.Push(0, pay, base)
	ring.Tick(base.Add(30 * time.Millisecond))
	// A seq far past the window forces flushTo: seqs 1..99 are passed WITHOUT
	// any skip epoch, because no hold could have covered a count bound.
	ring.Push(100, pay, base.Add(40*time.Millisecond))
	if ring.Skips != 0 {
		t.Fatalf("the window flush reported %d skips; flushTo must not skip", ring.Skips)
	}
	// Now one of those flushed seqs arrives, very late.
	ring.Push(50, pay, base.Add(5*time.Second))
	if ring.Olds != 1 {
		t.Fatalf("ring counted %d old arrivals, want 1", ring.Olds)
	}
	if r.Hold() != 0 {
		t.Fatalf("a window-flushed seq taught the ratchet a %v hold. ring.go's window "+
			"is a COUNT bound, so no hold of any length would have covered it", r.Hold())
	}
	if _, unheld := r.Filtered(); unheld != 1 {
		t.Fatalf("the window-flushed arrival was not recorded as un-held: %d", unheld)
	}
}
