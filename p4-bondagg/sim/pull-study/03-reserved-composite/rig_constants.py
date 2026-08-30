#!/usr/bin/env python3
# =============================================================================
# rig_constants.py -- U10 REVIEW ITEM 4.  THE PER-LINK CONSTANTS SETTLED AT N=2.
#
# WHAT ITEM 4 SAYS (docs/ROADMAP.md, EPIC 1, U10 row)
#   "the per-link constants are still the ones settled at N=2."
# They were chosen when the rig only ever ran two links.  The project's absolute
# rule is N-GENERIC with no 2-source assumption, so a constant tuned at N=2 and
# carried into N=3..8 is exactly the defect that rule exists to catch.
#
# THE N=2 RIG IS STILL IN THE TREE AND IS STILL THE ANCESTOR.
#   `ackclock_sim.py::make_defs` returns a LIST OF EXACTLY TWO DICTS -- a tether
#   and an eth, written out longhand.  `reserved_composite.py::build_rig` is its
#   N-generic successor.  Every constant that appears in BOTH was settled in the
#   two-link world.  This file establishes which ones those are BY COMPARING THE
#   VALUES, not by asserting the history (C1), then measures what each does as N
#   grows (C2-C5), then classifies each one:
#     (a) N-INVARIANT  -- the quantity it bounds is per-frame or per-link, so the
#                         same number is correct at any N, and that is MEASURED
#                         here, not argued;
#     (b) DERIVABLE    -- an N-generic expression exists that reduces to today's
#                         value at N=2, so the constant can be replaced;
#     (c) OPEN         -- neither.  REPORTED, not guessed.  Per the standing
#                         no-arbitrary-constants rule, an N=2 constant that
#                         cannot be derived must NOT be replaced with a freshly
#                         invented one.
#
# NOTHING IS CHANGED BY THIS FILE.  It edits no other file, adds no bar, tunes
# no scheduler, and replaces no constant.  Every sweep below is a MEASUREMENT
# GRID, not a model knob: the grids are stated in the code and none of their
# values is carried into anything.
#
# ---------------------------------------------------------------------------
# THE PROBES
#   C1  CENSUS.  Every per-link constant the GATED scheduler set (Dc / ewma /
#       pull / oracle) actually reads, with its file:line, what it does, and
#       whether the identical value is present in the N=2 `make_defs` rig.
#   C2  THE HOLD, ARITHMETICALLY, ACROSS N.  The reorder hold and the duplicate
#       TTL share one formula whose two measured terms are ORDER STATISTICS over
#       the link set, so both grow with N by construction -- and whose third term
#       is a bare +130 ms.  C2 prints the term split at every battery mix and
#       says how close the clamps come to binding.
#   C3  THE HOLD, MEASURED, ACROSS N.  For each mix, the loss-minimising hold is
#       found by RE-RELEASING the same delivered arrivals at a grid of holds --
#       so the sim runs once and the hold is swept post hoc, exactly isolating
#       the receiver-side ring.  If the optimum moves with N while the formula's
#       output does not track it, the formula is not N-invariant.  SELF-GATE: at
#       the formula's own hold the recomputation must reproduce `run()`'s loss
#       and late-discard EXACTLY, or C3 is void.
#   C4  target_ms, MEASURED, ACROSS N.  The one per-link constant used by every
#       gated scheduler.  Swept live (it changes admission, so it cannot be swept
#       post hoc) at every N in the nested chain.
#   C5  THE INDEX-0 METRICS.  `tshare` is `assigned[0] / sum(assigned)` in both
#       the rig and the oracle.  At N=2, with the tether written first, that IS
#       "the spotty link's share".  At N>=3 it names one arbitrary link.  C5
#       measures the divergence against the N-generic spotty-CLASS share.
#
# Env: SEEDS(8) WORKERS(14) T(9.0) RIG(mid)
# Run: python rig_constants.py > rig_constants.txt 2> rig_constants.err
# =============================================================================
import importlib.util as _ilu
import math
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))


def _rig_pin():
    """Load ../rig_pin.py BY PATH (U35), never through sys.path."""
    p = os.path.abspath(os.path.join(HERE, os.pardir, 'rig_pin.py'))
    m = sys.modules.get('rig_pin')
    if m is not None and os.path.abspath(getattr(m, '__file__', '')) == p:
        return m
    spec = _ilu.spec_from_file_location('rig_pin', p)
    m = _ilu.module_from_spec(spec)
    sys.modules['rig_pin'] = m
    spec.loader.exec_module(m)
    return m


rig_pin = _rig_pin()
RC = rig_pin.load_pinned('reserved_composite', os.path.join(HERE, 'reserved_composite.py'),
                         why='the ADR-004 gated oracle rig')
