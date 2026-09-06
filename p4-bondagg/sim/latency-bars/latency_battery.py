#!/usr/bin/env python3
# =============================================================================
# latency_battery.py -- OBJ-D LATENCY BARS: SPD-1..6 and HOLD-1..4.
# Task U14 (docs/ROADMAP.md epic 1). Gated by .github/scripts/latency_gate.py.
#
# WHY THIS EXISTS
# -----------------------------------------------------------------------------
# `docs/INTENT.md` OBJ-D: "Nothing in the battery constrains p50/p95 today; that
# is why latency drifted." Latency became an objective partway through the
# project; no gate anywhere measures it. This battery is that gate's instrument.
#
# WHAT IT IS ALLOWED TO ASSERT -- ADR-004, and it is the binding constraint
# -----------------------------------------------------------------------------
#   "Until condition 2 is met, the rig gates PAIRED COMPARISONS (Dc vs ewma vs
#    pull on identical seeds), which survive physics error. It does not gate
#    absolute loss or latency figures."
#
# The rig has never been compared to a real router. So EVERY bar here is one of:
#
#   PAIRED     two scorings of the SAME runs, or two runs on the SAME seeds/rig/
#              offer differing only in the thing under test (draw order, or hold
#              policy). A physics error moves both sides together.
#   STRUCTURAL a count that is ZERO or a comparison of a quantity against ITSELF
#              in another segment of the same run. Not a magnitude, so ADR-004's
#              limit does not reach it: "no frame was placed on a spotty source"
#              is a statement about the ORDERING CODE, not about the physics.
#   UNIT       a deterministic assertion on a formula's own definition, on a
#              synthetic trace, with no rig physics involved at all (HOLD-4).
#              Authority: the design text that DEFINES the formula, not the rig.
#
# There is NO absolute class. `gp >= 0.99*offer` (r1 bar table SPD-1) is an
# absolute loss threshold wearing a goodput costume, and is NOT gated here -- it
# is replaced by a paired floor against a single-source control run on the same
# seeds. Same for `loss <= x%` anywhere.
#
# EVERY THRESHOLD AND WHERE IT CAME FROM
# -----------------------------------------------------------------------------
# Most limbs carry NO constant at all (>= or <= between two paired quantities).
# The ones that do:
#   2*gran      gran = `nsched_model.DT * 1000` = 10.0 ms, the model tick. The
#               release clock cannot resolve finer, so two policies whose
#               percentiles differ by less than a tick are indistinguishable by
#               construction. PHYSICS OF THE INSTRUMENT, not a tuning knob.
#               (The r1 bar table computed 2*gran = 2 ms from
#               `expH_frontier.py:21 TICK = 1.0`, which is wrong by 10x against
#               `nsched_model.py:62 DT = 0.010`. Corrected here.)
#   SPD3_GP     measured HERE, on this instrument, over the five-geometry sample,
#   SPD3_P95    rounded OUTWARD to 2 dp, printed with its live margin on every
#               run. Deep saturation is the one place the design ACCEPTS a cost.
#               r1 sec 6's "-2.3% at 140k" is a DIFFERENT instrument's number and
#               is no longer the source of either bar -- see set_cal().
#   burst_max   measured PER RUN, never a constant: the largest contiguous run of
#               late-arriving seqs in that same trace. The ratchet provably
#               cannot cover the first macro event on a path set (design r1
#               sec 4.4), so its late count may exceed a clairvoyant fixed hold's
#               by at most one event's frames. r1's HOLD-2 wrote this as
#               "late <= 1.10*late(343)"; 1.10 is invented and is not used.
#   1 ULP       HOLD-4 only. `math.ulp(expected)`, the IEEE754 double spacing at
#               the expected value -- float representation error, not slack.
#
# A BAR IS ONE SIGNED NUMBER, AND PASS IS ITS SIGN
# -----------------------------------------------------------------------------
# Every check calls `bar(id, subject, margin, detail)` and PASS means
# `margin >= 0`. There is no separate predicate to widen. This is the fix for the
# fourth weakened-green gate in this project: the old `bar(id, subject, ok,
# detail, slack)` took the verdict and the margin as INDEPENDENT arguments, so a
# tolerance could be widened in `ok` while `slack` went on printing the
# undiluted number. Four GATED bars were diluted that way (SPD-3a 0.97->0.60,
# HOLD-1d and HOLD-2b burst->20*burst, HOLD-4a 1e-9->5.0 ms), the pin was
# re-measured exactly as DEMO B/C prescribe, and the gate exited 0 with every
# mutation row "-> ok". `latency_gate.py`'s MARGIN_PIN now pins that one number
# for all 31 check lines, so the dilution IS the diff.
#
# N-GENERIC
# -----------------------------------------------------------------------------
# No bar names a path index. "spotty share" is summed over
# `{i : sim.spotty[i]}`, the archetype's own identity class, over range(N).
# `reserved_composite.finalize()`'s `tshare` is NOT used anywhere here: it is
# `assigned[0]/total` (`reserved_composite.py:466` on this branch, `:518` on dev
# after U35 rewrote the file), a privileged-index quantity.
# Rig sizes present: N=1 (SPD-1 control), N=2 (SPD-5, HOLD-1..3), N=3 (SPD-1..4,
# SPD-6). Nothing in this unit measures latency behaviour above N=3, and the wire
# ceiling is 256 -- stated, not papered over.
#
# ALWAYS EXITS 0 and prints a verdict, exactly like highn_battery.py and
# nsched_model.py. The GATE decides pass/fail. Run it directly to see the bars.
#
#   cd p4-bondagg/sim/latency-bars && PYTHONPATH=../.. python -u latency_battery.py
#
# Env: SEEDS (default 6), T (9.0), DEFECT (default none -- see DEFECTS below;
# used by the RED demonstration and by the gate's mutation self-check).
# =============================================================================
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.abspath(os.path.join(HERE, '..'))
RCD = os.path.join(SIM, 'pull-study', '03-reserved-composite')
R2 = os.path.join(SIM, 'modes-r2-study')
# Pin the physics and the harness BY PATH (U35 discipline). The tree holds two
# materially different `ackclock_sim.py` and two `nsched_model.py`; which one
# runs must not be decided by sys.path inheritance.
sys.path[0:0] = [HERE, R2, RCD, SIM]

