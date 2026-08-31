#!/usr/bin/env python3
"""ladder_gate.py -- U39. The `ladder` job's gate, and its label.

WHY THIS EXISTS
===============
`ladder` carried `continue-on-error: true` from 2026-08-25 (`f6bdaa8`, added in
the same commit as a gofmt fix, justified as "P4 rate-share bars the EIF
datapath supersedes"). It therefore gated NOTHING for five days, and rotted: on
`dev` it scores 7-8/10 and nobody is ever made to resolve that. This script
replaces `continue-on-error` with an honest classification, so the job can be
FATAL without pretending its red stages are green.

WHAT `ladder` ACTUALLY MEASURES -- read this before reading the tick
====================================================================
It drives the **EIF PUSH** datapath, the design ADR-002 superseded. `pathsim.py`
launches only `AGG_MODE=server` and `AGG_MODE=client`; `AGG_MODE=pull-client`
exists only on the unmerged `u7-pull-core-go` branch. **No stage has ever
entered the shipped pull datapath.** ADR-002 RETAINS the push stack as the
validated reference and the mid-bufferbloat fallback, so this job is kept and
gated -- but labelled, exactly as `eif-model` is labelled for `nsched_model.py`
(docs/TEST-SUITE.md). A green run here says the PUSH REFERENCE still behaves as
recorded. It says nothing whatever about the pull datapath.

WHAT ROUND 3 CHANGED, AND WHY -- three demonstrated holes in round 2
====================================================================
Round 2 classified honestly and then failed to ENFORCE the classification. An
independent verifier demonstrated all three of these on a real runner.

  H1  SIX OF THE TWELVE GATED MAGNITUDE BARS COULD BE DILUTED TO VACUITY AND THE
      FATAL JOB STAYED GREEN. `S1.share <0.08 -> <0.95`, `S2.share >0.25 ->
      >0.001`, `S2b.deliv >=1800 -> >=1`, `S3.thr >=1.5 -> >=0.01`, `S4.tail
      >=392 -> >=1`, `S7.k {8,12} -> {8,12,20,0,-}`: all ten jobs green, with
      `delivered >= 1` printed next to its own `[min 2424 max 2640]` envelope.
      Cause: `recline()` returned the record's threshold text and it was thrown
      away into `_`. The gate printed pathsim's CURRENT threshold next to the
      record's envelope and never compared the two.
      FIX, and it is U8's control (`EXPECT['B3_vs_oracle']`) applied here --
      assert WHAT a bar is gated against, not only that it passed:
      `check_thresholds()` requires every emitted bar's printed `bar=` text to be
      BYTE-EQUAL to `ladder_record.txt`'s threshold column. Second, independent
      catch in `ladder_equiv_check.py`, which now compares the bar EXPRESSIONS
      structurally (by AST) against the frozen pre-refactor source instead of
      only by boolean outcome on the 14 recorded runs -- an outcome comparison is
      blind to any dilution that flips no recorded verdict, which is exactly why
      `lossbar` (compared numerically) was protected and every other bar was not.

  H2  THE CLASS RULE WAS DOCUMENTED AND NOT ENFORCED. Moving `S3.thr` from GATED
      to UNGATED with a fabricated `"9/14"` (the record says 14/14) passed all 26
      self-checks, and a failing `S3.thr` then exited 0. `main()` validated only
      that a classified bar APPEARED in the record; it never read the count.
      FIX: `check_classes()` derives the class from the record's pass count and
      requires the declared class to equal it -- 14/14 GATED, 0/14 KNOWN_FAIL,
      between UNGATED -- fatally. And the counts themselves are no longer
      hand-written: `ladder_equiv_check.py` recomputes every column of
      `ladder_record.txt` from `ladder_ci_runs.json` through pathsim's own
      source and fails if the file disagrees, so the count cannot be fabricated
      either.

  H3  KNOWN_FAIL AND UNGATED BARS HAD NO FLOOR IN EITHER DIRECTION. They were
      printed and never tested; only GATED appended to `regressions`. A stub with
      `S2.tail=0/1900`, `S3.peerloss=100%`, `S2/S6/S7/S8 loss 93-99%`, `S6.k=0`
      exited 0 with "32 gated bars hold".
      FIX: a fatal DRIFT band on EVERY bar, derived from the recorded values and
      not from any threshold (`ladder_replay.band`): `[min-(max-min),
      max+(max-min)]`, two-sided, `min == max` meaning no band is derivable
      rather than a band of width zero. Two-sided on purpose -- a value far
      outside on the "good" side is evidence the measurement broke, not that the
      push reference improved, and it is what catches a vacuous stub.
      Its false-positive rate is MEASURED, not asserted, and round 3 overstated
      the measurement in this very docstring. It shipped "14/14 inside on 16 of
      16 bars with a derivable band, 0 exclusions". The code never compared 224
      hold-outs: `ladder_equiv_check.py` SKIPS a hold-out whose remaining values
      have no spread (3 of 224 on the 14-run record) and the run printed `221
      compared`. Worse, a hold-out that is neither the unique min nor the unique
      max leaves the band unchanged and is inside by construction -- only 25 of
      those 221 could ever have failed, and S5.loss, S6.k and S7.k contributed
      ZERO of them. S5.loss is the bar whose whole band rested on one 0.1
      observation among thirteen 0.0s, and it is the bar that then reddened this
      fatal job (1.70%, mirror run 33336749301). The aggregate zero was hiding
      that three bars were being counted as evidence while testing nothing.
      FIX: `ladder_replay.loo()` reports compared / informative / excluded /
      skipped PER BAR, those four numbers are a COLUMN of `ladder_record.txt`,
      and `ladder_equiv_check.py` check (4) fails if the recomputation disagrees
      with the file. The false-positive rate is now published, not asserted, and
      it is not zero.

THE THREE CLASSES, AND THE ONE RULE THAT PARTITIONS THEM
========================================================
Baseline: **69 `ladder` runs**, recorded bar by bar in
`p4-bondagg/sim/ladder_record.txt` (run ids, repos and branches in
`ladder_ci_runs.json`). This gate READS that file, refuses to classify a bar the
record does not cover, AND refuses to run if a declared class disagrees with the
record's own pass count.

**The partition is by MEASURED REPRODUCIBILITY on that record, and by nothing
else.** den/den -> GATED. 0/den -> KNOWN_FAIL. Anything between -> UNGATED.

WHICH RUNS ARE IN THE RECORD, AND WHY IT IS A RULE AND NOT A WINDOW
==================================================================
Round 3 recorded "14 consecutive runs on `dev`". That window was a CHOICE, and
the choice mattered: `gh run list -R mmakki-ui/bond -b dev -L 200` lists **67**
`emulator-gate` runs whose `p4-bondagg/daemon` tree is `f9eb0608` and whose
`pathsim.py` blob is `22b78825` -- the same two objects the 14 ran -- going back
to 2026-08-25 21:18Z. Fifty-three qualifying runs were left out, and the bars
that looked 14/14 inside that window are not all den/den over the population.

The inclusion rule is now stated and applied mechanically:

    a run enters the record iff its `p4-bondagg/daemon` tree is `f9eb0608`
    AND its `pathsim.py` bars are structurally identical to the frozen base
    AND its `ladder` job printed all ten stage lines and all ten verdicts.

That admits 60 `dev` runs (7 of the 67 printed no stage lines at all -- the
private repo's Actions minutes ran out at 11:58Z on 2026-08-30 and those jobs
died with zero steps) and 9 runs of this branch on the public mirror. Measured,
not assumed: the mirror runs ran `pathsim.py` blobs `d0d517ce` / `d9e435d1` /
`fa1023c6`, and `diff` of the LF-normalized files puts the last two ONE COMMENT
LINE from the first (a ROADMAP task id). The `dev` runs ran the pre-refactor
`22b78825`, whose equivalence is not assumed either -- it is the frozen base
`ladder_equiv_check.py` compares against structurally (30/0), by outcome
(690/0) and by stage verdict (690/0) on every CI run.

It EXCLUDES, for stated reasons rather than by omission: the dilution branches
(`u39-dilution-control`, `u39-dilution-probe` -- their bars differ, which IS the
dilution) and every other unit's feature branch (sampled: `p4-bondagg/daemon` is
`cc13438b` / `ee0b9b13` / `292491aa` there, not `f9eb0608`, so they are a
different measurement subject).

`origin/dev`'s daemon tree is itself now `cc13438b`, not the recorded
`f9eb0608`. The delta is U7's pull core and it is ADDITIVE: `git diff f9eb0608
cc13438b` is five new files plus a 6-line `main.go` hunk adding an
`AGG_MODE=pull-client` case; the `client` and `server` dispatch this harness
uses is untouched (one deleted line, an error string). So the record still
describes the subject -- but that is a measured claim about a DIFF, not about a
run, and re-measuring it after the merge is exactly what this unit's own rule
asks for.

GATED (31)      -- held on every recorded run, so a threshold failure is a CHANGE
                   IN BEHAVIOUR of the push reference. Fails the job.
KNOWN_FAIL (2)  -- an HONEST, PERSISTENT fail: 0/69. Reported every run, never
                   weakened, never tuned away. Same shape as `eif-model`
                   tolerating its documented N5H FAIL and `rig-paired` carrying
                   `BASELINE_FAILS`. Adding a bar here to go green is weakening
                   a bar; only a MEASURED 0/den belongs.
UNGATED (7)     -- FLIPPED on the record: 28/69, 28/69, 48/69, 58/69, 59/69,
                   63/69, 67/69. A demonstration that the bar is not reproducible
                   at its current threshold; the cause is structural, since this
                   harness spawns real Go daemons over loopback and
                   PYTHONHASHSEED pins the shim's draws but pins NOTHING about
                   wall-clock scheduling. Its THRESHOLD is not gated and is not
                   widened either.

**"UNGATED" means "not gated AT ITS THRESHOLD". It does not mean unchecked:**
every UNGATED and KNOWN_FAIL bar carries the fatal DRIFT band above, which is
the floor H3 was about.

A bar id in no class is a HARD FAIL. New bars must be classified deliberately.

S5.loss MOVED GATED -> UNGATED, AND THAT IS A LOSS OF COVERAGE
==============================================================
Round 3 shipped `S5.loss` GATED on 14/14 and the fatal job then **reddened on a
clean tree**: mirror run 33336749301, `S5.loss value=1.70% bar=loss <= 1.00%`,
with a DRIFT on top of it (band `[-0.1, 0.2]`). Four further runs of the
byte-identical tree were green (`gh api repos/mmakki-ui/bond-ci/commits/16ece69`
and `.../a82931d` both resolve to tree `fc7e97d`), so the shipped state was a
FATAL job with a ~20% clean-tree red.

The response is the one this file PRE-REGISTERED for exactly this event: a red
is a MEASUREMENT that the bar is not reproducible, answered by re-measuring the
record and moving the class BY THE RULE -- never by widening the threshold. On
the 69-run record `S5.loss` is **67/69**, so the rule makes it UNGATED. Its
threshold `loss <= 1.00%` is UNCHANGED, still printed, still reported every run.

Three things are said plainly rather than absorbed:

  * This is LESS coverage, not a fix. `S5` now has NO threshold-gated magnitude
    bar at all; it is carried by its DRIFT band alone (`[-1.7, 3.4]`, from
    measured 0..1.7). The run prints per-stage magnitude coverage so this cannot
    quietly become untrue.
  * The band is WIDER because the true spread is wider than 14 runs showed. That
    is the cost of the small window, not a tolerance anyone chose.
  * The excursion is NOT root-caused. S5 normally loses 0-1 frames of 1000; the
    two failing runs lost 17 (mirror 33336749301) and 14 (dev 33028285498).
    Nothing here explains why. **U39e stays
    open**, and this is the only honest place for it: the unit can say the bar is
    not reproducible; it cannot say why.

The anti-bias rule that makes this a re-measurement and not a laundry: the record
takes EVERY run the inclusion rule admits -- 69 of them, including both failing
S5 runs and every run that has ever failed any other bar. Appending only a
failing run, or only green ones, is forbidden and is what "re-measure" must never
be allowed to mean.

WHAT IS ACTUALLY GATED -- the honest count, because "31" overstates it
=====================================================================
"31 bars GATED" is true as a count of classified ids and materially overstates
the behavioural coverage. Enumerated:

  31 GATED = 10 `*.order` + 10 `*.dup` + 11 magnitude bars.
  The 10 `*.dup` bars are REDUNDANT by this unit's own proof: `dup` can never
  fail while `order` passes (the order scan requires a STRICT increase, which
  forces distinctness -- exhaustive over every sequence of length <= 6 over
  {0..3}: 5460 sequences, 0 with dup>0 and inorder=True. Including the empty
  sequence that enumeration is 5461; the claim holds either way, and at every
  length, because strict increase forces distinctness at any length).
  So: **21 independent threshold-gated bars -- 10 ordering, 11 magnitude.**

Per-stage MAGNITUDE coverage is DERIVED from the declarations and the record and
PRINTED by every run (`magnitude_cover()`), so a class move cannot silently empty
a stage. On this record:

  threshold-gated magnitude bars   S1 2 . S2 1 . S2b 2 . S3 2 . S4 2 . S5 0 .
                                   S6 0 . S7 1 . S8 0 . S9 1          = 11
  + fatal DRIFT band               S1 0 . S2 3 . S2b 2 . S3 4 . S4 0 . S5 1 .
                                   S6 2 . S7 2 . S8 1 . S9 1          = 16
  ---------------------------------------------------------------------------
  stages with NO fatal magnitude check of either kind                 : none
  stages with NO threshold-gated magnitude bar         : S5, S6, S8 (round 3
                                                         claimed none)

The 11 threshold-gated magnitude bars are ABSOLUTE thresholds --

    S1.loss  <= 0.50%   S2b.loss <= 50.00%  S3.loss <= 55.00%
    S4.loss  <= 12.00%  S9.loss  <= 45.00%
    S1.share  S2.share  S2b.deliv  S3.thr  S4.tail  S7.k

-- so absoluteness is not what puts a bar in UNGATED; instability on the record
is. They are gated as **regression tripwires of this harness against its own
recorded behaviour**, not as claims the magnitudes are physically right. Nothing
here asserts that S3 losing 40% of frames is acceptable; it asserts that S3 lost
34.3-40.23% on all 69 recorded runs against a bar sitting at 55%. ADR-004's
prohibition is on treating an unanchored simulator's absolute number as TRUTH,
which this does not do.

The honest cost: several GATED bars carry slack that means nothing physically --
S2b.loss 50% vs observed 22.35-31.35%, S3.loss 55% vs 34.3-40.23%, S9.loss 45%
vs 20.18-29.36%. The DRIFT band is what now covers that slack, and every run
prints both.

MARGIN vs SPREAD -- den/den is not reproducibility, and this unit says so
========================================================================
A bar that passed 69/69 by a hair is not established; a bar that passed by ten
spreads is. The run prints, for every bar with a derivable spread,
`margin = |threshold - nearest observed value|` and `margin/spread`. Two GATED
bars are fragile by that measure and are named rather than quietly gated:

  * `S3.thr`  bar 1.50 Mb vs recorded min 1.56 -- margin 0.06 on a spread of
    0.40, i.e. **0.15 spreads** (4% of the bar).
  * `S7.k`  enumerated `K in {8,12}` against observed values {8, 12}: the bar
    admits EXACTLY the observed set, so its margin is **zero** by construction,
    and its hold-out column reads `informative 0` -- 69 hold-outs, not one of
    which could ever have failed. It is 69/69 only because a legacy bar happens
    to admit both values its tier controller produced; the controller
    demonstrably flips (K=12 on runs 33309669280 and 33301987287). Compare
    `S6.k`, which is `K == 20`, flips the same way, and is therefore 63/69 and
    UNGATED. **The class rule is threshold-relative, not property-relative**, and
    these two bars are the demonstration.

Pre-registered, and now with a worked example (S5.loss above): if `S3.thr` or
`S7.k` reds, that is a MEASUREMENT that the bar is not reproducible, and the
response is to re-measure the record over EVERY qualifying run and move the bar's
class by the rule -- never to widen the threshold, and never to append the
failing run alone.

WHAT THIS GATE DOES **NOT** DO
==============================
- It does not gate the seven UNGATED bars at their THRESHOLDS, and it does not
  widen them either. Either move needs a defensible envelope; 69 runs fix a RANGE
  and still not a distribution, and widening a bar to the observed max is fitting
  a threshold to the sample, which is tuning a bar to go green by another name.
  The concrete argument is in the record itself: the 14-run window's maxima were
  exceeded by later runs on SIX bars once the population was collected
  (S6.loss 1.70 -> 2.60, S8.loss 4.23 -> 4.63, S7.loss 3.83 -> 4.43,
  S3.peerloss 33 -> 39, S2.loss 8.43 -> 9.43, S5.loss 0.10 -> 1.70). An observed
  max is not a bound. U39a.
- Four GATED bars have NO derivable drift band because the record shows no spread
  at all over 69 runs (S1.loss, S1.share, S4.loss, S4.tail -- min == max). Named
  non-coverage: they are carried by their threshold alone. A stub that sets each
  of them to its threshold constant passes; that is demonstrated, not assumed
  (`test_ladder_gate.py`).
- The hold-out column is not a licence. Three bars (S6.k, S7.k, and S5.loss on
  the 14-run record) have `informative 0` -- every hold-out left the band where
  it was, so their bands have never been tested by the false-positive
  measurement, whatever the aggregate says.
- The DRIFT band is a gross-change tripwire. It will not catch a regression
  smaller than the observed spread.
- `*.dup` can never fail while `*.order` passes (proof above), so the dup bars
  are redundant tripwires, not 10 independent gates.
- The frozen-base pin in `ladder_equiv_check.py` is NOT an anchor outside this
  tree: in CI the git cross-check is SKIPPED (the mirror is a single force-pushed
  commit), so the pin verifies the file against a hash committed beside it. Any
  single commit touching both defeats it, INCLUDING a well-meant "regenerate the
  baseline". What is genuinely independent of that is the DRIFT band, which is
  derived from measured values and moves with none of it.
- Nothing here has ever run on hardware.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SIMDIR = os.path.join(ROOT, "p4-bondagg", "sim")
sys.path.insert(0, SIMDIR)
import ladder_replay as LR  # noqa: E402  (path must be set first)

RECORD = os.path.join(SIMDIR, "ladder_record.txt")
STAGES = LR.STAGES

# The exact bar id set each stage must emit. A stage that emits a different set
# means pathsim.py changed and this gate has not been re-derived -> hard fail,
# rather than silently gating a subset.
EXPECT = {
    "S1":  {"order", "dup", "loss", "share"},
    "S2":  {"order", "dup", "loss", "share", "tail"},
    "S2b": {"order", "dup", "loss", "deliv"},
    "S3":  {"order", "dup", "loss", "thr", "rate", "peerloss"},
    "S4":  {"order", "dup", "loss", "tail"},
    "S5":  {"order", "dup", "loss"},
    "S6":  {"order", "dup", "loss", "k"},
    "S7":  {"order", "dup", "loss", "k"},
    "S8":  {"order", "dup", "loss"},
    "S9":  {"order", "dup", "loss"},
}

GATED = (
    [f"{s}.order" for s in STAGES] + [f"{s}.dup" for s in STAGES] +
    ["S1.loss", "S2b.loss", "S3.loss", "S4.loss", "S9.loss"] +
    ["S1.share", "S2.share", "S2b.deliv", "S3.thr", "S4.tail", "S7.k"]
)

KNOWN_FAIL = {
    # bar          why it is an honest fail rather than a regression
    "S2.tail":     "0/69. Best recorded 1849/1900 = 97.3% against a 98.5% bar. The "
                   "push stack's post-ramp delivery never reaches it: loss continues "
                   "through steady state, it is not a startup transient. Design-"
                   "INDEPENDENT bar -- a real behavioural fail of the retained push "
                   "reference, not an artifact of the pivot. U39b.",
    "S3.peerloss": "0/69 at 17.0-39.0% against a 3.0% bar, off by 6-13x. Reads the "
                   "PUSH LOSS METER, which ADR-002 deleted along with the FEC tier "
                   "controller. Describes the retained reference only. U39c.",
}

# The six bars measured as not reproducible AT THEIR THRESHOLD. Every one of them
# still carries the fatal DRIFT band; "ungated" is about the threshold only.
UNGATED = ["S2.loss", "S3.rate", "S5.loss", "S6.loss", "S6.k", "S7.loss", "S8.loss"]

# S2.loss and S2.tail are ONE measurement split across two classes, and that has
# to be stated where the classes are declared rather than buried in a report.
# Measured over the 69 runs: Pearson r = -0.9797 between S2's loss% and its
# tail900 count; the packets lost OUTSIDE the scored tail window
# ((npkts-fwd) - (1900-tail900)) are 25.9 +- 8.1 (sample sd, n=69, range 15..80),
# i.e. the ramp loss that is not part of the scored tail. They are the same
# physical quantity seen twice. Round 2 left one KNOWN_FAIL and the other
# UNGATED, so S2's loss magnitude was bounded by nothing at all -- the concrete
# form of the laundering risk. The classification is NOT changed (the rule is
# reproducibility on the record, and changing a class by judgement is exactly the
# laundering the rule exists to prevent); what changed is that both now carry the
# fatal DRIFT band, so S2's loss magnitude is bounded in both directions again.
# The 14-run r of -0.9968 was the small window flattering the relationship; over
# the population it is -0.9797, which is the number to quote.
COUPLED = {("S2.loss", "S2.tail"): "Pearson r = -0.9797 over the 69 runs; one measurement, two bars"}


def die(msg, code=1):
    print("\nFAIL(gate): " + msg)
    sys.exit(code)


def classes():
    """bar -> declared class name."""
    out = {b: "GATED" for b in GATED}
    out.update({b: "KNOWN_FAIL" for b in KNOWN_FAIL})
    out.update({b: "UNGATED" for b in UNGATED})
    return out


def class_from_record(row):
    """The class the record's own pass count dictates. THE rule, in one place."""
    if row["passes"] == row["den"]:
        return "GATED"
    if row["passes"] == 0:
        return "KNOWN_FAIL"
    return "UNGATED"