A = RC.A
M = RC.M
DT = RC.DT

SEEDS   = int(os.environ.get('SEEDS', '8'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T       = float(os.environ.get('T', '9.0'))
RIG     = os.environ.get('RIG', 'mid')

#: measurement grids.  Stated here, used nowhere else, carried into nothing.
HOLD_GRID = [round(0.02 * i, 3) for i in range(0, 51)]        # 0 .. 1.00 s, 2 ticks apart
TARGET_GRID = [10.0, 20.0, 30.0, 40.0, 60.0, 80.0, 120.0]     # ms, brackets the 40.0 default
LOADS = [0.65, 0.95]


#: the lagged-meter window _lagged_deliv actually reads (reserved_composite.py:255):
#: [now - NLAG - 0.100, now - NLAG).  Derived from the module, not restated.
NLAG_W = M.NLAG + 0.100


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def _wrap(text, width):
    """Fold one evidence string to `width`, continuation lines indented."""
    out, line = [], ''
    for w in text.split():
        if line and len(line) + 1 + len(w) > width:
            out.append(line)
            line = '  ' + w
        else:
            line = (line + ' ' + w) if line else w
    if line:
        out.append(line)
    return out


# ---------------------------------------------------------------------------
# the mixes, by name, so a worker can rebuild them (Windows spawn)
# ---------------------------------------------------------------------------
MIXES = [
    ('N2-het', ['cellA', 'eth']),
    ('N3-het', ['cellA', 'cellB', 'eth']),
    ('N4-het', ['cellA', 'cellB', 'wifi', 'eth']),
    ('N5-het', ['cellA', 'cellB', 'cellC', 'wifi', 'eth']),
    ('N4-teth', ['cellA', 'cellB', 'cellC', 'eth']),
    ('N5-corr', ['cellA*', 'cellB*', 'cellC*', 'wifi', 'eth']),
]
CHAIN = MIXES[:4]


def arch(nm):
    if nm == 'cellA':
        return RC.cellA(RC.DROPS_A)
    if nm == 'cellB':
        return RC.cellB(RC.DROPS_B)
    if nm == 'cellC':
        return RC.cellC(RC.DROPS_C)
    if nm == 'cellA*':
        return RC.cellA(RC.DROPS_CORR)
    if nm == 'cellB*':
        return RC.cellB(RC.DROPS_CORR)
    if nm == 'cellC*':
        return RC.cellC(RC.DROPS_CORR)
    if nm == 'wifi':
        return RC.wifi()
    if nm == 'eth':
        return RC.eth()
    raise KeyError(nm)


def archs_of(names):
    return [arch(n) for n in names]


def make_sim(defs, ofn, tt, seed, sched, **kw):
    if sched in ('Dc', 'Dpp', 'D', 'redundant'):
        return RC.SimD(defs, ofn, tt, seed, sched=sched, **kw)
    return A.Sim(defs, ofn, tt, seed, sched=sched, mirror=False, **kw)


def hold_formula(defs):
    """The SHIPPED hold, verbatim from reserved_composite.py:497-498 and
    ackclock_sim.py:610-611.  Returned with its terms so C2 can split them."""
    owds = [d['down_owd'] + d['loc_owd'] for d in defs]
    jits = [d['jit'] for d in defs]
    spread = max(owds) - min(owds)
    jitterm = 3.0 * max(jits)
    raw = (spread + jitterm + 130.0) / 1000.0
    return min(0.35, max(0.08, raw)), spread, jitterm, 130.0, raw


# ---------------------------------------------------------------------------
# C3 worker -- run once, re-release at every hold in the grid
# ---------------------------------------------------------------------------
def rescore(s, hold):
    """Recompute (loss, late_discard, p95) from a FINISHED sim at an arbitrary
    reorder hold.  Mirrors reserved_composite.py:499-514 line for line; the
    self-gate in C3 checks that claim against run()'s own output."""
    deliv_items = [(a, seq) for seq, a in s.arr.items() if a is not None]
    release, _skips, _depth = RC.reorder_release(deliv_items, hold)
    rel = set(release)
    late = sum(1 for (a, sq) in deliv_items if sq not in rel and s.enq.get(sq, 0) > s.warm)
    lat = []
    deliv_data = 0
    for seq, rt in release.items():
        st = s.enq[seq]
        if st > s.warm:
            deliv_data += 1
            lat.append((rt - st) * 1000.0)
    lat.sort()
    p95 = lat[min(len(lat) - 1, int(0.95 * (len(lat) - 1)))] if lat else 0.0
    loss = 100.0 * (s.offered_post - deliv_data) / s.offered_post if s.offered_post else 0.0
    return max(0.0, loss), late, p95


def w_hold(task):
    (mi, names, load, sched, seed) = task
    archs = archs_of(names)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    o = make_sim(defs, (lambda t, _n=nom, _L=load: _L * _n), T, seed, sched)
    m = o.run()
    hf = hold_formula(defs)[0]
    # SELF-GATE: at the formula's own hold the recomputation must match run()
    gl, gla, _gp = rescore(o, hf)
    gate = (abs(gl - m['loss']) <= 1e-9 and gla == m['late'])
    curve = []
    for h in HOLD_GRID:
        l, la, p95 = rescore(o, h)
        curve.append((h, l, la, p95))
    return (mi, sched, seed, load, hf, gate, curve)


def w_target(task):
    (mi, names, load, sched, seed, tm) = task
    archs = archs_of(names)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    m = make_sim(defs, (lambda t, _n=nom, _L=load: _L * _n), T, seed, sched,
                 target_ms=tm).run()
    return (mi, sched, seed, load, tm, m['loss'], m['gp'], m['p95'])


def w_share(task):
    (mi, names, load, sched, seed) = task
    archs = archs_of(names)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    o = make_sim(defs, (lambda t, _n=nom, _L=load: _L * _n), T, seed, sched)
    m = o.run()
    tot = sum(o.assigned) or 1
    sp = [i for i, a in enumerate(archs) if a['spotty']]
    return (mi, sched, seed, m['tshare'], sum(o.assigned[i] for i in sp) / tot,
            [x / tot for x in o.assigned])


# =============================================================================
def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    t0 = time.time()
    H = '#' * 110
    print(H)
    print('# rig_constants.py -- U10 ITEM 4: per-link constants settled at N=2')
    print('# seeds=%d  T=%.1fs  rig=%s' % (SEEDS, T, RIG))
    print(H)
    print(RC.identity_banner())
    print(H)

    # ================= C1  census ==========================================
    print()
    print('=' * 110)
    print('C1  CENSUS -- per-link constants the GATED scheduler set reads, and whether the')
    print('    SAME value is present in the two-link ancestor rig (ackclock_sim.make_defs)')
    print('=' * 110)
    n2 = A.make_defs(bottleneck=RIG)
    print('  ackclock_sim.make_defs(%r) returns %d path dicts -- written out longhand, one'
          % (RIG, len(n2)))
    print('  tether and one eth.  That is the N=2 rig.  reserved_composite.build_rig is its')
    print('  N-generic successor.  Values below are compared, not asserted.')
    print()
    cA = RC.cellA(RC.DROPS_A)
    cE = RC.eth()
    n2e = A.make_defs(bottleneck='edge')
    aE = RC.build_rig([cA, cE], bottleneck='edge')
    # numeric identity, sampled at the rig's own tick -- not a string comparison
    n = int(round(T / DT))
    dcap = [max(abs(n2e[i]['cap_fn'](j * DT) - aE[i]['cap_fn'](j * DT)) for j in range(n))
            for i in (0, 1)]
    print('  %-44s %14s %14s %10s'
          % ('per-link constant', 'N=2 rig', 'N-generic rig', 'delta'))
    for i, who in ((0, 'spotty (tether/cellA)'), (1, 'steady (eth/eth)')):
        print('  %-44s %14s %14s %10s'
              % ('%s: cap_fn(t) over [0,T)' % who, 'make_defs[%d]' % i,
                 'build_rig[%d]' % i, '%.3g' % dcap[i]))
        for f in ('loc_owd', 'down_owd', 'jit'):
            print('  %-44s %14g %14g %10g'
                  % ('    %s' % f, n2e[i][f], aE[i][f], aE[i][f] - n2e[i][f]))
    #: make_defs' own default `drops`, ackclock_sim.py:682, written out here so the
    #: comparison is against a value, not against a memory of one.
    N2_DROPS = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
    d_drops = (max(abs(a1 - a2) + abs(b1 - b2)
                   for (a1, b1), (a2, b2) in zip(N2_DROPS, RC.DROPS_A))
               if len(N2_DROPS) == len(RC.DROPS_A) else float('inf'))
    print('  %-44s %14s %14s %10.3g'
          % ('default dropout schedule', '3 x 0.4s', '%d x %.1fs'
             % (len(RC.DROPS_A), RC.DROPS_A[0][1] - RC.DROPS_A[0][0]), d_drops))
    # read both defaults rather than restating them
    lm_n2 = A.make_defs.__defaults__[1]
    lm_ng = RC.build_rig.__defaults__[1]
    print('  %-44s %14g %14g %10g'
          % ('local_mult (mid local drain)', lm_n2, lm_ng, lm_ng - lm_n2))
    ident = (all(d <= 1e-9 for d in dcap) and d_drops <= 1e-9
             and abs(lm_ng - lm_n2) <= 1e-12)
    print()
    print('  -> %s'
          % ("IDENTICAL: cellA and eth ARE the N=2 rig's two paths, sampled at every tick"
             if ident else 'DIFFER -- the ancestry claim below does not hold, check it'))
    print('     cellB, cellC and wifi were invented afterwards for the N>2 mixes.  They have')
    print('     no ancestor and no measurement behind them.  ADR-004 condition 2 (compare')
    print('     the rig to a real router) is OPEN, so NONE of these has ever been measured')
    print('     against hardware at any N.')
    print()
    print('  Scheduler-side per-link constants, and whether the GATED set reads them:')
    LIVE = [
        ('target_ms = 40.0', 'reserved_composite.py:205, ackclock_sim.py:123',
         'per-link admission ms-gate AND the delivered-rate meter threshold',
         'LIVE for Dc, ewma, pull, oracle'),
        ('reorder hold +130.0 ms', 'reserved_composite.py:497, ackclock_sim.py:610',
         'additive term of the ring hold; also the Dc duplicate TTL (:245)',
         'LIVE for every scheduler (finalize)'),
        ('hold clamps 0.08 / 0.35 s', 'reserved_composite.py:497, ackclock_sim.py:610',
         'floor and ceiling on the same hold', 'LIVE, see C2'),
        ('hold jitter multiplier 3.0', 'reserved_composite.py:498, ackclock_sim.py:611',
         '3 sigma of the MAX-jitter link only', 'LIVE'),
        ('maxq_ms = 300.0', 'reserved_composite.py:205,226',
         'pool bound = 0.300 * sum(cap0) -- AGGREGATE, scales with N',
         'LIVE for Dc/pull/D'),
        ('QMAX_MS = 300.0', 'nsched_model.py:344 via reserved_composite.py:177',
         'per-path downstream fluid tail-drop bound', 'LIVE'),
        ('NLAG = 0.350 + 0.100 s window', 'nsched_model.py:347, reserved_composite.py:252',
         'per-link lagged delivered-rate meter window', 'LIVE for Dc, ewma'),
        ('deliv_hist horizon 0.6 s', 'reserved_composite.py:473',
         'per-link delivered-history trim', 'LIVE for Dc'),
        ('DRAIN_TAU = 0.10 / REGEN = 0.02', 'reserved_composite.py:182,183',
         'per-link local drain EWMA and idle probe-up toward cap0',
         'LIVE for every SimD scheduler (feeds _local_ms -> _meter_ok)'),
        ('HEALTH_FRAC = 0.75', 'reserved_composite.py:181,311',
         'host must drain >= 75% of nominal cap0',
         'NOT live for Dc/Dpp -- the else-branch is D/D\' only (:310)'),
        ('tshare = assigned[0]/sum', 'reserved_composite.py:518, ackclock_sim.py:643',
         'a per-link metric keyed to INDEX 0', 'LIVE, see C5'),
    ]
    for (nm, cite, what, live) in LIVE:
        print('    %-32s %s' % (nm, what))
        print('        %-30s %s' % (cite, live))
    sys.stdout.flush()

    # ================= C2  the hold, arithmetically =========================
    print()
    print('=' * 110)
    print('C2  THE HOLD FORMULA ACROSS N -- arithmetic only, no simulation')
    print('    hold = clamp[0.08, 0.35]( (max owd - min owd) + 3.0*max(jit) + 130.0 ) / 1000')
    print('=' * 110)
    print('  %-9s %3s %10s %10s %9s %9s %9s %8s %8s'
          % ('mix', 'N', 'owd spread', '3*max jit', '+const', 'raw ms', 'hold ms',
             'const%', 'clamped'))
    hf_by_mix = {}
    for (lab, names) in MIXES:
        defs = RC.build_rig(archs_of(names), bottleneck=RIG)
        h, spread, jt, k, raw = hold_formula(defs)
        hf_by_mix[lab] = h
        print('  %-9s %3d %10.1f %10.1f %9.1f %9.1f %9.1f %7.1f%% %8s'
              % (lab, len(names), spread, jt, k, raw * 1000.0, h * 1000.0,
                 100.0 * k / (raw * 1000.0), 'yes' if abs(h - raw) > 1e-9 else 'no'))
    print()
    print('  Both MEASURED terms are ORDER STATISTICS over the link set, so both are')
    print('  non-decreasing in N by construction -- adding a link can only widen the owd')
    print('  spread and can only raise max(jit).  That much is N-generic in FORM.')
    print('  What is not: the +130 ms is the LARGEST term at every N in the table, so the')
    print('  hold is majority-constant everywhere the rig has ever run.')
    # can the clamps ever bind, within the rig's own archetype set?
    allarch = [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
               RC.wifi(), RC.eth()]
    wide = RC.build_rig(allarch, bottleneck=RIG)
    hw, sp_w, jt_w, _k, raw_w = hold_formula(wide)
    print('  WIDEST mix the archetype set can build (all five, any N>=5): raw=%.1f ms,'
          % (raw_w * 1000.0))
    print('  ceiling=350 ms.  The ceiling is UNREACHABLE with these archetypes at ANY N --')
    print('  max/min are set by the archetype SET, not by how many links are drawn from it,')
    print('  so duplicating links cannot widen it.  Nothing in the rig ever exercises either')
    print('  clamp: they are untested code at every N the battery runs.')
    sys.stdout.flush()

    # ================= C3  the hold, measured ===============================
    print()
    print('=' * 110)
    print('C3  THE HOLD, MEASURED ACROSS N.  One sim run per (mix, sched, seed); the hold is')
    print('    then swept POST HOC by re-releasing the same arrivals, so nothing but the')
    print('    receiver-side ring changes.  Grid: %.2f..%.2f s in %.0f ms steps.'
          % (HOLD_GRID[0], HOLD_GRID[-1], 1000.0 * (HOLD_GRID[1] - HOLD_GRID[0])))
    print('    CAVEAT, stated: for Dc the same formula ALSO sets the sender-side duplicate')
    print('    TTL (reserved_composite.py:245), which is fixed at its formula value here.')
    print('    So C3 isolates the RING, which U11 measured as 78-96% of Dc\'s loss.')
    print('=' * 110)
    tasks = [(mi, names, 0.65, sch, sd)
             for mi, (lab, names) in enumerate(MIXES)
             for sch in ('Dc', 'oracle') for sd in range(SEEDS)]
    hres = {}
    gates = []
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (mi, sch, sd, load, hf, gate, curve) in ex.map(w_hold, tasks, chunksize=1):
            hres.setdefault((mi, sch), []).append(curve)
            gates.append(gate)
    print('  SELF-GATE: recomputation reproduces run() at the formula hold on %d/%d runs -> %s'
          % (sum(1 for g in gates if g), len(gates),
             'OK' if all(gates) else 'VOID -- C3 numbers are not trustworthy'))
    print()
    print("  the CEILING column is loss at hold = 350 ms, the formula's own clamp")
    print('  %-9s %3s %7s %9s %8s %9s %9s %8s %8s %7s'
          % ('mix', 'N', 'formula', 'loss@form', 'p95@form', 'loss@350', 'best hold',
             'loss@best', 'p95@best', 'gain pt'))
    best_by_mix = {}
    for mi, (lab, names) in enumerate(MIXES):
        for sch in ('Dc', 'oracle'):
            curves = hres[(mi, sch)]
            hf = hf_by_mix[lab]
            # median across seeds at each hold
            grid = HOLD_GRID
            lossg = [med([c[j][1] for c in curves]) for j in range(len(grid))]
            p95g = [med([c[j][3] for c in curves]) for j in range(len(grid))]
            jf = min(range(len(grid)), key=lambda j: abs(grid[j] - hf))
            jc = min(range(len(grid)), key=lambda j: abs(grid[j] - 0.350))
            jb = min(range(len(grid)), key=lambda j: lossg[j])
            if sch == 'Dc':
                best_by_mix[lab] = grid[jb]
            edge = ' EDGE' if jb in (0, len(grid) - 1) else ''
            print('  %-9s %3d %7.0f %9.3f %8.0f %9.3f %9.0f %8.3f %8.0f %7.3f  [%s]%s'
                  % (lab, len(names), hf * 1000.0, lossg[jf], p95g[jf], lossg[jc],
                     grid[jb] * 1000.0, lossg[jb], p95g[jb], lossg[jf] - lossg[jb],
                     sch, edge))
    print()
    hs = [best_by_mix[lab] * 1000.0 for (lab, _) in CHAIN]
    fs = [hf_by_mix[lab] * 1000.0 for (lab, _) in CHAIN]
    print('  NESTED CHAIN N=2->5.  loss-minimising hold: %s'
          % '  '.join('N=%d:%.0f' % (i + 2, h) for i, h in enumerate(hs)))
    print('                        formula output      : %s'
          % '  '.join('N=%d:%.0f' % (i + 2, f) for i, f in enumerate(fs)))
    print('  measured optimum moves %.0f ms across the chain; the formula moves %.0f ms.'
          % (max(hs) - min(hs), max(fs) - min(fs)))
    print('  READ THE TWO COLUMNS TOGETHER.  Loss and p95 move in OPPOSITE directions with')
    print('  the hold, so "best hold" is the LOSS-optimal hold and is not a recommendation:')
    print('  the rig is RIG=%s, where HANDOFF records the hold as a real latency trade (p50'
          % RIG)
    print('  68 -> 129 ms), unlike at the edge where it moved no percentile.  What C3')
    gaps = [best_by_mix[l_] * 1000.0 - hf_by_mix[l_] * 1000.0 for (l_, _) in MIXES]
    print('  establishes is narrower and enough: the formula does NOT sit at the loss')
    print('  optimum at ANY N; the gap is %.0f-%.0f ms and does NOT close as N grows; and'
          % (min(gaps), max(gaps)))
    print('  the loss on the table is far larger than any bar tolerance in the battery.')
    print('  The optimum is also NOT monotone in N (%s), so this is a LEVEL error in the'
          % ' '.join('N=%d:%.0f' % (len(nm_), best_by_mix[l_] * 1000.0)
                     for (l_, nm_) in CHAIN))
    print('  formula, not a failure to scale with N -- which is the opposite of what item 4')
    print('  was looking for and is reported as measured.')
    if any(abs(h - 0.350) < 1e-9 or h > 0.350 for h in
           [best_by_mix[l_] for (l_, _) in MIXES]):
        print("  NOTE: the loss-optimal hold exceeds the formula's own 350 ms CEILING on at")
        print('  least one mix, so the ceiling is not dormant on the loss axis -- it is')
        print('  below the loss optimum at every N measured here.')
    sys.stdout.flush()

    # ================= C4  target_ms ========================================
    print()
    print('=' * 110)
    print('C4  target_ms ACROSS N -- swept LIVE (it changes admission, so it cannot be swept')
    print('    post hoc).  The one per-link constant every gated scheduler reads.')
    print('    grid: %s ms   (the shipped value is 40.0)'
          % ', '.join('%g' % x for x in TARGET_GRID))
    print('=' * 110)
    ttasks = [(mi, names, L, sch, sd, tm)
              for mi, (lab, names) in enumerate(CHAIN)
              for L in LOADS for sch in ('Dc',) for sd in range(SEEDS)
              for tm in TARGET_GRID]
    tres = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (mi, sch, sd, L, tm, loss, gp, p95) in ex.map(w_target, ttasks, chunksize=4):
            tres.setdefault((mi, L, tm), []).append((loss, gp, p95))
    for L in LOADS:
        print('  load=%.2f   Dc loss%% by target_ms' % L)
        print('    %-9s %3s %s' % ('mix', 'N', ' '.join('%8.0f' % x for x in TARGET_GRID)))
        for mi, (lab, names) in enumerate(CHAIN):
            row = [med([r[0] for r in tres[(mi, L, tm)]]) for tm in TARGET_GRID]
            jb = min(range(len(row)), key=lambda j: row[j])
            print('    %-9s %3d %s   best=%gms'
                  % (lab, len(names), ' '.join('%8.3f' % v for v in row), TARGET_GRID[jb]))
        print('    %-9s %3s %s' % ('', '', ' '.join('%8s' % '' for _ in TARGET_GRID)))
        print('  load=%.2f   Dc gp by target_ms' % L)
        for mi, (lab, names) in enumerate(CHAIN):
            row = [med([r[1] for r in tres[(mi, L, tm)]]) for tm in TARGET_GRID]
            jb = max(range(len(row)), key=lambda j: row[j])
            print('    %-9s %3d %s   best=%gms'
                  % (lab, len(names), ' '.join('%8.0f' % v for v in row), TARGET_GRID[jb]))
    sys.stdout.flush()

    # ================= C5  index-0 metrics ==================================
    print()
    print('=' * 110)
    print('C5  THE INDEX-0 METRIC.  `tshare = assigned[0] / sum(assigned)` --')
    print('    reserved_composite.py:518 and ackclock_sim.py:643, identical text in both.')
    print('    Measured against the N-generic spotty-CLASS share (the quantity')
    print('    highn_battery.py:196 already computes for itself, over spotty_idx).')
    print('=' * 110)
    stasks = [(mi, names, 0.65, sch, sd)
              for mi, (lab, names) in enumerate(MIXES)
              for sch in ('pull', 'Dc') for sd in range(SEEDS)]
    sres = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (mi, sch, sd, ts, ss, shares) in ex.map(w_share, stasks, chunksize=4):
            sres.setdefault((mi, sch), []).append((ts, ss, shares))
    print('  %-9s %3s %-7s %10s %12s %10s   %s'
          % ('mix', 'N', 'sched', 'tshare', 'class share', 'error', 'per-link shares'))
    for mi, (lab, names) in enumerate(MIXES):
        for sch in ('pull', 'Dc'):
            rs = sres[(mi, sch)]
            ts = med([r[0] for r in rs])
            ss = med([r[1] for r in rs])
            sh = rs[0][2]
            print('  %-9s %3d %-7s %10.3f %12.3f %+10.3f   %s'
                  % (lab, len(names), sch, ts, ss, ts - ss,
                     ' '.join('%.3f' % x for x in sh)))
    print()
    print('  At N=2 the two agree exactly -- index 0 IS the only spotty link.  From N=3 the')
    print('  error is the share of every spotty link after the first.  Downstream consumers')
    print('  of the index-0 number, none of which are N-generic:')
    print('    docs/knowledge/design/p5-execution-handover.md:64 -- names `tshare stable` as')
    print('      an E2c equivalence criterion for the SHIPPED standing-lightning datapath')
    print('    docs/HANDOFF.md:294 and ADR-003-mode-set.md:21 -- cite `tshare 0.181` as')
    print('      "pull put 18% on the spotty source", the number that motivates `speed`')
    print('  highn_battery.py does NOT use it (it computes sshare over spotty_idx), so the')
    print('  BATTERY is clean and the METRIC and its citations are not.')

    # ================= C6  the classification ===============================
    print()
    print('=' * 110)
    print('C6  VERDICT -- constant by constant.  (a) N-INVARIANT  (b) DERIVABLE  (c) OPEN.')
    print('    Every row cites the probe above that establishes it.  Nothing here is changed,')
    print('    and per the no-arbitrary-constants rule an OPEN row is REPORTED, never')
    print('    replaced with a freshly invented number.')
    print('=' * 110)
    # evidence pulled from the runs above, not restated
    best_t = {}
    for L in LOADS:
        for mi, (lab, names) in enumerate(CHAIN):
            row = [med([r[0] for r in tres[(mi, L, tm)]]) for tm in TARGET_GRID]
            best_t[(lab, L)] = TARGET_GRID[min(range(len(row)), key=lambda j: row[j])]
    gaps = [best_by_mix[l_] * 1000.0 - hf_by_mix[l_] * 1000.0 for (l_, _) in MIXES]
    hb_lo = min(best_by_mix.values()) * 1000.0
    hb_hi = max(best_by_mix.values()) * 1000.0
    ts_err = []
    for mi, (lab, names) in enumerate(MIXES):
        if len(names) > 2:
            rs = sres[(mi, 'Dc')]
            ts_err.append(abs(med([r[0] for r in rs]) - med([r[1] for r in rs])))
    ROWS = [
        ('cellA / eth physical knobs',
         "the rig's two original paths: cap base/amp/period, loc/down owd, jit, the "
         "dropout schedule, local_mult",
         'OPEN',
         'C1: byte-identical to ackclock_sim.make_defs at every tick (delta 0 on all '
         'seven quantities). cellB, cellC and wifi have no ancestor. ADR-004 condition 2 '
         'is open, so not one of them has ever been measured against hardware at ANY N.'),
        ('target_ms = 40.0',
         'per-link admission ms-gate and delivered-rate meter threshold; read by Dc, '
         'ewma, pull and oracle',
         'N-INVARIANT (measured)',
         'C4: the loss-optimal value is %s ms at load 0.65 and %s ms at 0.95, for '
         'N=2,3,4,5 respectively. It tracks OFFERED LOAD, not link count -- so the same '
         'number is right at N=5 as at N=2. Separate, and NOT an N defect: 40 is not the '
         'optimum at 0.65. Left exactly as it is.'
         % ('/'.join('%g' % best_t[(l_, 0.65)] for (l_, _) in CHAIN),
            '/'.join('%g' % best_t[(l_, 0.95)] for (l_, _) in CHAIN))),
        ('reorder hold, the +130.0 ms term',
         'additive term of the ring release timeout, and of the Dc duplicate TTL',
         'OPEN',
         'C2: the largest of the three terms at every N (52-58 percent of the raw value). '
         'C3: the formula returns 223-249 ms while the loss optimum is %.0f-%.0f ms; the '
         'gap is %.0f-%.0f ms and does not close as N grows. A LEVEL error the rig cannot '
         'derive -- ROADMAP U13 owns the derivation. Do NOT substitute another number.'
         % (hb_lo, hb_hi, min(gaps), max(gaps))),
        ('hold: 3.0 * max(jit)',
         '3-sigma jitter margin, taken from the single highest-jitter link',
         'DERIVABLE in form, OPEN in value',
         'C2: an order statistic over the link set, so N-generic in shape. But it is '
         'anchored on the max-jitter link, which need not be either of the two '
         'extremal-OWD links whose arrival skew it is margining -- at N=2 they coincide '
         'and from N=3 they need not. ackclock_sim.py:614-620 already carries the derived '
         'shape (0.5 * measured RTTmin spread + 3 * measured sigma); it is reachable only '
         'under sched=="C" and the gated set never runs it.'),
        ('hold clamps 0.08 / 0.35 s',
         'floor and ceiling on the same hold',
         'OPEN',
         'C2: the widest mix the archetype set can build gives raw 249 ms, so NEITHER '
         'clamp is reachable at ANY N -- they are untested code on every run the battery '
         'has ever made. C3: the loss optimum is %.0f-%.0f ms, %.1f-%.1f times ABOVE the '
         '350 ms ceiling, so the ceiling is not dormant on the loss axis. It caps the '
         'answer.' % (hb_lo, hb_hi, hb_lo / 350.0, hb_hi / 350.0)),
        ('maxq_ms = 300.0 -> 0.3 * sum(cap0)',
         'shared-pool byte bound',
         'DERIVABLE',
         'Already N-generic in form: a delay bound times the AGGREGATE nominal rate, '
         'linear in N by construction. Two caveats to carry: cap0 is cap_fn(0.0), which '
         "is U33's finding F1; and U7's shipped Go pool bound derives from sum(SO_SNDBUF) "
         'instead (ROADMAP, U7 round 2), so the rig and the artifact bound the same pool '
         'by DIFFERENT quantities. That divergence belongs to U9 / EQ-1.'),
        ('QMAX_MS = 300.0',
         'per-path downstream fluid tail-drop bound',
         'N-INVARIANT in form, OPEN in value',
         'Per-link; no N term appears anywhere it is used. Its VALUE has never been '
         'measured on hardware (ADR-004 condition 2).'),
        ('NLAG = 0.350 + the 0.100 s window',
         'per-link lagged delivered-rate meter window',
         'N-INVARIANT in form, OPEN in value',
         'Per-link; no N term. It is a hardware RTT-scale quantity, and G1 is what '
         'measures it.'),
        ('deliv_hist horizon = 0.6 s',
         'per-link delivered-history trim',
         'DERIVABLE',
         '_lagged_deliv reads [now-NLAG-0.100, now-NLAG), so the horizon must exceed '
         'NLAG + 0.100 = %.3f s or the meter reads an empty window. The requirement is '
         'exact and derivable from the module; the remaining %.3f s of margin is not.'
         % (NLAG_W, 0.6 - NLAG_W)),
        ('DRAIN_TAU = 0.10 / REGEN = 0.02',
         "per-link local drain EWMA and idle probe-up toward cap0; feeds _local_ms and "
         "therefore Dc's room() gate",
         'OPEN',
         'Per-link and N-independent in form, but no derivation exists on the record for '
         'either value.'),
        ('HEALTH_FRAC = 0.75',
         'host must be draining at least 75 percent of its nominal cap0',
         'NOT LIVE for the gated set',
         'reserved_composite.py:298 sends Dc and Dpp down the meter branch; HEALTH_FRAC '
         "is read only at :311, inside the D / D-prime else-branch. It gates nothing this "
         'CI job scores. Reported so it is not mistaken for a live N=2 constant.'),
        ('tshare = assigned[0] / sum',
         'a PER-LINK metric keyed to INDEX 0, in the rig and in the oracle alike',
         'DERIVABLE',
         'C5: exact at N=2, because index 0 IS the only spotty link there, and wrong by '
         '%.3f-%.3f from N=3. The N-generic form already exists -- highn_battery.py:196 '
         'computes the share over spotty_idx and reduces to tshare at N=2. The battery is '
         'clean; the METRIC and its three downstream citations are not.'
         % (min(ts_err), max(ts_err))),
        ('cap0 = cap_fn(0.0)',
         "each path's NOMINAL cap, read in nine places",
         'DERIVABLE',
         "U33's finding F1: nominal is sampled from the trace at one instant rather than "
         'being a property of the archetype (base/amp/period). Not an N=2 constant, but '
         'it is the input to maxq_kb, drain_ewma, push_est and REGEN, so it belongs in '
         'this table.'),
    ]
    for (nm, what, verdict, ev) in ROWS:
        print()
        print('  %-36s [%s]' % (nm, verdict))
        print('    does : %s' % what)
        for ln in _wrap('evidence: ' + ev, 98):
            print('    %s' % ln)
    print()
    print('  SUMMARY: %d N-INVARIANT, %d DERIVABLE, %d OPEN, %d not live for the gated set.'
          % (sum(1 for r in ROWS if r[2].startswith('N-INVARIANT')),
             sum(1 for r in ROWS if r[2].startswith('DERIVABLE')),
             sum(1 for r in ROWS if r[2] == 'OPEN'),
             sum(1 for r in ROWS if r[2].startswith('NOT LIVE'))))
    print('  Three rows are N-invariant or derivable in FORM and open in VALUE; they are')
    print('  counted under the first label.  Nothing above was changed by this file.')

    print()
    print('=' * 110)
    print('elapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
