package main

// =============================================================================
// U36a -- WHERE THE SOURCE LIST COMES FROM.
//
// THE DEFECT THIS REPLACES. The push entry points (deleted in U128) resolved
// env("AGG_PATHS", <a two-interface literal>). Two things were wrong with it,
// and the second is the worse one:
//   * it named specific interfaces, which are properties of one box on one day;
//   * it SET N. With the variable unset the daemon did not fail, it ran, and it
//     described a two-source box. On 2026-08-30 a third source (a repeater) was
//     added to the client, so that description became false about the actual
//     hardware (ROADMAP "A THIRD WAN SOURCE EXISTS ON THE CLIENT").
//
// THE RULE THIS FILE OBEYS. Do not replace one frozen assumption with another.
// "Refuse when AGG_PATHS is unset" would be exactly that: a decision, baked into
// the binary, about what an operator must already know. The honest version is to
// LOOK, and to refuse only when looking genuinely returns nothing.
//
// WHAT COUNTS AS A SOURCE. Whatever currently carries an UP default route. That
// is a property of the running kernel, not of a name, and it is the same rule the
// two artifacts that already discover sources use: deploy/p5/bond-xctl
// ordered_wans() (its non-ubus fallback parses `ip route show` for `default ...
// dev X metric M`) and scripts/e1-probe.sh:79-86 ("N-generic: whatever carries a
// default route is a source. No hardcoded list, no assumed count.").
//
// SINGLE DISCOVERER -- THIS IS A FALLBACK, NOT A SECOND OPINION. bond-xctl is
// the authoritative discoverer: it snapshots the source set, feeds it to the
// daemon as AGG_PATHS in agg_env, and converged() compares the world against
// that same snapshot. A daemon that re-probed on its own would build against a
// different world than the one the reconciler compared, which is the hazard U18's
// report names. So AGG_PATHS, WHEN SET, ALWAYS WINS AND IS TAKEN VERBATIM: the
// route table is not read at all in that case, not even to warn about a
// disagreement, because a warning is a second opinion. Discovery runs only when
// nothing supplied a list.
//
// MECHANISM: /proc/net/route, PARSED. Three candidates were on the table.
//   * netlink RTM_GETROUTE via syscall.NetlinkRIB. Stdlib, no exec. Rejected on
//     TESTABILITY: its input is the live kernel, so N=0/1/2/3/5/8 cannot be
//     exercised without root, netns and hardware -- none of which exist here or
//     on the CI runner. An untestable discoverer is how a wrong discovery stays
//     invisible, which is the failure mode this unit exists to end.
//   * shelling out to `ip route show default`. Adds an exec from a daemon, a
//     dependency on iproute2 being installed, and a dependency on its output
//     format; the boxes run busybox, whose `ip` prints a related but not
//     identical format. bond-xctl can afford that (it is already shell, on the
//     box, where `ip` is known present); a Go daemon should not.
//   * /proc/net/route, read and parsed. CHOSEN. Procfs is always mounted on
//     OpenWrt, the format is fixed and documented, it needs no privilege and no
//     exec, it carries the METRIC directly (the exact key ordered_wans() ranks
//     by), and -- the deciding property -- the path is a parameter, so every N in
//     {0,1,2,3,5,8,256} is a fixture and is tested.
//
// KNOWN LIMITS, RECORDED RATHER THAN PAPERED OVER.
//   * /proc/net/route is IPv4 ONLY (IPv6 lives in /proc/net/ipv6_route, whose
//     format differs). That matches this daemon, which is udp4 throughout
//     (net.ResolveUDPAddr("udp4", ...) at every call site). A v6 transport would
//     need a second parser; it does not exist yet, so neither does the parser.
//   * A TUNNEL DEVICE CARRYING THE DEFAULT ROUTE IS NOT DISTINGUISHABLE HERE.
//     bond-xctl excludes $WG_DEV by name because it knows the name. This daemon
//     does not, and no route-table field says "this is the tunnel". Classifying by
//     /sys/class/net/*/type or by the presence of a device symlink would be a
//     guess that misclassifies PPP, VLAN and bridge WANs, so it is not made. The
//     mitigations are: AGG_PATHS wins whenever the reconciler is present (which is
//     the deployed shape); AGG_EXCLUDE takes an operator list; and the chosen set
//     is LOGGED per source with its metric and gateway, so a wrong discovery is
//     visible in the first line of the log instead of being inferred from
//     throughput. Deriving it from a measurement is an OPEN QUESTION, not an
//     answer this unit has.
//   * The ceiling is the WIRE's, not a policy: pathID is one byte (frame.go:9),
//     so at most MaxLinks = 256 sources are distinguishable. Nothing here caps
//     below that, and nothing assumes a count.
// =============================================================================

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
)

