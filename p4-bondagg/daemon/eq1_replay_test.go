package main

// =============================================================================
// U9 / EQ-1 -- TRACE EQUIVALENCE against the two-stage rig (ADR-004 condition 1).
//
// The trace format, what it has to contain, and the exact scope of the claim are
// specified in p4-bondagg/sim/eq1/README.md. The short version:
//
//   The oracle (reserved_composite.SimD, sched='pull') and this pull core do not
//   share a state space -- one is a single-threaded fixed-tick fluid simulator
//   whose admission gate is a backlog/drain-rate ESTIMATE, the other is N
//   goroutines whose gate is a socket refusing a write. So the trace SUPPLIES
//   the parts that cannot be compared (draw order, room()) and COMPARES the
//   parts that can (the emitted wire bytes, the pool, the shed set).
//
//   Compared byte-wise: every emitted frame, in order, as the bytes the socket
//   received, with header[8:12] masked because it is time.Now(). That covers
//   magic, ver, flags, pathID, rsvd, seq32, fseq32 and the entire 1208-byte
//   body. The whole emission stream is reduced to one sha256 which the trace
//   carries, computed on the Python side from the oracle's own decisions and an
//   INDEPENDENT implementation of the frame.go layout.
//
//   NOT compared: draw order (S1), room(), the pool bound's AGE limb (the oracle
//   has none -- the replay runs maxAge=0), the in-flight bound understatement
//   (S2a, no oracle counterpart), and everything downstream of the send.
//
// The refusal path has no oracle counterpart either -- the oracle's `Stage.offer`
// refused zero times in every trace recorded, because room() excludes a link
// BEFORE it can attempt. EQ-1 tests the Go rollback as a TRANSPARENCY property
// instead: the trace's R records name the links the oracle had excluded when its
// draw loop stopped, the replay makes each of them draw and be refused, and the
// emitted stream must come out bit-identical. A rollback that pushed to the
// tail, dropped the frame, or burned an fseq changes the stream and fails.
// =============================================================================

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// eq1Sock is the seam fake: a linkSocket whose acceptance is dictated by the
// replay driver. It records the exact bytes handed to it.
type eq1Sock struct {
	refuse bool
	last   []byte
}

func (s *eq1Sock) WriteToUDP(b []byte, _ *net.UDPAddr) (int, error) {
	if s.refuse {
		// The class the pull core exists to recognise: a full device queue.
		return 0, &net.OpError{Op: "write", Net: "udp",
			Err: os.NewSyscallError("sendto", syscall.ENOBUFS)}
	}
	s.last = append(s.last[:0], b...)
	return len(b), nil
}

func (s *eq1Sock) SyscallConn() (syscall.RawConn, error) {
	return nil, errors.New("eq1: no rawconn")
}

// eq1T is what the replay reports through. *testing.T satisfies it; so does
// eq1Catch, which is how the negative control (TestEQ1ReplayDetectsDivergence)
// runs the replay and expects it to FAIL. Without that control the only evidence
// the Go comparison has teeth would be "it went green", which is not evidence.
type eq1T interface {
	Fatalf(format string, args ...interface{})
	Logf(format string, args ...interface{})
	Helper()
}

// eq1Catch records the first Fatalf and unwinds by panicking with itself, which
// eq1ReplayErr recovers. It is the standard way to make a Fatalf-shaped helper
// testable without duplicating it.
type eq1Catch struct{ msg string }

func (c *eq1Catch) Fatalf(format string, args ...interface{}) {
	c.msg = fmt.Sprintf(format, args...)
	panic(c)
}

func (c *eq1Catch) Logf(string, ...interface{}) {}

func (c *eq1Catch) Helper() {}

// eq1ReplayErr runs the replay under a catcher and returns the first failure, or
// nil. mutate names a deliberate defect injected into the REPLAY DRIVER (never
// into pull.go) so that the control measures whether each comparison point is
// live.
func eq1ReplayErr(path, mutate string) (err error) {
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
	eq1ReplayMut(c, path, mutate)
	return nil
}

// eq1Meta is the trace header.
type eq1Meta struct {
	kv map[string]string
}

func (m eq1Meta) str(k string) string { return m.kv[k] }

