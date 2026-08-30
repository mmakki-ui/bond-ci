package main

// ADVERSARIAL VERIFY of U15a (E2b cap). NOT part of the unit. These tests are
// MEASUREMENTS written by an independent reviewer; every one of them models the
// REAL wiring in pullrun.go (N pings per cadence, one echo per ping, EVERY
// link's record in EVERY echo -- server/echo.go) rather than the unit's own
// N=1, zero-lag harness.

import (
	"encoding/binary"
	"testing"
	"time"
)

func advCfg() CapConfig {
	return CapConfig{TargetMS: 40, Trip: 0.92, Clear: 1.5, MinRateKbps: 500,
		DetWindow: 400 * time.Millisecond}
}

// advPayload builds the server echo payload from the documented layout
// (server/echo.go:107-118) without touching the unit's helper.
func advPayload(srvMS uint32, ids []byte, rx []uint64) []byte {
	p := make([]byte, 6+len(ids)*18)
	p[0] = byte(len(ids))
	binary.BigEndian.PutUint32(p[2:6], srvMS)
	for i := range ids {
		o := 6 + i*18
		p[o] = ids[i]
		binary.BigEndian.PutUint64(p[o+2:o+10], rx[i]/1000)
		binary.BigEndian.PutUint64(p[o+10:o+18], rx[i])
	}
	return p
}

// A1. THE REAL WIRING, N in {1,2,3,5}, zero lag, everything delivered.
// pullrun.go sends one ping PER LINK per cadence and the server answers EACH
// with an echo carrying EVERY link's counters. Measure what the PSTAT "unal"
// counter reads on a perfectly healthy path.
func TestAdvRealWiringUnalignedCounterOnAHealthyPath(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5} {
		c, err := NewCap(n, advCfg())
		if err != nil {
			t.Fatal(err)
		}
		cad := int(PingIval / time.Millisecond)
		t0 := time.Now()
		const per = 60000
		ids := make([]byte, n)
		rx := make([]uint64, n)
		for i := 0; i < n; i++ {
			ids[i] = byte(i)
		}
		bp := make([]uint64, n)
		for k := 0; k < 30; k++ {
			ts := uint32(2000000 + k*cad)
			for i := 0; i < n; i++ {
				c.MarkPing(i, ts, uint64(k*per)) // same ms for all N: the common case
			}
			now := t0.Add(time.Duration(k) * PingIval)
			for i := 0; i < n; i++ {
				rx[i] = uint64(k * per)
			}
			// one echo per ping sent -> N echoes, all carrying all N records
			for e := 0; e < n; e++ {
				c.FoldEcho(ts, advPayload(uint32(900000+k*cad+e), ids, rx), bp, now)
			}
		}
		st := c.Stats(0)
		t.Logf("N=%d link0: folds=%d unaligned=%d ratio unal/fold=%.2f latched=%v",
			n, st.Folds, st.Unaligned, float64(st.Unaligned)/float64(st.Folds), st.Latched)
		if n > 1 && st.Unaligned == 0 {
			t.Errorf("N=%d: expected duplicate-echo unaligned inflation, got 0", n)
		}
	}
}

// A2. THE MILLISECOND STRADDLE. pullrun.go takes ts := nowMS() INSIDE the
// per-link loop, so on any cadence where the loop crosses a millisecond the N
// links carry DIFFERENT stamps. The echo answering link 0's ping then aligns to
// nothing on link 1 -- and link 1 has not folded yet, so foldRecord emits the
// operator-facing INERT WARNING on a perfectly healthy path.
func TestAdvMillisecondStraddleFiresTheInertWarning(t *testing.T) {
	c, err := NewCap(2, advCfg())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	c.MarkPing(0, 3000000, 0) // link 0 stamped at T
	c.MarkPing(1, 3000001, 0) // link 1 stamped at T+1: the loop crossed a ms
	ids := []byte{0, 1}
	rx := []uint64{0, 0}
	// link 0's echo comes back first, as it was sent first
	c.FoldEcho(3000000, advPayload(500000, ids, rx), []uint64{0, 0}, now)
	st1 := c.Stats(1)
	t.Logf("link1 after link0's echo: folds=%d unaligned=%d inert=%v span=%dms markers=%d grows=%d",
		st1.Folds, st1.Unaligned, st1.Inert, st1.SpanMS, st1.Markers, st1.Grows)
	if !st1.Inert {
		t.Errorf("expected link 1 to report INERT on a healthy path after one straddled cadence")
	}
	// link 1 does fold from its OWN echo, so the state was transient -- but the
	// WARNING has already been printed, once per link, for good.
	c.FoldEcho(3000001, advPayload(500001, ids, rx), []uint64{0, 0}, now)
	t.Logf("link1 after its own echo: %+v", c.Stats(1))
}

