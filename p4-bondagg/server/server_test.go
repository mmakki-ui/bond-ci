package main

import (
	"encoding/binary"
	"testing"
	"time"
)

// ---- wire compatibility ------------------------------------------------------

func TestFrameRoundTrip(t *testing.T) {
	pay := []byte("hello wire")
	b := make([]byte, HdrLen+len(pay))
	n := Pack(b, FlagData, 7, 0x11223344, 0x55667788, 0x99aabbcc, pay)
	if n != HdrLen+len(pay) {
		t.Fatalf("Pack len = %d, want %d", n, HdrLen+len(pay))
	}
	if b[0] != Magic {
		t.Fatalf("magic = %#x, want %#x", b[0], Magic)
	}
	if b[1]>>4 != Ver {
		t.Fatalf("ver = %d, want %d", b[1]>>4, Ver)
	}
	fl, pid, seq, ts, fseq, got, err := Unpack(b[:n])
	if err != nil {
		t.Fatalf("Unpack: %v", err)
	}
	if fl != FlagData || pid != 7 || seq != 0x11223344 || ts != 0x55667788 || fseq != 0x99aabbcc {
		t.Fatalf("header mismatch: fl=%d pid=%d seq=%#x ts=%#x fseq=%#x", fl, pid, seq, ts, fseq)
	}
	if string(got) != string(pay) {
		t.Fatalf("payload = %q, want %q", got, pay)
	}
}

func TestUnpackRejectsForeignFrames(t *testing.T) {
	b := make([]byte, HdrLen)
	Pack(b, FlagPing, 0, 0, 0, 0, nil)
	b[1] = (1 << 4) | (FlagPing & 0x0F) // a pre-P5 Ver 1 peer: reject, never misparse
	if _, _, _, _, _, _, err := Unpack(b); err == nil {
		t.Fatal("Unpack accepted a Ver 1 header")
	}
	Pack(b, FlagPing, 0, 0, 0, 0, nil)
	b[0] = 0
	if _, _, _, _, _, _, err := Unpack(b); err == nil {
		t.Fatal("Unpack accepted a bad magic")
	}
	if _, _, _, _, _, _, err := Unpack(make([]byte, HdrLen-1)); err == nil {
		t.Fatal("Unpack accepted a short frame")
	}
}

// ---- the echo ----------------------------------------------------------------

// TestEchoUsesItsOwnFlag is the regression test for the wire collision the U16
// verify pass found. The echo MUST NOT go out under FlagPong.
//
// FlagPong already carries the client's own 6-byte R3 answer in the other
// direction (daemon/main.go:153). The shipped client accepts a pong on
// `len(pay) >= pongLen` with pongLen=6 (daemon/main.go:156-162), and the
// 16-byte header is byte-identical either way, so an echo sent as FlagPong is
// accepted and reinterpreted: the echo's rsvd=0 lands in sched.OnQ as a
// permanently clean uplink queue (AIMD then ramps to the ceiling and never
// backs off), the low bits of srvMS land in delivered-bytes, and nrec lands in
// lossPeerB. No error and no log -- it would not have been visible until
// hardware.
//
// This test pins the flag itself, not the payload, because the payload is what
// makes the bug invisible: any echo long enough to be a "valid" pong triggers
// it. It also pins FlagEcho as distinct from every other flag, since the
// protection depends on the client's RX switch (daemon/main.go:147) having no
// default arm and therefore dropping what it does not recognise.
func TestEchoUsesItsOwnFlag(t *testing.T) {
	if FlagEcho == FlagPong {
		t.Fatal("the echo shares FlagPong: the shipped client misparses it as an R3 pong " +
			"and feeds rsvd=0 to AIMD as a clean queue")
	}
	for name, f := range map[string]byte{
		"FlagData": FlagData, "FlagPing": FlagPing,
		"FlagPong": FlagPong, "FlagFEC": FlagFEC,
	} {
		if FlagEcho == f {
			t.Fatalf("FlagEcho collides with %s (%#x)", name, f)
		}
	}
	if FlagEcho > 0x0F {
		t.Fatalf("FlagEcho %#x does not fit the header's 4-bit flag nibble", FlagEcho)
	}

	// And the frame the server actually builds carries it.
	st := &LinkStats{}
	st.OnData(0, 1200)
	pay := make([]byte, MaxPayload)
	pl := st.Snapshot(pay, 12345)
	out := make([]byte, MaxFrame)
	n := Pack(out, FlagEcho, 3, 0, 0x0BADF00D, 0, pay[:pl])
	fl, pid, _, ts, _, got, err := Unpack(out[:n])
	if err != nil {
		t.Fatalf("Unpack: %v", err)
	}
	if fl != FlagEcho {
		t.Fatalf("echo went out under flag %#x, want FlagEcho %#x", fl, FlagEcho)
	}
	if pid != 3 {
		t.Fatalf("echo pathID = %d, want 3 (the link the ping arrived on)", pid)
	}
	if ts != 0x0BADF00D {
		t.Fatalf("echo txstamp = %#x, want the ping's stamp echoed verbatim", ts)
	}
	if len(got) != pl {
		t.Fatalf("echo payload = %d bytes, want %d", len(got), pl)
	}
	// The length that made the collision silent: this payload IS >= pongLen.
	if len(got) < 6 {
		t.Fatal("echo shorter than a pong payload -- the collision test above is vacuous")
	}
}

