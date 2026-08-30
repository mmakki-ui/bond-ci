package main

import (
	"encoding/binary"
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// U15a / E2b tests.
//
// WHAT THESE CAN AND CANNOT SHOW. Every test here runs against synthetic echo
// payloads built by capEchoPayload below, in-process, with a clock the test
// supplies. They decide the daemon's OWN arithmetic and its OWN state machine:
// the alignment, the wrap, the restart, the latch, the hysteresis, the fail-open.
// They decide NOTHING about hardware. Whether a hidden mid-network bottleneck
// exists on the target path at all -- the entire reason this file's subject
// exists -- is G1/E1's measurement and no test in this package can stand in for
// it. That is why the cap ships OFF and why enabling it demands numbers this
// build refuses to supply.
// ---------------------------------------------------------------------------

// capTestCfg is the model configuration. These are NOT defaults and they are not
// shipped: cap.go contains no threshold literal at all and refuses to start
// without operator-supplied values. They are here so the state machine has
// numbers to be tested with. Their provenance, stated correctly (an earlier
// version of this comment said all five carry masterpiece_dp.py's "(*)" marking;
// only two do): trip 0.92 = CAP_TRIP (:96) and clear 1.5 = CAP_CLEAR (:97), both
// "(*) set for real on the hardware edge-vs-mid box test" per the legend at
// :90-91; window 400 ms = CAP_DET_W (:104) and minrate 500 kb/s = MINRATE (:106)
// carry no marking; target 40 ms is the oracle constructor default
// (reserved_composite.py:153, 03-reserved-composite/ackclock_sim.py:80), model
// validated only, ADR-004.
func capTestCfg() CapConfig {
	return CapConfig{
		TargetMS:    40,
		Trip:        0.92,
		Clear:       1.5,
		MinRateKbps: 500,
		DetWindow:   400 * time.Millisecond,
	}
}

// capRec is one link record in an echo payload.
type capRec struct {
	id     byte
	frames uint64
	bytes  uint64
}

// capEchoPayload builds an echo payload in the SERVER's format, byte for byte:
// p4-bondagg/server/echo.go:107-118, and the writer is Snapshot at echo.go:162.
// Hand-built rather than imported because daemon and server are separate Go
// modules -- which is exactly the drift risk the decoder's length check exists
// for, so the encoder used to test it must be written from the documented layout
// and not shared with the producer.
func capEchoPayload(srvMS uint32, recs ...capRec) []byte {
	p := make([]byte, capEchoHdrLen+len(recs)*capEchoRecLen)
	p[0] = byte(len(recs))
	p[1] = 0
	binary.BigEndian.PutUint32(p[2:6], srvMS)
	for i, r := range recs {
		off := capEchoHdrLen + i*capEchoRecLen
		p[off] = r.id
		p[off+1] = 0
		binary.BigEndian.PutUint64(p[off+2:off+10], r.frames)
		binary.BigEndian.PutUint64(p[off+10:off+18], r.bytes)
	}
	return p
}

// unalignedInflight is THE FAILURE, implemented so it can be executed instead of
// described: the naive difference between the client's CURRENT cumulative sent
// bytes and the rxBytes of an echo that was snapshotted a round trip ago
// (cap.go LAG ALIGNMENT, p5-execution-handover.md:38, server/echo.go:76-81).
// Nothing in the datapath calls it and it exists only in this file.
func unalignedInflight(sentNow, rxFromEcho uint64) float64 {
	return float64(sentNow) - float64(rxFromEcho)
}

// capFold is the shorthand every trace test uses: mark a ping, then fold the
// echo that answers it.
func capFold(c *Cap, link int, ts uint32, sentCum, rx uint64, srvMS uint32, bp uint64, now time.Time) {
	c.MarkPing(link, ts, sentCum)
	bps := make([]uint64, c.N())
	if link < len(bps) {
		bps[link] = bp
	}
	c.FoldEcho(ts, capEchoPayload(srvMS, capRec{id: byte(link), frames: rx / 1000, bytes: rx}), bps, now)
}

func newTestCap(t *testing.T, n int) *Cap {
	t.Helper()
	c, err := NewCap(n, capTestCfg())
	if err != nil {
		t.Fatalf("NewCap: %v", err)
	}
	return c
}

// ---------------------------------------------------------------------------
// 1. THE FLAG AND ITS DEFAULT
// ---------------------------------------------------------------------------

// The cap is OFF unless AGG_PULL_CAP is exactly "on", and OFF means a nil *Cap
// that admits every link at every N. The nil receiver IS the off state, so the
// draw loop needs no branch for it.
func TestCapDefaultOffAdmitsEverythingForAnyN(t *testing.T) {
	for _, v := range []string{"", "off", "1", "true", "ON", "yes"} {
		on, _, err := CapConfigFromEnv(func(k string) string {
			if k == "AGG_PULL_CAP" {
				return v
			}
			return "40"
		})
		if err != nil || on {
			t.Fatalf("AGG_PULL_CAP=%q: on=%v err=%v, want off with no error", v, on, err)
		}
	}
	var off *Cap
	if off.Enabled() {
		t.Fatal("a nil *Cap reports Enabled")
	}
	for _, n := range []int{1, 2, 3, 5, 8} {
		for i := 0; i < n; i++ {
			if !off.Admit(i, time.Now()) {
				t.Fatalf("N=%d link %d: a disabled cap refused a draw", n, i)
			}
		}
	}
}

// Switching the cap on without the numbers E1 produces is a REFUSAL, and the
// refusal names every missing key at once. This is the E1 gate made structural:
// there is no default for any of them anywhere in the build, so the cap cannot
// be enabled before the experiment that derives them.
func TestCapConfigRequiresEveryUnderivedNumber(t *testing.T) {
	full := map[string]string{
		"AGG_PULL_CAP":              "on",
		"AGG_PULL_CAP_TARGET_MS":    "40",
		"AGG_PULL_CAP_TRIP":         "0.92",
		"AGG_PULL_CAP_CLEAR":        "1.5",
		"AGG_PULL_CAP_MINRATE_KBPS": "500",
		"AGG_PULL_CAP_DET_MS":       "400",
	}
	for _, missing := range capEnvKeys {
		on, _, err := CapConfigFromEnv(func(k string) string {
			if k == missing {
				return ""
			}
			return full[k]
		})
		if on {
			t.Fatalf("missing %s: cap enabled anyway", missing)
		}
		if !errors.Is(err, ErrCapNoDerivation) {
			t.Fatalf("missing %s: err=%v, want ErrCapNoDerivation", missing, err)
		}
		if !strings.Contains(err.Error(), missing) {
			t.Fatalf("missing %s: refusal does not name it: %v", missing, err)
		}
	}
	// And the whole set at once: every key named in one message.
	_, _, err := CapConfigFromEnv(func(k string) string {
		if k == "AGG_PULL_CAP" {
			return "on"
		}
		return ""
	})
	for _, k := range capEnvKeys {
		if !strings.Contains(err.Error(), k) {
			t.Fatalf("refusal does not name %s: %v", k, err)
		}
	}
	if !strings.Contains(err.Error(), "E1") {
		t.Fatalf("refusal does not name the experiment that derives the numbers: %v", err)
	}
}

// A complete set is accepted and lands in the config unchanged.
func TestCapConfigAcceptsACompleteSet(t *testing.T) {
	env := map[string]string{
		"AGG_PULL_CAP":              "on",
		"AGG_PULL_CAP_TARGET_MS":    "37",
		"AGG_PULL_CAP_TRIP":         "0.9",
		"AGG_PULL_CAP_CLEAR":        "1.4",
		"AGG_PULL_CAP_MINRATE_KBPS": "250",
		"AGG_PULL_CAP_DET_MS":       "350",
	}
	on, cfg, err := CapConfigFromEnv(func(k string) string { return env[k] })
	if err != nil || !on {
		t.Fatalf("on=%v err=%v", on, err)
	}
	if cfg.TargetMS != 37 || cfg.Trip != 0.9 || cfg.Clear != 1.4 ||
		cfg.MinRateKbps != 250 || cfg.DetWindow != 350*time.Millisecond {
		t.Fatalf("config not carried through: %+v", cfg)
	}
}

// Values that cannot mean anything are refused rather than coerced: a
// non-positive or unparseable threshold, a value with TRAILING GARBAGE, and a
// Clear that does not exceed Trip (the gap between them IS the hysteresis, so a
// non-positive gap turns latch-and-hold into a flap).
//
// The trailing-garbage rows are the ones that used to pass. fmt.Sscan stops at
// the first token and reports no error for what follows, so "0.92 junk" parsed
// to 0.92 with err nil and an operator typo became a silently accepted threshold
// on a safety mechanism. cap.go uses strconv.ParseFloat, which requires the
// whole string.
func TestCapConfigRejectsNonsenseValues(t *testing.T) {
	base := map[string]string{
		"AGG_PULL_CAP":              "on",
		"AGG_PULL_CAP_TARGET_MS":    "40",
		"AGG_PULL_CAP_TRIP":         "0.92",
		"AGG_PULL_CAP_CLEAR":        "1.5",
		"AGG_PULL_CAP_MINRATE_KBPS": "500",
		"AGG_PULL_CAP_DET_MS":       "400",
	}
	bad := []struct{ k, v string }{
		{"AGG_PULL_CAP_TARGET_MS", "0"},
		{"AGG_PULL_CAP_TARGET_MS", "-5"},
		{"AGG_PULL_CAP_TRIP", "abc"},
		{"AGG_PULL_CAP_TRIP", "0.92 junk"},
		{"AGG_PULL_CAP_CLEAR", "1.5 1.6"},
		{"AGG_PULL_CAP_TARGET_MS", "40ms"},
		{"AGG_PULL_CAP_MINRATE_KBPS", "500kbps"},
		{"AGG_PULL_CAP_DET_MS", "400 // window"},
		{"AGG_PULL_CAP_DET_MS", "0"},
		{"AGG_PULL_CAP_CLEAR", "0.5"}, // <= Trip: no hysteresis gap
		{"AGG_PULL_CAP_CLEAR", "0.92"},
	}
	for _, b := range bad {
		on, _, err := CapConfigFromEnv(func(k string) string {
			if k == b.k {
				return b.v
			}
			return base[k]
		})
		if on || err == nil {
			t.Fatalf("%s=%q accepted (on=%v err=%v)", b.k, b.v, on, err)
		}
	}
}

// A detection window shorter than the echo cadence cannot contain two readings,
// so it cannot contain a ratio. Refused at construction (cap.go S10).
func TestCapRefusesADetectionWindowShorterThanTheEchoCadence(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval - time.Millisecond
	if _, err := NewCap(2, cfg); err == nil {
		t.Fatal("accepted a window shorter than PingIval")
	}
	cfg.DetWindow = PingIval
	if _, err := NewCap(2, cfg); err != nil {
		t.Fatalf("rejected a window of exactly one echo cadence: %v", err)
	}
}

// FlagEcho must not collide with any flag the shipped stack already uses, or an
// echo would be parsed as something else by a peer that has not learned it.
func TestCapFlagEchoDoesNotCollideWithTheShippedFlags(t *testing.T) {
	for _, f := range []struct {
		name string
		v    int
	}{{"FlagData", FlagData}, {"FlagPing", FlagPing}, {"FlagPong", FlagPong}, {"FlagFEC", FlagFEC}} {
		if f.v == FlagEcho {
			t.Fatalf("FlagEcho 0x%x collides with %s", FlagEcho, f.name)
		}
	}
	if FlagEcho != 0x4 {
		t.Fatalf("FlagEcho = 0x%x, the server sends 0x4 (server/frame.go:62)", FlagEcho)
	}
	if FlagEcho > 0x0F {
		t.Fatal("FlagEcho does not fit the header's 4-bit flag nibble (frame.go:8)")
	}
}

// ---------------------------------------------------------------------------
// 2. LAG ALIGNMENT -- the load-bearing pair. The second test is what makes the
//    first mean anything: a meter that always returned zero would pass the first
//    alone.
// ---------------------------------------------------------------------------

// capCleanTrace is one clean sustained-load trace, shared by the pair below so
// they are provably measuring the SAME sequence.
//
//	rate      1000 wire bytes per ms on one link
//	ping      every 100 ms, carrying the client's own txstamp
//	RTT       200 ms, so the echo answering the ping at T arrives at T+200
//	delivery  lossless. The ping shares the link's queue with the data, so
//	          everything sent before T has arrived when the ping does: the echo
//	          for stamp T reports rxBytes = sent(T).
type capCleanStep struct {
	relMS    int    // ms after trace start at which the ping went out
	sentAt   uint64 // bytes sent, relative to trace start, at that ping
	rx       uint64 // bytes received, relative to trace start, in the echo for it
	sentNow  uint64 // bytes sent, relative to trace start, when the echo ARRIVES
	arriveMS int    // ms after trace start at which the echo arrives
}

func capCleanTrace(steps int) []capCleanStep {
	// rate = wire bytes per ms, ivalMS = ping cadence, rttMS = echo lag.
	const (
		rate   = 1000
		ivalMS = 100
		rttMS  = 200
	)
	out := make([]capCleanStep, 0, steps)
	for k := 1; k <= steps; k++ {
		t := k * ivalMS
		out = append(out, capCleanStep{
			relMS:    t,
			sentAt:   uint64(rate * t),
			rx:       uint64(rate * t),
			sentNow:  uint64(rate * (t + rttMS)),
			arriveMS: t + rttMS,
		})
	}
	return out
}

// capCleanRate is the trace's delivered rate in bytes per ms. Named so the two
// tests below divide by the same number.
const capCleanRate = 1000.0

// THE test the handover calls the #1 implementation risk. With the cap LATCHED
// -- so the bound is actually being evaluated on every draw -- a clean path at
// sustained load, whose echoes are a full round trip stale, must never close the
// gate. The aligned meter reads no queue because sent-at-the-marker and
// received-at-the-snapshot are the same point in the byte stream.
func TestCapLagAlignedMeterDoesNotLatchUnderCleanSustainedLoad(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()

	// Force the latch with one deficit window so the BOUND is live for the clean
	// phase. Without this the test would pass trivially on the dormant path: an
	// unlatched cap admits without consulting the meter at all.
	const setupSent, setupRx uint64 = 500_000, 100_000
	const setupSrv uint32 = 500
	capFold(c, 0, 900001, 0, 0, 100, 0, base)
	capFold(c, 0, 900002, setupSent, setupRx, setupSrv, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: the deficit window did not latch the cap")
	}

	tr := capCleanTrace(12)
	for k, s := range tr {
		offMS := 400 + s.arriveMS
		now := base.Add(time.Duration(offMS) * time.Millisecond)
		stamp := uint32(1000 + k)
		sentAt := setupSent + s.sentAt
		rx := setupRx + s.rx
		srv := setupSrv + uint32(s.relMS)
		capFold(c, 0, stamp, sentAt, rx, srv, 0, now)
		if !c.Latched(0) {
			t.Fatalf("step %d: the latch cleared, so the bound stopped being tested", k)
		}
		far, ok := c.FarMS(0)
		if !ok {
			t.Fatalf("step %d: no delivered rate measured", k)
		}
		if far >= capTestCfg().TargetMS {
			t.Fatalf("step %d: LATCHED SHUT on a clean path -- far=%.1fms >= target %.1fms. "+
				"That is the un-aligned failure (handover caveat 1) reappearing", k, far, capTestCfg().TargetMS)
		}
		if !c.Admit(0, now) {
			t.Fatalf("step %d: the cap refused a draw on a clean path", k)
		}
	}
	if d, ok := c.DelivBytesPerMs(0); !ok || math.Abs(d-capCleanRate) > 1 {
		t.Fatalf("delivered rate %v (ok=%v), want ~%v bytes/ms", d, ok, capCleanRate)
	}
}

// The same trace through the UN-ALIGNED difference, which is what the code would
// compute if MarkPing did not exist. It must exceed the budget by a wide margin
// -- that is the permanent latch, executed. Without this test the one above
// proves only that some number stayed small.
func TestCapUnalignedDifferenceWouldLatchOnTheSameCleanTrace(t *testing.T) {
	target := capTestCfg().TargetMS
	for k, s := range capCleanTrace(12) {
		bad := unalignedInflight(s.sentNow, s.rx) / capCleanRate
		if bad < target {
			t.Fatalf("step %d: the un-aligned difference read %.1fms, below the %.1fms budget. "+
				"The trace no longer demonstrates the failure the alignment prevents, so the "+
				"aligned test above has lost its control", k, bad, target)
		}
		if bad < 100 {
			t.Fatalf("step %d: un-aligned reading %.1fms is not the ~RTT-sized error the "+
				"mechanism exists for", k, bad)
		}
	}
}

// An echo whose txstamp matches no marker is NOT folded and does NOT fall back to
// sent_cum(now). Falling back is exactly the un-aligned difference.
func TestCapEchoWithNoMarkerIsNotFolded(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	c.MarkPing(0, 111, 1000)
	c.FoldEcho(222, capEchoPayload(700, capRec{id: 0, frames: 1, bytes: 5000}), []uint64{0}, now)
	st := c.Stats(0)
	if st.Unaligned != 1 || st.Folds != 0 {
		t.Fatalf("stats %+v, want exactly one unaligned and no fold", st)
	}
	if _, ok := c.DelivBytesPerMs(0); ok {
		t.Fatal("an unalignable echo produced a delivered rate")
	}
}

// A marker beyond the ring's CURRENT depth is evicted, and an echo answering an
// evicted ping is unalignable rather than mis-aligned against a different ping's
// counter. The depth is no longer a constant: it starts at capMarkersInitial and
// the evicted echo's own span is what deepens it.
func TestCapMarkerRingEvictsTheOldestBeyondItsDepth(t *testing.T) {
	c := newTestCap(t, 1)
	if got := c.Stats(0).Markers; got != capMarkersInitial {
		t.Fatalf("initial depth %d, want capMarkersInitial=%d", got, capMarkersInitial)
	}
	cad := int(PingIval / time.Millisecond)
	for k := 0; k < 8; k++ {
		c.MarkPing(0, uint32(1000+k*cad), uint64(k*1000))
	}
	now := time.Now()
	// The oldest stamp is 7 cadences back and the ring holds one marker.
	c.FoldEcho(1000, capEchoPayload(1, capRec{id: 0, bytes: 1}), []uint64{0}, now)
	st := c.Stats(0)
	if st.Unaligned != 1 || st.Folds != 0 {
		t.Fatalf("an evicted marker did not report as unaligned: %+v", st)
	}
	// ...and this is the fix: the unalignable echo still MEASURED the span and
	// deepened the ring. Discarding it is how the ring stayed silently short.
	if st.SpanMS != int32(7*cad) || st.Grows != 1 || st.Markers != capMarkersInitial+1 {
		t.Fatalf("the evicted echo did not size the ring: %+v", st)
	}
	// The newest marker is still there.
	c.FoldEcho(uint32(1000+7*cad), capEchoPayload(1, capRec{id: 0, bytes: 1}), []uint64{0}, now)
	if c.Stats(0).Folds != 1 {
		t.Fatalf("the newest marker did not align: %+v", c.Stats(0))
	}
}

// capSpanTrace drives one link at a FIXED ping->echo span: a ping every
// PingIval, and in the same step the echo answering the ping sent spanMS ago.
// Everything sent is delivered, so a working meter never latches -- the only
// thing under test is whether an echo can be ALIGNED at all.
func capSpanTrace(c *Cap, spanMS, steps int) {
	cad := int(PingIval / time.Millisecond)
	lag := spanMS / cad
	const perStep = 120_000
	t0 := time.Now()
	for k := 0; k < steps; k++ {
		c.MarkPing(0, uint32(1_000_000+k*cad), uint64(k*perStep))
		if k < lag {
			continue
		}
		now := t0.Add(time.Duration(k) * PingIval)
		c.FoldEcho(uint32(1_000_000+(k-lag)*cad),
			capEchoPayload(uint32(500_000+k*cad),
				capRec{id: 0, bytes: uint64((k - lag) * perStep)}),
			[]uint64{0}, now)
	}
}

// capFixedRingFolds is THE DEFECT, implemented so it can be EXECUTED rather than
// described: the marker ring exactly as round 1 shipped it -- one fixed depth,
// no span measurement, no growth -- driven by the same trace capSpanTrace drives
// through the real meter. Nothing in the datapath calls it; it is scaffolding in
// the same idiom as unalignedInflight.
func capFixedRingFolds(depth, spanMS, steps int) (folds, unaligned int) {
	cad := int(PingIval / time.Millisecond)
	lag := spanMS / cad
	var ring []uint32
	for k := 0; k < steps; k++ {
		ring = append(ring, uint32(1_000_000+k*cad))
		if len(ring) > depth {
			ring = append([]uint32(nil), ring[len(ring)-depth:]...)
		}
		if k < lag {
			continue
		}
		want := uint32(1_000_000 + (k-lag)*cad)
		hit := -1
		for i, ts := range ring {
			if ts == want {
				hit = i
				break
			}
		}
		if hit < 0 {
			unaligned++
			continue
		}
		folds++
		ring = append([]uint32(nil), ring[hit+1:]...)
	}
	return folds, unaligned
}

// B3, THE DEFECT. The ring used to be DeadIval/PingIval+1 = 7 markers = 700 ms
// of ping history, a LIVENESS horizon standing in for a ROUND TRIP. Executed
// here against the old sizing on the same traces the fixed meter is driven with
// below: at spans of 700 / 800 / 1200 ms EVERY echo is unalignable, so the cap
// was enabled and measuring nothing -- silently inert.
//
// The 600 ms row is the boundary that shows where the number came from: the old
// ring worked up to exactly DeadIval and not one cadence past it.
func TestCapFixedDeadIvalRingIsInertAtRealisticSpans(t *testing.T) {
	const steps = 40
	oldDepth := int(DeadIval/PingIval) + 1
	for _, span := range []int{700, 800, 1200} {
		folds, unaligned := capFixedRingFolds(oldDepth, span, steps)
		if folds != 0 || unaligned == 0 {
			t.Fatalf("span %dms: the old fixed ring folded %d / unaligned %d -- the defect "+
				"this unit was reported for is not reproduced", span, folds, unaligned)
		}
	}
	if folds, _ := capFixedRingFolds(oldDepth, int(DeadIval/time.Millisecond), steps); folds == 0 {
		t.Fatalf("the old ring failed at exactly DeadIval too, so DeadIval is not the "+
			"quantity it was sized by: folds=%d", folds)
	}
}

// B3, THE FIX. The same traces through the real meter: the ring measures the
// ping->echo span from the echoes it cannot yet align, deepens itself to
// requiredMarkers(span), and starts folding. The final depth must be exactly
// span/PingIval + 1 -- derived, and containing no chosen number.
func TestCapMarkerRingSizesItselfFromTheMeasuredSpan(t *testing.T) {
	const steps = 40
	cad := int(PingIval / time.Millisecond)
	for _, span := range []int{700, 800, 1200} {
		c := newTestCap(t, 1)
		capSpanTrace(c, span, steps)
		st := c.Stats(0)
		if st.Folds == 0 {
			t.Fatalf("span %dms: still inert, folds=0 unaligned=%d depth=%d",
				span, st.Unaligned, st.Markers)
		}
		if c.Inert(0) {
			t.Fatalf("span %dms: Inert reports true on a link that folded %d", span, st.Folds)
		}
		if st.SpanMS != int32(span) {
			t.Fatalf("span %dms: measured %dms", span, st.SpanMS)
		}
		if want := span/cad + 1; st.Markers != want {
			t.Fatalf("span %dms: ring settled at %d markers, derivation says %d",
				span, st.Markers, want)
		}
		// The convergence cost is real and is one echo per marker: the ring
		// cannot un-evict a marker it has already dropped.
		if st.Unaligned == 0 {
			t.Fatalf("span %dms: no echo was spent converging, so the ring did not grow", span)
		}
	}
}

// Where no span can be measured -- a stamp this link never sent -- nothing grows
// and the cap is doing nothing for that link. That state is REPORTED, not
// silent: it is the difference between the round-1 defect and a known one.
func TestCapInertIsReportedNotSilent(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	c.MarkPing(0, 5000, 1000)
	for k := 0; k < 5; k++ {
		// A stamp NEWER than any ping this link sent: not ours, no span.
		c.FoldEcho(uint32(9000+k), capEchoPayload(uint32(700+k), capRec{id: 0, bytes: 1}),
			[]uint64{0}, now)
	}
	st := c.Stats(0)
	if st.Folds != 0 || st.Unaligned != 5 {
		t.Fatalf("setup: %+v", st)
	}
	if !st.Inert || !c.Inert(0) {
		t.Fatalf("a link that folded nothing does not report inert: %+v", st)
	}
	if st.Grows != 0 || st.Markers != capMarkersInitial {
		t.Fatalf("a foreign stamp sized the ring: %+v", st)
	}
	// A link that IS folding must not report inert, or the signal is worthless.
	c2 := newTestCap(t, 1)
	capSpanTrace(c2, 700, 40)
	if c2.Inert(0) || c2.Stats(0).Inert {
		t.Fatalf("a folding link reports inert: %+v", c2.Stats(0))
	}
}

// ---------------------------------------------------------------------------
// 3. THE THREE WIRE SEMANTICS (server/echo.go)
// ---------------------------------------------------------------------------

// Semantic 1. A counter REGRESSION means the server restarted. The contract is
// explicit that the client must RE-BASELINE and must NOT clamp at zero, because
// a clamp holds a stale, too-large inflight. The failure being prevented is a
// permanently shut cap, so the assertion is that the cap admits afterwards --
// and that the naive difference on the same numbers would not have.
func TestCapServerRestartRebaselinesAndDoesNotLatchShut(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()

	// Build up a real history and latch, so a restart has something to corrupt.
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 4_000_000, 1_000_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	pre := c.Stats(0)

	// The server restarts: its counters go back to zero while the client's sent
	// counter keeps climbing.
	restart := base.Add(500 * time.Millisecond)
	capFold(c, 0, 3, 5_000_000, 20_000, 1500, 0, restart)

	st := c.Stats(0)
	if st.Rebases != pre.Rebases+1 {
		t.Fatalf("regression did not re-baseline: %+v -> %+v", pre, st)
	}
	if c.Latched(0) {
		t.Fatal("the latch survived a re-baseline: it is being held on readings that no longer exist")
	}
	if !c.Admit(0, restart) {
		t.Fatal("LATCHED SHUT across a server restart -- echo.go's caveat, by the other door")
	}
	// What the forbidden difference would have said on the same numbers.
	if bad := unalignedInflight(5_000_000, 20_000); bad < 4_000_000 {
		t.Fatalf("the trace no longer exercises the restart hazard (naive inflight %.0f)", bad)
	}
	// And the meter recovers on the next interval rather than staying dead.
	capFold(c, 0, 4, 5_100_000, 120_000, 1600, 0, restart.Add(100*time.Millisecond))
	if d, ok := c.DelivBytesPerMs(0); !ok || d <= 0 {
		t.Fatalf("the meter did not resume after the re-baseline: %v ok=%v", d, ok)
	}
}

// The very first reading is treated as a baseline for the same reason: there is
// no earlier counter to difference against, and the client may have been sending
// long before the first echo arrived.
func TestCapFirstReadingIsABaselineNotAnInflight(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	capFold(c, 0, 1, 9_000_000, 0, 100, 0, now)
	if _, ok := c.DelivBytesPerMs(0); ok {
		t.Fatal("the first reading produced a rate out of nothing")
	}
	if !c.Admit(0, now) {
		t.Fatal("the first reading closed the gate")
	}
	if c.Stats(0).Rebases != 1 {
		t.Fatalf("the first reading was not counted as a baseline: %+v", c.Stats(0))
	}
}

// Semantic 2a. srvMS is uint32 and WRAPS every ~49.7 days. The interval must be
// differenced as uint32 and read as int32; a naive int64 subtraction gives a
// ~4.29e9 ms denominator once per wrap and reports a delivered rate of about
// zero (echo.go:95-99).
func TestCapSrvMSWrapDoesNotZeroTheDeliveredRate(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	before := uint32(0xFFFFFFC0) // 64 ms short of the wrap
	after := before + 100        // wraps to 0x24
	if after > before {
		t.Fatal("the test's own stamps did not wrap")
	}
	capFold(c, 0, 1, 0, 0, before, 0, now)
	capFold(c, 0, 2, 100_000, 100_000, after, 0, now.Add(100*time.Millisecond))
	d, ok := c.DelivBytesPerMs(0)
	if !ok {
		t.Fatal("no rate across the wrap")
	}
	if math.Abs(d-1000) > 1 {
		t.Fatalf("delivered rate %.3f bytes/ms across the wrap, want ~1000. A naive int64 "+
			"difference gives ~2.3e-5 here", d)
	}
	if c.Stats(0).BadIvals != 0 {
		t.Fatalf("the wrap was mistaken for a bad interval: %+v", c.Stats(0))
	}
}

// Semantic 2b. srvMS is WALL clock, not monotonic (echo.go:89-94). A backward
// NTP step gives no denominator, so the interval is dropped -- and the meter
// re-baselines on the new stamp rather than freezing for the length of the step.
func TestCapSrvMSBackwardsStepIsDroppedNotRated(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	capFold(c, 0, 1, 0, 0, 100_000, 0, now)
	capFold(c, 0, 2, 100_000, 100_000, 100_100, 0, now.Add(100*time.Millisecond))
	if _, ok := c.DelivBytesPerMs(0); !ok {
		t.Fatal("setup: no rate before the step")
	}
	// NTP steps the server back 5 s.
	capFold(c, 0, 3, 200_000, 200_000, 95_100, 0, now.Add(200*time.Millisecond))
	if c.Stats(0).BadIvals != 1 {
		t.Fatalf("the backward step was not counted as a bad interval: %+v", c.Stats(0))
	}
	// The very next echo, on the NEW clock, measures normally: the meter did not
	// freeze for the size of the step.
	capFold(c, 0, 4, 300_000, 300_000, 95_200, 0, now.Add(300*time.Millisecond))
	d, ok := c.DelivBytesPerMs(0)
	if !ok || math.Abs(d-1000) > 1 {
		t.Fatalf("the meter did not resume on the stepped clock: %v ok=%v", d, ok)
	}
}

// Semantic 3. A record for a linkID this client does not meter is IGNORED --
// not an error, no state touched. It can come from a stale peer, a restart or a
// forged frame (echo.go:133-139).
func TestCapUnknownLinkRecordIsIgnored(t *testing.T) {
	c := newTestCap(t, 2)
	now := time.Now()
	c.MarkPing(0, 7, 1000)
	c.MarkPing(1, 7, 2000)
	pay := capEchoPayload(500,
		capRec{id: 0, frames: 1, bytes: 100},
		capRec{id: 9, frames: 1, bytes: 999999}, // never sent on
		capRec{id: 1, frames: 1, bytes: 200},
	)
	n := c.FoldEcho(7, pay, []uint64{0, 0}, now)
	if n != 0 {
		// both known records are first readings, so they baseline and report
		// false; the unknown one must not have been counted either way.
		t.Fatalf("FoldEcho folded %d records, want 0 (two baselines, one ignored)", n)
	}
	if c.Stats(0).Rebases != 1 || c.Stats(1).Rebases != 1 {
		t.Fatalf("known links did not baseline: %+v %+v", c.Stats(0), c.Stats(1))
	}
	if !c.Admit(0, now) || !c.Admit(1, now) {
		t.Fatal("an unknown record closed a gate")
	}
	// And an out-of-range link index cannot panic or affect anything.
	if !c.Admit(9, now) || !c.Admit(-1, now) {
		t.Fatal("Admit outside the link set did not fail open")
	}
}

// A payload whose nrec disagrees with its byte length, or that is shorter than
// the header, folds NOTHING rather than reading past a record boundary. The two
// modules do not share a package, so a layout drift shows up exactly here.
func TestCapFoldEchoRejectsShortAndInconsistentPayloads(t *testing.T) {
	c := newTestCap(t, 1)
	now := time.Now()
	c.MarkPing(0, 5, 0)
	good := capEchoPayload(100, capRec{id: 0, bytes: 10})
	for _, bad := range [][]byte{
		nil,
		{},
		good[:capEchoHdrLen-1],
		good[:len(good)-1], // nrec says 1 record, one byte short
	} {
		if n := c.FoldEcho(5, bad, []uint64{0}, now); n != 0 {
			t.Fatalf("folded %d records from a malformed payload of %d bytes", n, len(bad))
		}
	}
	if st := c.Stats(0); st.Folds != 0 || st.Rebases != 0 {
		t.Fatalf("a malformed payload moved state: %+v", st)
	}
	// The well-formed one still works, so the rejections above were about the
	// malformation and not about the setup.
	if n := c.FoldEcho(5, good, []uint64{0}, now); n != 0 || c.Stats(0).Rebases != 1 {
		t.Fatalf("the well-formed payload did not baseline: n=%d %+v", n, c.Stats(0))
	}
}

// The decoder reads the SERVER's documented layout: nrec at [0], srvMS at [2:6],
// then 18-byte records of {id, rsvd, frames, bytes}. Asserted by folding a
// payload whose fields are all distinct and checking the RATE, which can only
// come out right if srvMS and bytes were read from the right offsets.
func TestCapFoldEchoDecodesTheServerSnapshotFormat(t *testing.T) {
	c := newTestCap(t, 3)
	now := time.Now()
	for _, l := range []int{0, 1, 2} {
		c.MarkPing(l, 42, 0)
	}
	c.FoldEcho(42, capEchoPayload(1_000_000,
		capRec{id: 0, frames: 1, bytes: 0},
		capRec{id: 1, frames: 2, bytes: 0},
		capRec{id: 2, frames: 3, bytes: 0}), []uint64{0, 0, 0}, now)
	for _, l := range []int{0, 1, 2} {
		c.MarkPing(l, 43, 0)
	}
	// 250 ms later on the server clock, each link delivered a different amount.
	c.FoldEcho(43, capEchoPayload(1_000_250,
		capRec{id: 0, frames: 10, bytes: 250_000},
		capRec{id: 1, frames: 20, bytes: 500_000},
		capRec{id: 2, frames: 30, bytes: 750_000}), []uint64{0, 0, 0}, now.Add(250*time.Millisecond))
	want := []float64{1000, 2000, 3000}
	for l, w := range want {
		d, ok := c.DelivBytesPerMs(l)
		if !ok || math.Abs(d-w) > 1 {
			t.Fatalf("link %d: rate %v (ok=%v), want %v bytes/ms", l, d, ok, w)
		}
	}
}

// ---------------------------------------------------------------------------
// 4. THE DETECTOR AND ITS HYSTERESIS
// ---------------------------------------------------------------------------

// The MID signature: the socket took everything (no refusals) and the far end
// delivered less than we sent.
func TestCapDetectorLatchesOnMidDeficit(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatalf("a 0.50 delivered/sent ratio with no local refusals did not latch: %+v", c.Stats(0))
	}
	if c.Stats(0).Latches != 1 {
		t.Fatalf("latch not counted: %+v", c.Stats(0))
	}
}

