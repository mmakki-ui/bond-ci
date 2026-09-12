#!/usr/bin/env python3
# =============================================================================
# rig_paired_gate.py -- CI gate for the TWO-STAGE RIG (ADR-004's datapath oracle)
# Task U8 (docs/ROADMAP.md epic 1).
#
# WHAT THIS GATES (and, just as importantly, what it does NOT)
# -----------------------------------------------------------------------------
# ADR-004 promoted `pull-study/03-reserved-composite/reserved_composite.py` (SimD)
# + `../02-ackclock/ackclock_sim.py` to the authoritative datapath oracle, and
# attached a HARD LIMIT to that promotion:
#
#     "Until condition 2 is met, the rig gates PAIRED COMPARISONS (Dc vs ewma vs
#      pull on identical seeds), which survive physics error. It does not gate
#      absolute loss or latency figures."
#
# Condition 2 is the E1 reality anchor (ROADMAP G1). The rig has NEVER been
# compared against a real router, so its absolute numbers are unvalidated physics.
# A paired delta on identical seeds mostly cancels that error; an absolute
# threshold does not.
#
# CORRECTION, U10 item 3 (rig_geometry.txt). "Pairing cancels the error" is true of
# PHYSICS error and NOT true of STALL-GEOMETRY error, and the difference is measured,
# not argued. Cancellation needs both sides to respond to the perturbation alike.
# They do not: at N4-teth@0.65, over 32 stall arrangements holding each source's
# TOTAL outage time exactly, Dc's absolute loss moves 3.622 pt while the oracle's
# moves 0.745 pt -- so the PAIRED Dc-oracle residual still moves 3.605 pt, 100% of
# the total's movement (rig_geometry.txt, G2). Against 0.181 pt across 24 canonical
# jitter seeds, that is a geometry:jitter ratio of 20x, and 81% of it is the
# ARRANGEMENT rather than the capacity the arrangement removed (r^2 = 0.187).
# Consequence for this gate, stated plainly: a green run establishes the paired
# ORDERING ON ONE HAND-PLACED GEOMETRY. Per-bar geometry stability is measured in
# rig_geometry.txt G4 and summarised in the banner below. No class changed and no
# threshold moved -- this is what the existing classes do and do not establish.
#
# This script therefore SPLITS highn_battery.py's bars into three classes and
# gates only the first two:
#
#   [GATED  paired]       B1, B2, B3(gp), B3(loss), B4a
#                         Dc vs ewma / Dc vs pull / Dc vs oracle, same seeds, same
#                         rig. A physics error shifts both sides of the comparison
#                         together.
#   [GATED  relative]     B4b, B5
#                         Within-scheduler SHAPE (B4b: does Dc's spotty-class share
#                         walk up monotonically?) and cross-config DIRECTION (B5:
#                         does adding a source raise gp / cut loss, on identical
#                         seeds and an identical absolute offer?). No absolute
#                         threshold, but WEAKER than the paired class: these vary
#                         the config or the time window rather than only the
#                         scheduler, so a CONFIG-DEPENDENT physics error is not
#                         cancelled. Gated, claimed narrowly.
#   [NOT GATED  absolute] EMPTY. No bar in the battery is an absolute threshold
#                         any more. The class stays live because the ADR-004 limit
#                         does; a future absolute bar goes here.
#
# WHAT CHANGED -- B3(loss) MOVED FROM absolute TO paired (U11)
# -----------------------------------------------------------------------------
# This file previously argued at length that B3's loss half COULD NOT be gated,
# because it was the constant "Dc loss <= 2%" -- an absolute threshold on a
# simulator whose absolute numbers ADR-004 declares unvalidated. That argument was
# correct about the bar as it then stood, and it is now MOOT: U11 retired the
# constant. highn_battery.py:33,326,330 scores B3's loss half as
#     median over paired seeds of (loss_Dc - loss_oracle) <= 0
# where the oracle is `ackclock_sim.Sim` admitting on the TRUE instantaneous
# stage-2 cap (`B3_REF = 'oracle'`, :143-148). Both sides are the same rig, the
# same seeds, the same offer; only the admission rule differs. That is the exact
# structure the paired class exists for, so the ADR-004 objection no longer
# applies -- it was never an objection to B3, it was an objection to constants.
#
# Leaving it in ABSOLUTE after that change would have been the WORSE of the two
# available failures: the gate would still run green while a real, gateable bar
# was silently unenforced. The other U11-driven breakage (B5_deltas) at least dies
# loudly. This one would not.
#
# NOT claimed by this move: B3's old 2% constant was, by accident, the only bar in
# the battery sensitive to reorder-hold geometry. The ring discard that dominates
# the loss (78-96% of lost frames on Dc, 95-97% on the oracle -- coverage_oracle.txt)
# is COMMON-MODE and cancels out of the new relation, so this gate does not cover
# it. (coverage_oracle.txt:101-111, PART B2: late/lost per scheduler at load=0.65
# is 78.2-95.7% for Dc and 95.2-96.7% for the oracle across the six mixes.)
# highn_battery.py:92-97 records that as an open bar owed to ROADMAP U13/OBJ-B.
# The battery still PRINTS the retired constant's verdict beside the paired one
# (:340) so the number stays visible; this gate does not read that line.
#
# A GREEN RUN OF THIS JOB DOES NOT MEAN THE RIG'S ABSOLUTE LOSS OR LATENCY
# NUMBERS ARE VALIDATED. Nothing validates those until E1 lands. B3(loss) is now
# gated because it stopped being an absolute number, not because the rig's
# absolute numbers became trustworthy.
#
# HOW IT GATES
# -----------------------------------------------------------------------------
# highn_battery.py always exits 0 (it prints a verdict), exactly like
# nsched_model.py. So this wrapper parses its VERDICT block and fails if the set
# of GATED bar failures GROWS beyond the recorded baseline (BASELINE_FAILS below,
# re-measured at SEEDS=6 against U11/U12's battery, cross-checked against their
# own SEEDS=24 run highn_u11u12.txt -- see the block above BASELINE_FAILS).
# Same shape as the eif-model job tolerating the one documented N5H FAIL: known
# honest fails are recorded, not weakened, and anything NEW is a hard fail.
#
# It also asserts the battery STRUCTURE (scenario count + the exact number of
# check lines per bar). A battery that died mid-run would print no VERDICT, or a
# short one, and would otherwise read as green.
#
# KNOWN BLIND SPOT, stated so nobody has to rediscover it: this gates bar
# VERDICTS, not MARGINS. A regression that degrades Dc while every paired bar
# still passes goes through. Re-implementing the bar arithmetic here would be a
# second copy that drifts from highn_battery.py, so margin bars belong inside
# the battery instead -- p4-bondagg/sim/**, which this job does not own
# (ROADMAP U10/U11).
#
# Exit: 0 = gate pass | 1 = gate FAIL | 2 = harness/config error.
# =============================================================================
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
RIGDIR = os.path.join(REPO, 'p4-bondagg', 'sim', 'pull-study', '03-reserved-composite')
SIMDIR = os.path.join(REPO, 'p4-bondagg', 'sim')

