package main

// =============================================================================
// U13 / OBJ-B -- the DERIVED reorder hold, and a MONOTONIC frame stamp.
//
// Everything here is ADDITIVE and reachable only from runPullClient, with ONE
// exception that round 3 had to make and that is stated first because round 2
// claimed the opposite. paths.go, eif.go, estr.go, qtrack2.go, fec.go, frame.go
// and util*.go are byte-identical to dev; runClient/runServer are unchanged.
//
// ring.go IS NO LONGER BYTE-IDENTICAL. Round 2 froze it and called the freeze a
// safety property. It was not: `OnSkip func()` carried no seq, so this file could
// not tell an OnOld for a seq the ring HELD FOR from one for a seq it never held
// for, and the resulting rule learned an 8,213 ms hold on the shipped ring
// geometry (see OnOld, ROUND 3). The freeze was self-imposed, not external -- the
// P4 daemon is not deployed -- so it was removed rather than worked around. The
// change to ring.go is two lines of signature (`OnSkip func(seq uint32)`, and the
// two call sites pass the seq they were already incrementing past) plus a `Mask()`
// accessor. NOTHING in ring.go's behaviour changes: the push client's only OnSkip
// consumer (main.go:130,358) is a counter and ignores the argument.
//
// -----------------------------------------------------------------------------
// 1. WHAT WAS WRONG WITH THE HOLD
// -----------------------------------------------------------------------------
// paths.go:102 (push) and reserved_composite.py:445 (the rig) both compute
//
//     hold = clamp(owd_spread + 3*jitter + K, floor, ceiling)
//
// with K=250ms/floor 150/ceiling 350 in Go and K=130/80/350 in the rig. The owd
// spread and the jitter are MEASURED. The coefficient 3, K, the floor and the
// ceiling are not, and paths.go:102 says K is an "estimator probe-queue
// allowance (covers BigQ band)" -- ADR-002 DELETED the estimator, so on the pull
// datapath that term names a subsystem that no longer exists. The formula is on
// the HANDOFF record (2026-08-29) as owed a derivation.
//
// -----------------------------------------------------------------------------
// 2. THE DERIVATION -- the ring already measures the quantity
// -----------------------------------------------------------------------------
// The hold is the time the in-order frontier must wait for a frame that is late
// but still coming. That does not have to be MODELLED from owd and jitter: it is
// OBSERVED, once per frame the ring discards. When the ring gives up on seq s at
// (blockAt + hold) and s then arrives at t, the hold that WOULD have saved it is
// exactly t - blockAt.
//
//     H := max(H, t_arrival - t_blockStart)
//
// H rises only on direct evidence that it was too small, and on nothing else. No
// rate estimate, no ETA, no argmin, no Smith term -- ADR-002's prohibition is not
// touched: this is a receive-side observation of something that already happened.
//
// BOTH REMAINING BOUNDS ARE ring.go's OWN GEOMETRY, cited rather than invented:
//   * FLOOR -- ring.go:148-153 holdNow() already clamps to >= 10ms. That 10ms has
//     no derivation either. It is INHERITED, not adopted, and it is named here as
//     a surviving arbitrary constant this unit did NOT remove. Round 2 gave the
//     reason as "removing it means editing ring.go, which carries the deployed
//     push client"; round 3 DID edit ring.go, and the P4 daemon is not deployed,
//     so that reason is withdrawn. The real reason is the one that always applied
//     and was never stated: nothing derives a replacement. A floor is a claim
//     about the shortest reorder worth waiting for, and no measurement of that
//     exists.
//   * NO CEILING -- and the round-1 claim that ring.go supplies one is WITHDRAWN.
//     ring.go:139-141 `if seq-next > r.mask { flushTo(seq) }` is a COUNT bound:
//     2048 ARRIVALS ahead of the frontier, not 2048 milliseconds. The time it
//     corresponds to is 2048 / (delivered frame rate), so it tightens as the link
//     gets faster and LOOSENS without limit as the delivered rate falls. It is
//     therefore NOT a substitute for the 350ms ceiling, which bounded TIME. The
//     honest statement is that the derived hold has NO TIME CEILING at all: H is
//     bounded only by the largest lateness actually observed since the last
//     Reset. The effective hold in TIME at low delivered rate is UNMEASURED --
//     the rig scores at a fixed offered load and never sweeps delivered rate down
//     against a fixed window. Recorded as an open question, not closed.
//
// -----------------------------------------------------------------------------
// 3. IT IS COMPUTABLE ON THE FROZEN ring.go, AND THAT WAS NOT OBVIOUS
// -----------------------------------------------------------------------------
// blockAt is ring.go's r.blockAt and is not exported. Three candidate
// observations were MEASURED in the rig (p4-bondagg/sim/pull-study/
// 03-reserved-composite/highn_battery.py, U13 block) before this one was chosen:
//
//   (a) t_arrival - t_skip           -- what OnSkip's timestamp gives directly.
//       Measures the EXCESS over the hold in force, so the ratchet becomes a
//       function of its own output. Measured: H converges to 10-90ms and the
//       result is WORSE than the formula on every cell (N4-het@0.65 late-discard
//       32400 vs the formula's 2749).
//   (b) t_arrival - t_open, where t_open is the arrival of the first frame with a
//       higher seq -- computable from the arrival stream alone, no ring internals.
//       Measured: it UNDER-estimates, because a frame skipped as epoch collateral
//       has a t_open LATER than the epoch head's blockAt. H reaches 78-630ms and
//       it also loses to the formula at moderate load (8004 vs 2749).
//   (c) THIS ONE. OnSkip fires at t_skip = blockAt + holdInForce, and the hold in
//       force is OURS -- we install it. So blockAt = t_skip - holdInForce, exact.
//       Only the most recent epoch's blockAt is remembered, so a frame skipped in
//       an OLDER epoch is measured against a LATER block start and its lateness is
//       UNDER-stated -- this rule can only under-shoot the per-seq truth, never
//       over-shoot. ROUND 3: round 2 quantified that as "byte-identical on 7 of 9
//       (mix, load) cells" with NO artifact, no output file and no run id behind
//       it. That claim is WITHDRAWN. The rig now scores the per-seq variant
//       (highn_battery.PerSeqRatchet) against the shipped one on every cell of
//       every run and PRINTS the comparison as B6-SELF(d), so the size of the
//       approximation is a standing measurement instead of a remembered number.
//
// AND (c) IS ONLY SOUND WITH A SEQ FILTER, which round 2 did not have. An OnOld is
// evidence that the hold was too short ONLY for a seq the ring GAVE UP ON. See the
// ROUND 3 note above OnOld for the defect and the measurement that closed it.
//
// KNOWN ERROR IN (c), and its DIRECTION. blockAt = t_skip - holdInForce is exact
// only if the skip fires the instant the timer expires. ring.go drains on Push
// and on Tick, so a skip actually fires at the first of those AFTER
// blockAt+hold: the reconstructed blockAt is LATE by the drain lag, the measured
// lateness is SHORT by the same amount, and the ratchet therefore UNDER-shoots.
// It never over-shoots, which is the safe direction for a hold that has no
// ceiling. The lag is one inter-arrival time while frames are flowing (every
// Push drains) and at most PingIval = 100ms when the downlink is idle -- and an
// idle downlink has no reorder to measure. Asserted:
// TestRatchetUnderShootsWhenTheDrainIsLate.
//
// -----------------------------------------------------------------------------
// 4. WHAT THE MODEL SAYS IT BUYS, AND WHAT IT DOES NOT SAY
// -----------------------------------------------------------------------------
// CORRECTED IN ROUND 2 AGAINST THE BATTERY'S OWN PRINTED OUTPUT. Round 1 said
// "late-discard falls 2-5x and loss falls 1-3 pt". That is not what the [win]
// rows print. Read off run 33321810038, job 99284976188 (18 cells, SEEDS=6),
// scored with ring.go's REAL 2^11 window -- which is the model that describes the
// daemon:
//   late-discard force/ratchet:  1.00x .. 2.25x   (min 15444/15475 = 0.998x at
//                                N5-het@0.95, where the ratchet is very slightly
//                                WORSE; max 4920/2189 at N3-het@0.85)
//   loss (force - ratchet):      -0.02 .. +3.05 pt (the -0.02 is the same cell)
//   p50:                         within 7ms on every cell
//   p95:                         +0.0% .. +16% for the ratchet (worst 153 -> 177ms
//                                at N3-het@0.65); NOT "within a few ms".
// The 2-5x figure was read off the UNBOUNDED column, which is the rig's model and
// not the daemon's ring. On the UNBOUNDED model the ratchet's p95 is 1.0x-4.0x the
// formula's (412 -> 1654 ms at N5-het@0.95) -- see the divergence note in
// highn_battery.py's U13 block, and U13a.
//
// SO THE HONEST SIZE OF THE BENEFIT IS SMALLER THAN ROUND 1 CLAIMED: on the model
// that describes the shipped ring it is a 1.0x-2.25x reduction in late-discard and
// a -0.02..+3.05 pt reduction in loss, with one cell where it is a wash.
//
// NOT ESTABLISHED, and none of it is claimed here:
//   * UNTESTED: nothing in this file has run on hardware, and runPullClient has
//     never executed anywhere (pathsim.py launches only AGG_MODE=server|client).
//   * The rig has never been compared to a real router (ADR-004's open condition),
//     so its absolute late-discard and latency numbers are unvalidated physics.
//   * Whether a longer hold costs real latency depends on edge-vs-mid, which is
//     G1/E1, and on a LATENCY BUDGET for `max` mode that nobody has specified.
//     This file chooses no budget and asserts none; that is OBJ-D / U14.
//   * B6a REWARDS A LONGER HOLD, AND ROUND 2 DESCRIBED THAT HAZARD WRONGLY.
//     B6a is satisfied by discarding fewer arrived frames, and the cheapest way
//     to do that is to hold longer. Round 2 wrote "as it stands B6 would score a
//     hold of ten seconds as an improvement". MEASURED, that is FALSE and the
//     error was in the safe direction, which is why nobody noticed: a 10 s
//     constant trips the B6-CTRL patient limb (10 s > T = 9.0 s) and the job
//     exits 1. The claim was never checked. What WAS true is worse and was never
//     written down: substituting a CONSTANT hold for the ratchet and sweeping it
//     over 13 values x 18 cells, B6a ALONE passes 164 of 234 substitutions (the
//     per-cell edge is 0.25 s on three cells, 0.35 s on fourteen, 0.50 s on one,
//     and above its edge every cell passes out to 8 s) -- and a demonstrated 3 s
//     constant, with r=0 raises and obs=0 observations, reproduced the clean
//     baseline fail set BYTE-IDENTICALLY at a cost of p95 168 -> 2668 ms.
//     Artifact: p4-bondagg/sim/pull-study/03-reserved-composite/
//     b6c_constant_probe.{py,txt}. With B6c, 0 of the same 234 pass.
//     ROUND 3 CLOSES THE CONSTANT CLASS, and closes it at the derivation rather
//     than by a threshold. B6c gates two things on every cell: the hold must have
//     been RAISED by an observation at least once (a constant raises nothing, so
//     every constant fails, at any length), and it must not exceed the largest
//     lateness the trace ACTUALLY EXHIBITED, measured per-seq by a passive
//     witness that changes no decision in the walk. It PASSES the shipped rule
//     on 18/18 cells, so it is a bar and not a ban on holding. What B6c does NOT
//     do, stated because it is the residual: it does not bound an EVIDENCED hold
//     below that largest observed lateness, which on the cells reaches 2,153 ms. There
//     is still no latency budget on the other side (OBJ-D / U14), and on the
//     UNBOUNDED model the derived hold's p95 is 1.0x-4.0x the formula's
//     (412 -> 1654 ms at N5-het@0.95). OPEN, and now bounded rather than open-ended.
//   * ROUND 2's REASSURANCE WAS FALSIFIED BY MEASUREMENT AND IS WITHDRAWN. It
//     said "the only thing between LatenessRatchet and an unbounded hold is that
//     H rises solely on OBSERVED lateness". Observed lateness alone did NOT bound
//     it: with no seq filter, arrivals the ring never held for were counted as
//     observations and drove H to 8,213 ms on the shipped ring geometry. The
//     bound comes from WHICH observations count, not from the fact that they are
//     observations. That is now enforced (OnOld) and gated (B6c CTRL).
//   * The effective hold in TIME at low delivered rate is UNMEASURED -- see the
//     NO CEILING note in section 2.
//   * The rig models NO Reset at all: highn_battery.py's ratchet only ever
//     ratchets up, while the shipped one re-anchors on every change of the
//     delivering set, which on a spotty-tether box is its DOMINANT behaviour. So
//     every B6 number describes a ratchet the daemon does not have. OPEN.
//
// -----------------------------------------------------------------------------
// 5. THE MONOTONIC STAMP (OBJ-B, decided and not previously implemented)
// -----------------------------------------------------------------------------
// paths.go:13 nowMS() is time.Now().UnixMilli() -- WALL clock. An NTP step moves
// it, and every consumer reads the step as a one-way-delay excursion: the peer's
// OWD sample jumps, the jitter EWMA jumps, and on the push stack the hold jumps
// with it. monoMS() below is time.Since(a process-start anchor), which Go serves
// from the monotonic reading embedded in time.Time and which no clock adjustment
// moves.
//
// Only the PULL path uses it. paths.go keeps the wall clock because it is frozen.
// The consequence is stated exactly, not smoothed over: the pull client's own
// receive-side OWD tracker is pullOWD below and IS monotonic, but the push
// client's OWD (paths.go:57) still reads the wall clock and this unit does not
// change that.
//
// Why swapping the clock is safe for OWD at all: every consumer takes
// int32(now - tsms) in uint32 modular arithmetic and uses only DIFFERENCES
// (spread across paths, jitter as |d - prev|). A constant offset between the two
// clocks cancels exactly in modular subtraction. Asserted, not argued:
// TestMonoStampOffsetCancelsInOwdSpread.
// =============================================================================

