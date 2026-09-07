#!/usr/bin/env python3
"""ladder_replay.py -- U39 round 3. ONE implementation of three things that were
previously copy-pasted between `ladder_equiv_check.py` and `test_ladder_gate.py`,
plus the record grammar that `.github/scripts/ladder_gate.py` reads.

  * pull each stage's `verdict(...)` keywords out of pathsim.py by AST;
  * replay one recorded CI run through pathsim's REAL `verdict()`/`bars` source,
    producing the exact `BAR ...` text pathsim itself would print;
  * parse `BAR` lines and `ladder_record.txt` rows.

WHY IT IS ONE MODULE
====================
Round 2 shipped two near-identical copies of the replay. A gate whose baseline is
derived by a second copy of the code under test can drift from it silently -- the
same defect class this whole unit exists to close.

THE VALUE PARSER AND THE DRIFT BAND, WHICH ARE THE LOAD-BEARING PARTS
=====================================================================
`num()` reads the leading numeric literal of a bar's printed value: `5.96%` ->
5.96, `1756/1900` -> 1756, `1.67Mb` -> 1.67, `True` -> None. The SAME function
reads live output and recorded output, so the two cannot diverge in
interpretation.

`band()` turns a bar's recorded [min, max] into a fatal DRIFT band, and it is the
one check in this unit derived from MEASURED VALUES rather than from any
threshold. A diluted threshold does not move it. Its rule:

    w = max - min          (the spread the 14-run record actually established)
    w == 0  -> NO BAND. The record establishes no spread; none is invented.
    w > 0   -> [min - w, max + w]

Widening by exactly one observed range is a choice, and the honest statement of
it is: 14 samples fix a RANGE, not a distribution (the standing caveat this unit
already carries), so the band is a GROSS-CHANGE tripwire and nothing finer. It
was not picked to look safe -- it is the coarsest widening expressible as a pure
function of the record with no new number in it, and its false-positive rate was
MEASURED by leave-one-out on the record itself: for each of the 14 runs, build
the band from the other 13 and ask whether the held-out run falls inside.
Result: 16 of 16 bars with a derivable band, 14/14 runs inside, ZERO exclusions.
`ladder_equiv_check.py` re-runs that leave-one-out every CI run and fails if it
ever stops holding. That is what licenses making DRIFT fatal on a job that must
not flake.

Non-numeric bars (`*.order`, whose value is `True`/`False`) band by observed
TOKEN SET instead; there is no arithmetic to do on them.
"""
import ast
import contextlib
import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PATHSIM = os.path.join(HERE, "pathsim.py")
RUNS = os.path.join(HERE, "ladder_ci_runs.json")
RECORD = os.path.join(HERE, "ladder_record.txt")

STAGES = ["S1", "S2", "S2b", "S3", "S4", "S5", "S6", "S7", "S8", "S9"]

BAR_RE = re.compile(r"^BAR (S\d\w*)\.(\w+) (PASS|FAIL) value=(\S*) bar=(.*)$", re.M)


# --------------------------------------------------------------------------
# pathsim source -> stage kwargs / derived locals / verdict()
# --------------------------------------------------------------------------
def parts(src):
    """(stage -> {kwarg: source}, stage -> `tailok` source, verdict() source)."""
    kw, der, vsrc = {}, {}, None
    for node in ast.parse(src).body:
        if isinstance(node, ast.FunctionDef) and node.name == "verdict":
            vsrc = ast.get_source_segment(src, node)
        if isinstance(node, ast.FunctionDef) and re.fullmatch(r"S\d\w*", node.name):
            for st in node.body:
                if isinstance(st, ast.Assign) and getattr(st.targets[0], "id", "") == "tailok":
                    der[node.name] = ast.get_source_segment(src, st)
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call) and getattr(sub.func, "id", "") == "verdict":
                    kw[node.name] = {k.arg: ast.get_source_segment(src, k.value)
                                     for k in sub.keywords}
    if vsrc is None:
        raise AssertionError("verdict() not found in pathsim source")
    return kw, der, vsrc


