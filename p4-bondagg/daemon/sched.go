package main

// =============================================================================
// U17a -- AGG_SCHED, the fact that makes `max` and `speed` two different
// daemons instead of one daemon with two names.
//
// THE DEFECT THIS CLOSES, measured, not recalled:
//   grep -rn AGG_SCHED p4-bondagg/daemon/  -> 0
//   grep -rn AGG_SCHED p4-bondagg/server/  -> 0
// `bond-xctl` emits AGG_SCHED=max|speed into agg_env (bond-xctl
// @"echo \"AGG_SCHED=$(agg_sched_of)\"") and both procd stanzas pass it in the
// unit's environment (deploy/p5/init.d/bond-agg, and the byte-equal fallback
// stanza in bond-xctl), so the ORCHESTRATION distinguishes the two modes end to
// end -- and the datapath then threw the fact away. `bondctl mode speed`
// silently did `max`.
//
// THE POLICIES ARE NOT DERIVED HERE. They are settled in
// docs/knowledge/design/modes-max-speed-design.md (r2, measured, 2026-08-29):
//   max   = rank:hungriest . delivery:in_order   . hold:ratchet
//   speed = rank:K4        . delivery:on_arrival . hold:none
// This file is the CONSUMER of that decision, not a place to re-open it.
//
// WHAT THIS BUILD ACTUALLY IMPLEMENTS, and where it falls short of the design.
// Stated up front so nothing downstream reads the table above as a claim about
// the code:
//
//   speed / delivery:on_arrival  -- IMPLEMENTED, unconditionally (ring.go
//       arrival mode). No hold, no in-order release, dedup only. This half needs
//       no statistics and no peer cooperation, so it is the difference that
//       always exists between the two modes.
//   speed / hold:none            -- IMPLEMENTED, and it is not a second
//       mechanism: it FALLS OUT of deliver-on-arrival. The ring waits for
//       nothing, so there is no hold to set. HoldDur reports 0 in this mode,
//       which is what makes the mode visible in the PSTAT line.
//   speed / rank:K4              -- IMPLEMENTED as `(-hhat_i, lastD_i)`, with
//       the oracle's `+ local_ms_i` term ABSENT. local_ms is backlog/drain-EWMA
//       -- a rate estimate, and the pivot deleted the estimator (pull.go S1).
//       The missing term is the same open divergence S1 already records for draw
//       order; it is named here as S1b so it is not read as ported.
//   max / rank:hungriest         -- NOT IMPLEMENTED, and was not implemented
//       before this unit either. pull.go S1 records in as many words that Go
//       substitutes sync.Mutex acquisition order for `cand.sort(key=_local_ms)`,
//       for the same reason: no estimator. `max` therefore keeps EXACTLY the
//       draw behaviour it had before this file existed -- RankDrainOrder
//       installs no gate at all and PullLink.gate stays nil, so Drive runs U7's
//       loop verbatim. This unit does not narrow that gap and does not pretend
//       to.
//   max / hold:ratchet           -- NOT IMPLEMENTED. The lateness ratchet is the
//       DERIVED hold and it is U13/OBJ-B's unit (ROADMAP @"| U13 |"), still not
//       started. `max` keeps today's owd.Hold = clamp(spread+3*jit+250,150,350)
//       (paths.go), which is already on the HANDOFF record as owed a derivation.
//       Landing a ratchet here would be a second writer on U13's file set and
//       would ship an untested formula in the same commit as the mode split.
//
// So the honest one-line summary of this unit: the two modes now differ in
// DELIVERY unconditionally and in DRAW ORDER whenever the echo surface is alive.
// Neither of the two NOT-IMPLEMENTED rows is a max-vs-speed difference -- both
// are `max` refinements owned elsewhere -- so neither one can make the modes
// identical again.
//
// N-GENERICITY. Nothing here is indexed by a privileged path. The policy is one
// value for the whole datapath; the Ranker is N slices and a comparison; the
// gate is a loop over links with no first-path case and no 2-source assumption.
// Ties compare EQUAL and both links draw (the design's striping, sec 3.4), which
// is also what makes the whole thing invariant under permutation of AGG_PATHS --
// an index tie-break would not be. Asserted for N up to the wire ceiling
// (MaxLinks = 256, frame.go one-byte pathID) in sched_test.go.
// =============================================================================

