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

// ---- test helpers ------------------------------------------------------------

// testKey returns a deterministic distinct KeyLen-byte key.
func testKey(n byte) []byte {
	k := make([]byte, KeyLen)
	for i := range k {
		k[i] = byte(i) ^ n
	}
	return k
}

// mint builds an UPLINK frame -- what the client sends this server -- and tags
// it with an INDEPENDENT reimplementation of the MAC construction, deliberately
// not a call to authGate, so a change to the production code that also changes
// the wire cannot pass by agreeing with itself. It is the client half of the
// wire in test form.
func mint(key []byte, base, pid byte, seq, ts uint32, pay []byte) []byte {
	return mintDom(domC2S, key, base, pid, seq, ts, pay)
}

// mintDom is the same, in a chosen direction. It is separate so a test can mint
// the frame the SERVER would have sent (domS2C) and check what happens when it
// is aimed back at the server.
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

// plain builds an unauthenticated frame: exactly what the wire carried before
// this unit, and exactly what an off-path attacker can build.
func plain(base, pid byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay))
	n := Pack(b, base, pid, seq, ts, 0, pay)
	return b[:n]
}

// ---- the primitive -----------------------------------------------------------

// FlagAuth must be a free BIT in the 4-bit flag nibble, not a new flag value:
// the whole reason it is a bit and not a Ver bump is that an un-upgraded peer
// must DROP an authenticated frame, and it can only do that if the value it sees
// is one its switch does not know.
func TestFlagAuthDoesNotCollide(t *testing.T) {
	if FlagAuth > 0x0F {
		t.Fatalf("FlagAuth %#x does not fit the header's 4-bit flag nibble", FlagAuth)
	}
	for _, f := range []byte{FlagData, FlagPing, FlagPong, FlagFEC, FlagEcho} {
		if f&FlagAuth != 0 {
			t.Fatalf("base flag %#x already uses the FlagAuth bit %#x: setting it would "+
				"turn one known flag into another", f, FlagAuth)
		}
	}
}

// The tag is pinned to bytes computed OUTSIDE Go (python hmac/hashlib), so this
// test fails if the construction changes on either side of the wire. The same
// vector is asserted in the daemon module (daemon/auth_test.go
// TestMacVector) -- the two modules duplicate the code the way frame.go is
// duplicated, and this is what keeps the two copies honest.
func TestMacVector(t *testing.T) {
	key, err := hex.DecodeString("0102030405060708090a0b0c0d0e0f10" +
		"1112131415161718191a1b1c1d1e1f20")
	if err != nil {
		t.Fatal(err)
	}
	pay := make([]byte, 10)
	f := mint(key, FlagData, 7, 0x11223344, 0x55667788, pay)
	if got := hex.EncodeToString(f[:HdrLen]); got != "b0280700112233445566778800000000" {
		t.Fatalf("header = %s, want the pinned layout (ver 2, FlagAuth|FlagData)", got)
	}
	// The SAME header and length, tagged in the two directions, must give two
	// DIFFERENT pinned strings. Both are pinned, so neither the construction nor
	// the domain bytes can drift on one side of the wire only. (Before domain
	// separation both directions produced f2ae336fd4aee324.)
	if got := hex.EncodeToString(f[len(f)-MacLen:]); got != "e9100d241ffbb0a1" {
		t.Fatalf("client->server tag = %s, want the pinned vector e9100d241ffbb0a1 "+
			"(HMAC-SHA-256 over domC2S||header||be16(10), truncated to %d bytes)", got, MacLen)
	}
	d := mintDom(domS2C, key, FlagData, 7, 0x11223344, 0x55667788, pay)
	if got := hex.EncodeToString(d[len(d)-MacLen:]); got != "8b5225da83d5c07a" {
		t.Fatalf("server->client tag = %s, want the pinned vector 8b5225da83d5c07a", got)
	}
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	if !g.verify(f, time.Now()) {
		t.Fatal("the gate rejected a frame minted by the independent implementation")
	}
}

