package main

// =============================================================================
// U9 / EQ-1, ARM B -- the FREE-RUNNING arm.
//
// WHY IT EXISTS.  Arm A (eq1_replay_test.go) supplies the oracle's draw order
// and room() from the trace, so it cannot say anything about pull.go's S1: the
// oracle sorts candidates HUNGRIEST-FIRST on _local_ms, the Go core substitutes
// Go mutex acquisition order, and no trace comparison can adjudicate that -- the
// Go core has no observable counterpart of _local_ms to compare against.
// pull.go RETRACTS the opposite claim in the sentence anchored here --
// pull.go@'named EQ-1 the adjudicator of both' was an EARLIER revision of that
// line, and the register now says it is backwards -- because it cannot be, and
// this file is the honest substitute: it MEASURES THE CONSEQUENCE.
//
// CITATION FORM.  Every citation in this file into the two oracle sources is
// anchored as `<repo-relative path> @"exact source text"`, never as a bare
// file:LINE -- both files MOVE between trees (scripts/check-citations.py
// MOVING_TARGETS).  The ack-clock oracle cited here is
// p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py, spelled in full at
// every anchor because a second file of that name exists at
// p4-bondagg/sim/pull-study/03-reserved-composite/ackclock_sim.py and is NOT
// what these cites mean.
//
// WHAT IT DOES.  It runs the real thing -- N Drive goroutines, the real
// PullFIFO, the real send path -- against fake sockets whose acceptance follows
// the trace's own recorded per-link capacity samples (the C records), converted
// to frames per tick.  Arrivals come from the trace.  Nothing tells any link
// when to draw, so the per-link share that comes out is the Go core's own.  It
// is then compared to the share the oracle produced from the same physics.
//
// THE FAKE IS TWO STAGES, NOT ONE (U9d).  Until this round the fake socket was
// the LOCAL stage alone, clocked by the C records.  That is the whole rig on the
// EDGE arm -- build_rig sets down_cap_fn=lambda t: HUGE there
// (p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// @"backpressure=None, down_cap_fn=lambda t: HUGE,") -- but it is the WRONG
// HALF on the MID arm, where build_rig gives the local stage base*20
// (p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// @"loc = a['base'] * local_mult") and puts the real trace on the downstream
// one (p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// @"down_cap_fn=trace,").  Measured consequence of the
// one-stage fake on n5-het-mid: peak LOCAL occupancy 1-5 ms against a 300 ms
// qmax, zero refusals, zero sheds -- i.e. NOTHING in the harness could ever say
// no, and the share divergence it reported (0.213 here, 0.223 when the row was
// written) was Go mutex round-robin against an oracle that had a bottleneck,
// with the bottleneck missing from one side.  So the fake now carries the
// DOWNSTREAM stage too (eq1DownStage), fed by the Cd records, wired exactly as
// the oracle wires it: stage 1 drains into stage 2's offer, and a stage-2
// refusal is a TAILDROP -- the copy is lost, and stage 2 never pushes back on
// stage 1 (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"exited = s.local[i].drain(lcaps[i], now, s.rng)" through
// p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"delivered = s.down[i].drain(dcaps[i], now, s.rng)", whose stage-2 offer is
// followed by p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"# downstream taildrop = this copy LOST").
//
// That wiring is why the MID assignment number does not move and why that is the
// FINDING rather than a disappointment: when the bottleneck is downstream the
// local socket genuinely never refuses, so pull.go's room() substitution has NO
// signal to work with and the S1 cost is paid in downstream LOSS instead of in
// backpressure.  The run therefore reports TWO shares -- ASSIGNED (what the core
// put on each link) and DELIVERED (what survived stage 2) -- and the second is
// the one that prices S1 in the mid regime.
//
// WHAT IS GATED, AND WHAT IS ONLY REPORTED.
//   GATED -- invariants that hold regardless of goroutine scheduling:
//     * no seq is emitted twice (a peek race would break this)
//     * every emitted seq was enqueued, and none is invented
//     * each link's fseq series is contiguous 0..k-1 with k = its emissions
//     * emitted + shed + residual == enqueued (frame conservation)
//     * THE FAKE DID PHYSICS -- see below.
//     * THE SECOND STAGE DID PHYSICS -- the trace's own rig_tdrop total says
//       whether the ORACLE's stages taildropped; the fake's stage 2 must agree
//       in kind (dropped where the oracle dropped, dropped nothing where it
//       dropped nothing).  Two-sided, both sides read from the trace.
//   REPORTED, NOT GATED -- the per-link share divergence from the oracle.  It
//   is scheduling-dependent by construction, so a threshold on it would be an
//   invented constant.  It is printed so the size of S1 is on the record
//   instead of being argued about.
//
// THE FAKE-DID-PHYSICS BAR, AND WHY THE FIRST FOUR ARE NOT ENOUGH.
// The four invariants above are all satisfied SIMULTANEOUSLY by this arm's own
// retracted v1 harness (banked tokens clocked by the downstream cap, which the
// edge rig sets to HUGE): every frame emitted, nothing shed, nothing stale,
// nothing residual -- conservation holds exactly, fseq is contiguous, no seq is
// duplicated or invented.  That defect was found by READING A REPORTED NUMBER,
// and until now nothing stopped it coming back.  So on any trace whose own X
// totals record that THE ORACLE SHED (i.e. the offered load exceeded what the
// links could carry), this arm now requires the free run to have hit the same
// wall: at least one refusal, at least one shed, and fewer frames emitted than
// enqueued.  Every term is read from the trace; no threshold is invented, and a
// trace where the oracle shed nothing (the mid rig) is exempt because there is
// nothing for it to assert.  TestEQ1FreeRunDetectsV1Fake re-injects the v1 fake
// and requires these bars to kill it.
// =============================================================================

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// eq1StageSock is a FAITHFUL port of ackclock_sim.Stage's admission and drain
// (Stage.offer / Stage.drain, reserved_composite's local stage), used as the fake
// socket. It is the device queue the oracle's own local stage models:
//
//	offer : cap <= 0 or backlog_kb/cap*1000 > qmax  ->  refuse
//	drain : budget = cap*DT + carry; release while budget >= PKT_KB
//
// An earlier revision granted a per-tick token allowance instead. That was wrong
// and the run said so: tokens BANKED across ticks, so no link ever refused, every
// frame was emitted, and the measured shares came out at ~1/N -- Go mutex
// round-robin, not the physics. The number that produced (max|d share| 0.22-0.29)
// measured the fake, not S1, and is retracted.
//
// What is deliberately NOT modelled here is the oracle's room(): its estimator gate
// stops offering at _local_ms >= target_ms (40 ms) while this queue accepts to
// qmax (300 ms). That gap is not a defect in the fake -- it IS the substitution
// pull.go declares, and Arm B exists to size its consequence.
//
// bank is the RETRACTED v1 fake, kept executable as a negative control rather
// than only described in a comment: a token allowance that accumulates across
// ticks and is never checked against a queue. In v1 it was fed the DOWNSTREAM
// cap, which build_rig sets to HUGE on the edge arm, so the allowance was never
// exhausted, no link ever refused and every frame was emitted.
type eq1StageSock struct {
	mu      sync.Mutex
	backlog int
	cap     float64
	carry   float64
	pkt     float64
	dt      float64
	qmax    float64
	peakMs  float64
	refused int
	bank    bool
	tokens  float64
	seqs    []uint32
	fseq    []uint32

	// down is STAGE 2. nil means the one-stage fake this arm shipped before
	// U9d, kept reachable as the "one-stage" mutation below.
	down *eq1DownStage
}

