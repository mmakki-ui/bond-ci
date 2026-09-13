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
      Its false-positive rate is MEASURED, not asserted: leave-one-out over the
      record (band from 13 runs, test the 14th) is 14/14 inside on 16 of 16 bars
      with a derivable band, 0 exclusions, re-checked every CI run by
      `ladder_equiv_check.py`.

THE THREE CLASSES, AND THE ONE RULE THAT PARTITIONS THEM
========================================================
Baseline: 14 consecutive `ladder` runs on `dev`, 2026-08-30, recorded bar by bar
in `p4-bondagg/sim/ladder_record.txt` (run ids in that file). This gate READS
that file, refuses to classify a bar the record does not cover, AND refuses to
run if a declared class disagrees with the record's own pass count.

**The partition is by MEASURED REPRODUCIBILITY on that record, and by nothing
else.** 14/14 -> GATED. 0/14 -> KNOWN_FAIL. Anything between -> UNGATED.

GATED (32)      -- held on every recorded run, so a threshold failure is a CHANGE
                   IN BEHAVIOUR of the push reference. Fails the job.
KNOWN_FAIL (2)  -- an HONEST, PERSISTENT fail: 0/14. Reported every run, never
                   weakened, never tuned away. Same shape as `eif-model`
                   tolerating its documented N5H FAIL and `rig-paired` carrying
                   `BASELINE_FAILS`. Adding a bar here to go green is weakening
                   a bar; only a MEASURED 0/14 belongs.
UNGATED (6)     -- FLIPPED on the record: 6/14, 9/14, 9/14, 13/14, 13/14, 13/14.
                   A demonstration that the bar is not reproducible at its
                   current threshold; the cause is structural, since this harness
                   spawns real Go daemons over loopback and PYTHONHASHSEED pins
                   the shim's draws but pins NOTHING about wall-clock scheduling.
                   Its THRESHOLD is not gated and is not widened either.

**"UNGATED" now means "not gated AT ITS THRESHOLD". It does not mean unchecked:**
since round 3 every UNGATED and KNOWN_FAIL bar carries the fatal DRIFT band
above, which is the floor H3 was about.

A bar id in no class is a HARD FAIL. New bars must be classified deliberately.

WHAT IS ACTUALLY GATED -- the honest count, because "32" overstates it
=====================================================================
"32 bars GATED" is true as a count of classified ids and materially overstates
the behavioural coverage. Enumerated:

  32 GATED = 10 `*.order` + 10 `*.dup` + 12 magnitude bars.
  The 10 `*.dup` bars are REDUNDANT by this unit's own proof: `dup` can never
  fail while `order` passes (the order scan requires a STRICT increase, which
  forces distinctness -- exhaustive over every sequence of length <= 6 over
  {0..3}: 5460 sequences, 0 with dup>0 and inorder=True).
  So: **22 independent threshold-gated bars -- 10 ordering, 12 magnitude.**

Per-stage MAGNITUDE coverage, which is the number that matters and which round 2
did not print:

  threshold-gated magnitude bars   S1 2 · S2 1 · S2b 2 · S3 2 · S4 2 · S5 1 ·
                                   S6 0 · S7 1 · S8 0 · S9 1          = 12
  + fatal DRIFT band (round 3)     S1 0 · S2 3 · S2b 2 · S3 4 · S4 0 · S5 1 ·
                                   S6 2 · S7 2 · S8 1 · S9 1          = 16
  ----------------------------------------------------------------------------
  stages with NO fatal magnitude check    round 2: S6, S8      round 3: none

The 12 threshold-gated magnitude bars are ABSOLUTE thresholds --

    S1.loss  <= 0.50%   S2b.loss <= 50.00%  S3.loss <= 55.00%
    S4.loss  <= 12.00%  S5.loss  <=  1.00%  S9.loss <= 45.00%
    S1.share  S2.share  S2b.deliv  S3.thr  S4.tail  S7.k

-- so absoluteness is not what puts a bar in UNGATED; instability on the record
is. They are gated as **regression tripwires of this harness against its own
recorded behaviour**, not as claims the magnitudes are physically right. Nothing
here asserts that S3 losing 40% of frames is acceptable; it asserts that S3 lost
35.77-40.23% on all 14 recorded runs against a bar sitting at 55%. ADR-004's
prohibition is on treating an unanchored simulator's absolute number as TRUTH,
which this does not do.

The honest cost: several GATED bars carry slack that means nothing physically --
S2b.loss 50% vs observed 22.35-28.71%, S3.loss 55% vs 35.77-40.23%, S9.loss 45%
vs 20.24-27.22%. The DRIFT band is what now covers that slack (S3.loss trips at
44.69% rather than at 55%), and every run prints both.

MARGIN vs SPREAD -- 14/14 is not reproducibility, and this unit now says so
==========================================================================
A bar that passed 14/14 by a hair is not established; a bar that passed by ten
spreads is. The run prints, for every bar with a derivable spread,
`margin = |threshold - nearest observed value|` and `margin/spread`. Two GATED
bars are fragile by that measure and are named rather than quietly gated:

  * `S3.thr`  bar 1.50 Mb vs recorded min 1.56 -- margin 0.06 on a spread of
    0.34, i.e. **0.18 spreads** (4% of the bar). S3 has already produced two
    out-of-envelope values.
  * `S7.k`  enumerated `K in {8,12}` against observed values {8, 12}: the bar
    admits EXACTLY the observed set, so its margin is **zero** by construction.
    It is 14/14 only because a legacy bar happens to admit both values its tier
    controller produced -- the controller demonstrably flipped (K=12 on run
    33309669280). Compare `S6.k`, which is `K == 20`, flipped the same way, and
    is therefore 13/14 and UNGATED. **The class rule is threshold-relative, not
    property-relative**, and these two bars are the demonstration.

