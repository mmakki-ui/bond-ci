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

THE THREE CLASSES, AND THE ONE RULE THAT PARTITIONS THEM
========================================================
Baseline: 14 consecutive `ladder` runs on `dev`, 2026-08-30, recorded bar by bar
in `p4-bondagg/sim/ladder_record.txt` (run ids in that file). This gate READS
that file and refuses to classify a bar the record does not cover.

**The partition is by MEASURED REPRODUCIBILITY on that record, and by nothing
else.** 14/14 -> GATED. 0/14 -> KNOWN_FAIL. Anything between -> UNGATED.

GATED (32)      -- held on every recorded run, so a failure is a CHANGE IN
                   BEHAVIOUR of the push reference. Fails the job.
KNOWN_FAIL (2)  -- an HONEST, PERSISTENT fail: 0/14. Reported every run, never
                   weakened, never tuned away. Same shape as `eif-model`
                   tolerating its documented N5H FAIL and `rig-paired` carrying
                   `BASELINE_FAILS`. Adding a bar here to go green is weakening
                   a bar; only a MEASURED 0/14 belongs.
UNGATED (6)     -- FLIPPED on the record: 6/14, 9/14, 9/14, 13/14, 13/14, 13/14.
                   That is a demonstration that the bar is not reproducible at
                   its current threshold, and the cause is structural: this
                   harness spawns real Go daemons over loopback, and
                   PYTHONHASHSEED pins the shim's draws but pins NOTHING about
                   wall-clock scheduling. Gating a demonstrably flaky bar makes
                   the job flake, which is what produced `continue-on-error` in
                   the first place. Printed with its recorded envelope so drift
                   stays visible; not gated, and not re-thresholded to a wider
                   value either -- see the limit below.

A bar id in no class is a HARD FAIL. New bars must be classified deliberately.

**CORRECTING THE RATIONALE THIS FILE SHIPPED IN ROUND 1.** It said UNGATED was
"an ABSOLUTE threshold on a harness never anchored to a real router -- the class
ADR-004 forbids gating". That is not the rule in use, and the file's own tables
refute it: **12 of the 32 GATED bars are absolute magnitude thresholds**, six of
them absolute LOSS thresholds --

    S1.loss  <= 0.50%   S2b.loss <= 50.0%   S3.loss <= 55.0%
    S4.loss  <= 12.0%   S5.loss  <=  1.00%  S9.loss <= 45.0%

plus S1.share, S2.share, S2b.deliv, S3.thr, S4.tail, S7.k. Absoluteness is not
what puts a bar in UNGATED; instability on the record is.

Those 12 are gated for a DIFFERENT reason than ADR-004's paired bars, and the
difference is the point: they are **regression tripwires of this harness against
its own recorded behaviour**, not claims that the magnitudes are physically
right. Nothing here asserts that S3 losing 40% of frames is acceptable; it
asserts that S3 lost 35.77-40.23% on all 14 recorded runs against a bar sitting
at 55%. ADR-004's prohibition is on treating an unanchored simulator's absolute
number as TRUTH, which this does not do.

The honest cost of that distinction: several GATED bars carry slack that means
nothing physically -- S2b.loss 50% vs observed 22.35-28.71%, S3.loss 55% vs
35.77-40.23%, S9.loss 45% vs 20.24-27.22%. They will not catch a small
regression. They are tripwires against gross change, and the run output prints
each bar's value next to its recorded envelope so the slack is visible rather
than implied.

WHAT THIS GATE DOES **NOT** DO
==============================
- It does not gate the six UNGATED bars, and it does not widen them either.
  Either move needs a defensible envelope, and 14 runs fix a RANGE, not a
  distribution -- widening a bar to the observed max is fitting a threshold to
  6-13 samples, which is tuning a bar to go green by another name. The study
  nobody has run is the prerequisite. Open question, ROADMAP U39a.