// The EDGE case, and it is the reason the cap is dormant at the edge BY
// CONSTRUCTION rather than by tuning: the same deficit, but the local socket
// refused writes over the window, so the conjunction excludes it.
func TestCapDetectorDoesNotLatchAtTheEdge(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	// identical deficit to the test above; the only difference is Bpress moving.
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 17, base.Add(400*time.Millisecond))
	if c.Latched(0) {
		t.Fatal("latched at the EDGE: a delivered<sent deficit that came WITH refused writes " +
			"is the local link being the bottleneck, which is what pull already handles")
	}
}

// The asymmetry IS the hysteresis. A well-controlled mid path settles at
// delivered == sent (ratio 1.0), which is neither below Trip nor above Clear, so
// it must HOLD -- staying latched. A symmetric band would release here and
// re-latch on the next deficit, flapping.
func TestCapClearHysteresisHoldsAtUnityRatio(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	// Three consecutive windows at exactly 1.0.
	sent, rx, srv := uint64(1_000_000), uint64(500_000), uint32(1400)
	for k := 0; k < 3; k++ {
		sent += 400_000
		rx += 400_000
		srv += 400
		offMS := 800 + 400*k
		now := base.Add(time.Duration(offMS) * time.Millisecond)
		stamp := uint32(10 + k)
		capFold(c, 0, stamp, sent, rx, srv, 0, now)
		if !c.Latched(0) {
			t.Fatalf("window %d at ratio 1.0 released the latch -- that is the flap the "+
				"asymmetric band exists to prevent", k)
		}
	}
	if c.Stats(0).Clears != 0 {
		t.Fatalf("a hold was counted as a clear: %+v", c.Stats(0))
	}
}