// DOMAIN SEPARATION. Nothing in the header says which way a frame travels, so
// without the domain byte the server's own signed downlink frame is a valid
// UPLINK frame: bounce it back and the server authenticates it as its client.
// The control is the same header and payload minted in the uplink direction,
// which must verify -- so the failure below is the DIRECTION and not the bytes.
func TestDomainSeparationBindsDirection(t *testing.T) {
	key := testKey(5)
	now := time.Now()
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)

	// What the server itself would put on the wire, aimed back at the server.
	if g.verify(mintDom(domS2C, key, FlagData, 1, 42, 7, []byte("reflected")), now) {
		t.Fatal("the server accepted a frame tagged in its OWN sending direction: a " +
			"reflected downlink frame authenticates as an uplink frame")
	}
	// Control: identical in every byte except the domain.
	if !g.verify(mintDom(domC2S, key, FlagData, 1, 42, 7, []byte("reflected")), now) {
		t.Fatal("the control did not verify: this test is not measuring the domain")
	}
	if domC2S == domS2C || domC2S == 0 || domS2C == 0 {
		t.Fatalf("domC2S=%#x domS2C=%#x: the two directions must differ and neither "+
			"may be zero, or an unwritten byte is a valid domain", domC2S, domS2C)
	}
}

// The truncation length is a security parameter, not a layout detail: at 8 bytes
// a blind forgery is 2^-64 per attempt. Pin it so a "space saving" cannot shrink
// it quietly.
func TestMacTruncationIsEightBytes(t *testing.T) {
	if MacLen != 8 {
		t.Fatalf("MacLen = %d: see the derivation in auth.go -- 4 bytes is about "+
			"48 minutes of gigabit forgery, not a security bound", MacLen)
	}
	if KeyLen != sha256.Size {
		t.Fatalf("KeyLen = %d, want HMAC-SHA-256's output length %d", KeyLen, sha256.Size)
	}
	pay := make([]byte, 100)
	f := mint(testKey(1), FlagData, 0, 1, 1, pay)
	if len(f) != HdrLen+len(pay)+MacLen {
		t.Fatalf("sealed frame = %d bytes, want %d", len(f), HdrLen+len(pay)+MacLen)
	}
}

// Every bit of the header and every payload length is inside the MAC. This is
// the test that says which fields are actually protected -- pathID, seq, txstamp
// and the flags byte are all decisions the server makes, so all of them must be
// covered.
func TestMacCoversEveryHeaderByteAndTheLength(t *testing.T) {
	key := testKey(2)
	now := time.Now()
	pay := []byte("0123456789")
	good := mint(key, FlagData, 3, 4242, 99, pay)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	if !g.verify(good, now) {
		t.Fatal("the unmodified frame did not verify")
	}
	for i := 0; i < HdrLen; i++ {
		for bit := 0; bit < 8; bit++ {
			b := append([]byte(nil), good...)
			b[i] ^= 1 << bit
			if _, _, _, _, _, _, err := Unpack(b); err != nil {
				continue // magic/ver: rejected before the MAC, which is stricter
			}
			if g.verify(b, now) {
				t.Fatalf("header byte %d bit %d is outside the MAC", i, bit)
			}
		}
	}
	// Length: same header, one byte more and one byte less of payload.
	longer := append(append([]byte(nil), good[:len(good)-MacLen]...), 0)
	longer = append(longer, good[len(good)-MacLen:]...)
	if g.verify(longer, now) {
		t.Fatal("the payload LENGTH is outside the MAC: the meter counts wire bytes")
	}
	shorter := append(append([]byte(nil), good[:len(good)-MacLen-1]...), good[len(good)-MacLen:]...)
	if g.verify(shorter, now) {
		t.Fatal("a truncated payload still verified")
	}
}

func TestLoadKeysParsesAndSkipsJunk(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "transport.key")
	body := "# per-install secret\n\n" +
		hex.EncodeToString(testKey(1)) + "\n" +
		"   " + hex.EncodeToString(testKey(2)) + "   # the key being retired\n" +
		"not-hex\n" +
		"aabb\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	keys, err := LoadKeys(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 {
		t.Fatalf("loaded %d keys, want 2 (comments, blanks and malformed lines are skipped)", len(keys))
	}
	if !hmac.Equal(keys[0], testKey(1)) || !hmac.Equal(keys[1], testKey(2)) {
		t.Fatal("keys came back in the wrong order or wrong content")
	}
	if _, err := LoadKeys(filepath.Join(dir, "absent")); err == nil {
		t.Fatal("a missing key file must be reported to the caller, which logs and runs unauthenticated")
	}
}

// ---- the gate ----------------------------------------------------------------

// Before any valid tag has been seen the gate is OPEN: a server upgraded ahead
// of its client keeps serving that client. This is the property that makes the
// upgrade order irrelevant on a box with no console.
func TestGateOpenUntilFirstValidTag(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, ReopenDefault, roleServer)
	now := time.Now()
	if g.Closed(now) {
		t.Fatal("the gate started closed: an un-upgraded client would be locked out")
	}
	if _, v := g.Admit(plain(FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
		t.Fatal("an unauthenticated frame was refused before any tag had ever verified")
	}
}

