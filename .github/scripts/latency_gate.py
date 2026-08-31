#!/usr/bin/env python3
# =============================================================================
# latency_gate.py -- CI gate for the OBJ-D LATENCY BARS (SPD-1..6, HOLD-1..4).
# Task U14 (docs/ROADMAP.md epic 1).
#
# Sibling of rig_paired_gate.py (U8) and built to the same shape deliberately:
# the battery always exits 0 and prints a verdict; this wrapper pins the config,
# pins the instrument, checks the structure, classifies the failures, and pins
# the MEASURED MARGIN of every check line.
#
# WHAT IS DIFFERENT HERE, AND IT IS THE POINT OF THE UNIT
# -----------------------------------------------------------------------------
# 1. THE GATE/REPORT SPLIT IS MEASURED, NOT ASSERTED. U33 established that even
#    PAIRED quantities on this rig move about 0.9 pt across stall geometry, and
#    that the whole battery scores ONE hand-placed geometry. So a bar whose
#    verdict flips when the stall phase is rotated is not established by the
#    canonical point, and gating it would be gating a coin flip. The split below
#    comes from `p4-bondagg/sim/latency-bars/out/geometry.md` -- five geometries
#    (canonical + four `rig_checks.phase_drops` rotations), same seeds, same
#    bars. GATED = verdict identical on all five. REPORTED = it flipped.
#
#    NOTE what that rule IS and is not. It is VERDICT STABILITY across the
#    geometry sample (`geometry_split.py:16-19`). It is NOT U33's "a paired
#    margin below roughly 1 pt is not geometry-established", which this gate does
#    not implement: SPD-2a is GATED at a measured canonical margin of exactly
#    0.046310 and 0.000000 on three of the five geometries. That is a deliberate
#    knife edge on a job with no `continue-on-error`, and it is recorded as an
#    honest fail below rather than fixed by demoting the bar.
#
# 2. IT RUNS A MUTATION MATRIX. Four pre-registered DEFECTS, run on every CI run,
#    each of which must turn a named set of bars RED -- the gate RUNS them, it
#    does not take the demonstration on trust from a commit message. This project
#    has shipped two bars that passed while deliberately weakened (a 4x B2
#    dilution and a hardcoded SEEDS=2 both exited 0,
#    `rig_paired_gate.py:preflight`), and both were caught by review rather than
#    by CI.
#
# 3. IT PINS EVERY CHECK LINE'S MARGIN. This is the fix for the FOURTH
#    weakened-green gate in this project, and the previous two mechanisms did not
#    catch it. The attack, measured: dilute four GATED bars (SPD-3a 0.97 -> 0.60,
#    HOLD-1d and HOLD-2b `+burst` -> `+20*burst`, HOLD-4a `< 1e-9` -> `< 5.0` ms),
#    re-measure the hash pin exactly as this unit's own DEMO B/C prescribe, run
#    the gate -> EXIT 0, GATE PASS, all four mutation rows `-> ok`.
#
#    The reason is arithmetic, not luck. A hash pin stops the battery being
#    EDITED-without-declaring-it. A mutation matrix proves a bar can detect a
#    GROSS defect. NEITHER BOUNDS DILUTION: the unit's own published numbers show
#    13x to 30x of headroom under every gated bar carrying a numeric tolerance
#    (SPD-3a clean 0.9993 vs bar 0.97 vs defect 0.5727; HOLD-1d clean 24 vs 527
#    vs defect 8544; HOLD-2b clean 118 vs 1716 vs defect 37077). And the
#    MUST_FAIL shrink-detector only sees bars that ALREADY FAIL -- SPD-2b and
#    SPD-5a, 3 of 15 gated bars. Diluting any of the other 12 moved no line this
#    gate read.
#
#    So: the battery now emits ONE SIGNED MARGIN per check line and PASS is the
#    SIGN of that margin (`latency_battery.py:bar`) -- there is no separate
#    predicate left to widen -- and MARGIN_PIN below pins the margin of all 31
#    check lines, GATED and REPORTED alike, to 9 significant digits. Widening a
#    bar now necessarily moves a pinned number, and the gate prints the delta.
#    A margin that MOVES for an honest reason (the SUT genuinely improved or
#    regressed) is equally loud, and is re-baselined with `--remargin` in the
#    same commit that says what moved and why. That is the same discipline as
#    MUST_FAIL: from here the two are indistinguishable, so both are loud.
#
# EXIT: 0 = gate pass | 1 = gate FAIL | 2 = harness/config error.
# =============================================================================
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
SIMDIR = os.path.join(REPO, 'p4-bondagg', 'sim')
LATDIR = os.path.join(SIMDIR, 'latency-bars')
RCD = os.path.join(SIMDIR, 'pull-study', '03-reserved-composite')

# --- the config the baseline and the geometry study were measured at ---------
CFG = {'SEEDS': '6', 'T': '9.0', 'PYTHONHASHSEED': '0'}

