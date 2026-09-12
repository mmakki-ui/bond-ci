#!/usr/bin/env python3
# =============================================================================
# highn_battery.py -- HIGH-N (N=4, N=5) as a SCORED case, not a smoke test.
#
# WHY: bonding exists for the regime where required throughput EXCEEDS what the
# present sources supply -- and the answer to that is MORE SOURCES.  So high-N is
# the MOTIVATING regime, yet the study's evidence was N=2 / N=3 heavy, N=4 had
# ONE scenario, and N=5 existed only as an assert-nothing "ran without error"
# smoke test (myslice_baseline.py).  The client box already declares FOUR WAN
# interfaces (docs/INTENT.md), so N=4 is CURRENT HARDWARE, not a growth scenario.
#
# WHAT: the settled composite (reserved_composite.SimD sched='Dc') scored against
# the SAME paired references the N=2 headline used (ackclock_sim.Sim 'ewma' = the
# shipped one-sided delivered-rate cap, 'pull' = uncapped work-conserving, 'Dpp' =
# the uncapped-native predecessor), on heterogeneous N=4 / N=5 mixes, with REAL
# PASS BARS.
#
# PHYSICS: nsched_model.py imported UNMODIFIED (two levels up), exactly as every
# other script in this study.  Rigs/archetypes are reserved_composite's own
# builders -- NO new archetype and NO new numeric knob is introduced by this file.
#
# ---------------------------------------------------------------------------
# BARS -- every bar is either the EXISTING composite bar shape (adv_verify_dc.py)
# or a relation to a PAIRED reference run.  Nothing is picked here.
#
#   B1  NO-COLLAPSE (gp)   : Dc gp >= 0.99 * ewma gp            [loads .85/.95]
#         shape verbatim from adv_verify_dc.py -- the composite must not collapse
#         versus the shipped cap it is built out of.
#   B2  LOSS-PARITY        : Dc loss <= ewma loss + 0.5 pt      [loads .85/.95]
#         shape verbatim from adv_verify_dc.py.  KNOWN HONEST FAIL AT N=2
#         (adv_verify_dc.out: +0.845 pt @0.85, +0.655 pt @0.95, 24/24 seeds).
#         Inherited UNWEAKENED so the high-N rows are comparable to that record.
#   B3  SPARE-LOAD WIN     : Dc gp >= ewma gp AND Dc loss <= ORACLE loss  [load .65]
#         (a) gp half: shape verbatim from adv_verify_dc.py.  UNCHANGED.
#         (b) loss half: the absolute 'Dc loss <= 2%' constant is RETIRED here and
#             replaced by a PAIRED relation to a reference run.  See the U11 block
#             below for the measurement that justified it and the honest record of
#             what the old constant did.
#
# --- U11: WHY B3's ABSOLUTE HALF WAS RETIRED (evidence: coverage_oracle.txt) ---
# highn.txt recorded 'Dc loss <= 2%' failing at EVERY N>=3 (3.07..5.39%).  Fable's
# review called that a mis-derived bar but made the call PROVISIONAL on measuring
# the residual.  coverage_oracle.py ran both halves of that discriminating
# experiment, 24 paired seeds, six mixes, load 0.65:
#
#  (a) ORACLE-PAIRED COVERAGE  (loss_pull-loss_X)/(loss_pull-loss_oracle):
#      Dc = 1.220 (N2) 1.094 (N3) 1.115 (N4) 1.199 (N5) 1.050 (N4-teth) 1.112 (N5-corr).
#      NOT falling with N -- N5 (1.199) is level with N2 (1.220) and both exceed N3.
#      The variation tracks SPOTTY FRACTION, not N.  Fable's 'mechanism is leaking
#      coverable loss as N grows' branch is REFUTED.
#  (b) SHED-VS-LATE DECOMPOSITION of Dc's own 0.65 loss (instrument self-checked
#      against the simulator's own `late` counter, 0/144 runs disagreeing):
#        copies shed while a steady host's meter was still open  = 0, ALL SIX MIXES.
#        copies shed with every steady meter latched             = 0% on the four
#          chain mixes, 11.1% (N4-teth) / 15.9% (N5-corr) -- capacity arithmetic,
#          exactly the intent-consistent case.
#      So the duplication gate has NO fault.  What DOES dominate is Fable's (ii):
#        78-96% of every lost frame ARRIVED and was then discarded by the reorder
#        ring as late.  This is NOT specific to Dc -- it is 50-62% for pull and
#        95-97% for the ORACLE.  The oracle's own residual loss at 0.65 is
#        4.11-6.08% at N>=3 and is almost entirely ring discard.
#
# FABLE'S EXACT SHAPE WAS TRIED AND REJECTED.  'coverage >= coverage(N=2) - eps',
#   with eps pre-registered as the reference cell's own per-seed spread (median-min
#   = 0.0129 over 24 seeds), FAILS Dc on 5/6 mixes -- it is STRICTER than the bar it
#   was meant to correct.  The reason is structural, not numeric: coverage(N=2) is
#   not an intent boundary, it is just another measurement, and it inherits N=2's
#   mix-specific advantage (one spotty source, abundant steady slack).  That shape
#   turns MIX HETEROGENEITY into a fake leak signal.  Widening eps until Dc passed
#   would have derived it from the failing observation -- gaming, condition 1.  The
#   oracle relation below has a real boundary at 1.0 and needs no epsilon at all.
#
# CONSEQUENCE, and the four-condition test (fable-highn-review.md):
#   1. DERIVATION SOURCE -- 'Dc loss <= oracle loss' is a relation to a PAIRED
#      reference run, which is this file's own stated bar rule (see the header
#      above: "either the EXISTING composite bar shape or a relation to a PAIRED
#      reference run.  Nothing is picked here").  B3's loss half was the ONLY bar
#      in this file that broke that rule.  Nothing is derived from the 3.07/5.39
#      numbers that failed.  DISCLOSED: coverage>1 was observed before 1.0 was
#      adopted as the boundary; the defence is that 1.0 is the ONE structural point
#      on that scale (the reference relation itself), not a level fitted to Dc --
#      a fitted threshold would have been 1.04, and epsilon-padding it would be.
#   2. PRE-REGISTRATION -- the rule it restores predates this battery, in this
#      file's own header and in the project's no-arbitrary-constants guardrail.
#   3. FALSIFIABILITY -- validated against mechanism-removed controls on the same
#      evidence: it FAILS ewma (no duplication) on 6/6 mixes and Dpp (no native
#      cap) on 2/6 (N3 0.711, N4-teth 0.735).  It is not theatre.
#   4. THE RECORD SURVIVES -- the old constant's five failures stay written in
#      highn.txt, and this run still PRINTS Dc's absolute 0.65 loss beside the
#      oracle floor so the retired constant's number remains visible.
#
# WHAT THIS BAR DOES NOT COVER (named, not hidden): the reorder-hold geometry.
#   The ring discard above is common-mode -- it sits in both sides of the new
#   relation and so cancels out of it.  B3's 2% was accidentally the only bar in
#   the battery that saw it, and it is NOT replaced in that role: it needs its own
#   bar, against the derived hold (ROADMAP U13 / OBJ-B).  Recorded as an open
#   question, not silently absorbed.
#   B4a NO-EVICTION-SPIRAL : spotty-class native share(Dc) <= share(pull)
#         PAIRED, constant-free.  pull is the UNCAPPED baseline in which the
#         eviction spiral (spotty native share 23%->58%) was observed; the
#         composite exists to cap exactly that, so it must never be worse than
#         pull.  Generalised N-generically:
#             share = sum(assigned[i] for i in spotty-class) / sum(assigned)
#         At N=2 with cellA at index 0 this IS the recorded 'tshare' metric, so
#         the N=2 row stays comparable to adv_verify_dc.out.
#   B4b NO-WALK            : the within-run spotty-share timeline (independent
#         truncated-T reconstruction, same method as adv_verify_dc.py) must not
#         be monotonically non-decreasing across all checkpoints.
#   B5  SCALING (high-N specific, DERIVED from the motivating requirement)
#         On a NESTED chain N2 c N3 c N4-het c N5-het, offered the SAME ABSOLUTE
#         rate, so the small configs are genuinely over-subscribed -- the
#         motivating regime -- each added source must BUY something:
#             gp strictly increases   AND   loss strictly decreases.
#         The offer is derived from the rig's own nominal aggregate; no constant.
#
#         U12 -- TWO offers, because ONE was not a test of the last step.  At
#         0.85 x nominal(N5-het) = 162,350 the N=5 step is UNDER-STRESSED by its
#         own admission: N4-het's nominal aggregate is already 174,000, so N4 is
#         not over-subscribed at all and N=5 buys only +1,277 gp (highn.txt:159).
#         The second chain is offered LOADS[-1] x nominal(N5-het) ~= 181,450 --
#         ABOVE N4-het's nominal, so N4 genuinely cannot carry it and the N=5 step
#         is a real capacity test.  No new constant: the multipliers are LOADS[1]
#         and LOADS[-1], the same load fractions the main table already uses.
#
#   B6  HOLD GEOMETRY (U13 / OBJ-B) -- the bar the block above says is owed.
#         Three limbs, all scored by RE-RELEASING one already-finished Dc run's
#         delivery trace under a different hold.  No extra simulation, no new
#         constant, and the reference is a run, not a number.  Full derivation
#         and the honest fails in the U13 block below.
#
# HONEST-FAIL POLICY: bars are reported as measured.  Nothing here tunes the
# scheduler, and no bar is weakened to go green.
# ---------------------------------------------------------------------------
# Env: SEEDS (default 24), WORKERS (default 14), T (default 9.0), RIG (default
# 'mid' -- the meter-free blind spot, the hard case, as adv_verify_dc used).
# =============================================================================
import os, sys, time
from concurrent.futures import ProcessPoolExecutor

import nsched_model as M
import reserved_composite as RC
import ackclock_sim as A

