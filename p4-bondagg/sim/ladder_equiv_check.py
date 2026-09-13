#!/usr/bin/env python3
"""ladder_equiv_check.py -- U39. Proof that the pathsim.py refactor moved no bar,
and that `ladder_record.txt` is a rendering of measured data rather than prose.

U39 rewrote each stage's `extra_ok=<conjunction>` into a declared `bars=[...]`
list so `.github/scripts/ladder_gate.py` can classify each sub-bar without
re-implementing a threshold. A refactor of a test's own thresholds is exactly the
change that must not be taken on trust -- and pathsim cannot be run on the dev PC
to check it (it spawns a Go daemon; there is no Go toolchain here).

WHAT ROUND 3 ADDED, AND THE HOLE IT CLOSES
==========================================
Round 2 compared the old and new limbs **by BOOLEAN OUTCOME on the recorded
runs**. That is blind to any dilution that never flips a recorded verdict, and an
independent verifier demonstrated the consequence: `S1.share <0.08 -> <0.95`,
`S2.share >0.25 -> >0.001`, `S2b.deliv >=1800 -> >=1`, `S3.thr >=1.5 -> >=0.01`,
`S4.tail >=392 -> >=1` and `S7.k {8,12} -> {8,12,20,0,-}` all passed this file
AND the gate, on a real runner, with all ten jobs green. `lossbar` was the one
threshold protected, because it alone was compared NUMERICALLY.

Check (0) below closes that: every limb is now compared **structurally, as
source** (`ast.unparse` normal form), so a changed threshold is a divergence
whether or not it changes any verdict. The outcome comparison is kept as well --
they catch different things.

Round 2 also hand-wrote `ladder_record.txt`, and nothing checked it. A fabricated
pass count ("9/14" where the record's own runs say den/den) was therefore invisible
and could move a bar out of the GATED class. Check (4) closes that: every column
of the record is RECOMPUTED from `ladder_ci_runs.json` through pathsim's real
`verdict()`/`bars` source and must match exactly. Regenerate with
`--emit-record`; do not hand-patch.

THE CHECKS
==========
  0. STRUCTURE: `bars=`'s ok-expressions vs BASE's `extra_ok=` limbs, positional,
     compared as unparsed source. Plus the `tailok` derivation, plus `lossbar`
     numerically. This is the anti-dilution check.
  1. OUTCOME: the same limbs evaluated over every recorded CI run.
  2. VERDICT: the refactored `verdict()` recomputes each stage verdict from each
     run's measured values; compared against the PASS/FAIL the CI logs printed.
  3. CONTROLS: both `verdict()` bodies driven through limbs the record never
     fired (a duplicate, an out-of-order delivery, loss over bar).
  4. RECORD: `ladder_record.txt` == the recomputed threshold / count / envelope
     / hold-out audit. All four columns, all fatal.
  5. BAND: leave-one-out over the record -- build each bar's DRIFT band from the
     other n-1 values and ask whether the held-out one falls inside. This is the
     measurement that is supposed to license making DRIFT fatal on a job that
     must not flake, and round 3 OVERSTATED it in prose ("14/14 inside, ZERO
     exclusions"): 3 of 224 hold-outs had no band at all, and only 25 of the 221
     compared could ever have failed, with S5.loss, S6.k and S7.k contributing
     none. It is no longer prose. `ladder_replay.loo()` reports compared /
     informative / excluded / skipped per bar, those numbers are a COLUMN of the
     record, and check (4) is what fails if they change. This file also prints
     LOO-UNINFORMATIVE for any bar whose band no hold-out ever tested.

Why (1) exists as well as (2): (2) alone is blind to a bar inside a stage that
already fails for another reason. Measured -- mutating S2.share 0.25 -> 0.90 left
(2) at 0 mismatches, because S2.tail is False on every recorded run. (1)
catches it.
Why (0) exists as well as (1): see above -- (1) is blind to a dilution that flips
no recorded verdict, which is six of the twelve gated magnitude bars.

WHERE THE "OLD" SOURCE COMES FROM, AND WHY IT IS NOT A GIT LOOKUP
================================================================
Round 1 of this file read the base source with
`git show 96b9ddb:p4-bondagg/sim/pathsim.py` under `check=True`. That is fatal in
CI, and not marginally:

  * `actions/checkout@v4` defaults to `fetch-depth: 1`, so the object is not in
    the clone. Reproduced: `git clone --depth 1` of this branch ->
    `git cat-file -e 96b9ddb` exits 128, and this script raised
    CalledProcessError and exited 1. With `ladder` now FATAL that reds the job on
    every run.
  * `fetch-depth: 0` would NOT fix it where CI actually runs. The public CI mirror
    (`scripts/sync-public-ci.sh`, mmakki-ui/bond-ci) is built by `git init` + one
    commit + force-push, deliberately: "NO HISTORY ... history could carry a value
    that was committed once and removed later". Measured:
    `gh api repos/mmakki-ui/bond-ci/commits` returns exactly ONE sha. `96b9ddb`
    does not exist in that repo at any depth and never will.

So the dependency on a historical blob is REMOVED, not fetched around. The base
source is vendored verbatim as `ladder_base_pathsim.frozen.py` and pinned by
`BASE_SHA256` below. Where the real object IS reachable (a full clone, e.g. the
dev PC) the frozen copy is additionally cross-checked byte-for-byte against it,
so the vendoring is verified rather than asserted; where it is not reachable the
check says SKIPPED rather than passing quietly.

**AND THE LIMIT OF THAT PIN, STATED PLAINLY (round 3).** In CI the SKIPPED path
is the one that runs, so the pin verifies a file against a hash committed in the
same tree. Demonstrated: rewrite the frozen base's S1 limb, recompute
`BASE_SHA256`, dilute `pathsim.py` to match -> exit 0, output still naming
`96b9ddb`. Any single commit touching both files defeats it, including a
well-meant "regenerate the baseline". It is a tamper-EVIDENCE mechanism for a
full clone and for review, not an anchor. Two things do not depend on it: check
(4), which ties the record to `ladder_ci_runs.json` (byte-identical to the
private-repo CI logs), and the gate's DRIFT band, which is derived from those
MEASURED VALUES and moves with no threshold at all. A coordinated edit of
pathsim + the frozen base + its sha + the record is still not detectable from
inside this tree; a value that then falls outside its measured band is.

The frozen file is named `*.frozen.py` on purpose: it inherits `.gitattributes`'
`*.py text eol=lf` (so the bytes are stable on a Windows checkout), and
`ladder_base_pathsim.frozen` is not a legal module name, so no `import` can reach
it by accident.

Run:  python p4-bondagg/sim/ladder_equiv_check.py
      python p4-bondagg/sim/ladder_equiv_check.py --emit-record   (regenerate)
"""
import ast
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ladder_replay as LR  # noqa: E402  (path must be set first)

