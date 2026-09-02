package main

import (
	"encoding/binary"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// THE FOUR FORGERY VECTORS, one test each, driven through the real rxPath.
//
// Every test here carries a POSITIVE CONTROL: the same attack run against a
// keyless gate, asserting that it SUCCEEDS. Without that half the test could
// pass because the attack never worked, or because the harness never delivered
// the frame -- the shape of a bar that measures nothing. The control is also
// the regression test for the degraded posture: it pins exactly what an install
// with no key file is still exposed to.

func mustAddr(t *testing.T, s string) *net.UDPAddr {
	t.Helper()
	a, err := net.ResolveUDPAddr("udp4", s)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// newTestRx builds the real receive path over a real ring, with no sockets.
// keys == nil is the pre-U31 server: authentication off.
func newTestRx(keys [][]byte) (*rxPath, *peers, *echoBudget, *Ring, *[]uint32) {
	pr := &peers{}
	st := &LinkStats{}
	bud := &echoBudget{}
	owd := &OWD{}
	got := new([]uint32)
	ring := NewRing(4, 20*time.Millisecond, func(b []byte) {
		if len(b) >= 4 {
			*got = append(*got, binary.BigEndian.Uint32(b))
		}
	})
	g := newAuthGate(keys, 10*time.Second, roleServer)
	x := newRxPath(g, pr, st, bud, owd, ring, 5*time.Millisecond, 20*time.Millisecond)
	return x, pr, bud, ring, got
}

// seqPay makes a payload whose first 4 bytes are the seq, so the ring's output
// identifies which frame came out.
//
// SIZED, not arbitrary. The echo budget bills replies against DATA bytes
// received (echo.go), and the smallest possible echo is HdrLen + echoHdrLen +
// one 18-byte record = 40 bytes. A test whose setup frame is smaller than that
// gets its echo SHED by the budget, so every "no echo was sent" assertion would
// pass without the auth gate doing anything -- the shape of a bar that measures
// nothing. 64 bytes of payload puts one setup frame's credit at 80, comfortably
// above the 40-byte echo, so a reply that does not appear is the gate's doing.
func seqPay(seq uint32) []byte {
	b := make([]byte, 64)
	binary.BigEndian.PutUint32(b, seq)
	return b
}

// VECTOR 1 -- ROADMAP U31: "one forged DATA frame redirects the whole downlink".
// pr.learn ran on ANY accepted DATA frame and route() returns `last`, so a
// single forged 17-byte frame sent ALL downlink to the attacker's address until
// the next legitimate arrival.
func TestForgedDataFrameCannotRedirectTheDownlink(t *testing.T) {
	key := testKey(1)
	cli := mustAddr(t, "203.0.113.9:59402")
	atk := mustAddr(t, "198.51.100.7:1234")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, seqPay(1)), cli, now)
	if _, a := pr.route(); a.String() != cli.String() {
		t.Fatalf("setup: downlink routes to %v, want the client %v", a, cli)
	}
	x.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), atk, now)
	if _, a := pr.route(); a.String() != cli.String() {
		t.Fatalf("VECTOR 1 OPEN: one forged frame moved the downlink to %v", a)
	}

	// Positive control: with no key the same forged frame still redirects.
	y, pr2, _, _, _ := newTestRx(nil)
	y.Handle(plain(FlagData, 1, 1, 1, seqPay(1)), cli, now)
	y.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), atk, now)
	if _, a := pr2.route(); a.String() != atk.String() {
		t.Fatal("the control did not reproduce the attack: this test proves nothing")
	}
}

// VECTOR 2 -- ROADMAP U31: "~90x per-source echo reflection". A spoofed 16-byte
// ping drew an echo of up to 1498 bytes to an address of the attacker's
// choosing, billed against the real client's credit.
func TestForgedPingCannotReflectToAThirdParty(t *testing.T) {
	key := testKey(1)
	cli := mustAddr(t, "203.0.113.9:59402")
	victim := mustAddr(t, "192.0.2.55:53")
	now := time.Now()

	x, _, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, seqPay(1)), cli, now)
	out, dst := x.Handle(plain(FlagPing, 1, 0, 7, nil), victim, now)
	if out != nil {
		t.Fatalf("VECTOR 2 OPEN: a forged ping drew a %d-byte echo to %v", len(out), dst)
	}
}