import reserved_composite as RC          # noqa: E402
import nsched_model as M                 # noqa: E402
import holdlib as HL                     # noqa: E402
import expF_marginal as XF               # noqa: E402
import expG_mid as XG                    # noqa: E402
import ratchet as RT                     # noqa: E402
from holdlib import med, pct             # noqa: E402
from expF_marginal import VSim           # noqa: E402
from expG_mid import GSim                # noqa: E402
from ratchet import ratchet_release, late_runs   # noqa: E402

# --- assert we are measuring the instrument we claim to be measuring ---------
# `expF_marginal.py:6` and `expG_mid.py:10` prepend a HARDCODED absolute path,
#   SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
# which is the MAIN worktree, not this one. On any other machine it does not
# exist and is skipped. On Mo's PC it DOES exist and it is a DIFFERENT TREE at a
# different commit, so `sys.path[0:0] = [HERE, R2, RCD, SIM]` above winning is
# load-bearing, not cosmetic. Earlier text here claimed the hardcoded path
# "resolves to these same files"; that was false, and three of the six modules
# below only resolved correctly because the main tree happens not to carry those
# names. So EVERY module this battery imports is pinned by path, not just the two
# with known duplicates -- an accident of naming is not a guarantee.
def _pin(mod, want, label):
    got = os.path.normpath(mod.__file__)
    if got != os.path.normpath(want):
        raise SystemExit(
            'RIG PIN FAILED: %s resolved to %s, expected %s.\n'
            '  Another copy of this module exists on sys.path (ROADMAP U35; and\n'
            '  expF_marginal.py:6 / expG_mid.py:10 hardcode the MAIN worktree).\n'
            '  Running the wrong one silently measures a different tree.'
            % (label, got, want))


_pin(RC, os.path.join(RCD, 'reserved_composite.py'), 'reserved_composite')
_pin(M, os.path.join(SIM, 'nsched_model.py'), 'nsched_model')
_pin(HL, os.path.join(R2, 'holdlib.py'), 'holdlib')
_pin(XF, os.path.join(R2, 'expF_marginal.py'), 'expF_marginal')
_pin(XG, os.path.join(R2, 'expG_mid.py'), 'expG_mid')
_pin(RT, os.path.join(HERE, 'ratchet.py'), 'ratchet')

# --- config, pinned ----------------------------------------------------------
SEEDS = int(os.environ.get('SEEDS', '6'))
T = float(os.environ.get('T', '9.0'))
# GEO: which STALL GEOMETRY to score. 'canonical' = the hand-placed DROPS_* the
# whole project has measured on. An integer selects a phase-rotated schedule via
# `rig_checks.phase_drops` -- U33's corrected randomiser, count- and
# duration-preserving, no interval over t=0. Used to DERIVE which bars are
# gateable: U33 measured that even PAIRED quantities move ~0.9 pt across
# geometry, so a bar whose verdict flips across the geometry sample is a bar the
# canonical point alone cannot establish. See geometry.md.
GEO = os.environ.get('GEO', 'canonical')
WARM = 1.0                       # RC.SimD's own warm-up (`reserved_composite.py:175`
                                 # on this branch, `:227` on dev after U35)
GRAN = M.DT * 1000.0             # = 10.0 ms, the model tick. Physical.
TOL = 2.0 * GRAN                 # "+2*gran": one tick of slack either side
FIXED343 = 343.0                 # the hold the SHIPPED formula COMPUTES on the
                                 # canonical N2 rig: `paths.go:102`
                                 # `spread + 3*j + 250`, clamped to
                                 # [HoldMin, HoldMax] = [150, 350] ms
                                 # (`main.go:21-22`). On this rig that is
                                 # 18 + 3*25 + 250 = 343 ms, from `RC.cellA()`
                                 # loc/down owd 25/2 jit 25 and `RC.eth()` 8/1
                                 # jit 1. It is NOT `HoldMax`, which is 350.
                                 # Not a threshold: it is the OTHER ARM of the pair.