def check_classes(rec, declared):
    """H2. Every declared class must equal the class the record's count dictates."""
    errs = []
    for bar, cls in sorted(declared.items()):
        row = LR.rec_for(rec, bar)
        if row is None:
            errs.append("%s is classified %s but has NO row in ladder_record.txt"
                        % (bar, cls))
            continue
        want = class_from_record(row)
        if want != cls:
            errs.append("%s is declared %s but the record says %d/%d -> %s. The class "
                        "rule is the record's pass count and nothing else; a class "
                        "moved by hand is how a failing bar stops failing the job."
                        % (bar, cls, row["passes"], row["den"], want))
    return errs


def check_thresholds(rec, bars, declared):
    """H1. The printed threshold must be BYTE-EQUAL to the recorded one."""
    errs = []
    for bar in sorted(bars):
        if bar not in declared:
            continue                      # reported separately as UNCLASSIFIED
        row = LR.rec_for(rec, bar)
        if row is None:
            continue                      # reported by check_classes
        got = bars[bar][2]
        if got != row["threshold"]:
            errs.append("%s is gated against %r but the record was measured against "
                        "%r. The bar was CHANGED, not the behaviour. Re-measure the "
                        "record and say what changed; do not print a new threshold "
                        "next to an old envelope." % (bar, got, row["threshold"]))
    return errs