import (
	"sync"
	"time"
)

// monoEpoch anchors the pull path's frame stamp. Package init time; the value is
// arbitrary because only differences are ever used (see the header).
var monoEpoch = time.Now()

// monoMS is the pull datapath's frame timestamp: milliseconds since monoEpoch,
// truncated to the wire's 32-bit stamp field (frame.go:38). Immune to wall-clock
// steps, unlike paths.go:13 nowMS().
//
// UNTESTED: no test steps the real system clock -- there is no portable way to do
// that from a unit test. What IS tested is that monoMS never goes backwards, that
// it advances at the same rate as nowMS over a sampled interval
// (TestMonoStampAdvancesLikeWallClock), and that an arbitrary constant offset
// between two stamp sources leaves every OWD difference unchanged
// (TestMonoStampOffsetCancelsInOwdSpread).
func monoMS() uint32 {
	return uint32(time.Since(monoEpoch).Milliseconds() & 0xFFFFFFFF)
}

// stampMS is the seam the tests substitute. Production value is monoMS; nothing
// in the shipped path ever reassigns it.
var stampMS = monoMS

// monoAgeMS maps an instant to milliseconds since monoEpoch. It is the AGE clock
// -- not truncated to the wire's 32 bits, because an age is not a wire field.
//
// WHY IT EXISTS (round-2 blocker B5). time.Now() returns a time.Time that CARRIES
// a monotonic reading, and t2.Sub(t1) uses it, so every consumer that keeps
// time.Time values and subtracts them is already immune to a wall-clock step.
// time.Now().UnixMilli() is the opposite: it DISCARDS the monotonic reading and
// yields a wall-clock number. PullLink.lastRxMs stored one of those and RxAge
// subtracted another, and RxAge feeds SetAlive -> AliveSet -> SameAliveSet ->
// LatenessRatchet.Reset (pullrun.go). So the ratchet's re-anchoring -- the ONLY
// thing that ever lowers the derived hold -- rode the wall clock, in a unit whose
// premise is that it must not. Anchoring both ends on monoEpoch fixes that: the
// stored value and the query both go through Sub, which uses the monotonic
// reading whenever the caller passes a time.Time obtained from time.Now() (every
// in-tree caller does).
//
// STILL UNTESTABLE IN PROCESS: no unit test can step the system clock. What IS
// asserted is the discriminating structural fact -- that the stored value is
// milliseconds since PROCESS START, not milliseconds since the Unix epoch
// (TestRxAgeIsAnchoredOnTheMonotonicEpoch).
func monoAgeMS(t time.Time) int64 { return int64(t.Sub(monoEpoch) / time.Millisecond) }

