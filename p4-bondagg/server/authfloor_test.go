package main

import (
	"testing"
	"time"
)

// U31 fix round 3, blocker B6: AGG_AUTH_REOPEN_MS had a floor in PROSE and none
// in code. The ROADMAP said the horizon "has a floor from physics (DeadIval
// 600 ms)", which reads as an implemented floor; the only validation was
// envMS's ms<=0 check, so AGG_AUTH_REOPEN_MS=1 was accepted and logged as
// normal ("auth: 1 key(s) ... reopen horizon 1ms").
//
// The first test below is the ATTACK, and it fails on the pre-fix tree: with a
// horizon shorter than the gap between authenticated frames, closedLocked ages
// out between frames, the gate is OPEN in the gap, and every forgery in it is
// admitted -- with authok climbing normally and nothing in the log saying the
// gate is not shut. The remaining tests pin the fix.

// THE ATTACK. A tiny horizon leaves the gate open between two perfectly healthy
// authenticated frames.
func TestAShortHorizonLeavesTheGateOpenBetweenFrames(t *testing.T) {
	key := testKey(1)
	// The unclamped value an operator could set before the fix.
	g := newAuthGate([][]byte{key}, time.Millisecond, roleServer)
	t0 := time.Now()

	if _, v := g.Admit(mint(key, FlagData, 0, 1, 100, []byte{1}), t0); v != admitPass {
		t.Fatal("a valid frame was not admitted")
	}
	if !g.Closed(t0) {
		t.Fatal("the gate did not close on a verified frame")
	}
	// A gap any healthy tunnel produces: the peer's ping cadence is 100 ms and
	// it is declared dead only at DeadIval = 600 ms, so 50 ms of silence is
	// NORMAL, not an outage.
	gap := t0.Add(50 * time.Millisecond)
	if g.Closed(gap) {
		t.Fatal("this test proves nothing: the gate is still closed 50ms later, so " +
			"the horizon under test is not short enough to open between frames")
	}
	// POSITIVE CONTROL, in the same shape as the four vector tests: the attack
	// must SUCCEED against the unclamped gate, or this test is measuring
	// nothing.
	forged := plain(FlagData, 0, 9999, 1, []byte{2})
	if _, v := g.Admit(forged, gap); v != admitPass {
		t.Fatalf("the forgery was not admitted (verdict=%d) -- the hole this test "+
			"demonstrates is absent, so it no longer measures what it claims", v)
	}
	if aok, _, ashed := g.Counts(); ashed != 0 || aok != 1 {
		t.Fatalf("authok=%d authshed=%d -- the point is that nothing looks wrong: "+
			"the forgery is admitted with no shed counted", aok, ashed)
	}

	// Now the same operator value, put through the clamp the daemon applies.
	g2 := newAuthGate([][]byte{key}, clampReopen(time.Millisecond), roleServer)
	if _, v := g2.Admit(mint(key, FlagData, 0, 1, 100, []byte{1}), t0); v != admitPass {
		t.Fatal("a valid frame was not admitted under the clamped horizon")
	}
	if !g2.Closed(gap) {
		t.Fatal("the clamped gate opened inside a 50ms gap")
	}
	if _, v := g2.Admit(forged, gap); v != admitShed {
		t.Fatalf("clamped gate admitted the forgery: verdict=%d, want admitShed", v)
	}
}

// The floor is the peer's liveness timer, not a number of its own: a peer still
// considered ALIVE has by definition sent something within DeadIval. This
// module cannot import daemon/main.go (separate Go module, hand-kept mirror
// like frame.go), so the value is pinned here against its cited source.
func TestReopenFloorMatchesPeerLiveness(t *testing.T) {
	if ReopenFloor != 600*time.Millisecond {
		t.Fatalf("ReopenFloor=%v, want the peer's DeadIval = 600ms "+
			"(daemon/main.go:29). If DeadIval moved, move this with it.", ReopenFloor)
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

// Mirror of daemon/auth.go's guard, kept here so the two copies stay
// byte-comparable. This server's own TX buffers already carry the trailer
// (main.go HdrLen+MaxPayload+MacLen, rx.go MaxAuthFrame), so this asserts the
// guard rather than a live defect.
func TestSealRefusesAShortBuffer(t *testing.T) {
	key := testKey(2)
	g := newAuthGate([][]byte{key}, time.Second, roleServer)
	now := time.Now()
	// The server signs only once the peer has proven itself.
	if _, v := g.Admit(mint(key, FlagData, 0, 1, 100, []byte{1}), now); v != admitPass {
		t.Fatal("setup frame not admitted")
	}
	pay := make([]byte, MaxPayload)
	short := make([]byte, MaxPayload+HdrLen)
	n := Pack(short, FlagData, 0, 7, 1234, 0, pay)
	flagsBefore := short[1]
	if m := g.Seal(short, n, now); m != -1 {
		t.Fatalf("Seal returned %d on a buffer with no headroom, want -1", m)
	}
	if short[1] != flagsBefore {
		t.Fatalf("Seal set FlagAuth (%#x -> %#x) on a frame it did not sign",
			flagsBefore, short[1])
	}
	if g.SealShort() != 1 {
		t.Fatalf("SealShort=%d, want 1", g.SealShort())
	}
	// And the correctly sized buffer still seals.
	ok := make([]byte, HdrLen+MaxPayload+MacLen)
	n2 := Pack(ok, FlagData, 0, 7, 1234, 0, pay)
	if m := g.Seal(ok, n2, now); m != n2+MacLen {
		t.Fatalf("Seal returned %d on a correctly sized buffer, want %d", m, n2+MacLen)
	}
}
