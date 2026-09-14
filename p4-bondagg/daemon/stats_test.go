package main

// U225 / M2 -- bars for the read-only stats file (stats.go).
//
// WHAT EACH BAR IS FOR, and each names the seed that reddens it:
//   - TestStatsUnsetWritesNothing  AGG_STATS unset writes no file AND logs the
//     same bytes as before the unit. Seed: make the nil sink write anywhere.
//   - TestStatsSameFormatter       the file's line 1 is the log line VERBATIM,
//     and `PSTAT n=` occurs exactly once in the non-test sources. Seed: a second
//     fmt string for the file -> both halves red.
//   - TestStatsAtomicReader        1000 ticks, a concurrent reader never sees a
//     partial snapshot. Seed: write in place instead of tmp+rename -> red.
//   - TestStatsPerLinkLoss         N=3 -> exactly 3 link lines carrying sLossE.
//   - TestStatsMissingDirDoesNotCrash  an unwritable path is a rate-limited WARN,
//     never a panic and never a 1 Hz log flood.
//   - TestStatsRefusesRelativePath a relative AGG_STATS is refused at start.
//
// No t.Run anywhere: this package has zero subtests and the CI floor's
// source-count cross-check (emulator-gate.yml) counts top-level funcs.

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// statsFixtureLine is a realistic PSTAT line: the file is what a reader polls,
// and a one-word fixture would make the tearing bar vacuous by being smaller
// than any plausible write granularity.
func statsFixtureLine(tick int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "PSTAT n=8 sched=max depth=%d peak=41 qb=8192/65536 peakb=9001 enq=%d "+
		"drawn=%d stale=0 qdrop=0 retq=0 hold=213ms del=%d rxshed=0 authok=%d authbad=0 "+
		"authshed=0 sealshort=0 gate=0", tick%17, tick, tick, tick*3, tick*2)
	for i := 0; i < 8; i++ {
		fmt.Fprintf(&b, " | wan%d sent=%d kb=%d blk=0ms bp=0 wravg=1200ns wrmin=900ns err=0 up=true",
			i, tick*7+i, tick*3+i)
	}
	return b.String()
}

// captureLog redirects the standard logger into a buffer with no timestamp
// prefix, so two runs are byte-comparable. Returns the buffer and a restore.
func captureLog() (*bytes.Buffer, func()) {
	buf := &bytes.Buffer{}
	oldOut, oldFlags, oldPrefix := log.Writer(), log.Flags(), log.Prefix()
	log.SetOutput(buf)
	log.SetFlags(0)
	log.SetPrefix("")
	return buf, func() {
		log.SetOutput(oldOut)
		log.SetFlags(oldFlags)
		log.SetPrefix(oldPrefix)
	}
}

// inDir runs f with the process working directory moved, and ALWAYS moves it
// back -- a leaked chdir would break TestStatsSameFormatter's source scan and be
// attributed to the wrong bar. (go 1.22 here, so no t.Chdir.)
func inDir(t *testing.T, dir string, f func()) {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := os.Chdir(wd); err != nil {
			t.Fatal(err)
		}
	}()
	f()
}