# --- the config this gate's baseline was measured at -------------------------
# Changing any of these invalidates BASELINE_FAILS (measured: the SEEDS 24 -> 6
# reduction alone flips one bar verdict), so the script refuses to run against a
# config it has no baseline for rather than silently comparing to the wrong record.
CFG = {'SEEDS': '6', 'T': '9.0', 'RIG': 'mid', 'PYTHONHASHSEED': '0'}

# --- bar classification ------------------------------------------------------
# B3(loss) is PAIRED as of U11 -- see the "WHAT CHANGED" block in the header.
PAIRED = ('B1', 'B2', 'B3(gp)', 'B3(loss)', 'B4a')  # gated: paired, identical seeds
RELATIVE = ('B4b', 'B5')                     # gated: shape / direction, no threshold
# NOT gated: absolute thresholds, which ADR-004 forbids gating until E1. EMPTY
# today -- B3(loss) was the only member and U11 made it paired. Kept as a live
# class, not deleted: the ADR-004 limit still stands, so any future absolute bar
# belongs here. An id in NO class fails closed (`unknown` below), so emptying this
# tuple cannot silently un-gate anything.
ABSOLUTE = ()

# --- recorded baseline -------------------------------------------------------
# RE-MEASURED against U11/U12's battery. Not assumed unchanged.
#
#   SEEDS=24 (U11/U12's own run, highn_u11u12.txt:192-198): 6 gated fails --
#     the 5 B2 rows and the 1 B4a row below, byte-for-byte the same subjects as
#     the pre-U11 record. ZERO B3(loss) fails: the old "Dc loss <= 2%" constant
#     failed 5 mixes in highn.txt; the paired oracle relation that replaced it
#     passes all 6.
#   SEEDS=6, T=9.0, RIG=mid, PYTHONHASHSEED=0, WORKERS=4 (run by this gate,
#     2026-08-29, TWICE, battery elapsed 559.3 s and 511.9 s): 5 gated fails, the
#     SAME five both times, gate exit 0 both times. The set is a strict SUBSET of
#     the 24-seed set -- exactly one entry short.
#
# THE ONE DIFFERENCE, stated rather than smoothed over: B2 N3-het @0.85 is FAIL
# at 24 seeds (+0.515 pt, 14/24 seeds) and PASS at 6 seeds. That is the SAME bar
# the pre-U11 baseline already flagged as the single 24->6 verdict flip -- it sits
# ~0.01 pt from the bar -- so U11 did not move it; the seed count does. It is KEPT
# here, deliberately, on the strength of the 24-seed record: dropping it would let
# a genuinely regressing bar be re-reported as a NEW fail only sometimes, i.e. a
# flaky gate. The cost is named and printed EVERY run: the "not hit" section below
# lists it, so the log always says the gate is looser than the run that produced it.
#
# NOTHING HERE IS A WEAKENED BAR. Every entry is a failure that was measured and
# published before this gate existed. The gate's job is to stop the set GROWING.
# Measured margins at SEEDS=6 (from the run above), so a future reader can see how
# close each is: B2 N2-het@0.85 +0.852 pt 6/6 seeds | N2-het@0.95 +0.661 6/6 |
# N3-het@0.95 +0.634 6/6 | N4-het@0.95 +0.695 6/6 | B4a N5-corr@0.95 Dc 0.340 vs
# pull 0.335. The gate still reads VERDICTS, not these margins (see the blind spot
# above); they are recorded as evidence, not enforced.
# MUST_FAIL vs TOLERATED. This split exists because a Fable pass DEMONSTRATED the
# bypass it closes: diluting B2's bar in highn_battery.py (`ew_ls + 0.5` -> `+ 2.0`,
# a 4x loosening) made all five known fails stop firing, and the gate PASSED, exit 0.
# A gate that only fires on the fail set GROWING treats a weakened bar as an
# improvement -- a one-way ratchet pointing the wrong way.
#
# So: a MUST_FAIL entry that does NOT fail is now a hard exit 1. Both directions are
# loud. A genuine scheduler improvement therefore also fails the job, and that is
# CORRECT and intended -- it is a re-baseline event, exactly symmetric with the
# standing rule that you may not add an entry to the baseline to go green. Re-measure,
# move the entry, and say so in the commit.
#
# Every MUST_FAIL entry was measured failing at SEEDS=6 in three independent runs.
MUST_FAIL = {
    ('B2', 'N2-het cellA + eth load=0.85'),
    ('B2', 'N2-het cellA + eth load=0.95'),
    ('B2', 'N3-het cellA + cellB + eth load=0.95'),
    ('B2', 'N4-het cellA + cellB + wifi + eth load=0.95'),
    # Hairline, and named as such: Dc 0.340 vs pull 0.335. It is in MUST_FAIL because
    # that is what was MEASURED, three times, not because the margin is comfortable.
    ('B4a', 'N5-corr cellA+cellB+cellC (CORRELATED stalls) + wifi + eth load=0.95'),
}