SEEDS = int(os.environ.get('SEEDS', '24'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T = float(os.environ.get('T', '9.0'))
RIG = os.environ.get('RIG', 'mid')
LOADS = [0.65, 0.85, 0.95]
SCHEDS = ['Dc', 'ewma', 'pull', 'Dpp']
# B3's loss reference.  Run ONLY at B3's load so the main table stays byte-
# comparable with the highn.txt record; 'oracle' = ackclock_sim.Sim admitting on
# the TRUE instantaneous stage-2 cap (the physics-derived floor for admission
# control).  See the U11 block in the header.
B3_REF = 'oracle'
B3_LOAD = 0.65

# timeline (B4b) -- same checkpoints + seed count as adv_verify_dc.py
CK = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]
TL_SEEDS = 12
TL_SCHEDS = ['Dc', 'ewma']

# =============================================================================
# U13 / OBJ-B -- B6 HOLD GEOMETRY.  The bar the U11 block above says is owed.
# =============================================================================
# THE PROBLEM U11 LEFT.  78-96% of every frame Dc loses at load 0.65 ARRIVED and
# was then discarded by the reorder ring as late (coverage_oracle.txt PART B2).
# The oracle's own residual is 95-97% late-discard.  Because it is COMMON-MODE it
# cancels out of every paired and every relative bar in this file, so after U11 no
# bar anywhere moves when the hold geometry moves.  B3's retired absolute 2% was
# accidentally the only thing that flagged it.
#
# THE HOLD IN FORCE, and what is invented in it.  Both rigs compute
#     hold = clamp((max(owd)-min(owd)) + 3*max(jit) + 130ms, 80ms, 350ms)
# (reserved_composite.py:445, ackclock_sim.py:566-567; the Go daemon's shipped
# counterpart is paths.go:102 with +250ms and clamp 150..350).  Two terms are
# MEASURED -- the cross-path owd spread and the jitter.  Four numbers are not:
# the coefficient 3, the +130 (+250 in Go), the floor and the ceiling.  Go's own
# comment says the additive term is an "estimator probe-queue allowance (covers
# BigQ band)" -- ADR-002 DELETED the estimator, so on the pull datapath that term
# names a subsystem that no longer exists.
#
# THE DERIVATION.  The hold is the time the in-order frontier must wait for a
# frame that is late but still coming.  That quantity does not have to be modelled
# from owd and jitter: the RING ITSELF MEASURES IT, once per discarded frame.
# When the ring gives up on seq s at (block_start + hold) and s then arrives at t,
# the hold that WOULD have saved it is exactly `t - block_start`.  That is an
# observation, not a prediction; it needs no rate estimate, no ETA and no argmin
# (ADR-002's standing prohibition).  So:
#
#     LATENESS RATCHET:  H := max(H, t_arrival - t_block_start), over frames the
#     ring actually discarded.  H rises ONLY on direct evidence that it was too
#     small, and on nothing else.  No coefficient, no floor, no ceiling.
#
# The two remaining bounds are NOT new constants -- they are ring.go's existing
# geometry, cited here rather than re-invented:
#   * FLOOR: ring.go:147-150 `holdNow()` already clamps to >= 10ms.  That 10ms has
#     no derivation either.  It is INHERITED, not adopted, and named here as a
#     surviving arbitrary constant this unit did not remove (ring.go is frozen --
#     it carries the deployed EIF push client).
#   * NO CEILING, and the round-1 claim that ring.go supplies one is WITHDRAWN.
#     ring.go:138-139 `if seq-next > r.mask { flushTo(seq) }` is a COUNT bound:
#     2048 ARRIVALS ahead of the frontier, not 2048 milliseconds.  The TIME it
#     corresponds to is 2048 / (delivered frame rate) -- it tightens as the link
#     speeds up and LOOSENS without limit as the delivered rate falls, so it is not
#     a substitute for the 350ms ceiling, which bounded TIME.  The honest statement
#     is that the derived hold has NO TIME CEILING: H is bounded only by the largest
#     lateness observed since the last reset.  The effective hold in TIME at low
#     delivered rate is UNMEASURED -- every cell here runs at a fixed offered load
#     and nothing sweeps delivered rate down against a fixed window.  Open, not
#     closed.
#
# MEASURED DIVERGENCE, and it matters for anything read off this rig about hold
# LENGTH: `nsched_model.reorder_release` models an INFINITE ring (`present` is an
# unbounded dict) while `ring.go` has a 2^11 window (pullrun.go:228
# `NewRing(11, ...)`).  MEASURED on run 33321810038 job 99284976188, 18 cells,
# SEEDS=6: on the UNBOUNDED model the ratchet's p95 is 1.0x-4.0x the formula's
# (N4-het@0.95 444 -> 1386 ms, N5-het@0.95 412 -> 1654 ms); on the WINDOWED model
# it is +0.0% to +16% (N4-het@0.95 416 -> 416 ms, worst 153 -> 177 ms at
# N3-het@0.65).  So the rig OVERSTATES the latency cost of a longer hold, and the
# windowed cost is NOT "within a few ms" either.  Both are printed below.  The
# GATED limbs use the UNBOUNDED model only -- that is the validated instrument
# (ADR-004); the windowed column is reported as evidence for the Go port, not
# gated.  U13a.
#
# B6a REWARDS A LONGER HOLD, AND ROUND 2 STATED THAT HAZARD WRONGLY.  B6a is
# satisfied by discarding fewer arrived frames, and the cheapest way to do that is
# to hold longer.  Round 2 wrote "B6 as it stands would score a hold of 10 seconds
# as an improvement".  MEASURED, that is FALSE, and it was wrong in the SAFE
# direction, which is why it went unnoticed: a 10 s constant trips the B6-CTRL
# patient limb (10 s > T = 9.0 s, so `subst B6a force := patient(T)` stops failing)
# and the job exits 1.  The claim was written, not checked.
#
# WHAT WAS ACTUALLY TRUE IS WORSE AND NOBODY HAD BOUNDED IT.  Substituting a
# CONSTANT hold for the ratchet and sweeping the constant over
# {0.02,0.08,0.15,0.25,0.35,0.5,0.75,1,1.5,2,3,5,8} s on all 18 cells --
# b6c_constant_probe.py, output b6c_constant_probe.txt, SEEDS=3 -- B6a ALONE
# passes 164 of the 234 substitutions.  The blind-spot EDGE, per cell, is 0.25 s
# on three cells, 0.35 s on fourteen and 0.50 s on one; above its edge every cell
# passes for every larger constant tested, out to 8 s.  A 3 s constant makes r=0
# raises and obs=0 observations, reproduces the clean baseline fail set byte for
# byte, and costs p50 88 -> 438 ms / p95 168 -> 2668 ms at N4-teth@0.85 (worst
# printed row: p95 96 -> 2648 ms at N4-teth@0.65) -- none of which B6a can see.
# WITH B6c: 0 of the same 234 substitutions pass.
#
# SO ROUND 3 ADDS B6c, AND IT GATES THE DERIVATION RATHER THAN A THRESHOLD:
#   (c1) the derived hold must have been RAISED by an observation at least once.
#        A constant raises nothing, so EVERY constant fails c1 at every length --
#        the whole class goes, not a range of it.
#   (c2) the derived hold must not exceed the largest lateness THE TRACE ACTUALLY
#        EXHIBITED, measured per-seq by `LatenessWitness`, a passive observer that
#        changes no decision in the walk (asserted inert, B6-SELF(e)).
# Both are gated on all 18 cells and both are demonstrated by substitution, not
# asserted: `subst B6c ratchet := clamp350 / clamp80 / patient(T) / UNFILTERED`.
# And B6c PASSES what ships on 18/18 cells, with the derived hold sitting EXACTLY
# at the largest lateness the trace exhibited (346-2153 ms) -- it is a bar, not a
# ban on holding.
#
# WHAT B6c DOES NOT DO, because that is the residual and it should be read: it
# does not bound an EVIDENCED hold below the largest observed lateness, which on
# these cells reaches 2,153 ms.  There is still no latency budget on the other side
# (OBJ-D / U14) and on the UNBOUNDED model the derived hold's p95 is 1.0x-4.0x the
# formula's.  OPEN -- bounded now, not open-ended.
#
# THE BAR.  Three limbs, each re-releasing ONE already-finished Dc run's own
# delivery trace under a different hold policy.  Same seeds, same physics, same
# arrivals -- only the hold differs, which is the one dimension every other bar in
# this file cancels.
#
#   B6-SELF  INSTRUMENT IDENTITY (hard, never baselineable).  Re-scoring the
#            trace at the rig's OWN hold with the walk below must reproduce the
#            rig's OWN reported loss and late-discard EXACTLY.  This is what makes
#            the other two limbs readable, and it is also the tripwire ROADMAP's
#            sequencing constraint asks for: any edit to
#            `nsched_model.reorder_release` or to `reserved_composite.py:445`
#            breaks it loudly instead of silently shifting both sides of a paired
#            bar.  Zero tolerance, no epsilon.
#   -------------------------------------------------------------------------
#   ROUND 2: BOTH BARS RE-DERIVED, BECAUSE THE ROUND-1 PAIR WAS NOT A GATE.
#   -------------------------------------------------------------------------
#   THE MEASUREMENT THAT FORCED IT.  Round 1's B6b was `late(hold in force) <
#   late(ring's 10ms floor)`.  Sweeping the hold in force over
#   {0,10,20,30,40,60,80,100,130,175,250,350,500} ms on ALL 18 cells x 6 seeds
#   (1404 re-releases) shows it flips between 10ms and 20ms and prints PASS on
#   18/18 cells for EVERY value from 20ms up.  The shipped clamp is [80,350]ms, so
#   every shortening a real regression could produce -- 4.0x (80->20) to 17.5x
#   (350->20) -- was invisible; in late-discard terms the bar carried 10.3x-29.0x
#   of slack (min N3-het@0.95 55332/5385, max N2-het@0.65 13169/454).  A bar that
#   cannot see the regression it exists to catch is not a gate.  The sweep is hold_sweep_b2.py in this directory; its output is
#   hold_sweep_b2.txt.
#
#   Round 1's B6a was `late(hold in force) <= late(ratchet)`, which FAILED 18/18
#   and was carried as 18 MUST_FAIL pins in rig_paired_gate.py.  An expected-fail
#   pin only fires when it STOPS failing; as a positive assertion the same
#   measurement is strictly stronger and needs no pin list at all.  So B6a is
#   turned around.
#
#   B6a      THE DERIVED HOLD MUST STRICTLY BEAT THE HOLD IN FORCE (paired,
#            boundary 0, STRICT).   med(late(ratchet) - late(hold in force)) < 0.
#            The reference is the HOLD IN FORCE, recomputed per cell from that
#            cell's own owd/jitter -- so unlike a fixed floor it TRACKS the physics
#            of each cell and sits inside the realistic range.  Measured tolerance
#            on the canonical geometry: tightest GATED cell 1.82x (N3-het@0.65,
#            2133 vs 1104), loosest 4.23x; the ungated N2-het@0.65 is 1.17x.
#
#   B6b      THE HOLD MUST BEAT THE SHORTEST HOLD ITS OWN FORMULA CAN EMIT
#            (paired, boundary 0, STRICT).
#            med(late(hold in force) - late(the formula's own clamp floor)) < 0.
#            The reference moved from ring.go's 10ms floor to
#            reserved_composite.py:445's OWN clamp floor, 80ms -- a value the
#            formula itself can produce, inside the realistic range, cited rather
#            than invented.  It now flips as soon as the hold in force reaches its
#            own clamp floor instead of only below 20ms, and the late-discard slack
#            falls from 10.3x-29.0x to 3.07x-8.37x (measured, 18 cells, SEEDS=6).
#            It keeps the common-mode teeth the 10ms reference had: if
#            reorder_release stops holding, BOTH sides become the same run, the
#            paired median is exactly 0, and STRICT `< 0` fails.  Written `<=` it
#            would pass in exactly that case -- measured in round 1, and the
#            strictness is kept for the same reason.
#
#   NAMED NON-COVERAGE, MEASURED NOT ASSUMED.  B6a gates 17 of the 18 cells.
#   N2-het@0.65 is REPORTED AND NOT GATED: its canonical margin is 65 frames on
#   454, and re-running that mix over 48 count- and duration-preserving stall-phase
#   rotations (rig_checks.phase_drops, U33's corrected randomiser) x 6 seeds x 3
#   loads = 864 runs gives med(ratchet - force) in [-192.5, +56.0] with 10/48
#   rotations of the WRONG SIGN at load 0.65.  So that cell's verdict is decided by
#   the hand-placed stall geometry, not by the hold -- exactly the class U33 warned
#   about.  The same sweep gives 0/48 violations at loads 0.85 and 0.95 (worst
#   margin -1096) and 0/48 for B6b at all three loads (worst -3301), so the rest of
#   the N2 mix IS geometry-established.  The next-smallest gated margin is +1007
#   (N3-het@0.65), an order above the +-192 excursion measured at N=2 scale.  The
#   excluded cell is one explicit entry (B6A_UNESTABLISHED) printed on every run,
#   so it cannot silently grow.  Reproduce with b4_geometry_estab.py.
#
#   B6-CTRL  FALSIFIABILITY CONTROL, run every time, EIGHT limbs after round 3,
#            and NONE of them compares a vector with itself.  Round 1's `force :=
#            ratchet` limb evaluated med(r_late - r_late) <= 0 and its `force :=
#            floor` limb evaluated not(med(z_late - z_late) < 0): both are
#            tautologies that cannot fail, so half the control was theatre.  Each
#            limb now substitutes a DIFFERENT RUN:
#              B6a, force := patient hold (T, so nothing that arrives is ever
#                   discarded)                       -> must FAIL   (satisfiable:
#                   the ratchet cannot beat a hold that discards nothing)
#              B6a, ratchet := the t_skip observation (candidate (a) in the
#                   derivation -- the defect a careless edit to hold.go OnSkip
#                   produces, dropping the `- holdInForce` term).  TWO assertions,
#                   because the measurement does not support one blanket claim:
#                     (i) 18/18 the defect is STRICTLY WORSE than the correct
#                         observation -- measured 1.9x to 7.6x more late-discard.
#                    (ii) >=1 cell where substituting it turns B6a RED, i.e. the
#                         gate exits 1.  MEASURED IN ROUND 3: 17 of the 17 gated
#                         cells.  Round 2 measured 7, and the number moved for a
#                         reason worth recording rather than quietly restating:
#                         SkipTimeRatchet inherits LatenessRatchet, so making the
#                         model the SHIPPED rule (one blockAt, not per-seq) also
#                         made the defect measure against the most recent epoch,
#                         which shrinks its H further and costs it the cells where
#                         it used to stay green at loads 0.85/0.95.  The limb is
#                         still asserted as >=1, not as 17: the assertion is that
#                         the bar SEES the defect, and pinning a count would break
#                         on any legitimate change.        (RED ON DEFECT)
#              B6b, force := the ring's 10ms floor    -> must FAIL   (has teeth)
#              B6b, force := the formula's clamp CEILING, 350ms
#                                                    -> must PASS   (satisfiable)
#            ROUND 3 adds FOUR limbs on B6c, because B6a and B6b together were
#            demonstrated to pass a hold with no derivation behind it:
#              B6c, ratchet := clamp350 / clamp80 / patient(T) -- three CONSTANTS
#                   -> each must FAIL on 18/18.  A constant raises nothing, so it
#                      fails c1 at every length; the class dies, not a range of it.
#              B6c, ratchet := UNFILTERED (the ROUND-2 SHIPPED RULE: no
#                   skipped-seq filter, so ring.go's window flush and duplicates
#                   are read as evidence) on the [win] model
#                   -> must FAIL on >=1 cell.  MEASURED: 15 of 18, learning a
#                      median 6,285ms hold against the correct rule's 825ms.  NOT
#                      18/18, and that is stated rather than hidden: on a cell
#                      whose offered load never overflows the 2^11 window there is
#                      no flushTo, the two rules observe exactly the same events,
#                      and they ARE the same run.  A limb demanding a difference
#                      there would be asserting one that cannot exist.
#            If any limb does not come out as stated, the control itself fails the
#            battery: the limb is not responding to the hold.
#
# WHY NOT AN ABSOLUTE LATE-DISCARD BAR: ADR-004 forbids gating the rig's absolute
# numbers until E1.  Both limbs are relations between two runs on identical
# arrivals, which is the paired class the gate already recognises.
#
# WHAT B6 DOES NOT DO, stated rather than implied: it does not choose a hold for
# the product.  The ratchet trades late-discard for latency, and the size of that
# trade depends on edge-vs-mid (G1/E1) and on a LATENCY BUDGET for `max` mode that
# nobody has specified.  B6 asserts nothing about p50/p95; it prints them.  The
# budget is OBJ-D / U14's, and it is an open question, not a number chosen here.
# =============================================================================
RING_WINDOW = 2048    # ring.go mask+1, via pullrun.go:228 NewRing(11, ...)
RING_FLOOR = 0.010    # ring.go:147-150 holdNow() -- INHERITED, underived
# reserved_composite.py:445's OWN clamp limbs.  Cited, not invented: they are the
# two ends of the range the hold in force can occupy, so they are the only
# in-range references available without picking a number.
CLAMP_LO = 0.08
CLAMP_HI = 0.35
# B6a's one non-geometry-established cell (see the header): (scenario index, load).
B6A_UNESTABLISHED = {(0, 0.65)}
_INF = float('inf')


def formula_hold(sim):
    """The hold the rig itself used.  Kept byte-identical to
    reserved_composite.py:445-447 / ackclock_sim.py:566-567.  If either moves,
    B6-SELF goes red -- which is the point."""
    owds = [sim.defs[i]['down_owd'] + sim.defs[i]['loc_owd'] for i in range(sim.N)]
    jits = [d['jit'] for d in sim.defs]
    return min(0.35, max(0.08,
               ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0))


class FixedHold:
    """A constant hold -- the shipped formula, or the ring floor."""
    def __init__(s, h):
        s.h = h
        s.h_end = h
        s.raises = 0
        s.obs = 0

    def now(s):
        return s.h

    def on_epoch(s, block_at, lo, hi):
        pass

    def on_late(s, t, sq):
        pass


class LatenessRatchet:
    """hold.go's SHIPPED rule, transliterated -- not a Python idealisation of it.

    H := max(H, t_arrival - t_block_start) over frames THE RING ACTUALLY SKIPPED.

    ROUND 3, and this class changed because the round-2 version was NOT the
    algorithm that ships.  Round 2 kept a per-seq `marks` dict: every skipped seq
    remembered its OWN epoch's block start, and `on_late` popped that seq's own
    mark.  hold.go cannot do that -- `ring.go OnSkip` used to carry no seq, so the
    daemon kept ONE blockAt and observed EVERY arrival below the frontier.  The
    two are not the same rule, and the difference is not cosmetic: measured on the
    WINDOWED model (ring.go's real 2^11 ring, i.e. the daemon) the unfiltered rule
    learns an 8,213 ms hold at N5-het@0.95 where the per-seq rule learns 525 ms,
    because `ring.go flushTo` (:119-121) advances the frontier past seqs the ring
    NEVER held for, and every one of those arriving late was being read as
    evidence that the hold should be longer.  That is a runaway with no ceiling,
    and it was in the shipped file.

    So TWO things changed together, and neither is a model choice:
      * hold.go now filters -- an OnOld counts only for a seq the ring actually
        SKIPPED (ring.go OnSkip carries the seq; the ratchet records it in a
        buffer with ring.go's OWN geometry, seq&mask + the stored seq, exactly
        ring.go's `entry{seq,valid}` shape, so the record is O(1) and introduces
        no constant);
      * this class models exactly that: ONE `blk` (the most recent epoch's block
        start, which is all hold.go keeps) plus the same skipped-seq filter.

    ATTRIBUTION ERROR AND ITS DIRECTION, now measured rather than asserted.  With
    one blockAt, a frame skipped in an OLDER epoch is measured against a LATER
    block start, so `t - blk` UNDER-states its lateness: this rule can only
    under-shoot the per-seq truth, never over-shoot.  `PerSeqRatchet` below is
    that truth, scored on every cell every run and printed -- round 2 claimed
    "byte-identical on 7 of 9 cells" with no artifact behind it, and that claim is
    withdrawn and replaced by the printed B6-SELF(d) line.

    Using the GIVE-UP time instead of the block start is a different defect and is
    `SkipTimeRatchet` below."""

    def __init__(s, floor=RING_FLOOR, window=RING_WINDOW):
        s.h = 0.0
        s.floor = floor
        s.blk = None
        s.mask = window - 1
        s.pseq = [0] * window
        s.pon = [False] * window
        s.raises = 0
        s.obs = 0
        s.h_end = 0.0

    def now(s):
        return s.h if s.h > s.floor else s.floor

    def on_epoch(s, block_at, lo, hi):
        if block_at is None:
            return
        s.blk = block_at
        n = hi - lo
        if n >= s.mask:
            lo = hi - s.mask
        for g in range(lo, hi + 1):
            i = g & s.mask
            s.pseq[i] = g
            s.pon[i] = True

    def _mark(s, sq):
        """True (and consumes the record) iff the ring actually skipped sq."""
        i = sq & s.mask
        if not s.pon[i] or s.pseq[i] != sq:
            return False
        s.pon[i] = False
        return True

    def on_late(s, t, sq):
        if not s._mark(sq):
            return
        if s.blk is None:
            return
        s.obs += 1
        d = t - s.blk
        if d > s.h:
            s.h = d
            s.h_end = d
            s.raises += 1


class PerSeqRatchet:
    """THE ATTRIBUTION REFERENCE -- what an ideal ratchet with per-seq blockAt
    would learn.  Every skipped seq remembers its OWN epoch's block start.  The
    daemon cannot do this (hold.go keeps one blockAt), so this class is NOT what
    ships; it exists so the size of that approximation is a printed measurement
    (B6-SELF(d)) instead of a prose claim.  Marks are pruned to one ring window
    below the frontier: past that ring.go's own flushTo has already moved on."""

    def __init__(s, floor=RING_FLOOR, window=RING_WINDOW):
        s.h = 0.0
        s.floor = floor
        s.window = window
        s.marks = {}
        s.raises = 0
        s.obs = 0
        s.h_end = 0.0

    def now(s):
        return s.h if s.h > s.floor else s.floor

    def on_epoch(s, block_at, lo, hi):
        if block_at is None:
            return
        n = hi - lo
        if n >= s.window:
            lo = hi - s.window + 1
        for g in range(lo, hi + 1):
            s.marks[g] = block_at
        if len(s.marks) > 4 * s.window:
            cut = hi - s.window
            for k in [k for k in s.marks if k < cut]:
                del s.marks[k]

    def on_late(s, t, sq):
        b = s.marks.pop(sq, None)
        if b is None:
            return
        s.obs += 1
        d = t - b
        if d > s.h:
            s.h = d
            s.h_end = d
            s.raises += 1


class UnfilteredOldRatchet(LatenessRatchet):
    """THE ROUND-2 SHIPPED DEFECT, kept in tree so the control is a DEMONSTRATION
    and not an assertion (the discipline U33 used for phase_drops_wrapsplit, and
    this file already uses for SkipTimeRatchet).

    Identical to LatenessRatchet except that it drops the skipped-seq filter --
    i.e. exactly what hold.go OnOld did before round 3, and exactly what deleting
    the `skipped(seq)` guard from it produces again.  Every arrival below the
    frontier is read as evidence, including seqs the ring never held for because
    ring.go's window forced the frontier past them.  Measured: on the WINDOWED
    model it learns 8,213 ms where the correct rule learns 525 ms."""

    def _mark(s, sq):
        return True


class LatenessWitness:
    """B6c's REFERENCE, and it is deliberately not a hold policy: it never
    influences the walk.  It records, per skipped seq and against that seq's OWN
    epoch block start, the largest lateness THE TRACE ACTUALLY EXHIBITED.  It is
    the physical quantity a reorder hold exists to cover, measured from the run
    rather than chosen, so a hold longer than it is holding for something that did
    not happen on this trace."""

    def __init__(s, window=RING_WINDOW):
        s.ps = PerSeqRatchet(0.0, window)

    def on_epoch(s, block_at, lo, hi):
        s.ps.on_epoch(block_at, lo, hi)

    def on_late(s, t, sq):
        s.ps.on_late(t, sq)

    @property
    def maxlate(s):
        return s.ps.h

    @property
    def obs(s):
        return s.ps.obs


class SkipTimeRatchet(LatenessRatchet):
    """THE DEFECT, kept in tree so the control is a DEMONSTRATION rather than an
    assertion (same discipline as U33's phase_drops_wrapsplit).

    Identical to LatenessRatchet except that it marks the GIVE-UP time instead of
    the block start: block_at + the hold in force, i.e. it drops the
    `- holdInForce` term.  That is candidate (a) in the derivation, and it is
    exactly what a careless edit to hold.go's OnSkip produces -- OnSkip's argument
    IS the give-up instant, so forgetting `.Add(-r.effHoldLocked())` yields this.
    Measured: H converges to 10-90ms and loses to the formula on every cell."""

    def on_epoch(s, block_at, lo, hi):
        if block_at is None:
            return
        LatenessRatchet.on_epoch(s, block_at + s.now(), lo, hi)


def release_var(items, pol, window=None, wit=None):
    """`nsched_model.reorder_release` with the hold read from `pol` at every
    decision point, plus the two ratchet observation hooks and an OPTIONAL finite
    ring window (ring.go Push: `seq-next > mask` -> flushTo).

    `wit` is an OPTIONAL PASSIVE observer fed the same two hooks. It never
    supplies a hold and cannot change a single decision this walk makes -- it is
    read only by B6c, which needs the trace's own lateness measured independently
    of whatever policy is under test. Asserted inert by B6-SELF(e).

    With `pol = FixedHold(h)` and `window=None` this MUST be byte-identical to
    `M.reorder_release(items, h)` -- asserted by b6_selfcheck(), which also
    asserts window=huge == window=None."""
    if not items:
        return {}, 0, 0
    arr = sorted(items)
    n = len(arr)
    max_seq = max(s for _, s in arr)
    next_seq = min(s for _, s in arr)
    present = {}; release = {}
    skips = 0; max_depth = 0
    blocked_at = None; ptr = 0
    while ptr < n or next_seq <= max_seq:
        hold = pol.now()
        t_arr = arr[ptr][0] if ptr < n else _INF
        t_hold = (blocked_at + hold) if blocked_at is not None else _INF
        if t_arr == _INF and t_hold == _INF:
            break
        flushable = (hold > 0.0 or present or ptr >= n
                     or arr[ptr][1] > next_seq)
        if t_hold <= t_arr and flushable:
            clock = t_hold
            b0 = blocked_at
            if present:
                target = max(present)
                lo = hi = None
                while next_seq <= target:
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = clock if clock > a else a
                    else:
                        skips += 1
                        if lo is None:
                            lo = next_seq
                        hi = next_seq
                    next_seq += 1
                if lo is not None:
                    pol.on_epoch(b0, lo, hi)
                    if wit is not None:
                        wit.on_epoch(b0, lo, hi)
            else:
                tgt = arr[ptr][1] if ptr < n else max_seq + 1
                lo = next_seq if next_seq < tgt else None
                while next_seq < tgt:
                    skips += 1
                    next_seq += 1
                if lo is not None:
                    pol.on_epoch(b0, lo, next_seq - 1)
                    if wit is not None:
                        wit.on_epoch(b0, lo, next_seq - 1)
            blocked_at = None
        else:
            clock = t_arr
            while ptr < n and arr[ptr][0] == t_arr:
                sq = arr[ptr][1]
                if sq >= next_seq and sq not in release:
                    if window is not None and sq - next_seq > window - 1:
                        # ring.go:138-139 -- a seq past the window forces the
                        # frontier forward, delivering what is buffered below it.
                        while next_seq < sq:
                            a = present.pop(next_seq, None)
                            if a is not None:
                                release[next_seq] = clock if clock > a else a
                            next_seq += 1
                        blocked_at = None
                    present[sq] = t_arr
                elif sq < next_seq:
                    pol.on_late(t_arr, sq)
                    if wit is not None:
                        wit.on_late(t_arr, sq)
                ptr += 1
        while next_seq in present:
            a = present.pop(next_seq)
            release[next_seq] = clock if clock > a else a
            next_seq += 1
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None:
                blocked_at = clock
        else:
            blocked_at = None
        if len(present) > max_depth:
            max_depth = len(present)
    return release, skips, max_depth


def hold_score(sim, pol, window=None, wit=None):
    """Re-score a FINISHED run's delivery trace under a hold policy.  Arithmetic
    copied from reserved_composite.SimD.finalize (:447-462) so the numbers are
    comparable to the rig's own -- B6-SELF asserts they are IDENTICAL at the rig's
    own hold."""
    deliv = [(a, sq) for sq, a in sim.arr.items() if a is not None]
    release, skips, depth = release_var(deliv, pol, window, wit)
    rel = set(release)
    late = sum(1 for (a, sq) in deliv
               if sq not in rel and sim.enq.get(sq, 0) > sim.warm)
    Teff = sim.T - sim.warm
    lat = []; nd = 0
    for sq, rt in release.items():
        st = sim.enq[sq]
        if st > sim.warm:
            nd += 1
            lat.append((rt - st) * 1000.0)
    lat.sort()

    def pct(p):
        return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))] if lat else 0.0
    loss = 100.0 * (sim.offered_post - nd) / sim.offered_post if sim.offered_post else 0.0
    return {'gp': nd * M.PKT_KB / Teff, 'loss': max(0.0, loss), 'late': late,
            'p50': pct(.5), 'p95': pct(.95), 'p99': pct(.99), 'depth': depth,
            'hold': pol.h_end, 'raises': pol.raises, 'obs': pol.obs,
            'wmax': (wit.maxlate if wit is not None else 0.0),
            'wobs': (wit.obs if wit is not None else 0)}