func TestStatsUnsetWritesNothing(t *testing.T) {
	// The OFF path is the whole U7/U15b rule: with AGG_STATS unset this daemon
	// must be byte-identical to the one that existed before this unit -- no file,
	// no scratch, and THE SAME LOG BYTES.
	line := statsFixtureLine(1)
	ifn := []string{"wan0", "wan1"}
	loss := []float64{0.0, 1.25}
	now := time.Unix(1700000000, 0)

	if s := NewStatsSink(""); s != nil {
		t.Fatalf("AGG_STATS unset must give a nil sink, got %+v", s)
	}

	offDir := t.TempDir()
	// The nil sink is exercised with the process CWD inside an empty directory so
	// a sink that "helpfully" fell back to a relative default would leave a trace.
	var offLog *bytes.Buffer
	inDir(t, offDir, func() {
		var restoreOff func()
		offLog, restoreOff = captureLog()
		statsEmit(NewStatsSink(""), line, now, 42*time.Second, ifn, loss)
		restoreOff()
	})

	ents, err := os.ReadDir(offDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 0 {
		t.Fatalf("the OFF path wrote %d entries: %v -- AGG_STATS unset must write NOTHING", len(ents), ents)
	}

	onDir := t.TempDir()
	sink := NewStatsSink(filepath.Join(onDir, "datapath.stats"))
	if sink == nil {
		t.Fatal("an absolute AGG_STATS must give a live sink")
	}
	onLog, restoreOn := captureLog()
	statsEmit(sink, line, now, 42*time.Second, ifn, loss)
	restoreOn()

	if offLog.String() != onLog.String() {
		t.Fatalf("the ON path changed the LOG. off=%q on=%q -- the stats file must add "+
			"nothing to the log line, or every existing log bar and every operator's eye "+
			"is reading a different daemon", offLog.String(), onLog.String())
	}
	if got, want := offLog.String(), line+"\n"; got != want {
		t.Fatalf("the OFF path's log line is %q, want %q (log.Print of the PSTAT string, unchanged)", got, want)
	}
	// The ON path leaves the file and NO scratch: the tmp was renamed, not left.
	ents, err = os.ReadDir(onDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Name() != "datapath.stats" {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("ON path left %v, want exactly [datapath.stats] -- a leftover .tmp is a "+
			"clean-predicate finding on the box", names)
	}
}

func TestStatsSameFormatter(t *testing.T) {
	// ONE formatter, two halves.
	//
	// Half 1, behavioural: the file's first line is the ts/up/ival prefix plus
	// the caller's line VERBATIM. A sink that re-rendered any field would drift
	// the instant that field's format changed, so this asserts the whole string,
	// twice, with one field different between the two snapshots.
	dir := t.TempDir()
	path := filepath.Join(dir, "datapath.stats")
	sink := NewStatsSink(path)
	ifn := []string{"wan0"}
	loss := []float64{0.4}

	for _, tick := range []int{1, 2} {
		line := statsFixtureLine(tick) // tick changes enq=/drawn=/del=: one field family
		sink.Write(line, time.Unix(1700000000+int64(tick), 0), time.Duration(tick)*time.Second, ifn, loss)
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
		want := fmt.Sprintf("ts=%d up=%d ival_ms=%d %s", 1700000000+tick, tick, statIval.Milliseconds(), line)
		if lines[0] != want {
			t.Fatalf("file line 1 is NOT the log line verbatim behind the prefix.\n got: %q\nwant: %q\n"+
				"A second formatter for the file is the defect: the portal would show numbers "+
				"no log line ever printed", lines[0], want)
		}
		if !strings.HasSuffix(lines[0], line) {
			t.Fatalf("file line 1 does not END with the log line: %q", lines[0])
		}
	}

	// Half 2, structural: there is exactly ONE place in the non-test daemon
	// sources that formats a PSTAT line. This is the bar the "add a second fmt
	// string in stats.go" seed reddens even if the seed also copies the prefix.
	srcs, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	total, where := 0, []string{}
	for _, f := range srcs {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if n := strings.Count(string(b), "PSTAT n="); n > 0 {
			total += n
			where = append(where, fmt.Sprintf("%s x%d", f, n))
		}
	}
	if total != 1 {
		t.Fatalf("`PSTAT n=` occurs %d times in the daemon sources (%v), want exactly 1. "+
			"The log line and the stats file share ONE formatter (stats.go, statsEmit)", total, where)
	}
}

func TestStatsAtomicReader(t *testing.T) {
	// 1000 ticks with a reader spinning on the same path. Every read must be a
	// WHOLE snapshot: prefix ts=, the exact link count, and the latency line last.
	// Seed A (os.WriteFile straight to s.path instead of tmp+rename) makes the
	// reader observe truncated prefixes and this goes red.
	dir := t.TempDir()
	path := filepath.Join(dir, "datapath.stats")
	sink := NewStatsSink(path)
	ifn := []string{"wan0", "wan1", "wan2", "wan3", "wan4", "wan5", "wan6", "wan7"}
	loss := []float64{0, 1, 2, 3, 4, 5, 6, 7}
	wantLines := 1 + len(ifn) + 1

	sink.Write(statsFixtureLine(0), time.Unix(1700000000, 0), 0, ifn, loss) // prime

	stop := make(chan struct{})
	var wg sync.WaitGroup
	var reads int
	var bad string
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			b, err := os.ReadFile(path)
			if err != nil {
				// ENOENT is itself a failure of atomicity here: the file exists
				// from the priming write onward and rename never unlinks it.
				if bad == "" {
					bad = "read failed: " + err.Error()
				}
				continue
			}
			reads++
			s := string(b)
			if bad != "" {
				continue
			}
			switch {
			case !strings.HasPrefix(s, "ts="):
				bad = fmt.Sprintf("TORN: snapshot does not start with ts= (%d bytes, head %q)", len(s), head(s))
			case !strings.HasSuffix(s, "latency p50=absent p95=absent\n"):
				bad = fmt.Sprintf("TORN: snapshot does not end with the latency line (%d bytes, tail %q)", len(s), tail(s))
			default:
				if n := strings.Count(s, "\n"); n != wantLines {
					bad = fmt.Sprintf("TORN: snapshot has %d lines, want %d (%d bytes)", n, wantLines, len(s))
				}
			}
		}
	}()

	for i := 1; i <= 1000; i++ {
		sink.Write(statsFixtureLine(i), time.Unix(1700000000+int64(i), 0), time.Duration(i)*time.Second, ifn, loss)
	}
	close(stop)
	wg.Wait()

	if bad != "" {
		t.Fatalf("a concurrent reader saw a partial snapshot after %d reads: %s", reads, bad)
	}
	// ANTI-VACUITY: a reader that never managed a single read proves nothing.
	if reads < 100 {
		t.Fatalf("the reader only completed %d reads over 1000 ticks -- this bar would pass "+
			"on a torn writer too; it is not measuring anything", reads)
	}
}

