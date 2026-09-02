package main

// =============================================================================
// U36a bars. What they are actually for, since a discoverer is easy to test
// vacuously: every bar below exercises the SAME entry point the daemon calls,
// planSources, never a private helper, and the
// route table is a FILE PATH parameter -- which is the whole reason /proc/net/route
// was chosen over netlink. N is a fixture here, so N in {0,1,2,3,5,8,256} is
// tested rather than argued about. N=3 is the client Mo has today; N=0 is the one
// case that may legitimately refuse.
// =============================================================================

import (
	"bytes"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"unsafe"
)

// ---- fixtures ---------------------------------------------------------------

// u36aTable renders a /proc/net/route file: the kernel's header line plus rows.
const u36aHdr = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT"

func u36aTable(rows ...string) string {
	return u36aHdr + "\n" + strings.Join(rows, "\n") + "\n"
}

// u36aDefault is one UP default route (dest 0, mask 0, RTF_UP|RTF_GATEWAY).
func u36aDefault(iface string, metric int) string {
	return u36aRow(iface, "00000000", "0101A8C0", "0003", metric, "00000000")
}

func u36aRow(iface, dest, gw, flags string, metric int, mask string) string {
	return fmt.Sprintf("%s\t%s\t%s\t%s\t0\t0\t%d\t%s\t0\t0\t0", iface, dest, gw, flags, metric, mask)
}

func u36aWrite(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "route")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return p
}

// u36aNSources builds a table of n up default routes with GENERATED names --
// deliberately not real interface names, so a bar can never pass because a name
// was special-cased somewhere.
func u36aNSources(t *testing.T, n int) (string, []string) {
	t.Helper()
	rows := make([]string, 0, n)
	want := make([]string, 0, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("src%03d", i)
		rows = append(rows, u36aDefault(name, 10*(i+1)))
		want = append(want, name)
	}
	if n == 0 {
		return u36aWrite(t, u36aHdr+"\n"), want
	}
	return u36aWrite(t, u36aTable(rows...)), want
}

// ---- discovery, at every N --------------------------------------------------

func TestDiscoverEnrolsEverySourceAtEachN(t *testing.T) {
	// N=1 (single WAN), 2 (what the deleted default assumed), 3 (the client Mo
	// has today, after the repeater), 5 and 8 (nothing anywhere may cap at 4).
	for _, n := range []int{1, 2, 3, 5, 8} {
		path, want := u36aNSources(t, n)
		p := planSources("", "", path)
		if p.Err != nil {
			t.Fatalf("N=%d: refused a box that has %d sources: %v", n, n, p.Err)
		}
		if len(p.Names) != n {
			t.Fatalf("N=%d: discovered %d sources %v", n, len(p.Names), p.Names)
		}
		if !reflect.DeepEqual(p.Names, want) {
			t.Fatalf("N=%d: got %v want %v", n, p.Names, want)
		}
		if len(p.Found) != n {
			t.Fatalf("N=%d: Found has %d entries, so the startup log would not name them all", n, len(p.Found))
		}
	}
}

func TestDiscoverAtZeroSourcesRefuses(t *testing.T) {
	// A route table with routes in it, none of them a default route. This is the
	// ONE case that may legitimately refuse: the box has no uplink.
	path := u36aWrite(t, u36aTable(
		u36aRow("srcA", "0001A8C0", "00000000", "0001", 0, "00FFFFFF"),
		u36aRow("srcB", "000010AC", "00000000", "0001", 0, "0000FFFF"),
	))
	p := planSources("", "", path)
	if p.Err == nil {
		t.Fatalf("accepted a box with no default route: names=%v", p.Names)
	}
	if len(p.Names) != 0 {
		t.Fatalf("refused but still produced names %v", p.Names)
	}
	if !strings.Contains(p.Err.Error(), path) {
		t.Fatalf("refusal does not say what was looked at: %v", p.Err)
	}
}