// Release happens when the far end visibly outpaces us, i.e. the bottleneck
// lifted and the queue is draining.
func TestCapClearReleasesWhenFarEndOutpaces(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	// delivered/sent = 400000/100000 = 4.0 > Clear.
	capFold(c, 0, 3, 1_100_000, 900_000, 1800, 0, base.Add(800*time.Millisecond))
	if c.Latched(0) {
		t.Fatalf("a 4.0 ratio did not clear: %+v", c.Stats(0))
	}
	if c.Stats(0).Clears == 0 {
		t.Fatalf("clear not counted: %+v", c.Stats(0))
	}
}

// The other release: the regime genuinely returned to edge, i.e. the local
// socket started refusing writes. A latch built on a mid reading must not
// survive that.
func TestCapLocalCongestionReleasesTheLatch(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	// same deficit ratio, but Bpress moved: the local link is the bottleneck now.
	capFold(c, 0, 3, 2_000_000, 1_000_000, 1800, 5, base.Add(800*time.Millisecond))
	if c.Latched(0) {
		t.Fatal("the latch survived the local socket refusing writes")
	}
}

// An idle window has no evidence in it. Reading its ratio would let an idle path
// clear a latch it never tested, so the latch HOLDS below MinRate.
func TestCapIdleWindowHoldsTheLatch(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	// 400 ms window carrying 100 bytes: 2 kb/s, far below MinRateKbps=500.
	capFold(c, 0, 3, 1_000_100, 500_100, 1800, 0, base.Add(800*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("an idle window cleared the latch on no evidence")
	}
}

// ---------------------------------------------------------------------------
// 5. THE BOUND
// ---------------------------------------------------------------------------

// Unlatched, Admit does not consult anything: the cap is dormant and plain pull
// rules. Asserted with a rate present and a would-be-huge reading available.
func TestCapAdmitIsDormantWhileUnlatched(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	// a real interval, but the ratio is 1.0 so nothing latches.
	capFold(c, 0, 2, 1_000_000, 1_000_000, 1400, 0, base.Add(400*time.Millisecond))
	if c.Latched(0) {
		t.Fatal("setup: unexpectedly latched")
	}
	for k := 0; k < 5; k++ {
		offMS := 400 + k
		if !c.Admit(0, base.Add(time.Duration(offMS)*time.Millisecond)) {
			t.Fatal("an unlatched cap refused a draw")
		}
	}
	if c.Stats(0).Refusals != 0 {
		t.Fatalf("refusals counted while dormant: %+v", c.Stats(0))
	}
}

// While latched, the bound closes the gate once the accumulated downstream
// deficit would take longer than the target to drain at the measured rate.
func TestCapBoundClosesWhenQueueTimeExceedsTarget(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)                                      // baseline
	capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond)) // latch, ratio 0.5
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	// deliv = 50000 bytes / 100 ms = 500 B/ms. One more interval of the same
	// deficit puts 50 000 bytes of queue behind us: 100 ms at 500 B/ms.
	capFold(c, 0, 3, 200_000, 100_000, 1200, 0, base.Add(200*time.Millisecond))
	far, ok := c.FarMS(0)
	if !ok || math.Abs(far-100) > 1 {
		t.Fatalf("far=%v ok=%v, want ~100ms", far, ok)
	}
	if c.Admit(0, base.Add(200*time.Millisecond)) {
		t.Fatalf("the bound admitted at far=%.1fms against a %.1fms target", far, cfg.TargetMS)
	}
	if c.Stats(0).Refusals != 1 {
		t.Fatalf("refusal not counted: %+v", c.Stats(0))
	}
}