def bar_exprs(bars_src):
    """[(bar id, source of the ok expression, source of the threshold text)].

    Structural, not evaluated. This is what makes a threshold dilution visible:
    comparing `share1 < 0.08` to `share1 < 0.95` as SOURCE cannot be fooled by a
    mutation that happens not to flip any recorded verdict.
    """
    out = []
    node = ast.parse(bars_src, mode="eval").body
    if not isinstance(node, (ast.List, ast.Tuple)):
        raise AssertionError("bars= is not a list/tuple literal: %r" % bars_src)
    for el in node.elts:
        if not isinstance(el, (ast.Tuple, ast.List)) or len(el.elts) != 4:
            raise AssertionError("bar entry is not a 4-tuple: %r" % ast.unparse(el))
        bid = el.elts[0]
        if not isinstance(bid, ast.Constant) or not isinstance(bid.value, str):
            raise AssertionError("bar id is not a string literal: %r" % ast.unparse(bid))
        out.append((bid.value, ast.unparse(el.elts[1]), ast.unparse(el.elts[3])))
    return out


def and_limbs(src):
    """An `extra_ok=` conjunction split into its limbs, normalized by unparse."""
    if src is None:
        return []
    node = ast.parse(src, mode="eval").body
    lst = node.values if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.And) else [node]
    return [ast.unparse(x) for x in lst]


# --------------------------------------------------------------------------
# replay one recorded run through the REAL verdict()
# --------------------------------------------------------------------------
class _Lock:
    def __enter__(self): return None
    def __exit__(self, *a): return False


def stage_env(stage, line, der):
    """The locals each stage's bars close over, read out of its recorded line."""
    def g(pat, cast=float):
        m = re.search(pat, line)
        return cast(m.group(1)) if m else None

    env = {}
    if stage in ("S1", "S2"):
        env["share1"] = g(r"p1share=([\d.]+)%") / 100.0
    if stage == "S2":
        env["tl"] = g(r"tail900=(\d+)/", int)
    if stage == "S2b":
        env["n"] = g(r"delivered=(\d+)", int)
    if stage == "S3":
        env["thr"] = g(r"late_thr=([\d.]+)Mb")
        env["p0"] = g(r"p0rate=(\d+)kb", int)
        env["calm"] = g(r"median_peerloss=([\d.]+)%")
    if stage == "S4":
        env["tail"] = g(r"tail=(\d+)/", int)
    if stage in ("S6", "S7"):
        env["k"] = g(r"K=(\S+)", str)
    if stage in der:
        exec(der[stage], env)
    return env


def replay(src, run):
    """Reproduce pathsim's stdout for one recorded run. Returns (text, n_pass)."""
    kw, der, vsrc = parts(src)
    buf, npass = io.StringIO(), 0
    for stage in STAGES:
        line = run["st"][stage]
        env = stage_env(stage, line, der)
        bars = eval(kw[stage].get("bars", "()"), env)
        lossbar = eval(kw[stage].get("lossbar", "0.01"), {})
        fwd = int(re.search(r"fwd=(\d+)/", line).group(1))
        npkts = int(re.search(r"fwd=\d+/(\d+)", line).group(1))
        ns = dict(glock=_Lock(), got=list(range(fwd)), gtimes=[],
                  dcnt={0: 0, 1: 0}, dupseq=[0])
        exec(vsrc, ns)
        with contextlib.redirect_stdout(buf):
            if ns["verdict"]("%s x" % stage, npkts, lossbar=lossbar, bars=bars):
                npass += 1
    buf.write("== LADDER: %d/10 PASS ==\n" % npass)
    return buf.getvalue(), npass


def bars_of(text):
    """`BAR` lines -> {bar id: (ok, value string, threshold string)}."""
    return {m.group(1) + "." + m.group(2):
            (m.group(3) == "PASS", m.group(4), m.group(5).strip())
            for m in BAR_RE.finditer(text)}


# --------------------------------------------------------------------------
# values, envelopes, bands
# --------------------------------------------------------------------------
_NUM = re.compile(r"^-?\d+(?:\.\d+)?")


def num(s):
    """Leading numeric literal of a printed bar value, or None if there is none."""
    m = _NUM.match(s or "")
    return float(m.group(0)) if m else None


def fmt(x):
    """Shortest exact rendering, so the record can be regenerated byte-stably."""
    return str(int(x)) if float(x).is_integer() else repr(round(float(x), 10))


def band(lo, hi):
    """Fatal DRIFT band from a recorded [min, max]. None when no spread exists."""
    w = hi - lo
    if w == 0:
        return None
    return (lo - w, hi + w)