import (
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// The policy
// ---------------------------------------------------------------------------

// SchedRank is the DRAW-ORDER half of a scheduler.
type SchedRank int

const (
	// RankDrainOrder is `max`: whoever drains first draws first. It installs NO
	// gate -- the draw order is whatever the pool's mutex hands out, which is
	// pull.go S1's open divergence from the oracle's hungriest-first and is
	// unchanged by this unit.
	RankDrainOrder SchedRank = iota
	// RankDeadlineHit is `speed`'s K4: order by (-hhat, lastD). A worse-ranked
	// source draws only while better ones' gates are closed (design sec 3.1,
	// emergent activation) -- there is no admission controller and no discrete
	// activation state.
	RankDeadlineHit
)

// SchedDelivery is the RECEIVE half.
type SchedDelivery int

const (
	// DeliverInOrder is `max`: the reorder ring releases in seq order and holds
	// a gap. Justified by the inner TCP the model does not price (design sec 4.5).
	DeliverInOrder SchedDelivery = iota
	// DeliverOnArrival is `speed`: release the instant a frame arrives, dedup
	// only, never wait. Measured to dominate every hold policy on every speed
	// scenario -- never worse on loss, latency or freeze (design sec 4.3).
	DeliverOnArrival
)

// SchedHold is the reorder horizon.
type SchedHold int

const (
	// HoldReorder is the receiver hold `max` uses today. NOT the design's
	// ratchet -- see the file header and U13.
	HoldReorder SchedHold = iota
	// HoldNone is `speed`: there is no hold, because there is nothing to hold
	// for. It is a consequence of DeliverOnArrival, not an independent knob.
	HoldNone
)

// SchedPolicy is the whole of what AGG_SCHED selects.
type SchedPolicy struct {
	Name     string
	Rank     SchedRank
	Delivery SchedDelivery
	Hold     SchedHold
	// Fanout is the SEND half, and it is the only one of these four that changes
	// how many times a frame leaves the box. False (every mode but `lightning`)
	// is one shared pool and one copy per frame -- the pull core U7 wrote. True
	// is per-link pools fed one seq: every source carries every packet
	// (ADR-003:38), first copy wins by the seq dedup both rings already do.
	Fanout bool
}

// schedPolicies is the daemon's half of the mode->scheduler contract. The
// AUTHORITATIVE table -- which MODE maps to which SCHEDULER -- lives in exactly
// one place, `bond-xctl`'s AGG_SCHED_TABLE, and orchestration/bond_model.py
// asserts that no other shipped artifact restates it. This map is not that
// table: it is the set of SCHEDULERS this binary can run, keyed by the value the
// table emits. Adding a third scheduler is a row there and an entry here, and
// nothing else anywhere.
var schedPolicies = map[string]SchedPolicy{
	"max": {
		Name:     "max",
		Rank:     RankDrainOrder,
		Delivery: DeliverInOrder,
		Hold:     HoldReorder,
	},
	"speed": {
		Name:     "speed",
		Rank:     RankDeadlineHit,
		Delivery: DeliverOnArrival,
		Hold:     HoldNone,
	},
	// U138/U119. `eco` is the pull core at N=1 over the primary source: one
	// link, so there is no draw order to choose (drain-order is the identity at
	// N=1) and nothing to reorder ACROSS, which is why delivery is on arrival
	// and the hold is none -- on one path a seq gap is a LOSS, not a reorder,
	// and holding for it buys nothing. Fanout is false because at N=1 fan-out
	// and no fan-out are the same wire. REFUSED at N != 1: see SchedArity.
	"eco": {
		Name:     "eco",
		Rank:     RankDrainOrder,
		Delivery: DeliverOnArrival,
		Hold:     HoldNone,
		Fanout:   false, // stated, not defaulted: it is what separates eco from lightning
	},
	// `lightning` is `eco`'s delivery rules with the send side fanned out: every
	// live source carries every frame. The draw order is drain-order because
	// under fan-out there is nothing to order -- each link owns its own pool and
	// takes its own copy, so no link can pin another (a rank gate would only be
	// able to make a link skip a frame nobody else was going to send for it).
	"lightning": {
		Name:     "lightning",
		Rank:     RankDrainOrder,
		Delivery: DeliverOnArrival,
		Hold:     HoldNone,
		Fanout:   true,
	},
}

// SchedInherited is what an ABSENT AGG_SCHED means, and the choice is
// deliberate in both directions:
//
//   - it is `max`, because `max` is byte-for-byte the datapath this daemon ran
//     before AGG_SCHED existed. A stanza that predates U17 (direction-B
//     half-upgraded box, ROADMAP U17c) therefore keeps behaving exactly as it
//     did, rather than silently acquiring a new datapath.
//   - it is LOGGED as inherited rather than as a choice, and SchedFromEnv
//     reports explicit=false so the caller can say so. "The operator asked for
//     max" and "nobody said anything" are different facts and this daemon does
//     not conflate them.
//
// What is NOT allowed is the thing U17a exists to remove: a NAMED scheduler
// being served as a different one. An unrecognised AGG_SCHED is an error, never
// a fallback to this default.
const SchedInherited = "max"

// SchedNames lists the schedulers this build implements, sorted so the error
// text is stable.
func SchedNames() []string {
	out := make([]string, 0, len(schedPolicies))
	for k := range schedPolicies {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// SchedFromEnv resolves AGG_SCHED. get is the environment reader (the daemon
// passes env; tests pass a map) so this is executable without touching process
// state.
//
// explicit reports whether AGG_SCHED was actually set. The error case is a
// REFUSAL, not a degradation: a value this build does not implement means the
// orchestration and the datapath disagree about what mode the box is in, and
// running anyway is precisely the silent substitution that made `bondctl mode
// speed` do `max`.
// n is the source count (len(AGG_PATHS)) and it is a parameter because ONE
// scheduler is arity-bound: `eco` IS the N=1 datapath and means nothing at any
// other N. The refusal happens here, before this process binds a socket, which
// is the same reason the unknown-value refusal is here (U138/U119).
func SchedFromEnv(get func(string) string, n int) (SchedPolicy, bool, error) {
	v := get("AGG_SCHED")
	if v == "" {
		return schedPolicies[SchedInherited], false, nil
	}
	q, ok := schedPolicies[v]
	if !ok {
		return SchedPolicy{}, true, fmt.Errorf(
			"AGG_SCHED=%q is not a scheduler this build implements (implemented: %s). "+
				"REFUSING to start. Serving an unknown scheduler as %q is the exact "+
				"silent substitution U17a removes: the orchestration would report the "+
				"box in one mode while the wire carried another",
			v, strings.Join(SchedNames(), "|"), SchedInherited)
	}
	if err := SchedArity(q, n); err != nil {
		return SchedPolicy{}, true, err
	}
	if q.Fanout && n == 1 {
		log.Printf("pull-sched: AGG_SCHED=%s at N=1 is DEGENERATE -- with one source, "+
			"'every source carries every frame' is one copy, which is exactly `eco`'s "+
			"datapath. Accepted rather than refused: the mode is the orchestration's "+
			"choice and a source can leave the set between the fact being written and "+
			"this daemon starting, so a running lightning box that loses a source must "+
			"keep running. Nothing here changes shape at N=1; the fan-out is over one "+
			"pool.", q.Name)
	}
	return q, true, nil
}

// SchedArity is the N half of the mode contract, and it is the SAME rule the DAG
// enforces from the other side (guard sources_for_mode, U141) -- stated in both
// places deliberately, per the U17a refusal doctrine: the daemon never serves a
// named mode as a different one, and "eco over three sources" is not eco.
//
// It is a refusal and not a degradation for the reason the unknown-value branch
// above gives: bond-ecod flips eco<->lightning by an agg_env byte change and one
// restart, so an eco stanza reaching a box with N != 1 means the orchestration
// and the datapath disagree about the box, and running anyway would report one
// mode while the wire carried another.
//
// n <= 0 is "the caller does not know N" (a nil core in ApplySched) and is NOT
// an arity error -- there is nothing to check against. Every other policy is
// N-generic and this returns nil for all of them.
func SchedArity(p SchedPolicy, n int) error {
	if n <= 0 {
		return nil
	}
	if p.Name == "eco" && n != 1 {
		return fmt.Errorf(
			"AGG_SCHED=eco with %d sources. REFUSING to start: `eco` IS the single-source "+
				"datapath (one link over the primary, deliver on arrival, no hold, no "+
				"fan-out) and it has no meaning at N=%d -- there is no rule in it for "+
				"choosing among %d sources. This build implements %s; `lightning` is the "+
				"one that uses every source for every frame. Serving eco over %d sources "+
				"would report the box in a mode the wire was not in",
			n, n, n, strings.Join(SchedNames(), "|"), n)
	}
	return nil
}

// Describe is the start-up log line, and it is deliberately the whole policy
// rather than the name: a name in a log proves nothing about what the binary
// then did.
func (p SchedPolicy) Describe() string {
	rank := "drain-order (max; hungriest-first NOT ported -- pull.go S1)"
	if p.Rank == RankDeadlineHit {
		rank = fmt.Sprintf("K4 (-hhat,lastD) one-way-budget=%v rtt-budget=%v",
			SpeedBudgetOneWay, SpeedBudgetRTT)
	}
	del := "in-order ring"
	if p.Delivery == DeliverOnArrival {
		del = "ON ARRIVAL (dedup-only ring, zero wait)"
	}
	hold := "owd.Hold clamp(spread+3*jit+250,150,350) -- NOT the design ratchet, U13 owns that"
	if p.Hold == HoldNone {
		hold = "none (falls out of deliver-on-arrival)"
	}
	fan := "OFF (one shared pool, every frame drawn exactly once)"
	if p.Fanout {
		fan = "ON (per-link pools, one seq each -- every source carries every frame; " +
			"downlink hint pins the single reply copy to AGG_PATHS[0])"
	}
	return fmt.Sprintf("scheduler=%s rank=%s delivery=%s hold=%s fanout=%s",
		p.Name, rank, del, hold, fan)
}

// ---------------------------------------------------------------------------
// The budget -- a REQUIREMENT, and one conversion that is an assumption
// ---------------------------------------------------------------------------

// SpeedBudgetOneWay is the datapath's claim on the conversational latency
// budget: 50 ms of ITU-T G.114's ~150 ms "good" one-way budget, the remaining
// two thirds left for capture/encode/app-buffer/decode/render
// (modes-max-speed-design.md sec 6). It is an APPLICATION REQUIREMENT with a
// stated derivation, not a tuned constant: if the stated fraction changes the
// bars re-derive and nothing in the mechanism moves.
const SpeedBudgetOneWay = 50 * time.Millisecond

// SpeedBudgetRTT is what the daemon can actually MEASURE against, and the factor
// of two is an ASSUMPTION, recorded rather than buried:
//
//	S8  THE DEADLINE IS EVALUATED ON A ROUND TRIP, NOT ON A ONE-WAY DELAY.
//	    hhat needs an ABSOLUTE comparison, and an absolute comparison needs a
//	    delay measured in ONE clock. The client and the server have no clock
//	    sync at all -- every one-way quantity in this daemon (owd.rel, and the
//	    `nowMS()-ts` fold on a data frame) carries an unknown constant offset,
//	    which is fine for a per-path SPREAD (it cancels) and useless against a
//	    fixed budget (it does not). The one quantity this client measures in its
//	    own clock on EVERY path is the ping->reply round trip: BOTH servers echo
//	    the client's own txstamp verbatim -- the E3 thin server in a FlagEcho
//	    (server/echo.go @"header txstamp = the client's ping txstamp, echoed
//	    VERBATIM") and the retained push server in a FlagPong (main.go
//	    @"case FlagPing: // client's ping: fold for the uplink floor + reply
//	    w/ surface"). pullrun.go feeds the Ranker from both, because the push
//	    server is the peer this client actually talks to today. So hhat is
//	    evaluated on that
//	    RTT against 2x the one-way budget, which assumes the two directions are
//	    symmetric. That assumption is NOT measured on this hardware and is not
//	    measured by the model either. E1/G1 is what measures it.
//	    What it costs if it is wrong: hhat's CLIFF sits at the wrong place, so
//	    paths are demoted a little early or a little late. It does not corrupt
//	    the ORDER, because every path is judged against the same budget with the
//	    same conversion.
const SpeedBudgetRTT = 2 * SpeedBudgetOneWay

// ---------------------------------------------------------------------------
// The Ranker -- hhat and lastD, both from the EXISTING ping/echo cadence
// ---------------------------------------------------------------------------

// probe is one outstanding ping, remembered until its echo comes back or it
// matures into a miss.
type probe struct {
	ts   uint32
	sent time.Time
}

// Ranker carries `speed`'s two statistics. Both are fed from the ping/echo
// exchange the control loop ALREADY runs at PingIval, which is what closes the
// model's own flagged gap (design sec 3.6: "the sim has no idle-path probes, so
// a vacated path's lastD/hhat go stale ... the real daemon's existing 100 ms
// ping stream feeds both statistics continuously", with no new constant): a path
// this client has stopped drawing on is still pinged, so it is still ranked and
// can still be re-promoted when it recovers.
//
//	lastD_i  the round trip of the most recent echo on link i, in ms. Event
//	         driven and windowless. It is deliberately NOT a minimum: a min
//	         filter cannot learn that a path got WORSE, which is the measured
//	         refutation that replaced r1's Dmin (design sec 3.6 / sec 9 row 3).
//	hhat_i   the deadline-hit rate over the last epoch: answered-within-budget
//	         divided by pings that have MATURED (answered, or unanswered for
//	         longer than the budget). It fuses loss and latency with ZERO
//	         coefficients -- an unanswered ping is a miss for the same reason a
//	         late one is, and neither needs a weight (design sec 3.6 / sec 9
//	         row 4).
//
// The epoch is the EXISTING LossIval loss-report cadence; the maturity horizon
// is the budget itself. No new cadence and no new constant enters.
//
// EVERY METHOD TOLERATES A NIL RECEIVER, exactly like Cap: `max` constructs no
// Ranker at all, so the calls in the RX and control loops cost one nil check
// and the `max` build behaves as if this file did not exist.
type Ranker struct {
	mu    sync.Mutex
	n     int
	pend  [][]probe
	hit   []int
	miss  []int
	hbar  []float64
	haveH []bool
	lastD []float64
	haveD []bool
	// observability only; nothing in the datapath reads these.
	echoes []uint64
	misses []uint64
}

// NewRanker builds the statistics for n links. n is len(Links) and nothing else.
func NewRanker(n int) *Ranker {
	if n < 0 {
		n = 0
	}
	return &Ranker{
		n:      n,
		pend:   make([][]probe, n),
		hit:    make([]int, n),
		miss:   make([]int, n),
		hbar:   make([]float64, n),
		haveH:  make([]bool, n),
		lastD:  make([]float64, n),
		haveD:  make([]bool, n),
		echoes: make([]uint64, n),
		misses: make([]uint64, n),
	}
}

// N is how many links this Ranker was built for. 0 on a nil Ranker.
func (r *Ranker) N() int {
	if r == nil {
		return 0
	}
	return r.n
}

func (r *Ranker) inRange(i int) bool { return r != nil && i >= 0 && i < r.n }

// Ping records that a probe left on link i carrying txstamp ts. Called from the
// control loop at the same point Cap.MarkPing is, on the same ping.
//
// It also matures, which is what BOUNDS the pending list without a cap: a probe
// older than the budget is resolved as a miss, and probes leave at PingIval, so
// the list holds at most ceil(budget/PingIval)+1 entries per link by
// construction.
func (r *Ranker) Ping(i int, ts uint32, now time.Time) {
	if !r.inRange(i) {
		return
	}
	r.mu.Lock()
	r.matureLocked(now)
	r.pend[i] = append(r.pend[i], probe{ts: ts, sent: now})
	r.mu.Unlock()
}

// Echo resolves a probe. ts is the client's OWN txstamp, echoed back verbatim by
// the server, so now-sent is a round trip measured entirely in this client's
// clock -- no clock sync, no offset (see S8 above for what the budget comparison
// then assumes).
//
// An echo whose ts matches nothing is ignored rather than guessed at: it is a
// duplicate, or a reply to a probe this Ranker already matured.
func (r *Ranker) Echo(i int, ts uint32, now time.Time) {
	if !r.inRange(i) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	q := r.pend[i]
	for k := range q {
		if q[k].ts != ts {
			continue
		}
		d := now.Sub(q[k].sent)
		r.pend[i] = append(q[:k], q[k+1:]...)
		r.lastD[i] = float64(d) / float64(time.Millisecond)
		r.haveD[i] = true
		r.echoes[i]++
		if d <= SpeedBudgetRTT {
			r.hit[i]++
		} else {
			r.miss[i]++
		}
		r.matureLocked(now)
		return
	}
	r.matureLocked(now)
}

// matureLocked resolves every probe outstanding for longer than the budget as a
// MISS. That is the whole of hhat's loss half: a frame that never arrives cannot
// arrive within the budget, so loss needs no separate term and no coefficient.
func (r *Ranker) matureLocked(now time.Time) {
	for i := 0; i < r.n; i++ {
		q := r.pend[i]
		keep := q[:0]
		for k := range q {
			if now.Sub(q[k].sent) > SpeedBudgetRTT {
				r.miss[i]++
				r.misses[i]++
				continue
			}
			keep = append(keep, q[k])
		}
		r.pend[i] = keep
	}
}

// Epoch closes the hit-rate window. Called from the control loop's EXISTING loss
// epoch (LossIval), so no cadence is invented.
//
// A path that resolved nothing this epoch keeps its previous hhat rather than
// reverting to unknown: "no evidence this epoch" is not "no evidence".
func (r *Ranker) Epoch(now time.Time) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.matureLocked(now)
	for i := 0; i < r.n; i++ {
		tot := r.hit[i] + r.miss[i]
		if tot > 0 {
			r.hbar[i] = float64(r.hit[i]) / float64(tot)
			r.haveH[i] = true
		}
		r.hit[i], r.miss[i] = 0, 0
	}
}

// Better reports whether link a is STRICTLY better than link b under K4.
//
// Strictly, and that word is load-bearing three times over:
//
//  1. equal keys mean NEITHER blocks the other, so near-equal paths both draw
//     and the result is striping -- the design's answer to flap (sec 3.4). There
//     is no discrete activation state to oscillate.
//  2. it is what makes the whole ordering invariant under permutation of
//     AGG_PATHS. An index tie-break would decide ties by position, which is a
//     privileged path by another name.
//  3. it is what guarantees SOMETHING always draws -- see the acyclicity
//     argument below, which is a PROOF and not an assertion, because the
//     randomised bar that used to stand in for one missed a real cycle.
//
// A path with no statistics is neither better nor worse than anything. That is
// not a nicety: statistics arrive on the ping/echo stream, which runs whether or
// not a link draws, so an unmeasured link is a link this daemon has only just
// been handed -- and blocking it would be ranking on absence.
//
// WHY hhat GATES THE WHOLE COMPARISON (U17a, a real defect, fixed here)
//
// K4's key is the PAIR (-hhat, lastD): hhat is the primary and lastD is only its
// tie-break. The first cut of this function fell THROUGH to lastD whenever either
// side lacked hhat, which made lastD a PRIMARY key for some pairs and a tie-break
// for others -- and a comparator that judges different pairs on different keys is
// not transitive. It admitted a 3-cycle, on values reachable in normal operation:
//
//	A  hhat=0.5  lastD=20ms   (both statistics)
//	B  hhat=0.0  lastD= 5ms   (both statistics)
//	C  hhat  n/a lastD=10ms   (echoed once, but no Epoch has closed on it yet)
//
//	Better(A,B) -> true   both have hhat, 0.5 > 0.0
//	Better(B,C) -> true   C has no hhat, so lastD decided it: 5 < 10
//	Better(C,A) -> true   C has no hhat, so lastD decided it: 10 < 20
//
// Every one of A, B, C then has something strictly better than it, so rankGate
// blocks ALL THREE and the pool draws NOTHING -- a datapath stall in `speed`, on
// a box with no console. haveD-without-haveH is not synthetic: Echo sets haveD
// immediately, Epoch sets haveH, so every link lives in that state from its first
// echo until the next LossIval -- which is exactly the window a hot-plugged WAN
// is in. It needs three links, so it cannot happen on a 2-source box and can on
// the N=3 client.
//
// The fix is to compare only links that BOTH carry the primary key. Then the
// relation is acyclic, and this is the proof rather than a sample of it:
//
//   - Every true edge a->b has hbar[a] >= hbar[b] (strictly greater, or equal and
//     then decided by lastD). So around any cycle hbar is non-increasing and
//     returns to its start => every hbar on the cycle is EQUAL.
//   - With hbar equal, every edge on the cycle was decided by the second clause,
//     so lastD[a] < lastD[b] strictly for each edge, and lastD around the cycle
//     would have to return to its start. Impossible for a strict order on the
//     reals.
//
// So there are no cycles of any length, and among any set of eligible links at
// least one has nothing strictly better than it. Executed, exhaustively rather
// than at random, by TestRankerBetterIsAcyclicSoSomeLinkAlwaysDraws.
//
// The behavioural cost is the safe direction: a link with lastD but no hhat is
// incomparable, so it neither blocks nor is blocked -- it spills instead of
// stalling, which is what "blocking it would be ranking on absence" already said
// about a link with no statistics at all.
func (r *Ranker) Better(a, b int) bool {
	if r == nil || a == b || !r.inRange(a) || !r.inRange(b) {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	// The primary key gates the comparison. Falling through to lastD when one
	// side has no hhat is what admitted the cycle above.
	if !r.haveH[a] || !r.haveH[b] {
		return false
	}
	if r.hbar[a] != r.hbar[b] {
		return r.hbar[a] > r.hbar[b]
	}
	if r.haveD[a] && r.haveD[b] && r.lastD[a] != r.lastD[b] {
		return r.lastD[a] < r.lastD[b]
	}
	return false
}

// Key exposes one link's statistics for logging and for tests.
func (r *Ranker) Key(i int) (hbar, lastD float64, haveHbar, haveLastD bool) {
	if !r.inRange(i) {
		return 0, 0, false, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.hbar[i], r.lastD[i], r.haveH[i], r.haveD[i]
}

// Stat is the per-link fragment of the PSTAT line. Empty string when there is no
// Ranker, so a `max` run prints exactly what it printed before this unit
// existed.
func (r *Ranker) Stat(i int) string {
	if !r.inRange(i) {
		return ""
	}
	h, d, hh, hd := r.Key(i)
	hs, ds := "n/a", "n/a"
	if hh {
		hs = fmt.Sprintf("%.3f", h)
	}
	if hd {
		ds = fmt.Sprintf("%.1fms", d)
	}
	r.mu.Lock()
	e, m := r.echoes[i], r.misses[i]
	r.mu.Unlock()
	return fmt.Sprintf(" hhat=%s lastD=%s echo=%d late=%d", hs, ds, e, m)
}

// ---------------------------------------------------------------------------
// The gate -- how a rank becomes a draw decision without an admission controller
// ---------------------------------------------------------------------------

// SchedGate is consulted by Drive before it draws. A nil gate means "draw", and
// nil IS `max`: RankDrainOrder installs none, so the `max` draw loop is U7's,
// unmodified, with one nil check in front of it.
type SchedGate interface {
	MayDraw(idx int) bool
}

// rankGate turns K4 into the design's EMERGENT ACTIVATION (sec 3.1) with no
// admission controller and no activation state anywhere:
//
//	a link may draw unless some OTHER ELIGIBLE link is strictly better.
//
// "Eligible" is the link's own already-existing gate state, published by the
// link that owns it and never computed here: alive, not structurally disabled,
// and not currently refused. So a worse-ranked source draws exactly when better
// ones' gates are CLOSED -- which is the whole of `speed`'s spill rule, "latency
// first, and spill over" (sec 4.3b), expressed without a threshold, a watermark
// or a Mbps number. Static priority is what this is NOT: the rank is recomputed
// from live statistics every epoch, and sec 3.2 records that static priority
// (V1/CPF) was measured at -9% goodput at spill and refuted.
type rankGate struct {
	rk    *Ranker
	links []*PullLink
}

// NewRankerFor builds the statistics a policy needs, or nil if it needs none.
// `max` needs none, and nil is what makes every Ranker call in the RX and
// control loops a single branch in that mode.
func NewRankerFor(p SchedPolicy, n int) *Ranker {
	if p.Rank != RankDeadlineHit {
		return nil
	}
	return NewRanker(n)
}

// ApplySched is the ONE place a resolved policy becomes datapath state, and it
// exists as a named function for a reason this repo has already paid for once:
// redline 6 shipped a gate that was logic-correct and WIRED TO NOTHING, and only
// a seeded A/B found it. The policy, the ring, the ranker and the gate are each
// testable on their own; the three lines that CONNECT them were not, because
// runPullClient binds real sockets and no test can call it. So the connection
// is a function, and TestApplySchedWiresBothHalves executes it.
//
// It is total and order-independent: either half may be nil (the server has no
// ring of this kind; a test may pass no core), and calling it twice with the
// same policy is a no-op. It must be called BEFORE PullCore.Start and before the
// first Push -- see SetSched and Ring.SetArrival for why each says so.
// U138 adds the SEND half and the arity refusal. It returns an error rather
// than logging one, so the caller decides what a refusal costs (runPullClient
// makes it fatal, before any goroutine starts); every existing call site keeps
// compiling because a Go call is a legal statement whether or not it returns.
// The check is here as well as in SchedFromEnv because this is the seam a test
// can execute -- SchedFromEnv answers about the ENVIRONMENT, ApplySched answers
// about the CORE it is about to wire, and it is the core that carries N.
func ApplySched(p SchedPolicy, c *PullCore, r *Ring, rk *Ranker) error {
	if c != nil {
		if err := SchedArity(p, c.N()); err != nil {
			return err
		}
		c.SetSched(p, rk)
		// The send half. Nil (shared pool) for every policy but `lightning`, so
		// a core wired by any other mode is the one U7 wrote, and a core wired
		// twice ends in the shape the LAST policy names -- see SetFanout.
		c.SetFanout(p.Fanout)
	}
	if r != nil {
		r.SetArrival(p.Delivery == DeliverOnArrival)
	}
	return nil
}

func (g *rankGate) MayDraw(idx int) bool {
	if g == nil || g.rk == nil {
		return true
	}
	for j := range g.links {
		if j == idx {
			continue
		}
		if !g.links[j].Eligible() {
			continue
		}
		if g.rk.Better(j, idx) {
			return false
		}
	}
	return true
}