# --- instrument pin ----------------------------------------------------------
# The battery and the ratchet are the MEASURING INSTRUMENT, not the system under
# test: the bar arithmetic, the rigs, the offers and the hold policy all live in
# them. reserved_composite.py / nsched_model.py are deliberately NOT pinned --
# those ARE the system under test and must be free to change and be measured.
# Their IDENTITY is pinned instead, by resolving __file__ under the gate's own
# environment (ADR-004 named the wrong ackclock_sim.py in prose for a day).
PIN = {
    'latency_battery.py': '18977c65a09d935561ef9b5b3bb8b3660d6094137ac2119f481364e897bfcc4d',
    'ratchet.py': '543c068778e2e0aa9b823502416314e2341da2107fc177de2d7d7aafc1b208b6',
}

# --- bar classification ------------------------------------------------------
# DERIVED, in two independent studies, both of which are re-runnable
# (`p4-bondagg/sim/latency-bars/out/RUNME.sh`):
#
#   out/geometry.md   -- 31 checks x 5 stall geometries. A bar whose VERDICT
#                        flips when the stall phase is rotated is not established
#                        by the canonical point. Demoted: HOLD-1c, HOLD-2a,
#                        SPD-3b, SPD-4a, SPD-4b, SPD-5b, SPD-5c.
#   out/mutations.md  -- every gated bar against 6 defect injections plus the
#                        clean control. A bar no known-bad tree can redden is not
#                        a gate. Demoted: HOLD-1a, HOLD-1b, HOLD-3a, HOLD-3b,
#                        SPD-1c, SPD-1d, each with the MEASURED reason it cannot
#                        fail. The GATE itself runs a 4-defect SUBSET of that
#                        study; see MUTATIONS.
#
# 15 of 28 bar ids survive both. The other 13 are printed on every run and gate
# nothing. That is the honest number and it is not padded upward.
GATED = ('HOLD-1d', 'HOLD-2b', 'HOLD-4a', 'HOLD-4b', 'HOLD-4c',
         'SPD-1a', 'SPD-1b', 'SPD-2a', 'SPD-2b', 'SPD-2c', 'SPD-3a',
         'SPD-5a', 'SPD-6a', 'SPD-6b', 'SPD-6c')
# Printed, never gated. Two different reasons, both measured; the banner says which.
REPORTED = ('HOLD-1a', 'HOLD-1b', 'HOLD-1c', 'HOLD-2a', 'HOLD-3a', 'HOLD-3b',
            'SPD-1c', 'SPD-1d', 'SPD-3b', 'SPD-4a', 'SPD-4b', 'SPD-5b', 'SPD-5c')

# --- recorded honest fails ---------------------------------------------------
# Measured, published, and NOT weakened away. An entry that stops failing is a
# hard exit 1 in the other direction (see rig_paired_gate.py's MUST_FAIL: a
# shrinking fail set is indistinguishable from a diluted bar).
#
# SCOPE, stated because it was overstated: this detector reaches ONLY the bars
# listed here -- 2 ids, 3 check lines, of 15 gated bars. The other 12 pass on the
# clean tree, so diluting one of them moves no line it reads. That gap is what
# MARGIN_PIN closes; MUST_FAIL is not, and never was, a dilution detector for the
# battery as a whole.
# Measured at SEEDS=6, GEO=canonical (out/geo_canonical.txt), and FAILING on all
# five geometries -- so these are not phase artifacts. Each is a real statement
# that the r1 design's claim does not hold on this rig at its real granularity:
#
#   SPD-2b  `speed`'s p95 at spill is 21 ms against `max`'s 14 ms, scored under
#           the SAME (ratchet) hold on the SAME seeds. r1 sec 8 claims
#           "p95 <= p95(max)" and cites 14 <= 14 -- measured with expF's hold
#           (`max(maxgap+1ms, 10ms)`), not with the derived hold the design
#           adopts. Under the design's own hold the claim is false here.
#   SPD-5a  `speed`'s mid goodput is 0.04% below Dc's at both loads. That is far
#           BELOW the ~0.9 pt band U33 measured paired quantities moving across
#           geometry, so the failure is real but its SIZE is not established.
#           Kept as a fail because the bar is written `>=` with no margin and
#           inventing a margin to clear it is exactly the forbidden move.
MUST_FAIL = {
    ('SPD-2b', 'paired p95 <= p95(max)'),
    ('SPD-5a', 'load=0.65 paired gp >= gp(Dc)'),
    ('SPD-5a', 'load=0.85 paired gp >= gp(Dc)'),
}
TOLERATED = set()