Pre-registered, so that a future red is read correctly: if `S3.thr` or `S7.k`
reds, that is a MEASUREMENT that the bar is not reproducible, and the response is
to re-measure the record and move the bar's class by the rule -- never to widen
the threshold.

WHAT THIS GATE DOES **NOT** DO
==============================
- It does not gate the six UNGATED bars at their THRESHOLDS, and it does not
  widen them either. Either move needs a defensible envelope, and 14 runs fix a
  RANGE, not a distribution -- widening a bar to the observed max is fitting a
  threshold to 6-13 samples, which is tuning a bar to go green by another name.
  Four values have already landed outside the 14-run range on later runs (listed
  in `ladder_record.txt`), which is the concrete argument. U39a.
- Four GATED bars have NO derivable drift band because the record shows no spread
  at all (S1.loss, S1.share, S4.loss, S4.tail -- min == max on 14 runs). Named
  non-coverage: they are carried by their threshold alone.
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
    ["S1.loss", "S2b.loss", "S3.loss", "S4.loss", "S5.loss", "S9.loss"] +
    ["S1.share", "S2.share", "S2b.deliv", "S3.thr", "S4.tail", "S7.k"]
)

KNOWN_FAIL = {
    # bar          why it is an honest fail rather than a regression
    "S2.tail":     "0/14. Best recorded 1835/1900 = 96.6% against a 98.5% bar. The "
                   "push stack's post-ramp delivery never reaches it: loss continues "
                   "through steady state, it is not a startup transient. Design-"
                   "INDEPENDENT bar -- a real behavioural fail of the retained push "
                   "reference, not an artifact of the pivot. U39b.",
    "S3.peerloss": "0/14 at 20.0-33.0% against a 3.0% bar, off by 7-11x. Reads the "
                   "PUSH LOSS METER, which ADR-002 deleted along with the FEC tier "
                   "controller. Describes the retained reference only. U39c.",
}

# The six bars measured as not reproducible AT THEIR THRESHOLD. Every one of them
# still carries the fatal DRIFT band; "ungated" is about the threshold only.
UNGATED = ["S2.loss", "S3.rate", "S6.loss", "S6.k", "S7.loss", "S8.loss"]

# S2.loss and S2.tail are ONE measurement split across two classes, and that has
# to be stated where the classes are declared rather than buried in a report.
# Measured over the 14 runs: Pearson r = -0.9968 between S2's loss% and its
# tail900 count; the packets lost outside the scored tail
# window are 24.8 +- 3.1 (sample sd, n=14, range 20..31), i.e. the ramp loss that is not part of the scored tail. They are the
# same physical quantity seen twice. Round 2 left one KNOWN_FAIL and the other
# UNGATED, so S2's loss magnitude was bounded by nothing at all -- the concrete
# form of the laundering risk. The classification is NOT changed (the rule is
# reproducibility on the record, and changing a class by judgement is exactly the
# laundering the rule exists to prevent); what changed is that both now carry the
# fatal DRIFT band, so S2's loss magnitude is bounded in both directions again.
COUPLED = {("S2.loss", "S2.tail"): "Pearson r = -0.9968 over the 14 runs; one measurement, two bars"}


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

    gap = |threshold - nearest recorded value|. For a 14/14 bar that is its
    MARGIN; for a 0/14 bar it is its SHORTFALL. Divided by the recorded spread it
    answers the question 14/14 does not: is this bar established, or did it pass
    fourteen times by less than the noise? `S3.thr` reads 0.18 spreads and
    `S7.k` reads 0.00.
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
        die("class rule violated (%d problem(s)). 14/14 -> GATED, 0/14 -> "
            "KNOWN_FAIL, between -> UNGATED." % len(cerrs), 2)

    print("=" * 78)
    print("ladder gate -- EIF PUSH REFERENCE (ADR-002-superseded design), NOT the")
    print("shipped pull datapath. pathsim launches AGG_MODE=server|client only.")
    print("Baseline: 14 dev runs, p4-bondagg/sim/ladder_record.txt")
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
    print("GATED -- 14/14 on the baseline; a threshold failure here fails the job.")
    print("32 classified ids = 10 order + 10 dup + 12 magnitude, and the 10 dup bars")
    print("are REDUNDANT (dup cannot fail while order passes; proof in the docstring)")
    print("-> 22 independent gated bars: 10 ordering, 12 magnitude. 12 of these are")
    print("ABSOLUTE thresholds, gated as regression tripwires of this harness against")
    print("its own record -- NOT as claims the magnitudes are right. Some carry large")
    print("dead slack, which is why the DRIFT band below is also fatal.")
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
    print("KNOWN HONEST FAIL -- measured 0/14 on the push reference. Reported, never")
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
    print("UNGATED AT THEIR THRESHOLD -- bars that FLIPPED on the 14-run record")
    print("(6/14..13/14), i.e. measured as not reproducible at their current")
    print("threshold. NOT ungated for being absolute -- 12 gated bars are absolute")
    print("too. Neither gated nor widened: 14 runs fix a range, not a distribution")
    print("(U39a). They are NOT unchecked: the DRIFT band below is fatal for each.")
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
    print("    %2d threshold-gated magnitude bars; every stage S1..S9 now has at least"
          % (len(GATED) - 2 * len(STAGES)))
    print("       one FATAL magnitude check (round 2: S6 and S8 had none)")
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