// eq1DownStage is the SECOND stage: ackclock_sim.Stage again, this time the
// DOWNSTREAM one. The oracle builds it at p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"s.down = [Stage(owd_ms=d['down_owd']," and runs it at
// p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"exited = s.local[i].drain(lcaps[i], now, s.rng)" -- stage 1 drains, every
// exited frame is offered to stage 2, then stage 2 drains. Two properties of
// that wiring are load-bearing here and both
// are the oracle's, not a choice of this harness:
//
//   - a stage-2 refusal is a TAILDROP, not backpressure.
//     p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
//     @"if not s.down[i].offer(seq, enq, dcaps[i]):" is followed by nothing
//     but a bare pass, p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
//     @"# downstream taildrop = this copy LOST". Stage 1 drains at its own
//     rate regardless.
//   - therefore the Go core NEVER sees a refusal from this stage. The socket is
//     stage 1. That is exactly the mid-regime exposure U9d exists to price: the
//     bottleneck is somewhere the pull core's one observed signal cannot reach.
//
// qmax is taken from the trace's local_qmax_ms. build_rig gives the mid rig's
// down stage down_qmax=QMAX_MS
// (p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// @"down_qmax=QMAX_MS, spotty=a['spotty']))"), the same constant the local
// stage defaults to (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"def __init__(s, owd_ms=0.0, jit_ms=0.0, qmax_ms=QMAX_MS):"), so on the mid
// arm this is the recorded value. On the EDGE arm build_rig sets down_qmax=HUGE
// (p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// @"down_qmax=HUGE, spotty=a['spotty']))"), and using 300 ms there instead is
// numerically
// indistinguishable: Cd is 1e9 kb/s in every edge trace, 300 ms of it is 3.0e8
// kb = 3.06e7 frames of 9.79 kb, and one 10 ms tick drains 1.0e7 kb -- the queue
// cannot survive a tick, let alone reach the ceiling. The bar below asserts that
// rather than assuming it: on a trace whose rig_tdrop is 0 the fake's stage 2
// must drop nothing.
type eq1DownStage struct {
	backlog   int
	carry     float64
	pkt       float64
	dt        float64
	qmax      float64
	peakMs    float64
	taildrop  int
	delivered int
}