# Fails at SEEDS=24, not at SEEDS=6, so its absence is not alarming. Kept rather than
# dropped: at ~0.01 pt from its bar it would otherwise flip dev red on any legitimate
# change. Printed `(not hit)` every run.
TOLERATED = {
    ('B2', 'N3-het cellA + cellB + eth load=0.85'),
}

BASELINE_FAILS = MUST_FAIL | TOLERATED

# --- expected battery structure (6 scenarios) --------------------------------
# 6 scenarios x {1 B3 line, 2 B1 lines, 2 B2 lines, 3 B4a lines}; 12 B4b timeline
# rows (Dc + the unscored ewma reference per scenario).
#
# B5_deltas = 6, NOT 3. Counted from the battery, not assumed: highn_battery.py:419
# builds the chain as the scenarios flagged `chain` -> 4 members (N2/N3/N4-het/
# N5-het, :169-177), and :422 now runs TWO offers (`offers = [(LOADS[1], ...),
# (LOADS[-1], ...)]`, U12 -- the 0.85 offer leaves the N=5 step under-stressed
# because N4-het's own nominal already exceeds it). The `dgp=` marker this counts
# is printed once per step-to-step transition (:461), so 2 offers x (4-1) steps = 6.
# It was 3 before U12 added the second offer; left at 3 the structure check kills
# the job exit 1 on a green tree.
EXPECT = {
    'B1': 12,
    'B3_vs_oracle': 6,
    'B2': 12,
    'B3': 6,
    'B4a': 18,
    'B4b_rows': 12,
    'B5_deltas': 6,
    'scenarios': 6,
}

