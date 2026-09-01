package main

import (
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// U17a BARS.
//
// THE BAR THESE EXIST TO MAKE FAILABLE: `max` and `speed` must not be the same
// datapath. Before this unit they were -- `grep -rn AGG_SCHED p4-bondagg/daemon/`
// returned zero, so every byte on the wire and every frame out of the ring was
// identical in both modes and `bondctl mode speed` silently did `max`. A test
// suite that only asserted "speed works" would have passed on that tree, which
// is why the bars below are written as A/Bs: the SAME input through BOTH
// policies, asserting the outputs DIFFER. Delete the split and they go red.
//
// Which ones go red if the split is reverted, stated so the claim is checkable
// rather than asserted:
//   * delete Ring.arrival            -> 6, 7, 9, 10 fail (delivery order and the
//                                       hold report become identical)
//   * make schedPolicies["speed"] a  -> 1, 4, 5 fail (the policy values are
//     copy of ["max"]                   equal), and 19..23 fail with it
//   * drop the rank gate from Drive  -> 23 fails (link 1 carries frames under
//                                       `speed` that it must not)
//   * fall back to max on an unknown -> 2 fails (the silent substitution)
//     AGG_SCHED
// ---------------------------------------------------------------------------

// schedRing builds a ring in one delivery mode and records the FIRST BYTE of
// each delivered payload, in delivery order. Order is the whole point: the two
// modes deliver the same frames, and what differs is when and in what sequence.
func schedRing(arrival bool, hold time.Duration) (*Ring, *[]byte) {
	var got []byte
	r := NewRing(4, hold, func(b []byte) { got = append(got, b[0]) })
	r.SetArrival(arrival)
	return r, &got
}

// setStats installs a rank state directly. It lives in the test file and not in
// sched.go on purpose: the production Ranker has exactly ONE writer, the
// ping/echo path, and a test-only setter in the shipped file is a second one.
func setStats(r *Ranker, i int, hbar float64, haveHbar bool, lastD float64, haveLastD bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.hbar[i], r.haveH[i] = hbar, haveHbar
	r.lastD[i], r.haveD[i] = lastD, haveLastD
}

func schedLinks(n int) []*PullLink {
	out := make([]*PullLink, n)
	for i := range out {
		out[i] = newPullLinkSock(i, "w", newFakeSock(0, nil), testDst())
	}
	return out
}

// 1
func TestSchedMaxAndSpeedDifferInDeliveryAndRank(t *testing.T) {
	mx, ok := schedPolicies["max"]
	if !ok {
		t.Fatal("no `max` scheduler")
	}
	sp, ok := schedPolicies["speed"]
	if !ok {
		t.Fatal("no `speed` scheduler")
	}
	if mx == sp {
		t.Fatal("max and speed are the SAME policy value: the two aggregate modes " +
			"would be indistinguishable, which is the defect U17a exists to close")
	}
	if mx.Delivery == sp.Delivery {
		t.Fatalf("delivery is identical (%v): this is the half that must differ "+
			"UNCONDITIONALLY, with no statistics and no peer cooperation", mx.Delivery)
	}
	if mx.Rank == sp.Rank {
		t.Fatalf("rank is identical (%v): the draw order must differ", mx.Rank)
	}
	if mx.Hold == sp.Hold {
		t.Fatalf("hold is identical (%v): speed holds for nothing", mx.Hold)
	}
	if sp.Delivery != DeliverOnArrival || sp.Hold != HoldNone || sp.Rank != RankDeadlineHit {
		t.Fatalf("speed is not the settled policy: %+v", sp)
	}
	if mx.Delivery != DeliverInOrder || mx.Rank != RankDrainOrder {
		t.Fatalf("max is not the settled policy: %+v", mx)
	}
}

// 2
func TestSchedUnknownValueIsRefusedNotSilentlyMax(t *testing.T) {
	p, explicit, err := SchedFromEnv(func(k string) string {
		if k == "AGG_SCHED" {
			return "lightning"
		}
		return ""
	})
	if err == nil {
		t.Fatalf("an unimplemented AGG_SCHED was ACCEPTED and resolved to %+v. That is "+
			"the silent substitution: the orchestration would report one mode while the "+
			"wire carried another", p)
	}
	if !explicit {
		t.Fatal("an unknown value must still report AGG_SCHED as explicitly set")
	}
	if !strings.Contains(err.Error(), "lightning") {
		t.Fatalf("the refusal must name the value it refused: %v", err)
	}
}

// 3
func TestSchedUnsetInheritsMaxAndIsReportedAsInherited(t *testing.T) {
	p, explicit, err := SchedFromEnv(func(string) string { return "" })
	if err != nil {
		t.Fatalf("unset AGG_SCHED must not be an error: %v", err)
	}
	if explicit {
		t.Fatal("unset AGG_SCHED reported as explicitly set: `nobody said anything` and " +
			"`the operator asked for max` are different facts")
	}
	if p.Name != SchedInherited || p.Rank != RankDrainOrder || p.Delivery != DeliverInOrder {
		t.Fatalf("unset must inherit the pre-AGG_SCHED datapath, got %+v", p)
	}
}

// 4
func TestSchedImplementedNamesAreExactlyMaxAndSpeed(t *testing.T) {
	got := SchedNames()
	want := []string{"max", "speed"}
	if len(got) != len(want) {
		t.Fatalf("implemented schedulers = %v, want %v. bond-xctl's AGG_SCHED_TABLE and "+
			"this build must agree on the set, or a mode the box can select is a mode "+
			"the daemon refuses", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("implemented schedulers = %v, want %v", got, want)
		}
	}
}

// 5
func TestSchedDescribeNamesTheActualPolicyNotJustTheMode(t *testing.T) {
	mx := schedPolicies["max"].Describe()
	sp := schedPolicies["speed"].Describe()
	if mx == sp {
		t.Fatal("the two policies describe themselves identically, so a log line cannot " +
			"tell them apart -- which is how this defect stayed invisible")
	}
	if !strings.Contains(sp, "ON ARRIVAL") {
		t.Fatalf("speed's description does not state its delivery policy: %q", sp)
	}
	if strings.Contains(mx, "ON ARRIVAL") {
		t.Fatalf("max claims deliver-on-arrival: %q", mx)
	}
}

// 6
func TestRingArrivalDeliversOutOfOrderImmediately(t *testing.T) {
	r, got := schedRing(true, 30*time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	r.Push(2, []byte{2}, n)
	r.Push(1, []byte{1}, n)
	if string(*got) != string([]byte{0, 2, 1}) {
		t.Fatalf("arrival delivery = %v, want [0 2 1]: on-arrival releases in ARRIVAL "+
			"order with no tick, no hold and no re-sequencing", *got)
	}
	if r.Skips != 0 {
		t.Fatalf("arrival skipped %d: nothing is ever late, because nothing waits", r.Skips)
	}
}

// 7  THE A/B. Same frames, same times, both policies.
func TestRingInOrderHoldsTheGapThatArrivalDelivers(t *testing.T) {
	hold := 30 * time.Millisecond
	ro, gotO := schedRing(false, hold)
	ra, gotA := schedRing(true, hold)
	t0 := time.Now()
	ro.Push(0, []byte{0}, t0)
	ra.Push(0, []byte{0}, t0)
	t1 := t0.Add(hold + time.Millisecond)
	ro.Tick(t1)
	ra.Tick(t1)
	// Frame 2 arrives while 1 is missing. This is the whole difference.
	ro.Push(2, []byte{2}, t1)
	ra.Push(2, []byte{2}, t1)
	if string(*gotO) != string([]byte{0}) {
		t.Fatalf("in-order delivered %v across a gap: it must hold", *gotO)
	}
	if string(*gotA) != string([]byte{0, 2}) {
		t.Fatalf("arrival delivered %v: it must not hold for anything", *gotA)
	}
	ro.Push(1, []byte{1}, t1)
	ra.Push(1, []byte{1}, t1)
	if string(*gotO) != string([]byte{0, 1, 2}) {
		t.Fatalf("in-order final = %v, want [0 1 2]", *gotO)
	}
	if string(*gotA) != string([]byte{0, 2, 1}) {
		t.Fatalf("arrival final = %v, want [0 2 1]", *gotA)
	}
	if string(*gotO) == string(*gotA) {
		t.Fatal("BOTH MODES PRODUCED THE SAME DELIVERY ORDER. `max` and `speed` are the " +
			"same datapath again -- this is exactly the state U17a found and closed")
	}
}

// 8
func TestRingArrivalDedupsFirstCopyWins(t *testing.T) {
	r, got := schedRing(true, 30*time.Millisecond)
	n := time.Now()
	r.Push(5, []byte{5}, n)
	r.Push(5, []byte{99}, n.Add(time.Millisecond))
	if len(*got) != 1 || (*got)[0] != 5 {
		t.Fatalf("delivered %v: the FIRST copy wins and the second is suppressed", *got)
	}
	if r.Dups != 1 {
		t.Fatalf("Dups=%d, want 1: the dedup memory is the only job the ring keeps in "+
			"this mode, and E2c lightning depends on it", r.Dups)
	}
}

// 9
func TestRingArrivalNeverSkipsAndTickIsInert(t *testing.T) {
	r, got := schedRing(true, 30*time.Millisecond)
	n := time.Now()
	r.Push(0, []byte{0}, n)
	r.Push(10, []byte{10}, n) // a nine-frame hole
	before := len(*got)
	r.Tick(n.Add(time.Hour))
	if len(*got) != before {
		t.Fatalf("Tick delivered %d more frames: nothing is buffered, so nothing can be "+
			"released by a timer", len(*got)-before)
	}
	if r.Skips != 0 || r.Olds != 0 {
		t.Fatalf("skips=%d olds=%d: a hole is not an event in this mode -- the frame "+
			"either arrived or it did not", r.Skips, r.Olds)
	}
	if string(*got) != string([]byte{0, 10}) {
		t.Fatalf("delivered %v, want [0 10]", *got)
	}
}

// 10
func TestRingArrivalHoldDurIsZeroAndInOrderIsNot(t *testing.T) {
	ra, _ := schedRing(true, 30*time.Millisecond)
	ro, _ := schedRing(false, 30*time.Millisecond)
	ra.SetHold(77 * time.Millisecond)
	ro.SetHold(77 * time.Millisecond)
	if ra.HoldDur() != 0 {
		t.Fatalf("arrival reports hold=%v: the PSTAT line is how an operator tells the "+
			"two modes apart, and a hold nobody waits on is a false number there",
			ra.HoldDur())
	}
	if ro.HoldDur() != 77*time.Millisecond {
		t.Fatalf("in-order reports hold=%v, want 77ms", ro.HoldDur())
	}
	if !ra.Arrival() || ro.Arrival() {
		t.Fatal("Arrival() does not report the policy the ring is running")
	}
}

// 11
func TestRankerEchoWithinBudgetIsAHit(t *testing.T) {
	r := NewRanker(1)
	t0 := time.Now()
	r.Ping(0, 7, t0)
	r.Echo(0, 7, t0.Add(20*time.Millisecond))
	r.Epoch(t0.Add(21 * time.Millisecond))
	h, d, haveH, haveD := r.Key(0)
	if !haveH || !haveD {
		t.Fatal("an answered probe left the statistics unmeasured")
	}
	if h != 1.0 {
		t.Fatalf("hhat=%v, want 1.0: one probe, answered inside the budget", h)
	}
	if d != 20 {
		t.Fatalf("lastD=%v, want 20 (ms, round trip in THIS client's clock)", d)
	}
}

// 12
func TestRankerUnansweredPingMaturesIntoAMiss(t *testing.T) {
	r := NewRanker(1)
	t0 := time.Now()
	r.Ping(0, 7, t0)
	r.Epoch(t0.Add(SpeedBudgetRTT + time.Millisecond))
	h, _, haveH, _ := r.Key(0)
	if !haveH {
		t.Fatal("an unanswered probe produced no hit-rate at all: loss must reach hhat " +
			"without a separate term, or the K4 rank cannot see DEG-LOSS")
	}
	if h != 0.0 {
		t.Fatalf("hhat=%v, want 0.0: a probe that never came back cannot have come back "+
			"within the budget", h)
	}
}

// 13
func TestRankerLateEchoIsAMissNotAHit(t *testing.T) {
	r := NewRanker(1)
	t0 := time.Now()
	r.Ping(0, 9, t0)
	r.Echo(0, 9, t0.Add(SpeedBudgetRTT+time.Millisecond))
	r.Epoch(t0.Add(SpeedBudgetRTT + 2*time.Millisecond))
	h, d, _, haveD := r.Key(0)
	if h != 0.0 {
		t.Fatalf("hhat=%v, want 0.0: arriving late is a miss, which is how hhat fuses "+
			"latency and loss with no coefficient", h)
	}
	if !haveD || d <= float64(SpeedBudgetRTT/time.Millisecond) {
		t.Fatalf("lastD=%v: a late sample must still update lastD -- a filter that only "+
			"took the good samples could never learn a path got worse", d)
	}
}

// 14  DEG-LOSS: equal latency, one path loses. K1/K2/K3 never demote it (design
// sec 3.6); K4 must.
func TestRankerDemotesLossyPathAtEqualLatency(t *testing.T) {
	r := NewRanker(2)
	t0 := time.Now()
	for k := 0; k < 5; k++ {
		ts := uint32(k)
		r.Ping(0, ts, t0)
		r.Echo(0, ts, t0.Add(10*time.Millisecond))
		r.Ping(1, ts, t0)
		if k < 4 {
			r.Echo(1, ts, t0.Add(10*time.Millisecond))
		}
	}
	r.Epoch(t0.Add(SpeedBudgetRTT + time.Millisecond))
	h0, d0, _, _ := r.Key(0)
	h1, d1, _, _ := r.Key(1)
	if d0 != d1 {
		t.Fatalf("the two paths must be latency-IDENTICAL for this bar to mean anything: "+
			"%v vs %v", d0, d1)
	}
	if !(h0 > h1) {
		t.Fatalf("hhat did not separate a lossy path from a clean one at equal latency: "+
			"%v vs %v", h0, h1)
	}
	if !r.Better(0, 1) {
		t.Fatal("the clean path is not ranked better than the lossy one: this is DEG-LOSS, " +
			"the one degradation a latency-only key can never see")
	}
	if r.Better(1, 0) {
		t.Fatal("the lossy path ranks better than the clean one")
	}
}

// 15  The clock-skew degradation path, and it is a real one: if the RTT budget
// is wrong for this hardware every path scores the same hhat, and K4 must then
// fall back to K2 (lastD) rather than losing its order entirely.
func TestRankerFallsBackToLatencyWhenHitRatesTie(t *testing.T) {
	r := NewRanker(2)
	t0 := time.Now()
	r.Ping(0, 1, t0)
	r.Echo(0, 1, t0.Add(10*time.Millisecond))
	r.Ping(1, 1, t0)
	r.Echo(1, 1, t0.Add(30*time.Millisecond))
	r.Epoch(t0.Add(SpeedBudgetRTT + time.Millisecond))
	h0, _, _, _ := r.Key(0)
	h1, _, _, _ := r.Key(1)
	if h0 != h1 {
		t.Fatalf("this bar needs the hit rates to TIE (both inside the budget): %v vs %v",
			h0, h1)
	}
	if !r.Better(0, 1) || r.Better(1, 0) {
		t.Fatal("with hhat tied the rank must be decided by lastD, ascending")
	}
}

// 16
func TestRankerUnmeasuredPathIsNeitherBetterNorWorse(t *testing.T) {
	r := NewRanker(2)
	setStats(r, 0, 1.0, true, 10, true)
	if r.Better(0, 1) || r.Better(1, 0) {
		t.Fatal("a path with no statistics was ordered against one that has them. " +
			"Blocking it would be ranking on absence, and a link that cannot draw " +
			"cannot be re-promoted")
	}
}

// 17  N-GENERIC: the order must depend on the statistics and not on the index.
func TestRankerIsInvariantUnderPermutationOfPaths(t *testing.T) {
	hb := []float64{1.0, 0.8, 1.0, 0.5}
	ld := []float64{10, 10, 30, 5}
	perm := []int{3, 0, 2, 1}
	n := len(hb)
	base := NewRanker(n)
	perd := NewRanker(n)
	for i := 0; i < n; i++ {
		setStats(base, i, hb[i], true, ld[i], true)
		setStats(perd, perm[i], hb[i], true, ld[i], true)
	}
	for a := 0; a < n; a++ {
		for b := 0; b < n; b++ {
			if base.Better(a, b) != perd.Better(perm[a], perm[b]) {
				t.Fatalf("Better(%d,%d)=%v but the permuted ranker says %v for the SAME "+
					"two paths. Some index is privileged", a, b, base.Better(a, b),
					perd.Better(perm[a], perm[b]))
			}
		}
	}
}

// rankCell is one link's K4 statistics. rankGrid is every combination of the
// three hhat values, the three lastD values, and the present/absent flag on each
// -- 3*2*3*2 = 36 cells, which is the whole shape space of a Ranker entry as far
// as `Better` can tell them apart.
type rankCell struct {
	hbar  float64
	haveH bool
	lastD float64
	haveD bool
}

func rankGrid() []rankCell {
	hs := []float64{0, 0.5, 1}
	ds := []float64{5, 10, 20}
	var out []rankCell
	for _, h := range hs {
		for _, hh := range []bool{true, false} {
			for _, d := range ds {
				for _, hd := range []bool{true, false} {
					out = append(out, rankCell{h, hh, d, hd})
				}
			}
		}
	}
	return out
}

func rankerOf(cells ...rankCell) *Ranker {
	r := NewRanker(len(cells))
	for i, c := range cells {
		setStats(r, i, c.hbar, c.haveH, c.lastD, c.haveD)
	}
	return r
}

// 18  THE NO-STALL PROOF. If `Better` ever admitted a cycle, every eligible link
// could be blocked by another and the pool would stall until the control tick,
// forever, on a box with no console.
//
// This bar was a RANDOM SAMPLE and it was not good enough. It drew 400 triples
// per n from exactly the grid below and asserted only that a source node exists.
// A real cycle lives in that grid -- 54 of the 46656 triples, 0.116% -- so the
// sample missed it with probability (1-0.001157)^400 = 0.63. It was a coin flip
// on the one property it existed to establish, and it came up heads.
//
// So it is EXHAUSTIVE now, and it checks TRANSITIVITY rather than a source node.
// That is the stronger and the cheaper claim: transitivity is a property of
// TRIPLES, so enumerating every triple over the grid settles it for every n, and
// an irreflexive antisymmetric transitive relation has no cycles of ANY length.
// A source-node check at n<=8 could never have said that.
func TestRankerBetterIsAcyclicSoSomeLinkAlwaysDraws(t *testing.T) {
	g := rankGrid()
	if len(g) != 36 {
		t.Fatalf("the grid is %d cells, not 36 -- the exhaustive claim below is "+
			"about a different space than the one this bar enumerates", len(g))
	}
	for i := range g {
		for j := range g {
			for k := range g {
				tri := []rankCell{g[i], g[j], g[k]}
				r := rankerOf(tri...)
				// irreflexive
				for x := 0; x < 3; x++ {
					if r.Better(x, x) {
						t.Fatalf("%+v is strictly better than itself", tri[x])
					}
				}
				// antisymmetric
				for x := 0; x < 3; x++ {
					for y := 0; y < 3; y++ {
						if x != y && r.Better(x, y) && r.Better(y, x) {
							t.Fatalf("%+v and %+v are each strictly better than the "+
								"other", tri[x], tri[y])
						}
					}
				}
				// transitive -- this is what makes it acyclic at EVERY n
				for x := 0; x < 3; x++ {
					for y := 0; y < 3; y++ {
						for z := 0; z < 3; z++ {
							if x == y || y == z || x == z {
								continue
							}
							if r.Better(x, y) && r.Better(y, z) && !r.Better(x, z) {
								t.Fatalf("NOT TRANSITIVE: %+v > %+v > %+v but the first "+
									"is not better than the last. A non-transitive "+
									"comparator admits a cycle, and a cycle is every "+
									"link blocked and nothing drawing",
									tri[x], tri[y], tri[z])
							}
						}
					}
				}
				// and, directly, a source node exists
				free := 0
				for x := 0; x < 3; x++ {
					blocked := false
					for y := 0; y < 3; y++ {
						if y != x && r.Better(y, x) {
							blocked = true
							break
						}
					}
					if !blocked {
						free++
					}
				}
				if free == 0 {
					t.Fatalf("EVERY link is blocked by another: %+v %+v %+v. The pool "+
						"would stall until the control tick and then stall again",
						tri[0], tri[1], tri[2])
				}
			}
		}
	}
}

// 18a  THE CONCRETE CYCLE, as a regression bar. The exhaustive sweep above would
// catch this too, but a named triple says WHICH defect this is, and it is the one
// an adversarial review flagged and a passing random test failed to refute.
//
// Reachable, not synthetic: Echo sets haveD and Epoch sets haveH, so every link
// is haveD-without-haveH from its first echo until the next LossIval. That is the
// state a hot-plugged WAN is in. It needs three links, so a 2-source box cannot
// show it and the N=3 client can.
func TestRankerLastDWithoutHbarCannotFormACycle(t *testing.T) {
	// Link 0 (A) and link 1 (B) carry both statistics. Link 2 (C) has echoed
	// once and no Epoch has closed on it yet, so it has lastD and no hhat.
	r := rankerOf(
		rankCell{hbar: 0.5, haveH: true, lastD: 20, haveD: true},
		rankCell{hbar: 0.0, haveH: true, lastD: 5, haveD: true},
		rankCell{haveH: false, lastD: 10, haveD: true},
	)
	if !r.Better(0, 1) {
		t.Fatal("A has the higher hhat and both carry it, so A must outrank B; " +
			"this bar is no longer about the cycle it was written for")
	}
	// The two edges that used to close the cycle, both decided by lastD only
	// because C had no hhat. hhat is the PRIMARY key: a pair that does not both
	// carry it is incomparable, not ranked on the tie-break.
	if r.Better(1, 2) {
		t.Fatal("B > C was decided by lastD alone because C has no hhat. That makes " +
			"lastD a primary key for some pairs and a tie-break for others, which " +
			"is exactly what closed the A>B>C>A cycle")
	}
	if r.Better(2, 0) {
		t.Fatal("C > A was decided by lastD alone because C has no hhat -- the second " +
			"edge of the cycle")
	}
	blocked := 0
	for x := 0; x < 3; x++ {
		for y := 0; y < 3; y++ {
			if x != y && r.Better(y, x) {
				blocked++
				break
			}
		}
	}
	if blocked == 3 {
		t.Fatal("all three links are blocked: this is the stall the cycle causes")
	}
}

// 18b  The same triple at the GATE, which is where the stall would actually be
// felt. rankGate is the only consumer of Better, so acyclicity that is true of
// the relation and untested at the gate is a proof about the wrong object.
func TestRankGateNeverBlocksEveryEligibleLink(t *testing.T) {
	links := schedLinks(3)
	rk := rankerOf(
		rankCell{hbar: 0.5, haveH: true, lastD: 20, haveD: true},
		rankCell{hbar: 0.0, haveH: true, lastD: 5, haveD: true},
		rankCell{haveH: false, lastD: 10, haveD: true},
	)
	g := &rankGate{rk: rk, links: links}
	draws := 0
	for i := 0; i < 3; i++ {
		if !links[i].Eligible() {
			t.Fatalf("link %d starts ineligible; this bar needs all three eligible "+
				"or it is not testing the stall", i)
		}
		if g.MayDraw(i) {
			draws++
		}
	}
	if draws == 0 {
		t.Fatal("three eligible links and NOT ONE may draw. `speed` sends nothing " +
			"until a statistic changes, on a box with no console")
	}
}

// 19
func TestRankGateBlocksWorseLinkUntilTheBetterGateCloses(t *testing.T) {
	links := schedLinks(2)
	rk := NewRanker(2)
	setStats(rk, 0, 1.0, true, 10, true)
	setStats(rk, 1, 0.5, true, 10, true)
	g := &rankGate{rk: rk, links: links}
	if !g.MayDraw(0) {
		t.Fatal("the best-ranked link is blocked; nothing would ever draw")
	}
	if g.MayDraw(1) {
		t.Fatal("the worse-ranked link may draw while a better one is open: `speed` is " +
			"latency-first, and this is the whole of it")
	}
	links[0].setGateClosed(true)
	if !g.MayDraw(1) {
		t.Fatal("the better link's gate CLOSED and the worse one still may not draw: " +
			"that is a stall, not a spill")
	}
	links[0].setGateClosed(false)
	if g.MayDraw(1) {
		t.Fatal("the better link re-opened and the worse one kept drawing")
	}
}

// 20
func TestRankGateIgnoresDeadAndDisabledLinks(t *testing.T) {
	links := schedLinks(2)
	rk := NewRanker(2)
	setStats(rk, 0, 1.0, true, 10, true)
	setStats(rk, 1, 0.5, true, 10, true)
	g := &rankGate{rk: rk, links: links}
	links[0].SetAlive(false)
	if !g.MayDraw(1) {
		t.Fatal("a DEAD better-ranked link still pins the worse one: the far end has " +
			"stopped answering and the box would stop sending")
	}
	links[0].SetAlive(true)
	if g.MayDraw(1) {
		t.Fatal("liveness is not level-triggered in the gate")
	}
	dis := []*PullLink{NewPullLink(0, "w0", nil, testDst()), links[1]}
	g2 := &rankGate{rk: rk, links: dis}
	if !g2.MayDraw(1) {
		t.Fatal("a structurally DISABLED better-ranked link (no socket) still pins the " +
			"worse one; it can never send, so it can never yield either")
	}
}

// 21
func TestSetSchedInstallsNoGateForMax(t *testing.T) {
	c := &PullCore{FIFO: NewPullFIFO(), Links: schedLinks(3)}
	c.SetSched(schedPolicies["max"], NewRanker(3))
	for i, l := range c.Links {
		if l.gate != nil {
			t.Fatalf("link %d carries a gate under `max`. The mode the box runs today "+
				"must keep U7's draw loop verbatim", i)
		}
	}
	c.SetSched(schedPolicies["speed"], NewRanker(3))
	for i, l := range c.Links {
		if l.gate == nil {
			t.Fatalf("link %d carries no gate under `speed`: the rank is unreachable and "+
				"the two modes draw identically", i)
		}
	}
}

// 22
func TestSetSchedSpeedWithoutARankerFallsBackToDrawOrder(t *testing.T) {
	c := &PullCore{FIFO: NewPullFIFO(), Links: schedLinks(2)}
	c.SetSched(schedPolicies["speed"], nil)
	for i, l := range c.Links {
		if l.gate != nil {
			t.Fatalf("link %d gated with no statistics behind the gate", i)
		}
	}
}

// 23  THE TX-SIDE A/B, end to end through Drive. Identical offer, identical
// sockets, identical statistics -- only AGG_SCHED differs.
func TestSpeedAndMaxProduceDifferentDrawSets(t *testing.T) {
	const frames = 40
	run := func(name string) (best, worse, defers uint64) {
		f := NewPullFIFO()
		// The better-ranked link is SLOW but always accepts. That is the point:
		// `speed` must not spill to a worse path merely because the best one is
		// slow -- it spills when a gate CLOSES, and a successful write is not a
		// closed gate.
		l0 := newPullLinkSock(0, "w0", newFakeSock(2*time.Millisecond, nil), testDst())
		l1 := newPullLinkSock(1, "w1", newFakeSock(0, nil), testDst())
		c := &PullCore{FIFO: f, Links: []*PullLink{l0, l1}}
		rk := NewRanker(2)
		setStats(rk, 0, 1.0, true, 10, true)
		setStats(rk, 1, 0.5, true, 10, true)
		c.SetSched(schedPolicies[name], rk)
		for i := 0; i < frames; i++ {
			f.Enqueue([]byte{byte(i)}, time.Now())
		}
		c.Start()
		waitFor(func() bool { return l0.Sent()+l1.Sent() >= frames }, 10*time.Second)
		f.Close()
		return l0.Sent(), l1.Sent(), l1.Defers()
	}
	m0, m1, mdef := run("max")
	s0, s1, sdef := run("speed")
	if m0+m1 != frames {
		t.Fatalf("max lost frames: %d+%d != %d", m0, m1, frames)
	}
	if s0+s1 != frames {
		t.Fatalf("speed lost frames: %d+%d != %d", s0, s1, frames)
	}
	if m1 == 0 {
		t.Fatalf("under `max` the second link carried NOTHING (%d/%d). `max` is "+
			"work-conserving: every link that can send, does", m1, frames)
	}
	if mdef != 0 {
		t.Fatalf("under `max` a link deferred %d times. No gate exists in that mode", mdef)
	}
	if s1 != 0 {
		t.Fatalf("under `speed` the WORSE-ranked link carried %d of %d frames while the "+
			"better one was accepting every write. The rank is not reaching the draw "+
			"loop, so `speed` is drawing like `max`", s1, frames)
	}
	if sdef == 0 {
		t.Fatal("under `speed` the worse-ranked link never deferred: it was not gated at all")
	}
	if m1 == s1 {
		t.Fatal("BOTH MODES PRODUCED THE SAME DRAW SET. AGG_SCHED is not reaching the " +
			"datapath -- the exact state U17a found")
	}
}

// 24
func TestPullFIFOWakeReleasesEveryParkedRankWaiter(t *testing.T) {
	f := NewPullFIFO()
	done := make(chan int, 2)
	for k := 0; k < 2; k++ {
		go func(k int) { f.WaitRank(); done <- k }(k)
	}
	if !waitFor(func() bool { return f.RankParked() == 2 }, 2*time.Second) {
		t.Fatalf("only %d rank waiters parked", f.RankParked())
	}
	f.Wake()
	for k := 0; k < 2; k++ {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("Wake released fewer than EVERY parked rank waiter. A Signal here " +
				"leaves N-1 links idle for up to N control ticks with work in the pool")
		}
	}
}

// 25
func TestPullFIFORankChangedReleasesParkedRankWaiter(t *testing.T) {
	f := NewPullFIFO()
	done := make(chan struct{}, 2)
	for k := 0; k < 2; k++ {
		go func() { f.WaitRank(); done <- struct{}{} }()
	}
	if !waitFor(func() bool { return f.RankParked() == 2 }, 2*time.Second) {
		t.Fatalf("only %d rank waiters parked", f.RankParked())
	}
	f.RankChanged()
	for k := 0; k < 2; k++ {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("a gate-close did not release every deferring link, so the spill " +
				"waits for the control tick instead of for the event that caused it")
		}
	}
}

