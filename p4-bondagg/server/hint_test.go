package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"testing"
	"time"
)

// U34a -- the SERVER half of the downlink hint: what route does with header
// byte [3]. The client half (what goes on the wire) is daemon/hint_test.go.
//
// Every bar here is driven through the real rxPath, not by poking peers
// directly, because the thing being asserted is a DATAPATH property: the byte is
// read only in the FlagData arm, only after gate.Admit has accepted the frame,
// and only into `hint` -- never into `last` and never into `ep`.

// hintVector is pinned character for character in daemon/hint_test.go. The two
// modules cannot import each other, so this pair of hand-written strings is the
// only bar that fails when the two copies of the header drift -- which they have
// (U48: this file's mirror comment dropped byte [3]'s annotation, and U34 round
// 1 then recorded the field as unused).
const hintVector = "b0" + "20" + "07" + "02" + "11223344" + "55667788" + "99aabbcc"

func TestHintHeaderVector(t *testing.T) {
	b := make([]byte, HdrLen)
	PackRsvd(b, FlagData, 0x07, 0x02, 0x11223344, 0x55667788, 0x99aabbcc, nil)
	if got := hex.EncodeToString(b); got != hintVector {
		t.Fatalf("header vector drifted:\n got %s\nwant %s", got, hintVector)
	}
}

func TestServerHintTargetIsModuloTwoFiveSix(t *testing.T) {
	for p := 0; p < 256; p++ {
		if got := HintTarget(byte(p), 0); got != byte(p) {
			t.Fatalf("d=0 must be the identity: HintTarget(%d,0)=%d", p, got)
		}
		for d := 0; d < 256; d++ {
			if got, want := HintTarget(byte(p), byte(d)), byte((p+d)%256); got != want {
				t.Fatalf("HintTarget(%d,%d)=%d, want %d", p, d, got, want)
			}
		}
	}
}

// mintHint is mint with an explicit byte [3] -- the client's hinted DATA frame,
// tagged by the same independent reimplementation of the MAC that mint uses.
func mintHint(key []byte, base, pid, d byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay)+MacLen)
	n := PackRsvd(b, base|FlagAuth, pid, d, seq, ts, 0, pay)
	m := hmac.New(sha256.New, key)
	var in [macInLen]byte
	in[0] = domC2S
	copy(in[1:1+HdrLen], b[:HdrLen])
	binary.BigEndian.PutUint16(in[1+HdrLen:], uint16(len(pay)))
	m.Write(in[:])
	copy(b[n:], m.Sum(nil)[:MacLen])
	return b[:n+MacLen]
}

// plainHint is plain with an explicit byte [3]: what an attacker, or a keyless
// install's real client, puts on the wire.
func plainHint(base, pid, d byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay))
	n := PackRsvd(b, base, pid, d, seq, ts, 0, pay)
	return b[:n]
}

// THE ROUND TRIP. The client sends DATA on link 1 carrying d = 2; the server
// routes the downlink onto link 3 = (1 + 2), at the address IT learned for link
// 3 -- not at the address the hinting frame came from.
//
// The CONTROL is the same exchange with d = 0, which must route to link 1. That
// half is what makes this a bar and not a coincidence: without it the test would
// still pass if route ignored the hint and link 3 merely happened to be `last`.
func TestDownlinkHintRoutesToTheLinkTheClientNames(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	x.Handle(mintHint(key, FlagData, 1, 2, 2, 1, seqPay(2)), a1, now)

	link, addr := pr.routeAt(now)
	if link != 3 || addr.String() != a3.String() {
		t.Fatalf("hint d=2 on pathID 1: downlink rides link %d at %v, want link 3 at %v",
			link, addr, a3)
	}

	// CONTROL: d = 0 is A0. Same two links, same order, hint dropped.
	y, pr2, _, _, _ := newTestRx([][]byte{key})
	y.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	y.Handle(mint(key, FlagData, 1, 2, 1, seqPay(2)), a1, now)
	link, addr = pr2.routeAt(now)
	if link != 1 || addr.String() != a1.String() {
		t.Fatalf("control: d=0 must be A0, got link %d at %v, want link 1 at %v",
			link, addr, a1)
	}
}

// The hint moves the ROUTE and nothing else. `last` must keep meaning "the link
// the client last sent DATA on" (spec item 3): it is what the fallback returns
// and what U31 vector 1 asserts about. Proven by taking the hint away and
// watching the route return to link 1 with no new DATA frame in between.
func TestHintMovesTheRouteWithoutMovingLastOrEp(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	x.Handle(mintHint(key, FlagData, 1, 2, 2, 1, seqPay(2)), a1, now)
	if l, _ := pr.routeAt(now); l != 3 {
		t.Fatalf("setup: route is link %d, want 3", l)
	}
	if pr.last != 1 {
		t.Fatalf("the hint moved `last` to %d: it must stay the frame's own path, 1", pr.last)
	}
	if pr.ep[1].String() != a1.String() || pr.ep[3].String() != a3.String() {
		t.Fatal("the hint moved an endpoint: ep must only ever be written for the frame's OWN path")
	}
}

