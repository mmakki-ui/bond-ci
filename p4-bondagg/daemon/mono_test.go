package main

// U13 / OBJ-B, the half that survives U159: the MONOTONIC AGE CLOCK.
//
// U13 built a derived reorder hold (hold.go's LatenessRatchet) on top of the
// reorder ring, and this clock existed because the ratchet's re-anchoring rode
// SetAlive. U159 deleted the ring at both ends and the ratchet with it, so the
// ratchet and its bars did not land. THIS defect is independent of the ring --
// link liveness must not move when the wall clock steps -- so the fix and its
// bar do.
//
// NOT COVERED, stated rather than implied: nothing here steps the real system
// clock. There is no portable way to do that from a unit test. What is asserted
// is the DISCRIMINATING structural fact that distinguishes the fixed code from
// the defective code -- the stored value's magnitude.

import (
	"sync/atomic"
	"testing"
	"time"
)

// B5: link liveness must not ride the wall clock. RxAge feeds SetAlive, and
// SetAlive is what takes a link out of the pool. The round-1 code stored
// time.Now().UnixMilli(), which is ~1.7e12 and fails the first limb below.
func TestRxAgeIsAnchoredOnTheMonotonicEpoch(t *testing.T) {
	l := NewPullLink(0, "eth0", nil, nil)
	l.MarkRx()
	got := atomic.LoadInt64(&l.lastRxMs)
	ceiling := int64(time.Since(monoEpoch)/time.Millisecond) + 1000
	if got < 0 || got > ceiling {
		t.Fatalf("lastRxMs=%d is not milliseconds since the process's monotonic "+
			"epoch (ceiling %d) -- it looks like a WALL-CLOCK Unix stamp", got, ceiling)
	}
	if age := l.RxAge(time.Now()); age < 0 || age > time.Second {
		t.Fatalf("RxAge right after MarkRx is %v", age)
	}
	// And it still measures elapsed time, on the same anchor at both ends. Without
	// this limb the bar above would pass on a monoAgeMS that always returned 0.
	if age := l.RxAge(time.Now().Add(5 * time.Second)); age < 4900*time.Millisecond ||
		age > 5100*time.Millisecond {
		t.Fatalf("RxAge 5s after MarkRx is %v", age)
	}
}
