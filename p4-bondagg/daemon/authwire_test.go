package main

import (
	"net"
	"testing"
	"time"
)

// U31 fix round 3. These tests exist because the unit's own verify found that
// the client half of the transport MAC was a LIBRARY CALLED BY NOTHING, and
// that the three-point integration recipe written at the top of auth.go, if
// followed literally against the pull client's real buffers, PANICS on the
// first full-size frame and TRUNCATES every sealed frame on receive.
//
// So the recipe is EXECUTED here, against the same buffers the daemon
// allocates, rather than described. The wiring tests do not even compile
// against the pre-fix tree: PullLink had no gate.

// ---------------------------------------------------------------------------
// BUFFERS. The defect, as arithmetic: Pack fills at most MaxPayload+HdrLen =
// 1516 bytes, Seal writes 8 more, and the pull client's send buffer was
// exactly 1516 (pull.go Drive, pre-fix).
// ---------------------------------------------------------------------------

func TestPullSendBuffersCarryTheTrailer(t *testing.T) {
	if PullSendBufLen != MaxPayload+HdrLen+MacLen {
		t.Fatalf("PullSendBufLen=%d, want MaxPayload+HdrLen+MacLen=%d",
			PullSendBufLen, MaxPayload+HdrLen+MacLen)
	}
	if MacLen == 0 {
		t.Fatal("MacLen is zero; this test proves nothing")
	}
	if MaxAuthFrame != MaxFrame+MacLen {
		t.Fatalf("MaxAuthFrame=%d, want MaxFrame+MacLen=%d", MaxAuthFrame, MaxFrame+MacLen)
	}
}

// A full-size frame sealed in the buffer Drive actually allocates. Against the
// pre-fix buffer this is an index-out-of-range PANIC inside Seal, on a router
// with no console.
func TestSealAFullSizeFrameInTheRealSendBuffer(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, time.Second, roleClient)
	out := make([]byte, PullSendBufLen)
	pay := make([]byte, MaxPayload)
	n := Pack(out, FlagData, 0, 7, 1234, 0, pay)
	if n != MaxPayload+HdrLen {
		t.Fatalf("Pack returned %d, want %d", n, MaxPayload+HdrLen)
	}
	m := g.Seal(out, n, time.Now())
	if m != n+MacLen {
		t.Fatalf("Seal returned %d, want %d", m, n+MacLen)
	}
	if g.SealShort() != 0 {
		t.Fatalf("SealShort=%d, want 0", g.SealShort())
	}
}

// Seal must REFUSE a buffer with no headroom rather than write past it. A panic
// here is a daemon gone on a box with no console; returning n unsealed would
// emit FlagAuth with no tag, which the peer sheds as a forgery -- a silent
// stall that looks exactly like a bad key.
func TestSealRefusesAShortBuffer(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, time.Second, roleClient)
	pay := make([]byte, MaxPayload)
	short := make([]byte, MaxPayload+HdrLen) // the pre-fix buffer, exactly
	n := Pack(short, FlagData, 0, 7, 1234, 0, pay)
	flagsBefore := short[1]
	if m := g.Seal(short, n, time.Now()); m != -1 {
		t.Fatalf("Seal returned %d on a buffer with no headroom, want -1", m)
	}
	if short[1] != flagsBefore {
		t.Fatalf("Seal set FlagAuth (%#x -> %#x) on a frame it did not sign",
			flagsBefore, short[1])
	}
	if g.SealShort() != 1 {
		t.Fatalf("SealShort=%d, want 1", g.SealShort())
	}
}