# --- B4 / r1 sec 8's granularity-inflation guard, BOTH limbs -----------------
# r1 (`modes-r2-study/fable-modes-design.md:350-351`) pre-registers the guard as
# two limbs: "HOLD-4 asserts hold==gran with zero observations AND gran is
# asserted <=10ms in model and == ticker period in Go". Only the first limb was
# implemented. HOLD-4 compares the ratchet's floor against the SAME variable it
# was handed, so it is invariant to inflation AT THE SOURCE: raise `nsched_model.DT`
# and GRAN, TOL and all three HOLD-4 bars move together and still pass. This is
# limb two, and it is the limb that is anchored OUTSIDE the battery.
def _gran_guard():
    src = open(os.path.join(SIM, 'nsched_model.py'), encoding='utf-8').read()
    m = re.search(r'(?m)^DT\s*=\s*([0-9.eE+-]+)\s*$', src)
    if not m:
        raise SystemExit('GRAN GUARD FAILED: no top-level `DT = ...` in nsched_model.py; '
                         'the granularity has no source to be pinned to.')
    dt_src = float(m.group(1)) * 1000.0
    if GRAN != dt_src:
        raise SystemExit('GRAN GUARD FAILED: GRAN=%r but nsched_model.py source says '
                         'DT*1000=%r. Granularity must come from the model tick, not '
                         'from a literal in this file.' % (GRAN, dt_src))
    if not (GRAN <= 10.0):
        raise SystemExit(
            'GRAN GUARD FAILED: gran=%.4f ms > 10 ms.\n'
            '  r1 sec 8 pre-registers "gran is asserted <=10ms in model" as the second\n'
            '  limb of the granularity-inflation guard, precisely because HOLD-4 alone\n'
            '  cannot see inflation at the source: raise DT and the ratchet floor, TOL\n'
            '  and every HOLD-4 expectation move together and all three still pass.\n'
            '  10 ms is `nsched_model.py:62 DT = 0.010`, the tick the whole battery and\n'
            '  every published margin were measured at -- not a tuning knob.' % GRAN)
    # Limb two, Go side. r1 says gran should also equal "the ticker period in Go".
    # MEASURED, and it does NOT: the shipped ring is ticked once per iteration of
    # the control loop, which sleeps PingIval.
    go = open(os.path.join(SIM, '..', 'daemon', 'main.go'), encoding='utf-8').read()
    if 'ring.Tick(now)' not in go:
        raise SystemExit('GRAN GUARD FAILED: `ring.Tick(now)` is gone from daemon/main.go, '
                         'so the cadence this guard reports is no longer the ring cadence.')
    mg = re.search(r'PingIval\s*=\s*(\d+)\s*\*\s*time\.Millisecond', go)
    if not mg:
        raise SystemExit('GRAN GUARD FAILED: cannot read PingIval from daemon/main.go; '
                         'the Go ring tick period is unmeasurable from here.')
    return dt_src, float(mg.group(1))


GO_TICK_MS = None                # filled by _gran_guard, reported in the banner

# SPD-3's two measured ratios. Deep saturation is the one place the design accepts
# a cost, so this is the only bar carrying a ratio rather than a bare >= / <=.
# Both are derived from THIS instrument's own geometry sample, not from r1.
CAL = {
    'SPD3_GP': None,             # filled below from measurement (see set_cal)
    'SPD3_P95': None,
}

# --- the defect injections that prove the bars can go RED --------------------
# Each is a REAL historical design error from this project's own record, not a
# synthetic mutation. `DEFECT=<name>` selects one. `none` is the shipped tree.
DEFECTS = {
    'none': 'no injection -- the tree as it stands',
    'rank-static': 'SPD: draw order = static latency rank (V1). REFUTED in r1 sec 3.2 '
                   '(= CPF strict priority; -9.07% gp at S3@90k)',
    'rank-hungriest': 'SPD: draw order = hungriest (V0) -- i.e. `speed` silently '
                      'degraded into `max`',
    'hold-quantile': 'HOLD: ratchet replaced by the REFUTED q=0.99/W=3s quantile '
                     '(r1 sec 4.2)',
    'rank-mid-meter': 'SPD-5: the mid draw key becomes owd + max(local_ms, far_ms) '
                      '-- feeding the cap meter into the RANK, REFUTED in r1 sec 5 '
                      '(p95 456 vs 371 at mid 0.85)',
    'hold-gran': 'HOLD: ratchet replaced by a bare granularity hold (the ratchet '
                 'never learns)',
    'warmup-max': 'HOLD-3: warm-up hold = the shipped computed hold (343 ms on '
                  'this rig) instead of granularity -- the exact bug r1 sec 4.4 '
                  'deletes ("warm-up = HoldMax is backwards"). 343 is NOT HoldMax: '
                  'HoldMax is 350 (`daemon/main.go:22`); 343 is what '
                  '`paths.go:102` spread+3*j+250 computes on the canonical rig',
    'ratchet-x3': 'HOLD: granularity inflated 3x, so the floor becomes a pad again. '
                  'This is r1 sec 8\'s OWN pre-registered pass-by-artifact route '
                  '("granularity inflation -- gran becomes the new pad"), and the '
                  'guard it names is exactly HOLD-4',
    'calibrate': 'no bars; print the measured SPD-3 ratios so CAL can be set',
}
DEFECT = os.environ.get('DEFECT', 'none')
if DEFECT not in DEFECTS:
    raise SystemExit('unknown DEFECT=%r; known: %s' % (DEFECT, ', '.join(sorted(DEFECTS))))

FAILS = []
LINES = []


def say(s=''):
    print(s, flush=True)


def ulp_margin(got, want):
    """Margin for a UNIT equality bar, in ULPs of the expected value.

    HOLD-4 asserts an EXACT identity of the ratchet's own definition, so the only
    admissible slack is float representation error. `math.ulp(want)` is that, and
    it is not a tuning knob: it is the spacing of IEEE754 doubles at `want`.
    Measured on the shipped ratchet: HOLD-4a and HOLD-4c land exactly (0 ULP),
    HOLD-4b lands 1 ULP high (147.00000000000003 vs 147.0), which is why the bar
    is `<= 1 ULP` and not `== 0`.

    The previous form was `abs(got-want) < 1e-9` / `< 1e-6` with the margin
    computed SEPARATELY as `-abs(got-want)`; that let the tolerance be widened to
    5.0 ms while the printed margin stayed 0. Here the tolerance IS the margin."""
    return 1.0 - abs(got - want) / math.ulp(want)


def fmt_margin(m):
    """The margin's canonical printed form: 9 significant digits, and never the
    string '-0'. 9 sig-digits is IEEE754 double precision (~16 digits) with seven
    digits of headroom for accumulated rounding, so it is stable across platforms
    while still separating a 0.85 pt margin from a 39.93 pt one. It is what the
    gate pins, so it has to be exact and it has to be reproducible."""
    return '%.9g' % (m + 0.0)