# --- structure ---------------------------------------------------------------
# Exact check-line count per bar id. A battery that died mid-run prints fewer and
# would otherwise read as green. An id NOT in this dict is an UNCLASSIFIED BAR
# and fails the job: a new bar must be triaged (geometry + mutation) deliberately,
# never absorbed because nobody updated a list.
EXPECT = {
    'HOLD-1a': 1, 'HOLD-1b': 1, 'HOLD-1c': 1, 'HOLD-1d': 1,
    'HOLD-2a': 1, 'HOLD-2b': 1,
    'HOLD-3a': 1, 'HOLD-3b': 1,
    'HOLD-4a': 1, 'HOLD-4b': 1, 'HOLD-4c': 1,
    'SPD-1a': 1, 'SPD-1b': 1, 'SPD-1c': 1, 'SPD-1d': 1,
    'SPD-2a': 1, 'SPD-2b': 1, 'SPD-2c': 1,
    'SPD-3a': 1, 'SPD-3b': 1,
    'SPD-4a': 1, 'SPD-4b': 1,
    'SPD-5a': 2, 'SPD-5b': 2, 'SPD-5c': 2,     # two loads each
    'SPD-6a': 1, 'SPD-6b': 1, 'SPD-6c': 1,
}

# --- the mutation matrix -----------------------------------------------------
# defect -> the bar ids that MUST go RED under it.
#
# COVERAGE RULE, and it is CHECKED IN CODE (`check_invariants`), not asserted in
# a comment. Every GATED bar is either
#   (a) a value here -- a defect is demonstrated to redden it every run; or
#   (b) in MUST_FAIL -- it ALREADY fails on the clean tree, so "a defect turns it
#       red" is not a statement that can be made about it.
# Nothing else may be gated. The earlier text here said "every bar this gate
# gates appears at least once as a value here", which was FALSE: SPD-2b and
# SPD-5a appear in no MUTATIONS value, and nothing enforced the claim. Both are
# case (b). The rule is now stated correctly and the code refuses to start if it
# is violated.
# Measured: out/mutations.md. Every entry was observed flipping that bar from
# PASS to FAIL at SEEDS=2, GEO=canonical.
#
# `hold-quantile` (the refuted q=0.99/W=3s hold) is NOT here even though it is a
# valid defect: `holdlib.dyn_release` re-sorts its sample window on every block
# and takes minutes per scenario. Its target bars (HOLD-1d, HOLD-2b) are covered
# by `hold-gran`. Available manually as DEFECT=hold-quantile.
# `rank-mid-meter` is not here either: it reddens SPD-5a and SPD-5c, and both of
# those already fail on the clean tree, so it demonstrates nothing this gate can
# use. Kept in the battery because it is a real refuted design and the next
# person to touch SPD-5 will want it.
MUTATIONS = {
    'hold-gran': ('HOLD-1d', 'HOLD-2b', 'SPD-3a'),
    'rank-hungriest': ('SPD-1a', 'SPD-1b', 'SPD-2c', 'SPD-6a', 'SPD-6b', 'SPD-6c'),
    'rank-static': ('SPD-2a',),
    'ratchet-x3': ('HOLD-4a', 'HOLD-4b', 'HOLD-4c'),
}
# Gated-eligible by geometry, but NO defect reddens them, so they are NOT gated.
# Reasons are measured and written out in out/mutations.md; the short form is that
# r1's bar table wrote four bars against a 1 ms granularity the model does not
# have, and two more against a reference that absorbs the defect they exist to
# catch. Listed here so the job prints them rather than letting them disappear.
NO_RED_DEMO = ('HOLD-1a', 'HOLD-1b', 'HOLD-3a', 'HOLD-3b', 'SPD-1c', 'SPD-1d')

MUT_SEEDS = '2'

