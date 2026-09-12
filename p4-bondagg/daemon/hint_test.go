package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"testing"
	"time"
)

// U34a -- header byte [3] is the DOWNLINK HINT under FlagData, delta-encoded.
// This is the CLIENT half: the byte this module puts on the wire. The SERVER
// half (what route does with it) is server/hint_test.go, and the two are tied
// together by TestHintHeaderVector below, whose byte string is pinned
// IDENTICALLY in both modules -- the modules cannot import each other, so a
// hand-pinned vector on both sides is the only bar that fails when the two
// copies of frame.go drift. That drift is not hypothetical: server/frame.go
// claiming to be a verbatim mirror while dropping the byte's annotation is what
// made U34 round 1 record the field as unused (U48).

// TestPackRsvdCarriesByteThree: the byte goes out as given, and comes back.
func TestPackRsvdCarriesByteThree(t *testing.T) {
	pay := []byte("payload")
	for _, d := range []byte{0, 1, 2, 127, 128, 254, 255} {
		b := make([]byte, MaxFrame)
		n := PackRsvd(b, FlagData, 9, d, 0x11223344, 0x55667788, 0x99aabbcc, pay)
		if b[3] != d {
			t.Fatalf("PackRsvd wrote byte[3]=%d, want %d", b[3], d)
		}
		if got := Rsvd(b[:n]); got != d {
			t.Fatalf("Rsvd read %d, want %d", got, d)
		}
		fl, pid, rsvd, seq, ts, fseq, got, err := UnpackRsvd(b[:n])
		if err != nil {
			t.Fatal(err)
		}
		if fl != FlagData || pid != 9 || rsvd != d || seq != 0x11223344 ||
			ts != 0x55667788 || fseq != 0x99aabbcc || !bytes.Equal(got, pay) {
			t.Fatalf("UnpackRsvd round trip: fl=%d pid=%d rsvd=%d seq=%x ts=%x fseq=%x pay=%q",
				fl, pid, rsvd, seq, ts, fseq, got)
		}
		// The 7-value Unpack is a WRAPPER over UnpackRsvd and must agree with
		// it on every field it still returns: every existing reader in this
		// module calls it, and a wrapper that quietly disagreed would move the
		// resequencer, the OWD sample and the loss meter at once.
		fl2, pid2, seq2, ts2, fseq2, got2, err2 := Unpack(b[:n])
		if err2 != nil || fl2 != fl || pid2 != pid || seq2 != seq || ts2 != ts ||
			fseq2 != fseq || !bytes.Equal(got2, pay) {
			t.Fatal("Unpack disagrees with UnpackRsvd")
		}
	}
}

// TestPackStillEmitsHintZero: every existing call site in this module goes
// through Pack, and Pack must keep emitting 0 -- which under the delta encoding
// MEANS "prefer the link this frame is riding", i.e. the pre-U34a downlink rule.
// If Pack ever emitted anything else, every unmodified sender here would start
// steering the far end's downlink by accident.
func TestPackStillEmitsHintZero(t *testing.T) {
	b := make([]byte, MaxFrame)
	for _, fl := range []byte{FlagData, FlagPing, FlagPong, FlagFEC} {
		n := Pack(b, fl, 4, 7, 8, 9, []byte("x"))
		if b[3] != 0 {
			t.Fatalf("Pack under flag %d wrote byte[3]=%d, want 0", fl, b[3])
		}
		if Rsvd(b[:n]) != 0 {
			t.Fatal("Rsvd disagrees with the byte Pack wrote")
		}
	}
}

// TestHintTargetIsModuloTwoFiveSix, exhaustively over the whole value space --
// 65,536 pairs, the entire domain, so this is a proof and not a sample.
//
// The two properties that make the encoding work are asserted separately:
// d = 0 is the IDENTITY (which is what makes a hint-unaware sender correct
// rather than merely tolerated), and from ANY pathID the 256 values of d reach
// all 256 links exactly once (which is what makes every link addressable -- the
// superseded biased encoding could not name link 255 at all).
func TestHintTargetIsModuloTwoFiveSix(t *testing.T) {
	for p := 0; p < 256; p++ {
		if got := HintTarget(byte(p), 0); got != byte(p) {
			t.Fatalf("d=0 must be the identity: HintTarget(%d,0)=%d", p, got)
		}
		var seen [256]bool
		for d := 0; d < 256; d++ {
			want := byte((p + d) % 256)
			got := HintTarget(byte(p), byte(d))
			if got != want {
				t.Fatalf("HintTarget(%d,%d)=%d, want %d", p, d, got, want)
			}
			if seen[got] {
				t.Fatalf("pathID %d reaches link %d twice", p, got)
			}
			seen[got] = true
		}
		for l := 0; l < 256; l++ {
			if !seen[l] {
				t.Fatalf("pathID %d cannot address link %d", p, l)
			}
		}
	}
}

// hintVector is the 16 header bytes of a hinted DATA frame: magic b0,
// ver 2 | FlagData = 0x20, pathID 07, hint 02, then seq, txstamp and fseq
// big-endian. Written out BY HAND from the layout comment rather than captured
// from a run, so it is an independent statement of the wire, and pinned
// character for character in server/hint_test.go.
const hintVector = "b0" + "20" + "07" + "02" + "11223344" + "55667788" + "99aabbcc"

