package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// U159 BARS -- the two things the deletion has to keep true.
//
// The reorder ring is gone at both ends (Mo, 2026-09-02). Two claims replaced
// it, and a claim nobody can watch fail is not a bar:
//
//	(a) STRUCTURAL. Nothing in the SHIPPED tree consults a reorder hold on the
//	    way to WireGuard. This is a source bar as well as a behavioural one
//	    because the failure it guards against is a re-INTRODUCTION -- a future
//	    unit adding "a small buffer, just for ordering" -- and that is a shape
//	    in the source, not a value a datapath test would notice.
//
//	(b) THE REORDER-DEPTH BOUND. With no ring, the wire's own reorder reaches
//	    WireGuard unsmoothed and its anti-replay window is what tolerates it.
//	    The window is a FRAME COUNT, so the bound has to be one too --
//	    ReorderDepthFrames / ReorderEnvelopeOK in main.go.
// ---------------------------------------------------------------------------

// (a) BEHAVIOURAL HALF. The shipped receive seam, driven with no socket:
// frames handed to Handle out of seq order must leave in ARRIVAL order, on the
// call that delivered them, with no tick, no timer and no clock advance.
//
// Seeded red (recorded in the U159 evidence): reintroduce any hold in the
// delivery path -- buffer f.pay and release it in seq order -- and the arrival
// order below stops matching.
func TestServerDeliversOnArrivalNotInSeqOrder(t *testing.T) {
	cli := mustAddr(t, "203.0.113.9:59402")
	t0 := time.Now()
	x, _, _, got := newTestRx(nil)

	// Deliberately out of order, all at the SAME instant: no amount of waiting
	// is available to a resequencer, and none is needed.
	for _, sq := range []uint32{5, 3, 9, 4} {
		x.Handle(plain(FlagData, 1, sq, 1, seqPay(sq)), cli, t0)
		if n := len(*got); n == 0 || (*got)[n-1] != sq {
			t.Fatalf("seq %d did not leave on the call that delivered it: got %v", sq, *got)
		}
	}
	eq(t, *got, 5, 3, 9, 4)
}

// (a) STRUCTURAL HALF. No reorder-hold machinery in the shipped (non-test)
// sources of this package. The identifiers are the ones the deleted ring
// actually used, so a "small dedup table" or a re-ported hold trips it by name.
//
// It reads the package directory rather than a manifest, so a NEW file carrying
// the machinery is caught too -- the failure a hand-kept list would miss.
func TestNoReorderHoldInTheShippedServerTree(t *testing.T) {
	banned := regexp.MustCompile(
		`(?:NewRing|\bRing\b|SetArrival|deliverArrival|reanchor|holdNow|SetHold|HoldDur|blockOn|epochOn|RingPow2|HoldMinDefault|HoldMaxDefault)`)
	hits := scanShipped(t, banned)
	if len(hits) != 0 {
		t.Fatalf("reorder-hold machinery is back in the shipped server tree:\n  %s\n"+
			"U159 deleted it: this datapath writes every payload to WireGuard AT ARRIVAL. "+
			"If a hold is genuinely needed again that is a decision for the owner and an "+
			"ADR-002 amendment, not a buffer added under a review.",
			strings.Join(hits, "\n  "))
	}
}

// scanShipped returns "<file>:<line>: <text>" for every match of re in the
// package's non-test .go sources. Comments are stripped before matching: a
// comment may NAME the thing that was deleted (they all do, on purpose), code
// may not.
func scanShipped(t *testing.T, re *regexp.Regexp) []string {
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
				hits = append(hits, n+":"+itoa(i+1)+": "+strings.TrimSpace(line))
			}
		}
	}
	return hits
}