# --- the margin pin ----------------------------------------------------------
# (bar id, subject) -> the margin the CLEAN tree prints at SEEDS=6 T=9.0
# GEO=canonical PYTHONHASHSEED=0, as `latency_battery.fmt_margin` formats it
# (`%.9g`, i.e. 9 significant digits: IEEE754 doubles carry ~16, so this leaves
# seven digits of headroom for accumulated rounding while still separating a
# 0.85 pt margin from a 39.93 pt one).
#
# ALL 31 CHECK LINES ARE PINNED, gated and reported alike. A reported bar gates
# nothing, but it is still printed as evidence, and evidence that can be silently
# rewritten is not evidence.
#
# Regenerate with `--remargin`, which prints pinned-vs-measured with the delta so
# the person re-baselining has to look at what moved. Never regenerate it to go
# green; the delta is the finding.
MARGIN_PIN_ROWS = (
    ('SPD-1a', 'spotty-class share == 0 (structural)', '0'),
    ('SPD-1b', 'out-of-order arrivals == 0 (structural)', '0'),
    ('SPD-1c', 'paired p95 <= p95(N=1 eth control) + 2*gran', '20'),
    ('SPD-1d', 'paired gp >= gp(N=1 eth control)', '0'),
    ('SPD-2a', 'paired gp >= gp(max)', '0.0463095384'),
    ('SPD-2b', 'paired p95 <= p95(max)', '-7'),
    ('SPD-2c', 'spotty-class share == 0 at spill (structural)', '0'),
    ('SPD-3a', 'paired gp >= 0.99 * gp(max) [measured ratio]', '0.927219142'),
    ('SPD-3b', 'paired p95 <= 1.03 * p95(max) [measured ratio]', '0.244094488'),
    ('SPD-4a', 'paired gp >= gp(max)', '0.00255872269'),
    ('SPD-4b', 'paired p95 <= p95(max)', '-3.97903932e-13'),
    ('SPD-5a', 'load=0.65 paired gp >= gp(Dc)', '-0.0405865641'),
    ('SPD-5b', 'load=0.65 paired p95 <= p95(Dc)', '23.2778204'),
    ('SPD-5c', 'load=0.65 paired late-discard <= late(Dc)', '-33'),
    ('SPD-5a', 'load=0.85 paired gp >= gp(Dc)', '-0.0448817296'),
    ('SPD-5b', 'load=0.85 paired p95 <= p95(Dc)', '14.4476038'),
    ('SPD-5c', 'load=0.85 paired late-discard <= late(Dc)', '-42'),
    ('SPD-6a', 'share rises or holds into the 90k step (no starvation)', '0'),
    ('SPD-6b', 'share RETURNS to the fits-load value after the step', '0'),
    ('SPD-6c', 'no residual pinning: seg3 share <= seg2 share', '0'),
    ('HOLD-1a', 'edge p50(ratchet) <= p50(343) + 2*gran', '20'),
    ('HOLD-1b', 'edge p95(ratchet) <= p95(343) + 2*gran', '10'),
    ('HOLD-1c', 'edge p99(ratchet) <= p99(343) + 2*gran', '-42'),
    ('HOLD-1d', 'edge late(ratchet) <= late(343) + one event burst', '503'),
    ('HOLD-3a', 'edge p95 of frames enqueued in [0,1s) <= overall p95 + 2*gran', '250'),
    ('HOLD-2a', 'mid p50(ratchet) <= p50(343) + 2*gran', '-2.33304608'),
    ('HOLD-2b', 'mid late(ratchet) <= late(343) + one event burst', '1607'),
    ('HOLD-3b', 'mid p95 of frames enqueued in [0,1s) <= overall p95 + 2*gran', '415.28712'),
    ('HOLD-4a', 'zero observations => hold == gran', '1'),
    ('HOLD-4b', 'injected gap g => hold == g + gran', '0'),
    ('HOLD-4c', 'membership change => hold == spread(D) + gran', '1'),
)
MARGIN_PIN = {(b, s): v for b, s, v in MARGIN_PIN_ROWS}

FAIL_RE = re.compile(r'^\s*FAIL\s+(\S+)\s+(.*?):')
COUNT_RE = re.compile(r'^\s*(\d+) BAR FAILURE\(S\):')
VERDICT_RE = re.compile(r'^\s*(ALL BARS PASS|\d+ BAR FAILURE\(S\):)')
ECHO_RE = re.compile(r'seeds=(\d+)\s+T=([\d.]+)s\s+gran=([\d.]+)ms\s+rig=(\S+)\s+geo=(\S+)\s+defect=(\S+)')
CHECK_RE = re.compile(r'^\s{2}(SPD-\d[a-z]|HOLD-\d[a-z])\s')
MARGIN_RE = re.compile(r'^\s*MARGIN\s+(\S+)\s+\|\s+(.*?)\s+\|\s+(\S+)\s*$')


def die(msg, code=2):
    print('\n!! latency gate: %s' % msg)
    sys.exit(code)


def norm(s):
    return ' '.join(s.split())


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def run_battery(env, seeds, defect, geo='canonical'):
    e = dict(env)
    e['SEEDS'] = str(seeds)
    e['DEFECT'] = defect
    e['GEO'] = geo
    p = subprocess.Popen([sys.executable, '-u', 'latency_battery.py'], cwd=LATDIR,
                         env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1, encoding='utf-8', errors='replace')
    lines = []
    for line in p.stdout:
        lines.append(line.rstrip('\n'))
    rc = p.wait()
    return rc, lines


def fails_of(lines):
    out = []
    for l in lines:
        m = FAIL_RE.match(l)
        if m:
            out.append((m.group(1), norm(m.group(2))))
    return out


def margins_of(lines):
    """[(bar id, subject, margin string)] in the order the battery printed them.

    A list, not a dict: SPD-5a/5b/5c each print TWICE (load 0.65 and 0.85) and
    the subject carries the load, so the (id, subject) key is unique -- but a
    duplicate key would silently swallow one row, and this gate exists because
    something silently swallowed a row."""
    out = []
    for l in lines:
        m = MARGIN_RE.match(l)
        if m:
            out.append((m.group(1), norm(m.group(2)), m.group(3)))
    return out