// The RX side of the same arithmetic. A buffer of MaxFrame truncates a sealed
// full-size frame by exactly MacLen, and the server's own note says a truncated
// tag would look exactly like a bad tag -- so the link fails closed with
// authbad climbing and nothing saying why. Both halves are asserted: the
// truncated read is counted as a failed verify, and the correctly sized read
// verifies.
func TestPullRxBufferHoldsASealedFullSizeFrame(t *testing.T) {
	key := testKey(2)
	pay := make([]byte, MaxPayload)
	wire := mint(key, FlagData, 0, 9, 5678, pay) // a DOWNLINK frame, domS2C
	if len(wire) != HdrLen+MaxPayload+MacLen {
		t.Fatalf("sealed frame is %d bytes, want %d", len(wire), HdrLen+MaxPayload+MacLen)
	}
	if len(wire) > MaxAuthFrame {
		t.Fatalf("sealed frame %d exceeds MaxAuthFrame %d", len(wire), MaxAuthFrame)
	}
	if len(wire) <= MaxFrame {
		t.Fatalf("sealed frame %d fits in MaxFrame %d, so the truncation this test "+
			"is about cannot happen and the test proves nothing", len(wire), MaxFrame)
	}

	// What the pre-fix RX buffer delivered: ReadFromUDP into a MaxFrame buffer
	// returns at most MaxFrame bytes.
	g := newAuthGate([][]byte{key}, time.Second, roleClient)
	f, v := g.Admit(wire[:MaxFrame], time.Now())
	if v == admitPass && f.authed {
		t.Fatal("a truncated sealed frame verified")
	}
	if _, bad, _ := g.Counts(); bad == 0 {
		t.Fatal("the truncated frame was not counted as a failed verify -- it is " +
			"indistinguishable from a forgery, which is the whole defect")
	}

	// The correctly sized read.
	g2 := newAuthGate([][]byte{key}, time.Second, roleClient)
	f2, v2 := g2.Admit(wire, time.Now())
	if v2 != admitPass || !f2.authed {
		t.Fatalf("full sealed frame: verdict=%d authed=%v, want pass+authed", v2, f2.authed)
	}
	if len(f2.pay) != MaxPayload {
		t.Fatalf("payload len %d, want %d", len(f2.pay), MaxPayload)
	}
}

// ---------------------------------------------------------------------------
// WIRING. The gate is reachable from the pull client's send path, driven here
// through the real seam (linkSocket) rather than asserted by grep.
// ---------------------------------------------------------------------------

// End to end across the two mirrored modules' rules: a frame sealed by the
// CLIENT's send path must verify under a SERVER-role gate holding the same key,
// and must then close that gate against an unsigned forgery.
func TestPullSendSealsAndAServerRoleGateVerifies(t *testing.T) {
	key := testKey(3)
	client := &authTX{gate: newAuthGate([][]byte{key}, time.Second, roleClient)}
	server := newAuthGate([][]byte{key}, time.Second, roleServer)

	fs := newFakeSock(0, nil)
	l := newPullLinkSock(0, "if0", fs, testDst())
	l.auth = client
	out := make([]byte, PullSendBufLen)

	pay := make([]byte, MaxPayload)
	for i := range pay {
		pay[i] = byte(i)
	}
	if r := l.send(&PullFrame{seq: 11, enq: time.Now(), payload: pay}, out); r != sendOK {
		t.Fatalf("send=%d, want sendOK", r)
	}
	w := fs.frames()
	if len(w) != 1 {
		t.Fatalf("%d writes, want 1", len(w))
	}
	if len(w[0].b) != HdrLen+MaxPayload+MacLen {
		t.Fatalf("wrote %d bytes, want the SEALED length %d",
			len(w[0].b), HdrLen+MaxPayload+MacLen)
	}
	// Integration point 3: the meter counts the sealed length, because that is
	// what the server counts on arrival (server/rx.go OnData(len(b))).
	if l.Bytes() != uint64(len(w[0].b)) {
		t.Fatalf("sent-bytes meter counted %d, want the sealed %d", l.Bytes(), len(w[0].b))
	}
	f, v := server.Admit(w[0].b, time.Now())
	if v != admitPass || !f.authed {
		t.Fatalf("server verdict=%d authed=%v, want pass+authed", v, f.authed)
	}
	if f.seq != 11 || f.pid != 0 || len(f.pay) != MaxPayload {
		t.Fatalf("server read seq=%d pid=%d paylen=%d", f.seq, f.pid, len(f.pay))
	}
	// The gate is now CLOSED, so the forgery this unit exists to stop dies.
	if !server.Closed(time.Now()) {
		t.Fatal("the server gate did not close on a verified frame")
	}
	forged := plainFrame(FlagData, 0, 99, 1, []byte{1, 2, 3})
	if _, fv := server.Admit(forged, time.Now()); fv != admitShed {
		t.Fatalf("forgery verdict=%d, want admitShed", fv)
	}
}

