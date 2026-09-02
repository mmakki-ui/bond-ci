package main

// =============================================================================
// U9 / EQ-1, ARM B -- the FREE-RUNNING arm.
//
// WHY IT EXISTS.  Arm A (eq1_replay_test.go) supplies the oracle's draw order
// and room() from the trace, so it cannot say anything about pull.go's S1: the
// oracle sorts candidates HUNGRIEST-FIRST on _local_ms, the Go core substitutes
// Go mutex acquisition order, and no trace comparison can adjudicate that -- the
// Go core has no observable counterpart of _local_ms to compare against.
// pull.go@'is the adjudicator for S1 and S2' -- it cannot be, and this file is
// the honest substitute: it MEASURES THE CONSEQUENCE.
//
// WHAT IT DOES.  It runs the real thing -- N Drive goroutines, the real
// PullFIFO, the real send path -- against fake sockets whose acceptance follows
// the trace's own recorded per-link capacity samples (the C records), converted
// to frames per tick.  Arrivals come from the trace.  Nothing tells any link
// when to draw, so the per-link share that comes out is the Go core's own.  It
// is then compared to the share the oracle produced from the same physics.
//
// WHAT IS GATED, AND WHAT IS ONLY REPORTED.
//   GATED -- invariants that hold regardless of goroutine scheduling:
//     * no seq is emitted twice (a peek race would break this)
//     * every emitted seq was enqueued, and none is invented
//     * each link's fseq series is contiguous 0..k-1 with k = its emissions
//     * emitted + shed + residual == enqueued (frame conservation)
//     * THE FAKE DID PHYSICS -- see below.
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

// tick sets this tick's capacity and drains the device queue, exactly as
// Stage.drain does, including the carry and the reset-on-empty.
func (s *eq1StageSock) tick(cap float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cap = cap
	if s.bank {
		// v1: the allowance accumulates and nothing ever drains a queue.
		s.tokens += cap * s.dt
		return
	}
	budget := cap*s.dt + s.carry
	for s.backlog > 0 && budget >= s.pkt-1e-9 {
		s.backlog--
		budget -= s.pkt
	}
	s.carry = budget
	if s.carry < 0 {
		s.carry = 0
	}
	if s.backlog == 0 {
		s.carry = 0
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
			// LOCAL stage capacity (trace v2). Cd is the downstream cap and is
			// deliberately NOT used: in the edge rig it is HUGE, which is what
			// made the first Arm B run report a 0 ms peak on every link. It is
			// parsed only so the v1 fake can be reconstructed exactly.
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
	socks := make([]*eq1StageSock, n)
	links := make([]*PullLink, n)
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 59402}
	for i := 0; i < n; i++ {
		socks[i] = &eq1StageSock{pkt: pkt, dt: dt, qmax: qmax,
			bank: mutate == "v1-fake"}
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
		// v1 clocked the fake off Cd, the DOWNSTREAM cap. Reproduced exactly.
		src := tk.caps
		if mutate == "v1-fake" {
			src = tk.dcaps
		}
		for i := 0; i < n && i < len(src); i++ {
			socks[i].tick(src[i])
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
	// The room() substitution's cost, measured rather than argued: the oracle
	// stops offering a link at target_ms; the socket-gated core fills the device
	// queue toward qmax. peak device occupancy is what that costs in latency.
	tgt, _ := strconv.ParseFloat(meta.str("target_ms"), 64)
	peaks := make([]string, 0, n)
	for i := 0; i < n; i++ {
		peaks = append(peaks, fmt.Sprintf("L%d %.0fms", i, socks[i].peakMs))
	}
	t.Logf("EQ-1 ARM B %s: enq=%d oracle-placed=%d oracle-shed=%d | go-emitted=%d "+
		"go-shed=%d go-refused=%d go-residual=%d", path, enq, oTot, oracleShed,
		gTot, goShed, refusedTotal, depth)
	t.Logf("   S1 draw order -- share oracle/go: %s  max|d share|=%.3f",
		strings.Join(parts, " "), maxAbs)
	t.Logf("   room() substitution -- oracle gate %.0fms, device qmax %.0fms, "+
		"go peak device occupancy: %s", tgt, qmax, strings.Join(peaks, " "))
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