func TestDiscoverWithNoRouteTableRefuses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "does-not-exist")
	p := planSources("", "", path)
	if p.Err == nil {
		t.Fatal("accepted an unreadable route table")
	}
	joined := strings.Join(p.Notes, " | ")
	if !strings.Contains(joined, path) {
		t.Fatalf("notes do not name the unreadable file: %v", p.Notes)
	}
}

func TestDiscoverWithAnEmptyRouteTableRefuses(t *testing.T) {
	p := planSources("", "", u36aWrite(t, u36aHdr+"\n"))
	if p.Err == nil {
		t.Fatalf("accepted an empty route table: names=%v", p.Names)
	}
}

func TestDiscoverDedupesADeviceWithTwoDefaultRoutes(t *testing.T) {
	// A device may carry more than one default route (two gateways, two metrics).
	// It is ONE source, kept at its best metric -- the set never gains a duplicate
	// and never shrinks, which is bond-xctl ordered_wans()'s stated property.
	path := u36aWrite(t, u36aTable(
		u36aDefault("srcA", 30),
		u36aDefault("srcB", 20),
		u36aDefault("srcA", 5),
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"srcA", "srcB"}) {
		t.Fatalf("got %v want [srcA srcB] (srcA once, at metric 5)", p.Names)
	}
	if p.Found[0].Metric != 5 {
		t.Fatalf("srcA kept at metric %d, want its best (5)", p.Found[0].Metric)
	}
}

func TestDiscoverOrdersByMetricThenLexically(t *testing.T) {
	// Metric ascending is the ranking bond-xctl ordered_wans() uses, so the
	// fallback and the reconciler enrol the same sources in the same order. The
	// lexical tie-break is a determinism rule, not a preference.
	path := u36aWrite(t, u36aTable(
		u36aDefault("zulu", 10),
		u36aDefault("alpha", 40),
		u36aDefault("mike", 10),
		u36aDefault("bravo", 1),
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"bravo", "mike", "zulu", "alpha"}) {
		t.Fatalf("got %v want [bravo mike zulu alpha]", p.Names)
	}
}

func TestDiscoverSkipsRoutesWithRtfUpClear(t *testing.T) {
	path := u36aWrite(t, u36aTable(
		u36aRow("down", "00000000", "0101A8C0", "0002", 1, "00000000"),
		u36aDefault("up", 20),
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"up"}) {
		t.Fatalf("got %v want [up]: a default route with RTF_UP clear is not a source", p.Names)
	}
	if !strings.Contains(strings.Join(p.Notes, " | "), "RTF_UP") {
		t.Fatalf("the skip is invisible to an operator: %v", p.Notes)
	}
}

func TestDiscoverSkipsNonDefaultRoutes(t *testing.T) {
	// Both limbs matter: dest==0 with a non-zero mask is a network route, and a
	// non-zero dest with a zero mask is not a default route either.
	path := u36aWrite(t, u36aTable(
		u36aRow("lan", "0000A8C0", "00000000", "0001", 0, "00FFFFFF"),
		u36aRow("odd", "0101A8C0", "00000000", "0001", 0, "00000000"),
		u36aDefault("wan", 10),
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"wan"}) {
		t.Fatalf("got %v want [wan]", p.Names)
	}
}

func TestDiscoverSurvivesMalformedLines(t *testing.T) {
	// A single unreadable row must not turn a three-source box into a zero-source
	// box -- that failure mode is exactly what this unit exists to remove.
	path := u36aWrite(t, u36aTable(
		u36aDefault("srcA", 10),
		"this is not a route table line at all and has too few fields",
		"srcJUNK\tZZZZZZZZ\t0101A8C0\t0003\t0\t0\t10\t00000000\t0\t0\t0",
		u36aDefault("srcB", 20),
		u36aDefault("srcC", 30),
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"srcA", "srcB", "srcC"}) {
		t.Fatalf("got %v want [srcA srcB srcC]", p.Names)
	}
	if !strings.Contains(strings.Join(p.Notes, " | "), "unparseable hex") {
		t.Fatalf("the malformed row was skipped silently: %v", p.Notes)
	}
}