// And it re-opens as the queue drains, without needing the latch to clear: the
// bound is continuous, only the detector is sticky.
func TestCapBoundReopensAsTheQueueDrains(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond))
	capFold(c, 0, 3, 200_000, 100_000, 1200, 0, base.Add(200*time.Millisecond))
	if c.Admit(0, base.Add(200*time.Millisecond)) {
		t.Fatal("setup: the bound did not close")
	}
	// The queue drains while the ratio stays inside the HOLD band (0.92..1.5), so
	// the latch survives and this really does test the bound rather than the
	// detector: 120 000 bytes in, 170 000 out => ratio 1.417, queue -50 000.
	capFold(c, 0, 4, 320_000, 270_000, 1300, 0, base.Add(300*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("the latch cleared, so this no longer tests the bound")
	}
	far, ok := c.FarMS(0)
	if !ok || far != 0 {
		t.Fatalf("far=%v ok=%v, want the queue estimate drained to 0", far, ok)
	}
	if !c.Admit(0, base.Add(300*time.Millisecond)) {
		t.Fatal("the bound stayed shut after the queue drained")
	}
}

// The queue estimate is clamped at zero: a queue cannot be negative. This is NOT
// the counter clamp echo.go forbids -- that one is about hiding a server restart
// inside a cumulative difference, and it is tested separately above.
func TestCapQueueEstimateNeverGoesNegative(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond))
	// A long run of intervals where far more comes out than goes in.
	sent, rx, srv := uint64(100_000), uint64(50_000), uint32(1100)
	for k := 0; k < 6; k++ {
		sent += 1_000
		rx += 30_000
		srv += 100
		offMS := 200 + 100*k
		now := base.Add(time.Duration(offMS) * time.Millisecond)
		stamp := uint32(20 + k)
		capFold(c, 0, stamp, sent, rx, srv, 0, now)
		if far, ok := c.FarMS(0); ok && far < 0 {
			t.Fatalf("step %d: negative far-inflight %.3f", k, far)
		}
	}
}