// The keyless posture must be the pre-U31 wire byte for byte: no trailer, no
// FlagAuth bit. This is the compatibility half of the degradation argument and
// it is what makes wiring the gate in additive rather than a flag day.
func TestPullSendWithoutAKeyIsTheOldWire(t *testing.T) {
	fs := newFakeSock(0, nil)
	l := newPullLinkSock(0, "if0", fs, testDst())
	l.auth = &authTX{gate: newAuthGate(nil, time.Second, roleClient)}
	out := make([]byte, PullSendBufLen)
	pay := []byte{1, 2, 3, 4}
	if r := l.send(&PullFrame{seq: 5, enq: time.Now(), payload: pay}, out); r != sendOK {
		t.Fatalf("send=%d, want sendOK", r)
	}
	w := fs.frames()[0].b
	if len(w) != HdrLen+len(pay) {
		t.Fatalf("wrote %d bytes, want the UNSEALED %d", len(w), HdrLen+len(pay))
	}
	if w[1]&FlagAuth != 0 {
		t.Fatalf("FlagAuth set with no key loaded: flags=%#x", w[1])
	}
}

// A nil *authTX -- the field's zero value -- must be the same no-op, so a
// caller that knows nothing about the gate changes no behaviour.
func TestNilAuthIsANoOp(t *testing.T) {
	var a *authTX
	buf := make([]byte, PullSendBufLen)
	n := Pack(buf, FlagData, 0, 1, 2, 0, []byte{9})
	if m := a.Seal(buf, n, time.Now()); m != n {
		t.Fatalf("nil authTX Seal returned %d, want %d", m, n)
	}
	a.MarkRx(time.Now()) // must not panic
}

// SetAuth must reach EVERY link, for any N. One gate shared by all of them
// because the peer is one server; a per-link gate would let SendAuth's silence
// fallback fire on a link that merely went quiet.
func TestSetAuthReachesEveryLinkForAnyN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		names := make([]string, n)
		conns := make([]*net.UDPConn, n)
		for i := range names {
			names[i] = "if"
		}
		c := NewPullCore(names, conns, testDst())
		a := &authTX{gate: newAuthGate([][]byte{testKey(4)}, time.Second, roleClient)}
		c.SetAuth(a)
		for i := range c.Links {
			if c.Links[i].auth != a {
				t.Fatalf("N=%d: link %d did not receive the gate", n, i)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// THE REOPEN FLOOR. Prose said the horizon "has a floor from physics"; nothing
// enforced one, so AGG_AUTH_REOPEN_MS=1 was accepted and logged as normal.
// ---------------------------------------------------------------------------

func TestReopenFloorMatchesPeerLiveness(t *testing.T) {
	if ReopenFloor != DeadIval {
		t.Fatalf("ReopenFloor=%v, want DeadIval=%v -- the floor IS the peer's "+
			"liveness timer, not a number of its own", ReopenFloor, DeadIval)
	}
	if ReopenDefault < ReopenFloor {
		t.Fatalf("ReopenDefault %v is below its own floor %v", ReopenDefault, ReopenFloor)
	}
}

func TestClampReopenAppliesTheFloor(t *testing.T) {
	if got := clampReopen(time.Millisecond); got != ReopenFloor {
		t.Fatalf("clampReopen(1ms)=%v, want %v", got, ReopenFloor)
	}
	if got := clampReopen(ReopenFloor - time.Nanosecond); got != ReopenFloor {
		t.Fatalf("clampReopen(floor-1ns)=%v, want %v", got, ReopenFloor)
	}
	if got := clampReopen(30 * time.Second); got != 30*time.Second {
		t.Fatalf("clampReopen(30s)=%v, want it untouched", got)
	}
}
