package main

// =============================================================================
// U36a bars. What they are actually for, since a discoverer is easy to test
// vacuously: every bar below exercises the SAME entry point the daemon calls
// (planSources / serverPathSpace / pushPrior), never a private helper, and the
// route table is a FILE PATH parameter -- which is the whole reason /proc/net/route
// was chosen over netlink. N is a fixture here, so N in {0,1,2,3,5,8,256} is
// tested rather than argued about. N=3 is the client Mo has today; N=0 is the one
// case that may legitimately refuse.
// =============================================================================

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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

// ---- the server's N is a different question ---------------------------------

func TestServerPathSpaceDefaultsToTheWirePathIDSpace(t *testing.T) {
	// The server cannot discover this: the quantity is the CLIENT's source count.
	// With nothing supplied it admits every addressable pathID rather than
	// assuming one -- the same answer server/owd.go:18 reached.
	n, origin, err := serverPathSpace("", "")
	if err != nil {
		t.Fatalf("refused: %v", err)
	}
	if n != MaxLinks {
		t.Fatalf("N=%d, want MaxLinks=%d", n, MaxLinks)
	}
	if origin == "" {
		t.Fatal("no origin string, so the startup log would not say where N came from")
	}
}

func TestServerPathSpaceHonoursAggPaths(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		names := make([]string, n)
		for i := range names {
			names[i] = fmt.Sprintf("src%03d", i)
		}
		got, _, err := serverPathSpace(strings.Join(names, ","), "999")
		if err != nil {
			t.Fatalf("n=%d refused: %v", n, err)
		}
		if got != n {
			t.Fatalf("AGG_PATHS with %d entries gave N=%d (AGG_N must not win over it)", n, got)
		}
	}
}

func TestServerPathSpaceHonoursAggN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8, MaxLinks} {
		got, _, err := serverPathSpace("", fmt.Sprintf("%d", n))
		if err != nil {
			t.Fatalf("AGG_N=%d refused: %v", n, err)
		}
		if got != n {
			t.Fatalf("AGG_N=%d gave N=%d", n, got)
		}
	}
	for _, bad := range []string{"0", "-1", "two", "3.5"} {
		if _, _, err := serverPathSpace("", bad); err == nil {
			t.Fatalf("AGG_N=%q accepted", bad)
		}
	}
	if _, _, err := serverPathSpace("", fmt.Sprintf("%d", MaxLinks+1)); err == nil {
		t.Fatalf("AGG_N=%d accepted; pathID is one byte", MaxLinks+1)
	}
}

func TestServerPathSpaceFootprintIsBounded(t *testing.T) {
	// Admitting the whole pathID space costs memory, so MEASURE it rather than
	// assert it is fine. This is the static per-pathID footprint of the server's
	// per-path stacks; maps grow on top of it, but only for links that carry
	// traffic. reflect, not unsafe.Sizeof, because these structs hold mutexes.
	sz := func(v interface{}) uintptr { return reflect.TypeOf(v).Elem().Size() }
	per := sz((*Estr)(nil)) + sz((*CapEst)(nil)) + sz((*FecTx)(nil)) + sz((*tierCtl)(nil)) +
		sz((*FecRx)(nil)) + sz((*LossMeter)(nil)) + sz((*rxEst)(nil)) +
		8*8 // sLossE, delivBytes, lossByte, lossPeerB, eps, lastRx, fseqDn, OWD
	total := per * uintptr(MaxLinks)
	t.Logf("server per-pathID static footprint = %d B; at MaxLinks=%d that is %d B (%.2f MiB)",
		per, MaxLinks, total, float64(total)/(1024*1024))
	const bound = 4 << 20
	if total > bound {
		t.Fatalf("admitting the whole pathID space costs %d B, over the %d B bound. "+
			"Either shrink a per-path struct or stop defaulting the server to MaxLinks", total, bound)
	}
}

// ---- AGG_W: flat, or nothing ------------------------------------------------

func TestPushFlatPriorIsFlatAtEachN(t *testing.T) {
	// A flat prior expresses no preference between paths. The deleted default
	// expressed one between the first two, and left every path above them on
	// parseW's fallback, so it was not a coherent vector for any N but 2.
	for _, n := range []int{1, 2, 3, 5, 8, MaxLinks} {
		w := pushFlatPrior(n)
		if len(w) != n {
			t.Fatalf("n=%d: got %d weights", n, len(w))
		}
		for i := range w {
			if w[i] != w[0] {
				t.Fatalf("n=%d: w[%d]=%v != w[0]=%v -- path %d is privileged", n, i, w[i], w[0], i)
			}
		}
	}
}

func TestPushPriorUnsetIsFlatAndPermutationInvariant(t *testing.T) {
	// Every spelling of "unset" resolves to the same flat vector, and the vector
	// does not depend on the order of the source list.
	for _, s := range []string{"", " ", "\t", "\n"} {
		for _, n := range []int{1, 2, 3, 5, 8} {
			w := pushPrior(s, n)
			for i := range w {
				if w[i] != w[0] {
					t.Fatalf("AGG_W=%q n=%d: w[%d] != w[0]", s, n, i)
				}
			}
		}
	}
	if !reflect.DeepEqual(pushPrior("", 3), pushFlatPrior(3)) {
		t.Fatal("pushPrior with AGG_W unset is not pushFlatPrior")
	}
}

func TestPushPriorHonoursAnOperatorVector(t *testing.T) {
	// Removing the default must not remove the knob: a supplied AGG_W still binds
	// positionally, exactly as before.
	w := pushPrior("11000,7000,3000", 3)
	if w[0] != 11000 || w[1] != 7000 || w[2] != 3000 {
		t.Fatalf("supplied AGG_W did not bind: %v", w)
	}
	// A short vector against a larger N: the named paths bind, and the unnamed
	// one falls through to parseW's own per-path fallback -- the same value the
	// flat prior uses, so a short AGG_W does not privilege the paths it names
	// relative to some third number invented for the rest.
	w4 := pushPrior("11000,7000,3000", 4)
	if len(w4) != 4 || w4[0] != 11000 || w4[3] != pushFlatPrior(4)[3] {
		t.Fatalf("n=4 with a 3-entry AGG_W: %v (flat fallback is %v)", w4, pushFlatPrior(4))
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
