package main

import (
	"testing"
	"time"
)

// U132: the server used to log one 250-byte SSTAT line every StatIval (1s)
// unconditionally, and init.d/p5-server routes stderr into the box's shared
// logd ring -- an idle server evicted the dropbear/wg lines another
// operator debugs with. statDecision is the pure function the stat
// goroutine now asks on every tick; these three tests drive it directly, no
// socket, no ticker, no real time.

// TestStatIdleSilent: nothing changed since the last emitted line, and the
// heartbeat interval has not elapsed -- statDecision must say no line goes
// out.
func TestStatIdleSilent(t *testing.T) {
	snap := statSnapshot{delivs: 10, towg: 10, gateShut: 0}
	if statDecision(snap, snap, false, 30*time.Second) {
		t.Fatal("statDecision emitted with no counter change and < heartbeat elapsed")
	}
	// right at the boundary, still short: (StatHeartbeat - 1ns) must stay silent.
	if statDecision(snap, snap, false, StatHeartbeat-time.Nanosecond) {
		t.Fatal("statDecision emitted one tick before the heartbeat elapsed")
	}
}

// TestStatHeartbeat: still nothing changed, but StatHeartbeat has elapsed --
// exactly one line must go out so an idle server still proves it is alive.
func TestStatHeartbeat(t *testing.T) {
	snap := statSnapshot{delivs: 10, towg: 10, gateShut: 0}
	if !statDecision(snap, snap, false, StatHeartbeat) {
		t.Fatal("statDecision stayed silent at exactly the heartbeat interval")
	}
	if !statDecision(snap, snap, false, StatHeartbeat+time.Minute) {
		t.Fatal("statDecision stayed silent well past the heartbeat interval")
	}
}

// TestStatFirstLineAlwaysEmits: the very first line after start goes out
// regardless of counters or elapsed time -- first overrides everything else.
func TestStatFirstLineAlwaysEmits(t *testing.T) {
	var zero statSnapshot
	if !statDecision(zero, zero, true, 0) {
		t.Fatal("statDecision withheld the first line ever")
	}
}

// TestStatCounterChangeEmits: a counter moving between ticks -- with the
// heartbeat nowhere near elapsed -- must still emit immediately.
func TestStatCounterChangeEmits(t *testing.T) {
	prev := statSnapshot{delivs: 10, towg: 10, gateShut: 0}
	cur := prev
	cur.delivs = 11
	if !statDecision(cur, prev, false, time.Second) {
		t.Fatal("statDecision withheld a line although a counter changed")
	}
}

// TestStatGateTransitionEmits: the gate= field flipping (open<->closed) is
// the deliverable's third required case -- a gate transition must always
// emit a line, with every counter otherwise unchanged and the heartbeat
// nowhere near elapsed.
func TestStatGateTransitionEmits(t *testing.T) {
	prev := statSnapshot{delivs: 10, towg: 10, gateShut: 0}
	cur := prev
	cur.gateShut = 1
	if !statDecision(cur, prev, false, time.Second) {
		t.Fatal("statDecision withheld a line on a gate= transition")
	}

	// and the reverse direction, closed -> open.
	prev2 := statSnapshot{delivs: 10, towg: 10, gateShut: 1}
	cur2 := prev2
	cur2.gateShut = 0
	if !statDecision(cur2, prev2, false, time.Second) {
		t.Fatal("statDecision withheld a line on a gate= transition (closed->open)")
	}
}