func itoa(n int) string {
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
// depthOf is the measurement: for a delivered seq sequence, how far behind the
// highest seq already delivered does a later frame sit. That is exactly the
// quantity WireGuard's anti-replay window bounds, and with deliver-on-arrival
// it is a property of the WIRE -- this datapath neither creates nor absorbs it.
func depthOf(seqs []uint32) int {
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

// reorderedTrace is n frames delivered in ARRIVAL order, where one frame in
// every lag+1 arrives exactly `lag` frames late -- the shape a slower path
// carrying its share of a striped bond presents to the receiver.
func reorderedTrace(n, lag int) []uint32 {
	if lag <= 0 || lag+2 >= n {
		return nil
	}
	period := lag + 1
	out := make([]uint32, 0, n)
	for i := 0; i < n; i++ {
		if i%period == 0 {
			continue // held back on the slow path
		}
		out = append(out, uint32(i))
		if i%period == period-1 {
			out = append(out, uint32(i-lag)) // the late one lands exactly lag behind
		}
	}
	return out
}

// A reorder at the STATED envelope must stay inside the window; a reorder past
// the bound must be visible as past it. Both halves, because a bar that only
// said "718 < 2048" would pass with the arithmetic inverted.
//
// The envelope numbers are the design's, not new ones: MaxReorderSpreadMS is
// the deleted hold's own horizon (350 ms) and the frame rate below is read off
// it -- 2053 frames/s is 25 Mbit/s at MaxFrame, the class of uplink this bond
// aggregates.
func TestDeliveredReorderDepthStaysInsideTheWGReplayWindow(t *testing.T) {
	if WGReplayWindow <= 0 || MaxReorderSpreadMS <= 0 {
		t.Fatal("the bound is not stated: WGReplayWindow / MaxReorderSpreadMS")
	}
	if d := ReorderDepthFrames(MaxReorderSpreadMS, 2053); d != 718 {
		t.Fatalf("depth at 25 Mbit/s = %d frames, want 718", d)
	}
	if !ReorderEnvelopeOK(2053) {
		t.Fatal("25 Mbit/s is outside the stated envelope: the bond's own class of " +
			"uplink would present a reorder WireGuard drops")
	}
	// And the envelope is FINITE, which is the honest half: the ceiling is
	// about 5851 frames/s (~71 Mbit/s at MaxFrame), not "no limit".
	if ReorderEnvelopeOK(WGReplayWindow*1000/MaxReorderSpreadMS + 1) {
		t.Fatal("the envelope claims to be unbounded: above ~5851 frames/s a full " +
			"spread of reorder is deeper than the window and WireGuard drops it")
	}

	depth := ReorderDepthFrames(MaxReorderSpreadMS, 2053)
	if got := depthOf(reorderedTrace(4096, depth)); got != depth {
		t.Fatalf("trace depth = %d, want %d: the generator does not build the "+
			"reorder it claims, so nothing below measures anything", got, depth)
	}
	if got := depthOf(reorderedTrace(4096, depth)); got >= WGReplayWindow {
		t.Fatalf("delivered reorder depth %d >= WGReplayWindow %d: WireGuard would "+
			"drop the late frames", got, WGReplayWindow)
	}
	// The other direction, executed rather than described: a reorder DEEPER
	// than the bound must measure as outside the window. Without this the bar
	// above cannot fail and is theatre.
	if got := depthOf(reorderedTrace(1<<14, WGReplayWindow+1)); got < WGReplayWindow {
		t.Fatalf("a reorder of %d frames measured as depth %d, inside the window: the "+
			"bound cannot detect the case it exists for", WGReplayWindow+1, got)
	}
}

// The frame format is UNCHANGED: seq is still on the wire, still parsed, and
// still four bytes at the same offset. U159 stopped CONSUMING it for ordering;
// it did not remove it, and a client that stopped sending it would break every
// future use of the field.
func TestWireSeqFieldSurvivesTheRingDeletion(t *testing.T) {
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
	if binary.BigEndian.Uint32(b[4:8]) != 0xDEADBEEF {
		t.Fatal("seq moved on the wire: the frame format is out of scope for U159")
	}
}

// (a) THE DEDUP HALF, BEHAVIOURAL -- and this is the bar the identifier regex
// above CANNOT be. The regression the brief names by name is "a small dedup
// table", and one written under a FRESH identifier (`seen map[uint32]bool`,
// `last [256]uint32`) trips no filter built from the deleted ring's names. It
// trips this one, because it asserts the OBSERVABLE property instead: every
// copy that arrives is delivered.
//
// That property is load-bearing, not incidental. The rings were the dedup
// memory first-copy-wins needed for `lightning`, which puts one copy of every
// frame on every source; U159 handed that job to WireGuard's anti-replay
// window. So a duplicate MUST pass through this layer -- and if a future unit
// re-adds dedup here, the trade recorded in main.go's DELIVER ON ARRIVAL block
// (a wasted decrypt per copy) stops being the trade that was decided.
func TestServerDeliversEveryCopyOfADuplicatedSeq(t *testing.T) {
	cli := mustAddr(t, "203.0.113.9:59402")
	t0 := time.Now()
	x, _, _, got := newTestRx(nil)

	// `lightning`'s shape: seq 7 on path 1, the same seq on path 2, and a
	// repeat on path 1 -- same instant, so no dedup could claim it aged out.
	for _, l := range []byte{1, 2, 1} {
		x.Handle(plain(FlagData, l, 7, 1, seqPay(7)), cli, t0)
	}
	eq(t, *got, 7, 7, 7)

	// Interleaved with a distinct seq, so a bar that only counted deliveries
	// could not pass a first-wins filter by accident.
	y, _, _, got2 := newTestRx(nil)
	for _, s := range []uint32{4, 4, 9, 4} {
		y.Handle(plain(FlagData, 1, s, 1, seqPay(s)), cli, t0)
	}
	eq(t, *got2, 4, 4, 9, 4)
}
