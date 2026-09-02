package main

import (
	"testing"
	"time"
)

func mk(hold time.Duration) (*Ring, *[][]byte) {
	var got [][]byte
	r := NewRing(4, hold, func(b []byte) { got = append(got, append([]byte{}, b...)) })
	return r, &got
}

func arm(r *Ring, n time.Time) time.Time {
	n = n.Add(r.holdNow() + time.Millisecond)
	r.Tick(n)
	return n
}

func TestInOrder(t *testing.T) {
	r, got := mk(30 * time.Millisecond)
	n := time.Now()
	for i := uint32(0); i < 5; i++ {
		r.Push(i, []byte{byte(i)}, n)
	}
	n = arm(r, n)
	if len(*got) != 5 || (*got)[4][0] != 4 {
		t.Fatalf("in-order: %v", *got)
	}
}

func TestStartupCrossPath(t *testing.T) {
	// fast path's 6..9 arrive before slow path's 0..5: warm-up must anchor at 0
	r, got := mk(60 * time.Millisecond)
	n := time.Now()
	for i := uint32(6); i < 10; i++ {
		r.Push(i, []byte{byte(i)}, n)
	}
	n2 := n.Add(50 * time.Millisecond)
	for i := uint32(0); i < 6; i++ {
		r.Push(i, []byte{byte(i)}, n2)
	}
	n3 := arm(r, n2)
	_ = n3
	if len(*got) != 10 || (*got)[0][0] != 0 || (*got)[9][0] != 9 {
		t.Fatalf("startup: %v", *got)
	}
}