func TestHintHeaderVector(t *testing.T) {
	b := make([]byte, HdrLen)
	PackRsvd(b, FlagData, 0x07, 0x02, 0x11223344, 0x55667788, 0x99aabbcc, nil)
	if got := hex.EncodeToString(b); got != hintVector {
		t.Fatalf("header vector drifted:\n got %s\nwant %s", got, hintVector)
	}
}

// mintHint is mintDom with an explicit byte [3]: an INDEPENDENT reimplementation
// of the tag over a hinted frame, so a change to auth.go that also changed the
// wire cannot pass by agreeing with itself.
func mintHint(dom byte, key []byte, base, pid, d byte, seq, ts uint32, pay []byte) []byte {
	b := make([]byte, HdrLen+len(pay)+MacLen)
	n := PackRsvd(b, base|FlagAuth, pid, d, seq, ts, 0, pay)
	m := hmac.New(sha256.New, key)
	var in [macInLen]byte
	in[0] = dom
	copy(in[1:1+HdrLen], b[:HdrLen])
	binary.BigEndian.PutUint16(in[1+HdrLen:], uint16(len(pay)))
	m.Write(in[:])
	copy(b[n:], m.Sum(nil)[:MacLen])
	return b[:n+MacLen]
}

// TestClientHintIsInsideTheTransportMac. The hint is a ROUTING instruction, so
// an off-path attacker who can rewrite it steers the peer's downlink -- the same
// consequence as U31 vector 1, reached by editing one byte of a captured frame
// instead of forging a whole one. It is covered because the MAC covers
// hdr[:HdrLen] (auth.go macLocked), and this asserts that coverage for THIS byte
// with a frame that actually carries a non-zero hint: the sweep in
// TestMacCoversEveryHeaderByteAndTheLength -- which lives in the SERVER module
// (server/auth_test.go) and has no counterpart here -- flips bits of a frame
// whose byte [3] is 0, so it proves the byte is covered but never exercises a
// real hint. This test is the only byte-[3] MAC bar in this module.
//
// It walks all 255 other values of d rather than one, because the failure this
// guards against -- a MAC input that copied fewer than HdrLen bytes, or masked
// the byte -- would be value-dependent if it were partial.
func TestClientHintIsInsideTheTransportMac(t *testing.T) {
	key := testKey(1)
	now := time.Now()
	pay := []byte("0123456789")

	// domC2S: the frame this CLIENT sends. Verified with a gate in the far
	// end's role, which is how the other tests in this module stand up the wire.
	good := mintHint(domC2S, key, FlagData, 3, 2, 4242, 99, pay)
	if Rsvd(good) != 2 {
		t.Fatal("setup: the minted frame does not carry the hint")
	}
	g := newAuthGate([][]byte{key}, ReopenDefault, roleServer)
	if !g.verify(good, now) {
		t.Fatal("the unmodified hinted frame did not verify: this test proves nothing")
	}
	for d := 0; d < 256; d++ {
		if byte(d) == 2 {
			continue
		}
		alt := append([]byte(nil), good...)
		alt[3] = byte(d)
		if g.verify(alt, now) {
			t.Fatalf("the hint is OUTSIDE the MAC: d=2 rewritten to %d still verified", d)
		}
	}
}

// TestPackThenOverwriteIsPackRsvd. Spec item 4 (downlink-routing-spec.md:509-512)
// wants byte [3] passed to Pack instead of written over Pack's zero afterwards.
// PackRsvd is that parameter, but the two FEC parity sites still use the old
// shape at the time (the two FEC parity sites, since deleted by U128 -- see tag eif-push-reference main.go:312-313 and :477-478) Packed a FlagFEC frame and then assigned
// fout[3] = kk -- and main.go is outside U34a's owned files, so the rewrite is
// handed on. This bar is what makes handing it on safe: it asserts the two
// shapes emit BYTE-IDENTICAL frames for every one of the 256 values of K, so
// whoever collapses those two sites into one PackRsvd call is making a
// provably wire-neutral edit and does not have to re-derive that.
//
// It also gates the reverse: if PackRsvd ever stopped writing dst[3] (or wrote
// it before the flag/pathID bytes and got overwritten), the two shapes would
// stop agreeing and this goes red while TestPackStillEmitsHintZero -- which
// only ever looks at 0 -- would not.
func TestPackThenOverwriteIsPackRsvd(t *testing.T) {
	pp := []byte("parity-body")
	for k := 0; k < 256; k++ {
		kk := byte(k)

		// The shape main.go uses today, copied verbatim from :312-313.
		a := make([]byte, len(pp)+HdrLen)
		na := Pack(a, FlagFEC, 5, 0x0a0b0c0d, 0x01020304, 0, pp)
		a[3] = kk

		// The shape spec item 4 asks for.
		b := make([]byte, len(pp)+HdrLen)
		nb := PackRsvd(b, FlagFEC, 5, kk, 0x0a0b0c0d, 0x01020304, 0, pp)

		if na != nb || !bytes.Equal(a[:na], b[:nb]) {
			t.Fatalf("K=%d: the two shapes differ\n overwrite %x (n=%d)\n PackRsvd  %x (n=%d)",
				k, a[:na], na, b[:nb], nb)
		}
		// And the byte still reads back as K, not as a hint: the FEC reader
		// (main.go:220, :611) does int(buf[3]) and must keep seeing K.
		if Rsvd(b[:nb]) != kk {
			t.Fatalf("K=%d: byte[3] reads back %d", k, Rsvd(b[:nb]))
		}
	}
}
