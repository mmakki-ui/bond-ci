package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// U159 BARS, client half. Mirrors p4-bondagg/server/deliver_test.go, because
// the deletion is at BOTH ends and a bar on one end proves nothing about the
// other.
//
//	(a) STRUCTURAL -- no reorder-hold machinery in the shipped tree. The failure
//	    this guards is a re-INTRODUCTION ("just a small buffer, for ordering"),
//	    which is a shape in the source, not a value a datapath test notices.
//	(b) THE REORDER-DEPTH BOUND -- WireGuard's anti-replay window is what
//	    tolerates reorder now, it counts FRAMES, so the bound is a frame count.
//
// There is deliberately NO datapath-driving bar here. On this end the receive
// path after U159 is one call -- `deliver(pay)` in runPullClient, a closure over
// wgSock -- and a test that re-implemented it around a stub would assert its own
// stub. The server bar exercises the real seam (rxPath.Handle takes no socket).
// What this file asserts instead is the SHAPE of the shipped arm, read from
// pullrun.go's own AST (TestClientFlagDataArmBranchesOnNothingAndEndsInDeliver),
// which catches the re-introduction a name filter cannot: a dedup table under a
// fresh identifier.
// ---------------------------------------------------------------------------

// (a) No reorder-hold machinery in the shipped (non-test) sources.
//
// TWO NAMES ARE DELIBERATELY NOT BANNED, and both were measured against this
// tree rather than guessed:
//
//	`hold`   -- owd.Hold(HoldMin, HoldMax) survives as the SENDER pool and
//	            copy-queue residence budget (pull.go S4/S5, lightning.go). It is
//	            a different physical quantity from the receiver horizon U159
//	            deleted.
//	`blockOn` -- lossmeter.go:48,89,95,96,111 times a gap in the frontier to
//	            CLASSIFY it as late-vs-lost. It reorders nothing and delays no
//	            frame; it is a meter, not a buffer. Banning it made this bar red
//	            on its first run against a correct tree, which is how a bar gets
//	            switched off.
//
// A bar that has to be relaxed to go green is worth less than one scoped
// honestly, so the set below is the RING's own identifiers.
func TestNoReorderRingInTheShippedDaemonTree(t *testing.T) {
	banned := regexp.MustCompile(
		`(?:NewRing|\bRing\b|SetArrival|pushArrival|deliverArrival|reanchor|holdNow|HoldDur|epochOn|arrQ|DeliverOnArrival|DeliverInOrder|SchedDelivery|SchedHold)`)
	hits := scanShippedDaemon(t, banned)
	if len(hits) != 0 {
		t.Fatalf("reorder-ring machinery is back in the shipped daemon tree:\n  %s\n"+
			"U159 deleted it at both ends: every mode hands the payload to the WG socket "+
			"AT ARRIVAL. If ordering or a dedup table is genuinely needed again that is "+
			"the owner's decision and an ADR-002 amendment, not a buffer added under a "+
			"review.", strings.Join(hits, "\n  "))
	}
}

// scanShippedDaemon returns "<file>:<line>: <text>" for every match of re in the
// package's non-test .go sources. Comments are stripped first: a comment may
// NAME the deleted thing (they all do, on purpose), code may not.
func scanShippedDaemon(t *testing.T, re *regexp.Regexp) []string {
	t.Helper()
	names, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(names) == 0 {
		t.Fatal("scanned no sources at all: this bar would pass on an empty tree")
	}
	var hits []string
	for _, n := range names {
		if strings.HasSuffix(n, "_test.go") {
			continue
		}
		b, err := os.ReadFile(n)
		if err != nil {
			t.Fatalf("read %s: %v", n, err)
		}
		for i, line := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
			code := line
			if j := strings.Index(code, "//"); j >= 0 {
				code = code[:j]
			}
			if re.MatchString(code) {
				hits = append(hits, n+":"+dItoa(i+1)+": "+strings.TrimSpace(line))
			}
		}
	}
	return hits
}

func dItoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

// (b) THE REORDER-DEPTH BOUND.
//
// dDepthOf measures, for a delivered seq sequence, how far behind the highest
// seq already delivered a later frame sits -- exactly the quantity WireGuard's
// anti-replay window bounds. With deliver-on-arrival it is a property of the
// WIRE: this datapath neither creates nor absorbs it.
func dDepthOf(seqs []uint32) int {
	hi, depth := uint32(0), 0
	for i, s := range seqs {
		if i == 0 || int32(s-hi) > 0 {
			hi = s
			continue
		}
		if d := int(hi - s); d > depth {
			depth = d
		}
	}
	return depth
}