// offer is Stage.offer (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"def offer(s, seq, enq_t, cap):") on the downstream queue, with q_ms's
// cap<=0 -> 1e9 branch (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"return s.backlog_kb / cap * 1000.0 if cap > 0 else 1e9") written out as
// the short circuit.
func (d *eq1DownStage) offer(cap float64) {
	if cap <= 0 || float64(d.backlog)*d.pkt/cap*1000.0 > d.qmax {
		d.taildrop++
		return
	}
	d.backlog++
	if q := float64(d.backlog) * d.pkt / cap * 1000.0; q > d.peakMs {
		d.peakMs = q
	}
}

// drain is Stage.drain (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"def drain(s, cap, now, rng):"): one tick's budget plus the
// carry, release while the budget covers a packet, carry clamped at 0 and reset
// when the queue empties. What leaves here is DELIVERED -- it is past both
// stages, which is what the delivered share is counted from.
func (d *eq1DownStage) drain(cap float64) {
	budget := cap*d.dt + d.carry
	for d.backlog > 0 && budget >= d.pkt-1e-9 {
		d.backlog--
		budget -= d.pkt
		d.delivered++
	}
	d.carry = budget
	if d.carry < 0 || d.backlog == 0 {
		d.carry = 0
	}
}

func (s *eq1StageSock) WriteToUDP(b []byte, _ *net.UDPAddr) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.bank {
		if s.tokens < s.pkt-1e-9 {
			s.refused++
			return 0, &net.OpError{Op: "write", Net: "udp",
				Err: os.NewSyscallError("sendto", syscall.ENOBUFS)}
		}
		s.tokens -= s.pkt
		s.seqs = append(s.seqs, binary.BigEndian.Uint32(b[4:8]))
		s.fseq = append(s.fseq, binary.BigEndian.Uint32(b[12:16]))
		return len(b), nil
	}
	refuse := s.cap <= 0
	if !refuse {
		qms := float64(s.backlog) * s.pkt / s.cap * 1000.0
		refuse = qms > s.qmax
	}
	if refuse {
		s.refused++
		return 0, &net.OpError{Op: "write", Net: "udp",
			Err: os.NewSyscallError("sendto", syscall.ENOBUFS)}
	}
	s.backlog++
	if q := float64(s.backlog) * s.pkt / s.cap * 1000.0; q > s.peakMs {
		s.peakMs = q
	}
	s.seqs = append(s.seqs, binary.BigEndian.Uint32(b[4:8]))
	s.fseq = append(s.fseq, binary.BigEndian.Uint32(b[12:16]))
	return len(b), nil
}

func (s *eq1StageSock) SyscallConn() (syscall.RawConn, error) {
	return nil, errors.New("eq1: no rawconn")
}