func TestDiscoverRanksAMetriclessRouteAsZero(t *testing.T) {
	// bond-xctl:406-409 treats a default route printed with no metric as metric 0.
	// The two must agree or the fallback and the reconciler order sources
	// differently and pathID i stops meaning the same link.
	path := u36aWrite(t, u36aTable(
		u36aDefault("ranked", 10),
		"noMetric\t00000000\t0101A8C0\t0003\t0\t0\tzz\t00000000\t0\t0\t0",
	))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"noMetric", "ranked"}) {
		t.Fatalf("got %v want [noMetric ranked] (metric-less ranks as 0)", p.Names)
	}
}

func TestDiscoverDecodesGatewayLittleEndian(t *testing.T) {
	// /proc/net/route prints the little-endian u32, so 0101A8C0 is 192.168.1.1.
	// A wrong decode here makes the startup log unreadable, which is the only
	// thing standing between a wrong discovery and silence.
	path := u36aWrite(t, u36aTable(u36aRow("gw", "00000000", "0101A8C0", "0003", 0, "00000000")))
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if p.Found[0].Gateway != "192.168.1.1" {
		t.Fatalf("gateway decoded as %q, want 192.168.1.1", p.Found[0].Gateway)
	}
}

func TestDiscoverIsDeterministic(t *testing.T) {
	// Map iteration order must not reach the result. Same table, same answer.
	path, _ := u36aNSources(t, 8)
	first := planSources("", "", path)
	for i := 0; i < 20; i++ {
		again := planSources("", "", path)
		if !reflect.DeepEqual(first.Names, again.Names) {
			t.Fatalf("run %d: %v != %v", i, again.Names, first.Names)
		}
	}
}

func TestDiscoverHonoursAggExclude(t *testing.T) {
	path, _ := u36aNSources(t, 5)
	p := planSources("", " src002 , src004 ", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"src000", "src001", "src003"}) {
		t.Fatalf("got %v want [src000 src001 src003]", p.Names)
	}
	if !strings.Contains(strings.Join(p.Notes, " | "), "AGG_EXCLUDE") {
		t.Fatalf("the exclusion is invisible to an operator: %v", p.Notes)
	}
}

func TestDiscoverRefusesWhenExcludeRemovesEverySource(t *testing.T) {
	path, want := u36aNSources(t, 3)
	p := planSources("", strings.Join(want, ","), path)
	if p.Err == nil {
		t.Fatalf("accepted an empty source set: names=%v", p.Names)
	}
}

// ---- AGG_PATHS, when set, always wins ---------------------------------------

func TestAggPathsWinsOverDiscovery(t *testing.T) {
	// The single-discoverer rule: bond-xctl ordered_wans() feeds AGG_PATHS through
	// agg_env, and converged() compares the world against that same snapshot. A
	// daemon that overrode it, or merged with it, would build against a different
	// world than the one the reconciler compared.
	path, _ := u36aNSources(t, 5)
	p := planSources("supplied0,supplied1,supplied2", "", path)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"supplied0", "supplied1", "supplied2"}) {
		t.Fatalf("got %v, want the supplied list -- discovery leaked into the result", p.Names)
	}
	if len(p.Found) != 0 {
		t.Fatalf("discovery ran anyway and found %v", p.Found)
	}
}

func TestAggPathsWinsWithoutReadingTheRouteTable(t *testing.T) {
	// Stronger than the bar above and the one that actually pins "no second
	// opinion": point the table at a file that cannot exist. If the resolver
	// touched it at all there would be a note about it.
	missing := filepath.Join(t.TempDir(), "never")
	p := planSources("only", "", missing)
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"only"}) {
		t.Fatalf("got %v want [only]", p.Names)
	}
	for _, n := range p.Notes {
		if strings.Contains(n, missing) {
			t.Fatalf("the route table was read even though AGG_PATHS was set: %q", n)
		}
	}
}