def b6_selfcheck(trials=200, seed=0):
    """Three identities the B6 walk must satisfy before its numbers mean anything:
      (1) FixedHold(h), window=None  ==  M.reorder_release(items, h), exactly.
      (2) window = 10x the seq range  ==  window=None, exactly.
      (3) attaching the B6c witness changes NOTHING -- same release, same skips,
          same depth, on both the unbounded and the windowed walk.  Without this
          the reference B6c is judged against could quietly be part of the thing
          it judges.
    Random traces including duplicates, out-of-order arrivals and hold=0 (U1's
    termination corner).  Returns (n_release, n_window, n_witness) disagreements."""
    import random
    rnd = random.Random(seed)
    bad_r = bad_w = bad_i = 0
    for _ in range(trials):
        n = rnd.randint(1, 120)
        items = []
        t = 0.0
        for _i in range(n):
            t += rnd.random() * 0.02
            items.append((t + rnd.random() * 0.4, rnd.randint(0, n)))
        for h in (0.0, 0.005, 0.08, 0.13, 0.35, 1.0):
            r1, s1, d1 = M.reorder_release(items, h)
            r2, s2, d2 = release_var(items, FixedHold(h), None)
            if (r1, s1, d1) != (r2, s2, d2):
                bad_r += 1
            r3, s3, d3 = release_var(items, FixedHold(h), 10 * (n + 2))
            if (r2, s2, d2) != (r3, s3, d3):
                bad_w += 1
            r4, s4, d4 = release_var(items, FixedHold(h), None, LatenessWitness())
            if (r2, s2, d2) != (r4, s4, d4):
                bad_i += 1
            r5, s5, d5 = release_var(items, FixedHold(h), 64, LatenessWitness())
            r6, s6, d6 = release_var(items, FixedHold(h), 64)
            if (r5, s5, d5) != (r6, s6, d6):
                bad_i += 1
    return bad_r, bad_w, bad_i