def check_invariants(pin_count=True):
    """Refuse to run if the gate's own tables contradict each other.

    These are the claims this file's comments make about itself. They were
    comments only, and one of them was FALSE for two of the fifteen gated bars.
    A claim about a data structure belongs in code that reads the data
    structure."""
    bad = []
    covered = set()
    for v in MUTATIONS.values():
        covered |= set(v)
    already_failing = set(b for b, _s in MUST_FAIL)
    for b in GATED:
        if b not in covered and b not in already_failing:
            bad.append('%s is GATED but no defect reddens it and it is not in '
                       'MUST_FAIL -- nobody has shown it can fail' % b)
    for b in sorted(covered - set(GATED)):
        bad.append('%s has a red demo but is not GATED -- either gate it or say '
                   'why in REPORTED/NO_RED_DEMO' % b)
    for b in set(GATED) & set(REPORTED):
        bad.append('%s is in BOTH GATED and REPORTED' % b)
    for b in sorted(set(GATED) | set(REPORTED)):
        if b not in EXPECT:
            bad.append('%s is classified but has no EXPECT row' % b)
    for b in sorted(EXPECT):
        if b not in GATED and b not in REPORTED:
            bad.append('%s has an EXPECT row but is neither GATED nor REPORTED' % b)
    n_pins = sum(EXPECT.values())
    if pin_count and len(MARGIN_PIN) != n_pins:
        bad.append('MARGIN_PIN has %d rows but EXPECT accounts for %d check lines'
                   % (len(MARGIN_PIN), n_pins))
    for b in sorted(NO_RED_DEMO):
        if b in GATED:
            bad.append('%s is in NO_RED_DEMO and also GATED' % b)
    if bad:
        die('this gate\'s own tables are inconsistent:\n    ' + '\n    '.join(bad), 2)


def banner():
    print('=' * 100)
    print('OBJ-D LATENCY GATE -- SPD-1..6 / HOLD-1..4   (U14)')
    print('=' * 100)
    print('  battery : p4-bondagg/sim/latency-bars/latency_battery.py')
    print('  ratchet : p4-bondagg/sim/latency-bars/ratchet.py  (the derived hold, '
          'implemented here for the first time)')
    print('  physics : p4-bondagg/sim/nsched_model.py + pull-study/03-reserved-composite')
    print('  config  : SEEDS=%s T=%s GEO=canonical PYTHONHASHSEED=%s'
          % (CFG['SEEDS'], CFG['T'], CFG['PYTHONHASHSEED']))
    print('')
    print('  GATED    %s' % ', '.join(GATED))
    print('  REPORTED %s' % (', '.join(REPORTED) if REPORTED else '(none)'))
    print('           -- demoted for ONE of two MEASURED reasons, never for convenience:')
    print('              (a) the verdict FLIPS across stall geometry (out/geometry.md), so')
    print('                  the canonical point does not establish it; or')
    print('              (b) NO defect injection can turn it RED (out/mutations.md), so it')
    print('                  is not a gate at all. Each carries the reason it cannot fail.')
    print('')
    print('  ADR-004: no absolute loss or latency threshold is asserted against this')
    print('  rig anywhere in this battery. Every gated bar is PAIRED (two scorings of')
    print('  the same runs, or two runs on the same seeds), STRUCTURAL (a zero count,')
    print('  or one segment of a run against another), or UNIT (the ratchet formula on')
    print('  a synthetic trace, with no rig physics in it at all).')
    print('  A green run says the ORDERING held. It says nothing about magnitudes, and')
    print('  nothing about hardware: the rig has never been compared to a real router.')
    print('')
    print('  WHAT A GREEN RUN HERE DOES NOT CONSTRAIN -- printed every run, not buried:')
    print('   1. The system under test is expF_marginal.VSim / expG_mid.GSim, the r2 STUDY')
    print('      simulators (draw keys v0/v1/v2, g0/g2/g2m). NOT nsched_model.py\'s')
    print('      scheduler and NOT p4-bondagg/daemon/. This gate constrains a research')
    print('      prototype\'s draw order; it constrains no shipping code.')
    print('   2. This job has no continue-on-error and SPD-2a is GATED at a measured')
    print('      paired margin of 0.046310 (0.000000 on 3 of the 5 geometries).')
    print('      Deterministic, so it will not flake -- but it is a knife edge.')
    print('   3. Every run here is GEO=canonical. The geometry study that produced the')
    print('      GATED/REPORTED split is NOT re-run by this job (out/RUNME.sh does it by')
    print('      hand), so a bar that becomes geometry-unstable will not be noticed here.')
    print('   4. Rig sizes are N in {1,2,3}. The wire ceiling is 256.')
    print('   5. The model tick is 10 ms; the shipped ring ticks at PingIval = 100 ms')
    print('      (daemon/main.go). Every HOLD bar is scored 10x finer than the daemon')
    print('      resolves. r1 sec 8 asks for equality; it does not hold.')
    print('=' * 100)
    sys.stdout.flush()