# The `dev` commit these frozen bytes were taken from. Pinned so this check keeps
# meaning after the branch merges (comparing against a moving `dev` would compare
# the file to itself and pass vacuously).
BASE = "96b9ddb"
BASE_PATH = "p4-bondagg/sim/pathsim.py"
# sha256 over the LF-normalized bytes of that blob. Normalized rather than raw so
# the pin survives a checkout that rewrites line endings.
BASE_SHA256 = "63b3e930a8f08537b450edc4726ee3d6c85a7e0feeb96cacb1869d3e9f752c62"

REPO = os.path.dirname(os.path.dirname(HERE))
NEW = LR.PATHSIM
FROZEN = os.path.join(HERE, "ladder_base_pathsim.frozen.py")
RUNS = LR.RUNS
RECORD = LR.RECORD

EMIT = "--emit-record" in sys.argv[1:]


def canon(b):
    """LF-normalize. The only normalization applied anywhere in this file."""
    return b.replace(b"\r\n", b"\n")


def fail(msg):
    print("FAIL(equiv): " + msg)
    sys.exit(2)


def norm(src):
    """Normal form of an expression's source, so formatting is not a difference."""
    return ast.unparse(ast.parse(src, mode="eval").body)


def norm_stmt(src):
    return ast.unparse(ast.parse(src))