def measure(src, runs):
    """{bar: dict(passes, den, vals, tokens, threshold)} recomputed from the runs.

    This is the ONLY derivation of the baseline. `ladder_record.txt` is a
    rendering of it and `ladder_equiv_check.py` asserts the two agree exactly, so
    a hand-edited pass count or envelope in the record is a CI failure rather
    than an unchecked comment.
    """
    acc = {}
    for r in runs:
        text, _ = replay(src, r)
        for b, (ok, val, thr) in bars_of(text).items():
            d = acc.setdefault(b, {"passes": 0, "den": 0, "vals": [], "tokens": [],
                                   "threshold": thr})
            if d["threshold"] != thr:
                raise AssertionError("bar %s printed two different thresholds: %r / %r"
                                     % (b, d["threshold"], thr))
            d["den"] += 1
            d["passes"] += 1 if ok else 0
            v = num(val)
            if v is None:
                d["tokens"].append(val)
            else:
                d["vals"].append(v)
    return acc


def wildcard(acc, suffix):
    """Fold the per-stage rows of a bar id the record carries as `*.<suffix>`."""
    keys = sorted(b for b in acc if b.split(".", 1)[1] == suffix)
    out = {"passes": 0, "den": 0, "vals": [], "tokens": [],
           "threshold": acc[keys[0]]["threshold"]}
    for k in keys:
        if acc[k]["threshold"] != out["threshold"]:
            raise AssertionError("wildcard %s: %s prints a different threshold" % (suffix, k))
        out["passes"] += acc[k]["passes"]
        out["den"] += acc[k]["den"]
        out["vals"] += acc[k]["vals"]
        out["tokens"] += acc[k]["tokens"]
    return out


def envelope_text(d):
    """The record's envelope column, in the strict grammar load_record() parses."""
    if d["vals"] and d["tokens"]:
        raise AssertionError("bar mixes numeric and non-numeric values: %r" % d)
    if d["vals"]:
        return "min %s max %s" % (fmt(min(d["vals"])), fmt(max(d["vals"])))
    return "tokens {%s}" % ",".join(sorted(set(d["tokens"])))


# --------------------------------------------------------------------------
# ladder_record.txt
# --------------------------------------------------------------------------
ROW = re.compile(r"^\s*(\*|S\d\w*)\.(\w+)\s*\|\s*(.+?)\s*\|\s*(\d+)\s*/\s*(\d+)\s*\|\s*(.+?)\s*$")


def load_record(path=RECORD):
    """{bar: dict(threshold, passes, den, env, lo, hi, tokens)}.

    Pipe-delimited on purpose: round 2 split the columns on whitespace, and a
    threshold string like `tail900 >= 1871.5 of 1900` or `K in {8,12}` is only
    unambiguous with a real delimiter.
    """
    rec = {}
    for ln in open(path, encoding="utf-8"):
        if ln.lstrip().startswith("#") or "|" not in ln:
            continue
        m = ROW.match(ln.rstrip("\n"))
        if not m:
            continue
        env = m.group(6)
        d = {"threshold": m.group(3), "passes": int(m.group(4)),
             "den": int(m.group(5)), "env": env, "lo": None, "hi": None, "tokens": None}
        me = re.match(r"^min\s+(-?[\d.]+)\s+max\s+(-?[\d.]+)$", env)
        mt = re.match(r"^tokens\s+\{(.*)\}$", env)
        if me:
            d["lo"], d["hi"] = float(me.group(1)), float(me.group(2))
        elif mt:
            d["tokens"] = [x.strip() for x in mt.group(1).split(",") if x.strip()]
        else:
            raise AssertionError("ladder_record.txt: envelope column %r does not parse. "
                                 "Grammar is `min <x> max <y>` or `tokens {a,b}`." % env)
        rec[m.group(1) + "." + m.group(2)] = d
    if not rec:
        raise AssertionError("ladder_record.txt parsed to zero rows")
    return rec


def rec_for(rec, bar):
    """A bar's row, falling back to the `*.<suffix>` wildcard row."""
    return rec.get(bar) or rec.get("*." + bar.split(".", 1)[1])


def bar_const(threshold):
    """The bar's own constant: the FIRST numeric literal in its threshold text.

    Used only to REPORT margin-vs-spread. `late_thr >= 1.50 Mb` -> 1.50;
    `tail900 >= 1871.5 of 1900` -> 1871.5; `inorder == True` -> None.

    The lookbehind is load-bearing: without it `p1share < 8.0%` reads 1 out of
    the IDENTIFIER and `tail900 >= 1871.5` reads 900, which silently reported
    nonsense margins for four bars.
    """
    m = re.search(r"(?<![\w.])-?\d+(?:\.\d+)?", threshold or "")
    return float(m.group(0)) if m else None