def preflight(env):
    for fn, want in sorted(PIN.items()):
        got = sha256_of(os.path.join(LATDIR, fn))
        if want and got != want:
            die('%s changed (sha256 %s, expected %s).\n'
                '  This file is the INSTRUMENT, not the system under test. Loosening a\n'
                '  bar in it is invisible to every other check here. If the change is\n'
                '  intended: re-run the geometry study, re-measure the baseline, re-run\n'
                '  the mutation matrix, and update PIN/GATED/MUST_FAIL/MUTATIONS in the\n'
                '  SAME commit, saying what moved and why.' % (fn, got[:16], want[:16]), 2)
    probe = ('import reserved_composite, nsched_model, sys; '
             'sys.stdout.write(reserved_composite.__file__ + "\\n" + nsched_model.__file__)')
    penv = dict(env)
    # The battery inserts RCD itself (`latency_battery.py` sys.path[0:0]); this
    # standalone probe has to be given it, or it fails to import and the gate dies
    # at exit 2 -- loud, but for the wrong reason.
    penv['PYTHONPATH'] = os.pathsep.join([RCD, SIMDIR, penv.get('PYTHONPATH', '')])
    r = subprocess.run([sys.executable, '-c', probe], cwd=LATDIR, env=penv,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        die('could not resolve the rig modules under the gate environment:\n%s'
            % r.stderr.strip()[:400], 2)
    rc, nsc = [os.path.normpath(x) for x in r.stdout.strip().splitlines()[:2]]
    for name, g, w in (('reserved_composite', rc, os.path.normpath(os.path.join(RCD, 'reserved_composite.py'))),
                       ('nsched_model', nsc, os.path.normpath(os.path.join(SIMDIR, 'nsched_model.py')))):
        if g != w:
            die('%s resolves to %s, but this gate claims %s. The tree holds more than\n'
                '  one copy of each (ROADMAP U35); do not run an oracle you cannot name.'
                % (name, g, w), 2)
    print('  preflight: battery %s | ratchet %s | rig %s | physics %s'
          % (sha256_of(os.path.join(LATDIR, 'latency_battery.py'))[:12],
             sha256_of(os.path.join(LATDIR, 'ratchet.py'))[:12],
             os.path.basename(os.path.dirname(rc)), os.path.basename(nsc)))
    sys.stdout.flush()


def remargin():
    """Re-measure the margin pin. Prints the paste-ready MARGIN_PIN_ROWS block
    AND a pinned-vs-measured delta column, so re-baselining cannot be done
    without seeing what moved."""
    for k, v in sorted(CFG.items()):
        if os.environ.get(k) != v:
            die('config mismatch: %s=%r but the pin is measured at %s=%r'
                % (k, os.environ.get(k), k, v))
    env = dict(os.environ)
    env['PYTHONPATH'] = SIMDIR + os.pathsep + env.get('PYTHONPATH', '')
    rc, lines = run_battery(env, CFG['SEEDS'], 'none')
    if rc != 0:
        die('battery exited %d' % rc, 2)
    rows = margins_of(lines)
    print('MARGIN_PIN_ROWS = (')
    for bid, subj, val in rows:
        print("    ('%s', '%s', '%s')," % (bid, subj.replace("'", "\\'"), val))
    print(')')
    print('\n-- pinned vs measured --------------------------------------------------')
    for bid, subj, val in rows:
        want = MARGIN_PIN.get((bid, subj))
        if want is None:
            print('  NEW    %-9s %-52s %s' % (bid, subj, val))
        elif want != val:
            print('  MOVED  %-9s %-52s %s -> %s  (delta %+.9g)'
                  % (bid, subj, want, val, float(val) - float(want)))
        else:
            print('  same   %-9s %-52s %s' % (bid, subj, val))
    for bid, subj in sorted(k for k in MARGIN_PIN
                            if k not in set((b, s) for b, s, _ in rows)):
        print('  GONE   %-9s %-52s %s' % (bid, subj, MARGIN_PIN[(bid, subj)]))
    sys.exit(0)


def main():
    check_invariants()
    for k, v in sorted(CFG.items()):
        if os.environ.get(k) != v:
            die('config mismatch: %s=%r but the baseline and the geometry study were '
                'measured at %s=%r.' % (k, os.environ.get(k), k, v))

    env = dict(os.environ)
    env['PYTHONPATH'] = SIMDIR + os.pathsep + env.get('PYTHONPATH', '')

    banner()
    preflight(env)

    # ---------------------------------------------------------------- clean --
    print('\n' + '-' * 100)
    print('RUN 1 of 2 -- the tree as it stands, SEEDS=%s GEO=canonical' % CFG['SEEDS'])
    print('-' * 100)
    sys.stdout.flush()
    rc, lines = run_battery(env, CFG['SEEDS'], 'none')
    for l in lines:
        print(l)
    sys.stdout.flush()
    if rc != 0:
        # A guard trip is a CONFIG error, not a bar failure: the battery refused
        # to measure at all. Exit 2 so it is not read as "a bar went red".
        guard = next((l for l in lines
                      if 'GUARD FAILED' in l or 'RIG PIN FAILED' in l), None)
        if guard:
            die('the battery refused to run:\n    %s\n'
                '  This is an instrument guard, not a bar failure -- nothing was '
                'measured.' % guard.strip(), 2)
        die('the battery exited %d -- it is supposed to always exit 0 and print a '
            'verdict, so it crashed. Treat as FAIL.' % rc, 1)

    echo = next((ECHO_RE.search(l) for l in lines if ECHO_RE.search(l)), None)
    if not echo:
        die('no config echo line -- cannot confirm the battery ran the pinned config', 2)
    for name, got_v, want_v in (('SEEDS', echo.group(1), CFG['SEEDS']),
                                ('T', float(echo.group(2)), float(CFG['T'])),
                                ('GEO', echo.group(5), 'canonical'),
                                ('DEFECT', echo.group(6), 'none')):
        if str(got_v) != str(want_v):
            die('the battery RAN %s=%s while this gate pinned %s=%s. The environment '
                'was set correctly, so a hardcoded value inside the battery is '
                'comparing a different run against this baseline.'
                % (name, got_v, name, want_v), 2)

    # ---- structure: a battery that died mid-run must not read as green -------
    got = {}
    for l in lines:
        m = CHECK_RE.match(l)
        if m:
            got[m.group(1)] = got.get(m.group(1), 0) + 1
    print('\n' + '-' * 100)
    print('STRUCTURE CHECK -- a battery that died mid-run prints fewer check lines and')
    print('would otherwise read as green.')
    bad = []
    for k in sorted(EXPECT):
        n = got.get(k, 0)
        ok = n == EXPECT[k]
        print('  %-9s got %2d  want %2d  -> %s' % (k, n, EXPECT[k], 'ok' if ok else 'MISMATCH'))
        if not ok:
            bad.append(k)
    for k in sorted(set(got) - set(EXPECT)):
        print('  %-9s got %2d  want  -   -> UNCLASSIFIED BAR' % (k, got[k]))
        bad.append(k)
    if bad:
        die('battery structure mismatch on %s -- it did not run the full set of '
            'checks, so its verdict is not usable' % ', '.join(bad), 1)

    if not any(VERDICT_RE.match(l) for l in lines):
        die('no VERDICT line -- the battery never reached its verdict', 1)

    # ---- margin pin: what BOUNDS dilution ------------------------------------
    # The structure check above counts check lines; the failure classification
    # below reads VERDICTS. Neither can see a bar whose tolerance was widened
    # while its verdict stayed PASS -- which is how four gated bars were diluted
    # to a green exit 0 with every mutation row "-> ok". A bar's margin is one
    # signed number in a stated unit, and PASS is its sign
    # (`latency_battery.bar`), so widening the bar cannot avoid moving it.
    print('\n' + '-' * 100)
    print('MARGIN PIN -- every check line\'s measured margin against the recorded')
    print('baseline. A widened tolerance IS a moved margin: this is what the hash pin')
    print('and the mutation matrix between them do NOT bound.')
    print('-' * 100)
    got_m = margins_of(lines)
    if len(got_m) != sum(EXPECT.values()):
        die('parsed %d MARGIN lines but EXPECT accounts for %d check lines -- the '
            'battery is not printing one margin per check' % (len(got_m), sum(EXPECT.values())), 2)
    moved, unpinned = [], []
    for bid, subj, val in got_m:
        want = MARGIN_PIN.get((bid, subj))
        if want is None:
            unpinned.append((bid, subj, val))
        elif val != want:
            moved.append((bid, subj, want, val))
    seen_keys = set((b, s) for b, s, _v in got_m)
    vanished = sorted(k for k in MARGIN_PIN if k not in seen_keys)
    print('  %d check lines, %d pinned, %d moved, %d unpinned, %d pinned-but-absent'
          % (len(got_m), len(got_m) - len(unpinned), len(moved), len(unpinned), len(vanished)))
    for bid, subj, want, val in moved:
        try:
            d = '%+.9g' % (float(val) - float(want))
        except ValueError:
            d = '?'
        print('    MOVED      %-9s %-52s pinned %s -> measured %s  (delta %s)'
              % (bid, subj, want, val, d))
    for bid, subj, val in unpinned:
        print('    UNPINNED   %-9s %-52s measured %s' % (bid, subj, val))
    for bid, subj in vanished:
        print('    ABSENT     %-9s %-52s pinned %s' % (bid, subj, MARGIN_PIN[(bid, subj)]))
    hard_margin = bool(moved or unpinned or vanished)
    if hard_margin:
        print('\nGATE FAIL -- the measured margins do not match the recorded ones.')
        print('  A bar was WIDENED (its margin grew), the system under test MOVED, or a')
        print('  check line was added/renamed/removed. From here those are')
        print('  indistinguishable, so all of them are loud. Re-baseline with')
        print('  `python .github/scripts/latency_gate.py --remargin` in the SAME commit')
        print('  that says which margin moved and why. Regenerating it to go green is')
        print('  exactly the move this pin exists to stop.')

    seen = fails_of(lines)
    cm = next((COUNT_RE.match(l) for l in lines if COUNT_RE.match(l)), None)
    declared = int(cm.group(1)) if cm else 0
    if declared != len(seen):
        die('the battery reported %d bar failure(s) but this gate parsed %d. A FAIL '
            'line it cannot read is a failure it would silently ignore.'
            % (declared, len(seen)), 2)

    baseline = MUST_FAIL | TOLERATED
    gated_new, gated_known, reported, unknown = [], [], [], []
    for bid, subj in seen:
        if bid in REPORTED:
            reported.append((bid, subj))
        elif bid in GATED:
            (gated_known if (bid, subj) in baseline else gated_new).append((bid, subj))
        else:
            unknown.append((bid, subj))

    print('-' * 100)
    print('BAR FAILURES BY CLASS  (%d reported by the battery)' % len(seen))
    print('-' * 100)
    print('  NOT GATED [geometry-unstable] -- reported only:')
    for b, s in reported:
        print('    (reported) %-9s %s' % (b, s))
    if not reported:
        print('    (none failing this run)')
    print('  GATED, in the recorded baseline -- honest known fails, NOT weakened away:')
    for b, s in gated_known:
        print('    (known)    %-9s %s' % (b, s))
    if not gated_known:
        print('    (none)')
    stale = sorted(baseline - set(gated_known))
    if stale:
        print('  Baseline entries that did NOT fail this run:')
        for b, s in stale:
            print('    (not hit)  %-9s %s   [%s]'
                  % (b, s, 'TOLERATED' if (b, s) in TOLERATED else 'MUST_FAIL'))

    hard = ['margin-pin'] if hard_margin else []
    missing = sorted(MUST_FAIL - set(gated_known))
    if missing:
        print('\nGATE FAIL -- %d MUST_FAIL baseline entry(ies) did NOT fail:' % len(missing))
        for b, s in missing:
            print('    NOT HIT    %-9s %s' % (b, s))
        print('  Either the datapath genuinely improved (re-baseline and say so) or a bar')
        print('  was diluted. From here the two are indistinguishable, so both are loud.')
        hard.append('must-fail')
    if gated_new or unknown:
        print('\nGATE FAIL -- %d NEW gated bar failure(s) beyond the recorded baseline:'
              % (len(gated_new) + len(unknown)))
        for b, s in gated_new + unknown:
            print('    NEW FAIL   %-9s %s' % (b, s))
        print('  Do NOT add it to the baseline to go green -- that is weakening the bar.')
        hard.append('new-fail')

    # ------------------------------------------------------------- mutation --
    print('\n' + '-' * 100)
    print('RUN 2 of 2 -- MUTATION MATRIX, SEEDS=%s. FOUR defects, each of which must' % MUT_SEEDS)
    print('turn a named set of bars RED. Each is a real design error from this project')
    print('record. A hash pin stops the battery being EDITED; this stops it being')
    print('HOLLOW; the MARGIN PIN above is what bounds how far it can be DILUTED.')
    print('NOT run here: rank-mid-meter and warmup-max (they redden only bars that')
    print('already fail on the clean tree) and hold-quantile (minutes per scenario).')
    print('-' * 100)
    sys.stdout.flush()
    mut_bad = []
    for defect in sorted(MUTATIONS):
        want = set(MUTATIONS[defect])
        rc2, l2 = run_battery(env, MUT_SEEDS, defect)
        if rc2 != 0:
            die('battery exited %d under DEFECT=%s' % (rc2, defect), 2)
        red = set(b for b, _s in fails_of(l2))
        miss = sorted(want - red)
        print('  %-16s expects RED: %-40s -> %s'
              % (defect, ', '.join(sorted(want)), 'ok' if not miss else 'NOT RED: ' + ', '.join(miss)))
        if miss:
            mut_bad.append((defect, miss))
    if NO_RED_DEMO:
        print('')
        print('  BARS WITH NO DEMONSTRATED FAILURE MODE -- reported, deliberately NOT gated:')
        for b in NO_RED_DEMO:
            print('    (no red demo) %s' % b)
    if mut_bad:
        print('\nGATE FAIL -- %d defect(s) did not redden the bars they must:' % len(mut_bad))
        for d, m in mut_bad:
            print('    %-16s still green: %s' % (d, ', '.join(m)))
        print('  A bar that a known-bad tree passes is not a gate. Either the bar was')
        print('  weakened, or the defect injection stopped injecting -- check both.')
        hard.append('mutation')

    print('\n' + '=' * 100)
    if hard:
        print('GATE FAIL (%s)' % ', '.join(hard))
        sys.exit(1)
    print('GATE PASS -- every gated bar held outside the recorded baseline, and every')
    print('gated bar was demonstrated RED under its pre-registered defect in this run.')
    print('Reminder: this says NOTHING about absolute latency, and nothing about hardware.')
    sys.exit(0)


if __name__ == '__main__':
    if '--rehash' in sys.argv:
        # NOTE: --rehash updates the hash pin ONLY. It deliberately does NOT
        # touch MARGIN_PIN. The demonstrated attack was "dilute the bar, run
        # --rehash, commit" -- so the two pins must not be re-measurable by one
        # command. Use --remargin, which prints the deltas.
        for fn in sorted(PIN):
            print("    '%s': '%s'," % (fn, sha256_of(os.path.join(LATDIR, fn))))
        print('\n-- the hash pin only. MARGIN_PIN is NOT updated by --rehash; if you',
              file=sys.stderr)
        print('-- changed a bar, run --remargin too and say what moved.', file=sys.stderr)
        sys.exit(0)
    if '--remargin' in sys.argv:
        check_invariants(pin_count=False)
        remargin()
    main()
