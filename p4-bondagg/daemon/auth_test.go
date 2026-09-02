package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The client half of U31. The design argument lives in server/auth.go; these
// tests pin the two things that can silently diverge -- the wire construction
// (TestMacVector, which asserts the SAME bytes as the server module's test of
// the same name) and the degradation rules that keep a key mismatch from
// bricking a tunnel.

func testKey(n byte) []byte {
	k := make([]byte, KeyLen)
	for i := range k {
		k[i] = byte(i) ^ n
	}
	return k
}

// mint is an INDEPENDENT reimplementation of the tag, so a change to auth.go
// that also changes the wire cannot pass by agreeing with itself. It builds a
// DOWNLINK frame -- what the server sends this client -- because that is the
// direction this module's gate verifies.
func mint(key []byte, base, pid byte, seq, ts uint32, pay []byte) []byte {
	return mintDom(domS2C, key, base, pid, seq, ts, pay)
}

// mintDom is the same, in a chosen direction, so a test can mint the frame this
// CLIENT would have sent (domC2S) and check that its own gate refuses it.
func mintDom(dom byte, key []byte, base, pid byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay)+MacLen)
	n := Pack(b, base|FlagAuth, pid, seq, ts, 0, pay)
	m := hmac.New(sha256.New, key)
	var in [macInLen]byte
	in[0] = dom
	copy(in[1:1+HdrLen], b[:HdrLen])
	binary.BigEndian.PutUint16(in[1+HdrLen:], uint16(len(pay)))
	m.Write(in[:])
	copy(b[n:], m.Sum(nil)[:MacLen])
	return b[:n+MacLen]
}

func plainFrame(base, pid byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay))
	n := Pack(b, base, pid, seq, ts, 0, pay)
	return b[:n]
}

// FlagAuth must be a free BIT, so that a peer which does not know it sees an
// unrecognised flag VALUE and drops the frame (main.go:147 has no default arm)
// rather than misparsing it as a known flag -- the FlagEcho/FlagPong lesson.
func TestFlagAuthDoesNotCollide(t *testing.T) {
	if FlagAuth > 0x0F {
		t.Fatalf("FlagAuth %#x does not fit the header's 4-bit flag nibble", FlagAuth)
	}
	// 0x4 is the server's FlagEcho (server/frame.go). It is a literal here on
	// purpose: this module does not own that constant and must not declare it.
	for _, f := range []byte{FlagData, FlagPing, FlagPong, FlagFEC, 0x4} {
		if f&FlagAuth != 0 {
			t.Fatalf("base flag %#x already uses the FlagAuth bit %#x", f, FlagAuth)
		}
	}
}

// The SAME vector as server/auth_test.go TestMacVector. If these two ever
// disagree the two modules have stopped speaking the same wire.
func TestMacVector(t *testing.T) {
	key, err := hex.DecodeString("0102030405060708090a0b0c0d0e0f10" +
		"1112131415161718191a1b1c1d1e1f20")
	if err != nil {
		t.Fatal(err)
	}
	f := mint(key, FlagData, 7, 0x11223344, 0x55667788, make([]byte, 10))
	if got := hex.EncodeToString(f[:HdrLen]); got != "b0280700112233445566778800000000" {
		t.Fatalf("header = %s, want the pinned layout (ver 2, FlagAuth|FlagData)", got)
	}
	// Both directions, pinned to the same two strings as server/auth_test.go.
	// (Before domain separation both directions produced f2ae336fd4aee324.)
	if got := hex.EncodeToString(f[len(f)-MacLen:]); got != "8b5225da83d5c07a" {
		t.Fatalf("server->client tag = %s, want the pinned vector 8b5225da83d5c07a -- "+
			"this module and the server module must produce the same bytes", got)
	}
	u := mintDom(domC2S, key, FlagData, 7, 0x11223344, 0x55667788, make([]byte, 10))
	if got := hex.EncodeToString(u[len(u)-MacLen:]); got != "e9100d241ffbb0a1" {
		t.Fatalf("client->server tag = %s, want the pinned vector e9100d241ffbb0a1", got)
	}
	g := newAuthGate([][]byte{key}, ReopenDefault, roleClient)
	if !g.verify(f, time.Now()) {
		t.Fatal("the gate rejected a frame minted by the independent implementation")
	}
}