func (m eq1Meta) num(t eq1T, k string) int {
	t.Helper()
	v, err := strconv.Atoi(m.kv[k])
	if err != nil {
		t.Fatalf("eq1: header key %q is not an integer (%q)", k, m.kv[k])
	}
	return v
}

// eq1Payload builds the body of frame seq: byte j is (seq*31 + j) & 0xFF. The
// recorder builds the identical bytes, so a body attached to the wrong seq is a
// byte mismatch rather than an invisible swap.
func eq1Payload(dst []byte, seq uint32) {
	off := byte(seq * 31)
	for j := range dst {
		dst[j] = off + byte(j)
	}
}

// eq1PoolDigest hashes the pool's seq list, in order, exactly as the recorder
// hashes the oracle's fifo. Truncated to 16 bytes / 32 hex chars, matching.
func eq1PoolDigest(f *PullFIFO) (int, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	h := sha256.New()
	var b [4]byte
	for i := 0; i < f.n; i++ {
		binary.BigEndian.PutUint32(b[:], f.ring[(f.head+i)%len(f.ring)].seq)
		h.Write(b[:])
	}
	return f.n, hex.EncodeToString(h.Sum(nil))[:32]
}

func eq1PoolLen(f *PullFIFO) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.n
}

func eq1Open(t eq1T, path string) (io.ReadCloser, func()) {
	t.Helper()
	fh, err := os.Open(path)
	if err != nil {
		t.Fatalf("eq1: open %s: %v", path, err)
	}
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(fh)
		if err != nil {
			fh.Close()
			t.Fatalf("eq1: gzip %s: %v", path, err)
		}
		return gz, func() { gz.Close(); fh.Close() }
	}
	return fh, func() { fh.Close() }
}

func eq1TraceDir() string {
	if d := os.Getenv("EQ1_TRACE_DIR"); d != "" {
		return d
	}
	return filepath.Join("..", "sim", "eq1", "traces")
}

func eq1Traces(t eq1T) []string {
	t.Helper()
	dir := eq1TraceDir()
	var out []string
	for _, pat := range []string{"*.eq1", "*.eq1.gz"} {
		m, err := filepath.Glob(filepath.Join(dir, pat))
		if err != nil {
			t.Fatalf("eq1: glob: %v", err)
		}
		out = append(out, m...)
	}
	sort.Strings(out)
	return out
}

// TestEQ1TraceEquivalence is the gate. It fails if no trace is present: an
// equivalence test that silently tests nothing is worse than no test, and this
// one has a committed fixture precisely so it can never degrade to a skip.
func TestEQ1TraceEquivalence(t *testing.T) {
	traces := eq1Traces(t)
	if len(traces) == 0 {
		t.Fatalf("eq1: no traces in %s -- EQ-1 cannot pass vacuously. "+
			"Record one with p4-bondagg/sim/eq1/eq1_record.py", eq1TraceDir())
	}
	// No t.Run. The `go` job's test-count ratchet counts `=== RUN` lines and
	// its comment states the daemon package has no subtests; adding one would
	// silently inflate that count and invalidate the ratchet's own reasoning.
	for _, p := range traces {
		eq1ReplayMut(t, p, "")
	}
}

// eq1Mutations are defects injected into the REPLAY DRIVER -- never into pull.go
// -- each aimed at ONE comparison point, so that a comparison point which has
// silently gone dead shows up as a mutation that is no longer detected.
//
// This exists because the Python kill matrix (eq1_selfcheck.py --mutate-all)
// proves the TRACE contains enough to detect a defect. That is a different claim
// from "the Go comparison would report it", and conflating the two is exactly the
// vacuity this project keeps finding in its own gates.
var eq1Mutations = []struct {
	name string
	what string
}{
	{"no-return", "a refused frame is not returned to the pool -> pool digest"},
	{"no-bound", "the pool byte bound is disabled -> pool digest and shed count"},
	{"zero-pathid", "pathID is zeroed on the wire -> the pathID assertion"},
	{"zero-fseq", "fseq is zeroed on the wire -> the fseq assertion"},
	{"flip-body", "one payload byte is flipped -> ONLY the emission digest sees it"},
	// Not a defect in the comparison -- a defect in the PIN. It perturbs the
	// tree sha the header is checked against, so a replay that still passes
	// proves nobody reads the pin. That was literally true in round 1.
	{"oracle-pin", "the tree oracle drifts from the one the trace recorded -> the pin"},
}

