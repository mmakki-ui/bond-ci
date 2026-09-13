package main

import (
	"testing"
	"time"
)

// TestLossMeter: reorder-tolerant per-path fseq-gap loss with ring-skip (TIME-
// based) semantics. A frame that arrives LATE but within `hold` fills its gap
// and is NOT loss; a frontier gap that stays open longer than `hold` is loss.
func TestLossMeter(t *testing.T) {
	t0 := time.Unix(3000, 0)
	hold := 100 * time.Millisecond
	if l, tot := (&LossMeter{}).Window(t0, hold); l != 0 || tot != 0 {
		t.Fatalf("empty meter should read 0/0, got %d/%d", l, tot)
	}
	// Case A: pure reorder INSIDE hold -> ZERO lost (the fix). fseq 5 arrives
	// after 6,7 but only ~2ms later, well within hold; must not count as loss.
	mA := &LossMeter{}
	for k, fs := range []uint32{0, 1, 2, 3, 4, 6, 7, 5, 8, 9, 10, 11, 12} {
		mA.Data(fs, t0.Add(time.Duration(k)*time.Millisecond), hold)
	}
	if lost, total := mA.Window(t0.Add(20*time.Millisecond), hold); lost != 0 || total == 0 {
		t.Fatalf("reorder within hold must not count as loss: lost=%d total=%d", lost, total)
	}
	// Case B: exactly one genuine loss. fseq 100 never arrives; the frontier gap
	// stays open longer than hold (later arrival is > hold after it blocked), so
	// it -- and only it -- is declared lost.
	mB := &LossMeter{}
	for i := uint32(60); i <= 99; i++ {
		mB.Data(i, t0, hold)
	}
	mB.Data(101, t0, hold)                               // gap 100 opens at t0
	mB.Data(102, t0.Add(hold+10*time.Millisecond), hold) // > hold later -> 100 lost
	if lost, total := mB.Window(t0.Add(2*hold), hold); lost != 1 || total < 2 {
		t.Fatalf("genuine loss miscounted: lost=%d total=%d (want lost=1)", lost, total)
	}
}