// The client's own uplink frame, reflected back at it, must not authenticate as
// a downlink frame. Mirror of server/auth_test.go TestDomainSeparationBindsDirection.
func TestDomainSeparationBindsDirection(t *testing.T) {
	key := testKey(5)
	now := time.Now()
	g := newAuthGate([][]byte{key}, ReopenDefault, roleClient)
	if g.verify(mintDom(domC2S, key, FlagData, 1, 42, 7, []byte("reflected")), now) {
		t.Fatal("the client accepted a frame tagged in its OWN sending direction")
	}
	if !g.verify(mintDom(domS2C, key, FlagData, 1, 42, 7, []byte("reflected")), now) {
		t.Fatal("the control did not verify: this test is not measuring the domain")
	}
	if domC2S == domS2C || domC2S == 0 || domS2C == 0 {
		t.Fatalf("domC2S=%#x domS2C=%#x: the two directions must differ and neither "+
			"may be zero", domC2S, domS2C)
	}
}

func TestMacTruncationIsEightBytes(t *testing.T) {
	if MacLen != 8 {
		t.Fatalf("MacLen = %d: see the derivation in server/auth.go", MacLen)
	}
	if KeyLen != sha256.Size {
		t.Fatalf("KeyLen = %d, want HMAC-SHA-256's output length %d", KeyLen, sha256.Size)
	}
	if MaxAuthFrame != MaxFrame+MacLen {
		t.Fatal("an RX buffer sized MaxFrame truncates an authenticated frame, which " +
			"is indistinguishable from a bad tag")
	}
}

func TestLoadKeysParsesAndSkipsJunk(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "transport.key")
	body := "# per-install secret\n\n" + hex.EncodeToString(testKey(1)) + "\n" +
		"   " + hex.EncodeToString(testKey(2)) + "   # retiring\n" + "not-hex\naabb\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	keys, err := LoadKeys(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 || !hmac.Equal(keys[0], testKey(1)) || !hmac.Equal(keys[1], testKey(2)) {
		t.Fatalf("loaded %d keys, want the 2 well-formed ones in file order", len(keys))
	}
	if _, err := LoadKeys(filepath.Join(dir, "absent")); err == nil {
		t.Fatal("a missing key file must be reported, so the caller can log and run unauthenticated")
	}
}

func TestGateClosedRejectsUnauthenticated(t *testing.T) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleClient)
	now := time.Now()
	if _, v := g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
		t.Fatal("a correctly tagged frame was refused")
	}
	if _, v := g.Admit(plainFrame(FlagData, 0, 2, 1, []byte("x")), now); v != admitShed {
		t.Fatal("an unauthenticated downlink frame was accepted while the gate was closed")
	}
}

// The client is recoverable, but a downlink that dies on a key mismatch is still
// an outage. Same reopen rule as the server.
func TestGateReopensAfterAKeyMismatch(t *testing.T) {
	mine, theirs := testKey(1), testKey(2)
	g := newAuthGate([][]byte{mine}, 10*time.Second, roleClient)
	t0 := time.Now()
	g.Admit(mint(mine, FlagData, 0, 1, 1, []byte("x")), t0)
	bad := mint(theirs, FlagData, 0, 2, 1, []byte("x"))
	if _, v := g.Admit(bad, t0.Add(time.Second)); v != admitShed {
		t.Fatal("a wrong-key frame was served while the gate was still closed")
	}
	if _, v := g.Admit(bad, t0.Add(11*time.Second)); v != admitPass {
		t.Fatal("the gate never reopened after a key mismatch")
	}
}

func TestMismatchedKeyKeepsThePayloadIntact(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, 10*time.Second, roleClient)
	pay := []byte("the whole wireguard datagram")
	f, v := g.Admit(mint(testKey(2), FlagData, 0, 1, 1, pay), time.Now())
	if v != admitPass {
		t.Fatal("setup: the gate was not open")
	}
	if string(f.pay) != string(pay) {
		t.Fatalf("payload = %q, want %q: the tag trailer was not stripped", f.pay, pay)
	}
}

func TestGateWithoutKeysNeverCloses(t *testing.T) {
	g := newAuthGate(nil, ReopenDefault, roleClient)
	now := time.Now()
	if g.Enabled() || g.Closed(now) {
		t.Fatal("a keyless gate reported itself enabled or closed")
	}
	f, v := g.Admit(mint(testKey(1), FlagData, 0, 1, 1, []byte("payload")), now)
	if v != admitPass || string(f.pay) != "payload" {
		t.Fatal("a keyless client mishandled an authenticated frame from the server")
	}
	if n := g.Seal(make([]byte, HdrLen+MacLen), HdrLen, now); n != HdrLen {
		t.Fatal("a keyless client signed a frame")
	}
	if g.SendAuth(now, now) {
		t.Fatal("a keyless client tried to send authenticated frames")
	}
}