// With authentication OFF, the ping's SOURCE ADDRESS is no longer an aiming
// primitive: the echo goes to the link's learned endpoint instead. That is the
// only part of vector 2 that survives the gate being open, and it is narrower
// than "reflection is closed" -- see TestOpenGateReflectsViaAForgedDataFrame
// directly below, which is the other half of the truth.
func TestDegradedGateRefusesToReflectAtThePingSource(t *testing.T) {
	cli := mustAddr(t, "203.0.113.9:59402")
	victim := mustAddr(t, "192.0.2.55:53")
	now := time.Now()

	x, _, _, _, _ := newTestRx(nil)
	x.Handle(plain(FlagData, 1, 1, 1, seqPay(1)), cli, now)
	out, dst := x.Handle(plain(FlagPing, 1, 0, 7, nil), victim, now)
	if out == nil {
		t.Fatal("setup: an unauthenticated install stopped echoing altogether")
	}
	if dst.String() != cli.String() {
		t.Fatalf("VECTOR 2 OPEN with auth off: echo went to %v, want the learned client %v",
			dst, cli)
	}
	if len(out) <= len(plain(FlagPing, 1, 0, 7, nil)) {
		t.Fatal("the echo is no bigger than the ping: nothing here is about amplification")
	}
}

// VECTOR 2, THE PART THAT IS STILL OPEN. This unit's first write-up said vector
// 2 was "closed unconditionally -- there is no victim to aim at even with auth
// off". That is false, and this test is the demonstration rather than a
// correction in prose.
//
// The endpoint an echo is sent to is LEARNED from DATA frames, and with the gate
// open a forged DATA frame is an accepted DATA frame (rx.go). So the attacker
// spends ONE forgery to install the victim as the link's endpoint, and every
// later 16-byte ping -- forged, from anywhere -- draws a full echo at the
// victim. What the endpoint rule bought is that reflection now costs a forged
// DATA frame instead of a free ping, and that the same forgery redirects the
// client's downlink, so it cannot be done quietly.
//
// The closing half of this test is the contrast: with a key configured the same
// sequence reflects nothing.
func TestOpenGateReflectsViaAForgedDataFrame(t *testing.T) {
	cli := mustAddr(t, "203.0.113.9:59402")
	victim := mustAddr(t, "192.0.2.55:53")
	now := time.Now()

	x, pr, _, _, _ := newTestRx(nil) // no key: the posture of every install today
	x.Handle(plain(FlagData, 1, 1, 1, seqPay(1)), cli, now)
	// One forged DATA frame, source-spoofed as the victim.
	x.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), victim, now)
	out, dst := x.Handle(plain(FlagPing, 1, 0, 7, nil), mustAddr(t, "198.51.100.7:1234"), now)
	if out == nil || dst.String() != victim.String() {
		t.Fatalf("the residual did not reproduce: echo went to %v. If this now fails "+
			"because reflection is genuinely shut with the gate OPEN, that is a real "+
			"improvement -- rewrite the claim, do not delete the test", dst)
	}
	if len(out) <= len(plain(FlagPing, 1, 0, 7, nil)) {
		t.Fatal("the echo is no bigger than the ping that drew it: nothing here is " +
			"about amplification")
	}
	if _, a := pr.route(); a.String() != victim.String() {
		t.Fatal("the same forged frame is supposed to have redirected the downlink too: " +
			"that is what makes this loud rather than cheap")
	}

	// With a key on both ends the whole sequence is refused.
	y, _, _, _, _ := newTestRx([][]byte{testKey(1)})
	y.Handle(mint(testKey(1), FlagData, 1, 1, 1, seqPay(1)), cli, now)
	y.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), victim, now)
	out2, dst2 := y.Handle(plain(FlagPing, 1, 0, 7, nil), mustAddr(t, "198.51.100.7:1234"), now)
	if out2 != nil {
		t.Fatalf("VECTOR 2 OPEN with the gate CLOSED: %d bytes to %v", len(out2), dst2)
	}
}