// 26
func TestPullFIFOProgressAndEnqueueDoNotReleaseParkedRankWaiter(t *testing.T) {
	f := NewPullFIFO()
	done := make(chan struct{}, 1)
	go func() { f.WaitRank(); done <- struct{}{} }()
	if !waitFor(func() bool { return f.RankParked() == 1 }, 2*time.Second) {
		t.Fatal("no rank waiter parked")
	}
	f.Progress()
	f.Enqueue([]byte{1}, time.Now())
	fr, ok := f.Draw()
	if !ok {
		t.Fatal("nothing to draw")
	}
	f.Return(fr, time.Now())
	select {
	case <-done:
		t.Fatal("a DRAIN event released a link that was deferring on RANK. The better " +
			"link draining is precisely the reason to keep deferring, and merging the " +
			"two wake sets is how two refusing links woke each other at CPU speed before")
	case <-time.After(50 * time.Millisecond):
	}
	f.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Close stranded a deferring link")
	}
}

// 27
func TestSchedRankIsNGenericUpToTheWireCeiling(t *testing.T) {
	for _, n := range []int{0, 1, 2, 3, 5, 8, 16, MaxLinks} {
		rk := NewRanker(n)
		if rk.N() != n {
			t.Fatalf("NewRanker(%d).N()=%d", n, rk.N())
		}
		links := schedLinks(n)
		g := &rankGate{rk: rk, links: links}
		for i := 0; i < n; i++ {
			if !g.MayDraw(i) {
				t.Fatalf("n=%d: link %d gated with NO statistics anywhere", n, i)
			}
		}
		// A strict total order whose BEST member is the LAST index. If any index
		// were privileged this is where it would show.
		for i := 0; i < n; i++ {
			lat := n - i
			setStats(rk, i, 1.0, true, float64(lat), true)
		}
		allowed := 0
		for i := 0; i < n; i++ {
			if g.MayDraw(i) {
				allowed++
			}
		}
		if n == 0 {
			continue
		}
		if allowed != 1 {
			t.Fatalf("n=%d: %d links may draw under a strict total order, want exactly 1",
				n, allowed)
		}
		if !g.MayDraw(n - 1) {
			t.Fatalf("n=%d: the best-ranked link is the LAST index and it may not draw", n)
		}
	}
}