// The client initiates, so it signs with the first key in its own file until a
// peer's frame has verified -- after which it signs with the key that verified,
// which is what makes a mid-rollover server able to read it.
func TestClientSignsWithTheFirstKeyUntilAPeerVerifies(t *testing.T) {
	first, second := testKey(1), testKey(2)
	g := newAuthGate([][]byte{first, second}, ReopenDefault, roleClient)
	now := time.Now()
	buf := make([]byte, HdrLen+8+MacLen)
	n := g.Seal(buf, Pack(buf, FlagData, 0, 1, 1, 0, make([]byte, 8)), now)
	if !newAuthGate([][]byte{first}, ReopenDefault, roleServer).verify(buf[:n], now) {
		t.Fatal("the client did not sign with the first key in its file")
	}
	g.Admit(mint(second, FlagData, 0, 1, 1, []byte("x")), now)
	n = g.Seal(buf, Pack(buf, FlagData, 0, 2, 1, 0, make([]byte, 8)), now)
	if !newAuthGate([][]byte{second}, ReopenDefault, roleServer).verify(buf[:n], now) {
		t.Fatal("after verifying under the second key the client kept signing with the first")
	}
}

// THE CLIENT LOCKOUT TEST. A server too old to know FlagAuth drops every
// authenticated frame as an unknown flag value. Nothing reports that; the tunnel
// is simply dead. After the horizon of sealing into silence the client stops
// sealing.
func TestSendAuthFallsBackOnSilence(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, 10*time.Second, roleClient)
	t0 := time.Now()
	if !g.SendAuth(t0, t0) {
		t.Fatal("the client refused to try authenticating at all")
	}
	if !g.SendAuth(t0.Add(5*time.Second), t0) {
		t.Fatal("the client gave up before the horizon")
	}
	if g.SendAuth(t0.Add(11*time.Second), t0) {
		t.Fatal("the client sealed into silence past the horizon: an old server would " +
			"drop every frame and nothing would ever recover")
	}
	if g.SendAuth(t0.Add(12*time.Second), t0.Add(11*time.Second)) {
		t.Fatal("the fallback is not sticky: it will oscillate between a working and a " +
			"dead tunnel forever")
	}
}

// ...but traffic FROM the peer, or one verified frame, means the far side is
// listening, and the client must keep authenticating.
func TestSendAuthStaysOnOnceThePeerVerifies(t *testing.T) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, 10*time.Second, roleClient)
	t0 := time.Now()
	g.SendAuth(t0, t0)
	g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), t0.Add(time.Second))
	if !g.SendAuth(t0.Add(60*time.Second), t0.Add(time.Second)) {
		t.Fatal("the client stopped authenticating a peer that had verified")
	}
	// And plain silence short of the horizon must not trip it either.
	h := newAuthGate([][]byte{key}, 10*time.Second, roleClient)
	h.SendAuth(t0, t0)
	if !h.SendAuth(t0.Add(11*time.Second), t0.Add(9*time.Second)) {
		t.Fatal("the client fell back while the peer was still answering")
	}
}

// Seal then Admit through a second gate holding the same key: the round trip a
// real deployment makes across the two modules.
func TestSealRoundTrips(t *testing.T) {
	key := testKey(7)
	tx := newAuthGate([][]byte{key}, ReopenDefault, roleClient)
	rx := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	now := time.Now()
	pay := []byte("wireguard bytes")
	buf := make([]byte, HdrLen+len(pay)+MacLen)
	n := tx.Seal(buf, Pack(buf, FlagData, 3, 9, 11, 0, pay), now)
	f, v := rx.Admit(buf[:n], now)
	if v != admitPass || !f.authed {
		t.Fatal("a sealed frame did not verify at the far end")
	}
	if f.base != FlagData || f.pid != 3 || f.seq != 9 || f.ts != 11 {
		t.Fatalf("header lost in the round trip: base=%#x pid=%d seq=%d ts=%d",
			f.base, f.pid, f.seq, f.ts)
	}
	if string(f.pay) != string(pay) {
		t.Fatalf("payload = %q, want %q", f.pay, pay)
	}
}