- It does not detect a regression inside a GATED bar's slack (see above).
- `*.dup` can never fail while `*.order` passes: `verdict()`'s order scan
  requires a STRICT increase, which forces distinctness (verified by exhaustive
  enumeration of every sequence of length <= 6 over {0..3}: 5460 sequences, 0
  with dup>0 and inorder=True). So ladder's de-duplication evidence is carried
  by the order bar; the dup bar is redundant, kept as a tripwire.
- Nothing here has ever run on hardware.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SIMDIR = os.path.join(ROOT, "p4-bondagg", "sim")
RECORD = os.path.join(SIMDIR, "ladder_record.txt")

STAGES = ["S1", "S2", "S2b", "S3", "S4", "S5", "S6", "S7", "S8", "S9"]

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
                   "reference, not an artifact of the pivot.",
    "S3.peerloss": "0/14 at 20.0-33.0% against a 3.0% bar, off by 7-11x. Reads the "
                   "PUSH LOSS METER, which ADR-002 deleted along with the FEC tier "
                   "controller. Describes the retained reference only.",
}

UNGATED = {
    "S2.loss": "6/14",
    "S3.rate": "9/14",
    "S6.loss": "9/14",
    "S6.k":    "13/14",
    "S7.loss": "13/14",
    "S8.loss": "13/14",
}


def die(msg, code=1):
    print("\nFAIL(gate): " + msg)
    sys.exit(code)


def load_record():
    """Recorded pass/14 per bar. The gate refuses to classify what it cannot cite."""
    if not os.path.exists(RECORD):
        die("baseline record missing: %s" % RECORD, 2)
    rec = {}
    for line in open(RECORD, encoding="utf-8"):
        m = re.match(r"^(\*|S\d\w*)\.(\w+)\s+(.*?)\s+(\d+)/(\d+)\s+(.*)$", line.rstrip())
        if m:
            rec[m.group(1) + "." + m.group(2)] = (int(m.group(4)), int(m.group(5)),
                                                  m.group(3).strip(), m.group(6).strip())
        else:
            m = re.match(r"^(\*|S\d\w*)\.(\w+)\s+(.*?)\s+(\d+)/(\d+)\s*$", line.rstrip())
            if m:
                rec[m.group(1) + "." + m.group(2)] = (int(m.group(4)), int(m.group(5)),
                                                      m.group(3).strip(), "")
    return rec