if not os.path.exists(FROZEN):
    fail("frozen base source missing: %s" % FROZEN)
frozen = canon(open(FROZEN, "rb").read())
digest = hashlib.sha256(frozen).hexdigest()
if digest != BASE_SHA256:
    fail("frozen base source sha256 %s, pinned %s. The vendored copy of %s:%s "
         "has been edited. It is a FROZEN historical artifact -- restore it, do "
         "not re-pin it." % (digest, BASE_SHA256, BASE, BASE_PATH))
old_src = frozen.decode("utf-8")
new_src = open(NEW, encoding="utf-8").read()

# Non-vacuity: if the two sources were identical this whole file would compare
# pathsim.py against itself and pass for free.
if canon(new_src.encode("utf-8")) == frozen:
    fail("working-tree pathsim.py is byte-identical to the frozen base -- this "
         "check would be vacuous.")

# Cross-check against real history WHERE REACHABLE. Not required, never fatal for
# being absent: shallow clones and the history-free mirror are the normal case.
# Read the limit of this pin in the module docstring before trusting it.
try:
    p = subprocess.run(["git", "-C", REPO, "cat-file", "blob", "%s:%s" % (BASE, BASE_PATH)],
                       capture_output=True)
except OSError as e:
    p, xcheck = None, "SKIPPED -- no usable git (%s)" % e
if p is not None:
    if p.returncode != 0:
        xcheck = ("SKIPPED -- %s:%s not in this clone (git exit %d). Expected under "
                  "actions/checkout fetch-depth:1 and ALWAYS true on the history-free "
                  "CI mirror. The sha256 pin above is tamper EVIDENCE here, not an "
                  "anchor -- see the docstring." % (BASE, BASE_PATH, p.returncode))
    elif canon(p.stdout) != frozen:
        fail("frozen copy DIVERGES from the real git object %s:%s. One of them is "
             "wrong; the git object is the authority." % (BASE, BASE_PATH))
    else:
        xcheck = "byte-identical to the real git object %s:%s" % (BASE, BASE_PATH)


old_kw, old_der, _ = LR.parts(old_src)
new_kw, new_der, _ = LR.parts(new_src)
assert set(old_kw) == set(new_kw) and len(old_kw) == 10, (sorted(old_kw), sorted(new_kw))

runs = json.load(open(RUNS))

# ---------------------------------------------------------------------------
# PROVENANCE -- every recorded run must NAME a fetchable CI job and the objects
# it ran. This is tamper EVIDENCE, not an anchor, and the difference is stated
# below where the emit guard is. A run with no provenance cannot be checked by
# anyone; a run with provenance can be re-fetched with one command:
#     gh api repos/<repo>/actions/runs/<run>/jobs
# The `daemon` field must be identical across the whole record, because a run of
# a different daemon tree is a different measurement and pooling it silently is
# the failure this field exists to make visible.
# ---------------------------------------------------------------------------
REQUIRED = ("run", "repo", "branch", "head", "pathsim", "daemon")
prov = []
seen = set()
for r in runs:
    missing = [k for k in REQUIRED if not isinstance(r.get(k), str) or not r[k]]
    if missing:
        prov.append("run %r is missing provenance field(s): %s"
                    % (r.get("run", "<no id>"), ", ".join(missing)))
        continue
    if not r["run"].isdigit():
        prov.append("run id %r is not a CI run id" % r["run"])
    if r["run"] in seen:
        prov.append("run id %r appears twice" % r["run"])
    seen.add(r["run"])
daemons = sorted({r.get("daemon") for r in runs if isinstance(r.get("daemon"), str)})
if len(daemons) > 1:
    prov.append("the record pools runs of DIFFERENT daemon trees (%s). A run of a "
                "different daemon is a different measurement." % ", ".join(daemons))
