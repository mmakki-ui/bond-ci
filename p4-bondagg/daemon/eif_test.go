package main

import (
	"testing"
	"time"
)

// TestEifPickArgmin: with two ACTIVE alive paths, Pick returns the lower-ETA one
// (here decided by the anchored owd delta).
func TestEifPickArgmin(t *testing.T) {
	est := []*Estr{NewEstr(), NewEstr()}
	ce := []*CapEst{NewCapEst(1000), NewCapEst(1000)}
	now := time.Now()
	est[0].OnPong(now, 0, 100, 0, 0) // owdD = 100ms (slower)
	est[1].OnPong(now, 0, 0, 0, 0)   // owdD = 0 (faster)
	e := NewEIF(est, ce, 0)
	e.role[1] = roleActive // white-box: make both eligible
	if got := e.Pick(1200); got != 1 {
		t.Fatalf("argmin: Pick=%d want 1 (lower owd)", got)
	}
}

// TestEifBackpressure: the only ACTIVE path with q̂ > BP_MS -> txdrop (-1).
func TestEifBackpressure(t *testing.T) {
	est := []*Estr{NewEstr()}
	ce := []*CapEst{NewCapEst(1000)}
	now := time.Now()
	est[0].OnPong(now, 400, 0, 0, 0) // qmeas 400ms -> q̂ ~ 400 > BP_MS(270)
	e := NewEIF(est, ce, 0)
	if got := e.Pick(1200); got != -1 {
		t.Fatalf("backpressure: Pick=%d want -1", got)
	}
	if e.TxDrops() != 1 {
		t.Fatalf("txdrop not counted: %d", e.TxDrops())
	}
}

// TestEifStandbyExcluded: a standby (non-active) path is never picked even when
// it is the only alive path with capacity.
func TestEifStandbyExcluded(t *testing.T) {
	est := []*Estr{NewEstr(), NewEstr()}
	ce := []*CapEst{NewCapEst(1000), NewCapEst(1000)}
	e := NewEIF(est, ce, 0) // path0 ACTIVE, path1 STANDBY
	// only path0 is active -> Pick must return 0 (never the standby 1)
	if got := e.Pick(1200); got != 0 {
		t.Fatalf("standby excluded: Pick=%d want 0", got)
	}
}

// TestEifDeadPromotes: when the primary dies, Control promotes an alive path so
// the datapath keeps an ACTIVE primary.
func TestEifDeadPromotes(t *testing.T) {
	est := []*Estr{NewEstr(), NewEstr()}
	ce := []*CapEst{NewCapEst(1000), NewCapEst(1000)}
	e := NewEIF(est, ce, 0) // prim=0
	e.SetAlive(0, false)    // path0 dies
	e.Control(time.Now())
	if e.Prim() == 0 {
		t.Fatalf("dead primary not re-promoted (prim still 0)")
	}
	if e.role[e.Prim()] != roleActive {
		t.Fatalf("new primary not ACTIVE")
	}
}

// TestEifAllDeadRevive (#1): ALL N paths go DEAD at once, then revive. The
// DEAD-handling loop returns every path to STANDBY, leaving ZERO ACTIVE -- and
// activation needs an existing ACTIVE path to shadow standby ETAs against, so it
// can never spin one up: Pick returns -1 every frame (100% txdrop until restart).
// Control's end-guard must promote the best alive path so the datapath recovers.
func TestEifAllDeadRevive(t *testing.T) {
	est := []*Estr{NewEstr(), NewEstr()}
	ce := []*CapEst{NewCapEst(1000), NewCapEst(1000)}
	now := time.Now()
	est[0].OnPong(now, 0, 0, 0, 0) // fresh pong -> q̂ ~ 0 (pickable, not BP)
	est[1].OnPong(now, 0, 0, 0, 0)
	e := NewEIF(est, ce, 0) // prim=0 ACTIVE, path1 STANDBY

	e.SetAlive(0, false) // ALL paths die at once (e.g. dual-WAN blip)
	e.SetAlive(1, false)
	e.Control(now) // both -> DEAD, no ACTIVE survivor

	e.SetAlive(0, true) // both revive
	e.SetAlive(1, true)
	e.Control(now) // DEAD -> STANDBY for both; end-guard must re-promote

	nActive := 0
	for i := 0; i < 2; i++ {
		if e.role[i] == roleActive && e.alive[i] {
			nActive++
		}
	}
	if nActive == 0 {
		t.Fatalf("all-dead-revive: no ACTIVE alive path after revive (Pick deadlock)")
	}
	if got := e.Pick(1200); got < 0 {
		t.Fatalf("all-dead-revive: Pick=%d want a valid path (100%% txdrop deadlock)", got)
	}
}