def main():
    # Pinned config, checked rather than assumed: pathsim seeds each scenario off
    # hash(name), so an unpinned PYTHONHASHSEED changes the shim's loss draws and
    # the baseline in ladder_record.txt no longer describes this run.
    if os.environ.get("PYTHONHASHSEED") != "0":
        die("PYTHONHASHSEED=%r, baseline was measured at '0'. Refusing to compare "
            "against a record measured elsewhere." % os.environ.get("PYTHONHASHSEED"), 2)

    rec = load_record()

    classified = set(GATED) | set(KNOWN_FAIL) | set(UNGATED)
    missing_rec = [b for b in classified
                   if b not in rec and ("*." + b.split(".", 1)[1]) not in rec]
    if missing_rec:
        die("bars classified with no entry in ladder_record.txt: %s" % ", ".join(sorted(missing_rec)), 2)

    print("=" * 78)
    print("ladder gate -- EIF PUSH REFERENCE (ADR-002-superseded design), NOT the")
    print("shipped pull datapath. pathsim launches AGG_MODE=server|client only.")
    print("Baseline: 14 dev runs, p4-bondagg/sim/ladder_record.txt")
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

    bars = {}
    for m in re.finditer(r"^BAR (S\d\w*)\.(\w+) (PASS|FAIL) value=(\S*) bar=(.*)$", out, re.M):
        bars[m.group(1) + "." + m.group(2)] = (m.group(3) == "PASS", m.group(4), m.group(5).strip())

    # ---- structure: a run that died mid-way must not read green -------------
    errs = []
    for st in STAGES:
        got = {k.split(".", 1)[1] for k in bars if k.split(".", 1)[0] == st}
        if got != EXPECT[st]:
            errs.append("stage %s emitted bars %s, expected %s"
                        % (st, sorted(got) or "NONE", sorted(EXPECT[st])))
    if not re.search(r"^== LADDER: \d+/10 PASS ==$", out, re.M):
        errs.append("no '== LADDER: n/10 PASS ==' summary line -- pathsim did not finish")
    unknown = sorted(set(bars) - classified)
    if unknown:
        errs.append("UNCLASSIFIED bar id(s): %s -- classify them in ladder_gate.py "
                    "deliberately; this gate fails closed rather than skip a bar"
                    % ", ".join(unknown))
    if errs:
        for e in errs:
            print("  STRUCTURE: " + e)
        die("structure check failed (%d problem(s))" % len(errs), 2)

    # ---- verdict ------------------------------------------------------------
    def recline(bar):
        return rec.get(bar) or rec.get("*." + bar.split(".", 1)[1])

    print()
    print("-" * 78)
    print("GATED -- 14/14 on the baseline; a failure here fails the job. 12 of these")
    print("are ABSOLUTE magnitude thresholds, gated as regression tripwires of this")
    print("harness against its own record -- NOT as claims the magnitudes are right.")
    print("Compare each value to the recorded envelope: some carry large dead slack.")
    print("-" * 78)
    regressions = []
    for b in sorted(GATED):
        ok, val, txt = bars[b]
        n, d, _, env = recline(b)
        print("  %-12s %-4s value=%-10s %-26s baseline %d/%d  [%s]"
              % (b, "PASS" if ok else "FAIL", val, txt, n, d, env))
        if not ok:
            regressions.append((b, val, txt, n, d))

    print()
    print("-" * 78)
    print("KNOWN HONEST FAIL -- measured 0/14 on the push reference. Reported, never")
    print("weakened. These are the two stages that make ladder a standing red.")
    print("-" * 78)
    for b in sorted(KNOWN_FAIL):
        ok, val, txt = bars[b]
        n, d, _, env = recline(b)
        print("  %-12s %-4s value=%-10s %-26s baseline %d/%d  [%s]"
              % (b, "PASS" if ok else "FAIL", val, txt, n, d, env))
        print("      %s" % KNOWN_FAIL[b].replace("\n", " "))
        if ok:
            print("      NOTE: this bar PASSED. That is an improvement, not a failure. If it")
            print("      holds across a re-measured record, move it to GATED.")

    print()
    print("-" * 78)
    print("UNGATED -- bars that FLIPPED on the 14-run record (6/14..13/14), i.e.")
    print("measured as not reproducible at their current threshold. This harness")
    print("spawns real daemons; PYTHONHASHSEED pins the shim's draws and nothing")
    print("about wall-clock scheduling. NOT ungated for being absolute -- 12 gated")
    print("bars are absolute too. Reported with the recorded envelope; neither gated")
    print("nor widened: 14 runs fix a range, not a distribution -- ROADMAP U39a.")
    print("-" * 78)
    for b in sorted(UNGATED):
        ok, val, txt = bars[b]
        n, d, _, env = recline(b)
        print("  %-12s %-4s value=%-10s %-26s baseline %d/%d  [%s]"
              % (b, "PASS" if ok else "FAIL", val, txt, n, d, env))

    print()
    print("=" * 78)
    if regressions:
        for b, val, txt, n, d in regressions:
            print("  REGRESSION  %s  value=%s  bar=%s  (baseline %d/%d)" % (b, val, txt, n, d))
        die("%d GATED bar(s) regressed. Do not add them to KNOWN_FAIL to go green -- "
            "that is weakening a bar. Fix the cause, or record a NEW measured baseline "
            "and say what changed." % len(regressions))
    print("  ladder gate PASS -- %d gated bars hold; %d known honest fails reported;"
          % (len(GATED), len(KNOWN_FAIL)))
    print("  %d bars ungated by class. This is a statement about the PUSH REFERENCE." % len(UNGATED))
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())