// -----------------------------------------------------------------------------
// pullOWD -- paths.go's OWD tracker, on the monotonic clock.
// -----------------------------------------------------------------------------
// The EWMA arithmetic is copied from paths.go:56-72 verbatim so the pull path's
// owd/jitter series is the same estimator the push path was validated with. Only
// the clock differs.
//
// INHERITED UNDERIVED CONSTANTS THIS FILE INTRODUCES A SECOND COPY OF, listed
// here because U13's whole premise is that undeclared constants get declared.
// 0.9 and 0.1 are the OWD and jitter EWMA weights, used twice in Sample below;
// they are paths.go:64,71's numbers, copied so the two series are the same
// estimator, and nothing derives 0.9. A second COPY is strictly worse than one,
// and it exists only because nowMS() is called INSIDE paths.go's Sample
// (paths.go:57) and paths.go is frozen, so paths.go itself cannot be reused here.
// 3.0, the +250ms and the 150..350ms clamp are formulaHold below, paths.go:102's
// numbers: same status, copied and not adopted, and now with exactly one consumer
// (divergence S4). RingHoldFloor = 10ms is ring.go:148-153's floor, enforced
// identical by TestRingHoldFloorIsTheRingsOwnFloor. None of these governs the
// DERIVED hold: LatenessRatchet has no coefficient.
//
// This type carries NO Hold() method. That is deliberate: the pull path's reorder
// hold comes from LatenessRatchet, and the only remaining consumer of the
// clamp(spread + 3*jit + 250) formula in the pull client is the SENDER-side pool
// Trim -- which is exactly divergence S4, and keeping the two apart is what makes
// S4 visible instead of hidden behind a shared number (see pullrun.go).
type pullOWD struct {
	mu   sync.Mutex
	rel  []float64
	jit  []float64
	init []bool
}

