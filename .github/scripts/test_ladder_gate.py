"""Validate .github/scripts/ladder_gate.py in every direction, against a STUB
pathsim that prints BAR lines. The real pathsim needs a Go daemon and there is no
Go toolchain on this PC, so the gate's LOGIC is what is tested here -- the stub is
synthetic and labelled as such. The last block replays EVERY one of the REAL
recorded CI runs through pathsim's real source, which is not synthetic. That
block grows with the record: it was 14 runs, it is now 69.

ROUND 3. Round 2's 26 checks all passed while an independent verifier diluted six
of the twelve gated magnitude bars to near-vacuity on a real runner and kept the
fatal job green, fabricated a class for `S3.thr`, and fed a stub with
`S2.tail=0/1900` / `S3.peerloss=100%` / 93-99% losses / `S6.k=0` to exit 0. Every
one of those three attacks is now a check below, run against the gate as shipped:

  H1  the verifier's SIX threshold substitutions, singly and all at once
  H2  a class moved by hand, with and without a fabricated pass count
  H3  the vacuous stub, plus single-bar drift in each class and in each direction

ROUND 3 FIX ROUND. Two more attacks are checks below, both from the verify that
found them:

  H4  a class declared GATED while the record says the bar flips -- specifically
      S5.loss, the bar that reddened the fatal job on a clean tree and was moved
      to UNGATED by re-measuring. Declaring it GATED again must exit 2.
  H5  the per-stage magnitude-coverage report is DERIVED. Round 3 printed
      "every stage S1..S9 now has at least one FATAL magnitude check" as a
      constant string; a class move would have left that string printing a lie
      next to a green job.

A stub now prints each bar's REAL threshold text and a REAL in-envelope value,
both taken from ladder_record.txt -- round 2's stub printed `bar=b value=v`,
which is precisely why it could not see a diluted threshold.
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(sys.argv[1])
PY = sys.executable
SIM = os.path.join(REPO, "p4-bondagg", "sim")
sys.path.insert(0, SIM)
import ladder_replay as LR  # noqa: E402

REC = LR.load_record(os.path.join(SIM, "ladder_record.txt"))

# The bar set and the recorded verdicts, taken from ladder_record.txt's pass/den
# column: gated bars PASS, the two known fails FAIL, the six ungated ones at their
# most recent recorded value.
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


def rec_of(bar):
    return LR.rec_for(REC, bar)


def default_value(bar):
    """An in-envelope value for a bar: its recorded min, or its recorded token."""
    row = rec_of(bar)
    if row is None:
        return "0"
    if row["tokens"] is not None:
        return row["tokens"][0]
    return LR.fmt(row["lo"])


def default_threshold(bar):
    row = rec_of(bar)
    return row["threshold"] if row else "?"


def stub(bars, tail_summary=True, extra="", values=None, thresholds=None):
    """A synthetic pathsim printing real thresholds and real in-envelope values."""
    values = values or {}
    thresholds = thresholds or {}
    out = []
    for st, bl in bars.items():
        for bid, ok in bl:
            b = "%s.%s" % (st, bid)
            out.append('print(%r)' % ("BAR %s %s value=%s bar=%s"
                                      % (b, "PASS" if ok else "FAIL",
                                         values.get(b, default_value(b)),
                                         thresholds.get(b, default_threshold(b)))))
    if extra:
        out.append('print(%r)' % extra)
    if tail_summary:
        out.append('print("== LADDER: 8/10 PASS ==")')
    out.append("import sys; sys.exit(1)")
    return "\n".join(out) + "\n"


def run(stub_src, env_extra=None, gate_sub=None, record_sub=None):
    """Run the gate against a temp tree. `gate_sub`/`record_sub` are (old, new)
    text substitutions applied to the copied gate / record, so a tampered
    classification or a tampered baseline can be tested against the REAL gate."""
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, ".github", "scripts"))
        os.makedirs(os.path.join(d, "p4-bondagg", "sim"))
        g = open(os.path.join(REPO, ".github", "scripts", "ladder_gate.py"),
                 encoding="utf-8").read()
        for a, bsub in (gate_sub or []):
            assert a in g, "gate substitution target not found: %r" % (a,)
            g = g.replace(a, bsub)
        open(os.path.join(d, ".github", "scripts", "ladder_gate.py"), "w",
             encoding="utf-8", newline="\n").write(g)
        r = open(os.path.join(SIM, "ladder_record.txt"), encoding="utf-8").read()
        if record_sub:
            assert record_sub[0] in r, "record substitution target not found"
            r = r.replace(record_sub[0], record_sub[1])
        open(os.path.join(d, "p4-bondagg", "sim", "ladder_record.txt"), "w",
             encoding="utf-8", newline="\n").write(r)
        shutil.copy(os.path.join(SIM, "ladder_replay.py"),
                    os.path.join(d, "p4-bondagg", "sim", "ladder_replay.py"))
        open(os.path.join(d, "p4-bondagg", "sim", "pathsim.py"), "w",
             encoding="utf-8", newline="\n").write(stub_src)
        env = dict(os.environ, PYTHONHASHSEED="0")
        env.update(env_extra or {})
        p = subprocess.run([PY, os.path.join(d, ".github", "scripts", "ladder_gate.py")],
                           capture_output=True, text=True, env=env)
        return p.returncode, p.stdout + p.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


EQUIV_FILES = ["ladder_equiv_check.py", "ladder_replay.py", "pathsim.py",
               "ladder_base_pathsim.frozen.py", "ladder_ci_runs.json",
               "ladder_record.txt"]


def run_equiv(record_sub=None, pathsim_sub=None):
    """Run ladder_equiv_check.py against a temp copy of the sim dir, optionally
    with the record or pathsim.py tampered. The git cross-check SKIPs there (no
    repo), which is the same path CI takes on the history-free mirror."""
    d = tempfile.mkdtemp()
    try:
        sim = os.path.join(d, "p4-bondagg", "sim")
        os.makedirs(sim)
        for f in EQUIV_FILES:
            shutil.copy(os.path.join(SIM, f), os.path.join(sim, f))
        for name, sub in (("ladder_record.txt", record_sub), ("pathsim.py", pathsim_sub)):
            if not sub:
                continue
            t = open(os.path.join(sim, name), encoding="utf-8").read()
            assert sub[0] in t, "%s substitution target not found: %r" % (name, sub[0])
            open(os.path.join(sim, name), "w", encoding="utf-8",
                 newline=chr(10)).write(t.replace(sub[0], sub[1]))
        p = subprocess.run([PY, os.path.join(sim, "ladder_equiv_check.py")],
                           capture_output=True, text=True,
                           env=dict(os.environ, PYTHONHASHSEED="0"))
        return p.returncode, p.stdout + p.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


fails = 0


def check(name, got, want, needle=None, blob=""):
    global fails
    ok = (got == want) and (needle is None or needle in blob)
    print("  %-58s exit=%-2s want=%-2s %s" % (name, got, want, "ok" if ok else "MISMATCH"))
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
check("UNGATED bars fail in-envelope -> still PASS, reported", rc, 0, "S6.k         FAIL", out)

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
# H1 -- the verifier's SIX threshold dilutions. Each one kept the fatal job green
# in round 2, on a real runner, with `delivered >= 1` printed beside its own
# [min 2424 max 2640] envelope. Each must now RED, singly and together.
# ---------------------------------------------------------------------------
print("\nH1 -- threshold dilution (the six substitutions demonstrated on the runner):")
DILUTIONS = {
    "S1.share":  "p1share < 95.0%",
    "S2.share":  "p1share > 0.1%",
    "S2b.deliv": "delivered >= 1",
    "S3.thr":    "late_thr >= 0.01 Mb",
    "S4.tail":   "tail >= 1 of 400",
    "S7.k":      "K in {8,12,20,0,-}",
}
for bar, thr in DILUTIONS.items():
    rc, out = run(stub(BARS, thresholds={bar: thr}))
    check("%s diluted to %r" % (bar, thr), rc, 2, "%s is gated against" % bar, out)

rc, out = run(stub(BARS, thresholds=DILUTIONS))
check("all six diluted at once", rc, 2, "structure check failed (6 problem(s))", out)

rc, out = run(stub(BARS, thresholds={"S2.loss": "loss <= 99.00%"}))
check("an UNGATED bar's threshold diluted (S2.loss)", rc, 2, "S2.loss is gated against", out)

rc, out = run(stub(BARS, thresholds={"S3.peerloss": "median_peerloss <= 99.0%"}))
check("a KNOWN_FAIL bar's threshold diluted (S3.peerloss)", rc, 2,
      "S3.peerloss is gated against", out)

rc, out = run(stub(BARS, thresholds={"S5.order": "inorder == False"}))
check("a wildcard-row bar's threshold changed (S5.order)", rc, 2,
      "S5.order is gated against", out)

# ---------------------------------------------------------------------------
# H2 -- class membership must follow the record's pass count, not a comment
# ---------------------------------------------------------------------------
print("")
print("H2 -- class membership vs the record's own pass count:")
MOVE_THR = [('"S3.thr", "S4.tail"', '"S4.tail"'),
            ('UNGATED = ["S2.loss"', 'UNGATED = ["S3.thr", "S2.loss"')]
rc, out = run(stub(BARS), gate_sub=MOVE_THR)
check("S3.thr declared UNGATED while the record says den/den", rc, 2,
      "S3.thr is declared UNGATED", out)

b = copy.deepcopy(BARS); b["S3"] = [("order", 1), ("dup", 1), ("loss", 1),
                                    ("thr", 0), ("rate", 1), ("peerloss", 0)]
rc, out = run(stub(b), gate_sub=MOVE_THR)
check("...and a FAILING S3.thr under that fabricated class", rc, 2,
      "S3.thr is declared UNGATED", out)

FAKE_COUNT = ("S3.thr      | late_thr >= 1.50 Mb       |    69/69",
              "S3.thr      | late_thr >= 1.50 Mb       |    59/69")
rc, out = run(stub(b), gate_sub=MOVE_THR, record_sub=FAKE_COUNT)
check("...with the record's count ALSO fabricated to 59/69 (gate alone cannot see it)",
      rc, 0, "ladder gate PASS", out)
rc, out = run_equiv(record_sub=FAKE_COUNT)
check("...but ladder_equiv_check recomputes the count from every run", rc, 1,
      "DIVERGENT record S3.thr pass/den", out)

rc, out = run(stub(BARS), gate_sub=[('"S5.loss", "S6.loss", "S6.k"', '"S5.loss", "S6.k"'),
                                    ('"S2.tail":     "0/69', '"S6.loss": "fabricated", "S2.tail":     "0/69')])
check("a 28/69 bar declared KNOWN_FAIL (S6.loss)", rc, 2, "S6.loss is declared KNOWN_FAIL", out)

rc, out = run(stub(BARS), gate_sub=[('UNGATED = ["S2.loss", ', 'UNGATED = ['),
                                    ('["S1.loss", ', '["S2.loss", "S1.loss", ')])
check("a 28/69 bar declared GATED (S2.loss)", rc, 2, "S2.loss is declared GATED", out)

# H4 -- the bar this fix round moved. Declaring it GATED again must fail closed,
# and the message must say what the record says, so the next reader re-measures
# instead of re-declaring.
print("")
print("H4 -- S5.loss, the bar that reddened the fatal job, cannot be re-declared:")
rc, out = run(stub(BARS), gate_sub=[('"S5.loss", "S6.loss"', '"S6.loss"'),
                                    ('["S1.loss", ', '["S5.loss", "S1.loss", ')])
check("S5.loss declared GATED while the record says 67/69", rc, 2,
      "S5.loss is declared GATED but the record says 67/69", out)

b5 = copy.deepcopy(BARS); b5["S5"] = [("order", 1), ("dup", 1), ("loss", 0)]
rc, out = run(stub(b5, values={"S5.loss": "1.70%"}))
check("the real 1.70%% excursion (run 33336749301) is reported, not fatal", rc, 0,
      "ladder gate PASS", out)
check("...and it is PRINTED as a fail, not hidden", "BAR S5.loss FAIL" in out or
      "S5.loss      FAIL" in out, True, None, out)

rc, out = run(stub(b5, values={"S5.loss": "5.00%"}))
check("...but 5.00%% is outside the measured band and IS fatal", rc, 1,
      "DRIFT       S5.loss", out)

print("")
print("H5 -- per-stage magnitude coverage is derived, not a printed constant:")
rc, out = run(stub(BARS))
check("the clean run names the stages with no threshold-gated magnitude bar",
      "stages with NO threshold-gated magnitude bar : S5, S6, S8" in out, True, None, out)
rc, out = run(stub(BARS),
              gate_sub=[('"S4.loss", "S9.loss"', '"S4.loss"'),
                        ('UNGATED = ["S2.loss"', 'UNGATED = ["S9.loss", "S2.loss"')],
              record_sub=("S9.loss     | loss <= 45.00%            |    69/69",
                          "S9.loss     | loss <= 45.00%            |    59/69"))
check("S9.loss moved to UNGATED (with the record agreeing) -> S9 joins the line",
      "stages with NO threshold-gated magnitude bar : S5, S6, S8, S9" in out, True,
      None, out)
check("...and that run is still green, so the line is not a failure artifact",
      rc, 0, "ladder gate PASS", out)

# H3 -- a floor on KNOWN_FAIL and UNGATED bars, in both directions
# ---------------------------------------------------------------------------
print("\nH3 -- the DRIFT band, fatal, in every class and both directions:")
VACUOUS = {"S2.tail": "0/1900", "S3.peerloss": "100.0%", "S2.loss": "99.00%",
           "S6.loss": "93.00%", "S7.loss": "97.00%", "S8.loss": "95.00%",
           "S6.k": "0"}
rc, out = run(stub(BARS, values=VACUOUS))
check("the verifier's vacuous stub (7 bars far out of envelope)", rc, 1,
      "DRIFT       S2.tail", out)
check("...and it names every one of the seven", out.count("\n  DRIFT       "), 7, None, out)

rc, out = run(stub(BARS, values={"S2.tail": "0/1900"}))
check("KNOWN_FAIL drifts low (S2.tail 0)", rc, 1, "DRIFT       S2.tail", out)

rc, out = run(stub(BARS, values={"S3.peerloss": "100.0%"}))
check("KNOWN_FAIL drifts high (S3.peerloss 100%)", rc, 1, "DRIFT       S3.peerloss", out)

rc, out = run(stub(BARS, values={"S6.loss": "93.00%"}))
check("UNGATED drifts high (S6.loss 93%)", rc, 1, "DRIFT       S6.loss", out)

rc, out = run(stub(BARS, values={"S6.k": "0"}))
check("UNGATED enumerated drifts (S6.k = 0)", rc, 1, "DRIFT       S6.k", out)

rc, out = run(stub(BARS, values={"S2b.deliv": "99999"}))
check("GATED drifts on the GOOD side (S2b.deliv 99999)", rc, 1, "DRIFT       S2b.deliv", out)

rc, out = run(stub(BARS, values={"S3.loss": "50.00%"}))
check("GATED regression inside its dead slack (S3.loss 50% < 55% bar)", rc, 1,
      "DRIFT       S3.loss", out)

rc, out = run(stub(BARS, values={"S2.loss": "9.43%"}))
check("UNGATED at its recorded MAX -> inside the band, PASS", rc, 0, "ladder gate PASS", out)

rc, out = run(stub(BARS, values={"S6.loss": "1.73%"}))
check("S6.loss 1.73% (the real run-33321817968 excursion) -> inside band", rc, 0,
      "ladder gate PASS", out)

rc, out = run(stub(BARS, values={"S3.peerloss": "34.0%"}))
check("S3.peerloss 34.0% (the real run-33323192348 excursion) -> inside band", rc, 0,
      "ladder gate PASS", out)

rc, out = run(stub(BARS, values={"S1.share": "50.0%"}))
check("a zero-spread GATED bar has no band -> only its threshold gates it", rc, 0,
      "no band: record spread is 0", out)

# ---------------------------------------------------------------------------
# The baseline file itself must be well-formed, or nothing above means anything
# ---------------------------------------------------------------------------
print("\nrecord integrity:")
rc, out = run(stub(BARS), record_sub=("| min 2.64 max 9.43", "| roughly 3 to 9"))
check("record envelope column made unparseable", rc, 2, "does not parse", out)

rc, out = run(stub(BARS), record_sub=("| holdouts 69 informative 2 excluded 0 skipped 0\nS2.share",
                                      "| holdouts lots\nS2.share"))
check("record hold-out column made unparseable", rc, 2,
      "hold-out column", out)

rc, out = run(stub(BARS), record_sub=(
    "S2.tail     | tail900 >= 1871.5 of 1900 |     0/69 | min 1662 max 1849   "
    "| holdouts 69 informative 2 excluded 0 skipped 0\n", ""))
check("a classified bar's row deleted from the record", rc, 2,
      "has NO row in ladder_record.txt", out)

# ---------------------------------------------------------------------------
# The SECOND, independent catch for H1: ladder_equiv_check.py compares the bar
# EXPRESSIONS structurally against the frozen pre-refactor source. Round 2
# compared them only by boolean outcome on the 14 recorded runs, which is blind
# to any dilution that flips no recorded verdict -- all six below.
# ---------------------------------------------------------------------------
print("")
print("H1 (second catch) -- ladder_equiv_check.py on a diluted pathsim.py:")
SRC_DILUTIONS = [
    ("S1.share",  '("share", share1<0.08,', '("share", share1<0.95,'),
    ("S2.share",  '("share", share1>0.25,', '("share", share1>0.001,'),
    ("S2b.deliv", '("deliv", n>=1800,', '("deliv", n>=1,'),
    ("S3.thr",    '("thr",      thr>=1.5,', '("thr",      thr>=0.01,'),
    ("S4.tail",   '("tail", tail>=392,', '("tail", tail>=1,'),
    ("S7.k",      '("k", k in ("8","12"),', '("k", k in ("8","12","20","0","-"),'),
    ("S2.tail",   'tailok = tl >= (2800-900)*0.985', 'tailok = tl >= (2800-900)*0.50'),
]
rc, out = run_equiv()
check("clean tree", rc, 0, "0 divergent", out)
for bar, a, bb in SRC_DILUTIONS:
    rc, out = run_equiv(pathsim_sub=(a, bb))
    check("pathsim %s diluted -> structural divergence" % bar, rc, 1,
          "DIVERGENT %s" % bar.split(".")[0], out)

rc, out = run_equiv(record_sub=("|    28/69 | min 2.64 max 9.43",
                                "|    69/69 | min 2.64 max 9.43"))
check("record pass count fabricated (S2.loss 28/69 -> 69/69)", rc, 1,
      "DIVERGENT record S2.loss pass/den", out)

rc, out = run_equiv(record_sub=("| min 1662 max 1849", "| min 0 max 1900"))
check("record envelope widened by hand (S2.tail)", rc, 1,
      "DIVERGENT record S2.tail envelope", out)

rc, out = run_equiv(record_sub=("S5.loss     | loss <= 1.00%             |    67/69",
                                "S5.loss     | loss <= 1.00%             |    69/69"))
check("record pass count fabricated to re-GATE S5.loss (67/69 -> 69/69)", rc, 1,
      "DIVERGENT record S5.loss pass/den", out)

rc, out = run_equiv(record_sub=("S7.k        | K in {8,12}               |    69/69 | "
                                "min 8 max 12        | holdouts 69 informative 0 excluded 0 skipped 0",
                                "S7.k        | K in {8,12}               |    69/69 | "
                                "min 8 max 12        | holdouts 69 informative 9 excluded 0 skipped 0"))
check("hold-out audit fabricated (S7.k informative 0 -> 9)", rc, 1,
      "DIVERGENT record S7.k hold-outs", out)

# ---------------------------------------------------------------------------
# The load-bearing check: replay EVERY recorded CI run through the REAL
# verdict()/bars source in pathsim.py and require ladder_gate to exit 0 on every
# one. This is what licenses dropping `continue-on-error`, and it is the check
# that would have caught the shipped state: run 33336749301 is in the record and
# the round-3 gate exits 1 on it.
#
# It is NOT a prospective test. Every run here is also an input to the record, so
# passing is close to guaranteed by construction; what it proves is CONSISTENCY
# -- that no recorded run contradicts the classification derived from all of
# them. The prospective test is the next CI run, and the record says so.
# ---------------------------------------------------------------------------
psrc = open(LR.PATHSIM, encoding="utf-8").read()
recorded = json.load(open(LR.RUNS))


def as_stub(text):
    return "import sys\nsys.stdout.write(%r)\nsys.exit(1)\n" % text


print("\nreplay of all %d recorded CI runs through the real verdict()/bars source:"
      % len(recorded))
for _r in recorded:
    _text, _np = LR.replay(psrc, _r)
    rc, out = run(as_stub(_text))
    check("run %s (pathsim %d/10)" % (_r["run"], _np), rc, 0, "ladder gate PASS", out)

# ... and red on anything worse: break one GATED bar inside a real replayed run.
_text, _ = LR.replay(psrc, recorded[0])
rc, out = run(as_stub(_text.replace("BAR S4.tail PASS", "BAR S4.tail FAIL")))
check("real replay with one GATED bar broken", rc, 1, "REGRESSION  S4.tail", out)

# ... and red when a real replayed run carries a diluted threshold.
rc, out = run(as_stub(_text.replace("bar=delivered >= 1800", "bar=delivered >= 1")))
check("real replay with S2b.deliv diluted to `>= 1`", rc, 2,
      "S2b.deliv is gated against", out)

print("\n%s -- %d mismatch(es)" % ("FAIL" if fails else "ALL CHECKS PASS", fails))
sys.exit(1 if fails else 0)