func TestAggPathsIsTakenVerbatim(t *testing.T) {
	// Order preserved (it is the reconciler's ranking), whitespace trimmed, and a
	// repeated device kept as given with a note. The supplied list is authoritative
	// and this daemon does not edit it.
	p := planSources(" zulu , alpha ,zulu", "", filepath.Join(t.TempDir(), "never"))
	if p.Err != nil {
		t.Fatalf("refused: %v", p.Err)
	}
	if !reflect.DeepEqual(p.Names, []string{"zulu", "alpha", "zulu"}) {
		t.Fatalf("got %v want [zulu alpha zulu] -- the supplied list was reordered or edited", p.Names)
	}
	if !strings.Contains(strings.Join(p.Notes, " | "), "more than once") {
		t.Fatalf("the duplicate is invisible to an operator: %v", p.Notes)
	}
}

func TestAggPathsRejectsAnEmptyEntry(t *testing.T) {
	for _, s := range []string{"a,,b", "a,", ",a", "a, ,b"} {
		p := planSources(s, "", filepath.Join(t.TempDir(), "never"))
		if p.Err == nil {
			t.Fatalf("AGG_PATHS=%q accepted, names=%v", s, p.Names)
		}
	}
}

// ---- the ceiling is the wire's, and nothing caps below it -------------------

func TestDiscoveryHasNoUpperBoundBelowTheWireCeiling(t *testing.T) {
	path, want := u36aNSources(t, MaxLinks)
	p := planSources("", "", path)
	if p.Err != nil {
		t.Fatalf("refused %d sources, which the wire can address: %v", MaxLinks, p.Err)
	}
	if len(p.Names) != MaxLinks {
		t.Fatalf("discovered %d of %d sources", len(p.Names), MaxLinks)
	}
	if !reflect.DeepEqual(p.Names, want) {
		t.Fatal("the discovered set is not the fixture set at MaxLinks")
	}
}

func TestWireCeilingRefusesAboveMaxLinks(t *testing.T) {
	// Both entry paths, because a ceiling enforced on one of them is not enforced.
	path, want := u36aNSources(t, MaxLinks+1)
	if p := planSources("", "", path); p.Err == nil {
		t.Fatalf("discovery accepted %d sources; pathID is one byte", MaxLinks+1)
	}
	if p := planSources(strings.Join(want, ","), "", path); p.Err == nil {
		t.Fatalf("a supplied list of %d accepted; pathID is one byte", MaxLinks+1)
	}
	if err := wireCeiling(MaxLinks, "x"); err != nil {
		t.Fatalf("MaxLinks itself refused: %v", err)
	}
}

// ---- the regression bar: no interface-name literal in the daemon ------------

func TestNoInterfaceNameLiteralsInDaemonSource(t *testing.T) {
	// The unit's actual claim is "no interface names in code". Assert it, so a
	// future edit that reintroduces one fails here instead of on hardware. Comments
	// are stripped: the history has to stay writable, and it is the CODE that must
	// not name a device.
	banned := []string{"eth1", "usb0", "wwan0", "apcli0", "20000,15000"}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	scanned := map[string]bool{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		scanned[f] = true
		for i, line := range strings.Split(string(b), "\n") {
			if c := strings.Index(line, "//"); c >= 0 {
				line = line[:c]
			}
			for _, bad := range banned {
				if strings.Contains(line, bad) {
					t.Errorf("%s:%d names a specific interface or a 2-shaped weight vector in CODE: %q",
						f, i+1, strings.TrimSpace(line))
				}
			}
		}
	}
	// Anti-vacuity: a glob that matched nothing would pass silently.
	for _, must := range []string{"main.go", "pullrun.go", "discover.go"} {
		if !scanned[must] {
			t.Fatalf("%s was not scanned, so this bar proves nothing", must)
		}
	}
}