func newPullOWD(n int) *pullOWD {
	return &pullOWD{rel: make([]float64, n), jit: make([]float64, n), init: make([]bool, n)}
}

// Sample folds one arrival. tsms is the PEER's stamp; the clock offset between
// the two ends is arbitrary and cancels in every quantity read back out.
func (o *pullOWD) Sample(path int, tsms uint32) {
	d := float64(int32(stampMS() - tsms))
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.init[path] {
		o.rel[path] = d
		o.init[path] = true
		return
	}
	prev := o.rel[path]
	o.rel[path] = prev*0.9 + d*0.1
	dev := d - prev
	if dev < 0 {
		dev = -dev
	}
	o.jit[path] = o.jit[path]*0.9 + dev*0.1
}

// SpreadJit returns the cross-path relative-OWD spread and the max jitter over
// the paths that have delivered at least once, and whether any had. Parked paths
// carry no data and never init, so they cannot pin the spread (same rule as
// paths.go:84-86).
func (o *pullOWD) SpreadJit() (spread, jit float64, have bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	lo, hi := 0.0, 0.0
	for p := range o.rel {
		if !o.init[p] {
			continue
		}
		if !have || o.rel[p] < lo {
			lo = o.rel[p]
		}
		if !have || o.rel[p] > hi {
			hi = o.rel[p]
		}
		have = true
		if o.jit[p] > jit {
			jit = o.jit[p]
		}
	}
	return hi - lo, jit, have
}