// 28  THE WIRING BAR. A policy that is correct and connected to nothing is the
// redline-6 defect verbatim, and it is the one this suite could not otherwise
// see: runPullClient binds real sockets, so no test can call it. ApplySched is
// the seam that makes the connection executable.
func TestApplySchedWiresBothHalves(t *testing.T) {
	for _, name := range []string{"max", "speed"} {
		pol := schedPolicies[name]
		c := &PullCore{FIFO: NewPullFIFO(), Links: schedLinks(3)}
		r, _ := schedRing(false, 30*time.Millisecond)
		rk := NewRankerFor(pol, c.N())
		ApplySched(pol, c, r, rk)
		wantArrival := pol.Delivery == DeliverOnArrival
		if r.Arrival() != wantArrival {
			t.Fatalf("%s: ring arrival=%v, want %v -- the delivery half of the policy "+
				"never reached the ring", name, r.Arrival(), wantArrival)
		}
		wantGate := pol.Rank == RankDeadlineHit
		for i, l := range c.Links {
			if (l.gate != nil) != wantGate {
				t.Fatalf("%s: link %d gate=%v, want gated=%v -- the rank half of the "+
					"policy never reached the draw loop", name, i, l.gate != nil, wantGate)
			}
		}
		if (rk != nil) != wantGate {
			t.Fatalf("%s: NewRankerFor built ranker=%v, want %v", name, rk != nil, wantGate)
		}
	}
	// Total and order-independent: a nil half must not panic.
	ApplySched(schedPolicies["speed"], nil, nil, nil)
}