func TestEQ1ReplayDetectsDivergence(t *testing.T) {
	traces := eq1Traces(t)
	if len(traces) == 0 {
		t.Fatalf("eq1: no traces in %s", eq1TraceDir())
	}
	// SET-LEVEL, exactly like eq1_selfcheck.py --mutate-all, and for a reason the
	// first run of this control demonstrated: it originally used traces[0] alone
	// and failed, reporting that "zero-pathid" replayed CLEAN. That was correct.
	// traces[0] is the N=1 fixture, where pathID is already 0, so zeroing it
	// changes nothing -- the trace is genuinely blind to that mutation and the
	// Python matrix says the same. A mutation must be caught by SOME trace; per
	// trace blindness is a property of the trace, not of the comparison.
	for _, m := range eq1Mutations {
		caught := ""
		var first error
		for _, p := range traces {
			if err := eq1ReplayErr(p, m.name); err != nil {
				caught, first = filepath.Base(p), err
				break
			}
		}
		if caught == "" {
			t.Fatalf("eq1 NEGATIVE CONTROL FAILED: NO trace in %s detects the %q "+
				"defect (%s). The comparison is blind to it.",
				eq1TraceDir(), m.name, m.what)
		}
		t.Logf("eq1 control: %-12s caught by %-22s -- %s",
			m.name, caught, eq1FirstLine(first.Error()))
	}
	// And every unmutated replay must still pass, or the controls prove nothing.
	for _, p := range traces {
		if err := eq1ReplayErr(p, ""); err != nil {
			t.Fatalf("eq1: unmutated replay of %s failed: %v", p, err)
		}
	}
}

func eq1FirstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	if len(s) > 110 {
		return s[:110]
	}
	return s
}

type eq1State struct {
	meta eq1Meta
	n    int

	fifo     *PullFIFO
	links    []*PullLink
	socks    []*eq1Sock
	out      []byte
	assigned []int

	arrivals int
	placed   int
	refused  int
	injected int
	skipped  int
	shed     int
	tick     int
	tickShed int
	lastQd   uint64

	now  time.Time
	base time.Time

	mutate string
}