// formulaHold is paths.go:102's clamp(spread + 3*jit + 250, min, max), recomputed
// on the pull path's monotonic OWD. It is copied, NOT derived, and it keeps every
// invented number paths.go has: the coefficient 3, the +250 whose stated
// justification names the estimator ADR-002 deleted, and both clamp limbs.
//
// It is here for exactly ONE consumer -- the SENDER-side pool residence budget
// (PullFIFO.Trim). That reuse of a RECEIVER reorder spread as sender residence is
// divergence S4, logged by U7 and NOT closed by U13: this unit derives the
// RECEIVER hold, and a sender residence budget is a different physical quantity
// with no derivation available. What U13 does change is that the two are no
// longer THE SAME NUMBER: the ring now runs on LatenessRatchet, so S4 is one
// formula with one consumer instead of one formula silently governing two
// quantities. Narrowed and made structural; still open.
func formulaHold(o *pullOWD, min, max time.Duration) time.Duration {
	spread, jit, have := o.SpreadJit()
	if !have {
		// warm-up: nothing learned yet (paths.go:98-100)
		return max
	}
	h := time.Duration(spread+3*jit+250) * time.Millisecond
	if h < min {
		h = min
	}
	if h > max {
		h = max
	}
	return h
}

// -----------------------------------------------------------------------------
// LatenessRatchet
// -----------------------------------------------------------------------------
// LOCK ORDER, and it is the only concurrency subtlety here. ring.go calls OnSkip
// and OnOld from inside Push/drain/Tick while holding r.mu, so those two methods
// run UNDER the ring lock and must never call back into the Ring. Meanwhile the
// RX goroutines and the control goroutine call Hold() and then ring.SetHold(),
// i.e. r.mu is taken AFTER this mutex is released. Holding this mutex across a
// Ring call would give ring.mu -> ratchet.mu on one side and ratchet.mu ->
// ring.mu on the other, which is AB-BA. Hold() therefore copies under the lock
// and returns; no method here calls anything that can block.
//
// N-GENERIC: nothing in this type is per-path. The reorder hold is a property of
// the delivering SET, not of any member of it, and there is no index, no primary,
// no [2] and no per-path constant anywhere below. Reset() is driven by a change in
// the alive set, which is the observable event that invalidates past observations
// -- not by a window constant.
// Fields, since none of them carries a trailing comment. h is the derived hold,
// the max observed lateness this epoch. inForce is what we last installed on the
// Ring; OnSkip needs it to recover blockAt = t_skip - inForce. blockAt is the
// start of the most recent skip epoch, reconstructed in OnSkip. haveBlk says
// whether blockAt means anything yet. peak is the largest h ever reached across
// resets -- diagnostic, and a G1 input: how much reorder budget a real box
// actually needs.
type LatenessRatchet struct {
	// install orders a whole (read hold, record in force, push to the Ring)
	// sequence against Reset. Round 1 did those three steps under three separate
	// acquisitions from N concurrent RX goroutines, so a goroutine holding a
	// PRE-Reset hold could re-install it after Reset() had cleared it, and the
	// Ring and the ratchet could disagree indefinitely. See InstallOn.
	//
	// LOCK HIERARCHY, and it has no cycle: install > ring.mu > mu. install is
	// never taken while ring.mu or mu is held (OnSkip/OnOld run under ring.mu and
	// take only mu); mu is never held across a call that takes ring.mu.
	install sync.Mutex

	mu      sync.Mutex
	h       time.Duration
	inForce time.Duration
	blockAt time.Time
	haveBlk bool
	raises  uint64
	obs     uint64
	resets  uint64
	skipped uint64
	unheld  uint64
	peak    time.Duration

	// pendSeq/pendOn is the PENDING-SKIP record: which seqs the ring actually
	// gave up on and has not yet seen arrive. It is ring.go's own entry{seq,
	// valid} shape, indexed seq&mask with the ring's OWN mask, so it is O(1),
	// bounded by the ring's geometry, and introduces no constant of its own.
	// See the ROUND 3 note above OnOld for the measurement that made it
	// necessary.
	mask    uint32
	pendSeq []uint32
	pendOn  []bool
}