// A ping on a link this server has never accepted data on gets no echo at all --
// there is no address it could be sent to that the client itself has not proven.
func TestPingOnAnUnknownLinkDrawsNoEcho(t *testing.T) {
	now := time.Now()
	before := atomic.LoadUint64(&statEchoNoEp)
	x, _, _, _, _ := newTestRx(nil)
	out, _ := x.Handle(plain(FlagPing, 200, 0, 7, nil), mustAddr(t, "198.51.100.7:1"), now)
	if out != nil {
		t.Fatal("a ping on an unlearned link drew a reply to its own source address")
	}
	if atomic.LoadUint64(&statEchoNoEp) == before {
		t.Fatal("the drop was not counted (statEchoNoEp)")
	}
}

// VECTOR 3 -- ROADMAP U31: "meter starvation". Attacker pings drained the shared
// echo credit so the real client's echoes were shed, blinding the cap meter
// without touching the data path. A refused ping must not reach bud.spend.
func TestForgedPingCannotStarveTheEchoBudget(t *testing.T) {
	key := testKey(1)
	cli := mustAddr(t, "203.0.113.9:59402")
	atk := mustAddr(t, "198.51.100.7:1234")
	now := time.Now()

	x, _, bud, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, make([]byte, 1200)), cli, now)
	credit := atomic.LoadInt64(&bud.credit)
	for i := 0; i < 50; i++ {
		x.Handle(plain(FlagPing, 1, 0, uint32(i), nil), atk, now)
	}
	if got := atomic.LoadInt64(&bud.credit); got != credit {
		t.Fatalf("VECTOR 3 OPEN: 50 forged pings spent %d bytes of the client's credit",
			credit-got)
	}

	// Positive control: with no key the same flood drains the credit.
	y, _, bud2, _, _ := newTestRx(nil)
	y.Handle(plain(FlagData, 1, 1, 1, make([]byte, 1200)), cli, now)
	c2 := atomic.LoadInt64(&bud2.credit)
	for i := 0; i < 50; i++ {
		y.Handle(plain(FlagPing, 1, 0, uint32(i), nil), atk, now)
	}
	if atomic.LoadInt64(&bud2.credit) >= c2 {
		t.Fatal("the control did not reproduce the drain: this test proves nothing")
	}
}

// VECTOR 4 -- ROADMAP U31: "a forged far-future seq costs a full hold of uplink".
// Push re-anchors `next` onto the forged seq and every legitimate frame is then
// beyond-window-old and dropped WITHOUT being stored. The ring cannot tell a
// forgery from a peer restart, so this is only fixable by authentication.
func TestForgedFarSeqCannotReanchorTheRing(t *testing.T) {
	key := testKey(1)
	cli := mustAddr(t, "203.0.113.9:59402")
	atk := mustAddr(t, "198.51.100.7:1234")
	t0 := time.Now()

	x, _, _, ring, got := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, seqPay(1)), cli, t0)
	ring.Tick(t0.Add(30 * time.Millisecond))
	x.Handle(plain(FlagData, 1, 1<<30, 1, seqPay(1<<30)), atk, t0.Add(40*time.Millisecond))
	x.Handle(mint(key, FlagData, 1, 2, 1, seqPay(2)), cli, t0.Add(50*time.Millisecond))
	ring.Tick(t0.Add(100 * time.Millisecond))
	eq(t, *got, 1, 2)

	// Positive control: with no key the forgery re-anchors and seq 2 is lost.
	y, _, _, ring2, got2 := newTestRx(nil)
	y.Handle(plain(FlagData, 1, 1, 1, seqPay(1)), cli, t0)
	ring2.Tick(t0.Add(30 * time.Millisecond))
	y.Handle(plain(FlagData, 1, 1<<30, 1, seqPay(1<<30)), atk, t0.Add(40*time.Millisecond))
	y.Handle(plain(FlagData, 1, 2, 1, seqPay(2)), cli, t0.Add(50*time.Millisecond))
	ring2.Tick(t0.Add(100 * time.Millisecond))
	for _, s := range *got2 {
		if s == 2 {
			t.Fatal("the control did not reproduce the uplink loss: this test proves nothing")
		}
	}
}