// A3. INERT IS A LIFETIME PREDICATE, NOT A CURRENT-STATE ONE. A link that folds
// once and then never folds again -- every later echo unalignable -- is never
// reported inert, which is exactly the silent-inertness class round 2 says it
// closed.
func TestAdvInertNeverFiresOnALinkThatStopsFolding(t *testing.T) {
	c, err := NewCap(1, advCfg())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	ids := []byte{0}
	rx := []uint64{0}
	c.MarkPing(0, 4000000, 0)
	c.FoldEcho(4000000, advPayload(600000, ids, rx), []uint64{0}, now) // one fold
	for k := 1; k < 200; k++ {
		c.MarkPing(0, uint32(4000000+k*100), uint64(k*1000))
		// every echo answers a ping that is no longer in the ring
		c.FoldEcho(4000000, advPayload(uint32(600000+k*100), ids, rx), []uint64{0},
			now.Add(time.Duration(k)*PingIval))
	}
	st := c.Stats(0)
	t.Logf("folded once then 199 unalignable echoes: folds=%d unaligned=%d INERT=%v",
		st.Folds, st.Unaligned, st.Inert)
	if st.Inert {
		t.Errorf("Inert fired -- the predicate is current-state after all")
	}
}

// A4. THE RATCHET HAS NO UPPER BOUND. measureSpan accepts any stamp between this
// link's FIRST and most recent ping, and mkFirst is the first ping of the whole
// process. So the largest span an echo can claim is the process UPTIME, and
// requiredMarkers(uptime) grows without bound. Growth is one marker per echo and
// EVERY step logs, so the log volume is the sender's echo rate.
func TestAdvRatchetIsBoundedOnlyByProcessUptime(t *testing.T) {
	c, err := NewCap(1, advCfg())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	const first = uint32(5000000)
	cad := int(PingIval / time.Millisecond)
	hour := 3600 * 1000 / cad
	for k := 0; k < hour; k++ {
		c.MarkPing(0, uint32(int(first)+k*cad), uint64(k*1000))
	}
	need := requiredMarkers(int32(3600 * 1000))
	t.Logf("after 1h uptime, requiredMarkers(span=uptime) = %d markers = %d bytes",
		need, need*12)
	ids := []byte{0}
	rx := []uint64{0}
	// 500 echoes all claiming the very first stamp this link ever sent
	for k := 0; k < 500; k++ {
		c.FoldEcho(first, advPayload(uint32(700000+k), ids, rx), []uint64{0}, now)
	}
	st := c.Stats(0)
	t.Logf("after 500 echoes claiming the oldest in-range stamp: markers=%d grows=%d span=%dms",
		st.Markers, st.Grows, st.SpanMS)
	if st.Grows != 500 || st.Markers != capMarkersInitial+500 {
		t.Errorf("growth was not one marker per echo: markers=%d grows=%d", st.Markers, st.Grows)
	}
}

// A5. AN EXIT FROM THE LATCH THAT cap.go's "the exits that DO exist, and they
// are the whole list" DOES NOT LIST: a non-positive srvMS interval. echo.go
// states srvMS is WALL clock and that an NTP step corrupts it. foldRecord turns
// that into a full rebase, which clears the latch and zeroes the queue estimate.
func TestAdvBadSrvMSIntervalClearsTheLatch(t *testing.T) {
	cfg := advCfg()
	cfg.DetWindow = PingIval
	cfg.MinRateKbps = 1
	c, err := NewCap(1, cfg)
	if err != nil {
		t.Fatal(err)
	}
	ids := []byte{0}
	base := time.Now()
	fold := func(ts uint32, sent, rx uint64, srv uint32, at time.Time) {
		c.MarkPing(0, ts, sent)
		c.FoldEcho(ts, advPayload(srv, ids, []uint64{rx}), []uint64{0}, at)
	}
	fold(1, 0, 0, 1000, base)
	fold(2, 100000, 50000, 1100, base.Add(100*time.Millisecond))
	fold(3, 200000, 100000, 1200, base.Add(200*time.Millisecond))
	if !c.Latched(0) {
		t.Fatal("setup: no latch")
	}
	before := c.Stats(0)
	// srvMS does not advance: an NTP step back, or two snapshots in one ms.
	fold(4, 300000, 150000, 1200, base.Add(300*time.Millisecond))
	after := c.Stats(0)
	t.Logf("before: latched=%v clears=%d bad=%d | after a dms<=0 reading: latched=%v clears=%d bad=%d",
		before.Latched, before.Clears, before.BadIvals, after.Latched, after.Clears, after.BadIvals)
	if after.Latched {
		t.Errorf("the latch survived a non-positive srvMS interval")
	}
	if after.BadIvals != before.BadIvals+1 || after.Clears != before.Clears+1 {
		t.Errorf("expected exactly one bad interval and one clear: %+v", after)
	}
}