// Once a valid tag has been seen, unauthenticated frames are refused. This is
// the sentence the four vector tests depend on.
func TestGateClosedRejectsUnauthenticated(t *testing.T) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	now := time.Now()
	if _, v := g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
		t.Fatal("a correctly tagged frame was refused")
	}
	if !g.Closed(now) {
		t.Fatal("a valid tag did not close the gate")
	}
	if _, v := g.Admit(plain(FlagData, 0, 2, 1, []byte("x")), now); v != admitShed {
		t.Fatal("an unauthenticated frame was served while the gate was closed")
	}
}

// A forged frame must not refresh the gate's freshness in either direction: it
// cannot close the gate (it has no tag) and it cannot hold it closed or open.
func TestForgedFramesDoNotRefreshTheGate(t *testing.T) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, 10*time.Second, roleServer)
	t0 := time.Now()
	g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), t0)
	for i := 0; i < 100; i++ {
		g.Admit(plain(FlagData, 0, uint32(i), 1, []byte("x")), t0.Add(time.Second))
	}
	if !g.Closed(t0.Add(9 * time.Second)) {
		t.Fatal("forged traffic re-opened the gate early")
	}
	if g.Closed(t0.Add(11 * time.Second)) {
		t.Fatal("forged traffic held the gate closed past the horizon: a client whose " +
			"key stopped matching would never be served again")
	}
}

// THE LOCKOUT TEST. The server has no physical access, so the one thing this
// design may never do is refuse the real client forever over a configuration
// mismatch. After the reopen horizon the tunnel comes back, unauthenticated.
func TestGateReopensAfterAKeyMismatch(t *testing.T) {
	server, client := testKey(1), testKey(2)
	g := newAuthGate([][]byte{server}, 10*time.Second, roleServer)
	t0 := time.Now()
	if _, v := g.Admit(mint(server, FlagData, 0, 1, 1, []byte("x")), t0); v != admitPass {
		t.Fatal("setup: the pre-rollover frame did not verify")
	}
	mismatch := mint(client, FlagData, 0, 2, 1, []byte("x"))
	if _, v := g.Admit(mismatch, t0.Add(time.Second)); v != admitShed {
		t.Fatal("a wrong-key frame was served while the gate was still closed")
	}
	f, v := g.Admit(mismatch, t0.Add(11*time.Second))
	if v != admitPass {
		t.Fatal("the gate never reopened: a key mismatch has bricked a box with no console")
	}
	if f.authed {
		t.Fatal("a wrong-key frame was reported as authenticated")
	}
}

// ...and the frame it serves after reopening must be USABLE. A frame carrying
// FlagAuth has a tag trailer whether or not the tag is right; serving it with
// the trailer still attached would hand WireGuard 8 junk bytes per packet and
// the recovery above would be cosmetic.
func TestMismatchedKeyKeepsThePayloadIntact(t *testing.T) {
	g := newAuthGate([][]byte{testKey(1)}, 10*time.Second, roleServer)
	pay := []byte("the whole wireguard datagram")
	f, v := g.Admit(mint(testKey(2), FlagData, 0, 1, 1, pay), time.Now())
	if v != admitPass {
		t.Fatal("setup: the gate was not open")
	}
	if string(f.pay) != string(pay) {
		t.Fatalf("payload = %q, want %q: the tag trailer was not stripped", f.pay, pay)
	}
}

