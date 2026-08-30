#!/usr/bin/env python3
"""ladder_equiv_check.py -- U39. Proof that the pathsim.py refactor moved no bar.

U39 rewrote each stage's `extra_ok=<conjunction>` into a declared `bars=[...]`
list so `.github/scripts/ladder_gate.py` can classify each sub-bar without
re-implementing a threshold. A refactor of a test's own thresholds is exactly
the change that must not be taken on trust -- and pathsim cannot be run on the
dev PC to check it (it spawns a Go daemon; there is no Go toolchain here).

So this compares the two SOURCES directly, and both against the CI record:

  1. `bars=` from the working tree's pathsim.py
     vs `extra_ok=` from BASE (pinned below) -- split on `and` into limbs and
     compared LIMB BY LIMB, positionally, over the 14 recorded CI runs in
     `ladder_ci_runs.json`.
  2. The refactored `verdict()` body, exec'd in isolation, recomputes each
     stage verdict from each run's measured values; those are compared against
     the PASS/FAIL lines the CI logs actually printed.
  3. Positive controls through BOTH `verdict()` bodies for the limbs the 14-run
     record never fired (a duplicate, an out-of-order delivery, loss over bar).

Why (1) exists as well as (2): (2) alone is blind to a bar inside a stage that
already fails for another reason. Measured -- mutating S2.share 0.25 -> 0.90
left (2) at 0 mismatches, because S2.tail is False on all 14 runs. (1) catches
it. Both are kept.

WHERE THE "OLD" SOURCE COMES FROM, AND WHY IT IS NOT A GIT LOOKUP
================================================================
Round 1 of this file read the base source with
`git show 96b9ddb:p4-bondagg/sim/pathsim.py` under `check=True`. That is fatal
in CI, and not marginally:

  * `actions/checkout@v4` defaults to `fetch-depth: 1`, so the object is not in
    the clone. Reproduced: `git clone --depth 1` of this branch ->
    `git cat-file -e 96b9ddb` exits 128, and this script raised
    CalledProcessError and exited 1. With `ladder` now FATAL that reds the job
    on every run.
  * `fetch-depth: 0` would NOT fix it where CI actually runs. The public CI
    mirror (`scripts/sync-public-ci.sh`, mmakki-ui/bond-ci) is built by
    `git init` + one commit + force-push, deliberately: "NO HISTORY ... history
    could carry a value that was committed once and removed later". Measured:
    `gh api repos/mmakki-ui/bond-ci/commits` returns exactly ONE sha. `96b9ddb`
    does not exist in that repo at any depth and never will.

So the dependency on a historical blob is REMOVED, not fetched around. The base
source is vendored verbatim as `ladder_base_pathsim.frozen.py` and pinned by
`BASE_SHA256` below. Where the real object IS reachable (a full clone, e.g. the
dev PC) the frozen copy is additionally cross-checked byte-for-byte against it,
so the vendoring is verified rather than asserted; where it is not reachable the
check says SKIPPED rather than passing quietly.

The frozen file is named `*.frozen.py` on purpose: it inherits `.gitattributes`'
`*.py text eol=lf` (so the bytes are stable on a Windows checkout), and
`ladder_base_pathsim.frozen` is not a legal module name, so no `import` can
reach it by accident.

Run:  python p4-bondagg/sim/ladder_equiv_check.py
"""
import ast
import hashlib
import json
import os
import re
import subprocess
import sys

# The `dev` commit these frozen bytes were taken from. Pinned so this check keeps
# meaning after the branch merges (comparing against a moving `dev` would compare
# the file to itself and pass vacuously).
BASE = "96b9ddb"
BASE_PATH = "p4-bondagg/sim/pathsim.py"
# sha256 over the LF-normalized bytes of that blob. Normalized rather than raw so
# the pin survives a checkout that rewrites line endings.
BASE_SHA256 = "63b3e930a8f08537b450edc4726ee3d6c85a7e0feeb96cacb1869d3e9f752c62"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
NEW = os.path.join(HERE, "pathsim.py")
FROZEN = os.path.join(HERE, "ladder_base_pathsim.frozen.py")
RUNS = os.path.join(HERE, "ladder_ci_runs.json")