FAIL_RE = re.compile(r'^\s*FAIL\s+(\S+)\s+(.*?):')
VERDICT_RE = re.compile(r'^\s*(ALL BARS PASS|\d+ BAR FAILURE\(S\):)')
# The battery's own echo of the config it ACTUALLY ran (highn_battery.py:254). CFG
# above checks the ENVIRONMENT; this checks that the battery obeyed it. Measured
# bypass: hardcoding SEEDS=2 inside the battery while the env still said 6 compared a
# 2-seed run against the 6-seed baseline and PASSED, exit 0.
ECHO_RE = re.compile(r'seeds=(\d+)\s+T=([\d.]+)s\s+rig=(\S+)')
# The battery's own count of what it failed, used to prove the FAIL parser saw all of
# them. FAIL_RE needs a colon; a future fail line without one would be silently
# unparsed and the gate would read as green.
COUNT_RE = re.compile(r'^\s*(\d+) BAR FAILURE\(S\):')

# sha256 of the battery this gate's baseline was measured against. See preflight().
BATTERY_SHA256 = '7d781155c1625bd81dc2e0dd6ee387f2dae44a63ccb533ad13d0e3078c063eea'


def die(msg, code=2):
    print('\n!! rig-paired gate: %s' % msg)
    sys.exit(code)


def norm(s):
    return ' '.join(s.split())