if prov:
    for m in prov:
        print("PROVENANCE: " + m)
    fail("%d provenance problem(s) in %s. Every recorded run must name the CI run, "
         "repo, branch, head commit, pathsim blob and daemon tree it came from."
         % (len(prov), os.path.basename(RUNS)))

# ---------------------------------------------------------------------------
# (0) STRUCTURE -- the anti-dilution check. Source, not outcome.
# ---------------------------------------------------------------------------
n_struct = bad_struct = 0
for stage in sorted(old_kw):
    old_limbs = LR.and_limbs(old_kw[stage].get("extra_ok"))
    new_bars = LR.bar_exprs(new_kw[stage].get("bars", "()"))
    if len(old_limbs) != len(new_bars):
        bad_struct += 1
        print("DIVERGENT %s: %d limb(s) in the base, %d bar(s) now: %s vs %s"
              % (stage, len(old_limbs), len(new_bars), old_limbs, [b[0] for b in new_bars]))
        continue
    for limb, (bid, expr, _thr) in zip(old_limbs, new_bars):
        n_struct += 1
        if norm(limb) != norm(expr):
            bad_struct += 1
            print("DIVERGENT %s.%s THRESHOLD CHANGED: base `%s`  now `%s`"
                  % (stage, bid, norm(limb), norm(expr)))
    # the derived local a bar closes over is part of the threshold
    o, n = old_der.get(stage), new_der.get(stage)
    if (o is None) != (n is None) or (o is not None and norm_stmt(o) != norm_stmt(n)):
        bad_struct += 1
        print("DIVERGENT %s derived local: base `%s`  now `%s`" % (stage, o, n))
    n_struct += 1
    lo = eval(old_kw[stage].get("lossbar", "0.01"), {})
    ln = eval(new_kw[stage].get("lossbar", "0.01"), {})
    n_struct += 1
    if lo != ln:
        bad_struct += 1
        print("DIVERGENT %s.loss lossbar: base=%s now=%s" % (stage, lo, ln))

# ---------------------------------------------------------------------------
# (1)+(2) OUTCOME over the 14 recorded runs, and the stage verdicts
# ---------------------------------------------------------------------------
n_limb = n_stage = bad_limb = bad_stage = 0
for r in runs:
    for stage in sorted(old_kw):
        line = r["st"][stage]
        eo = LR.stage_env(stage, line, old_der)
        eb = LR.stage_env(stage, line, new_der)
        old_limbs = LR.and_limbs(old_kw[stage].get("extra_ok"))
        new_bars = eval(new_kw[stage].get("bars", "()"), eb)
        assert len(old_limbs) == len(new_bars), (stage, old_limbs, [b[0] for b in new_bars])
        assert eval(new_kw[stage].get("extra_ok", "True"), eb) is True, stage
        for limb, bar in zip(old_limbs, new_bars):
            n_limb += 1
            if bool(eval(limb, eo)) != bool(bar[1]):
                bad_limb += 1
                print("DIVERGENT %s.%s run %s: old `%s`=%s  new bar=%s"
                      % (stage, bar[0], r["run"], limb, bool(eval(limb, eo)), bool(bar[1])))
    text, npass = LR.replay(new_src, r)
    for stage in LR.STAGES:
        n_stage += 1
    got = {}
    for ln_ in text.splitlines():
        if ln_.startswith("PASS ") or ln_.startswith("FAIL "):
            got[ln_.split()[1]] = ln_.startswith("PASS ")
    for stage in LR.STAGES:
        if got.get(stage) != r["verdict"][stage]:
            bad_stage += 1
            print("MISMATCH run %s %s: refactor=%s  CI log recorded=%s"
                  % (r["run"], stage, got.get(stage), r["verdict"][stage]))

# ---------------------------------------------------------------------------
# (4) RECORD -- every column recomputed from the runs through the real source
# ---------------------------------------------------------------------------
acc = LR.measure(new_src, runs)
rows = []
for st in LR.STAGES:
    for b in sorted(acc):
        if b.split(".", 1)[0] == st and b.split(".", 1)[1] not in ("order", "dup"):
            rows.append((b, acc[b]))