// dReorderedTrace is n frames in ARRIVAL order where one frame in every lag+1
// arrives exactly `lag` frames late -- the shape a slower path carrying its
// share of a striped bond presents.
func dReorderedTrace(n, lag int) []uint32 {
	if lag <= 0 || lag+2 >= n {
		return nil
	}
	period := lag + 1
	out := make([]uint32, 0, n)
	for i := 0; i < n; i++ {
		if i%period == 0 {
			continue
		}
		out = append(out, uint32(i))
		if i%period == period-1 {
			out = append(out, uint32(i-lag))
		}
	}
	return out
}

// Both directions, because a bar that only said "718 < 2048" would pass with
// the arithmetic inverted. The envelope numbers are the design's, not new ones:
// MaxReorderSpreadMS is HoldMax (main.go:44), the horizon the deleted ring was
// already willing to spend, and 2053 frames/s is 25 Mbit/s at MaxFrame -- the
// class of uplink this bond aggregates.
func TestClientDeliveredReorderDepthStaysInsideTheWGReplayWindow(t *testing.T) {
	if WGReplayWindow <= 0 || MaxReorderSpreadMS <= 0 {
		t.Fatal("the bound is not stated: WGReplayWindow / MaxReorderSpreadMS")
	}
	if int(HoldMax/1e6) != MaxReorderSpreadMS {
		t.Fatalf("MaxReorderSpreadMS=%d but HoldMax=%v: the bound must stay the "+
			"deleted ring's own horizon, not a second independent guess",
			MaxReorderSpreadMS, HoldMax)
	}
	if d := ReorderDepthFrames(MaxReorderSpreadMS, 2053); d != 718 {
		t.Fatalf("depth at 25 Mbit/s = %d frames, want 718", d)
	}
	if !ReorderEnvelopeOK(2053) {
		t.Fatal("25 Mbit/s is outside the stated envelope: the bond's own class of " +
			"uplink would present a reorder WireGuard drops")
	}
	// The envelope is FINITE -- the honest half. ~5851 frames/s, ~71 Mbit/s at
	// MaxFrame, not "no limit".
	if ReorderEnvelopeOK(WGReplayWindow*1000/MaxReorderSpreadMS + 1) {
		t.Fatal("the envelope claims to be unbounded: above ~5851 frames/s a full " +
			"spread of reorder is deeper than the window and WireGuard drops it")
	}

	depth := ReorderDepthFrames(MaxReorderSpreadMS, 2053)
	if got := dDepthOf(dReorderedTrace(4096, depth)); got != depth {
		t.Fatalf("trace depth = %d, want %d: the generator does not build the "+
			"reorder it claims, so nothing below measures anything", got, depth)
	}
	if got := dDepthOf(dReorderedTrace(4096, depth)); got >= WGReplayWindow {
		t.Fatalf("delivered reorder depth %d >= WGReplayWindow %d: WireGuard would "+
			"drop the late frames", got, WGReplayWindow)
	}
	// A reorder DEEPER than the bound must measure as outside the window.
	// Without this the bar above cannot fail and is theatre.
	if got := dDepthOf(dReorderedTrace(1<<14, WGReplayWindow+1)); got < WGReplayWindow {
		t.Fatalf("a reorder of %d frames measured as depth %d, inside the window: the "+
			"bound cannot detect the case it exists for", WGReplayWindow+1, got)
	}
}

// The frame format is UNCHANGED. seq is still packed, still parsed, still four
// bytes at the same offset: U159 stopped CONSUMING it for ordering and dedup, it
// did not remove it. Mirrored on the server (TestWireSeqFieldSurvivesTheRingDeletion).
func TestClientWireSeqFieldSurvivesTheRingDeletion(t *testing.T) {
	b := make([]byte, MaxFrame)
	n := Pack(b, FlagData, 3, 0xDEADBEEF, 1234, 0, []byte{9, 9, 9})
	_, _, seq, _, _, _, err := Unpack(b[:n])
	if err != nil {
		t.Fatalf("a packed DATA frame no longer unpacks: %v", err)
	}
	if seq != 0xDEADBEEF {
		t.Fatalf("seq round-tripped as %#x, want 0xDEADBEEF -- the wire field is "+
			"still the contract even though delivery ignores it", seq)
	}
}