func TestReorderAfterArm(t *testing.T) {
	r, got := mk(50 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	r.Push(2, []byte{2}, n)
	r.Push(1, []byte{1}, n.Add(5*time.Millisecond))
	if len(*got) != 3 || (*got)[1][0] != 1 || (*got)[2][0] != 2 {
		t.Fatalf("reorder: %v", *got)
	}
}

func TestStragglerTimeout(t *testing.T) {
	r, got := mk(30 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	r.Push(2, []byte{2}, n) // 1 missing -> gap timer starts
	r.Tick(n.Add(10 * time.Millisecond))
	if len(*got) != 1 {
		t.Fatalf("held too little: %v", *got)
	}
	r.Tick(n.Add(45 * time.Millisecond)) // past hold: skip 1, release 2
	if len(*got) != 2 || (*got)[1][0] != 2 {
		t.Fatalf("timeout: %v", *got)
	}
	if r.Skips != 1 {
		t.Fatalf("skips=%d", r.Skips)
	}
}

func TestDupAndOld(t *testing.T) {
	r, got := mk(30 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	r.Push(1, []byte{1}, n)
	r.Push(1, []byte{9}, n) // dup of DELIVERED -> old-class
	r.Push(0, []byte{9}, n) // old
	if len(*got) != 2 || r.Olds != 2 {
		t.Fatalf("post-deliver dups: %v olds=%d", *got, r.Olds)
	}
	r.Push(3, []byte{3}, n) // gap at 2, buffered
	r.Push(3, []byte{9}, n) // in-buffer dup -> silently ignored
	r.Tick(n.Add(45 * time.Millisecond))
	if len(*got) != 3 || (*got)[2][0] != 3 || r.Olds != 2 || r.Skips != 1 {
		t.Fatalf("buffer-dup/skip: %v olds=%d skips=%d", *got, r.Olds, r.Skips)
	}
}

func TestRunSkip(t *testing.T) {
	r, got := mk(40 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	r.Push(10, []byte{10}, n) // 1..9 missing: one run, inside window
	r.Tick(n.Add(60 * time.Millisecond))
	if len(*got) != 2 || (*got)[1][0] != 10 || r.Skips != 9 {
		t.Fatalf("run-skip: got=%d skips=%d", len(*got), r.Skips)
	}
	// horizon: nothing buffered ahead -> next must NOT spin past maxSeq
	r.Push(12, []byte{12}, n.Add(61*time.Millisecond)) // 11 missing
	r.Tick(n.Add(200 * time.Millisecond))
	if (*got)[len(*got)-1][0] != 12 || r.next != 13 || r.Skips != 10 {
		t.Fatalf("horizon: next=%d skips=%d", r.next, r.Skips)
	}
}

func TestOverrunFlush(t *testing.T) {
	r, got := mk(40 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	r.Push(50, []byte{50}, n) // gap 49 > mask 15 -> reanchor path
	if len(*got) != 2 || (*got)[1][0] != 50 || r.next != 51 {
		t.Fatalf("overrun: %v next=%d", *got, r.next)
	}
}

// TestPeerRestartResync: the peer's seq counter restarts near 0 while next
// sits at a large value (a routine bond-agg restart, act_agg_restart). Every
// arrival is classified old and, before U113, the ring stayed silent
// forever -- armed was set at startup and never cleared. A full hold horizon
// of nothing-but-old arrivals must resync: drop the stale buffer, re-arm the
// warm-up on the new sequence space, and resume delivery within one hold.
func TestPeerRestartResync(t *testing.T) {
	r, got := mk(30 * time.Millisecond)
	n := time.Now()

	// established stream at a high seq.
	r.Push(1000, []byte{200}, n)
	n = arm(r, n) // armed, next=1001
	if len(*got) != 1 || (*got)[0][0] != 200 {
		t.Fatalf("setup: %v", *got)
	}

	// peer restarts: its seq counter resets near 0. Both arrivals are more
	// than mask(15) behind next(1001), so they count toward the resync run.
	n1 := n.Add(5 * time.Millisecond)
	r.Push(0, []byte{0}, n1) // starts the old-run: no resync yet
	if r.Resyncs != 0 || !r.armed {
		t.Fatalf("premature resync: resyncs=%d armed=%v", r.Resyncs, r.armed)
	}

	n2 := n1.Add(r.holdNow() + time.Millisecond) // a full hold horizon of nothing but old
	r.Push(0, []byte{0}, n2)                     // resync fires: buffer dropped, re-armed on seq 0
	if r.Resyncs != 1 || r.armed {
		t.Fatalf("resync did not fire: resyncs=%d armed=%v", r.Resyncs, r.armed)
	}

	// the new stream continues; delivery must resume within one hold.
	r.Push(1, []byte{1}, n2)
	r.Push(2, []byte{2}, n2)
	arm(r, n2)
	if len(*got) != 4 || (*got)[1][0] != 0 || (*got)[2][0] != 1 || (*got)[3][0] != 2 {
		t.Fatalf("post-resync delivery: %v", *got)
	}
}

func TestOverdueEpoch(t *testing.T) {
	// interleaved loss: evens present, odds missing — ONE Hold epoch
	// must release the whole batch, not Hold-per-gap.
	r, got := mk(40 * time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = arm(r, n)
	for s := uint32(2); s <= 10; s += 2 {
		r.Push(s, []byte{byte(s)}, n)
	}
	r.Tick(n.Add(60 * time.Millisecond))
	if len(*got) != 6 || (*got)[5][0] != 10 || r.Skips != 5 {
		t.Fatalf("epoch: got=%d skips=%d", len(*got), r.Skips)
	}
}

func TestReleaseBudget(t *testing.T) {
	var got [][]byte
	r := NewRing(10, 40*time.Millisecond, func(b []byte) { got = append(got, b) })
	n := time.Now()
	r.Push(0, []byte{0}, n)
	n = n.Add(r.holdNow() + time.Millisecond)
	r.Tick(n) // arm; delivers seq 0
	for s := uint32(2); s <= 600; s++ {
		r.Push(s, []byte{1}, n) // gap at 1: everything buffers behind it
	}
	r.Tick(n) // starts the gap timer
	n = n.Add(r.holdNow() + time.Millisecond)
	r.Tick(n) // epoch: budgeted release begins
	if len(got) != 1+ReleaseBudget {
		t.Fatalf("tick1=%d", len(got))
	}
	r.Tick(n)
	if len(got) != 1+2*ReleaseBudget {
		t.Fatalf("tick2=%d", len(got))
	}
	r.Tick(n)
	if len(got) != 600 || r.Skips != 1 {
		t.Fatalf("tick3=%d skips=%d", len(got), r.Skips)
	}
}
