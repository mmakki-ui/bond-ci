package main

// =============================================================================
// U225 / M2 -- THE READ-ONLY STATS FILE.
//
// OBJ-E asks for "a read-only localhost stats endpoint on the Go daemon"
// (docs/INTENT.md) and M2's interface row says "read-only stats out"
// (module-architecture.md). This is that endpoint, realised as a FILE rather
// than a listener, and the reason is stated once here so nobody re-litigates it
// from the word "endpoint": a socket needs a port number nobody has derived and
// a client tool (curl/nc) that busybox on these boxes does not carry, while a
// file under /var/run/p5 is localhost-only and read-only BY CONSTRUCTION -- the
// portal CGI already reads files there and the namespace glob
// (p5/contract/paths:213 `/var/run/p5/*`) already admits it, so this adds no
// listening surface and no new contract row.
//
// THE ONE INVARIANT THIS FILE EXISTS TO KEEP: there is exactly ONE formatter for
// the PSTAT snapshot. pullrun.go builds the line, statsEmit logs THAT STRING and
// hands THE SAME STRING to the sink, and the sink embeds it VERBATIM behind a
// `ts= up= ival_ms= ` prefix. It never re-formats a field. A second fmt string
// for the file is the defect this design forecloses: it would drift from the log
// silently and the portal would show numbers that no log line ever printed.
// stats_test.go pins both halves -- the verbatim embedding, and a source-level
// tripwire that the PSTAT format string occurs exactly once in the non-test
// daemon sources. (That tripwire greps for the literal prefix, so this comment
// deliberately does not spell it: a mention here would count as a second one,
// which is how the bar first fired.)
//
// OFF PATH: AGG_STATS unset -> NewStatsSink returns nil -> statsEmit does the
// one log.Print this tick always did and returns. Byte-identical behaviour and
// byte-identical log output, which is the U7/U15b rule for every unit that adds
// an optional limb to the datapath.
// =============================================================================

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// statIval is the PSTAT cadence. It is NOT a new constant: it is the literal
// that was already inline at the tick's `now.Sub(lastStat) > time.Second`
// (pullrun.go, the control cadence), given a name here so the file's `ival_ms=`
// and the tick that produces it cannot drift apart. The reader (U226) derives
// staleness from ts= plus this field and therefore carries no cadence constant
// of its own -- which is the whole point of writing it out.
const statIval = time.Second

// warnIval bounds the failure log. A sink that cannot write (read-only fs, the
// dir gone) would otherwise print once per second forever and push the last
// refusal out of logd's ring, which is the exact hazard the portal's Logs card
// already has to warn about.
const warnIval = time.Minute

// StatsSink writes the PSTAT snapshot to a file, atomically. A nil *StatsSink is
// the OFF state and every method is nil-safe: that is how AGG_STATS unset stays
// byte-identical without a branch at the call site.
type StatsSink struct {
	// path is the file the reader opens; tmp is the same-directory scratch the
	// content is built in. SAME DIRECTORY is not a style choice -- os.Rename is
	// only atomic within one filesystem, and /var/run/p5 is tmpfs while /tmp on
	// these boxes may not be.
	path string
	tmp  string

	mu       sync.Mutex
	lastWarn time.Time
}

// NewStatsSink returns nil (the OFF state) for an empty path, and refuses a
// relative one with a single line. A relative path would resolve against procd's
// working directory, not the operator's, so it would create a file nobody can
// find and the portal would report the stats absent while the daemon believed it
// was publishing them. Failing loudly at start is the cheaper of the two.
func NewStatsSink(path string) *StatsSink {
	if path == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		log.Printf("stats: AGG_STATS=%q is not an absolute path -- the stats file is "+
			"DISABLED. The daemon's working directory is procd's, not yours, so a "+
			"relative path would write somewhere no reader looks.", path)
		return nil
	}
	dir, base := filepath.Split(path)
	return &StatsSink{path: path, tmp: filepath.Join(dir, "."+base+".tmp")}
}

// Write publishes one snapshot. `line` is the PSTAT line EXACTLY as logged --
// this function must never reformat any field of it. ifnames and loss are the
// per-link axis: loss[i] is sLossE[i], the per-link loss EWMA in percent, which
// the daemon has computed since U17a and has never printed.
//
// Grammar (fixed in docs/knowledge/design/p5-portal-plan.md section 9 so U225
// and U226 could be built in parallel):
//
//	ts=<unix s> up=<uptime s> ival_ms=<cadence> <the PSTAT line verbatim>
//	link <ifname> loss_pct=<%.1f>          (one per link)
//	latency p50=absent p95=absent
//
// The latency line is a literal `absent` and not a number because this daemon
// measures no delivery-latency percentiles. Printing a zero there would be the
// portal faking data, which R1 forbids.
func (s *StatsSink) Write(line string, now time.Time, up time.Duration, ifnames []string, loss []float64) {
	if s == nil {
		return
	}
	var b strings.Builder
	// ONE formatter: `line` goes in whole. No field of it is re-rendered here.
	fmt.Fprintf(&b, "ts=%d up=%d ival_ms=%d %s\n",
		now.Unix(), int64(up/time.Second), statIval.Milliseconds(), line)
	for i, ifn := range ifnames {
		lp := 0.0
		if i < len(loss) {
			lp = loss[i]
		}
		fmt.Fprintf(&b, "link %s loss_pct=%.1f\n", ifn, lp)
	}
	b.WriteString("latency p50=absent p95=absent\n")
	if err := s.publish(b.String()); err != nil {
		s.warn(err)
	}
}

// publish is tmp + rename, which is the whole reason this is a file and not an
// fprintf into the live path: a reader polling at its own cadence must see the
// previous snapshot or the next one, never half of either. os.Rename is atomic
// within a filesystem, so a reader that opened the old inode keeps reading a
// complete old snapshot and the next open gets the complete new one.
//
// Two daemons in a respawn overlap: the last rename wins and the file is still a
// whole snapshot; `ts=` says which instant it came from.
func (s *StatsSink) publish(body string) error {
	if err := os.WriteFile(s.tmp, []byte(body), 0o644); err != nil {
		return err
	}
	if err := os.Rename(s.tmp, s.path); err != nil {
		// Leave no scratch behind for the clean predicate to trip on.
		_ = os.Remove(s.tmp)
		return err
	}
	return nil
}

// warn logs at most one failure per warnIval. The datapath is unaffected by a
// failed stats write and the message says so, because an operator reading a
// WARNING at 1 Hz will otherwise restart a healthy tunnel.
func (s *StatsSink) warn(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if !s.lastWarn.IsZero() && now.Sub(s.lastWarn) < warnIval {
		return
	}
	s.lastWarn = now
	log.Printf("stats WARNING: %s not written: %v -- the DATAPATH IS UNAFFECTED, only "+
		"the read-only stats file is; the reader reports it stale or absent. "+
		"(rate-limited to one line per %v)", s.path, err, warnIval)
}

// statsEmit is the ONE exit for a PSTAT snapshot. It exists so the log line and
// the file's first line are the same Go string by construction rather than by
// review: a future edit that wants to change the log has nowhere to change only
// the log.
func statsEmit(s *StatsSink, line string, now time.Time, up time.Duration, ifnames []string, loss []float64) {
	log.Print(line)
	s.Write(line, now, up, ifnames, loss)
}