// procNetRoute is the kernel's IPv4 route table as text. Overridable via
// AGG_ROUTE_TABLE so a harness (and every test in discover_test.go) can present
// a synthetic table without root, a netns or hardware.
const procNetRoute = "/proc/net/route"

// rtfUp is RTF_UP from linux/route.h. A route whose UP bit is clear is present
// in the table but not usable, and is not a source.
const rtfUp = 0x0001

// wanSource is one discovered source: the device that carries an up default
// route, the kernel metric that ranks it, and the gateway, which is logged so an
// operator can recognise the link.
type wanSource struct {
	Ifname  string
	Metric  int64
	Gateway string
}

// srcPlan is the resolved source list plus everything an operator needs in order
// to see WHY it is that list. Notes are non-fatal observations; Err is the one
// legitimate refusal.
type srcPlan struct {
	Names  []string
	Origin string
	Found  []wanSource
	Notes  []string
	Err    error
}

// decodeHexIPv4 renders one /proc/net/route address field. The kernel prints the
// little-endian u32, so 0101A8C0 is 192.168.1.1: octet order is low byte first.
func decodeHexIPv4(v uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", v&0xff, (v>>8)&0xff, (v>>16)&0xff, (v>>24)&0xff)
}

// parseDefaultRoutes extracts the up default routes from a /proc/net/route
// stream, deduped by device and ordered.
//
// A default route is Destination == 0 AND Mask == 0. Ordering is metric
// ascending with a lexical tie-break on the device name, and a device that
// carries two default routes is kept ONCE at its best (lowest) metric. That is
// deliberately the same ranking as bond-xctl ordered_wans(), so the fallback and
// the reconciler enrol the same sources in the same order and pathID i means the
// same link on both sides of a restart. The tie-break is a determinism rule, not
// a preference between links.
//
// Malformed lines are skipped with a note rather than aborting the parse: a
// single unreadable row must not turn a three-source box into a zero-source box.
func parseDefaultRoutes(r io.Reader) ([]wanSource, []string) {
	var out []wanSource
	var notes []string
	at := map[string]int{}
	sc := bufio.NewScanner(r)
	ln := 0
	for sc.Scan() {
		ln++
		f := strings.Fields(sc.Text())
		if len(f) < 8 || f[0] == "Iface" {
			continue
		}
		dest, e1 := strconv.ParseUint(f[1], 16, 32)
		flags, e2 := strconv.ParseUint(f[3], 16, 32)
		mask, e3 := strconv.ParseUint(f[7], 16, 32)
		if e1 != nil || e2 != nil || e3 != nil {
			notes = append(notes, fmt.Sprintf("route line %d: unparseable hex field, skipped (%q)", ln, sc.Text()))
			continue
		}
		if dest != 0 || mask != 0 {
			continue // a specific route, not a default route: not a source
		}
		if flags&rtfUp == 0 {
			notes = append(notes, fmt.Sprintf("route line %d: %s has a default route with RTF_UP clear, skipped", ln, f[0]))
			continue
		}
		metric, e4 := strconv.ParseInt(f[6], 10, 64)
		if e4 != nil {
			// bond-xctl's own fallback treats a metric-less default route as 0
			// (deploy/p5/bond-xctl:406-409). Keep the two identical.
			metric = 0
			notes = append(notes, fmt.Sprintf("route line %d: %s metric %q unparseable, ranked as 0 (same as bond-xctl's fallback)", ln, f[0], f[6]))
		}
		gw, _ := strconv.ParseUint(f[2], 16, 32)
		s := wanSource{Ifname: f[0], Metric: metric, Gateway: decodeHexIPv4(uint32(gw))}
		if i, dup := at[s.Ifname]; dup {
			if s.Metric < out[i].Metric {
				out[i] = s
			}
			notes = append(notes, fmt.Sprintf("%s carries more than one default route; kept once at its best metric %d", s.Ifname, out[i].Metric))
			continue
		}
		at[s.Ifname] = len(out)
		out = append(out, s)
	}
	if err := sc.Err(); err != nil {
		notes = append(notes, fmt.Sprintf("route table read stopped early: %v", err))
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Metric != out[j].Metric {
			return out[i].Metric < out[j].Metric
		}
		return out[i].Ifname < out[j].Ifname
	})
	return out, notes
}