func eq1ReplayMut(t eq1T, path, mutate string) {
	rc, closeFn := eq1Open(t, path)
	defer closeFn()

	sc := bufio.NewScanner(rc)
	sc.Buffer(make([]byte, 0, 1<<16), 1<<20)

	bodyH := sha256.New()
	emisH := sha256.New()

	var st eq1State
	st.mutate = mutate
	var trailer string
	var totals map[string]string
	frame := make([]byte, 0, 2048)

	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "E|") {
			trailer = line[2:]
			break
		}
		bodyH.Write([]byte(line))
		bodyH.Write([]byte{'\n'})
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Split(line, "|")
		switch f[0] {
		case "V":
			if f[1] != "2" {
				t.Fatalf("eq1: trace version %q, this replay speaks 2", f[1])
			}
		case "M":
			st.meta = eq1Meta{kv: map[string]string{}}
			for _, kv := range f[1:] {
				i := strings.IndexByte(kv, '=')
				st.meta.kv[kv[:i]] = kv[i+1:]
			}
			eq1Init(t, &st)
		case "L":
			// Link descriptor: audit data. N comes from the header and the
			// count of these is checked against it below.
		case "C", "Cd":
			// Per-link capacity samples: audit data. The core consumes no rate.
		case "T":
			eq1TickBoundary(t, &st)
			st.tick, _ = strconv.Atoi(f[1])
			ns, _ := strconv.ParseInt(f[2], 10, 64)
			st.now = st.base.Add(time.Duration(ns))
		case "A":
			seq64, _ := strconv.ParseUint(f[1], 10, 32)
			want := uint32(seq64)
			p := make([]byte, st.meta.num(t, "payload_bytes"))
			eq1Payload(p, want)
			got := st.fifo.Enqueue(p, st.now)
			if got != want {
				t.Fatalf("eq1 tick %d: Enqueue stamped seq %d, oracle stamped %d",
					st.tick, got, want)
			}
			st.arrivals++
		case "S":
			st.tickShed++
		case "D":
			idx, _ := strconv.Atoi(f[1])
			seq64, _ := strconv.ParseUint(f[2], 10, 32)
			seq := uint32(seq64)
			if f[3] == "a" {
				fs64, _ := strconv.ParseUint(f[4], 10, 32)
				frame = eq1Draw(t, &st, idx, seq, false, frame[:0])
				switch st.mutate {
				case "zero-pathid":
					frame[2] = 0
				case "zero-fseq":
					frame[12], frame[13], frame[14], frame[15] = 0, 0, 0, 0
				case "flip-body":
					frame[HdrLen] ^= 0xFF
				}
				eq1CheckFrame(t, &st, idx, seq, uint32(fs64), frame)
				emisH.Write(frame)
				st.placed++
				st.assigned[idx]++
			} else {
				eq1Draw(t, &st, idx, seq, true, nil)
				st.refused++
			}
		case "R":
			if len(f) > 1 && f[1] != "" {
				for _, s := range strings.Split(f[1], ",") {
					idx, _ := strconv.Atoi(s)
					if eq1PoolLen(st.fifo) == 0 {
						st.skipped++
						continue
					}
					eq1Draw(t, &st, idx, 0, true, nil)
					st.injected++
				}
			}
		case "P":
			wantN, _ := strconv.Atoi(f[2])
			gotN, gotD := eq1PoolDigest(st.fifo)
			if gotN != wantN || gotD != f[3] {
				t.Fatalf("eq1 tick %s: POOL DIVERGED -- oracle depth=%d digest=%s, "+
					"go depth=%d digest=%s", f[1], wantN, f[3], gotN, gotD)
			}
		case "X":
			totals = map[string]string{}
			for _, kv := range f[1:] {
				i := strings.IndexByte(kv, '=')
				totals[kv[:i]] = kv[i+1:]
			}
		default:
			t.Fatalf("eq1: unknown record %q", f[0])
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("eq1: read: %v", err)
	}
	if st.fifo == nil {
		t.Fatalf("eq1: trace had no M header")
	}
	if totals == nil {
		t.Fatalf("eq1: trace had no X totals line -- it is truncated")
	}
	eq1TickBoundary(t, &st)

	if got := hex.EncodeToString(bodyH.Sum(nil)); got != trailer {
		t.Fatalf("eq1: trace body sha256 %s != trailer %s -- the trace is corrupt",
			got, trailer)
	}

	// ---- the comparison ---------------------------------------------------
	if got := hex.EncodeToString(emisH.Sum(nil)); got != totals["emission_sha256"] {
		t.Fatalf("eq1: EMISSION STREAM DIVERGED\n  oracle sha256 %s\n  go     sha256 %s\n"+
			"  (%d frames compared byte-wise, header[8:12] masked)",
			totals["emission_sha256"], got, st.placed)
	}
	eq1WantInt(t, "arrivals", st.arrivals, totals["arrivals"])
	eq1WantInt(t, "placed", st.placed, totals["placed"])
	eq1WantInt(t, "refused", st.refused, totals["refused"])
	eq1WantInt(t, "shed", st.shed, totals["shed"])

	wantAsg := strings.Split(totals["assigned"], ",")
	if len(wantAsg) != st.n {
		t.Fatalf("eq1: assigned list has %d entries, N=%d", len(wantAsg), st.n)
	}
	for i, w := range wantAsg {
		eq1WantInt(t, fmt.Sprintf("assigned[%d]", i), st.assigned[i], w)
		// fseq is the per-link ACCEPT ordinal and nothing else: a refused write
		// must not burn one, or the peer's loss meter reads a gap that never
		// happened. Checked against the oracle's own per-link placement count.
		if int(st.links[i].fseq) != st.assigned[i] {
			t.Fatalf("eq1: link %d fseq=%d but %d frames were placed on it -- "+
				"a refusal burned an fseq", i, st.links[i].fseq, st.assigned[i])
		}
	}

	t.Logf("EQ-1 %s: N=%d ticks=%d arrivals=%d placed=%d shed=%d "+
		"refusals-injected=%d (skipped-empty=%d) emission=%s",
		filepath.Base(path), st.n, st.tick+1, st.arrivals, st.placed, st.shed,
		st.injected, st.skipped, totals["emission_sha256"][:16])
}