func TestEchoSnapshotLayout(t *testing.T) {
	s := &LinkStats{}
	s.OnData(0, 100)
	s.OnData(0, 200)
	s.OnData(9, 50)
	if f, b := s.Frames(0), s.Bytes(0); f != 2 || b != 300 {
		t.Fatalf("link 0 counters = %d frames / %d bytes, want 2 / 300", f, b)
	}
	dst := make([]byte, EchoMaxLen)
	n := s.Snapshot(dst, 0xDEADBEEF)
	if want := echoHdrLen + 2*echoRecLen; n != want {
		t.Fatalf("snapshot len = %d, want %d", n, want)
	}
	if dst[0] != 2 {
		t.Fatalf("nrec = %d, want 2", dst[0])
	}
	if got := binary.BigEndian.Uint32(dst[2:6]); got != 0xDEADBEEF {
		t.Fatalf("srvMS = %#x, want 0xDEADBEEF", got)
	}
	wantLink := []byte{0, 9}
	wantFrames := []uint64{2, 1}
	wantBytes := []uint64{300, 50}
	for i := range wantLink {
		rec := dst[echoHdrLen+i*echoRecLen:]
		if rec[0] != wantLink[i] {
			t.Fatalf("rec %d link = %d, want %d", i, rec[0], wantLink[i])
		}
		if f := binary.BigEndian.Uint64(rec[2:10]); f != wantFrames[i] {
			t.Fatalf("rec %d frames = %d, want %d", i, f, wantFrames[i])
		}
		if b := binary.BigEndian.Uint64(rec[10:18]); b != wantBytes[i] {
			t.Fatalf("rec %d bytes = %d, want %d", i, b, wantBytes[i])
		}
	}
}

// N is discovered from the wire, never configured: links appear the moment a
// frame carrying their pathID arrives, at any index, with no privileged index 0.
func TestEchoIsNGeneric(t *testing.T) {
	s := &LinkStats{}
	for _, link := range []byte{200, 1, 255, 0} {
		s.OnData(link, 10)
	}
	dst := make([]byte, EchoMaxLen)
	n := s.Snapshot(dst, 1)
	if want := echoHdrLen + 4*echoRecLen; n != want {
		t.Fatalf("snapshot len = %d, want %d", n, want)
	}
	if dst[0] != 4 {
		t.Fatalf("nrec = %d, want 4", dst[0])
	}
	for i, want := range []byte{0, 1, 200, 255} {
		if got := dst[echoHdrLen+i*echoRecLen]; got != want {
			t.Fatalf("rec %d link = %d, want %d (records must be ascending)", i, got, want)
		}
	}
}

// The echo payload is bounded so the whole reply frame stays inside MaxPayload.
func TestEchoSnapshotBounded(t *testing.T) {
	s := &LinkStats{}
	for i := 0; i < MaxLinks; i++ {
		s.OnData(byte(i), 10)
	}
	dst := make([]byte, EchoMaxLen)
	n := s.Snapshot(dst, 1)
	if n != EchoMaxLen {
		t.Fatalf("snapshot len = %d, want the EchoMaxLen bound %d", n, EchoMaxLen)
	}
	if int(dst[0]) != maxEchoRecs {
		t.Fatalf("nrec = %d, want maxEchoRecs %d", dst[0], maxEchoRecs)
	}
	if HdrLen+EchoMaxLen > MaxPayload {
		t.Fatalf("echo frame %d exceeds MaxPayload %d", HdrLen+EchoMaxLen, MaxPayload)
	}
}

// The reply budget is what makes reflection amplification impossible: bytes out
// can never exceed the DATA bytes actually received.
func TestEchoBudget(t *testing.T) {
	var b echoBudget
	if b.spend(1) {
		t.Fatal("spent with zero credit: a spoofed ping flood would be amplified")
	}
	b.earn(100)
	if !b.spend(60) {
		t.Fatal("refused a spend within credit")
	}
	if b.spend(60) {
		t.Fatal("overspent the credit")
	}
	if !b.spend(40) {
		t.Fatal("refused the exact remainder")
	}
}