// ---------------------------------------------------------------------------
// 6. ECHO LOSS
// ---------------------------------------------------------------------------

// A lost echo costs nothing: the counters are cumulative, so the next one
// carries the newer total and the meter measures the whole gap.
func TestCapLostEchoIsAbsorbedByTheNextOne(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	// the echoes for stamps 2 and 3 never arrive; 4 does, 300 ms later.
	c.MarkPing(0, 2, 100_000)
	c.MarkPing(0, 3, 200_000)
	capFold(c, 0, 4, 300_000, 300_000, 1300, 0, base.Add(300*time.Millisecond))
	d, ok := c.DelivBytesPerMs(0)
	if !ok || math.Abs(d-1000) > 1 {
		t.Fatalf("rate %v ok=%v across two lost echoes, want ~1000 bytes/ms", d, ok)
	}
	if c.Stats(0).Unaligned != 0 {
		t.Fatalf("a lost echo was mis-counted as unaligned: %+v", c.Stats(0))
	}
}

// SUSTAINED echo loss is different and needs a policy. Once the meter is older
// than DeadIval the cap RELEASES and the link falls back to plain pull. Failing
// closed here would let a broken REVERSE path stop forward traffic -- the same
// class of failure as the permanent latch, by another door.
func TestCapEchoLossFailsOpen(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond))
	capFold(c, 0, 3, 200_000, 100_000, 1200, 0, base.Add(200*time.Millisecond))
	if c.Admit(0, base.Add(200*time.Millisecond)) {
		t.Fatal("setup: the cap is not closed, so fail-open cannot be observed")
	}
	lastFold := base.Add(200 * time.Millisecond)
	justInside := lastFold.Add(DeadIval - time.Millisecond)
	justPast := lastFold.Add(DeadIval + time.Millisecond)
	// still closed just inside the horizon.
	if c.Admit(0, justInside) {
		t.Fatal("released before DeadIval")
	}
	// past it, open, and the latch goes with it.
	if !c.Admit(0, justPast) {
		t.Fatal("a stale meter kept the cap shut")
	}
	if c.Latched(0) {
		t.Fatal("the latch survived the meter going stale")
	}
}