def bar(bid, subject, margin, detail):
    """One bar check. THE VERDICT IS THE SIGN OF THE MARGIN -- there is no
    separate predicate, by construction.

    This is the fix for the fourth weakened-green gate in this project. The old
    signature took `ok` and `slack` as INDEPENDENT arguments, so a tolerance
    could be widened in `ok` (`abs(h1-G) < 1e-9` -> `< 5.0`) while `slack` went
    on printing the undiluted number; the gate read verdicts, the verdict did not
    move, and the run went green. Four gated bars were diluted that way and the
    gate exited 0 with every mutation row `-> ok`.

    Now a bar is ONE number in ONE unit, and `PASS` means `margin >= 0`. Widening
    a bar is therefore not expressible without changing the margin this line
    prints -- and `latency_gate.py`'s MARGIN_PIN pins that number for every one
    of the 31 check lines, so the change is a hard exit 1 with the delta named.
    The mutation matrix proves a bar detects a GROSS defect; the margin pin is
    what BOUNDS how much headroom the bar has. They are different jobs.

    The margin is always printed (there is no MARGINS switch any more): a number
    that only appears when someone asks for it is a number nothing checks."""
    ok = margin >= 0.0
    say('  %-7s %-52s %s  %s' % (bid, subject, 'PASS' if ok else 'FAIL', detail))
    say('  MARGIN %s | %s | %s' % (bid, subject, fmt_margin(margin)))
    if not ok:
        FAILS.append((bid, subject, detail))


# =============================================================================
# scoring
# =============================================================================
def stats(sim, pairs, lo=WARM, hi=None):
    """Percentiles + delivered count over frames ENQUEUED in (lo, hi]."""
    hi = sim.T if hi is None else hi
    lat = sorted((rt - sim.enq[sq]) * 1000.0 for sq, rt in pairs
                 if lo < sim.enq[sq] <= hi)
    gp = len(lat) * M.PKT_KB / max(1e-9, (hi - lo))
    return dict(p50=pct(lat, .5), p95=pct(lat, .95), p99=pct(lat, .99),
                n=len(lat), gp=gp)


def score_fixed(sim, hold_ms):
    items = [(a, sq) for sq, a in sim.arr.items() if a is not None]
    release, skips, _d = M.reorder_release(items, hold_ms / 1000.0)
    rel = set(release)
    late = sum(1 for (a, sq) in items if sq not in rel and sim.enq.get(sq, 0) > WARM)
    st = stats(sim, list(release.items()))
    st['late'] = late
    st['release'] = release
    return st


def score_ratchet(sim, seed_ms=0.0, warm_hold_ms=None):
    items = [(a, sq) for sq, a in sim.arr.items() if a is not None]
    if DEFECT == 'hold-gran':
        release, skips, _h = M.reorder_release(items, GRAN / 1000.0)
    elif DEFECT == 'hold-quantile':
        from holdlib import dyn_release
        r = dyn_release(sim.arr, sim.enq, 0.99, 3.0, warm=WARM, gran_ms=GRAN)
        # dyn_release reports percentiles and late but no release map, so the
        # HOLD-3 window check is skipped under this defect (it prints `-`).
        r['release'] = None
        r['gp'] = r['deliv'] * M.PKT_KB / max(1e-9, (sim.T - WARM))
        r['n'] = r['deliv']
        return r
    elif DEFECT == 'ratchet-x3':
        release, skips, _h = _ratchet_x3(items)
    elif DEFECT == 'warmup-max' and warm_hold_ms is not None:
        # Warm-up armed at HoldMax instead of granularity: score the [0, warm]
        # window under 343 and the rest under the ratchet, which is what a ring
        # that arms at HoldMax actually does.
        release, skips, _h = _split_warmup(items, warm_hold_ms)
    else:
        release, skips, _h = ratchet_release(items, GRAN, seed_ms)
    rel = set(release)
    late = sum(1 for (a, sq) in items if sq not in rel and sim.enq.get(sq, 0) > WARM)
    st = stats(sim, list(release.items()))
    st['late'] = late
    st['release'] = release
    return st


def _ratchet_x3(items):
    """The defect: inflate the granularity floor 3x, so it stops being the timer
    tick and becomes a pad -- the shape of `nsched_model.py:1403`'s `3.0*max(jits)`
    that the derived hold exists to delete. r1 sec 8 pre-registers this exact
    artifact route ("granularity inflation: gran becomes the new pad") and names
    HOLD-4 as its guard, so this defect is the design's own test of its own bar."""
    return ratchet_release(items, GRAN * 3.0, 0.0)


def _split_warmup(items, warm_hold_ms):
    """Score with `warm_hold_ms` while the ring is cold and the ratchet after."""
    early = [(a, sq) for (a, sq) in items if a <= WARM]
    late_i = [(a, sq) for (a, sq) in items if a > WARM]
    r1, s1, _ = M.reorder_release(early, warm_hold_ms / 1000.0)
    r2, s2, _ = ratchet_release(late_i, GRAN, 0.0)
    r1.update(r2)
    return r1, s1 + s2, []


def spotty_share(sim):
    """Fraction of PLACED frames that landed on a spotty-class source. N-generic:
    summed over the identity class, never over an index."""
    tot = sum(sim.assigned) or 1
    return sum(sim.assigned[i] for i in range(sim.N) if sim.spotty[i]) / tot


def segment_spotty_share(sim, lo, hi):
    """Same quantity restricted to frames ENQUEUED in [lo, hi). Uses `sent_on`,
    which records the link each seq was placed on -- no change to the harness."""
    tot = 0
    sp = 0
    for sq, links in sim.sent_on.items():
        if not (lo <= sim.enq.get(sq, -1) < hi) or not links:
            continue
        for i in links:
            tot += 1
            if sim.spotty[i]:
                sp += 1
    return (sp / tot) if tot else 0.0