// ---- the startup log is the only thing that makes a wrong discovery visible --

func TestStartupLogNamesEveryDiscoveredSource(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	oldFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() { log.SetOutput(old); log.SetFlags(oldFlags) }()

	for _, n := range []int{1, 2, 3, 5, 8} {
		buf.Reset()
		path, want := u36aNSources(t, n)
		p := planSources("", "", path)
		logSourcePlan("client", p)
		out := buf.String()
		for _, name := range want {
			if !strings.Contains(out, name) {
				t.Fatalf("N=%d: source %q is not in the startup log:\n%s", n, name, out)
			}
		}
		if !strings.Contains(out, path) {
			t.Fatalf("N=%d: the log does not say WHERE the sources came from:\n%s", n, out)
		}
		if !strings.Contains(out, "metric=") || !strings.Contains(out, "gw=") {
			t.Fatalf("N=%d: the log gives no metric/gateway, so a wrong pick is unrecognisable:\n%s", n, out)
		}
		if !strings.Contains(out, "FALLBACK") {
			t.Fatalf("N=%d: the log does not say this was a fallback probe:\n%s", n, out)
		}
	}

	// A supplied list logs its origin and does NOT claim to have probed.
	buf.Reset()
	logSourcePlan("client", planSources("a,b", "", filepath.Join(t.TempDir(), "never")))
	if out := buf.String(); !strings.Contains(out, "AGG_PATHS") || strings.Contains(out, "FALLBACK") {
		t.Fatalf("a supplied list logged the wrong origin:\n%s", out)
	}
}

// ---- U136: pull-side per-pathID footprint bar ------------------------------