// FALLBACK 1 -- a hint naming a link this server has never accepted a frame on
// is IGNORED, and the frame rides the link it came in on. Never a blackhole and
// never a fixed index (spec item 4): the pre-U34a bug class was exactly a hint
// that resolved to link 0 for every sender that did not know about hints.
func TestUnknownHintTargetFallsBackToTheFramesOwnLink(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	// d = 7 on pathID 1 names link 8, which has never sent anything.
	x.Handle(mintHint(key, FlagData, 1, 7, 2, 1, seqPay(2)), a1, now)
	link, addr := pr.routeAt(now)
	if link != 1 || addr.String() != a1.String() {
		t.Fatalf("unknown target: downlink rides link %d at %v, want the frame's own link 1 at %v",
			link, addr, a1)
	}
	if link == 0 && addr == nil {
		t.Fatal("fell into a blackhole")
	}

	// CONTROL: once link 8 exists, the same hint IS followed -- so the fallback
	// above is the target being unknown, not the hint being ignored.
	a8 := mustAddr(t, "203.0.113.8:59402")
	x.Handle(mint(key, FlagData, 8, 3, 1, seqPay(3)), a8, now)
	x.Handle(mintHint(key, FlagData, 1, 7, 4, 1, seqPay(4)), a1, now)
	if link, addr = pr.routeAt(now); link != 8 || addr.String() != a8.String() {
		t.Fatalf("control: with link 8 known the hint must be followed, got link %d at %v",
			link, addr)
	}
}

// FALLBACK 2 -- BL4, the freshness bound. A hint aims the downlink at a link the
// client is deliberately NOT sending DATA on, so that link's endpoint is as old
// as its last uplink frame. Past EpMaxAge the server stops believing it and
// falls back to the frame's own path.
//
// Both sides are asserted from ONE state, moving only the clock: at +500 ms the
// hint is followed, at +700 ms it is not. A test that only checked the stale
// side would pass against a route that had simply stopped following hints.
func TestStaleHintTargetFallsBackToTheFramesOwnLink(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	t0 := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, t0)
	x.Handle(mintHint(key, FlagData, 1, 2, 2, 1, seqPay(2)), a1, t0.Add(500*time.Millisecond))

	if l, a := pr.routeAt(t0.Add(500 * time.Millisecond)); l != 3 || a.String() != a3.String() {
		t.Fatalf("at +500ms (inside EpMaxAge) the hint must hold: link %d at %v", l, a)
	}
	if l, a := pr.routeAt(t0.Add(700 * time.Millisecond)); l != 1 || a.String() != a1.String() {
		t.Fatalf("at +700ms link 3's endpoint is %v old and must be refused: link %d at %v",
			700*time.Millisecond, l, a)
	}

	// An AUTHENTICATED ping on link 3 refreshes its endpoint without touching
	// the route (learnEp), which is what keeps a hinted, DATA-silent link
	// eligible while the gate is closed. Same clock, same hint, opposite verdict.
	x.Handle(mint(key, FlagPing, 3, 0, 7, nil), a3, t0.Add(650*time.Millisecond))
	if l, a := pr.routeAt(t0.Add(700 * time.Millisecond)); l != 3 || a.String() != a3.String() {
		t.Fatalf("a keepalive ping must refresh the hinted endpoint: link %d at %v", l, a)
	}
	if pr.last != 1 {
		t.Fatalf("the ping moved `last` to %d -- pings must never steer the downlink", pr.last)
	}
}

// EpMaxAge is DERIVED from the peer's own liveness timer, not chosen. This is
// the same hand-kept-mirror bar as TestReopenFloorMatchesPeerLiveness: the
// constant lives in the other module (daemon/main.go DeadIval = 600ms) and
// nothing but a test can hold the two copies together.
func TestEpMaxAgeMatchesPeerLiveness(t *testing.T) {
	if EpMaxAge != 600*time.Millisecond {
		t.Fatalf("EpMaxAge = %v, want the peer's DeadIval, 600ms", EpMaxAge)
	}
	if EpMaxAge != ReopenFloor {
		t.Fatalf("EpMaxAge %v and ReopenFloor %v are both DeadIval and must move together",
			EpMaxAge, ReopenFloor)
	}
}