def canon(b):
    """LF-normalize. The only normalization applied anywhere in this file."""
    return b.replace(b"\r\n", b"\n")


def fail(msg):
    print("FAIL(equiv): " + msg)
    sys.exit(2)


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
try:
    p = subprocess.run(["git", "-C", REPO, "cat-file", "blob", "%s:%s" % (BASE, BASE_PATH)],
                       capture_output=True)
except OSError as e:
    p, xcheck = None, "SKIPPED -- no usable git (%s)" % e
if p is not None:
    if p.returncode != 0:
        xcheck = ("SKIPPED -- %s:%s not in this clone (git exit %d). Expected under "
                  "actions/checkout fetch-depth:1 and ALWAYS true on the history-free "
                  "CI mirror. The sha256 pin above is the authority here."
                  % (BASE, BASE_PATH, p.returncode))
    elif canon(p.stdout) != frozen:
        fail("frozen copy DIVERGES from the real git object %s:%s. One of them is "
             "wrong; the git object is the authority." % (BASE, BASE_PATH))
    else:
        xcheck = "byte-identical to the real git object %s:%s" % (BASE, BASE_PATH)


def stage_kwargs(src):
    out, derived = {}, {}
    for node in ast.parse(src).body:
        if isinstance(node, ast.FunctionDef) and re.fullmatch(r"S\d\w*", node.name):
            for st in node.body:
                if isinstance(st, ast.Assign) and getattr(st.targets[0], "id", "") == "tailok":
                    derived[node.name] = ast.get_source_segment(src, st)
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call) and getattr(sub.func, "id", "") == "verdict":
                    out[node.name] = {k.arg: ast.get_source_segment(src, k.value) for k in sub.keywords}
    return out, derived


def verdict_src(src):
    for node in ast.parse(src).body:
        if isinstance(node, ast.FunctionDef) and node.name == "verdict":
            return ast.get_source_segment(src, node)
    raise AssertionError("verdict() not found")


class _L:
    def __enter__(self): return None
    def __exit__(self, *a): return False


def verdict_ns(src, got):
    ns = dict(glock=_L(), got=got, gtimes=[], dcnt={0: 0, 1: 0}, dupseq=[0],
              print=lambda *a, **k: None)
    exec(verdict_src(src), ns)
    return ns


old_kw, old_der = stage_kwargs(old_src)
new_kw, new_der = stage_kwargs(new_src)
assert set(old_kw) == set(new_kw) and len(old_kw) == 10, (sorted(old_kw), sorted(new_kw))

runs = json.load(open(RUNS))
n_limb = n_stage = bad_limb = bad_stage = 0