// discoverSources reads and parses a route table by path. An unreadable table is
// a note, not an error: the refusal belongs to "nothing was found", and is raised
// once, by planSources, so there is exactly one refusal point.
func discoverSources(path string) ([]wanSource, []string) {
	f, err := os.Open(path)
	if err != nil {
		return nil, []string{fmt.Sprintf("cannot read %s: %v", path, err)}
	}
	defer f.Close()
	return parseDefaultRoutes(f)
}

// splitPaths parses a supplied AGG_PATHS list. It is taken VERBATIM -- same
// order, no dedupe, no reordering -- because the reconciler is the discoverer and
// this daemon does not get a second opinion. A repeated device is reported as a
// note (it means two sockets on one link, which is almost certainly a mistake)
// but it is not silently removed and it is not fatal.
func splitPaths(s string) ([]string, []string, error) {
	raw := strings.Split(s, ",")
	names := make([]string, 0, len(raw))
	var notes []string
	seen := map[string]bool{}
	for i, v := range raw {
		v = strings.TrimSpace(v)
		if v == "" {
			return nil, notes, fmt.Errorf("AGG_PATHS: empty ifname at position %d in %q", i, s)
		}
		if seen[v] {
			notes = append(notes, fmt.Sprintf("AGG_PATHS lists %q more than once; kept as given (the supplied list is authoritative and is not edited here)", v))
		}
		seen[v] = true
		names = append(names, v)
	}
	return names, notes, nil
}

// wireCeiling refuses a source count the wire cannot address. The bound is
// MaxLinks = 256, which is the one-byte pathID (frame.go:9) and nothing else: it
// is not a policy about how many WANs a box may have. Past it, two links emit the
// same pathID and the peer merges their OWD, loss and fseq series, fabricating
// per-path loss out of two interleaved sub-sequences. Same bound, same reason and
// the same refusal as pullrun.go:88 and server/echo.go:8.
func wireCeiling(n int, what string) error {
	if n > MaxLinks {
		return fmt.Errorf("%s yields %d sources but the wire addresses paths with a ONE-BYTE pathID, "+
			"so at most %d are distinguishable (MaxLinks, frame.go:9). Links 0 and %d would both emit "+
			"pathID 0 and the peer would merge their OWD, loss and fseq series. Refusing to start "+
			"rather than fabricate per-path loss", what, n, MaxLinks, MaxLinks)
	}
	return nil
}

// excludeSet parses AGG_EXCLUDE, an optional operator list of devices that carry
// a default route but must not be enrolled. It exists for the one case discovery
// cannot decide for itself -- a tunnel device holding the default route, see the
// file header -- and it is empty by default, so it adds no assumption.
func excludeSet(s string) map[string]bool {
	m := map[string]bool{}
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			m[v] = true
		}
	}
	return m
}