// ---- the resequencer ---------------------------------------------------------

func newTestRing(hold time.Duration) (*Ring, *[]uint32) {
	got := new([]uint32)
	r := NewRing(4, hold, func(b []byte) {
		*got = append(*got, binary.BigEndian.Uint32(b))
	})
	return r, got
}

func push(r *Ring, seq uint32, at time.Time) {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, seq)
	r.Push(seq, b, at)
}

func eq(t *testing.T, got []uint32, want ...uint32) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("delivered %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("delivered %v, want %v", got, want)
		}
	}
}

func TestRingWarmupThenInOrder(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	for i := uint32(0); i < 8; i++ {
		push(r, i, t0.Add(time.Duration(i)*time.Millisecond))
	}
	r.Tick(t0.Add(time.Second))
	eq(t, *got, 0, 1, 2, 3, 4, 5, 6, 7)
}

func TestRingReordersWithinHold(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(30 * time.Millisecond))
	push(r, 3, t0.Add(40*time.Millisecond))
	push(r, 2, t0.Add(45*time.Millisecond))
	push(r, 1, t0.Add(50*time.Millisecond))
	eq(t, *got, 0, 1, 2, 3)
}

func TestRingSkipsAGapAfterHold(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(30 * time.Millisecond))
	push(r, 2, t0.Add(40*time.Millisecond))
	r.Tick(t0.Add(100 * time.Millisecond))
	eq(t, *got, 0, 2)
	_, skips, _, _ := r.Counts()
	if skips != 1 {
		t.Fatalf("skips = %d, want 1", skips)
	}
}

// Divergence 1: one frame carrying a seq a billion ahead -- garbage or a spoof
// past the magic/ver check -- must re-anchor in O(ring), delivering what was
// buffered. The client ring's flushTo would walk 2^30 seqs under the ring lock.
func TestRingFarJumpIsBounded(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 0, t0)
	r.Tick(t0.Add(30 * time.Millisecond))
	push(r, 2, t0.Add(40*time.Millisecond))
	done := make(chan struct{})
	go func() {
		push(r, 1<<30, t0.Add(50*time.Millisecond))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("far-forward seq did not re-anchor promptly: the walk is unbounded")
	}
	eq(t, *got, 0, 2, 1<<30)
}

// Divergence 2: a peer restart resets the sequence space. Without the resync the
// ring classifies every arrival as old and the tunnel is bricked until restart.
func TestRingResyncsOnPeerRestart(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 100, t0)
	r.Tick(t0.Add(30 * time.Millisecond))
	eq(t, *got, 100)
	push(r, 0, t0.Add(100*time.Millisecond))
	push(r, 1, t0.Add(130*time.Millisecond))
	r.Tick(t0.Add(200 * time.Millisecond))
	eq(t, *got, 100, 1)
	_, _, olds, resyncs := r.Counts()
	if resyncs != 1 {
		t.Fatalf("resyncs = %d, want 1", resyncs)
	}
	if olds != 2 {
		t.Fatalf("olds = %d, want 2", olds)
	}
}

// The resync must not fire on ordinary stragglers or lightning duplicate copies:
// those land within the ring window, so re-anchoring on them would walk the ring
// backwards and replay already-forwarded frames.
func TestRingStragglerDoesNotResync(t *testing.T) {
	r, got := newTestRing(20 * time.Millisecond)
	t0 := time.Now()
	push(r, 100, t0)
	r.Tick(t0.Add(30 * time.Millisecond))
	push(r, 99, t0.Add(100*time.Millisecond))
	push(r, 98, t0.Add(140*time.Millisecond))
	r.Tick(t0.Add(200 * time.Millisecond))
	eq(t, *got, 100)
	_, _, olds, resyncs := r.Counts()
	if olds != 2 {
		t.Fatalf("olds = %d, want 2", olds)
	}
	if resyncs != 0 {
		t.Fatalf("resyncs = %d, want 0: a straggler re-anchored the ring", resyncs)
	}
}

// ---- the reorder horizon -----------------------------------------------------

func TestOWDHoldIsPureGeometry(t *testing.T) {
	o := &OWD{}
	if got := o.Hold(5*time.Millisecond, 350*time.Millisecond); got != 350*time.Millisecond {
		t.Fatalf("warm-up hold = %v, want the max clamp", got)
	}
	o.Sample(3, nowMS())
	if got := o.Hold(5*time.Millisecond, 350*time.Millisecond); got != 5*time.Millisecond {
		t.Fatalf("single-link hold = %v, want the min clamp (spread 0, jitter 0)", got)
	}
}