// TestPullPerPathFootprintIsBounded restores the bar U135 dropped when it
// deleted serverPathSpace and, with it, TestServerPathSpaceFootprintIsBounded
// (dev a1b847f). That test bounded the SERVER's per-pathID footprint at a
// stack that no longer exists (Estr/CapEst/FecTx/FEC-tier/FecRx, deleted by
// U128/ADR-002). This one bounds the PULL side instead: the structures
// runPullClient (pullrun.go) and NewPullCore (pull.go) actually allocate ONE
// PER ADMITTED PATHID, in the daemon's DEFAULT configuration (AGG_LIGHTNING=0,
// AGG_PULL_CAP=off, AGG_SCHED=max) -- unsafe.Sizeof on the real types, not a
// number copied from prose.
//
// WHAT COUNTS AND WHY. Read from pullrun.go's own per-slice inventory
// (comment above pullNoPrior: "NewOWD(N), the LossMeter array, sLossE,
// delivBytes, lossByte ... RxEstSet's priorOwd") plus the per-path struct
// pull.go allocates that pullrun.go's inventory does not name (PullCore.Links)
// plus the per-path RX goroutine's own allocations (pullrun.go, the `for i :=
// 0; i < N; i++ { go func(p int) {...} }` loop) -- those run unconditionally,
// one goroutine per admitted path, same as everything else here:
//
//   - PullLink (pull.go:1003 type; pull.go:1605 allocation, `c.Links =
//     append(...)`) -- one per path, unconditional.
//
//   - OWD (paths.go:43 type; paths.go:51 allocation) -- 3 parallel N-slices
//     (rel, jit, init); per-path share is one float64 + one float64 + one
//     bool.
//
//   - rxEst (qtrack2.go:39 type; qtrack2.go:61 allocation, `est:
//     make([]rxEst, n)`) -- one per path, unconditional.
//
//   - LossMeter (lossmeter.go:37 type; pullrun.go:296-299 allocation, the
//     lossM []*LossMeter array).
//
//   - sLossE, delivBytes, lossByte (pullrun.go:300-302) -- one
//     float64/uint64/uint32 each, per path.
//
//   - buf (pullrun.go:340, `make([]byte, MaxAuthFrame)`) -- one per-path RX
//     goroutine allocates its own buffer, unconditionally, sized MaxAuthFrame
//     (HdrLen+6+MaxPayload+MacLen, frame.go/auth.go) = 1530 B.
//
//   - bpress (pullrun.go:344, `make([]uint64, N)`) -- same goroutine, also
//     unconditional (the capOn gate at pullrun.go:280/287 only decides
//     whether FoldEcho ever reads it, not whether it is allocated; the
//     comment above it says as much: "Only meaningful while the cap is on").
//     Sized N per goroutine, one goroutine per path, so its worst-case
//     per-path share at MaxLinks is MaxLinks*8 B.
//
//   - out (pull.go:1428, `make([]byte, PullSendBufLen)`) -- the per-path TX
//     goroutine's own send buffer (PullLink.Drive), allocated once before its
//     `for {}` draw loop and reused every iteration, so it lives as long as
//     the goroutine, same as buf above. Unconditional: it sits after the
//     disabled() early-return (pull.go:1421-1427), so every admitted link's
//     Drive goroutine (one per link, PullCore.Start, pull.go:1663-1666)
//     allocates it. PullSendBufLen = MaxPayload+HdrLen+MacLen (pull.go:950)
//     = 1500+16+8 = 1524 B.
//
//     POINTER-SLOT RULE, applied uniformly to every per-path []*T this bar
//     touches: a slice of pointers is two separate allocations -- the backing
//     array of 8-byte slots, and (if not nil) whatever each slot points to.
//     This bar counts the 8-byte slot for EVERY per-path []*T, regardless of
//     whether the pointee's own size is also summed elsewhere in perPath:
//
//   - pc (pullrun.go:128, `[]*net.UDPConn`) -- pointee (the net.UDPConn/fd)
//     is OS-owned and NOT summed (see NOT counted, below); only the slot is
//     a daemon-side allocation, so only the slot counts.
//
//   - lossM (pullrun.go:296, `[]*LossMeter`) -- pointee IS summed by value
//     above (`unsafe.Sizeof(LossMeter{})`), but the slot in lossM's backing
//     array is a distinct 8-byte heap allocation from the LossMeter it
//     points to (pullrun.go:297-299, `lossM[i] = &LossMeter{}`), so it counts
//     in addition to the struct sum, not instead of it.
//
//   - c.Links (pull.go:1605, `[]*PullLink`, via NewPullCore's `append`) --
//     same reasoning as lossM: PullLink{} is summed by value above, and the
//     slot in c.Links's backing array is a separate 8-byte allocation from
//     each appended *PullLink.
//
// WHAT DOES NOT COUNT, AND WHY (checked, not assumed):
//   - cap.go's capLink (cap.go:628, `c := &Cap{cfg: cfg, link:
//     make([]capLink, n)}`): built only when AGG_PULL_CAP=on (pullrun.go
//     NewCap call, gated on capOn); PullLink.cap stays a nil 8-byte pointer
//     in the default case, which IS counted inside sz(PullLink{}).
//   - lightning.go's spotty/perLink (lightning.go:738-739): NewLightning
//     returns nil unless AGG_LIGHTNING=1 ("nil == OFF, which is the
//     DEFAULT", lightning.go:713).
//   - lightning.go's DriveLit `out` buffer (lightning.go:655, `out :=
//     make([]byte, MaxPayload+HdrLen)`): DriveLit only ever runs as a
//     goroutine launched by Lightning.Start, and only on the non-nil
//     receiver branch (lightning.go:819-828: `if lit == nil { c.Start();
//     return }`, else `go c.Links[i].DriveLit(...)`) -- i.e. only when
//     AGG_LIGHTNING=1. The default (lit==nil) branch launches Drive
//     instead, whose own `out` (pull.go:1428) IS counted above. Same gate,
//     same exclusion, as spotty/perLink.
//   - sched.go's Ranker (pend/hit/miss/..., sched.go:324-332): NewRankerFor
//     returns nil unless the policy is RankDeadlineHit (AGG_SCHED=speed);
//     `max` needs none (sched.go:580). PullLink.gate stays a nil 16-byte
//     interface value.
//   - ring.go's Ring (ring.go:74, `return &Ring{buf: make([]entry, n),
//     ...}`): ONE ring for the whole datapath, not one per pathID
//     (pullrun.go: `ring := NewRing(...)` sits outside the per-link loop).
//   - lossmeter.go's `m.seen` map (lossmeter.go:68, `m.seen =
//     make(map[uint32]struct{})`): lazily allocated on the first in-window
//     DATA (lossmeter.go:60-69, `Data`) -- so unlike the cap/lightning/
//     ranker items above it is NOT gated behind an env flag; it exists in
//     the default config. It is excluded for a different reason: it is not
//     a fixed per-path cost, it is data-dependent. Its entries are
//     out-of-order arrivals in [next, maxF) awaiting the gap ahead of them
//     to fill; drain() (lossmeter.go:79-107) bounds it IN TIME -- any
//     frontier gap forces a resolution (deliver-in-order or declare-lost,
//     which deletes the entry) once it has blocked longer than `hold`
//     (lossmeter.go:95, `now.Sub(m.blockAt) <= hold`) -- but the code states
//     no fixed numeric bound on how many entries can accumulate WITHIN one
//     hold interval; that is set by reorder depth and pps during that
//     window, i.e. by traffic, not by a daemon-side constant. Same
//     non-unsafe.Sizeof-able category as the goroutine stack below: no
//     fixed struct/array here for this bar to size.
//   - pullNoPrior's return slice (pullrun.go:739, `func pullNoPrior(n int)
//     []float64 { return make([]float64, n) }`), fed straight into
//     NewRxEstSet (pullrun.go:295): NewRxEstSet copies each element into
//     rxEst.floor/relQF (qtrack2.go:63-64) and keeps no field pointing at
//     the slice itself (RxEstSet, qtrack2.go:52-56, has none) -- so it is
//     garbage as soon as NewRxEstSet returns, unlike rxEst, which persists
//     for the daemon's life. A one-shot construction-time temporary, not a
//     per-path standing allocation.
//   - the FRAMES held in a pool (PullFrame headers plus their payload backing
//     arrays, pull.go enqLocked): pool CONTENT, not pool structure. Bounded by
//     the byte limb, whose value is that link's SO_SNDBUF (pullrun.go) -- a
//     kernel setting, not a daemon-side constant -- and by the age limb, whose
//     value is owd.Hold. Data-dependent in exactly the sense lossmeter's `seen`
//     is, and excluded for the same reason. The same applies to the ring's
//     backing array (pull.go grow), whose high-water is set by whatever the
//     byte limb permitted.
//   - per-goroutine stack and the net.UDPConn/fd behind each pc entry: both
//     OS/runtime-managed, not a struct this bar sizes with unsafe.Sizeof, and
//     not shrinkable by editing a daemon-side type. NOT measured here.
//
// FAN-OUT ONLY (U138), and it is the one line here that is NOT in the default
// configuration -- it is counted anyway, so the bound holds for the worst
// per-path shape this binary can be put into rather than only for `max`:
//
//   - PullFIFO (pull.go:405 type; pull.go:484 allocation in NewPullFIFO) plus
//     the THREE sync.Cond values NewPullFIFO builds on it (pull.go:485-487,
//     cv/dcv/rcv). Under AGG_SCHED=lightning PullCore.SetFanout (pull.go)
//     allocates one pool PER LINK, so the pool structure becomes a per-pathID
//     cost. Under every other scheduler PullCore.FIFOs is nil, there is ONE
//     shared pool for the whole core, and this term is a singleton that does
//     not scale with N -- counting it per path there would overstate the sum.
//     Counted unconditionally because the bar bounds the worst case; what is
//     NOT counted is the pool's CONTENT (see below).
//
// A daemon actually running AGG_LIGHTNING=1 / AGG_PULL_CAP=on / AGG_SCHED=speed
// carries more than this bar measures; it is a floor on the default
// configuration plus the fan-out pool, not a ceiling on every configuration.
//
// NOT PER-PATHID AT ALL -- singleton, per-event or startup allocations that the
// completeness grep (make( / [MaxLinks] / [256] over the pull-side files) also
// hits. Listed so the grep-vs-lists comparison is empty, not so they count:
//
//   - pull.go:507 and pull.go:628 -- PullFIFO grow/copy; ONE FIFO per core.
//   - pullrun.go:374 -- per-pong temporary, discarded after the echo is built.
//   - pullrun.go:463 -- the single control goroutine's buffer.
//   - pullrun.go:673 -- the single WG-reader buffer.
//   - cap.go:1411 and sched.go:173 -- startup env parsing, once per process.
//   - lightning.go:341 and lightning.go:575 -- Lightning's own queue and stat
//     snapshot; nil unless AGG_LIGHTNING=1.
//   - ring.go:155 -- per-frame copy into the ONE ring, bounded by the ring.
func TestPullPerPathFootprintIsBounded(t *testing.T) {
	perPath := unsafe.Sizeof(PullLink{}) +
		unsafe.Sizeof(float64(0)) + unsafe.Sizeof(float64(0)) + unsafe.Sizeof(false) + // OWD: rel, jit, init
		unsafe.Sizeof(rxEst{}) +
		unsafe.Sizeof(LossMeter{}) +
		unsafe.Sizeof(float64(0)) + unsafe.Sizeof(uint64(0)) + unsafe.Sizeof(uint32(0)) + // sLossE, delivBytes, lossByte
		uintptr(MaxAuthFrame) + // pullrun.go buf: per-path RX buffer, unconditional
		uintptr(MaxLinks)*unsafe.Sizeof(uint64(0)) + // pullrun.go bpress: per-path RX backpressure slice, unconditional, worst case sized MaxLinks
		uintptr(PullSendBufLen) + // pull.go out: per-path TX buffer (Drive), unconditional
		unsafe.Sizeof((*net.UDPConn)(nil)) + // pullrun.go pc: per-path conn-table slot (pointee excluded, OS-owned)
		unsafe.Sizeof((*LossMeter)(nil)) + // pullrun.go lossM: per-path slot, pointee ALSO summed above
		unsafe.Sizeof((*PullLink)(nil)) + // pull.go c.Links: per-path slot, pointee ALSO summed above (PullLink{})
		unsafe.Sizeof(PullFIFO{}) + 3*unsafe.Sizeof(sync.Cond{}) // FAN-OUT ONLY: one pool per link under AGG_SCHED=lightning, plus its cv/dcv/rcv

	total := perPath * uintptr(MaxLinks)
	t.Logf("pull per-pathID footprint = %d B; at MaxLinks=%d that is %d B (%.2f MiB)",
		perPath, MaxLinks, total, float64(total)/(1024*1024))

	// Bound = the measured sum (perPath, total at MaxLinks=256, from this
	// test's own t.Logf) rounded UP to the next power of two, not an
	// inherited number. Recompute and restate both the bound and this
	// comment's date if a per-path struct or the per-path goroutine's own
	// allocations change shape.
	const bound = 1 << 21 // 2 MiB; measured 2026-09-02 (U138): perPath=5899 B, total=1510144 B at MaxLinks=256 -- next pow2 above measured, unchanged by U138's +368 B fan-out pool
	if total > bound {
		t.Fatalf("pull per-pathID footprint is %d B at MaxLinks=%d, over the %d B bound. "+
			"Either shrink a per-path struct/buffer or lower MaxLinks.", total, MaxLinks, bound)
	}
}