def b6_measure(sim, reported):
    """The re-releases B6 reads, computed in the worker that owns the run.
    `reported` is the rig's OWN finalize() dict, for the B6-SELF identity."""
    h = formula_hold(sim)
    w_u = LatenessWitness()
    w_w = LatenessWitness()
    f_u = hold_score(sim, FixedHold(h), None)              # formula, rig model
    r_u = hold_score(sim, LatenessRatchet(), None, w_u)    # ratchet, rig model
    z_u = hold_score(sim, FixedHold(RING_FLOOR), None)     # ring floor, CTRL
    c8_u = hold_score(sim, FixedHold(CLAMP_LO), None)      # B6b reference
    ch_u = hold_score(sim, FixedHold(CLAMP_HI), None)      # clamp ceiling, CTRL
    # The PATIENT hold: longer than the whole scored window, so no frame that
    # ARRIVES is ever discarded as late.  Derived from the run, not picked -- it is
    # the run's own length, the largest lateness the trace can contain.
    x_u = hold_score(sim, FixedHold(sim.T), None)
    d_u = hold_score(sim, SkipTimeRatchet(), None)         # THE DEFECT, CTRL
    # ATTRIBUTION REFERENCE (B6-SELF(d)).  What a per-seq blockAt would learn.  The
    # daemon cannot keep one; this measures how much that costs, on every cell,
    # every run -- replacing round 2's uncited "byte-identical on 7 of 9 cells".
    ps_u = hold_score(sim, PerSeqRatchet(), None)
    f_w = hold_score(sim, FixedHold(h), RING_WINDOW)       # formula, daemon ring
    r_w = hold_score(sim, LatenessRatchet(), RING_WINDOW, w_w)  # ratchet, daemon ring
    ps_w = hold_score(sim, PerSeqRatchet(), RING_WINDOW)
    # THE ROUND-2 SHIPPED DEFECT, scored on the model where it lives: with ring.go's
    # real window, flushTo advances the frontier past seqs the ring never held for.
    uf_w = hold_score(sim, UnfilteredOldRatchet(), RING_WINDOW)
    same = (f_u['late'] == reported.get('late')
            and abs(f_u['loss'] - reported.get('loss', -1.0)) < 1e-9)
    return {'self_ok': bool(same), 'hold_f': h,
            'c8_late': c8_u['late'], 'ch_late': ch_u['late'],
            'x_late': x_u['late'], 'd_late': d_u['late'], 'd_hold': d_u['hold'],
            'f_late': f_u['late'], 'r_late': r_u['late'], 'z_late': z_u['late'],
            'f_loss': f_u['loss'], 'r_loss': r_u['loss'], 'z_loss': z_u['loss'],
            'f_p50': f_u['p50'], 'r_p50': r_u['p50'],
            'f_p95': f_u['p95'], 'r_p95': r_u['p95'],
            'r_hold': r_u['hold'], 'r_raises': r_u['raises'], 'r_obs': r_u['obs'],
            # --- B6c: every millisecond of hold must be EVIDENCED --------------
            # `wmax` is the witness's number, not the policy's: the largest
            # lateness THIS TRACE exhibited, per-seq, measured by a passive
            # observer that changes no decision (B6-SELF(e)).
            'w_max_u': r_u['wmax'], 'w_max_w': r_w['wmax'],
            'r_hold_w': r_w['hold'], 'r_raises_w': r_w['raises'],
            # CTRL policies for B6c -- constants, so raises is 0 by construction
            # and h_end is the constant itself.  No extra runs: these are the same
            # scores the other limbs already use.
            'ch_hold': ch_u['hold'], 'ch_raises': ch_u['raises'],
            'x_hold': x_u['hold'], 'x_raises': x_u['raises'],
            'c8_hold': c8_u['hold'], 'c8_raises': c8_u['raises'],
            'uf_hold_w': uf_w['hold'], 'uf_raises_w': uf_w['raises'],
            'uf_late_w': uf_w['late'], 'uf_obs_w': uf_w['obs'],
            # --- B6-SELF(d): shipped single-blockAt vs per-seq attribution ------
            'ps_late': ps_u['late'], 'ps_hold': ps_u['hold'],
            'ps_late_w': ps_w['late'], 'ps_hold_w': ps_w['hold'],
            'w_f_late': f_w['late'], 'w_r_late': r_w['late'],
            'w_f_loss': f_w['loss'], 'w_r_loss': r_w['loss'],
            'w_f_p50': f_w['p50'], 'w_r_p50': r_w['p50'],
            'w_f_p95': f_w['p95'], 'w_r_p95': r_w['p95'],
            'w_r_hold': r_w['hold']}