def n_late(sim):
    """Count of frames that arrived after a higher seq already had -- i.e. the
    number of frames an in-order ring would have to wait for. Structural."""
    seqs = sorted(sq for sq, a in sim.arr.items() if a is not None)
    m = float('inf')
    c = 0
    for sq in reversed(seqs):
        a = sim.arr[sq]
        if a > m:
            c += 1
        if a < m:
            m = a
    return c


# =============================================================================
# rigs -- fixed set, so nobody can tune the rig homogeneous to make DeltaD ~ 0
# =============================================================================
def drops(name):
    """Dropout schedule for a spotty archetype under the selected geometry."""
    if GEO == 'canonical':
        return {'cellA': RC.DROPS_A, 'cellB': RC.DROPS_B, 'cellC': RC.DROPS_C}[name]
    import rig_checks as RK
    return RK.phase_drops(name, int(GEO), T)


S3 = RC.build_rig([RC.eth(), RC.wifi(), RC.cellA(drops('cellA'))], bottleneck='edge')
S4 = RC.build_rig([RC.cellA(drops('cellA')), RC.cellB(drops('cellB')),
                   RC.cellC(drops('cellC'))], bottleneck='edge')
ETH1 = RC.build_rig([RC.eth()], bottleneck='edge')          # SPD-1's N=1 control
CANON_E = RC.build_rig([RC.cellA(drops('cellA')), RC.eth()], bottleneck='edge')
CANON_M = RC.build_rig([RC.cellA(drops('cellA')), RC.eth()], bottleneck='mid')
NOM_M = 107000.0        # cellA 29000 + eth 78000, the canonical N2 nominal

SPEED_KEY = 'v2'
MAX_KEY = 'v0'
if DEFECT == 'rank-static':
    SPEED_KEY = 'v1'
elif DEFECT == 'rank-hungriest':
    SPEED_KEY = 'v0'
SPEED_KEY_M = 'g2'
if DEFECT in ('rank-static', 'rank-hungriest'):
    SPEED_KEY_M = 'g0'
elif DEFECT == 'rank-mid-meter':
    SPEED_KEY_M = 'g2m'


def run_edge(defs, offer, key, sd):
    of = offer if callable(offer) else (lambda t, _L=offer: float(_L))
    s = VSim(defs, of, T, sd, vkey=key)
    s.run()
    return s


def run_mid(defs, offer, key, sd):
    of = offer if callable(offer) else (lambda t, _L=offer: float(_L))
    s = GSim(defs, of, T, sd, gkey=key)
    s.run()
    return s


def sweep(fn, n=None):
    """Run fn(seed) over the seed set, returning the list of results."""
    return [fn(sd) for sd in range(n or SEEDS)]