for sfx in ("order", "dup"):
    rows.append(("*." + sfx, LR.wildcard(acc, sfx)))

if EMIT:
    # Refuse to regenerate the record from a source that has not passed every
    # earlier check. Without this, `--emit-record` is a one-command laundry: dilute
    # a bar, re-emit the record, and the gate's threshold comparison agrees with
    # the dilution. It is not a complete defence -- see the docstring's statement
    # of the frozen-base limit -- but it makes the laundering path fail loudly
    # instead of printing a clean table.
    if bad_struct or bad_limb or bad_stage:
        fail("refusing to emit a record from a tree that fails the structural (%d), "
             "outcome (%d) or verdict (%d) checks. Fix those first."
             % (bad_struct, bad_limb, bad_stage))
    # AND THE LIMIT OF THAT GUARD, DEMONSTRATED RATHER THAN ASSERTED (fix round).
    # A fabricated run that keeps every stage VERDICT unchanged passes checks (0),
    # (1) and (2) and therefore passes this guard. Measured: copy a recorded run,
    # rewrite `delivered=2473` to `delivered=1801` (still >= 1800, so no verdict
    # moves), re-emit -> the record's S2b.deliv envelope becomes `min 1801` and
    # everything is green. Without --emit-record the same edit is caught THREE
    # times (record pass/den, envelope and hold-out columns all diverge, plus a
    # LOO-EXCLUDED line), which is why the guard is worth having and why it is not
    # a defence. What a fabricated run must still do is NAME a CI run id, repo,
    # branch, head commit and daemon tree (the provenance block above), which a
    # reviewer can fetch in one command. That is tamper EVIDENCE for review, in
    # exactly the same sense as the frozen-base pin, and it is the honest ceiling
    # of what this tree can check about itself.
    w0 = max(len(r[0]) for r in rows)
    w1 = max(len(r[1]["threshold"]) for r in rows)
    w3 = max([len(LR.envelope_text(d)) for _, d in rows] + [len("envelope")])
    print("%-*s | %-*s | pass/den | %-*s | hold-outs"
          % (w0, "bar", w1, "threshold", w3, "envelope"))
    print("%s-|-%s-|----------|-%s-|-------------------------------------------"
          % ("-" * w0, "-" * w1, "-" * w3))
    for b, d in rows:
        print("%-*s | %-*s | %8s | %-*s | %s"
              % (w0, b, w1, d["threshold"], "%d/%d" % (d["passes"], d["den"]),
                 w3, LR.envelope_text(d), LR.loo_text(d)))
    sys.exit(0)

rec = LR.load_record(RECORD)
n_rec = bad_rec = 0
if sorted(rec) != sorted(b for b, _ in rows):
    bad_rec += 1
    print("DIVERGENT record rows: file has %s, the runs produce %s"
          % (sorted(rec), sorted(b for b, _ in rows)))
for b, d in rows:
    row = rec.get(b)
    if row is None:
        continue
    for field, want, got in (("threshold", d["threshold"], row["threshold"]),
                             ("pass/den", "%d/%d" % (d["passes"], d["den"]),
                              "%d/%d" % (row["passes"], row["den"])),
                             ("envelope", LR.envelope_text(d), row["env"]),
                             ("hold-outs", LR.loo_text(d), row["loo"])):
        n_rec += 1
        if want != got:
            bad_rec += 1
            print("DIVERGENT record %s %s: file %r, recomputed from the %d runs %r"
                  % (b, field, got, len(runs), want))