# ---------------------------------------------------------------------------
# Scenarios.  Heterogeneous mixes only -- no homogeneous clones.  Every member is
# a reserved_composite archetype (cellA/B/C = spotty tethers with DISTINCT caps,
# periods, owd/jit and DISTINCT dropout schedules; wifi = wifi-as-WAN steady;
# eth = ethernet steady).  The product spec (p5-execution-handover.md s1) is
# "any mix of multiple cell/USB tethers, wifi-as-WAN, ethernet".
#
# The first four form a NESTED chain (each adds exactly one source) -- that chain
# is what B5 scores.
# ---------------------------------------------------------------------------
def SCENARIOS():
    return [
        # -- nested chain --------------------------------------------------
        ('N2-het  cellA + eth',
         [RC.cellA(RC.DROPS_A), RC.eth()], True),
        ('N3-het  cellA + cellB + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.eth()], True),
        ('N4-het  cellA + cellB + wifi + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.wifi(), RC.eth()], True),
        ('N5-het  cellA + cellB + cellC + wifi + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
          RC.wifi(), RC.eth()], True),
        # -- off-chain high-N stress mixes ---------------------------------
        ('N4-teth cellA + cellB + cellC + eth  (tether-heavy 3/1)',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
          RC.eth()], False),
        ('N5-corr cellA+cellB+cellC (CORRELATED stalls) + wifi + eth',
         [RC.cellA(RC.DROPS_CORR), RC.cellB(RC.DROPS_CORR), RC.cellC(RC.DROPS_CORR),
          RC.wifi(), RC.eth()], False),
    ]


def spotty_idx(archs):
    return [i for i, a in enumerate(archs) if a['spotty']]


def make_sim(defs, ofn, tt, seed, sched):
    if sched in ('Dc', 'Dpp', 'D', 'redundant'):
        return RC.SimD(defs, ofn, tt, seed, sched=sched)
    return A.Sim(defs, ofn, tt, seed, sched=sched, mirror=False)


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