// NewLatenessRatchet takes the RING'S OWN mask (Ring.Mask()), which sizes the
// pending-skip record. It is not a tunable: a record shorter than the ring would
// forget a skip the ring can still be waiting on, and one longer cannot be
// reached, because ring.go:139-141 flushes anything more than mask ahead of the
// frontier.
func NewLatenessRatchet(mask uint32) *LatenessRatchet {
	n := int(mask) + 1
	return &LatenessRatchet{
		mask:    mask,
		pendSeq: make([]uint32, n),
		pendOn:  make([]bool, n),
	}
}

// SetInForce records the hold actually installed on the Ring. OnSkip needs it to
// recover blockAt = t_skip - holdInForce; without it the observation degrades to
// candidate (a) in the header, which was MEASURED to lose to the formula.
//
// The caller must pass what the RING will use, i.e. after ring.go's own >=10ms
// floor (ring.go:148-153) -- effHoldLocked() below applies exactly that floor so
// the two cannot drift.
//
// SHIPPED CALLERS MUST USE InstallOn INSTEAD. This is left exported for the tests
// that drive the ratchet without a Ring.
func (r *LatenessRatchet) SetInForce(d time.Duration) {
	r.mu.Lock()
	r.inForce = d
	r.mu.Unlock()
}

// InstallOn publishes the derived hold as ONE indivisible step: it records what is
// in force and hands the same value to `set` (Ring.SetHold on the shipped path)
// with `install` held throughout, so no concurrent Reset can be overwritten by a
// goroutine carrying a pre-Reset value, and the Ring can never be left holding a
// hold the ratchet has already discarded. Returns what was installed.
//
// r.mu is released before `set` runs -- see the LOCK HIERARCHY note on the struct.
func (r *LatenessRatchet) InstallOn(set func(time.Duration)) time.Duration {
	r.install.Lock()
	defer r.install.Unlock()
	r.mu.Lock()
	h := r.h
	r.inForce = h
	r.mu.Unlock()
	if set != nil {
		set(h)
	}
	return h
}

