"""Validate .github/scripts/ladder_gate.py in every direction, against a STUB
pathsim that prints BAR lines. The real pathsim needs a Go daemon and there is
no Go toolchain on this PC, so the gate's LOGIC is what is tested here -- the
stub is synthetic and labelled as such.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = sys.argv[1]
PY = sys.executable

# The bar set and the recorded verdicts, taken from ladder_record.txt's pass/14
# column: gated bars PASS, the two known fails FAIL, the six ungated ones at
# their most recent recorded value.
BARS = {
    "S1":  [("order", 1), ("dup", 1), ("loss", 1), ("share", 1)],
    "S2":  [("order", 1), ("dup", 1), ("loss", 0), ("share", 1), ("tail", 0)],
    "S2b": [("order", 1), ("dup", 1), ("loss", 1), ("deliv", 1)],
    "S3":  [("order", 1), ("dup", 1), ("loss", 1), ("thr", 1), ("rate", 1), ("peerloss", 0)],
    "S4":  [("order", 1), ("dup", 1), ("loss", 1), ("tail", 1)],
    "S5":  [("order", 1), ("dup", 1), ("loss", 1)],
    "S6":  [("order", 1), ("dup", 1), ("loss", 1), ("k", 1)],
    "S7":  [("order", 1), ("dup", 1), ("loss", 1), ("k", 1)],
    "S8":  [("order", 1), ("dup", 1), ("loss", 1)],
    "S9":  [("order", 1), ("dup", 1), ("loss", 1)],
}


def stub(bars, tail_summary=True, extra=""):
    out = []
    for st, bl in bars.items():
        for bid, ok in bl:
            out.append('print("BAR %s.%s %s value=v bar=b")' % (st, bid, "PASS" if ok else "FAIL"))
    if extra:
        out.append('print("%s")' % extra)
    if tail_summary:
        out.append('print("== LADDER: 8/10 PASS ==")')
    out.append("import sys; sys.exit(1)")
    return "\n".join(out) + "\n"


def run(stub_src, env_extra=None):
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, ".github", "scripts"))
        os.makedirs(os.path.join(d, "p4-bondagg", "sim"))
        shutil.copy(os.path.join(REPO, ".github", "scripts", "ladder_gate.py"),
                    os.path.join(d, ".github", "scripts", "ladder_gate.py"))
        shutil.copy(os.path.join(REPO, "p4-bondagg", "sim", "ladder_record.txt"),
                    os.path.join(d, "p4-bondagg", "sim", "ladder_record.txt"))
        open(os.path.join(d, "p4-bondagg", "sim", "pathsim.py"), "w").write(stub_src)
        env = dict(os.environ, PYTHONHASHSEED="0")
        env.update(env_extra or {})
        p = subprocess.run([PY, os.path.join(d, ".github", "scripts", "ladder_gate.py")],
                           capture_output=True, text=True, env=env)
        return p.returncode, p.stdout + p.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


import copy
fails = 0


def check(name, got, want, needle=None, blob=""):
    global fails
    ok = (got == want) and (needle is None or needle in blob)
    print("  %-52s exit=%-2s want=%-2s %s" % (name, got, want, "ok" if ok else "MISMATCH"))
    if not ok:
        fails += 1
        if needle and needle not in blob:
            print("      expected text not found: %r" % needle)


print("ladder_gate.py validation (synthetic stub pathsim -- no Go on this PC)")

rc, out = run(stub(BARS))
check("baseline shape (2 known fails, 1 ungated fail)", rc, 0, "ladder gate PASS", out)

b = copy.deepcopy(BARS); b["S4"] = [("order", 1), ("dup", 1), ("loss", 1), ("tail", 0)]
rc, out = run(stub(b))
check("GATED bar regresses (S4.tail)", rc, 1, "REGRESSION  S4.tail", out)

b = copy.deepcopy(BARS); b["S1"] = [("order", 0), ("dup", 1), ("loss", 1), ("share", 1)]
rc, out = run(stub(b))
check("GATED invariant regresses (S1.order)", rc, 1, "REGRESSION  S1.order", out)

b = copy.deepcopy(BARS); b["S6"] = [("order", 1), ("dup", 1), ("loss", 0), ("k", 0)]
rc, out = run(stub(b))
check("UNGATED bars fail -> still PASS, reported", rc, 0, "S6.k         FAIL", out)

b = copy.deepcopy(BARS); b["S2"] = [("order", 1), ("dup", 1), ("loss", 1), ("share", 1), ("tail", 1)]
rc, out = run(stub(b))
check("KNOWN_FAIL bar starts passing -> PASS + note", rc, 0, "That is an improvement", out)

b = copy.deepcopy(BARS); del b["S7"]
rc, out = run(stub(b))
check("a stage never ran (truncated run)", rc, 2, "stage S7 emitted bars NONE", out)

b = copy.deepcopy(BARS); b["S3"] = [x for x in b["S3"] if x[0] != "peerloss"]
rc, out = run(stub(b))
check("a bar silently deleted from a stage", rc, 2, "STRUCTURE: stage S3 emitted bars", out)

b = copy.deepcopy(BARS); b["S5"] = b["S5"] + [("newbar", 1)]
rc, out = run(stub(b))
check("an UNCLASSIFIED bar appears -> fail closed", rc, 2, "UNCLASSIFIED bar id(s): S5.newbar", out)

rc, out = run(stub(BARS, tail_summary=False))
check("no '== LADDER:' summary (pathsim died late)", rc, 2, "did not finish", out)

rc, out = run("import sys; sys.exit(3)")
check("pathsim exits 3 (harness failure, not a verdict)", rc, 2, "harness failure", out)

rc, out = run(stub(BARS), env_extra={"PYTHONHASHSEED": "7"})
check("PYTHONHASHSEED drifts from the pinned '0'", rc, 2, "Refusing to compare", out)

# ---------------------------------------------------------------------------
# The load-bearing check: replay all 14 RECORDED CI runs through the REAL
# verdict()/bars source in pathsim.py and require ladder_gate to exit 0 on every
# one. This is what licenses dropping `continue-on-error`. pathsim itself scored
# 7/10 or 8/10 on all 14 -- the gate must be green on exactly that behaviour and
# red on anything worse.
# ---------------------------------------------------------------------------
import ast
import contextlib
import io
import json

SIM = os.path.join(REPO, "p4-bondagg", "sim")
psrc = open(os.path.join(SIM, "pathsim.py"), encoding="utf-8").read()
recorded = json.load(open(os.path.join(SIM, "ladder_ci_runs.json")))


def _seg(n):
    return ast.get_source_segment(psrc, n)


_kw, _der, _vsrc = {}, {}, None
for _node in ast.parse(psrc).body:
    if isinstance(_node, ast.FunctionDef) and _node.name == "verdict":
        _vsrc = _seg(_node)
    if isinstance(_node, ast.FunctionDef) and re.fullmatch(r"S\d\w*", _node.name):
        for _stt in _node.body:
            if isinstance(_stt, ast.Assign) and getattr(_stt.targets[0], "id", "") == "tailok":
                _der[_node.name] = _seg(_stt)
        for _sub in ast.walk(_node):
            if isinstance(_sub, ast.Call) and getattr(_sub.func, "id", "") == "verdict":
                _kw[_node.name] = {k.arg: _seg(k.value) for k in _sub.keywords}


class _L:
    def __enter__(self): return None
    def __exit__(self, *a): return False


def replay(r):
    """Reproduce pathsim's stdout for one recorded run, through the real source."""
    buf, npass = io.StringIO(), 0
    for stage in ["S1", "S2", "S2b", "S3", "S4", "S5", "S6", "S7", "S8", "S9"]:
        line = r["st"][stage]

        def g(pat, c=float):
            m = re.search(pat, line)
            return c(m.group(1)) if m else None

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
        if stage in _der:
            exec(_der[stage], env)
        bars = eval(_kw[stage].get("bars", "()"), env)
        lossbar = eval(_kw[stage].get("lossbar", "0.01"), {})
        fwd = int(re.search(r"fwd=(\d+)/", line).group(1))
        npkts = int(re.search(r"fwd=\d+/(\d+)", line).group(1))
        ns = dict(glock=_L(), got=list(range(fwd)), gtimes=[], dcnt={0: 0, 1: 0}, dupseq=[0])
        exec(_vsrc, ns)
        with contextlib.redirect_stdout(buf):
            if ns["verdict"]("%s x" % stage, npkts, lossbar=lossbar, bars=bars):
                npass += 1
    buf.write("== LADDER: %d/10 PASS ==\n" % npass)
    return buf.getvalue(), npass


def as_stub(text):
    return "import sys\nsys.stdout.write(%r)\nsys.exit(1)\n" % text


print()
print("replay of the 14 recorded CI runs through the real verdict()/bars source:")
for _r in recorded:
    _text, _np = replay(_r)
    rc, out = run(as_stub(_text))
    check("run %s (pathsim %d/10)" % (_r["run"], _np), rc, 0, "ladder gate PASS", out)

# ... and red on anything worse: break one GATED bar inside a real replayed run.
_text, _ = replay(recorded[0])
rc, out = run(as_stub(_text.replace("BAR S4.tail PASS", "BAR S4.tail FAIL")))
check("real replay with one GATED bar broken", rc, 1, "REGRESSION  S4.tail", out)

print("\n%s -- %d mismatch(es)" % ("FAIL" if fails else "ALL CHECKS PASS", fails))
sys.exit(1 if fails else 0)