# ---------------------------------------------------------------------------
# workers (top-level + plain-dict args so they pickle under Windows spawn)
# ---------------------------------------------------------------------------
def work_main(task):
    (si, archs, load, sched, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    o = make_sim(defs, ofn, T, seed, sched)
    m = o.run()
    sp = spotty_idx(archs)
    tot = sum(o.assigned) or 1
    m2 = {k: m[k] for k in ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop') if k in m}
    m2['sshare'] = sum(o.assigned[i] for i in sp) / tot
    # B6 (U13) rides the runs that already exist -- the composite only, since the
    # hold geometry it scores is the RECEIVER's and is identical for every
    # scheduler.  No extra simulation; the cost is four re-releases of a trace
    # already in memory in this worker.
    if sched == 'Dc':
        m2['b6'] = b6_measure(o, m)
    return (si, sched, load, seed, m2)


def work_tl(task):
    """One truncated-T run for the spotty-share timeline (B4b)."""
    (si, archs, sched, seed, tt) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom: 0.95 * _n)
    o = make_sim(defs, ofn, tt, seed, sched)
    o.run()
    sp = set(spotty_idx(archs))
    a_sp = sum(o.assigned[i] for i in range(len(o.assigned)) if i in sp)
    a_all = sum(o.assigned)
    return (si, sched, seed, tt, a_sp, a_all)


def work_scale(task):
    """B5: one fixed ABSOLUTE offer applied to every member of the nested chain."""
    (ci, archs, offer, sched, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    ofn = (lambda t, _o=offer: _o)
    m = make_sim(defs, ofn, T, seed, sched).run()
    return (ci, sched, seed, {'gp': m['gp'], 'loss': m['loss'],
                              'p95': m['p95'], 'p99': m['p99']})


# ---------------------------------------------------------------------------
def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = SCENARIOS()
    t0 = time.time()

    print('#' * 118)
    print('# HIGH-N SCORED BATTERY  (N=4 / N=5 heterogeneous)  seeds=%d  T=%.1fs  rig=%s  medians'
          % (SEEDS, T, RIG))
    print('# physics = nsched_model.py UNMODIFIED   composite = reserved_composite.SimD(sched="Dc")')
    print('# references = ackclock_sim.Sim(ewma|pull, mirror=False) + SimD(Dpp)   PAIRED SEEDS')
    print('#' * 118)
    for (title, archs, chain) in scen:
        nom = sum(a['base'] for a in archs)
        print('#   %-58s N=%d spotty=%d/%d nominal_agg=%7d kb/s %s'
              % (title, len(archs), len(spotty_idx(archs)), len(archs), nom,
                 '[chain]' if chain else ''))
    print('#' * 118)
    sys.stdout.flush()

    # ---------------- main table ----------------
    tasks = [(si, archs, L, sch, sd)
             for si, (t_, archs, c_) in enumerate(scen)
             for L in LOADS for sch in SCHEDS for sd in range(SEEDS)]
    # B3's paired loss reference, at B3's load only (see B3_REF above).
    tasks += [(si, archs, B3_LOAD, B3_REF, sd)
              for si, (t_, archs, c_) in enumerate(scen)
              for sd in range(SEEDS)]
    print('# main-table runs: %d' % len(tasks), file=sys.stderr)
    res = {}
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sch, L, sd, m) in ex.map(work_main, tasks, chunksize=4):
            res.setdefault(si, {}).setdefault(sch, {}).setdefault(L, []).append(m)
            done += 1
            if done % 250 == 0:
                print('  ..main %d/%d  (%.0fs)' % (done, len(tasks), time.time() - t0),
                      file=sys.stderr)

    def agg(si, sch, L, k):
        return med([d[k] for d in res[si][sch][L]])

    for si, (title, archs, chain) in enumerate(scen):
        nom = sum(a['base'] for a in archs)
        print('=' * 118)
        print('%s   | N=%d spotty=%d nominal_agg=%d' % (title, len(archs),
                                                        len(spotty_idx(archs)), nom))
        print('=' * 118)
        print('  %-6s | %s' % ('sched', '  ||  '.join(
            '%-40s' % ('load=%.2f   gp  loss   p95   p99 sshare' % L) for L in LOADS)))
        for sch in SCHEDS:
            cells = []
            for L in LOADS:
                cells.append('%7.0f %5.2f %5.0f %5.0f %6.3f' % (
                    agg(si, sch, L, 'gp'), agg(si, sch, L, 'loss'),
                    agg(si, sch, L, 'p95'), agg(si, sch, L, 'p99'),
                    agg(si, sch, L, 'sshare')))
            print('  %-6s | %s' % (sch, '  ||  '.join('%-40s' % c for c in cells)))
        print()
    sys.stdout.flush()

    # ---------------- B1/B2/B3/B4a ----------------
    fails = []
    print('=' * 118)
    print('BAR CHECKS -- B1 no-collapse | B2 loss-parity | B3 spare-load win | B4a no-eviction-spiral')
    print('=' * 118)
    for si, (title, archs, chain) in enumerate(scen):
        print('-' * 118)
        print('%s' % title)
        dc_gp = agg(si, 'Dc', B3_LOAD, 'gp'); ew_gp = agg(si, 'ewma', B3_LOAD, 'gp')
        dc_ls = agg(si, 'Dc', B3_LOAD, 'loss')
        or_ls = agg(si, B3_REF, B3_LOAD, 'loss')
        ok_a = dc_gp >= ew_gp
        # PAIRED per-seed, same shape as B2 -- not a comparison of two medians.
        b3p = [a_ - b_ for a_, b_ in
               zip([d['loss'] for d in res[si]['Dc'][B3_LOAD]],
                   [d['loss'] for d in res[si][B3_REF][B3_LOAD]])]
        b3_over = sum(1 for x in b3p if x > 0.0)
        ok_b = med(b3p) <= 0.0
        if not ok_a:
            fails.append('B3(gp)   %s load=%.2f: Dc gp %.0f < ewma gp %.0f'
                         % (title, B3_LOAD, dc_gp, ew_gp))
        if not ok_b:
            fails.append('B3(loss) %s load=%.2f: Dc loss %.2f%% > %s loss %.2f%% '
                         '(paired median %+.3f pt, %d/%d seeds worse than the reference)'
                         % (title, B3_LOAD, dc_ls, B3_REF, or_ls,
                            med(b3p), b3_over, SEEDS))
        print('  B3 load=%.2f WIN : Dc gp=%.0f vs ewma=%.0f -> %s | Dc loss=%.2f%% vs %s '
              '%.2f%% -> %s   paired Dc-%s med=%+.3f min=%+.3f max=%+.3f  worse=%d/%d'
              % (B3_LOAD, dc_gp, ew_gp, 'PASS' if ok_a else 'FAIL',
                 dc_ls, B3_REF, or_ls, 'PASS' if ok_b else 'FAIL',
                 B3_REF, med(b3p), min(b3p), max(b3p), b3_over, SEEDS))
        print('    [retired U11] the old absolute half was "Dc loss <= 2.00%%"; on this cell '
              'Dc=%.2f%% -> %s.  Kept visible, not asserted.'
              % (dc_ls, 'would PASS' if dc_ls <= 2.0 else 'would FAIL'))
        for L in (0.85, 0.95):
            dc_gp = agg(si, 'Dc', L, 'gp'); ew_gp = agg(si, 'ewma', L, 'gp')
            dc_ls = agg(si, 'Dc', L, 'loss'); ew_ls = agg(si, 'ewma', L, 'loss')
            ok1 = dc_gp >= 0.99 * ew_gp
            ok2 = dc_ls <= ew_ls + 0.5
            # paired per-seed delta (same shape as adv_verify_dc.py)
            pairs = [a_ - b_ for a_, b_ in
                     zip([d['loss'] for d in res[si]['Dc'][L]],
                         [d['loss'] for d in res[si]['ewma'][L]])]
            over = sum(1 for x in pairs if x > 0.5)
            if not ok1:
                fails.append('B1 %s load=%.2f: Dc gp %.0f < 0.99*ewma %.0f'
                             % (title, L, dc_gp, 0.99 * ew_gp))
            if not ok2:
                fails.append('B2 %s load=%.2f: Dc loss %.2f%% > ewma+0.5 = %.2f%% '
                             '(paired median %+.3f pt, %d/%d seeds >0.5pt)'
                             % (title, L, dc_ls, ew_ls + 0.5, med(pairs), over, SEEDS))
            print('  B1 load=%.2f     : gp Dc=%.0f vs 0.99*ewma=%.0f -> %s'
                  % (L, dc_gp, 0.99 * ew_gp, 'PASS' if ok1 else 'FAIL'))
            print('  B2 load=%.2f     : loss Dc=%.2f%% vs ewma+0.5=%.2f%% -> %s   '
                  'paired Dc-ewma med=%+.3f min=%+.3f max=%+.3f  seeds>0.5pt=%d/%d'
                  % (L, dc_ls, ew_ls + 0.5, 'PASS' if ok2 else 'FAIL',
                     med(pairs), min(pairs), max(pairs), over, SEEDS))
        for L in LOADS:
            s_dc = agg(si, 'Dc', L, 'sshare'); s_pl = agg(si, 'pull', L, 'sshare')
            ok = s_dc <= s_pl
            if not ok:
                fails.append('B4a %s load=%.2f: spotty-share Dc %.3f > pull %.3f'
                             % (title, L, s_dc, s_pl))
            print('  B4a load=%.2f    : spotty-class native share Dc=%.3f vs pull=%.3f -> %s'
                  % (L, s_dc, s_pl, 'PASS' if ok else 'FAIL'))
    sys.stdout.flush()

    # ---------------- B6 hold geometry (U13 / OBJ-B) ----------------
    print('=' * 118)
    print('B6 HOLD GEOMETRY -- the reorder hold, re-scored on the SAME Dc traces')
    print('=' * 118)
    print('  hold in force = clamp(owd_spread + 3*max_jit + 130ms, 80, 350)   '
          '[reserved_composite.py:445]')
    print('  ratchet       = max over SKIPPED frames of (t_arrival - t_block_start), ONE '
          'blockAt')
    print('                  = hold.go OnSkip/OnOld transliterated, not an idealisation of it.')
    print('                  [U13, no constant]  PerSeqRatchet = the per-seq attribution '
          'reference')
    print('  B6a reference = the HOLD IN FORCE (tracks each cell\'s own owd/jitter).')
    print('  B6b reference = clamp%d = %.0fms, reserved_composite.py:445\'s OWN clamp FLOOR --'
          % (int(CLAMP_LO * 1000), 1000 * CLAMP_LO))
    print('                  a value the formula itself can emit, INSIDE the realistic range.')
    print('                  Round 1 used ring.go\'s 10ms floor; measured tolerance ~50x, so it')
    print('                  printed PASS on 18/18 cells for every hold from 20ms to 500ms.')
    print('                  See hold_sweep_b2.txt.  CTRL references: floor%d=%.0fms (ring.go)'
          % (int(RING_FLOOR * 1000), 1000 * RING_FLOOR))
    print('                  clamp%d=%.0fms (clamp ceiling), patient=T (discards nothing),'
          % (int(CLAMP_HI * 1000), 1000 * CLAMP_HI))
    print('                  defect=SkipTimeRatchet (the t_skip observation, candidate (a)).')
    print('  GATED limbs use the UNBOUNDED reorder model (nsched_model.reorder_release, the')
    print('  ADR-004 instrument).  The [win] columns re-score with ring.go\'s REAL 2^11 window')
    print('  (pullrun.go:228) and are REPORTED, not gated -- they are evidence for the Go port.')
    print('  B6c is gated on BOTH models: it is a relation between a hold and the lateness the')
    print('  SAME trace exhibited, not an absolute threshold, so ADR-004 is untouched.')
    bad_r, bad_w, bad_i = b6_selfcheck()
    print('  B6-SELF(a) release_var == nsched_model.reorder_release over 200 random traces x 6')
    print('             holds (incl. hold=0, U1\'s termination corner): %d disagreement(s) -> %s'
          % (bad_r, 'PASS' if bad_r == 0 else 'FAIL'))
    print('  B6-SELF(b) window=10x seq range == window=None: %d disagreement(s) -> %s'
          % (bad_w, 'PASS' if bad_w == 0 else 'FAIL'))
    print('  B6-SELF(e) attaching the B6c witness changes no release, skip or depth, on'
          ' both the')
    print('             unbounded and the windowed walk: %d disagreement(s) -> %s'
          % (bad_i, 'PASS' if bad_i == 0 else 'FAIL'))
    if bad_r:
        fails.append('B6-SELF(a) release_var diverged from nsched_model.reorder_release on '
                     '%d random trace/hold pairs: the B6 instrument is not the rig\'s '
                     'release rule, so every B6 number below is unreadable' % bad_r)
    if bad_w:
        fails.append('B6-SELF(b) the windowed release path changed the result at a window '
                     'wider than the trace on %d pairs: the window branch is not inert '
                     'when it should be' % bad_w)
    if bad_i:
        fails.append('B6-SELF(e) attaching the B6c witness changed the walk on %d trace/hold '
                     'pairs: the reference B6c judges a hold against is not independent of '
                     'the walk, so B6c is not evidence' % bad_i)
    print('-' * 118)
    n_self_bad = 0
    ctrl = {'a_patient_fail': 0, 'a_defect_worse': 0, 'a_defect_red': 0,
            'b_floor_fail': 0, 'b_ceiling_pass': 0, 'cells': 0,
            'c_const_ceiling': 0, 'c_const_patient': 0, 'c_const_floor': 0,
            'c_unfiltered': 0}
    psd = {'late_same': 0, 'hold_same': 0, 'late_same_w': 0, 'hold_same_w': 0,
           'ratio_max': 0.0}
    for si, (title, archs, chain) in enumerate(scen):
        print('%s' % title)
        for L in LOADS:
            b6 = [d['b6'] for d in res[si]['Dc'][L] if 'b6' in d]
            if not b6:
                continue
            n_self_bad += sum(1 for b in b6 if not b['self_ok'])
            f_late = [b['f_late'] for b in b6]
            r_late = [b['r_late'] for b in b6]
            z_late = [b['z_late'] for b in b6]
            c8_late = [b['c8_late'] for b in b6]
            ch_late = [b['ch_late'] for b in b6]
            x_late = [b['x_late'] for b in b6]
            d_late = [b['d_late'] for b in b6]
            # B6a: the DERIVED hold must strictly beat the hold IN FORCE.
            pa = [a_ - b_ for a_, b_ in zip(r_late, f_late)]      # want < 0
            # B6b: the hold in force must strictly beat the formula's OWN clamp floor.
            pb = [a_ - b_ for a_, b_ in zip(f_late, c8_late)]     # want < 0
            oka = med(pa) < 0.0
            okb = med(pb) < 0.0
            # B6c: the hold must be EVIDENCED.  Two limbs, both on the DERIVED
            # hold, both gated on every cell.
            #   c1  it must have been RAISED by an observation at least once --
            #       a hold nothing raised is not derived from anything.
            #   c2  it must not exceed the largest lateness the TRACE ACTUALLY
            #       EXHIBITED (the witness), measured per-seq by a passive
            #       observer.  A hold longer than that holds for something that
            #       did not happen.
            # Medians, like every other limb here, so one seed cannot decide it.
            r_raises_l = [b['r_raises'] for b in b6]
            r_hold_l = [b['r_hold'] for b in b6]
            wmax_l = [b['w_max_u'] for b in b6]
            okc1 = med(r_raises_l) >= 1
            okc2 = med([a_ - b_ for a_, b_ in zip(r_hold_l, wmax_l)]) <= 0.0
            okc = okc1 and okc2
            gated_a = (si, L) not in B6A_UNESTABLISHED
            # B6-CTRL: four substitutions, each against a DIFFERENT run.  No limb
            # compares a vector with itself (round-1 blocker B3).
            ctrl['cells'] += 1
            if not (med([a_ - b_ for a_, b_ in zip(r_late, x_late)]) < 0.0):
                ctrl['a_patient_fail'] += 1
            if med([a_ - b_ for a_, b_ in zip(d_late, r_late)]) > 0.0:
                ctrl['a_defect_worse'] += 1
            if gated_a and not (med([a_ - b_ for a_, b_ in zip(d_late, f_late)]) < 0.0):
                ctrl['a_defect_red'] += 1
            if not (med([a_ - b_ for a_, b_ in zip(z_late, c8_late)]) < 0.0):
                ctrl['b_floor_fail'] += 1
            if med([a_ - b_ for a_, b_ in zip(ch_late, c8_late)]) < 0.0:
                ctrl['b_ceiling_pass'] += 1
            # B6c CTRL: substitute a CONSTANT hold for the ratchet.  This is the
            # demonstrated attack -- a constant hold makes ZERO observations and
            # still satisfies B6a, because B6a only rewards discarding fewer
            # arrived frames.  Three constants already scored above (the clamp
            # ceiling, the clamp floor, and the patient hold = T), so no extra
            # run.  Each must FAIL B6c.
            for key, hk, rk in (('c_const_ceiling', 'ch_hold', 'ch_raises'),
                                ('c_const_patient', 'x_hold', 'x_raises'),
                                ('c_const_floor', 'c8_hold', 'c8_raises')):
                cc1 = med([b[rk] for b in b6]) >= 1
                cc2 = med([b[hk] - b['w_max_u'] for b in b6]) <= 0.0
                if not (cc1 and cc2):
                    ctrl[key] += 1
            # B6c CTRL: substitute the ROUND-2 SHIPPED RULE (no skipped-seq
            # filter) on the WINDOWED model, which is where ring.go's flushTo
            # makes it diverge.  Asserted the same way the t_skip defect is:
            # RED on AT LEAST ONE cell, with the count printed -- NOT on all 18,
            # and that is stated rather than hidden.  On a cell where the offered
            # load never overflows the 2^11 window there is no flushTo, the two
            # rules observe exactly the same events, and they ARE the same run:
            # a limb that demanded a difference there would be asserting a
            # difference that cannot exist.
            u1 = med([b['uf_raises_w'] for b in b6]) >= 1
            u2 = med([b['uf_hold_w'] - b['w_max_w'] for b in b6]) <= 0.0
            if not (u1 and u2):
                ctrl['c_unfiltered'] += 1
            # B6-SELF(d): shipped single-blockAt attribution vs per-seq truth.
            if med([b['ps_late'] for b in b6]) == med(r_late):
                psd['late_same'] += 1
            if med([b['ps_hold'] - b['r_hold'] for b in b6]) == 0.0:
                psd['hold_same'] += 1
            if med([b['ps_late_w'] for b in b6]) == med([b['w_r_late'] for b in b6]):
                psd['late_same_w'] += 1
            if med([b['ps_hold_w'] - b['r_hold_w'] for b in b6]) == 0.0:
                psd['hold_same_w'] += 1
            for b in b6:
                for a_, b_ in ((b['ps_hold'], b['r_hold']), (b['ps_hold_w'], b['r_hold_w'])):
                    if b_ > 0 and a_ / b_ > psd['ratio_max']:
                        psd['ratio_max'] = a_ / b_
            if not oka and gated_a:
                fails.append('B6a %s load=%.2f: the observation-derived hold does NOT strictly '
                             'beat the hold in force (late %d vs %d, paired median %+.1f frames, '
                             '%d/%d seeds not better); hold=%.0fms vs ratchet %.0fms'
                             % (title, L, med(r_late), med(f_late), med(pa),
                                sum(1 for x in pa if x >= 0), len(pa),
                                1000 * med([b['hold_f'] for b in b6]),
                                1000 * med([b['r_hold'] for b in b6])))
            if not okc:
                fails.append('B6c %s load=%.2f: the derived hold is not EVIDENCED '
                             '(raises=%d, must be >=1; hold=%.0fms vs the largest lateness '
                             'this trace exhibited=%.0fms, must be <=). A hold that nothing '
                             'raised, or that is longer than any lateness observed, is not '
                             'derived from a measurement'
                             % (title, L, med(r_raises_l), 1000 * med(r_hold_l),
                                1000 * med(wmax_l)))
            if not okb:
                fails.append('B6b %s load=%.2f: the hold in force is not STRICTLY better than '
                             'the shortest hold its OWN formula can emit (clamp floor %.0fms) '
                             '(late %d vs %d, paired median %+.1f frames) -- the hold is '
                             'inoperative'
                             % (title, L, 1000 * CLAMP_LO, med(f_late), med(c8_late), med(pb)))
            print('  L=%.2f hold=%3.0fms ratchet=%4.0fms(r=%d,obs=%d) | late  force=%6d '
                  'ratchet=%6d clamp%d=%7d | B6a %s  B6b %s'
                  % (L, 1000 * med([b['hold_f'] for b in b6]),
                     1000 * med([b['r_hold'] for b in b6]),
                     med([b['r_raises'] for b in b6]), med([b['r_obs'] for b in b6]),
                     med(f_late), med(r_late), int(CLAMP_LO * 1000), med(c8_late),
                     ('PASS' if oka else 'FAIL') if gated_a
                     else ('pass' if oka else 'fail') + '(NOT GATED: geometry)',
                     'PASS' if okb else 'FAIL'))
            print('        [B6c] evidenced: raises=%d(>=1) hold=%4.0fms <= max lateness this '
                  'trace exhibited=%4.0fms -> %s'
                  % (med(r_raises_l), 1000 * med(r_hold_l), 1000 * med(wmax_l),
                     'PASS' if okc else 'FAIL'))
            print('        [range] late at floor%d=%7d clamp%d=%6d clamp%d=%6d patient=%5d '
                  '| defect(t_skip ratchet)=%7d h=%4.0fms'
                  % (int(RING_FLOOR * 1000), med(z_late), int(CLAMP_LO * 1000), med(c8_late),
                     int(CLAMP_HI * 1000), med(ch_late), med(x_late), med(d_late),
                     1000 * med([b['d_hold'] for b in b6])))
            print('        loss force=%5.2f%% ratchet=%5.2f%% floor=%5.2f%% | p50 %4.0f/%4.0f '
                  'p95 %4.0f/%4.0f (force/ratchet, NOT asserted -- no latency budget exists, '
                  'OBJ-D/U14)'
                  % (med([b['f_loss'] for b in b6]), med([b['r_loss'] for b in b6]),
                     med([b['z_loss'] for b in b6]),
                     med([b['f_p50'] for b in b6]), med([b['r_p50'] for b in b6]),
                     med([b['f_p95'] for b in b6]), med([b['r_p95'] for b in b6])))
            print('        [win] ring.go 2^11: late force=%6d ratchet=%6d | loss %5.2f%%/%5.2f%% '
                  '| p50 %4.0f/%4.0f p95 %4.0f/%4.0f  ratchet=%4.0fms'
                  % (med([b['w_f_late'] for b in b6]), med([b['w_r_late'] for b in b6]),
                     med([b['w_f_loss'] for b in b6]), med([b['w_r_loss'] for b in b6]),
                     med([b['w_f_p50'] for b in b6]), med([b['w_r_p50'] for b in b6]),
                     med([b['w_f_p95'] for b in b6]), med([b['w_r_p95'] for b in b6]),
                     1000 * med([b['w_r_hold'] for b in b6])))
    print('-' * 118)
    print('  B6-SELF(c) per-run identity: re-scoring each Dc trace at the RIG\'S OWN hold '
          'reproduced')
    print('             its OWN reported loss and late-discard on %d/%d runs -> %s'
          % (sum(len([d for d in res[si]['Dc'][L] if 'b6' in d])
                 for si in range(len(scen)) for L in LOADS) - n_self_bad,
             sum(len([d for d in res[si]['Dc'][L] if 'b6' in d])
                 for si in range(len(scen)) for L in LOADS),
             'PASS' if n_self_bad == 0 else 'FAIL'))
    if n_self_bad:
        fails.append('B6-SELF(c) %d Dc run(s) where re-scoring at the rig\'s own hold did NOT '
                     'reproduce the rig\'s own loss/late: reserved_composite.py:445 or '
                     'nsched_model.reorder_release moved and B6 no longer measures the rig'
                     % n_self_bad)
    nc = ctrl['cells']
    print('  B6-SELF(d) ATTRIBUTION -- REPORTED, NOT GATED (the shipped rule can only')
    print('             UNDER-shoot the per-seq truth, so a bar on the gap would need a')
    print('             tolerance nothing derives).  The shipped rule keeps ONE blockAt, so a')
    print('             frame skipped in an older epoch is measured against a later block and')
    print('             its lateness is UNDER-stated.  Scored against PerSeqRatchet, which')
    print('             gives every skipped seq its own epoch: late-discard identical on')
    print('             %d/%d cells [unbounded] and %d/%d [win]; final hold identical on %d/%d'
          % (psd['late_same'], nc, psd['late_same_w'], nc, psd['hold_same'], nc))
    print('             and %d/%d; worst per-seq/shipped hold ratio %.3f.  This REPLACES the'
          ' round-2' % (psd['hold_same_w'], nc, psd['ratio_max']))
    print('             uncited "byte-identical on 7 of 9 cells" claim, which had no artifact.')
    print('  B6a is GATED on %d of %d cells.  NOT GATED, and it is one explicit entry so it '
          'cannot grow' % (nc - len(B6A_UNESTABLISHED), nc))
    for (si_, L_) in sorted(B6A_UNESTABLISHED):
        print('             silently: %s load=%.2f -- margin 65 frames on 454; 48 stall-phase '
              'rotations' % (scen[si_][0].split()[0], L_))
        print('             x 6 seeds x 3 loads (864 runs, b4_geometry_estab.py) put '
              'med(ratchet-force) in')
        print('             [-192.5,+56.0] with 10/48 rotations of the WRONG SIGN at this load. '
              'The verdict')
        print('             is decided by the hand-placed stall geometry, not by the hold (U33).')
    print('  B6-CTRL falsifiability, %d cells, FOUR substitutions -- and in round 2 none of them'
          % nc)
    print('             compares a vector with itself.  Each substitutes a DIFFERENT RUN:')
    print('             subst B6a force := patient(T)   -> FAIL %2d/%2d  (satisfiable: the '
          'ratchet cannot beat a hold that discards nothing)'
          % (ctrl['a_patient_fail'], nc))
    print('             subst B6a ratchet := t_skip     -> WORSE than the correct observation '
          'on %2d/%2d cells (candidate (a))' % (ctrl['a_defect_worse'], nc))
    print('             subst B6a ratchet := t_skip     -> turns B6a RED on %2d gated cell(s), so '
          'the gate exits 1  (RED ON DEFECT)' % ctrl['a_defect_red'])
    print('             subst B6b force := floor%d      -> FAIL %2d/%2d  (has teeth: a hold at '
          'the ring floor is not better than clamp%d)'
          % (int(RING_FLOOR * 1000), ctrl['b_floor_fail'], nc, int(CLAMP_LO * 1000)))
    print('             subst B6b force := clamp%d     -> PASS %2d/%2d  (satisfiable: the clamp '
          'ceiling does beat the clamp floor)'
          % (int(CLAMP_HI * 1000), ctrl['b_ceiling_pass'], nc))
    print('             subst B6c ratchet := clamp%d    -> FAIL %2d/%2d  (a CONSTANT hold makes '
          'ZERO observations)' % (int(CLAMP_HI * 1000), ctrl['c_const_ceiling'], nc))
    print('             subst B6c ratchet := clamp%d     -> FAIL %2d/%2d  (same, at the other end '
          'of the clamp)' % (int(CLAMP_LO * 1000), ctrl['c_const_floor'], nc))
    print('             subst B6c ratchet := patient(T) -> FAIL %2d/%2d  (the hold that satisfies '
          'B6a best of all)' % (ctrl['c_const_patient'], nc))
    print('             subst B6c ratchet := UNFILTERED -> FAIL %2d/%2d  on the [win] model  (the '
          'ROUND-2 SHIPPED RULE.  >=1 required:' % (ctrl['c_unfiltered'], nc))
    print('                                                              on a cell that never '
          'overflows the 2^11 window the two rules are the SAME RUN.')
    print('                                                              no skipped-seq filter, '
          'learns %.0fms vs %.0fms)'
          % (1000 * med([b['uf_hold_w'] for si_ in range(len(scen)) for L_ in LOADS
                         for b in [d['b6'] for d in res[si_]['Dc'][L_] if 'b6' in d]]),
             1000 * med([b['r_hold_w'] for si_ in range(len(scen)) for L_ in LOADS
                         for b in [d['b6'] for d in res[si_]['Dc'][L_] if 'b6' in d]])))
    for k, lbl in (('c_const_ceiling',
                    'B6c does not FAIL when the derived hold is replaced by the constant '
                    'clamp ceiling -- a hold with no observations behind it passes the bar '
                    'whose purpose is to gate a DERIVED hold'),
                   ('c_const_floor',
                    'B6c does not FAIL when the derived hold is replaced by the constant '
                    'clamp floor'),
                   ('c_const_patient',
                    'B6c does not FAIL when the derived hold is replaced by the patient '
                    'constant, which is the hold that satisfies B6a best of all'),
                   ('a_patient_fail',
                    'B6a does not FAIL when the hold in force is the patient hold'),
                   ('a_defect_worse',
                    'the t_skip DEFECT is not strictly worse than the correct observation'),
                   ('b_floor_fail',
                    'B6b does not FAIL when the hold in force is the ring floor'),
                   ('b_ceiling_pass',
                    'B6b does not PASS when the hold in force is the clamp ceiling')):
        if nc and ctrl[k] != nc:
            fails.append('B6-CTRL %s on %d/%d cells: the limb is not responding to the hold, '
                         'so its verdict is not evidence' % (lbl, nc - ctrl[k], nc))
    if nc and ctrl['c_unfiltered'] < 1:
        fails.append('B6-CTRL removing the skipped-seq filter from the ratchet (the ROUND-2 '
                     'SHIPPED RULE) fails B6c on 0 of %d cells: the bar cannot see the defect '
                     'that made the daemon learn an 8,213ms hold, so it is not a gate' % nc)
    if nc and ctrl['a_defect_red'] < 1:
        fails.append('B6-CTRL substituting the t_skip DEFECT for the derived observation turns '
                     'B6a RED on 0 gated cells: the bar cannot see the defect it exists to '
                     'catch, so it is not a gate')
    sys.stdout.flush()

    # ---------------- B4b spotty-share timeline ----------------
    print('=' * 118)
    print('B4b SPOTTY-SHARE TIMELINE (independent truncated-T reconstruction, load=0.95, %d seeds)'
          % TL_SEEDS)
    print('=' * 118)
    tl_tasks = [(si, archs, sch, sd, tt)
                for si, (t_, archs, c_) in enumerate(scen)
                for sch in TL_SCHEDS for sd in range(TL_SEEDS) for tt in CK]
    print('# timeline runs: %d' % len(tl_tasks), file=sys.stderr)
    cum = {}
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sch, sd, tt, a_sp, a_all) in ex.map(work_tl, tl_tasks, chunksize=4):
            cum.setdefault((si, sch, sd), {})[tt] = (a_sp, a_all)
            done += 1
            if done % 250 == 0:
                print('  ..tl %d/%d  (%.0fs)' % (done, len(tl_tasks), time.time() - t0),
                      file=sys.stderr)
    for si, (title, archs, chain) in enumerate(scen):
        print('  %s' % title)
        for sch in TL_SCHEDS:
            win = []
            for wi, tt in enumerate(CK):
                sp_d = all_d = 0
                for sd in range(TL_SEEDS):
                    cur = cum[(si, sch, sd)][tt]
                    prev = cum[(si, sch, sd)][CK[wi - 1]] if wi > 0 else (0, 0)
                    sp_d += cur[0] - prev[0]
                    all_d += cur[1] - prev[1]
                win.append(sp_d / all_d if all_d else 0.0)
            walk = all(win[i] <= win[i + 1] + 1e-9 for i in range(len(win) - 1))
            if sch == 'Dc' and walk:
                fails.append('B4b %s: Dc spotty-share WALKS UP monotonically: %s'
                             % (title, ' '.join('%.3f' % w for w in win)))
            print('    %-5s : %s   min=%.3f max=%.3f monotonic_up=%s -> %s'
                  % (sch, ' '.join('%.3f' % w for w in win), min(win), max(win),
                     walk, ('FAIL' if walk else 'PASS') if sch == 'Dc' else '-'))
    sys.stdout.flush()

    # ---------------- B5 scaling on the nested chain ----------------
    # U12: TWO offers.  LOADS[1] is the original (under-stresses the N=5 step --
    # N4-het's own nominal already exceeds it); LOADS[-1] puts the offer ABOVE
    # N4-het's nominal so the last step is a real capacity test.
    chain = [(t_, a_) for (t_, a_, c_) in scen if c_]
    nom5 = sum(a['base'] for a in chain[-1][1])
    nom4 = sum(a['base'] for a in chain[-2][1])
    offers = [(LOADS[1], LOADS[1] * nom5), (LOADS[-1], LOADS[-1] * nom5)]
    sc_tasks = [(ci * 10 + oi, archs, off, sch, sd)
                for oi, (fr_, off) in enumerate(offers)
                for ci, (t_, archs) in enumerate(chain)
                for sch in ('Dc', 'ewma') for sd in range(SEEDS)]
    print('# B5 runs: %d' % len(sc_tasks), file=sys.stderr)
    sres = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (key, sch, sd, m) in ex.map(work_scale, sc_tasks, chunksize=4):
            sres.setdefault(key, {}).setdefault(sch, []).append(m)
    for oi, (fr_, offer) in enumerate(offers):
        print('=' * 118)
        print('B5 SCALING -- nested chain, IDENTICAL absolute offer = %.2f x nominal(%s) = %.0f kb/s'
              % (fr_, chain[-1][0].split()[0], offer))
        print('   nominal(%s)=%d -> the N=%d member is at %.0f%% of its own nominal; '
              'the N=%d member at %.0f%%'
              % (chain[-2][0].split()[0], nom4, len(chain[-2][1]), 100.0 * offer / nom4,
                 len(chain[-1][1]), 100.0 * offer / nom5))
        if offer <= nom4:
            print('   *** the N=%d member is NOT over-subscribed at this offer -- the LAST step of'
                  % len(chain[-2][1]))
            print('   *** this chain is UNDER-STRESSED and its PASS is weak evidence (U12).')
        else:
            print('   (the motivating regime: EVERY smaller config, including the N=%d one, is'
                  % len(chain[-2][1]))
            print('    genuinely over-subscribed -- so the last step is a real capacity test.)')
        print('=' * 118)
        print('  %-46s %3s %9s %7s %6s %6s' % ('config (Dc)', 'N', 'gp', 'loss%', 'p95', 'p99'))
        prev = None
        for ci, (title, archs) in enumerate(chain):
            key = ci * 10 + oi
            g = med([d['gp'] for d in sres[key]['Dc']])
            l = med([d['loss'] for d in sres[key]['Dc']])
            p95 = med([d['p95'] for d in sres[key]['Dc']])
            p99 = med([d['p99'] for d in sres[key]['Dc']])
            mark = ''
            if prev is not None:
                up = g > prev[0]
                dn = l < prev[1]
                mark = '  dgp=%+.0f(%s) dloss=%+.2f(%s)' % (
                    g - prev[0], 'PASS' if up else 'FAIL',
                    l - prev[1], 'PASS' if dn else 'FAIL')
                if not up:
                    fails.append('B5 offer=%.0f %s: adding a source did NOT increase gp '
                                 '(%.0f -> %.0f)' % (offer, title, prev[0], g))
                if not dn:
                    fails.append('B5 offer=%.0f %s: adding a source did NOT reduce loss '
                                 '(%.2f%% -> %.2f%%)' % (offer, title, prev[1], l))
            print('  %-46s %3d %9.0f %7.2f %6.0f %6.0f%s'
                  % (title, len(archs), g, l, p95, p99, mark))
            prev = (g, l)
        print('  -- ewma (shipped cap) reference on the same chain, same offer --')
        for ci, (title, archs) in enumerate(chain):
            key = ci * 10 + oi
            print('  %-46s %3d %9.0f %7.2f'
                  % (title, len(archs),
                     med([d['gp'] for d in sres[key]['ewma']]),
                     med([d['loss'] for d in sres[key]['ewma']])))

    # ---------------- verdict ----------------
    print('=' * 118)
    print('VERDICT   (honest: bars are reported as measured; nothing was tuned)')
    print('=' * 118)
    if not fails:
        print('  ALL BARS PASS')
    else:
        print('  %d BAR FAILURE(S):' % len(fails))
        for f in fails:
            print('    FAIL  %s' % f)
    print('\nelapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