// ---------------------------------------------------------------------------
// 7. N-GENERICITY
// ---------------------------------------------------------------------------

// No index is privileged. The same trace applied to link j of an N-link cap must
// produce the same decisions for every j and every N, and must leave every other
// link untouched.
func TestCapIsNGenericAndPermutationSymmetric(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		for j := 0; j < n; j++ {
			c := newTestCap(t, n)
			base := time.Now()
			capFold(c, j, 1, 0, 0, 1000, 0, base)
			capFold(c, j, 2, 1_000_000, 500_000, 1400, 0, base.Add(400*time.Millisecond))
			if !c.Latched(j) {
				t.Fatalf("N=%d link %d did not latch on the same trace every other link latches on", n, j)
			}
			for k := 0; k < n; k++ {
				if k == j {
					continue
				}
				if c.Latched(k) {
					t.Fatalf("N=%d: folding link %d latched link %d", n, j, k)
				}
				if !c.Admit(k, base.Add(400*time.Millisecond)) {
					t.Fatalf("N=%d: folding link %d closed link %d", n, j, k)
				}
				if st := c.Stats(k); st.Folds != 0 || st.Rebases != 0 {
					t.Fatalf("N=%d: folding link %d moved link %d's counters: %+v", n, j, k, st)
				}
			}
		}
	}
}