// tick advances BOTH stages for one trace tick, in the oracle's own order
// (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"exited = s.local[i].drain(lcaps[i], now, s.rng)" through
// p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
// @"delivered = s.down[i].drain(dcaps[i], now, s.rng)"): set stage 1's
// capacity, drain stage 1, offer every frame that exited into stage 2, then
// drain stage 2. lcap is the C record,
// dcap the Cd record.
func (s *eq1StageSock) tick(lcap, dcap float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cap = lcap
	if s.bank {
		// v1: the allowance accumulates and nothing ever drains a queue.
		s.tokens += lcap * s.dt
		return
	}
	budget := lcap*s.dt + s.carry
	for s.backlog > 0 && budget >= s.pkt-1e-9 {
		s.backlog--
		budget -= s.pkt
		if s.down != nil {
			// A refusal here is a taildrop and NOT backpressure: stage 1 has
			// already let the frame go.
			// p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
			// @"# downstream taildrop = this copy LOST".
			s.down.offer(dcap)
		}
	}
	s.carry = budget
	if s.carry < 0 {
		s.carry = 0
	}
	if s.backlog == 0 {
		s.carry = 0
	}
	if s.down != nil {
		s.down.drain(dcap)
	}
}

// full reports whether this device would refuse right now -- the loop condition
// that lets the driver stop nudging once no link can take another frame.
func (s *eq1StageSock) full() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.bank {
		return s.tokens < s.pkt-1e-9
	}
	if s.cap <= 0 {
		return true
	}
	return float64(s.backlog)*s.pkt/s.cap*1000.0 > s.qmax
}

// eq1FreeTick is one tick of the trace, reduced to what Arm B needs.
type eq1FreeTick struct {
	arrivals []uint32
	caps     []float64
	dcaps    []float64
}

func TestEQ1FreeRunDivergence(t *testing.T) {
	traces := eq1Traces(t)
	if len(traces) == 0 {
		t.Fatalf("eq1: no traces in %s", eq1TraceDir())
	}
	for _, p := range traces {
		eq1FreeRun(t, p, "")
	}
}

// eq1FreeMutations are defects injected into ARM B'S FAKE -- never into pull.go.
// Each one is a harness defect this unit actually shipped and retracted, kept
// executable so the bars that would have caught it are proven to catch it.
var eq1FreeMutations = []struct {
	name string
	what string
}{
	{"v1-fake", "Arm B v1: banked tokens clocked by the DOWNSTREAM cap (HUGE on " +
		"the edge rig) -- no link ever refuses, every frame is emitted, shares ~1/N"},
	{"one-stage", "Arm B v2 (U9d): the LOCAL stage alone, no downstream queue -- " +
		"on the mid rig, where build_rig puts the real capacity on the DOWNSTREAM " +
		"stage and gives the local one base*20, nothing in the fake can ever drop"},
}

// TestEQ1FreeRunDetectsV1Fake is Arm B's negative control. Without it, Arm B's
// gate is four invariants that its own retracted v1 harness satisfied.
//
// The unmutated pass is not re-run here: TestEQ1FreeRunDivergence runs every
// trace unmutated in the same package, and a free run is expensive.
func TestEQ1FreeRunDetectsV1Fake(t *testing.T) {
	traces := eq1Traces(t)
	if len(traces) == 0 {
		t.Fatalf("eq1: no traces in %s", eq1TraceDir())
	}
	for _, m := range eq1FreeMutations {
		caught := ""
		var first error
		for _, p := range traces {
			if err := eq1FreeErr(p, m.name); err != nil {
				caught, first = filepath.Base(p), err
				break
			}
		}
		if caught == "" {
			t.Fatalf("eq1 ARM B NEGATIVE CONTROL FAILED: NO trace in %s detects "+
				"%q (%s). Arm B's gate would pass this arm's own retracted defect.",
				eq1TraceDir(), m.name, m.what)
		}
		t.Logf("eq1 ARM B control: %-8s caught by %-22s -- %s",
			m.name, caught, eq1FirstLine(first.Error()))
	}
}