def banner():
    print('=' * 100)
    print('RIG PAIRED GATE -- ADR-004 datapath oracle (the two-stage rig)')
    print('=' * 100)
    print('  rig    : p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py (SimD)')
    # This line named ../02-ackclock/ackclock_sim.py and was WRONG. There are two
    # materially different copies of ackclock_sim.py in the tree and the rig loads the
    # LOCAL one; preflight() below now asserts it rather than asserting it in prose.
    print('           + 03-reserved-composite/ackclock_sim.py  (NOT ../02-ackclock -- see U35)')
    print('           [physics: p4-bondagg/sim/nsched_model.py, unmodified]')
    print('  driver : highn_battery.py   SEEDS=%s T=%s RIG=%s WORKERS=%s PYTHONHASHSEED=%s'
          % (CFG['SEEDS'], CFG['T'], CFG['RIG'],
             os.environ.get('WORKERS', '(rig default 14)'), CFG['PYTHONHASHSEED']))
    print('')
    print('  GATED [paired]       %s   Dc vs ewma / pull / oracle, identical seeds'
          % ', '.join(PAIRED))
    print('  GATED [relative]     %s        within-scheduler shape / cross-config direction'
          % ', '.join(RELATIVE))
    print('  NOT GATED [absolute] %s   ADR-004 forbids gating absolute thresholds'
          % (', '.join(ABSOLUTE) if ABSOLUTE else '(none -- U11 made B3(loss) paired)'))
    print('')
    print('  THIS JOB DOES NOT VALIDATE THE RIG ABSOLUTE LOSS OR LATENCY NUMBERS.')
    print('  The rig has never been compared against a real router (ADR-004, "Open").')
    print('  Only the E1 reality anchor (ROADMAP G1) can lift that limit. Green here means')
    print('  the paired ordering held EVERYWHERE OUTSIDE the recorded baseline fail set --')
    print('  six paired orderings ARE violated on every green run and tolerated as known')
    print('  honest fails. It says nothing about the magnitudes.')
    print('  Green also says nothing about STALL GEOMETRY, and U10 item 3 measured how much')
    print('  that costs (rig_geometry.txt, 32 arrangements at fixed per-source outage time):')
    print('    B5(loss)  GEOMETRY-STABLE. All three chain steps pass on 32/32 arrangements.')
    print('    B3(loss)  geometry-stable on 4 of 6 mixes; N3-het 31/32 and N4-teth 25/32 are')
    print('              NOT -- on N4-teth the same paired median spans [-1.97, +1.68] pt')
    print('              against a canonical -0.671, so its verdict is the geometry\'s.')
    print('    B2        GEOMETRY-DEPENDENT on all five cells. The four recorded FAILs pass')
    print('              on 17-28 of 32 arrangements and the one PASS fails on 4; the spread')
    print('              of the bar\'s own statistic is 1.26-2.60 pt against its 0.5 pt')
    print('              tolerance. The published 0.65-0.85 pt honest fail is one point in')
    print('              that spread, not a level.')
    print('  U33\'s ~0.9 pt band was PHASE ONLY and is superseded by the above, which')
    print('  varies stall duration SPLIT and POSITION at the CANONICAL event count.')
    print('  Event COUNT is a separate surface (rig_geometry.txt G3) and feeds no bar')
    print('  verdict. This is a fixed-geometry ratchet, not a statement about nature.')
    print('')
    print('  REDUCED FROM THE PUBLISHED RUN -- what was dropped, so this is not read as complete:')
    print('    * SEEDS 24 -> %s per (scenario, load, sched) cell. The published record is'
          % CFG['SEEDS'])
    print('      highn_u11u12.txt at SEEDS=24: 733.7 s locally on 14 workers -- does not fit a job.')
    print('      This config re-measured locally at 559.3 s / 511.9 s on 4 workers (two runs,')
    print('      a runner core count) against U11/U12\'s battery. The 45-min timeout has headroom.')
    print('    * MEASURED effect of that reduction (measured, not assumed): exactly one bar')
    print('      verdict flips. B2 N3-het@load=0.85 is FAIL at SEEDS=24 (+0.515 pt, 14/24 seeds)')
    print('      and PASS at SEEDS=6 -- it sits ~0.01 pt from the bar. It is KEPT in the baseline')
    print('      set below on the strength of the SEEDS=24 record, so the gate cannot flake on it,')
    print('      and it is printed as "not hit" every run so the looseness is never invisible.')
    print('      A shrinking fail set used to be only WARNED about, never failed -- which made')
    print('      bar dilution indistinguishable from improvement. MUST_FAIL closes that: an')
    print('      entry that stops failing is exit 1, so both directions are loud.')
    print('    * NOT reduced: all 6 scenarios (N2/N3/N4/N5 het, N4 tether-heavy, N5 correlated),')
    print('      all 3 loads, all 4 schedulers, B3\'s paired oracle reference, both B5 offers,')
    print('      T=9.0 s, rig=mid, and the B4b timeline seed count (fixed at 12 inside')
    print('      highn_battery.py; this job does not own p4-bondagg/sim/**).')
    print('=' * 100)
    sys.stdout.flush()