// (a) THE DEDUP HALF ON THIS END, and it is deliberately NOT a name filter.
//
// The regression the brief names is "a small dedup table". Under a FRESH
// identifier (`seen map[uint32]bool`, `last [256]uint32`) it trips no regex
// built from the deleted ring's names, and this end has no socket-free seam a
// behavioural bar could drive -- `deliver` is a closure over wgSock inside
// runPullClient. So the bar reads the SHAPE of the shipped FlagData arm out of
// the AST of pullrun.go itself:
//
//   - it BRANCHES ON NOTHING. Every dedup and every reorder hold is a
//     conditional on per-seq state -- `if seen[..]`, `if sq <= hi`, a `for`
//     that drains a queue. An arm containing no if/for/range/switch/select and
//     no continue/break/goto/return cannot be one, whatever the identifiers.
//   - THE LAST STATEMENT IS `deliver(pay)`. A guard inserted ahead of it moves
//     it; a statement added after it is a consumer of the payload this datapath
//     does not have.
//
// WHAT IT DOES NOT COVER, stated rather than implied: a branchless filter (a
// bitmask write with no test) would pass, and so would a dedup moved out of
// this arm into Admit. It bounds the arm this unit emptied, which is where a
// re-introduction would land.
func TestClientFlagDataArmBranchesOnNothingAndEndsInDeliver(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "pullrun.go", nil, 0)
	if err != nil {
		t.Fatalf("parse pullrun.go: %v", err)
	}
	var arm *ast.CaseClause
	ast.Inspect(f, func(n ast.Node) bool {
		cc, ok := n.(*ast.CaseClause)
		if !ok {
			return true
		}
		for _, e := range cc.List {
			if id, ok := e.(*ast.Ident); ok && id.Name == "FlagData" {
				if arm != nil {
					t.Fatalf("two `case FlagData:` arms in pullrun.go (%s and %s): this "+
						"bar cannot tell which one is the receive path",
						fset.Position(arm.Pos()), fset.Position(cc.Pos()))
				}
				arm = cc
			}
		}
		return true
	})
	if arm == nil {
		t.Fatal("no `case FlagData:` in pullrun.go -- the receive arm this bar exists " +
			"for has been renamed or moved, so the bar is measuring nothing")
	}
	if len(arm.Body) == 0 {
		t.Fatal("the FlagData arm is empty: it no longer delivers at all")
	}
	for _, st := range arm.Body {
		ast.Inspect(st, func(n ast.Node) bool {
			switch n.(type) {
			case *ast.IfStmt, *ast.ForStmt, *ast.RangeStmt, *ast.SwitchStmt,
				*ast.TypeSwitchStmt, *ast.SelectStmt, *ast.BranchStmt, *ast.ReturnStmt:
				t.Fatalf("the FlagData receive arm branches at %s: %T. U159 made delivery "+
					"UNCONDITIONAL -- every frame goes to WireGuard at arrival, and dedup "+
					"is WireGuard's anti-replay window. A conditional here is a reorder "+
					"hold or a dedup table under some name, and that is the owner's "+
					"decision plus an ADR-002 amendment, not a buffer added under a review.",
					fset.Position(n.Pos()), n)
				return false
			}
			return true
		})
	}
	last, ok := arm.Body[len(arm.Body)-1].(*ast.ExprStmt)
	if !ok {
		t.Fatalf("the FlagData arm's last statement is %T, not the delivery call",
			arm.Body[len(arm.Body)-1])
	}
	call, ok := last.X.(*ast.CallExpr)
	if !ok {
		t.Fatalf("the FlagData arm's last statement is not a call: %T", last.X)
	}
	id, ok := call.Fun.(*ast.Ident)
	if !ok || id.Name != "deliver" || len(call.Args) != 1 {
		t.Fatalf("the FlagData arm does not end in deliver(pay) at %s",
			fset.Position(last.Pos()))
	}
	if a, ok := call.Args[0].(*ast.Ident); !ok || a.Name != "pay" {
		t.Fatalf("deliver is not handed the parsed payload directly at %s: a copy or a "+
			"buffered slice here is the ring coming back", fset.Position(last.Pos()))
	}
}