// eq1FreeErr runs Arm B under a catcher and returns its first failure, or nil.
// Same shape as eq1ReplayErr, same reason.
func eq1FreeErr(path, mutate string) (err error) {
	c := &eq1Catch{}
	defer func() {
		if r := recover(); r != nil {
			if rc, ok := r.(*eq1Catch); ok && rc == c {
				err = errors.New(c.msg)
				return
			}
			panic(r)
		}
	}()
	eq1FreeRun(c, path, mutate)
	return nil
}

func eq1FreeRun(t eq1T, path, mutate string) {
	rc, closeFn := eq1Open(t, path)
	defer closeFn()
	sc := bufio.NewScanner(rc)
	sc.Buffer(make([]byte, 0, 1<<16), 1<<20)

	var meta eq1Meta
	var ticks []eq1FreeTick
	var oracleAsg []int
	var pkt, dt float64
	payloadBytes := 0
	n := 0
	oracleShed := 0
	sawShed := false
	rigTdrop := 0
	sawTdrop := false

	for sc.Scan() {
		line := sc.Text()
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Split(line, "|")
		switch f[0] {
		case "M":
			meta = eq1Meta{kv: map[string]string{}}
			for _, kv := range f[1:] {
				i := strings.IndexByte(kv, '=')
				meta.kv[kv[:i]] = kv[i+1:]
			}
			n = meta.num(t, "n")
			payloadBytes = meta.num(t, "payload_bytes")
			pkt, _ = strconv.ParseFloat(meta.str("pkt_kb"), 64)
			dt = float64(meta.num(t, "dt_ns")) / 1e9
		case "T":
			ticks = append(ticks, eq1FreeTick{})
		case "C":
			// LOCAL stage capacity (trace v2). Cd is the DOWNSTREAM cap and it
			// now clocks stage 2 (U9d); before that it was parsed only so the v1
			// fake -- which wrongly clocked the one queue it had off Cd -- could
			// be reconstructed exactly.
			if len(ticks) == 0 {
				continue
			}
			cur := &ticks[len(ticks)-1]
			for _, v := range f[1:] {
				c, _ := strconv.ParseFloat(v, 64)
				cur.caps = append(cur.caps, c)
			}
		case "Cd":
			if len(ticks) == 0 {
				continue
			}
			cur := &ticks[len(ticks)-1]
			for _, v := range f[1:] {
				c, _ := strconv.ParseFloat(v, 64)
				cur.dcaps = append(cur.dcaps, c)
			}
		case "A":
			s64, _ := strconv.ParseUint(f[1], 10, 32)
			cur := &ticks[len(ticks)-1]
			cur.arrivals = append(cur.arrivals, uint32(s64))
		case "X":
			for _, kv := range f[1:] {
				i := strings.IndexByte(kv, '=')
				switch kv[:i] {
				case "assigned":
					for _, s := range strings.Split(kv[i+1:], ",") {
						v, _ := strconv.Atoi(s)
						oracleAsg = append(oracleAsg, v)
					}
				case "shed":
					oracleShed, _ = strconv.Atoi(kv[i+1:])
					sawShed = true
				case "rig_tdrop":
					// The oracle's OWN taildrops, both stages summed
					// (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
					// @"'tdrop': sum(st.taildrops for st in s.down) + sum(st.taildrops for st in s.local),").
					// The local half is zero in every
					// recorded trace -- room() excludes a link before it can
					// attempt, which is why X carries refused=0 everywhere (see
					// eq1_replay_test.go's header) -- so a nonzero rig_tdrop is
					// the DOWNSTREAM stage and nothing else.
					rigTdrop, _ = strconv.Atoi(kv[i+1:])
					sawTdrop = true
				}
			}
		}
	}
	if n == 0 || len(ticks) == 0 || len(oracleAsg) != n {
		t.Fatalf("eq1 free: %s did not parse (n=%d ticks=%d asg=%d)",
			path, n, len(ticks), len(oracleAsg))
	}

	f := NewPullFIFO()
	f.Trim(time.Now(), 0)
	f.SetMaxBytes(meta.num(t, "pool_max_bytes"))
	qmax, _ := strconv.ParseFloat(meta.str("local_qmax_ms"), 64)
	if qmax <= 0 {
		t.Fatalf("eq1 free: %s has no local_qmax_ms -- re-record it", path)
	}
	if !sawShed {
		t.Fatalf("eq1 free: %s has no shed total -- the bars below are derived "+
			"from it, so it cannot be missing", path)
	}
	if !sawTdrop {
		t.Fatalf("eq1 free: %s has no rig_tdrop total -- the stage-2 bar is "+
			"derived from it, so it cannot be missing", path)
	}
	// twoStage is off for the two harness mutations and on for every real run.
	// v1-fake predates stage 2 and must be reconstructed as it shipped.
	twoStage := mutate != "one-stage" && mutate != "v1-fake"
	socks := make([]*eq1StageSock, n)
	links := make([]*PullLink, n)
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 59402}
	for i := 0; i < n; i++ {
		socks[i] = &eq1StageSock{pkt: pkt, dt: dt, qmax: qmax,
			bank: mutate == "v1-fake"}
		if twoStage {
			socks[i].down = &eq1DownStage{pkt: pkt, dt: dt, qmax: qmax}
		}
		links[i] = newPullLinkSock(i, fmt.Sprintf("eq1f-%d", i), socks[i], dst)
	}
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(l *PullLink) { defer wg.Done(); l.Drive(f) }(links[i])
	}

	enq := 0
	pay := make([]byte, payloadBytes)
	for _, tk := range ticks {
		// Stage 1 is clocked by C, stage 2 by Cd. v1 had one queue and clocked
		// it off Cd; reproduced exactly by handing lcap=Cd to a sock with no
		// stage 2.
		src := tk.caps
		if mutate == "v1-fake" {
			src = tk.dcaps
		}
		for i := 0; i < n && i < len(src); i++ {
			d := 0.0
			if i < len(tk.dcaps) {
				d = tk.dcaps[i]
			}
			socks[i].tick(src[i], d)
		}
		for _, s := range tk.arrivals {
			eq1Payload(pay, s)
			f.Enqueue(pay, time.Now())
			enq++
		}
		// Let the links drain what they can. Bounded: at most this many Wake
		// rounds, so a stalled link can never hang the test.
		for spin := 0; spin < 200; spin++ {
			if eq1PoolLen(f) == 0 || eq1AllFull(socks) {
				break
			}
			f.Wake()
			runtime.Gosched()
		}
	}
	// Final drain, also bounded.
	for spin := 0; spin < 5000; spin++ {
		if eq1PoolLen(f) == 0 || eq1AllFull(socks) {
			break
		}
		f.Wake()
		runtime.Gosched()
	}
	f.Close()
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatalf("eq1 free: %s -- Drive goroutines did not exit after Close", path)
	}

	// ---- gated invariants -------------------------------------------------
	seen := make(map[uint32]int, enq)
	total := 0
	got := make([]int, n)
	for i, s := range socks {
		got[i] = len(s.seqs)
		total += got[i]
		for j, sq := range s.seqs {
			if s.fseq[j] != uint32(j) {
				t.Fatalf("eq1 free: %s link %d emission %d carries fseq %d -- the "+
					"per-link sub-sequence is not contiguous", path, i, j, s.fseq[j])
			}
			if prev, dup := seen[sq]; dup {
				t.Fatalf("eq1 free: %s seq %d emitted twice (links %d and %d) -- "+
					"two drawers took the same frame", path, sq, prev, i)
			}
			seen[sq] = i
			if int(sq) >= enq {
				t.Fatalf("eq1 free: %s emitted seq %d but only %d were enqueued",
					path, sq, enq)
			}
		}
	}
	depth, _, _, _, stale := f.Stats()
	_, _, _, qdrops, _ := f.ByteStats()
	if total+int(qdrops)+int(stale)+depth != enq {
		t.Fatalf("eq1 free: %s FRAME CONSERVATION BROKEN -- emitted %d + qdrops %d "+
			"+ stale %d + residual %d != enqueued %d",
			path, total, qdrops, stale, depth, enq)
	}

	// ---- the fake did physics ---------------------------------------------
	// Conditioned on the trace's own X totals: the oracle shed on this trace, so
	// the offered load exceeded what these links could carry under these
	// capacities. A fake that models the device at all must hit the same wall.
	// Every quantity below comes from the trace or from the run; nothing is a
	// chosen threshold. See the header block: this is the bar the v1 fake would
	// have failed, and TestEQ1FreeRunDetectsV1Fake proves it does.
	refusedTotal := 0
	for _, s := range socks {
		refusedTotal += s.refused
	}
	goShed := int(qdrops) + int(stale)
	if oracleShed > 0 {
		if refusedTotal == 0 {
			t.Fatalf("eq1 free: %s THE FAKE NEVER REFUSED -- the oracle shed %d "+
				"frames on this trace, so its links ran out of room; a device "+
				"model that refuses nothing is not modelling one. This is the v1 "+
				"defect (banked tokens) and its signature",
				path, oracleShed)
		}
		if goShed == 0 {
			t.Fatalf("eq1 free: %s THE POOL NEVER SHED -- the oracle shed %d "+
				"frames under the same arrivals and capacities, and the pool bound "+
				"is the same bound. Nothing pushed back",
				path, oracleShed)
		}
		if total >= enq {
			t.Fatalf("eq1 free: %s EVERY ENQUEUED FRAME WAS EMITTED (%d of %d) -- "+
				"the oracle could place only %d of its arrivals on the same "+
				"capacities. A fake that carries everything measures itself",
				path, total, enq, enq-oracleShed)
		}
	}

	// ---- the SECOND stage did physics (U9d) --------------------------------
	// Conditioned on the trace's own rig_tdrop, exactly as the bar above is
	// conditioned on its shed total. rig_tdrop is the oracle's taildrops over
	// both of ITS stages (p4-bondagg/sim/pull-study/02-ackclock/ackclock_sim.py
	// @"'tdrop': sum(st.taildrops for st in s.down) + sum(st.taildrops for st in s.local),");
	// the local half is zero in every
	// recorded trace, so it is the downstream stage's number. Two-sided:
	// dropped-where-the-oracle-dropped catches a stage 2 that is not there
	// (the "one-stage" mutation, and the harness this arm shipped before U9d);
	// dropped-nothing-where-the-oracle-dropped-nothing catches a stage 2 whose
	// ceiling or clock is wrong on the edge rig, where Cd is HUGE and a correct
	// stage 2 cannot drop a single frame.
	//
	// The bar is NOT conditioned on the fake having a second stage -- that is
	// the defect it is here to catch. A run with down == nil taildrops nothing
	// by construction, which is precisely the "one-stage" signature on a trace
	// whose oracle dropped.
	tdropTotal, delivTotal, downResidual, localResidual := 0, 0, 0, 0
	for _, s := range socks {
		localResidual += s.backlog
		if s.down != nil {
			tdropTotal += s.down.taildrop
			delivTotal += s.down.delivered
			downResidual += s.down.backlog
		}
	}
	if rigTdrop > 0 && tdropTotal == 0 {
		t.Fatalf("eq1 free: %s STAGE 2 NEVER DROPPED (down stage present: %v) -- "+
			"the oracle taildropped %d frames on this trace, so its downstream "+
			"queue overflowed under these Cd samples; a fake whose second stage "+
			"drops nothing is the one-stage fake, and on this rig the one stage it "+
			"has is the base*20 local one that can never fill",
			path, socks[0].down != nil, rigTdrop)
	}
	if rigTdrop == 0 && tdropTotal > 0 {
		t.Fatalf("eq1 free: %s STAGE 2 DROPPED %d WHERE THE ORACLE DROPPED NONE "+
			"-- Cd is unbounded on this rig, so a correct downstream stage "+
			"cannot overflow. Its ceiling or its clock is wrong",
			path, tdropTotal)
	}
	// The fake's own conservation, so the two stages cannot quietly lose frames
	// the way the v1 fake quietly carried them: everything the socket accepted is
	// either delivered past stage 2, taildropped by it, still in stage 2, or
	// still in stage 1 (the run stops clocking the stages after the last tick).
	if twoStage && total != delivTotal+tdropTotal+downResidual+localResidual {
		t.Fatalf("eq1 free: %s TWO-STAGE CONSERVATION BROKEN -- accepted %d != "+
			"delivered %d + taildropped %d + stage2 residual %d + stage1 residual %d",
			path, total, delivTotal, tdropTotal, downResidual, localResidual)
	}

	// ---- reported, not gated ---------------------------------------------
	oTot, gTot := 0, 0
	for i := 0; i < n; i++ {
		oTot += oracleAsg[i]
		gTot += got[i]
	}
	var maxAbs float64
	parts := make([]string, 0, n)
	for i := 0; i < n; i++ {
		os_ := 0.0
		if oTot > 0 {
			os_ = float64(oracleAsg[i]) / float64(oTot)
		}
		gs := 0.0
		if gTot > 0 {
			gs = float64(got[i]) / float64(gTot)
		}
		d := math.Abs(gs - os_)
		if d > maxAbs {
			maxAbs = d
		}
		parts = append(parts, fmt.Sprintf("L%d %.3f/%.3f", i, os_, gs))
	}
	// The DELIVERED share: what came out of stage 2, which on the mid rig is
	// where the capacity actually is. It is compared to the oracle's ASSIGNED
	// share because that is all the trace carries per link -- the oracle's own
	// per-link deliveries are not recorded, only rig_tdrop in total -- so this
	// number is oracle-ASSIGNED against go-DELIVERED and is stated that way.
	// It is REPORTED, not gated, for the same reason as the assigned share.
	var maxAbsD float64
	dparts := make([]string, 0, n)
	if twoStage {
		dTot := 0
		for i := 0; i < n; i++ {
			dTot += socks[i].down.delivered
		}
		for i := 0; i < n; i++ {
			os_ := 0.0
			if oTot > 0 {
				os_ = float64(oracleAsg[i]) / float64(oTot)
			}
			ds := 0.0
			if dTot > 0 {
				ds = float64(socks[i].down.delivered) / float64(dTot)
			}
			if d := math.Abs(ds - os_); d > maxAbsD {
				maxAbsD = d
			}
			dparts = append(dparts, fmt.Sprintf("L%d %.3f/%.3f", i, os_, ds))
		}
	}
	// The room() substitution's cost, measured rather than argued: the oracle
	// stops offering a link at target_ms; the socket-gated core fills the device
	// queue toward qmax. peak device occupancy is what that costs in latency.
	tgt, _ := strconv.ParseFloat(meta.str("target_ms"), 64)
	peaks := make([]string, 0, n)
	dpeaks := make([]string, 0, n)
	for i := 0; i < n; i++ {
		peaks = append(peaks, fmt.Sprintf("L%d %.0fms", i, socks[i].peakMs))
		if twoStage {
			dpeaks = append(dpeaks, fmt.Sprintf("L%d %.0fms", i, socks[i].down.peakMs))
		}
	}
	t.Logf("EQ-1 ARM B %s: enq=%d oracle-placed=%d oracle-shed=%d | go-emitted=%d "+
		"go-shed=%d go-refused=%d go-residual=%d", path, enq, oTot, oracleShed,
		gTot, goShed, refusedTotal, depth)
	t.Logf("   S1 draw order -- ASSIGNED share oracle/go: %s  max|d share|=%.3f",
		strings.Join(parts, " "), maxAbs)
	t.Logf("   STAGE 1 (LOCAL, clocked by C) -- room() substitution: oracle gate "+
		"%.0fms, device qmax %.0fms, go peak occupancy: %s",
		tgt, qmax, strings.Join(peaks, " "))
	if twoStage {
		t.Logf("   STAGE 2 (DOWNSTREAM, clocked by Cd) -- qmax %.0fms, oracle "+
			"rig_tdrop=%d, go taildrop=%d delivered=%d stage2-residual=%d "+
			"stage1-residual=%d, peak occupancy: %s", qmax, rigTdrop, tdropTotal,
			delivTotal, downResidual, localResidual, strings.Join(dpeaks, " "))
		t.Logf("   S1 draw order -- DELIVERED share (post stage-2) oracle-assigned/"+
			"go-delivered: %s  max|d share|=%.3f",
			strings.Join(dparts, " "), maxAbsD)
	}
}

// eq1AllFull is the driver's stop condition for a tick: every device queue would
// refuse, so nudging further only spins.
func eq1AllFull(socks []*eq1StageSock) bool {
	for _, s := range socks {
		if !s.full() {
			return false
		}
	}
	return true
}