// The hint is read ONLY under FlagData (spec item 1). Byte [3] is K under
// FlagFEC and 0 under every other flag, so a non-DATA frame carrying a non-zero
// byte [3] must leave the route exactly where it was. Without this the FEC group
// size would be a downlink routing instruction on the retained push datapath.
func TestByteThreeSteersNothingOutsideFlagData(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	x.Handle(mint(key, FlagData, 1, 2, 1, seqPay(2)), a1, now)
	if l, _ := pr.routeAt(now); l != 1 {
		t.Fatalf("setup: route is link %d, want 1", l)
	}
	// FlagFEC with K = 2: on FlagData that byte would name link 3.
	x.Handle(mintHint(key, FlagFEC, 1, 2, 3, 1, seqPay(3)), a1, now)
	if l, _ := pr.routeAt(now); l != 1 {
		t.Fatalf("a FlagFEC frame's K moved the downlink to link %d", l)
	}
	x.Handle(mintHint(key, FlagPing, 1, 2, 0, 7, nil), a1, now)
	if l, _ := pr.routeAt(now); l != 1 {
		t.Fatalf("a FlagPing frame's byte [3] moved the downlink to link %d", l)
	}
	x.Handle(mintHint(key, FlagEcho, 1, 2, 0, 7, nil), a1, now)
	if l, _ := pr.routeAt(now); l != 1 {
		t.Fatalf("a FlagEcho frame's byte [3] moved the downlink to link %d", l)
	}
}

// U31 VECTOR 1, THROUGH THE NEW FIELD. The hint is a routing instruction, so an
// attacker who can write it steers the downlink at the cost of one byte instead
// of a whole forged frame. It is refused for the same reason the rest of the
// header is: the MAC covers hdr[:HdrLen], so rewriting byte [3] invalidates the
// tag and Admit sheds the frame before it reaches peers.
//
// POSITIVE CONTROL, and it is the live exposure of every install today: with no
// key on the box the same rewritten frame IS obeyed. The hint does not create
// that exposure -- a forged DATA frame already moved the route -- but it must
// not be recorded as closed while the gate is open either.
func TestRewrittenHintCannotSteerTheDownlinkWhileTheGateIsClosed(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.1:59402")
	a3 := mustAddr(t, "203.0.113.3:59402")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 3, 1, 1, seqPay(1)), a3, now)
	x.Handle(mint(key, FlagData, 1, 2, 1, seqPay(2)), a1, now)

	tampered := mint(key, FlagData, 1, 3, 1, seqPay(3))
	tampered[3] = 2 // "route my downlink to link 3" -- not what was signed
	x.Handle(tampered, a1, now)
	if l, a := pr.routeAt(now); l != 1 || a.String() != a1.String() {
		t.Fatalf("VECTOR 1 VIA THE HINT: a rewritten byte [3] moved the downlink to link %d at %v",
			l, a)
	}

	y, pr2, _, _, _ := newTestRx(nil)
	y.Handle(plain(FlagData, 3, 1, 1, seqPay(1)), a3, now)
	y.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), a1, now)
	y.Handle(plainHint(FlagData, 1, 2, 3, 1, seqPay(3)), a1, now)
	if l, _ := pr2.routeAt(now); l != 3 {
		t.Fatal("the control did not reproduce the attack: this test proves nothing")
	}
}

// TestServerPackEmitsHintZero is the server's copy of the client's
// TestPackStillEmitsHintZero (daemon/hint_test.go), which had no counterpart
// here -- a mirror gap in exactly the pair of files whose drift cost U34 a
// round (U48). This module's downlink DATA frames are the ONLY frames a client
// would read a hint out of, so "the server never hints its peer" has to be a
// bar, not a comment: main.go's downlink sender now calls PackRsvd with an
// explicit 0, and Pack -- still used by rx.go's echo path -- must keep meaning
// the same thing.
func TestServerPackEmitsHintZero(t *testing.T) {
	b := make([]byte, HdrLen+64)
	for _, fl := range []byte{FlagData, FlagPing, FlagPong, FlagFEC, FlagEcho} {
		n := Pack(b, fl, 4, 7, 8, 9, []byte("x"))
		if b[3] != 0 {
			t.Fatalf("Pack under flag %d wrote byte[3]=%d, want 0", fl, b[3])
		}
		if Rsvd(b[:n]) != 0 {
			t.Fatal("Rsvd disagrees with the byte Pack wrote")
		}
		// PackRsvd with an explicit 0 -- what main.go's downlink sender does --
		// must be byte-identical to it, or the call site changed the wire.
		c := make([]byte, HdrLen+64)
		m := PackRsvd(c, fl, 4, 0, 7, 8, 9, []byte("x"))
		if m != n || string(c[:m]) != string(b[:n]) {
			t.Fatalf("flag %d: PackRsvd(rsvd=0) is not Pack", fl)
		}
	}
}