func eq1WantInt(t eq1T, what string, got int, want string) {
	t.Helper()
	w, err := strconv.Atoi(want)
	if err != nil {
		t.Fatalf("eq1: totals %s=%q is not an integer", what, want)
	}
	if got != w {
		t.Fatalf("eq1: %s -- oracle %d, go %d", what, w, got)
	}
}

// eq1OracleDir is where the pinned oracle lives, relative to this package.
func eq1OracleDir() string {
	if d := os.Getenv("EQ1_ORACLE_DIR"); d != "" {
		return d
	}
	return filepath.Join("..", "sim")
}

func eq1FileSHA(path string) (string, error) {
	fh, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer fh.Close()
	h := sha256.New()
	if _, err := io.Copy(h, fh); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// eq1OraclePin ENFORCES the header pin.
//
// eq1_record.py records the sha256 of the three oracle files it loaded and says
// in its own header comment that a replay whose shas do not match the tree is
// void. Round 1 recorded that and never read it, which is the same as not having
// it: the committed fixtures' pin was ALREADY stale on the merge target -- U35
// rewrote reserved_composite.py's header the same day -- and this gate plus the
// `go` job both stayed green. A trace is a recording of ONE oracle; replaying it
// against a different one compares against something the trace never saw, and
// every digest match after that is meaningless.
//
// There is deliberately no skip flag. The remedy is
// `python eq1_record.py --rerecord <trace>`, which re-records from the trace's
// own header parameters and prints which totals moved.
func eq1OraclePin(t eq1T, st *eq1State) {
	t.Helper()
	sim := eq1OracleDir()
	rig := filepath.Join(sim, "pull-study", "03-reserved-composite")
	for _, f := range []struct{ key, path string }{
		{"sha_nsched_model", filepath.Join(sim, "nsched_model.py")},
		{"sha_ackclock_sim", filepath.Join(rig, "ackclock_sim.py")},
		{"sha_reserved_composite", filepath.Join(rig, "reserved_composite.py")},
	} {
		want := st.meta.str(f.key)
		if want == "" {
			t.Fatalf("eq1 ORACLE PIN: trace header has no %s -- it predates the "+
				"pin and cannot be validated", f.key)
		}
		got, err := eq1FileSHA(f.path)
		if err != nil {
			t.Fatalf("eq1 ORACLE PIN: cannot read %s: %v", f.path, err)
		}
		if st.mutate == "oracle-pin" {
			got = "deadbeef" + got[8:]
		}
		if got != want {
			t.Fatalf("eq1 ORACLE PIN VOID: %s is %s in this tree, the trace was "+
				"recorded against %s. This trace records a DIFFERENT oracle. "+
				"Remedy: python eq1_record.py --rerecord <trace>",
				filepath.Base(f.path), got[:12], want[:12])
		}
	}
}

func eq1Init(t eq1T, st *eq1State) {
	t.Helper()
	eq1OraclePin(t, st)
	st.n = st.meta.num(t, "n")
	if st.n < 1 {
		t.Fatalf("eq1: N=%d", st.n)
	}
	if got := st.meta.num(t, "hdr_len"); got != HdrLen {
		t.Fatalf("eq1: trace says hdr_len=%d, frame.go says %d", got, HdrLen)
	}
	if got := st.meta.num(t, "ver"); got != Ver {
		t.Fatalf("eq1: trace says ver=%d, frame.go says %d", got, Ver)
	}
	if got := st.meta.num(t, "magic"); got != Magic {
		t.Fatalf("eq1: trace says magic=%d, frame.go says %d", got, Magic)
	}
	if got := st.meta.str("sched"); got != "pull" {
		t.Fatalf("eq1: trace scheduler is %q. Only the oracle's 'pull' has a "+
			"counterpart in this daemon; Dc is E2b/E2c and is not built", got)
	}
	st.fifo = NewPullFIFO()
	// The AGE limb is OFF. The oracle's bound is bytes only
	// (reserved_composite.py@'while len(s.fifo) * PKT_KB > s.maxq_kb') and inventing an oracle age
	// limb to match
	// the Go one would be making the oracle agree with the port. The Go age
	// limb is therefore NOT covered by EQ-1; it is stated, not tested.
	st.fifo.Trim(time.Now(), 0)
	if st.mutate != "no-bound" {
		st.fifo.SetMaxBytes(st.meta.num(t, "pool_max_bytes"))
	}
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 59402}
	for i := 0; i < st.n; i++ {
		s := &eq1Sock{}
		st.socks = append(st.socks, s)
		st.links = append(st.links, newPullLinkSock(i, fmt.Sprintf("eq1-%d", i), s, dst))
	}
	st.assigned = make([]int, st.n)
	st.out = make([]byte, MaxPayload+HdrLen)
	st.base = time.Unix(1700000000, 0)
	st.now = st.base
	st.tick = -1
}