// 29
func TestApplySchedIsIdempotentAndReversible(t *testing.T) {
	c := &PullCore{FIFO: NewPullFIFO(), Links: schedLinks(2)}
	r, _ := schedRing(false, 30*time.Millisecond)
	sp := schedPolicies["speed"]
	ApplySched(sp, c, r, NewRankerFor(sp, 2))
	ApplySched(sp, c, r, NewRankerFor(sp, 2))
	if !r.Arrival() || c.Links[0].gate == nil {
		t.Fatal("applying the same policy twice changed the answer")
	}
	mx := schedPolicies["max"]
	ApplySched(mx, c, r, NewRankerFor(mx, 2))
	if r.Arrival() {
		t.Fatal("`max` left the ring in arrival mode")
	}
	if c.Links[0].gate != nil || c.Links[1].gate != nil {
		t.Fatal("`max` left a rank gate installed")
	}
}

// 30
func TestRankerNilReceiverIsInertSoMaxPaysNothing(t *testing.T) {
	var rk *Ranker
	now := time.Now()
	rk.Ping(0, 1, now)
	rk.Echo(0, 1, now)
	rk.Epoch(now)
	if rk.N() != 0 {
		t.Fatal("a nil Ranker claims links")
	}
	if rk.Better(0, 1) {
		t.Fatal("a nil Ranker orders paths")
	}
	if rk.Stat(0) != "" {
		t.Fatalf("a nil Ranker prints %q into the `max` PSTAT line, which must stay "+
			"byte-identical to what it was before this unit", rk.Stat(0))
	}
	if _, _, h, d := rk.Key(0); h || d {
		t.Fatal("a nil Ranker claims measurements")
	}
}