// EffHold is the hold the RING will actually apply for the value currently in
// force -- i.e. after ring.go:148-153's own floor. It is what a receiver-side
// late-attribution consumer must use: the raw Hold() is 0 until the first OnOld,
// and a 0 horizon makes such a consumer attribute immediately and over-report.
func (r *LatenessRatchet) EffHold() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.effHoldLocked()
}

// OnSkip is wired to Ring.OnSkip. It fires once per skipped seq, all within one
// drain pass at one instant, so repeated calls inside an epoch are idempotent as
// far as blockAt is concerned -- but each call now also RECORDS ITS SEQ, which is
// what makes OnOld's observation attributable (see OnOld).
//
// Called UNDER ring.mu -- see the LOCK ORDER note. Does not call into the Ring.
func (r *LatenessRatchet) OnSkip(seq uint32, now time.Time) {
	r.mu.Lock()
	r.blockAt = now.Add(-r.effHoldLocked())
	r.haveBlk = true
	r.skipped++
	if r.pendOn != nil {
		i := seq & r.mask
		r.pendSeq[i] = seq
		r.pendOn[i] = true
	}
	r.mu.Unlock()
}

// wasSkipped reports whether the ring GAVE UP on this seq, and consumes the
// record so one skip yields at most one observation. Caller holds r.mu.
func (r *LatenessRatchet) wasSkipped(seq uint32) bool {
	if r.pendOn == nil {
		return false
	}
	i := seq & r.mask
	if !r.pendOn[i] || r.pendSeq[i] != seq {
		return false
	}
	r.pendOn[i] = false
	return true
}

// OnOld is wired to Ring.OnOld: a frame ARRIVED after the ring had already passed
// its seq. That is evidence the hold was too short ONLY IF the ring passed that
// seq by GIVING UP ON IT -- i.e. only if the seq was skipped. Hence the filter.
//
// ROUND 3, AND THIS IS A CORRECTED DEFECT, NOT A REFINEMENT. Round 2 had no
// filter, because ring.go's OnSkip carried no seq: every arrival below the
// frontier raised H, including seqs the ring never held for. ring.go:139-141
// flushTo advances next past missing seqs on a WINDOW OVERFLOW without skipping
// them -- a COUNT bound, which no hold could have covered -- and duplicates of
// already-delivered seqs arrive below the frontier too. Both were being read as
// "the hold should have been t - blockAt", against a blockAt from an unrelated
// epoch. MEASURED on the rig, scored with ring.go's real 2^11 window (the only
// model in which the two rules differ at all, and the one that describes this
// daemon): the unfiltered rule learns 8,213 ms at N5-het@0.95 where the filtered
// rule learns 525 ms (15.66x), and 8,170 vs 679 ms at N4-teth@0.95 (12.03x); the
// per-cell table is b6c_constant_probe.txt. That is a runaway with no ceiling and
// it was in the shipped file. It shows on 15 of 18 cells; the other three never
// overflow the 2^11 window, so there is no flushTo and the two rules are the same
// run. The unfiltered rule is kept in the
// rig as UnfilteredOldRatchet and B6c FAILS on it on every run, so the filter
// cannot be removed silently.
//
// Called UNDER ring.mu -- see the LOCK ORDER note. Does not call into the Ring.
func (r *LatenessRatchet) OnOld(seq uint32, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.wasSkipped(seq) {
		// The ring passed this seq without ever holding for it (window flush), or
		// it duplicates one already delivered, or its skip was already observed.
		// There is no block interval it can be measured against.
		r.unheld++
		return
	}
	if !r.haveBlk {
		// No skip epoch seen yet, so there is no blockAt to measure against and
		// no number that could be derived. Count nothing rather than guess.
		return
	}
	r.obs++
	d := now.Sub(r.blockAt)
	if d > r.h {
		r.h = d
		r.raises++
		if d > r.peak {
			r.peak = d
		}
	}
}