// eq1TickBoundary charges the previous tick's sheds. The oracle sheds AFTER
// appending every arrival of the tick; the Go pool sheds on each Enqueue. Both
// are oldest-first over the same arrival order, so the pool contents coincide at
// every tick boundary even though the interleaving differs -- which is why the
// comparison is per tick and the P digest, not per Enqueue.
func eq1TickBoundary(t eq1T, st *eq1State) {
	t.Helper()
	if st.fifo == nil {
		return
	}
	_, _, _, qd, _ := st.fifo.ByteStats()
	got := int(qd - st.lastQd)
	if got != st.tickShed {
		t.Fatalf("eq1 tick %d: SHED DIVERGED -- oracle shed %d, go shed %d",
			st.tick, st.tickShed, got)
	}
	st.lastQd = qd
	st.shed += got
	st.tickShed = 0
}

// eq1Draw performs one draw on behalf of link idx. wantSeq is checked only for
// recorded draws; injected refusals take whatever the head is.
func eq1Draw(t eq1T, st *eq1State, idx int, wantSeq uint32, refuse bool,
	sink []byte) []byte {
	t.Helper()
	if idx < 0 || idx >= st.n {
		t.Fatalf("eq1 tick %d: link index %d out of range (N=%d)", st.tick, idx, st.n)
	}
	if eq1PoolLen(st.fifo) == 0 {
		t.Fatalf("eq1 tick %d: oracle drew on link %d but the go pool is EMPTY",
			st.tick, idx)
	}
	fr, ok := st.fifo.Draw()
	if !ok {
		t.Fatalf("eq1 tick %d: Draw returned !ok on a non-empty pool", st.tick)
	}
	if !refuse && fr.seq != wantSeq {
		t.Fatalf("eq1 tick %d: link %d drew seq %d, oracle drew seq %d -- the "+
			"pool is not in the oracle's order", st.tick, idx, fr.seq, wantSeq)
	}
	st.socks[idx].refuse = refuse
	res := st.links[idx].send(fr, st.out)
	if refuse {
		if res != sendBackpressure {
			t.Fatalf("eq1 tick %d: link %d refused write classified as %v, want "+
				"sendBackpressure", st.tick, idx, res)
		}
		if st.mutate != "no-return" {
			st.fifo.Return(fr, st.now)
		}
		return sink
	}
	if res != sendOK {
		t.Fatalf("eq1 tick %d: link %d write classified as %v, want sendOK",
			st.tick, idx, res)
	}
	return append(sink, st.socks[idx].last...)
}

// eq1CheckFrame is the byte-wise half. It masks header[8:12] (time.Now()) IN
// PLACE, so what is fed to the emission digest is exactly what is compared.
func eq1CheckFrame(t eq1T, st *eq1State, idx int, seq, fseq uint32, b []byte) {
	t.Helper()
	want := st.meta.num(t, "frame_bytes")
	if len(b) != want {
		t.Fatalf("eq1 tick %d: link %d wrote %d bytes, oracle frame is %d",
			st.tick, idx, len(b), want)
	}
	for i := 8; i < 12; i++ {
		b[i] = 0
	}
	if b[2] != byte(idx) {
		t.Fatalf("eq1 tick %d: pathID %d, oracle placed seq %d on link %d",
			st.tick, b[2], seq, idx)
	}
	if got := binary.BigEndian.Uint32(b[4:8]); got != seq {
		t.Fatalf("eq1 tick %d: wire seq %d, oracle seq %d", st.tick, got, seq)
	}
	if got := binary.BigEndian.Uint32(b[12:16]); got != fseq {
		t.Fatalf("eq1 tick %d: link %d wire fseq %d, oracle accept-ordinal %d",
			st.tick, idx, got, fseq)
	}
}