# ---------------------------------------------------------------------------
# (5) BAND -- leave-one-out false-positive rate of the fatal DRIFT band
# ---------------------------------------------------------------------------
n_loo = n_inf = n_exc = n_skip = n_banded = bad_loo = 0
for b, d in rows:
    vals = d["vals"]
    if not vals or max(vals) - min(vals) == 0:
        continue
    n_banded += 1
    c, i_, e, s, exc = LR.loo(vals)
    n_loo += c
    n_inf += i_
    n_exc += e
    n_skip += s
    for v, bd in exc:
        print("LOO-EXCLUDED %s: held-out value %s outside band [%s, %s] built from "
              "the other %d runs -- the DRIFT band would have flaked on that sample"
              % (b, LR.fmt(v), LR.fmt(bd[0]), LR.fmt(bd[1]), len(vals) - 1))
    if i_ == 0:
        print("LOO-UNINFORMATIVE %s: %d hold-out(s) compared, %d skipped, NONE of them "
              "moved the band -- this bar contributes no evidence that its band does "
              "not flake, whatever the aggregate says"
              % (b, c, s))
# The exclusion count is NOT asserted to be zero. It is a measured column of
# ladder_record.txt like every other, and check (4) above fails on any change to
# it. Asserting zero here is what let round 3 ship "ZERO exclusions" as the

print("base:            %s:%s, vendored as %s" % (BASE, BASE_PATH, os.path.basename(FROZEN)))
print("base sha256:     %s  (pinned, LF-normalized)" % digest)
print("git cross-check: %s" % xcheck)
print("(0) STRUCTURE  base extra_ok limbs vs new bars, compared AS SOURCE      "
      ": %d compared, %d divergent" % (n_struct, bad_struct))
print("(1) OUTCOME    the same limbs over the %2d recorded runs                 "
      ": %d compared, %d divergent" % (len(runs), n_limb, bad_limb))
print("(2) VERDICT    refactored verdict() vs the CI-logged PASS/FAIL          "
      ": %d compared, %d mismatched" % (n_stage, bad_stage))
print("(4) RECORD     ladder_record.txt vs recomputation from ladder_ci_runs   "
      ": %d compared, %d divergent" % (n_rec, bad_rec))
print("(5) BAND       leave-one-out DRIFT band over %2d banded bars             "
      ": %d compared, %d excluded" % (n_banded, n_loo, n_exc))
print("               of those %d hold-outs only %d are INFORMATIVE (the hold-out was"
      % (n_loo, n_inf))
print("               the unique min or max, so removing it actually moved the band);")
print("               %d more had no derivable band at all and tested nothing. The"
      % n_skip)
print("               per-bar numbers are a COLUMN of ladder_record.txt and check (4)")
print("               above fails on any change to them; nothing here asserts a zero.")

print("\n(3) positive control -- limbs the %d-run record never fired:" % len(runs))
cases = [("clean", list(range(100)), True),
         ("one duplicate", list(range(100)) + [7], False),
         ("out of order", [1, 0] + list(range(2, 100)), False),
         ("loss over bar", list(range(90)), False)]


def verdict_ns(src, got):
    ns = dict(glock=LR._Lock(), got=got, gtimes=[], dcnt={0: 0, 1: 0}, dupseq=[0],
              print=lambda *a, **k: None)
    exec(LR.parts(src)[2], ns)
    return ns


ctl = 0
for name, got_, want in cases:
    o = verdict_ns(old_src, list(got_))["verdict"]("SX y", 100, lossbar=0.05)
    n = verdict_ns(new_src, list(got_))["verdict"]("SX y", 100, lossbar=0.05, bars=())
    good = (o == n == want)
    ctl += 0 if good else 1
    print("  %-16s old=%-5s new=%-5s expected=%-5s %s"
          % (name, o, n, want, "ok" if good else "DIVERGENT"))

print("\nNOTE, measured not assumed: `dup == 0` can never fail while `inorder`")
print("passes -- the order scan requires a STRICT increase, which forces")
print("distinctness. Exhaustive over every sequence of length <= 6 from {0..3}:")
print("5460 enumerated (lengths 1..6; 5461 including the empty sequence),")
print("0 with dup>0 and inorder=True either way. The dup bar is a")
print("redundant tripwire; ladder's de-duplication evidence is the order bar.")

sys.exit(1 if (bad_struct or bad_limb or bad_stage or bad_rec or ctl) else 0)