def drift(row, value_str):
    """(verdict, description). verdict is 'ok' | 'DRIFT' | 'none'."""
    v = LR.num(value_str)
    if row["tokens"] is not None:
        if value_str in row["tokens"]:
            return "ok", "in tokens {%s}" % ",".join(row["tokens"])
        return "DRIFT", "%r not in recorded tokens {%s}" % (value_str, ",".join(row["tokens"]))
    b = LR.band(row["lo"], row["hi"])
    if b is None:
        return "none", "no band: record spread is 0 (min == max == %s)" % LR.fmt(row["lo"])
    if v is None:
        return "DRIFT", "value %r is not numeric but the record is" % value_str
    lo, hi = b
    if lo - 1e-9 <= v <= hi + 1e-9:
        return "ok", "band [%s, %s]" % (LR.fmt(lo), LR.fmt(hi))
    return "DRIFT", "value %s outside band [%s, %s] (recorded %s..%s)" % (
        LR.fmt(v), LR.fmt(lo), LR.fmt(hi), LR.fmt(row["lo"]), LR.fmt(row["hi"]))


def margin(row):
    """gap/spread for a bar, or the reason it has none. Reported, never gated.

    gap = |threshold - nearest recorded value|. For a den/den bar that is its
    MARGIN; for a 0/den bar it is its SHORTFALL. Divided by the recorded spread it
    answers the question den/den does not: is this bar established, or did it pass
    every recorded time by less than the noise? `S3.thr` reads 0.15 spreads over
    69 runs and `S7.k` reads 0.00.
    """
    if row["tokens"] is not None:
        return "enumerated over {%s}" % ",".join(row["tokens"])
    const = LR.bar_const(row["threshold"])
    spread = row["hi"] - row["lo"]
    if const is None:
        return "no numeric constant in the bar"
    near = min((row["lo"], row["hi"]), key=lambda x: abs(x - const))
    m = abs(near - const)
    word = "margin" if row["passes"] == row["den"] else (
        "shortfall" if row["passes"] == 0 else "gap")
    if spread == 0:
        return "%s %s, no spread on the record" % (word, LR.fmt(m))
    return "%s %s / spread %s = %.2f spreads" % (word, LR.fmt(m), LR.fmt(spread), m / spread)