# =============================================================================
def main():
    t0 = time.time()
    say('=' * 100)
    say('OBJ-D LATENCY BARS -- SPD-1..6, HOLD-1..4   (U14)')
    say('=' * 100)
    say('  seeds=%d T=%.1fs gran=%.1fms rig=edge+mid geo=%s defect=%s'
        % (SEEDS, T, GRAN, GEO, DEFECT))
    say('  physics : %s' % os.path.relpath(M.__file__, SIM))
    say('  rig     : %s' % os.path.relpath(RC.__file__, SIM))
    say('  gran    : %.1f ms from nsched_model.py source DT, <=10 ms asserted '
        '(r1 sec 8 limb 2)' % GRAN)
    say('  go tick : %.0f ms -- daemon/main.go PingIval, the cadence that calls '
        'ring.Tick(now).' % GO_TICK_MS)
    say('            r1 sec 8 also asks for gran == the Go ticker period. MEASURED, '
        'and it')
    say('            does NOT hold: %.0f ms model vs %.0f ms shipped ring. Recorded as an'
        % (GRAN, GO_TICK_MS))
    say('            open finding, not asserted away -- every HOLD bar here is '
        'scored at a')
    say('            granularity 10x finer than the shipped ring can resolve.')
    say('  DEFECT  : %s' % DEFECTS[DEFECT])
    say('  ADR-004: every bar below is PAIRED, STRUCTURAL or UNIT. No absolute')
    say('  loss or latency threshold is asserted against this rig anywhere.')
    say('')

    # -------------------------------------------------------------- SPD-1 ----
    # S3 edge, offer 60k: the fastest source alone carries the whole offer
    # (eth base 78000 > 60000). OBJ-D says `speed` minimises latency subject to
    # demanded throughput; at a load that FITS one source, touching a second one
    # can only add skew. So: nothing on a spotty source, nothing out of order,
    # and no worse than just using that source -- the N=1 control, same seeds.
    say('#   SPD-1  S3 edge offer=60000  speed vs the N=1 eth control  nominal_agg=%d'
        % 60000)
    sp = sweep(lambda sd: run_edge(S3, 60000.0, SPEED_KEY, sd))
    ctl = sweep(lambda sd: run_edge(ETH1, 60000.0, SPEED_KEY, sd))
    sh = med([spotty_share(s) for s in sp])
    ng = med([n_late(s) for s in sp])
    p95s = med([score_ratchet(s)['p95'] for s in sp])
    p95c = med([score_ratchet(s)['p95'] for s in ctl])
    gps = med([score_ratchet(s)['gp'] for s in sp])
    gpc = med([score_ratchet(s)['gp'] for s in ctl])
    bar('SPD-1a', 'spotty-class share == 0 (structural)',
        -sh, 'share=%.4f' % sh)
    bar('SPD-1b', 'out-of-order arrivals == 0 (structural)',
        -float(ng), 'late_arrivals=%d' % ng)
    bar('SPD-1c', 'paired p95 <= p95(N=1 eth control) + 2*gran',
        p95c + TOL - p95s, 'p95=%.0f ctl=%.0f tol=%.0f' % (p95s, p95c, TOL))
    bar('SPD-1d', 'paired gp >= gp(N=1 eth control)',
        100.0 * (gps - gpc) / max(1e-9, gpc), 'gp=%.0f ctl=%.0f' % (gps, gpc))
    say('')

    # -------------------------------------------------------------- SPD-2 ----
    # S3 edge 90k: the offer no longer fits eth alone, so `speed` must SPILL.
    # Design r1 sec 6 measured ZERO goodput cost for the ordering at <=90k, so
    # the bar carries no margin at all: spilling by marginal completion time must
    # not cost goodput OR latency against hungriest-first on the same seeds.
    say('#   SPD-2  S3 edge offer=90000  speed vs max, identical seeds  nominal_agg=90000')
    sp = sweep(lambda sd: run_edge(S3, 90000.0, SPEED_KEY, sd))
    mx = sweep(lambda sd: run_edge(S3, 90000.0, MAX_KEY, sd))
    a = [score_ratchet(s) for s in sp]
    b = [score_ratchet(s) for s in mx]
    gp_s, gp_m = med([x['gp'] for x in a]), med([x['gp'] for x in b])
    p95_s, p95_m = med([x['p95'] for x in a]), med([x['p95'] for x in b])
    sh_s, sh_m = med([spotty_share(s) for s in sp]), med([spotty_share(s) for s in mx])
    bar('SPD-2a', 'paired gp >= gp(max)',
        100.0 * (gp_s - gp_m) / max(1e-9, gp_m), 'gp=%.0f max=%.0f' % (gp_s, gp_m))
    bar('SPD-2b', 'paired p95 <= p95(max)',
        p95_m - p95_s, 'p95=%.0f max=%.0f' % (p95_s, p95_m))
    bar('SPD-2c', 'spotty-class share == 0 at spill (structural)',
        -sh_s, 'share=%.4f max_share=%.4f' % (sh_s, sh_m))
    say('')

    # -------------------------------------------------------------- SPD-3 ----
    # S3 edge 140k, deep saturation (0.92 of sum-cap). This is the ONE place the
    # design accepts a cost for the ordering (r1 sec 6: -2.3% gp at 140k), so
    # this is the only bar carrying a measured ratio rather than >= / <=.
    say('#   SPD-3  S3 edge offer=140000  speed vs max, saturation  nominal_agg=140000')
    sp = sweep(lambda sd: run_edge(S3, 140000.0, SPEED_KEY, sd))
    mx = sweep(lambda sd: run_edge(S3, 140000.0, MAX_KEY, sd))
    a = [score_ratchet(s) for s in sp]
    b = [score_ratchet(s) for s in mx]
    gp_s, gp_m = med([x['gp'] for x in a]), med([x['gp'] for x in b])
    p95_s, p95_m = med([x['p95'] for x in a]), med([x['p95'] for x in b])
    if DEFECT == 'calibrate':
        say('  CAL SPD3_GP  = %.4f   (gp %.0f / %.0f)' % (gp_s / gp_m, gp_s, gp_m))
        say('  CAL SPD3_P95 = %.4f   (p95 %.0f / %.0f)' % (p95_s / max(1e-9, p95_m),
                                                           p95_s, p95_m))
    else:
        bar('SPD-3a', 'paired gp >= %.2f * gp(max)  [measured ratio]' % CAL['SPD3_GP'],
            100.0 * (gp_s / max(1e-9, gp_m) - CAL['SPD3_GP']),
            'ratio=%.4f bar=%.2f' % (gp_s / max(1e-9, gp_m), CAL['SPD3_GP']))
        bar('SPD-3b', 'paired p95 <= %.2f * p95(max)  [measured ratio]' % CAL['SPD3_P95'],
            100.0 * (CAL['SPD3_P95'] - p95_s / max(1e-9, p95_m)),
            'ratio=%.4f bar=%.2f' % (p95_s / max(1e-9, p95_m), CAL['SPD3_P95']))
    say('')

    # -------------------------------------------------------------- SPD-4 ----
    # S4 edge 50k, ALL sources spotty and homogeneous in OWD. This is the bar
    # that stops SPD-1..3 being passed by "always pick the ethernet": there is no
    # steady source here, so ordering has to earn its keep on jitter and dropouts
    # alone. r1 sec 3.1: homogeneity of OWD does NOT eliminate gaps.
    say('#   SPD-4  S4 edge offer=50000  all-spotty, speed vs max  nominal_agg=50000')
    sp = sweep(lambda sd: run_edge(S4, 50000.0, SPEED_KEY, sd))
    mx = sweep(lambda sd: run_edge(S4, 50000.0, MAX_KEY, sd))
    a = [score_ratchet(s) for s in sp]
    b = [score_ratchet(s) for s in mx]
    gp_s, gp_m = med([x['gp'] for x in a]), med([x['gp'] for x in b])
    p95_s, p95_m = med([x['p95'] for x in a]), med([x['p95'] for x in b])
    bar('SPD-4a', 'paired gp >= gp(max)',
        100.0 * (gp_s - gp_m) / max(1e-9, gp_m), 'gp=%.0f max=%.0f' % (gp_s, gp_m))
    bar('SPD-4b', 'paired p95 <= p95(max)',
        p95_m - p95_s, 'p95=%.3f max=%.3f' % (p95_s, p95_m))
    say('')

    # -------------------------------------------------------------- SPD-5 ----
    # Canonical N2 MID, 0.65 and 0.85. Same key, but now behind the cap's meter
    # gate instead of the edge socket gate. The point of the bar is that the
    # design is E1-INVARIANT: the ordering must win under BOTH gates, because E1
    # has not run and nobody knows which one ships.
    say('#   SPD-5  N2 mid cellA+eth  speed-key vs Dc(hungriest)  nominal_agg=%d' % NOM_M)
    for load in (0.65, 0.85):
        sp = sweep(lambda sd: run_mid(CANON_M, load * NOM_M, SPEED_KEY_M, sd))
        mx = sweep(lambda sd: run_mid(CANON_M, load * NOM_M, 'g0', sd))
        a = [score_ratchet(s) for s in sp]
        b = [score_ratchet(s) for s in mx]
        gp_s, gp_m = med([x['gp'] for x in a]), med([x['gp'] for x in b])
        p95_s, p95_m = med([x['p95'] for x in a]), med([x['p95'] for x in b])
        lt_s, lt_m = med([x['late'] for x in a]), med([x['late'] for x in b])
        sub = 'load=%.2f' % load
        bar('SPD-5a', '%s paired gp >= gp(Dc)' % sub,
            100.0 * (gp_s - gp_m) / max(1e-9, gp_m), 'gp=%.0f Dc=%.0f' % (gp_s, gp_m))
        bar('SPD-5b', '%s paired p95 <= p95(Dc)' % sub,
            100.0 * (p95_m - p95_s) / max(1e-9, p95_m),
            'p95=%.0f Dc=%.0f' % (p95_s, p95_m))
        bar('SPD-5c', '%s paired late-discard <= late(Dc)' % sub,
            lt_m - lt_s, 'late=%.0f Dc=%.0f' % (lt_s, lt_m))
    say('')

    # -------------------------------------------------------------- SPD-6 ----
    # Step load 30k -> 90k -> 30k on S3. r1 bar table marks this UNMEASURED and
    # says why it must exist: "offer shaping avoids spill transitions". A rank
    # with any hidden stickiness passes SPD-1..5 (all constant-offer) and fails
    # here. Both limbs compare a segment of the run against ANOTHER SEGMENT OF
    # THE SAME RUN, so there is no constant and no cross-run physics.
    say('#   SPD-6  S3 edge STEP 30k->90k->30k  share follows demand  nominal_agg=90000')

    def step(t):
        return 30000.0 if (t < 3.0 or t >= 6.0) else 90000.0

    sp = sweep(lambda sd: run_edge(S3, step, SPEED_KEY, sd))
    s1 = med([segment_spotty_share(s, 1.0, 3.0) for s in sp])   # after warm-up
    s2 = med([segment_spotty_share(s, 3.0, 6.0) for s in sp])
    s3 = med([segment_spotty_share(s, 6.0, T) for s in sp])
    bar('SPD-6a', 'share rises or holds into the 90k step (no starvation)',
        s2 - s1, 'seg1=%.4f seg2=%.4f' % (s1, s2))
    bar('SPD-6b', 'share RETURNS to the fits-load value after the step',
        s1 - s3, 'seg3=%.4f seg1=%.4f' % (s3, s1))
    bar('SPD-6c', 'no residual pinning: seg3 share <= seg2 share',
        s2 - s3, 'seg3=%.4f seg2=%.4f' % (s3, s2))
    say('')

    # ------------------------------------------------------- HOLD-1 / HOLD-3 --
    # Canonical N2 EDGE 0.85, `max` (hungriest). Post-hoc rescoring of the SAME
    # runs under the ratchet and under the shipped fixed 343 ms -- zero re-run
    # variance, the tightest pairing available anywhere in this project.
    # OBJ-B/OBJ-D: the derived hold must not buy its derivation with latency.
    say('#   HOLD-1 N2 edge cellA+eth load=0.85  ratchet vs fixed-343  nominal_agg=%d'
        % NOM_M)
    runs = sweep(lambda sd: run_edge(CANON_E, 0.85 * NOM_M, MAX_KEY, sd))
    R = [score_ratchet(s, warm_hold_ms=FIXED343) for s in runs]
    F = [score_fixed(s, FIXED343) for s in runs]
    burst = med([max(late_runs(s.arr) or [0]) for s in runs])
    for k in ('p50', 'p95', 'p99'):
        r, f = med([x[k] for x in R]), med([x[k] for x in F])
        bar('HOLD-1' + {'p50': 'a', 'p95': 'b', 'p99': 'c'}[k],
            'edge %s(ratchet) <= %s(343) + 2*gran' % (k, k),
            f + TOL - r, '%s=%.0f fixed=%.0f tol=%.0f' % (k, r, f, TOL))
    lr, lf = med([x['late'] for x in R]), med([x['late'] for x in F])
    bar('HOLD-1d', 'edge late(ratchet) <= late(343) + one event burst',
        lf + burst - lr, 'late=%.0f fixed=%.0f burst=%.0f' % (lr, lf, burst))

    # HOLD-3 rides the same runs: the design deletes "warm-up hold = HoldMax"
    # (r1 sec 4.4 -- one path delivering => no reorder possible). Scored INSIDE
    # [0, warm), which is the window every other bar excludes.
    e_in = med([stats(s, list(sc['release'].items()), lo=-1.0, hi=WARM)['p95']
                for s, sc in zip(runs, R) if sc['release'] is not None] or [0.0])
    e_all = med([x['p95'] for x in R])
    bar('HOLD-3a', 'edge p95 of frames enqueued in [0,1s) <= overall p95 + 2*gran',
        e_all + TOL - e_in, 'warm_p95=%.0f overall=%.0f tol=%.0f' % (e_in, e_all, TOL))
    say('')

    # ------------------------------------------------------- HOLD-2 / HOLD-3 --
    say('#   HOLD-2 N2 mid cellA+eth load=0.85  ratchet vs fixed-343  nominal_agg=%d'
        % NOM_M)
    runsm = sweep(lambda sd: run_mid(CANON_M, 0.85 * NOM_M, 'g0', sd))
    Rm = [score_ratchet(s, warm_hold_ms=FIXED343) for s in runsm]
    Fm = [score_fixed(s, FIXED343) for s in runsm]
    burstm = med([max(late_runs(s.arr) or [0]) for s in runsm])
    r50, f50 = med([x['p50'] for x in Rm]), med([x['p50'] for x in Fm])
    bar('HOLD-2a', 'mid p50(ratchet) <= p50(343) + 2*gran',
        f50 + TOL - r50, 'p50=%.0f fixed=%.0f tol=%.0f' % (r50, f50, TOL))
    lrm, lfm = med([x['late'] for x in Rm]), med([x['late'] for x in Fm])
    bar('HOLD-2b', 'mid late(ratchet) <= late(343) + one event burst',
        lfm + burstm - lrm, 'late=%.0f fixed=%.0f burst=%.0f' % (lrm, lfm, burstm))
    m_in = med([stats(s, list(sc['release'].items()), lo=-1.0, hi=WARM)['p95']
                for s, sc in zip(runsm, Rm) if sc['release'] is not None] or [0.0])
    m_all = med([x['p95'] for x in Rm])
    bar('HOLD-3b', 'mid p95 of frames enqueued in [0,1s) <= overall p95 + 2*gran',
        m_all + TOL - m_in, 'warm_p95=%.0f overall=%.0f tol=%.0f' % (m_in, m_all, TOL))
    say('')

    # -------------------------------------------------------------- HOLD-4 ---
    # UNIT bar. No rig, no physics, no seeds: synthetic arrival traces and the
    # ratchet's own definition. This is the ONE bar in the battery whose
    # authority is not a paired rig comparison -- it is the design text that
    # DEFINES the formula (r1/r2 sec 4.4), so ADR-004's limit does not apply.
    say('#   HOLD-4 unit derivation of the ratchet   (no rig, no seeds)')
    G = GRAN
    if DEFECT == 'ratchet-x3':
        def rr(items, gran, seed=0.0, resets=()):
            return _ratchet_x3(items)
    else:
        rr = ratchet_release

    # (1) zero observations: a genuine hole, nothing ever arrives for seq 1.
    # The frontier must wait exactly `gran` and then skip.
    it = [(0.000, 0), (0.500, 2), (0.510, 3)]
    _rel, _sk, holds = rr(it, G)
    h1 = holds[0][1] if holds else -1.0
    bar('HOLD-4a', 'zero observations => hold == gran',
        ulp_margin(h1, G), 'hold=%.3f gran=%.3f' % (h1, G))

    # (2) inject a gap of exactly g: seq 1 arrives g after the ring blocked on it.
    # g is measured from the instant the frontier PASSED the seq -- the
    # un-censoring sample -- which is `blocked_at + hold` = 0 + gran here. Being
    # explicit about which clock the gap runs from is the whole point of a unit
    # bar; "injected gap g" in the r1 table does not say, and the two readings
    # differ by exactly one gran.
    g_ms = 137.0
    t_pass = G / 1000.0
    it = [(0.000, 0), (0.100, 2), (t_pass + g_ms / 1000.0, 1), (1.000, 3), (2.000, 5)]
    _rel, _sk, holds = rr(it, G)
    hmax = max(h for _t, h in holds) if holds else -1.0
    bar('HOLD-4b', 'injected gap g => hold == g + gran',
        ulp_margin(hmax, g_ms + G), 'hold=%.3f want=%.3f' % (hmax, g_ms + G))

    # (3) membership change resets the ratchet to the seed. Same trace as (2)
    # with a reset after the sample: the hold must fall back to seed + gran.
    seed_ms = 23.0
    _rel, _sk, holds = rr(it, G, seed_ms, (0.500,))
    after = [h for t, h in holds if t >= 0.500]
    h3 = min(after) if after else -1.0
    bar('HOLD-4c', 'membership change => hold == spread(D) + gran',
        ulp_margin(h3, seed_ms + G), 'hold=%.3f want=%.3f' % (h3, seed_ms + G))
    say('')

    # ---- verdict -------------------------------------------------------------
    say('-' * 100)
    if not FAILS:
        say('ALL BARS PASS')
    else:
        say('%d BAR FAILURE(S):' % len(FAILS))
        for bid, subj, det in FAILS:
            say('  FAIL %s %s: %s' % (bid, subj, det))
    say('elapsed %.0fs' % (time.time() - t0))
    sys.exit(0)