// An authenticated ping may refresh its link's ENDPOINT (the client's NAT
// binding can move between two data frames, and the echo has to reach it) but
// must not move the downlink ROUTE, which stays a DATA-only decision.
func TestAuthenticatedPingRefreshesTheEndpointNotTheRoute(t *testing.T) {
	key := testKey(1)
	a1 := mustAddr(t, "203.0.113.9:1111")
	a2 := mustAddr(t, "203.0.113.9:2222")
	b1 := mustAddr(t, "203.0.113.10:3333")
	now := time.Now()

	x, pr, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, seqPay(1)), a1, now)
	x.Handle(mint(key, FlagData, 2, 2, 1, seqPay(2)), b1, now)
	x.Handle(mint(key, FlagPing, 1, 0, 7, nil), a2, now)
	if ep := pr.endpoint(1); ep.String() != a2.String() {
		t.Fatalf("link 1 endpoint = %v, want the rebound %v", ep, a2)
	}
	link, addr := pr.route()
	if link != 2 || addr.String() != b1.String() {
		t.Fatalf("a ping moved the downlink route to link %d / %v", link, addr)
	}
}

// The echo itself is signed once the gate is closed, so the client can reject a
// forged echo the same way the server rejects a forged frame. Without this the
// meter is authenticated in one direction only.
func TestEchoIsSignedWhenTheGateIsClosed(t *testing.T) {
	key := testKey(1)
	cli := mustAddr(t, "203.0.113.9:59402")
	now := time.Now()

	x, _, _, _, _ := newTestRx([][]byte{key})
	x.Handle(mint(key, FlagData, 1, 1, 1, make([]byte, 1200)), cli, now)
	out, dst := x.Handle(mint(key, FlagPing, 1, 0, 7, nil), cli, now)
	if out == nil {
		t.Fatal("an authenticated ping drew no echo")
	}
	if dst.String() != cli.String() {
		t.Fatalf("echo went to %v, want %v", dst, cli)
	}
	if out[1]&0x0F&FlagAuth == 0 {
		t.Fatal("the echo went out unsigned while the gate was closed")
	}
	client := newAuthGate([][]byte{key}, ReopenDefault, roleClient)
	if !client.verify(out, now) {
		t.Fatal("the client could not verify the server's echo")
	}
}

// An install with no key file must still forward, meter and echo. This is the
// posture every box is in until the deploy puts a secret on both of them.
func TestUnauthenticatedInstallStillWorks(t *testing.T) {
	cli := mustAddr(t, "203.0.113.9:59402")
	t0 := time.Now()

	x, pr, _, ring, got := newTestRx(nil)
	x.Handle(plain(FlagData, 1, 1, 1, seqPay(1)), cli, t0)
	ring.Tick(t0.Add(30 * time.Millisecond))
	eq(t, *got, 1)
	if _, a := pr.route(); a.String() != cli.String() {
		t.Fatal("an unauthenticated install stopped routing the downlink")
	}
	out, dst := x.Handle(plain(FlagPing, 1, 0, 7, nil), cli, t0)
	if out == nil || dst.String() != cli.String() {
		t.Fatal("an unauthenticated install stopped echoing to its own client")
	}
	if out[1]&0x0F&FlagAuth != 0 {
		t.Fatal("a keyless server signed a frame")
	}
}