def magnitude_cover(rec, declared):
    """Per-stage magnitude coverage, DERIVED. Round 3 PRINTED this as a constant
    string ("every stage S1..S9 now has at least one FATAL magnitude check") and
    then moved a class, which would have made the printed line false while the
    job stayed green. Nothing here is typed twice: the counts come from the
    declarations and the record.

    A magnitude bar is any classified bar that is not `*.order`/`*.dup`. It has
    THRESHOLD cover if it is GATED, and BAND cover if the record gives it a
    derivable drift band.
    """
    gated, banded = {}, {}
    for bar, cls in declared.items():
        suffix = bar.split(".", 1)[1]
        if suffix in ("order", "dup"):
            continue
        st = bar.split(".", 1)[0]
        row = LR.rec_for(rec, bar)
        gated.setdefault(st, [])
        banded.setdefault(st, [])
        if cls == "GATED":
            gated[st].append(bar)
        if row is not None and row["tokens"] is None and LR.band(row["lo"], row["hi"]):
            banded[st].append(bar)
    return gated, banded


def print_magnitude_cover(rec, declared):
    gated, banded = magnitude_cover(rec, declared)
    ng = sum(len(v) for v in gated.values())
    nb = sum(len(v) for v in banded.values())
    print("  per-stage MAGNITUDE coverage, derived from the declarations and the record:")
    print("    threshold-gated  " + " ".join("%s %d" % (st, len(gated.get(st, [])))
                                             for st in STAGES) + "   = %d" % ng)
    print("    fatal DRIFT band " + " ".join("%s %d" % (st, len(banded.get(st, [])))
                                             for st in STAGES) + "   = %d" % nb)
    no_thr = [st for st in STAGES if not gated.get(st)]
    none_at_all = [st for st in STAGES if not gated.get(st) and not banded.get(st)]
    print("    stages with NO threshold-gated magnitude bar : %s"
          % (", ".join(no_thr) or "none"))
    print("    stages with NO magnitude check of either kind: %s"
          % (", ".join(none_at_all) or "none"))
    return none_at_all