// The wire addresses paths with a ONE-BYTE pathID, so a cap wider than that
// could not tell two links apart in an echo record. Refused at construction,
// like pullrun.go refuses to start (pull.go MaxLinks, server/echo.go:8).
func TestCapRefusesMoreLinksThanTheWireCanAddress(t *testing.T) {
	if _, err := NewCap(MaxLinks, capTestCfg()); err != nil {
		t.Fatalf("N=MaxLinks refused: %v", err)
	}
	if _, err := NewCap(MaxLinks+1, capTestCfg()); err == nil {
		t.Fatal("accepted more links than the one-byte pathID space")
	}
}

// ---------------------------------------------------------------------------
// 8. DIAGNOSTICS, AND THE DATAPATH INTEGRATION
// ---------------------------------------------------------------------------

// Each counter moves for its own event and no other. pull.go keeps
// stale/qdrop/retq apart for the same reason: which thing happened is a
// different diagnosis each time.
func TestCapStatsCountersAreDistinct(t *testing.T) {
	c := newTestCap(t, 1)
	base := time.Now()

	c.FoldEcho(999, capEchoPayload(1, capRec{id: 0, bytes: 1}), []uint64{0}, base)
	if st := c.Stats(0); st.Unaligned != 1 || st.Folds != 0 || st.Rebases != 0 || st.BadIvals != 0 {
		t.Fatalf("after an unalignable echo: %+v", st)
	}
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	if st := c.Stats(0); st.Rebases != 1 || st.Folds != 1 || st.BadIvals != 0 {
		t.Fatalf("after the baseline: %+v", st)
	}
	capFold(c, 0, 2, 1_000_000, 500_000, 900, 0, base.Add(400*time.Millisecond))
	if st := c.Stats(0); st.BadIvals != 1 || st.Latches != 0 {
		t.Fatalf("after a backward server clock: %+v", st)
	}
}

// admitWithoutZeroRateGuard is Cap.Admit WITH THE DEADLOCK BREAK DELETED. It is
// a scratch copy in the test file, in the same idiom as unalignedInflight above,
// so that the permanent latch cap.go's guard prevents is EXECUTED rather than
// described. Nothing in the datapath calls it, and it must be kept in step with
// Admit by hand -- which is the point: it is the counterfactual, not a second
// implementation.
func admitWithoutZeroRateGuard(c *Cap, link int, now time.Time) bool {
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.latched {
		return true
	}
	if !l.lastFold.IsZero() && now.Sub(l.lastFold) > DeadIval {
		l.latched = false
		l.queueBytes = 0
		l.haveRate = false
		l.nClear++
		return true
	}
	// cap.go's `if !l.haveRate || l.deliv <= 0 { return true }` is REMOVED here.
	return l.queueBytes/l.deliv < c.cfg.TargetMS
}