// Hold is the derived reorder horizon. Zero until the first observation, which is
// correct and is the whole shape of the thing: it holds for nothing until
// something is measured, and ring.go's own floor (:148-153) is what the Ring
// actually applies in the meantime. The learning cost -- extra discards before
// the first raises -- is real and is included in every B6 measurement.
func (r *LatenessRatchet) Hold() time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.h
}

// Reset drops the learned hold. The cross-path arrival spread is a property of
// the delivering SET, so when that set changes the past observations describe a
// different system and a monotone max would carry the old one forward forever.
// This is the observable event the HANDOFF asks for ("re-anchor on observable
// events, not a window constant") and it is the ONLY thing that lowers H: there
// is no decay here, because no derivation for a decay rate exists and inventing
// one is the thing this unit is closing.
//
// CONSEQUENCE, stated because it is a real cost: within an epoch a single
// pathological reorder pins H for the rest of that epoch.
// The `install` argument is the SAME setter InstallOn takes (Ring.SetHold on the
// shipped path). Reset pushes the cleared hold straight through it under the
// install lock, so the Ring is re-anchored in the same indivisible step rather
// than at the next arrival -- and a racing InstallOn cannot slip the old value
// back in behind it. Tests that drive the ratchet without a Ring pass nil.
func (r *LatenessRatchet) Reset(install func(time.Duration)) {
	r.install.Lock()
	defer r.install.Unlock()
	r.mu.Lock()
	r.h = 0
	r.inForce = 0
	r.haveBlk = false
	r.resets++
	// The pending skips belong to the old delivering set as much as blockAt does;
	// leaving them would let a pre-Reset skip be observed against a post-Reset
	// blockAt. Clearing is O(ring), once per alive-set change, off the RX path.
	for i := range r.pendOn {
		r.pendOn[i] = false
	}
	r.mu.Unlock()
	if install != nil {
		install(0)
	}
}

// Stats: h, peak, raises, observations, resets. Diagnostics + a G1/E1 input --
// "how much reorder budget does this box actually need" is a measurement nobody
// has from hardware.
func (r *LatenessRatchet) Stats() (h, peak time.Duration, raises, obs, resets uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.h, r.peak, r.raises, r.obs, r.resets
}

// Filtered reports how many seqs the ring GAVE UP on, and how many OnOld arrivals
// were rejected as un-held (window flush, duplicate, or a seq already observed).
// unheld is the size of the round-2 defect ON THIS BOX: every one of those used to
// raise H. Diagnostic, and the number a hardware run should print before anyone
// trusts the rig's version of it.
func (r *LatenessRatchet) Filtered() (skipped, unheld uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.skipped, r.unheld
}

// effHoldLocked mirrors ring.go:148-153 holdNow(). Caller holds r.mu.
func (r *LatenessRatchet) effHoldLocked() time.Duration {
	if r.inForce < RingHoldFloor {
		return RingHoldFloor
	}
	return r.inForce
}

// RingHoldFloor is ring.go:148-153's own floor, restated here so OnSkip recovers
// the same blockAt the Ring used. INHERITED AND UNDERIVED -- it is not adopted as
// a derivation, it is copied. Round 1 claimed the copy meant "the two cannot
// disagree" with nothing enforcing it; TestRingHoldFloorIsTheRingsOwnFloor now
// drives a real Ring across the constant and asserts holdNow() and effHoldLocked()
// agree at every point, so the claim is checked rather than asserted. It stays
// because nothing derives a replacement -- NOT because ring.go cannot be edited;
// round 3 edited it. See the FLOOR note in section 2.
const RingHoldFloor = 10 * time.Millisecond

// AliveSet snapshots which links are alive, so a CHANGE can be detected without
// assuming anything about N or about which index means what. Returned as a plain
// bool slice; callers compare with SameAliveSet.
func AliveSet(c *PullCore) []bool {
	out := make([]bool, len(c.Links))
	for i := range c.Links {
		out[i] = c.Links[i].Alive()
	}
	return out
}

// SameAliveSet reports whether two snapshots describe the same delivering set. A
// length change counts as a change.
func SameAliveSet(a, b []bool) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