// planSources resolves the source list. The precedence is the whole contract.
//
// FIRST, if AGG_PATHS holds anything at all: that list, verbatim, in that order.
// The route table is not opened. This is what the reconciler supplies through
// agg_env and it always wins.
//
// SECOND, if AGG_PATHS is unset or blank: discover from the route table. Every
// device with an up default route is a source, deduped, ranked by metric.
//
// THIRD, only if discovery found nothing: refuse, and say what was looked at. A
// box with no default route has no uplink at all, which is the one case where
// there is genuinely nothing to describe.
//
// Nothing in this function branches on the count, privileges an index, or names a
// device.
func planSources(aggPaths, exclude, routePath string) srcPlan {
	var p srcPlan
	if strings.TrimSpace(aggPaths) != "" {
		names, notes, err := splitPaths(aggPaths)
		p.Notes, p.Err = notes, err
		if err != nil {
			return p
		}
		p.Names = names
		p.Origin = "AGG_PATHS, supplied (the reconciler is the discoverer; no route probe was run)"
		p.Err = wireCeiling(len(p.Names), "AGG_PATHS")
		return p
	}
	found, notes := discoverSources(routePath)
	p.Notes = notes
	ex := excludeSet(exclude)
	for _, s := range found {
		if ex[s.Ifname] {
			p.Notes = append(p.Notes, fmt.Sprintf("%s carries a default route but is in AGG_EXCLUDE, not enrolled", s.Ifname))
			continue
		}
		p.Found = append(p.Found, s)
		p.Names = append(p.Names, s.Ifname)
	}
	if len(p.Names) == 0 {
		p.Err = fmt.Errorf("AGG_PATHS is unset, so the source set was discovered from %s, and NOTHING "+
			"there carries an up default route (after AGG_EXCLUDE=%q). A box with no default route has "+
			"no uplink to aggregate. Refusing to start rather than invent a source set. Set AGG_PATHS "+
			"to override discovery, or point AGG_ROUTE_TABLE at the right table", routePath, exclude)
		return p
	}
	p.Origin = fmt.Sprintf("discovered from %s (every device with an up default route, ranked by metric)", routePath)
	p.Err = wireCeiling(len(p.Names), "discovery")
	return p
}

// logSourcePlan prints the decision ONCE, at startup, in a form an operator can
// check against the box. A discovery that is wrong is invisible unless it is
// printed, and "which sources, and why those" is the whole of what can go wrong
// here, so the origin, every source with its metric and gateway, and every note
// are all printed -- not just the count.
func logSourcePlan(role string, p srcPlan) {
	log.Printf("%s sources: origin=%s N=%d %v", role, p.Origin, len(p.Names), p.Names)
	for i, s := range p.Found {
		log.Printf("%s source %d: dev=%s metric=%d gw=%s", role, i, s.Ifname, s.Metric, s.Gateway)
	}
	for _, n := range p.Notes {
		log.Printf("%s sources NOTE: %s", role, n)
	}
	if len(p.Found) > 0 {
		log.Printf("%s sources: this was a FALLBACK probe -- deploy/p5/bond-xctl ordered_wans() is the "+
			"authoritative discoverer and supplies AGG_PATHS when it is running. A tunnel device holding "+
			"the default route is NOT distinguishable from a WAN in the route table; if one of the "+
			"sources above is the tunnel, set AGG_PATHS or AGG_EXCLUDE. Verify the list above against "+
			"the box before trusting any throughput number from this run.", role)
	}
}

// mustSources is the client entry point: resolve, log once, and fail loud only on
// the honest refusal.
func mustSources(role string) []string {
	p := planSources(env("AGG_PATHS", ""), env("AGG_EXCLUDE", ""), env("AGG_ROUTE_TABLE", procNetRoute))
	logSourcePlan(role, p)
	if p.Err != nil {
		log.Fatalf("%s: %v", role, p.Err)
	}
	return p.Names
}