// A6. THE SPAN MEASUREMENT DIES AT ~24.86 DAYS OF UPTIME. measureSpan requires
// int32(ts - mkFirst) >= 0, and mkFirst is never re-anchored, so once the
// process has been up longer than 2^31 ms every current stamp reads as "older
// than our first ping" and NO span is measurable any more. The ring can then
// never grow again -- and Inert will not report it, because the link has folded
// before (A3).
func TestAdvSpanBecomesUnmeasurableAfterMkFirstWraps(t *testing.T) {
	c, err := NewCap(1, advCfg())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	ids := []byte{0}
	rx := []uint64{0}
	const first = uint32(1000)
	c.MarkPing(0, first, 0)
	// ~24.9 days later, in ms
	late := first + uint32(2150000000)
	c.MarkPing(0, late, 1000000)
	c.MarkPing(0, late+100, 1000100)
	// an echo answering the ping sent 100 ms ago: perfectly ordinary
	c.FoldEcho(late, advPayload(800000, ids, rx), []uint64{0}, now)
	st := c.Stats(0)
	t.Logf("uptime 24.9 days, echo lagged 100ms: span=%dms grows=%d markers=%d folds=%d unaligned=%d",
		st.SpanMS, st.Grows, st.Markers, st.Folds, st.Unaligned)
	if st.SpanMS != 0 {
		t.Errorf("span was still measurable (%d ms) -- the wrap does not bite", st.SpanMS)
	}
}

// A7. THE HEADLINE MEASUREMENT, RE-RUN INDEPENDENTLY. The unit's own B3 trace
// (capSpanTrace) is N=1 and delivers exactly one echo per cadence. This runs the
// SAME question through the real N-link wiring: N pings per cadence sharing a
// stamp, N echoes per cadence, at a fixed ping->echo span. It asserts the ring
// converges to span/PingIval+1 and that folds actually happen.
func TestAdvRingSelfSizesUnderTheRealNLinkWiring(t *testing.T) {
	cad := int(PingIval / time.Millisecond)
	for _, n := range []int{1, 2, 3} {
		for _, span := range []int{700, 800, 1200} {
			c, err := NewCap(n, advCfg())
			if err != nil {
				t.Fatal(err)
			}
			lag := span / cad
			t0 := time.Now()
			ids := make([]byte, n)
			for i := range ids {
				ids[i] = byte(i)
			}
			rx := make([]uint64, n)
			bp := make([]uint64, n)
			const per = 60000
			steps := 60
			for k := 0; k < steps; k++ {
				ts := uint32(6000000 + k*cad)
				for i := 0; i < n; i++ {
					c.MarkPing(i, ts, uint64(k*per))
				}
				if k < lag {
					continue
				}
				now := t0.Add(time.Duration(k) * PingIval)
				old := uint32(6000000 + (k-lag)*cad)
				for i := 0; i < n; i++ {
					rx[i] = uint64((k - lag) * per)
				}
				for e := 0; e < n; e++ {
					c.FoldEcho(old, advPayload(uint32(950000+k*cad+e), ids, rx), bp, now)
				}
			}
			st := c.Stats(n - 1)
			want := span/cad + 1
			t.Logf("N=%d span=%dms link%d: folds=%d unaligned=%d markers=%d (derivation %d) span=%dms inert=%v",
				n, span, n-1, st.Folds, st.Unaligned, st.Markers, want, st.SpanMS, st.Inert)
			if st.Folds == 0 {
				t.Errorf("N=%d span=%dms: still inert under the real wiring", n, span)
			}
			if st.Markers != want {
				t.Errorf("N=%d span=%dms: ring settled at %d, derivation says %d",
					n, span, st.Markers, want)
			}
		}
	}
}