func head(s string) string {
	if len(s) > 60 {
		return s[:60]
	}
	return s
}

func tail(s string) string {
	if len(s) > 60 {
		return s[len(s)-60:]
	}
	return s
}

func TestStatsPerLinkLoss(t *testing.T) {
	// The per-link loss EWMA (sLossE) is computed by the daemon today and has
	// never left it. N=3 -> exactly 3 link lines, each carrying its own value at
	// one decimal, in link order.
	dir := t.TempDir()
	path := filepath.Join(dir, "datapath.stats")
	sink := NewStatsSink(path)
	ifn := []string{"wan0", "wwan0", "usb0"}
	loss := []float64{0.04, 12.35, 100.0}

	sink.Write(statsFixtureLine(3), time.Unix(1700000000, 0), 9*time.Second, ifn, loss)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	var got []string
	for _, l := range lines {
		if strings.HasPrefix(l, "link ") {
			got = append(got, l)
		}
	}
	want := []string{
		"link wan0 loss_pct=0.0",
		"link wwan0 loss_pct=12.3", // %.1f: 12.35 rounds to even here; asserted, not assumed
		"link usb0 loss_pct=100.0",
	}
	if len(got) != 3 {
		t.Fatalf("N=3 gave %d link lines, want 3: %v", len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("link line %d is %q, want %q", i, got[i], want[i])
		}
	}
	if last := lines[len(lines)-1]; last != "latency p50=absent p95=absent" {
		t.Fatalf("last line is %q, want the literal absent latency row -- this daemon "+
			"measures no percentiles and the portal must not be handed a fake zero", last)
	}
}

func TestStatsMissingDirDoesNotCrash(t *testing.T) {
	// /var/run/p5 is tmpfs created at runtime; a daemon that starts before it
	// exists must keep running the datapath and say so ONCE, not once a second.
	dir := t.TempDir()
	path := filepath.Join(dir, "does", "not", "exist", "datapath.stats")
	sink := NewStatsSink(path)
	if sink == nil {
		t.Fatal("an absolute path must give a live sink even if the dir is missing")
	}
	buf, restore := captureLog()
	defer restore()

	for i := 0; i < 5; i++ {
		sink.Write(statsFixtureLine(i), time.Unix(1700000000, 0), time.Second, []string{"wan0"}, []float64{0})
	}
	restore()

	out := buf.String()
	if n := strings.Count(out, "stats WARNING:"); n != 1 {
		t.Fatalf("5 failing writes logged %d WARNINGs, want exactly 1 (rate limited to one "+
			"per %v -- a 1 Hz flood pushes the last refusal out of logd's ring):\n%s", n, warnIval, out)
	}
	if !strings.Contains(out, "DATAPATH IS UNAFFECTED") {
		t.Fatalf("the WARNING must say the datapath is unaffected, or an operator restarts a "+
			"healthy tunnel over a stats file: %q", out)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("stat(%s) = %v, want IsNotExist", path, err)
	}
}

func TestStatsRefusesRelativePath(t *testing.T) {
	// A relative AGG_STATS resolves against procd's working directory, not the
	// operator's: the daemon would publish to a path no reader looks at while
	// believing it was publishing. Refuse at start, with one line.
	buf, restore := captureLog()
	sink := NewStatsSink("run/p5/datapath.stats")
	restore()
	if sink != nil {
		t.Fatalf("a relative AGG_STATS must be refused, got a non-nil sink")
	}
	if n := strings.Count(buf.String(), "not an absolute path"); n != 1 {
		t.Fatalf("the refusal must log exactly one line, got %d:\n%s", n, buf.String())
	}
	// And the refused sink is the OFF state, not a half-live one.
	dir := t.TempDir()
	inDir(t, dir, func() {
		sink.Write(statsFixtureLine(1), time.Unix(1700000000, 0), time.Second, []string{"wan0"}, []float64{0})
	})
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 0 {
		t.Fatalf("a refused sink wrote %v", ents)
	}
}