// A server with no key file must behave exactly as it did before this unit.
func TestGateWithoutKeysNeverCloses(t *testing.T) {
	g := newAuthGate(nil, ReopenDefault, roleServer)
	now := time.Now()
	if g.Enabled() {
		t.Fatal("a gate with no keys reported itself enabled")
	}
	if _, v := g.Admit(mint(testKey(1), FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
		t.Fatal("a keyless server refused an authenticated client")
	}
	if g.Closed(now) {
		t.Fatal("a keyless gate closed: nothing could ever satisfy it")
	}
	if _, v := g.Admit(plain(FlagData, 0, 2, 1, []byte("x")), now); v != admitPass {
		t.Fatal("a keyless server refused a plain frame")
	}
}

// A keyless server must also strip the trailer of an authenticated frame, or the
// authenticated client's payloads arrive 8 bytes long on every packet.
func TestKeylessServerStillStripsTheTrailer(t *testing.T) {
	g := newAuthGate(nil, ReopenDefault, roleServer)
	pay := []byte("payload")
	f, _ := g.Admit(mint(testKey(1), FlagData, 0, 1, 1, pay), time.Now())
	if string(f.pay) != string(pay) {
		t.Fatalf("payload = %q, want %q", f.pay, pay)
	}
}

// ---- signing -----------------------------------------------------------------

// The server answers a peer that has never authenticated with an UNSIGNED reply.
// An un-upgraded client drops an unknown flag value silently, so signing at a
// peer that cannot verify would black-hole its downlink.
func TestSealIsSilentUntilThePeerHasProvenItself(t *testing.T) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	now := time.Now()
	buf := make([]byte, HdrLen+16+MacLen)
	n := Pack(buf, FlagData, 0, 1, 1, 0, make([]byte, 16))
	if got := g.Seal(buf, n, now); got != n {
		t.Fatalf("Seal added %d bytes before the peer proved it speaks auth", got-n)
	}
	if buf[1]&0x0F&FlagAuth != 0 {
		t.Fatal("Seal set FlagAuth on a frame it did not sign")
	}
	g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), now)
	n2 := Pack(buf, FlagData, 0, 2, 1, 0, make([]byte, 16))
	if got := g.Seal(buf, n2, now); got != n2+MacLen {
		t.Fatalf("Seal added %d bytes after the peer proved itself, want %d", got-n2, MacLen)
	}
}

// Mid-rollover the two ends hold different key SETS. The reply must be signed
// with the key the peer's own frame verified under, never with a key chosen by
// position, or a client that holds only the new key cannot read the downlink.
func TestSealUsesTheKeyThatVerified(t *testing.T) {
	oldK, newK := testKey(1), testKey(2)
	server := newAuthGate([][]byte{oldK, newK}, ReopenDefault, roleServer)
	client := newAuthGate([][]byte{newK}, ReopenDefault, roleClient)
	now := time.Now()
	if _, v := server.Admit(mint(newK, FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
		t.Fatal("the server did not accept the new key")
	}
	buf := make([]byte, HdrLen+8+MacLen)
	n := Pack(buf, FlagData, 0, 7, 7, 0, make([]byte, 8))
	n = server.Seal(buf, n, now)
	if !client.verify(buf[:n], now) {
		t.Fatal("the server signed with a key the client does not hold: rollover would " +
			"silently kill the downlink")
	}
}

// The full no-flag-day rollover, both directions, with the server never
// restarted: add the new key to both accept sets, switch the client's signing
// key, then drop the old key. No step interrupts the tunnel.
func TestKeyRolloverWithoutAFlagDay(t *testing.T) {
	oldK, newK := testKey(3), testKey(4)
	now := time.Now()
	step := func(serverKeys [][]byte, signWith []byte) {
		t.Helper()
		g := newAuthGate(serverKeys, ReopenDefault, roleServer)
		if _, v := g.Admit(mint(signWith, FlagData, 0, 1, 1, []byte("x")), now); v != admitPass {
			t.Fatal("a rollover step refused the client's frame")
		}
		if !g.Closed(now) {
			t.Fatal("a rollover step left the gate open")
		}
	}
	// before: both ends hold only the old key
	step([][]byte{oldK}, oldK)
	// step 1: the new key is added to both accept sets, nobody signs with it yet
	step([][]byte{oldK, newK}, oldK)
	// step 2: the client switches which key it signs with
	step([][]byte{oldK, newK}, newK)
	// step 3: the old key is removed from both ends
	step([][]byte{newK}, newK)
}

// ---- cost --------------------------------------------------------------------
//
// Read these off the CI run (job go-server), not off a number written here.
// They measure the x86-64 runner; the ARM cost is UNMEASURED (see the cost note
// at the bottom of auth.go).

func BenchmarkAdmitAuthenticated(b *testing.B) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	f := mint(key, FlagData, 0, 1, 1, make([]byte, 1300))
	now := time.Now()
	b.SetBytes(int64(len(f)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, v := g.Admit(f, now); v != admitPass {
			b.Fatal("admit failed")
		}
	}
}

func BenchmarkSeal(b *testing.B) {
	key := testKey(1)
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	now := time.Now()
	g.Admit(mint(key, FlagData, 0, 1, 1, []byte("x")), now)
	buf := make([]byte, HdrLen+1300+MacLen)
	n := Pack(buf, FlagData, 0, 1, 1, 0, make([]byte, 1300))
	b.SetBytes(int64(n))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		g.Seal(buf, n, now)
	}
}