def set_cal():
    """SPD-3's two measured ratios, both derived from THIS instrument.

    SPD3_GP = 0.99. The gp ratio measured over the five-geometry sample at
    SEEDS=6 T=9.0 is canonical 0.9993, rot3 0.9986, rot7 0.9996, rot11 0.9990,
    rot19 0.9985 (`out/geo_*.txt`). The WORST of those, floored outward to 2 dp,
    is 0.99. It was 0.97 and the README derived 0.97 from "0.9993 floored
    outward to 2 dp", which produces 0.99, not 0.97: 0.97 actually came from r1
    sec 6's -2.3% at 140k -- the SUPERSEDED study, measured on a different
    instrument under a different hold policy. That is a number this battery
    never measured, and it left 2.9 pt of dilution headroom under a GATED bar.
    Retightened to what this instrument measures. The bar is strictly harder
    than it was; `hold-gran` still reddens it (ratio 0.5727, out/mut_hold-gran.txt).

    SPD3_P95 = 1.03. Canonical p95 ratio 1.0276, ceiled outward to 2 dp. SPD-3b
    is REPORTED, not gated: the ratio reaches 1.0446 on rot19 (out/geo_19.txt),
    which is the geometry flip that demotes it."""
    CAL['SPD3_GP'] = 0.99
    CAL['SPD3_P95'] = 1.03


set_cal()
_DT_SRC, GO_TICK_MS = _gran_guard()

if __name__ == '__main__':
    main()