for r in runs:
    for stage in sorted(old_kw):
        line = r["st"][stage]

        def grab(pat, cast=float):
            m = re.search(pat, line)
            return cast(m.group(1)) if m else None

        env = {}
        if stage in ("S1", "S2"):
            env["share1"] = grab(r"p1share=([\d.]+)%") / 100.0
        if stage == "S2":
            env["tl"] = grab(r"tail900=(\d+)/", int)
        if stage == "S2b":
            env["n"] = grab(r"delivered=(\d+)", int)
        if stage == "S3":
            env["thr"] = grab(r"late_thr=([\d.]+)Mb")
            env["p0"] = grab(r"p0rate=(\d+)kb", int)
            env["calm"] = grab(r"median_peerloss=([\d.]+)%")
        if stage == "S4":
            env["tail"] = grab(r"tail=(\d+)/", int)
        if stage in ("S6", "S7"):
            env["k"] = grab(r"K=(\S+)", str)

        eo, eb = dict(env), dict(env)
        # `tailok` is a derived local; take its definition from each source under
        # test rather than re-typing the threshold here (a re-typed threshold is
        # invisible to this check -- found by mutating 0.985 -> 0.50).
        if stage in old_der:
            exec(old_der[stage], eo)
        if stage in new_der:
            exec(new_der[stage], eb)

        oe = old_kw[stage].get("extra_ok")
        if oe is None:
            old_limbs = []
        else:
            n = ast.parse(oe, mode="eval").body
            parts = n.values if isinstance(n, ast.BoolOp) and isinstance(n.op, ast.And) else [n]
            old_limbs = [ast.unparse(x) for x in parts]

        new_bars = eval(new_kw[stage].get("bars", "()"), eb)
        assert len(old_limbs) == len(new_bars), (stage, old_limbs, [b[0] for b in new_bars])
        assert eval(new_kw[stage].get("extra_ok", "True"), eb) is True, stage

        lo = eval(old_kw[stage].get("lossbar", "0.01"), {})
        ln = eval(new_kw[stage].get("lossbar", "0.01"), {})
        if lo != ln:
            bad_limb += 1
            print("DIVERGENT %s.loss run %s: lossbar old=%s new=%s" % (stage, r["run"], lo, ln))

        for limb, bar in zip(old_limbs, new_bars):
            n_limb += 1
            if bool(eval(limb, eo)) != bool(bar[1]):
                bad_limb += 1
                print("DIVERGENT %s.%s run %s: old `%s`=%s  new bar=%s"
                      % (stage, bar[0], r["run"], limb, bool(eval(limb, eo)), bool(bar[1])))

        # ---- (2) recompute the stage verdict through the refactored verdict()
        fwd = int(re.search(r"fwd=(\d+)/", line).group(1))
        npkts = int(re.search(r"fwd=\d+/(\d+)", line).group(1))
        assert re.search(r"dup=(\d+)", line).group(1) == "0"
        assert re.search(r"inorder=(\w+)", line).group(1) == "True"
        got = list(range(fwd))
        ok = verdict_ns(new_src, got)["verdict"]("%s x" % stage, npkts, lossbar=ln, bars=new_bars)
        n_stage += 1
        if ok != r["verdict"][stage]:
            bad_stage += 1
            print("MISMATCH run %s %s: refactor=%s  CI log recorded=%s"
                  % (r["run"], stage, ok, r["verdict"][stage]))

print("base:            %s:%s, vendored as %s" % (BASE, BASE_PATH, os.path.basename(FROZEN)))
print("base sha256:     %s  (pinned, LF-normalized)" % digest)
print("git cross-check: %s" % xcheck)
print("per-LIMB  old extra_ok limbs vs new bars, 14 runs x 10 limbs : %d compared, %d divergent"
      % (n_limb, bad_limb))
print("per-STAGE refactored verdict() vs the CI-logged PASS/FAIL     : %d compared, %d mismatched"
      % (n_stage, bad_stage))

print("\npositive control -- limbs the 14-run record never fired:")
cases = [("clean", list(range(100)), True),
         ("one duplicate", list(range(100)) + [7], False),
         ("out of order", [1, 0] + list(range(2, 100)), False),
         ("loss over bar", list(range(90)), False)]
ctl = 0
for name, got, want in cases:
    o = verdict_ns(old_src, list(got))["verdict"]("SX y", 100, lossbar=0.05)
    n = verdict_ns(new_src, list(got))["verdict"]("SX y", 100, lossbar=0.05, bars=())
    good = (o == n == want)
    ctl += 0 if good else 1
    print("  %-16s old=%-5s new=%-5s expected=%-5s %s" % (name, o, n, want, "ok" if good else "DIVERGENT"))

print("\nNOTE, measured not assumed: `dup == 0` can never fail while `inorder`")
print("passes -- the order scan requires a STRICT increase, which forces")
print("distinctness. Exhaustive over every sequence of length <= 6 from {0..3}:")
print("5460 enumerated, 0 with dup>0 and inorder=True. The dup bar is a")
print("redundant tripwire; ladder's de-duplication evidence is the order bar.")

sys.exit(1 if (bad_limb or bad_stage or ctl) else 0)