def show(bar, ok, val, txt, row):
    dv, dd = drift(row, val)
    print("  %-12s %-4s value=%-10s %-26s baseline %d/%d  [%s]"
          % (bar, "PASS" if ok else "FAIL", val, txt, row["passes"], row["den"], row["env"]))
    print("      drift %-5s %-46s  %s" % (dv, dd, margin(row)))
    return dv


def main():
    # Pinned config, checked rather than assumed: pathsim seeds each scenario off
    # hash(name), so an unpinned PYTHONHASHSEED changes the shim's loss draws and
    # the baseline in ladder_record.txt no longer describes this run.
    if os.environ.get("PYTHONHASHSEED") != "0":
        die("PYTHONHASHSEED=%r, baseline was measured at '0'. Refusing to compare "
            "against a record measured elsewhere." % os.environ.get("PYTHONHASHSEED"), 2)

    if not os.path.exists(RECORD):
        die("baseline record missing: %s" % RECORD, 2)
    try:
        rec = LR.load_record(RECORD)
    except AssertionError as e:
        die(str(e), 2)

    declared = classes()
    dup = sorted(set(GATED) & (set(KNOWN_FAIL) | set(UNGATED))) + \
        sorted(set(KNOWN_FAIL) & set(UNGATED))
    if dup:
        die("bar(s) declared in more than one class: %s" % ", ".join(dup), 2)

    # H2 -- the class rule, enforced against the record BEFORE anything runs.
    cerrs = check_classes(rec, declared)
    if cerrs:
        for e in cerrs:
            print("  CLASS: " + e)
        die("class rule violated (%d problem(s)). den/den -> GATED, 0/den -> "
            "KNOWN_FAIL, between -> UNGATED. Re-measure the record over EVERY "
            "qualifying run and move the class by the rule; do not re-declare."
            % len(cerrs), 2)

    print("=" * 78)
    print("ladder gate -- EIF PUSH REFERENCE (ADR-002-superseded design), NOT the")
    print("shipped pull datapath. pathsim launches AGG_MODE=server|client only.")
    dens = sorted({LR.rec_for(rec, b)["den"] for b in declared
                   if LR.rec_for(rec, b) is not None
                   and not b.endswith((".order", ".dup"))})
    print("Baseline: %s runs, p4-bondagg/sim/ladder_record.txt (run ids, repos and"
          % ("/".join(str(d) for d in dens)))
    print("branches in p4-bondagg/sim/ladder_ci_runs.json; inclusion rule in the")
    print("ladder_gate.py docstring -- it is a rule, not a window)")
    print("Class rule checked against the record's own pass counts: %d bars OK."
          % len(declared))
    print("=" * 78)
    sys.stdout.flush()

    # STREAM rather than capture. pathsim takes minutes and the job carries a step
    # timeout; buffering its stdout would mean a timeout kill produces an EMPTY
    # log, which is worse than the non-fatal job this replaces. Lines are echoed
    # as they arrive AND collected for classification.
    proc = subprocess.Popen([sys.executable, "-u", "pathsim.py"], cwd=SIMDIR,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    lines = []
    for ln in proc.stdout:
        sys.stdout.write(ln)
        sys.stdout.flush()
        lines.append(ln)
    rc = proc.wait()
    out = "".join(lines)

    # pathsim exits 0 (all stages pass) or 1 (any stage failed). Its exit code is
    # ADVISORY here -- this gate decides. Anything else (signal, import error,
    # unhandled exception) is a harness failure and must not read as green.
    if rc not in (0, 1):
        die("pathsim exited %d -- harness failure, not a bar verdict." % rc, 2)

    bars = LR.bars_of(out)

    # ---- structure: a run that died mid-way must not read green -------------
    errs = []
    for st in STAGES:
        got = {k.split(".", 1)[1] for k in bars if k.split(".", 1)[0] == st}
        if got != EXPECT[st]:
            errs.append("stage %s emitted bars %s, expected %s"
                        % (st, sorted(got) or "NONE", sorted(EXPECT[st])))
    if not re.search(r"^== LADDER: \d+/10 PASS ==$", out, re.M):
        errs.append("no '== LADDER: n/10 PASS ==' summary line -- pathsim did not finish")
    unknown = sorted(set(bars) - set(declared))
    if unknown:
        errs.append("UNCLASSIFIED bar id(s): %s -- classify them in ladder_gate.py "
                    "deliberately; this gate fails closed rather than skip a bar"
                    % ", ".join(unknown))
    # H1 -- what each bar is gated AGAINST, not just whether it passed.
    errs += check_thresholds(rec, bars, declared)
    if errs:
        for e in errs:
            print("  STRUCTURE: " + e)
        die("structure check failed (%d problem(s))" % len(errs), 2)

    # ---- verdict ------------------------------------------------------------
    regressions, drifts = [], []

    print()
    print("-" * 78)
    n_mag = len(GATED) - 2 * len(STAGES)
    print("GATED -- passed on EVERY recorded run; a threshold failure here fails the job.")
    print("%d classified ids = %d order + %d dup + %d magnitude, and the dup bars are"
          % (len(GATED), len(STAGES), len(STAGES), n_mag))
    print("REDUNDANT (dup cannot fail while order passes; proof in the docstring)")
    print("-> %d independent gated bars: %d ordering, %d magnitude. All %d magnitude"
          % (len(GATED) - len(STAGES), len(STAGES), n_mag, n_mag))
    print("bars are ABSOLUTE thresholds, gated as regression tripwires of this harness")
    print("against its own record -- NOT as claims the magnitudes are right. Some carry")
    print("large dead slack, which is why the DRIFT band below is also fatal.")
    print("-" * 78)
    for b in sorted(GATED):
        ok, val, txt = bars[b]
        row = LR.rec_for(rec, b)
        if show(b, ok, val, txt, row) == "DRIFT":
            drifts.append((b, val, row))
        if not ok:
            regressions.append((b, val, txt, row))

    print()
    print("-" * 78)
    print("KNOWN HONEST FAIL -- measured 0/den on the push reference. Reported, never")
    print("weakened. These are the two stages that make ladder a standing red. Their")
    print("THRESHOLD is not gated; their DRIFT band is, and it is fatal.")
    print("-" * 78)
    for b in sorted(KNOWN_FAIL):
        ok, val, txt = bars[b]
        row = LR.rec_for(rec, b)
        if show(b, ok, val, txt, row) == "DRIFT":
            drifts.append((b, val, row))
        print("      %s" % KNOWN_FAIL[b].replace("\n", " "))
        if ok:
            print("      NOTE: this bar PASSED. That is an improvement, not a failure. If it")
            print("      holds across a re-measured record, move it to GATED.")

    print()
    print("-" * 78)
    ung = ", ".join("%s %d/%d" % (b, LR.rec_for(rec, b)["passes"], LR.rec_for(rec, b)["den"])
                    for b in sorted(UNGATED))
    print("UNGATED AT THEIR THRESHOLD -- bars that FLIPPED on the record, i.e. measured")
    print("as not reproducible at their current threshold. NOT ungated for being")
    print("absolute -- every gated magnitude bar is absolute too. Neither gated nor")
    print("widened: the record fixes a range, not a distribution (U39a). They are NOT")
    print("unchecked: the DRIFT band below is fatal for each.")
    print("  " + ung)
    print("-" * 78)
    for b in sorted(UNGATED):
        ok, val, txt = bars[b]
        row = LR.rec_for(rec, b)
        if show(b, ok, val, txt, row) == "DRIFT":
            drifts.append((b, val, row))

    for (a, c), why in COUPLED.items():
        print()
        print("  COUPLED: %s and %s -- %s." % (a, c, why))
        print("           Classified separately by the rule; both carry the fatal DRIFT")
        print("           band, so S2's loss magnitude is bounded in both directions.")

    print()
    print("=" * 78)
    if regressions:
        for b, val, txt, row in regressions:
            print("  REGRESSION  %s  value=%s  bar=%s  (baseline %d/%d)"
                  % (b, val, txt, row["passes"], row["den"]))
    for b, val, row in drifts:
        print("  DRIFT       %s  value=%s  %s" % (b, val, drift(row, val)[1]))
    if regressions or drifts:
        die("%d GATED bar(s) regressed, %d bar(s) drifted outside their recorded "
            "envelope. Do not add a bar to KNOWN_FAIL and do not widen a band to go "
            "green -- both are weakening a bar. Fix the cause, or record a NEW "
            "measured baseline (regenerate ladder_ci_runs.json) and say what changed."
            % (len(regressions), len(drifts)))

    unbanded = sorted(b for b in declared
                      if drift(LR.rec_for(rec, b), bars[b][1])[0] == "none")
    print("  ladder gate PASS")
    print("    %2d classified bars: %d GATED, %d KNOWN HONEST FAIL, %d UNGATED-at-threshold"
          % (len(declared), len(GATED), len(KNOWN_FAIL), len(UNGATED)))
    print("    %2d of the GATED ids are independent (10 dup bars are redundant with order)"
          % (len(GATED) - len(STAGES)))
    print("    %2d threshold-gated magnitude bars" % (len(GATED) - 2 * len(STAGES)))
    print_magnitude_cover(rec, declared)
    nb_dup = [b for b in unbanded if b.endswith(".dup")]
    nb_real = [b for b in unbanded if not b.endswith(".dup")]
    print("    %2d bars carry a fatal DRIFT band; %d have none because the record shows"
          % (len(declared) - len(unbanded), len(unbanded)))
    print("       no spread at all: the %d redundant *.dup bars, and %d GATED bars"
          % (len(nb_dup), len(nb_real)))
    print("       that are named non-coverage: %s" % ", ".join(nb_real))
    print("  This is a statement about the PUSH REFERENCE, and about nothing else.")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())