def sha256_of(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def preflight(env):
    """Assert the gate is measuring the instrument it thinks it is, before it runs.

    Two failures this closes, both found by adversarial review rather than by use:

    1. THE INSTRUMENT CAN BE DILUTED. highn_battery.py holds the bar arithmetic, the
       scenarios, the loads, the scheduler set and the seed derivation. Loosening any
       of them makes bars easier while every count and every text pin stays intact.
       Demonstrated: `ew_ls + 0.5` -> `+ 2.0` and the gate passed, exit 0. The battery
       is the MEASURING INSTRUMENT, not the system under test, so it is hash-pinned.
       reserved_composite.py / ackclock_sim.py / nsched_model.py are deliberately NOT
       pinned -- those are the system under test and must be free to change and be
       measured. Their identity is pinned instead (2).

    2. THE ORACLE'S IDENTITY WAS PROSE. The banner and ADR-004 both named
       ../02-ackclock/ackclock_sim.py; the rig loads 03-reserved-composite's copy, a
       materially different file. Nothing checked. Now the gate resolves the modules
       under its OWN environment and compares __file__ against what it claims.
    """
    want = os.path.join(RIGDIR, 'highn_battery.py')
    got = sha256_of(want)
    if BATTERY_SHA256 and got != BATTERY_SHA256:
        die('highn_battery.py changed (sha256 %s, expected %s).\n'
            '  The battery is the INSTRUMENT this gate reads, not the system under test:\n'
            '  its bar arithmetic, scenarios, loads, scheduler set and seed derivation all\n'
            '  live there, and loosening any of them is invisible to every other check here\n'
            '  (measured: a 4x dilution of B2 passed this gate at exit 0 before this pin).\n'
            '  If the change is intended, RE-MEASURE the baseline and update BASELINE_SHA\n'
            '  and MUST_FAIL/TOLERATED in the SAME commit, saying what moved and why.'
            % (got[:16], BATTERY_SHA256[:16]), 2)

    probe = ('import ackclock_sim, nsched_model, sys; '
             'sys.stdout.write(ackclock_sim.__file__ + "\\n" + nsched_model.__file__)')
    r = subprocess.run([sys.executable, '-c', probe], cwd=RIGDIR, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        die('could not resolve the rig modules under the gate environment:\n%s'
            % r.stderr.strip()[:400], 2)
    ack, nsc = [os.path.normpath(x) for x in r.stdout.strip().splitlines()[:2]]
    exp_ack = os.path.normpath(os.path.join(RIGDIR, 'ackclock_sim.py'))
    exp_nsc = os.path.normpath(os.path.join(SIMDIR, 'nsched_model.py'))
    for name, g, w in (('ackclock_sim', ack, exp_ack), ('nsched_model', nsc, exp_nsc)):
        if g != w:
            die('%s resolves to %s, but this gate claims %s.\n'
                '  The tree holds more than one copy of each (U35). Which one runs is decided\n'
                '  by sys.path, and the wrong answer was written down in ADR-004 for a day.\n'
                '  Fix the path or fix the claim -- do not run an oracle you cannot name.'
                % (name, g, w), 2)
    print('  preflight: battery sha256 %s | oracle %s | physics %s'
          % (got[:12], os.path.basename(os.path.dirname(ack)) + '/ackclock_sim.py',
             os.path.basename(os.path.dirname(nsc)) + '/nsched_model.py'))


def main():
    for k, v in sorted(CFG.items()):
        got = os.environ.get(k)
        if got != v:
            die('config mismatch: %s=%r but BASELINE_FAILS was measured at %s=%r. '
                'Re-measure the baseline before changing the config, or the gate '
                'compares against the wrong record.' % (k, got, k, v))

    env = dict(os.environ)
    env['PYTHONPATH'] = SIMDIR + os.pathsep + env.get('PYTHONPATH', '')

    banner()
    preflight(env)
    sys.stdout.flush()
    cmd = [sys.executable, 'highn_battery.py']
    print('+ cd %s && PYTHONPATH=%s %s\n' % (RIGDIR, SIMDIR, ' '.join(cmd)))
    sys.stdout.flush()

    # Stream stdout: if the job hits its timeout the bar names are already in the
    # log. The battery's progress counters go to stderr and are inherited.
    p = subprocess.Popen(cmd, cwd=RIGDIR, env=env, stdout=subprocess.PIPE,
                         stderr=None, text=True, bufsize=1,
                         encoding='utf-8', errors='replace')
    lines = []
    for line in p.stdout:
        line = line.rstrip('\n')
        lines.append(line)
        print(line)
        sys.stdout.flush()
    rc = p.wait()
    if rc != 0:
        die('highn_battery.py exited %d -- it is supposed to always exit 0 and print '
            'a verdict, so the rig crashed. Treat as FAIL.' % rc, 1)

    # ---- did the battery OBEY the config, or just inherit it? ----
    echo = next((ECHO_RE.search(l) for l in lines if ECHO_RE.search(l)), None)
    if not echo:
        die('the battery printed no config echo line -- cannot confirm it ran the config '
            'this gate pinned. Expected highn_battery.py:254 "seeds=N T=Xs rig=R".', 2)
    for name, got_v, want_v in (('SEEDS', echo.group(1), CFG['SEEDS']),
                                ('T', float(echo.group(2)), float(CFG['T'])),
                                ('RIG', echo.group(3), CFG['RIG'])):
        if str(got_v) != str(want_v):
            die('the battery RAN %s=%s while this gate pinned %s=%s. The environment was '
                'set correctly, so the battery is ignoring it -- a hardcoded value inside '
                'highn_battery.py compares a different run against this baseline and would '
                'otherwise pass silently.' % (name, got_v, name, want_v), 2)

    # ---- structure: a truncated battery must not read as green ----
    got = {
        'B1': sum(1 for l in lines if l.startswith('  B1 load=')),
        'B2': sum(1 for l in lines if l.startswith('  B2 load=')),
        'B3': sum(1 for l in lines if l.startswith('  B3 load=0.65 WIN')),
        # PIN THE REFERENCE, not just the count. B3(loss) is only a meaningful gate
        # because it is paired against the ORACLE (ackclock_sim.Sim admitting on the
        # true instantaneous stage-2 cap) -- the physics-derived floor. Flipping
        # highn_battery.py's B3_REF to 'ewma' or 'pull' would weaken the bar to a
        # comparison against a worse scheduler, keep this count at 6, keep the
        # structure check at 7/7, and leave the gate green. So assert the reference
        # appears in the same printed line.
        'B3_vs_oracle': sum(1 for l in lines
                            if l.startswith('  B3 load=0.65 WIN')
                            and 'paired Dc-oracle med=' in l),
        'B4a': sum(1 for l in lines if l.startswith('  B4a load=')),
        'B4b_rows': sum(1 for l in lines if 'monotonic_up=' in l),
        'B5_deltas': sum(1 for l in lines if 'dgp=' in l),
        'scenarios': sum(1 for l in lines if l.startswith('#   N') and 'nominal_agg=' in l),
    }
    print('\n' + '-' * 100)
    print('STRUCTURE CHECK -- a battery that died mid-run prints fewer check lines and')
    print('would otherwise read as green.')
    bad = []
    for k in sorted(EXPECT):
        ok = got[k] == EXPECT[k]
        print('  %-12s got %3d  want %3d  -> %s'
              % (k, got[k], EXPECT[k], 'ok' if ok else 'MISMATCH'))
        if not ok:
            bad.append(k)
    if bad:
        extra = ''
        if 'B3_vs_oracle' in bad and got['B3'] == EXPECT['B3']:
            extra = ('\n  B3 lines are all present but not paired against the ORACLE. Check '
                     "highn_battery.py's B3_REF: pairing B3(loss) against 'ewma' or 'pull' "
                     'instead is a WEAKENED bar, not a structure error.')
        die('battery structure mismatch on %s -- it did not run the full set of checks, '
            'so its verdict is not usable%s' % (', '.join(bad), extra), 1)

    if not any(VERDICT_RE.match(l) for l in lines):
        die('no VERDICT line in the battery output -- it never reached its verdict', 1)

    # ---- classify the reported failures ----
    seen = []
    for l in lines:
        m = FAIL_RE.match(l)
        if m:
            seen.append((m.group(1), norm(m.group(2))))

    # Prove the parser saw every failure the battery reported. FAIL_RE requires a
    # colon; a fail line written without one would be silently unparsed and the run
    # would read as green -- the gate would fail OPEN on exactly the case it exists
    # for. The battery states its own count, so cross-check against it.
    cm = next((COUNT_RE.match(l) for l in lines if COUNT_RE.match(l)), None)
    declared = int(cm.group(1)) if cm else 0
    if declared != len(seen):
        die('the battery reported %d bar failure(s) but this gate parsed %d. A FAIL line '
            'it could not read is a failure it would silently ignore, so the run is not '
            'usable. Check the FAIL line format against FAIL_RE.' % (declared, len(seen)), 2)

    gated_new, gated_known, ungated, unknown = [], [], [], []
    for bar, subj in seen:
        if bar in ABSOLUTE:
            ungated.append((bar, subj))
        elif bar in PAIRED or bar in RELATIVE:
            (gated_known if (bar, subj) in BASELINE_FAILS else gated_new).append((bar, subj))
        else:
            # Fail closed. A bar this gate has never classified must be triaged
            # deliberately, not silently ignored because nobody updated the list.
            unknown.append((bar, subj))

    print('-' * 100)
    print('BAR FAILURES BY CLASS  (%d reported by the battery)' % len(seen))
    print('-' * 100)
    print('  NOT GATED [absolute] -- reported only; ADR-004 forbids gating these:')
    for bar, subj in ungated:
        print('    (ungated) %-10s %s' % (bar, subj))
    if not ungated:
        print('    (none -- the ABSOLUTE class is empty since U11 made B3(loss) paired)')
    print('  GATED, already in the recorded baseline (highn_u11u12.txt at SEEDS=24, re-measured')
    print('  at SEEDS=6 by this gate) -- honest known fails:')
    for bar, subj in gated_known:
        print('    (known)   %-10s %s' % (bar, subj))
    if not gated_known:
        print('    (none)')

    stale = sorted(BASELINE_FAILS - set(gated_known))
    if stale:
        print('  Baseline entries that did NOT fail this run:')
        for bar, subj in stale:
            print('    (not hit) %-10s %s   [%s]'
                  % (bar, subj, 'TOLERATED' if (bar, subj) in TOLERATED else 'MUST_FAIL'))

    # A MUST_FAIL entry that stopped failing is a hard failure in the OTHER direction.
    # Measured bypass this closes: diluting B2's bar 4x silenced all five known fails
    # and the gate passed, exit 0 -- weakening read as improvement.
    missing = sorted(MUST_FAIL - set(gated_known))

    print('-' * 100)
    if unknown:
        print('  UNCLASSIFIED BARS -- failing closed:')
        for bar, subj in unknown:
            print('    (new bar) %-10s %s' % (bar, subj))
    if missing:
        print('')
        print('GATE FAIL -- %d MUST_FAIL baseline entry(ies) did NOT fail this run:'
              % len(missing))
        for bar, subj in missing:
            print('    NOT HIT   %-10s %s' % (bar, subj))
        print('')
        print('This is deliberate and it is not an error in the gate. Each of these was')
        print('MEASURED failing at this exact config in three independent runs, so one of')
        print('two things happened, and they are indistinguishable from here:')
        print('  (a) the scheduler genuinely IMPROVED -- good, and it needs a re-baseline;')
        print('  (b) a BAR WAS DILUTED in highn_battery.py -- a 4x loosening of B2 silenced')
        print('      all five of these at once, and before this check the gate passed.')
        print('Re-measure, move the entry, and say in the commit which one it was and why.')
        sys.exit(1)
    if gated_new or unknown:
        print('')
        print('GATE FAIL -- %d NEW gated bar failure(s) beyond the recorded baseline:'
              % (len(gated_new) + len(unknown)))
        for bar, subj in gated_new + unknown:
            print('    NEW FAIL  %-10s %s' % (bar, subj))
        print('')
        print('A paired/relative bar regressed. Do NOT add it to BASELINE_FAILS to go green --')
        print('that is weakening the bar. Fix the scheduler, or record the regression as a')
        print('decision carrying the measurement that justifies it.')
        sys.exit(1)

    print('GATE PASS -- no gated (paired/relative) bar failed outside the recorded baseline.')
    print('Reminder: this says NOTHING about the rig absolute loss or latency numbers.')
    sys.exit(0)


if __name__ == '__main__':
    main()