// B2. cap.go's zero-rate guard is the ONLY thing between this cap and a
// permanent latch, and it used to be documented as a bootstrap case ("no rate
// yet -- nothing has been measured"). Demonstrated rather than argued:
//
//   - latch the link, leaving a real queue estimate behind it;
//   - then stop admitting, which is what a closed gate DOES. Nothing is sent, so
//     nothing is delivered, so every subsequent interval has dRx = 0 and the
//     measured delivered rate is 0. farMS = queueBytes/0 is +Inf.
//   - echoes keep arriving throughout (pings are not gated by Admit), so
//     lastFold keeps advancing and the DeadIval staleness fail-open NEVER fires;
//     and with nothing sent the detector window falls under MinRateKbps, so
//     evaluate takes the HOLD arm and the latch never clears either.
//
// The guard-less copy refuses on every one of 30 consecutive intervals. The real
// Admit returns true on all 30 -- and does NOT clear the latch, which is correct:
// it breaks the deadlock without pretending the mid regime ended.
func TestCapZeroRateGuardIsWhatPreventsAPermanentLatch(t *testing.T) {
	build := func() (*Cap, time.Time) {
		t.Helper()
		cfg := capTestCfg()
		cfg.DetWindow = PingIval
		cfg.MinRateKbps = 1
		c, err := NewCap(1, cfg)
		if err != nil {
			t.Fatal(err)
		}
		base := time.Now()
		capFold(c, 0, 1, 0, 0, 1000, 0, base)
		capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond))
		capFold(c, 0, 3, 200_000, 100_000, 1200, 0, base.Add(200*time.Millisecond))
		if !c.Latched(0) {
			t.Fatal("setup: no latch")
		}
		if c.Admit(0, base.Add(200*time.Millisecond)) {
			t.Fatal("setup: the gate is open, so the quiet phase would not follow")
		}
		return c, base
	}

	withGuard, wbase := build()
	without, obase := build()

	const quiet = 30
	for k := 0; k < quiet; k++ {
		// A closed gate sends nothing, so sent_cum and rxBytes are both frozen
		// and only the server's clock moves. dSent = dRx = 0 -> deliv = 0.
		srv := uint32(1300 + k*100)
		off := time.Duration(300+k*100) * time.Millisecond
		capFold(withGuard, 0, uint32(4+k), 200_000, 100_000, srv, 0, wbase.Add(off))
		capFold(without, 0, uint32(4+k), 200_000, 100_000, srv, 0, obase.Add(off))

		if d, ok := withGuard.DelivBytesPerMs(0); !ok || d != 0 {
			t.Fatalf("step %d: the quiet phase did not produce a zero delivered rate (%v, %v)",
				k, d, ok)
		}
		if !withGuard.Admit(0, wbase.Add(off)) {
			t.Fatalf("step %d: the guard did not break the deadlock", k)
		}
		if admitWithoutZeroRateGuard(without, 0, obase.Add(off)) {
			t.Fatalf("step %d: the guard-less copy reopened, so this trace does not "+
				"demonstrate the latch the guard prevents", k)
		}
	}

	// Neither escape hatch fired on either copy: the meter is fresh (echoes kept
	// folding) and the detector held. So the guard really is the only exit.
	if !without.Latched(0) {
		t.Fatal("the guard-less copy cleared its latch by some other route")
	}
	if withGuard.Stats(0).Clears != 0 {
		t.Fatalf("something other than the guard released the cap: %+v", withGuard.Stats(0))
	}
	// And the guard does not pretend the regime ended.
	if !withGuard.Latched(0) {
		t.Fatal("the deadlock break cleared the latch; it must only open the gate")
	}
}

// The gate is consulted BEFORE the draw, which is where the oracle consults
// room(). A closed cap must produce NO writes at all -- not a draw-and-return,
// which would burn pool churn and hand the frame around the whole draw set.
func TestPullDriveConsultsTheCapBeforeDrawing(t *testing.T) {
	cfg := capTestCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Times must be near time.Now(): Admit's staleness horizon is measured
	// against the wall clock the datapath uses.
	base := time.Now()
	capFold(c, 0, 1, 0, 0, 1000, 0, base)
	capFold(c, 0, 2, 100_000, 50_000, 1100, 0, base.Add(100*time.Millisecond))
	capFold(c, 0, 3, 200_000, 100_000, 1200, 0, base.Add(200*time.Millisecond))
	if c.Admit(0, time.Now()) {
		t.Fatal("setup: the cap is open, so this cannot test a closed one")
	}

	f := NewPullFIFO()
	sock := newFakeSock(0, nil)
	core := &PullCore{FIFO: f, Links: []*PullLink{
		newPullLinkSock(0, "test0", sock, testDst()),
	}}
	core.SetCap(c)
	for i := 0; i < 5; i++ {
		f.Enqueue([]byte("payload"), time.Now())
	}
	go core.Links[0].Drive(f)

	// KEEP THE METER LIVE FOR THE WHOLE OBSERVATION, and this is not decoration.
	// Drive calls Admit with time.Now(), so the test cannot inject a clock into
	// it. Left alone, "the gate stays shut" would rest on the observation window
	// finishing before Admit's DeadIval staleness fail-open -- a wall-clock race
	// against a shared, loaded runner, decided by scheduling rather than by the
	// property under test. Refreshing an in-deficit reading every half cadence
	// removes the dependence entirely and states a STRONGER claim: the gate stays
	// shut while the deficit is LIVE, not merely while the meter is young enough.
	// The margin is not widened anywhere; the timing input is removed.
	type capQuiet struct {
		ts   uint32
		sent uint64
		rx   uint64
		srv  uint32
	}
	stop := make(chan struct{})
	fin := make(chan capQuiet, 1)
	go func() {
		st := capQuiet{ts: 3, sent: 200_000, rx: 100_000, srv: 1200}
		for {
			select {
			case <-stop:
				fin <- st
				return
			case <-time.After(PingIval / 2):
			}
			st.ts++
			st.sent += 100_000
			st.rx += 50_000
			st.srv += 100
			capFold(c, 0, st.ts, st.sent, st.rx, st.srv, 0, time.Now())
		}
	}()

	// The link parks on the cap gate at PingIval. Give it several cadences.
	time.Sleep(4 * PingIval)
	if got := sock.tries(); got != 0 {
		t.Fatalf("a closed cap still wrote %d frames", got)
	}
	if depth, _, _, drawn, _ := f.Stats(); depth != 5 || drawn != 0 {
		t.Fatalf("a closed cap disturbed the pool: depth=%d drawn=%d", depth, drawn)
	}
	if st := c.Stats(0); st.Clears != 0 {
		t.Fatalf("the gate was held shut by staleness or a clear, not by the bound: %+v", st)
	}

	// Clear it, and the same link drains the same pool.
	close(stop)
	q := <-fin
	time.Sleep(PingIval)
	capFold(c, 0, q.ts+1, q.sent+10_000, q.rx+400_000, q.srv+100, 0, time.Now())
	if c.Latched(0) {
		t.Fatal("the clear did not release the latch")
	}
	if !waitFor(func() bool { return sock.tries() >= 5 }, 2*time.Second) {
		t.Fatalf("after the cap cleared only %d writes happened", sock.tries())
	}
	f.Close()
}

// With the cap OFF -- the shipped default -- the pool still drains through every
// link. This is the regression assertion for the whole unit, and it is stated at
// the strength it actually has: it shows the draw loop still works with a nil
// gate at N in {1,2,3}. It does NOT show that the loop is otherwise identical to
// U7's; the added nil-check is real, it simply can never refuse.
func TestPullDriveIsUnchangedWithTheCapOff(t *testing.T) {
	for _, n := range []int{1, 2, 3} {
		f := NewPullFIFO()
		socks := make([]*fakeSock, n)
		core := &PullCore{FIFO: f}
		for i := 0; i < n; i++ {
			socks[i] = newFakeSock(0, nil)
			core.Links = append(core.Links, newPullLinkSock(i, "test", socks[i], testDst()))
		}
		core.SetCap(nil) // explicit: the OFF state
		const frames = 20
		for i := 0; i < frames; i++ {
			f.Enqueue([]byte("payload"), time.Now())
		}
		core.Start()
		ok := waitFor(func() bool {
			total := 0
			for _, s := range socks {
				total += s.tries()
			}
			return total >= frames
		}, 2*time.Second)
		f.Close()
		if !ok {
			t.Fatalf("N=%d: the pool did not drain with the cap off", n)
		}
	}
}
