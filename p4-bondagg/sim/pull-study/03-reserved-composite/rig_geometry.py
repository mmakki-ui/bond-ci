#!/usr/bin/env python3
# =============================================================================
# rig_geometry.py -- U10 REVIEW ITEM 3.  THE ABSOLUTE-LOSS BASIS.
#
# WHAT ITEM 3 SAYS (docs/ROADMAP.md, EPIC 1, U10 row; ADR-004 "Consequences")
#   "absolute loss resting on 2-8 discrete stalls at T=9 s" ... "the geometry
#    axis is sampled by PHASE ONLY."
#
# U33 closed the PHASE half: `rig_checks.py::phase_drops` rotates each source's
# canonical schedule cyclically, and measured a geometry spread of 1.99-2.74 pt
# against a jitter spread of 0.14-0.18 pt (11-17x).  A cyclic rotation is ONE
# one-parameter family per source.  It cannot reach:
#   * the COUNT     -- how the same outage time is split into events.  Canonical
#                      is 3 / 2 / 3 events, hand-chosen.
#   * the POSITION  -- where events sit RELATIVE TO EACH OTHER inside a source
#                      (rotation carries the pattern rigidly, so cellA's 2.5 s
#                      inter-stall gaps survive every rotation) and relative to
#                      the OTHER sources' events.
# This file samples both, then answers what item 3 asks: how much of the measured
# loss is geometry and how much is the scheduler, and what happens to the loss
# BARS when the hand placement is removed.
#
# ---------------------------------------------------------------------------
# WHAT IS HELD FIXED, AND WHY IT IS NOT A CHOICE
# ---------------------------------------------------------------------------
# Per source the TOTAL OUTAGE TIME is preserved exactly.  That is the physical
# property of a tether ("this link is down 13.3% of the window"); how many events
# it is split into and where they land is the hand-placed part.  Holding the
# physical quantity and randomising the arrangement is the split that isolates
# geometry from capacity -- and it is not perfectly clean, so G1 MEASURES the
# residual capacity confound instead of assuming it away.
#
# CONSTRAINTS ON THE SAMPLE SPACE, each DERIVED, none chosen:
#   (a) no interval may contain t = 0.  Finding F1 (rig_checks.py header): the
#       rig reads a path's NOMINAL cap as cap_fn(0.0) in nine places, so a stall
#       covering t=0 does not add an outage, it makes the path nominally dead.
#       Real geometry the rig cannot represent -> NAMED NON-COVERAGE, not a drop.
#   (b) no two intervals of one source may touch or overlap.  Two abutting
#       intervals ARE one longer interval, so an overlap silently changes the
#       count and can change the total duration -- the two controlled quantities.
#   (c) every gap, including the leading and trailing one, is at least DT =
#       nsched_model.DT (10 ms), the rig's own tick.  A gap below one tick is not
#       representable and an event below one tick never opens.  Same reason the
#       count ceiling is floor(D / DT).
#   (d) given (a)-(c) the draw is UNIFORM over the admissible arrangements: gaps
#       are a uniform point of {g_0..g_k >= DT, sum = T - D}.  Uniform is the
#       max-entropy choice under no information, and nothing here measures the
#       true arrangement distribution.  That is an OPEN QUESTION, reported in the
#       verdict: only hardware traces can supply the real one.  G3 exists so the
#       COUNT axis is read as a SURFACE rather than marginalised under this prior.
#
# ---------------------------------------------------------------------------
# THE PROBES
# ---------------------------------------------------------------------------
# G0  VALIDATE THE SAMPLER BEFORE ANY NUMBER IS SCORED.  Count, total duration,
#     in-window, no-interval-over-t=0, no-overlap-or-touch, cap_fn(0.0) ==
#     nominal, determinism -- on every draw.  Plus THREE NEGATIVE CONTROLS, one
#     per property, each of which MUST fail the validator.  A validator that
#     cannot fail is theatre (rig_checks.py, PROBE 2.0v).
#
# G1  THE CAPACITY CONFOUND, MEASURED.  Holding total outage time does NOT hold
#     available capacity: cap_fn is a sinusoid outside the stalls, so WHERE a
#     stall lands decides how much of the sinusoid it removes.  G1 integrates the
#     aggregate cap over the scored window for every geometry, so the loss spread
#     in G2 is read against a capacity spread rather than attributed wholly to
#     arrangement.
#
# G2  THE DECOMPOSITION.  At fixed (geometry, jitter seed):
#         loss(Dc)  =  loss(oracle)                +  (loss(Dc) - loss(oracle))
#                      ^ the REFERENCE                ^ the RESIDUAL
#     REFERENCE = what an admission policy with perfect knowledge of the true
#     instantaneous stage-2 cap loses on THIS geometry.  It is the physics-derived
#     admission reference B3(loss) is scored against -- it is NOT a lower bound,
#     and Dc comes in UNDER it on the canonical geometry, which is exactly what
#     B3 asserts.  RESIDUAL is therefore signed, and negative is good.
#     Both terms get their spread over geometries and over jitter seeds, plus a
#     one-way random-effects split of each term's variance.
#     `late` (reorder-ring late-discard) rides along: U11 found 78-96% of Dc's
#     loss at 0.65 is late-discard and 95-97% of the oracle's residual is too, so
#     most of the reference term is itself hold geometry.
#
# G3  THE COUNT AXIS AS A SURFACE.  Same total outage time split into k events,
#     k swept over the derived representable range.  No prior over k is needed.
#
# G4  THE BARS, RE-DERIVED ON THE ENSEMBLE.  Three loss bars, each re-scored per
#     geometry and reported as a PASS RATE next to its canonical verdict and the
#     published record:
#       B3(loss)  paired `med(Dc - oracle) <= 0`.  GATED as PAIRED.
#       B2        `Dc loss <= ewma loss + 0.5`.    GATED as PAIRED.
#       B5(loss)  `adding a source reduces Dc loss`.  GATED as RELATIVE.
#     (.github/scripts/rig_paired_gate.py:116-117.)
#
# REPRODUCTION.  On the CANONICAL geometry at SEEDS=24 this probe must reproduce
# highn_u11u12.txt digit-for-digit; the checks are printed inline.  Without that
# an ensemble number is a number from some other rig.
#
# NO BAR IS WEAKENED HERE AND NO SCHEDULER IS TUNED.  This file adds no bar to
# the battery and edits no other file.  Every scheduler, archetype, rig builder
# and constant is imported unmodified.
#
# NO NEW CONSTANT: the outage total, the count ceiling, the minimum gap and the
# admissible measure are derived from the canonical schedule and nsched_model.DT.
# The 1e-9 / 1e-12 tolerances are float-comparison guards.
#
# Env: GEOMS(32) GSEEDS(3) CSEEDS(24) WORKERS(14) T(9.0) RIG(mid)
#      KGEOMS(10) KSEEDS(3)          -- G3's smaller grid
# Run: python rig_geometry.py > rig_geometry.txt 2> rig_geometry.err
# =============================================================================
import importlib.util as _ilu
import math
import os
import random
import sys
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))


def _rig_pin():
    """Load ../rig_pin.py BY PATH (U35).  Never through sys.path -- sys.path is
    the mechanism U35 exists to remove from the decision."""
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
#: the rig itself, by path -- it pins its own oracle and physics at import
RC = rig_pin.load_pinned('reserved_composite', os.path.join(HERE, 'reserved_composite.py'),
                         why='the ADR-004 gated oracle rig')
A = RC.A
DT = RC.DT

GEOMS   = int(os.environ.get('GEOMS', '32'))
GSEEDS  = int(os.environ.get('GSEEDS', '3'))
CSEEDS  = int(os.environ.get('CSEEDS', '24'))
KGEOMS  = int(os.environ.get('KGEOMS', '10'))
KSEEDS  = int(os.environ.get('KSEEDS', '3'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T       = float(os.environ.get('T', '9.0'))
RIG     = os.environ.get('RIG', 'mid')
WARM    = 1.0            # SimD/Sim scoring warmup (reserved_composite.py:227)

BUILD = {'cellA': RC.cellA, 'cellB': RC.cellB, 'cellC': RC.cellC}
CANON = {'cellA': RC.DROPS_A, 'cellB': RC.DROPS_B, 'cellC': RC.DROPS_C}
CORR = {'cellA*': (RC.cellA, RC.DROPS_CORR), 'cellB*': (RC.cellB, RC.DROPS_CORR),
        'cellC*': (RC.cellC, RC.DROPS_CORR)}
#: N5-corr's defining property is that its three tethers stall TOGETHER.  Drawing
#: them independently would silently delete the scenario, so all three share one
#: RNG key -- and because DROPS_CORR is the same schedule for all three, they draw
#: the SAME arrangement.  Verified in G0 by an explicit correlation check.
SEEDKEY = {'cellA*': 'corr', 'cellB*': 'corr', 'cellC*': 'corr'}
STEADY = {'wifi': RC.wifi, 'eth': RC.eth}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def late_lost(deliv, loss_pct):
    """Frames LOST, reconstructed from what finalize() returns.
    loss = 100*(offered-deliv)/offered  ->  lost = deliv*loss/(100-loss)."""
    return deliv * loss_pct / max(1e-9, 100.0 - loss_pct)


def anova(groups):
    """One-way random-effects decomposition.  groups: one list per geometry,
    each holding that geometry's per-jitter-seed values.  Standard estimator:
    sigma2_within = MSW, sigma2_between = max(0, (MSB - MSW)/S).  No constant."""
    groups = [g for g in groups if g]
    K = len(groups)
    if K < 2:
        return 0.0, 0.0, 0.0
    S = min(len(g) for g in groups)
    groups = [g[:S] for g in groups]
    gm = [mean(g) for g in groups]
    gbar = mean(gm)
    ssb = S * sum((m - gbar) ** 2 for m in gm)
    ssw = sum(sum((x - m) ** 2 for x in g) for g, m in zip(groups, gm))
    msb = ssb / (K - 1)
    msw = ssw / (K * (S - 1)) if S > 1 else 0.0
    s2b = max(0.0, (msb - msw) / S)
    s2w = msw
    tot = s2b + s2w
    return s2b, s2w, (s2b / tot if tot > 0 else 0.0)


# ---------------------------------------------------------------------------
# G0 -- THE SAMPLER
# ---------------------------------------------------------------------------
def canon_of(name):
    """The canonical dropout schedule of a spotty archetype name."""
    return CORR[name][1] if name in CORR else CANON[name]


def builder_of(name):
    return CORR[name][0] if name in CORR else BUILD[name]


def outage_total(name):
    """Total outage time of the CANONICAL schedule.  DERIVED from
    reserved_composite.DROPS_*, not chosen."""
    return sum(b - a for (a, b) in canon_of(name))


def count_ceiling(name, tt):
    """Largest event count the rig can represent for this source's outage total:
    every event at least one tick long, and k+1 gaps of at least one tick fitting
    in the rest of the window.  Both limbs derived from DT."""
    D = outage_total(name)
    by_dur = int(math.floor(D / DT + 1e-9))
    by_gap = int(math.floor((tt - D) / DT + 1e-9)) - 1
    return max(1, min(by_dur, by_gap))


def _simplex(rng, n, total, floor_each):
    """Uniform point of {x_1..x_n : x_i >= floor_each, sum x_i = total}.
    Uniform-spacings construction on the reduced simplex: exact, no rejection."""
    free = total - n * floor_each
    if free < -1e-12:
        raise ValueError('infeasible simplex: n=%d floor=%g total=%g' % (n, floor_each, total))
    free = max(0.0, free)
    cuts = sorted(rng.random() for _ in range(n - 1))
    parts = []
    prev = 0.0
    for c in cuts:
        parts.append((c - prev) * free)
        prev = c
    parts.append((1.0 - prev) * free)
    return [floor_each + p for p in parts]


def geom_drops(name, gseed, tt, k=None, equal_dur=False):
    """Draw ONE stall arrangement for source `name`, preserving the canonical
    TOTAL outage time exactly.  `k` = event count (default: canonical).
    `equal_dur` splits the outage into k equal events (G3's count axis, where
    count alone must move); otherwise durations are a uniform simplex draw with a
    one-tick floor.  Placement: k+1 gaps, uniform simplex, one-tick floor -- so
    the leading gap is > 0 (constraint (a)), no two events touch (b), and
    everything lies inside [0, tt) (c)."""
    iv = canon_of(name)
    D = sum(b - a for (a, b) in iv)
    if k is None:
        k = len(iv)
    k = max(1, min(k, count_ceiling(name, tt)))
    rng = random.Random('geom|%s|%d|%d|%d'
                        % (SEEDKEY.get(name, name), k, gseed, int(equal_dur)))
    durs = [D / k] * k if equal_dur else _simplex(rng, k, D, DT)
    gaps = _simplex(rng, k + 1, tt - D, DT)
    out = []
    x = gaps[0]
    for i in range(k):
        out.append((x, x + durs[i]))
        x = x + durs[i] + gaps[i + 1]
    return out


# --- negative controls: each violates exactly one property and MUST be caught --
def nc_overlap(name, gseed, tt, k=None, equal_dur=False):
    """NEGATIVE CONTROL 1 -- starts one tick apart, so events certainly overlap.
    MUST fail the overlap check."""
    rng = random.Random('nc1|%s|%d' % (SEEDKEY.get(name, name), gseed))
    iv = canon_of(name)
    D = sum(b - a for (a, b) in iv)
    durs = [b - a for (a, b) in iv]
    base = rng.uniform(DT, max(DT, tt - D - DT))
    return [(base + i * DT, base + i * DT + d) for i, d in enumerate(durs)]


def nc_zero(name, gseed, tt, k=None, equal_dur=False):
    """NEGATIVE CONTROL 2 -- one event anchored at t=0.  MUST fail the t=0 check
    AND the cap_fn(0.0)==nominal check (finding F1)."""
    ok = geom_drops(name, gseed, tt)
    d = ok[0][1] - ok[0][0]
    return [(0.0, d)] + ok[1:]


def nc_dur(name, gseed, tt, k=None, equal_dur=False):
    """NEGATIVE CONTROL 3 -- one event stretched by a tick.  MUST fail the total
    duration check while passing count, window, t=0 and overlap."""
    ok = geom_drops(name, gseed, tt)
    (a, b) = ok[-1]
    return ok[:-1] + [(a, min(tt, b + DT))]


SAMPLERS = {'geom': geom_drops, 'nc_overlap': nc_overlap, 'nc_zero': nc_zero,
            'nc_dur': nc_dur}


# ---------------------------------------------------------------------------
# recipes -- a picklable description of one rig
# ---------------------------------------------------------------------------
def recipe(names, gseed, tt, phased=True, k=None, equal_dur=False, sampler='geom'):
    fn = SAMPLERS[sampler]
    out = []
    for nm in names:
        if nm in STEADY:
            out.append((nm, None))
        elif phased:
            out.append((nm, tuple(fn(nm, gseed, tt, k=k, equal_dur=equal_dur))))
        else:
            out.append((nm, tuple(canon_of(nm))))
    return tuple(out)


def archs_of(rec):
    out = []
    for (nm, drops) in rec:
        if nm in STEADY:
            out.append(STEADY[nm]())
        else:
            out.append(builder_of(nm)([tuple(x) for x in drops]))
    return out


def cap_integral(rec):
    """Aggregate deliverable capacity over the SCORED window [WARM, T), kb, and
    the same mix with no stalls.  Sampled at the rig's own tick."""
    archs = archs_of(rec)
    defs = RC.build_rig(archs, bottleneck=RIG)
    clean = RC.build_rig([dict(a, dropouts=()) for a in archs], bottleneck=RIG)
    n = int(round((T - WARM) / DT))
    got = ref = 0.0
    for j in range(n):
        t = WARM + j * DT
        got += sum(d['cap_fn'](t) for d in defs) * DT
        ref += sum(d['cap_fn'](t) for d in clean) * DT
    return got, ref


def validate(rec, tt, k=None):
    """MEASURE the six properties on one recipe.  Every entry must be 0."""
    bad = dict(count=0, dur=0, window=0, zero=0, overlap=0, cap0=0)
    archs = archs_of(rec)
    for (nm, drops) in rec:
        if nm in STEADY:
            continue
        iv = sorted(tuple(x) for x in drops)
        can = canon_of(nm)
        want = len(can) if k is None else k
        if len(iv) != want:
            bad['count'] += 1
        if abs(sum(b - a for a, b in iv) - sum(b - a for a, b in can)) > 1e-9:
            bad['dur'] += 1
        for (a, b) in iv:
            if a < 0.0 or b > tt + 1e-9 or b <= a:
                bad['window'] += 1
            if a <= 0.0 < b:
                bad['zero'] += 1
        for i in range(len(iv) - 1):
            if iv[i + 1][0] <= iv[i][1] + 1e-12:
                bad['overlap'] += 1
    nom = [d['cap_fn'](0.0) for d in
           RC.build_rig([dict(a, dropouts=()) for a in archs], bottleneck=RIG)]
    got = [d['cap_fn'](0.0) for d in RC.build_rig(archs, bottleneck=RIG)]
    bad['cap0'] = sum(1 for (x, y) in zip(nom, got) if abs(x - y) > 1e-9)
    return bad


# ---------------------------------------------------------------------------
# scenarios -- membership identical to highn_battery.SCENARIOS()
# ---------------------------------------------------------------------------
MIXES = [
    ('N2-het', ['cellA', 'eth']),
    ('N3-het', ['cellA', 'cellB', 'eth']),
    ('N4-het', ['cellA', 'cellB', 'wifi', 'eth']),
    ('N5-het', ['cellA', 'cellB', 'cellC', 'wifi', 'eth']),
    ('N4-teth', ['cellA', 'cellB', 'cellC', 'eth']),
    ('N5-corr', ['cellA*', 'cellB*', 'cellC*', 'wifi', 'eth']),
]
MIX = dict(MIXES)
CHAIN = MIXES[:4]
DECOMP = 'N4-teth'          # the cell U11 and rig_checks both used

#: B2's cells: its four recorded FAILS plus one thin PASS, so the ensemble is
#: asked about both verdicts.  highn_u11u12.txt lines 75, 77, 86, 99, 110.
B2_CELLS = [('N2-het', 0.85), ('N2-het', 0.95), ('N3-het', 0.85),
            ('N4-het', 0.95), ('N5-het', 0.95)]

#: THE PUBLISHED RECORD, canonical geometry, SEEDS=24, from highn_u11u12.txt.
#: Reproducing it is what makes an ensemble number below a number about THIS rig.
RECORD_B2 = {('N2-het', 0.85): +0.845, ('N2-het', 0.95): +0.655,
             ('N3-het', 0.85): +0.515, ('N4-het', 0.95): +0.690,
             ('N5-het', 0.95): +0.286}                       # lines 75,77,86,99,110
RECORD_B3 = {'N2-het': -2.134, 'N3-het': -1.153, 'N4-het': -1.049,
             'N5-het': -2.044, 'N4-teth': -0.671, 'N5-corr': -1.273}  # lines 72-127
RECORD_B5 = {'N2-het': 50.21, 'N3-het': 41.42, 'N4-het': 18.17,
             'N5-het': 11.86}                                # lines 179-182
B3_LOAD = 0.65


# ---------------------------------------------------------------------------
# one worker, one scored run
# ---------------------------------------------------------------------------
def make_sim(defs, ofn, tt, seed, sched):
    if sched in ('Dc', 'Dpp', 'D', 'redundant'):
        return RC.SimD(defs, ofn, tt, seed, sched=sched)
    return A.Sim(defs, ofn, tt, seed, sched=sched, mirror=False)


def w_run(task):
    (key, rec, load, offer_abs, sched, seed) = task
    archs = archs_of(rec)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    off = offer_abs if offer_abs is not None else load * nom
    m = make_sim(defs, (lambda t, _o=off: _o), T, seed, sched).run()
    return (key, sched, seed, {'gp': m['gp'], 'loss': m['loss'], 'late': m['late'],
                               'deliv': m['deliv'], 'p95': m['p95']})


# =============================================================================
def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    t0 = time.time()
    H = '#' * 112
    print(H)
    print('# rig_geometry.py -- U10 ITEM 3: the basis of ABSOLUTE loss')
    print('# geometries=%d  jitter seeds/geometry=%d  canonical seeds=%d  T=%.1fs  rig=%s'
          % (GEOMS, GSEEDS, CSEEDS, T, RIG))
    print(H)
    print(RC.identity_banner())
    print(H)
    sys.stdout.flush()

    # ================= G0  sampler validation ==============================
    print()
    print('=' * 112)
    print('G0  SAMPLER VALIDATION -- every property MEASURED on every draw, plus three')
    print('    negative controls that must each FAIL the property they violate')
    print('=' * 112)
    print('  canonical schedules, and the sample space they define:')
    for nm in ('cellA', 'cellB', 'cellC', 'cellA*'):
        D = outage_total(nm)
        print('    %-7s canonical k=%d  outage=%.3fs (%.1f%% of T)  count ceiling=%d'
              % (nm, len(canon_of(nm)), D, 100.0 * D / T, count_ceiling(nm, T)))
    spotty_all = ['cellA', 'cellB', 'cellC', 'cellA*', 'cellB*', 'cellC*']
    names_all = spotty_all + ['wifi', 'eth']
    tot = dict(count=0, dur=0, window=0, zero=0, overlap=0, cap0=0)
    for g in range(GEOMS):
        b = validate(recipe(names_all, g, T), T)
        for k_ in tot:
            tot[k_] += b[k_]
    g0_ok = all(v == 0 for v in tot.values())
    print('  corrected sampler, %d geometries x %d spotty sources:  %s -> %s'
          % (GEOMS, len(spotty_all), '  '.join('%s=%d' % (k_, tot[k_]) for k_ in sorted(tot)),
             'ALL PROPERTIES HOLD' if g0_ok else 'VIOLATIONS -- EVERY NUMBER BELOW IS VOID'))
    det = all(recipe(names_all, g, T) == recipe(names_all, g, T) for g in range(GEOMS))
    print('  determinism (same geometry seed -> identical schedule): %s'
          % ('PASS' if det else 'FAIL'))
    NC_MUST = {'nc_overlap': 'overlap', 'nc_zero': 'zero', 'nc_dur': 'dur'}
    nc_ok = True
    for s_, prop in sorted(NC_MUST.items()):
        agg_ = dict(count=0, dur=0, window=0, zero=0, overlap=0, cap0=0)
        for g in range(GEOMS):
            b = validate(recipe(names_all, g, T, sampler=s_), T)
            for k_ in agg_:
                agg_[k_] += b[k_]
        fired = agg_[prop] > 0
        nc_ok = nc_ok and fired
        print('  NEGATIVE CONTROL %-11s must fail %-8s -> %-6s (%s)'
              % (s_, prop, 'FIRED' if fired else 'SILENT',
                 '  '.join('%s=%d' % (k_, agg_[k_]) for k_ in sorted(agg_))))
    print('  -> negative controls: %s'
          % ('ALL FIRED (the validator can fail)' if nc_ok
             else 'A CONTROL WAS SILENT -- G0 IS THEATRE'))
    # N5-corr must STAY correlated, and the het mixes must stay independent
    corr_same = indep_same = 0
    for g in range(GEOMS):
        c = [geom_drops(n_, g, T) for n_ in ('cellA*', 'cellB*', 'cellC*')]
        h = [geom_drops(n_, g, T) for n_ in ('cellA', 'cellB', 'cellC')]
        corr_same += 1 if (c[0] == c[1] == c[2]) else 0
        indep_same += 1 if (h[0] == h[1] or h[1] == h[2] or h[0] == h[2]) else 0
    print("  CORRELATION PRESERVED: N5-corr's three tethers draw the SAME arrangement on")
    print('    %d/%d geometries (must be %d -- drawing them independently would delete the'
          % (corr_same, GEOMS, GEOMS))
    print('    scenario); the het mixes coincide on %d/%d (must be 0).' % (indep_same, GEOMS))
    corr_ok = (corr_same == GEOMS and indep_same == 0)
    sys.stdout.flush()

    # ================= build every recipe ONCE ==============================
    #   key -> (recipe, load, absolute offer or None)
    cells = {}
    for (lab, names) in MIXES:
        cells[(lab, 'canon')] = recipe(names, 0, T, phased=False)
        for g in range(GEOMS):
            cells[(lab, g)] = recipe(names, g, T)
    nom5 = sum(a['base'] for a in archs_of(cells[('N5-het', 'canon')]))
    B5_OFFER = 0.95 * nom5

    plan = {}

    def want(lab, gk, load, offer, sched, nseeds):
        rec = cells[(lab, gk)]
        for sd in range(nseeds):
            plan[((lab, gk, load, offer), sched, sd)] = (rec, load, offer)

    for (lab, names) in MIXES:                       # B3 + G2, load 0.65
        for sch in ('Dc', 'oracle'):
            want(lab, 'canon', B3_LOAD, None, sch, CSEEDS)
            for g in range(GEOMS):
                want(lab, g, B3_LOAD, None, sch, GSEEDS)
    for sch in ('ewma', 'pull'):                     # G2's extra references
        want(DECOMP, 'canon', B3_LOAD, None, sch, CSEEDS)
        for g in range(GEOMS):
            want(DECOMP, g, B3_LOAD, None, sch, GSEEDS)
    for (lab, load) in B2_CELLS:                     # B2
        for sch in ('Dc', 'ewma'):
            want(lab, 'canon', load, None, sch, CSEEDS)
            for g in range(GEOMS):
                want(lab, g, load, None, sch, GSEEDS)
    for (lab, names) in CHAIN:                       # B5
        want(lab, 'canon', None, B5_OFFER, 'Dc', CSEEDS)
        for g in range(GEOMS):
            want(lab, g, None, B5_OFFER, 'Dc', GSEEDS)

    # G3's count-axis recipes
    kmax = min(count_ceiling(n_, T) for n_ in MIX[DECOMP] if n_ not in STEADY)
    KS = [k for k in (1, 2, 3, 4, 6, 9, 12, 18, 24, 36, 54, 80) if k <= kmax]
    krecs = {}
    for k in KS:
        for g in range(KGEOMS):
            rec = recipe(MIX[DECOMP], 1000 + g, T, k=k, equal_dur=True)
            krecs[(k, g)] = rec
            for sch in ('Dc', 'oracle'):
                for sd in range(KSEEDS):
                    plan[(('K', k, g), sch, sd)] = (rec, B3_LOAD, None)

    tasks = [(key, rec, load, offer, sch, sd)
             for ((key, sch, sd), (rec, load, offer)) in plan.items()]
    print()
    print('  total scored runs: %d' % len(tasks), file=sys.stderr)
    print('  total scored runs: %d  (deduplicated: every cell runs once)' % len(tasks))
    sys.stdout.flush()
    R = {}
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (key, sch, sd, m) in ex.map(w_run, tasks, chunksize=4):
            R.setdefault(key, {}).setdefault(sch, {})[sd] = m
            done += 1
            if done % 500 == 0:
                print('  ..%d/%d (%.0fs)' % (done, len(tasks), time.time() - t0),
                      file=sys.stderr)

    def ser(key, sch, field):
        d = R[key][sch]
        return [d[sd][field] for sd in sorted(d)]

    def K3(lab, gk, load=B3_LOAD, offer=None):
        return (lab, gk, load, offer)

    # ================= G1  capacity confound ================================
    print()
    print('=' * 112)
    print('G1  THE CAPACITY CONFOUND.  Total outage time is held EXACTLY; available capacity')
    print('    is NOT, because cap_fn is a sinusoid outside the stalls.  Integral of')
    print('    aggregate cap over the scored window [%.1f, %.1f)s, as a %% of the same mix'
          % (WARM, T))
    print('    with no stalls at all.')
    print('=' * 112)
    print('  %-9s %9s %10s %10s %10s %10s %10s'
          % ('mix', 'canon%', 'geom min%', 'geom med%', 'geom max%', 'spread pt',
             'canon rank'))
    capfrac = {}
    for (lab, names) in MIXES:
        cg, cr = cap_integral(cells[(lab, 'canon')])
        cf = 100.0 * cg / cr
        vals = []
        for g in range(GEOMS):
            gg, gr = cap_integral(cells[(lab, g)])
            vals.append(100.0 * gg / gr)
        capfrac[lab] = vals
        print('  %-9s %9.3f %10.3f %10.3f %10.3f %10.3f %7d/%d'
              % (lab, cf, min(vals), med(vals), max(vals), max(vals) - min(vals),
                 sum(1 for v in vals if v < cf), len(vals)))
    print('  READ THIS FIRST: the capacity spread bounds how much of the loss spread below')
    print('  can be blamed on "the geometry removed more capacity" rather than on "the')
    print('  geometry arranged the same outage more awkwardly".  G2 regresses the two.')
    sys.stdout.flush()

    # ================= G2  decomposition ====================================
    print()
    print('=' * 112)
    print('G2  DECOMPOSITION -- loss(Dc) = loss(oracle) + (loss(Dc) - loss(oracle))')
    print('    REFERENCE = what an admission policy with PERFECT knowledge of the true')
    print('                instantaneous stage-2 cap loses on THIS geometry.  It is the')
    print('                bar B3(loss) scores against.  It is NOT a lower bound: Dc comes')
    print('                in UNDER it, which is what B3 asserts, so the RESIDUAL is signed')
    print('                and negative is good.')
    print('    cell: %s @ %.2f   %d geometries x %d jitter seeds; canonical arm %d seeds'
          % (DECOMP, B3_LOAD, GEOMS, GSEEDS, CSEEDS))
    print('=' * 112)
    scheds = ['Dc', 'oracle', 'ewma', 'pull']
    print('  --- canonical geometry (the basis every published number rests on) ---')
    for sch in scheds:
        key = K3(DECOMP, 'canon')
        ls = ser(key, sch, 'loss'); la = ser(key, sch, 'late'); dl = ser(key, sch, 'deliv')
        print('    %-7s loss med=%6.3f%%  min=%6.3f max=%6.3f  JITTER SPREAD=%.3f pt   '
              'late-discard share of lost med=%5.1f%%'
              % (sch, med(ls), min(ls), max(ls), max(ls) - min(ls),
                 med([100.0 * a / max(1e-9, late_lost(d, l)) for a, d, l in zip(la, dl, ls)])))
    c_dc = med(ser(K3(DECOMP, 'canon'), 'Dc', 'loss'))
    c_or = med(ser(K3(DECOMP, 'canon'), 'oracle', 'loss'))
    print('    canonical: reference %.3f pt, Dc %.3f pt, residual %+.3f pt (Dc beats the'
          % (c_or, c_dc, c_dc - c_or))
    print('    reference by %.3f pt -- record says %+.3f, see G4)' % (c_or - c_dc,
                                                                      RECORD_B3[DECOMP]))
    print()
    print('  --- geometry ensemble ---')
    gk = [K3(DECOMP, g) for g in range(GEOMS)]
    for sch in scheds:
        per = [ser(k_, sch, 'loss') for k_ in gk]
        gm = [mean(x) for x in per]
        s2b, s2w, fb = anova(per)
        print('    %-7s loss  per-geometry mean: med=%6.3f%% min=%6.3f max=%6.3f  '
              'GEOMETRY SPREAD=%.3f pt' % (sch, med(gm), min(gm), max(gm), max(gm) - min(gm)))
        print('            sd(between geometries)=%.4f pt   sd(within, jitter)=%.4f pt   '
              'variance BETWEEN=%.1f%%' % (math.sqrt(s2b), math.sqrt(s2w), 100.0 * fb))
    dc_g = [ser(k_, 'Dc', 'loss') for k_ in gk]
    or_g = [ser(k_, 'oracle', 'loss') for k_ in gk]
    rs_g = [[a - b for a, b in zip(x, y)] for x, y in zip(dc_g, or_g)]
    print()
    print('    THE DECOMPOSITION, paired at every (geometry, seed):')
    for tag, gr in (('Dc loss (total)', dc_g), ('reference loss(oracle)', or_g),
                    ('residual Dc - oracle', rs_g)):
        gm = [mean(x) for x in gr]
        s2b, s2w, fb = anova(gr)
        flat = [x for g_ in gr for x in g_]
        print('      %-24s mean=%+7.3f pt  per-geometry mean in [%+7.3f, %+7.3f] '
              'spread=%6.3f pt  var BETWEEN=%5.1f%%'
              % (tag, mean(flat), min(gm), max(gm), max(gm) - min(gm), 100.0 * fb))
    gm_dc = [mean(x) for x in dc_g]; gm_or = [mean(x) for x in or_g]
    gm_rs = [mean(x) for x in rs_g]
    j_dc = max(ser(K3(DECOMP, 'canon'), 'Dc', 'loss')) - min(ser(K3(DECOMP, 'canon'), 'Dc', 'loss'))
    print('      -> ABSOLUTE Dc loss moves %.3f pt across geometries and %.3f pt across the'
          % (max(gm_dc) - min(gm_dc), j_dc))
    print('         %d canonical jitter seeds: a geometry:jitter ratio of %.0fx.'
          % (CSEEDS, (max(gm_dc) - min(gm_dc)) / max(1e-9, j_dc)))
    print('      -> the REFERENCE moves only %.3f pt, so the two are NOT common-mode, and'
          % (max(gm_or) - min(gm_or)))
    print('         the PAIRED residual still moves %.3f pt -- %.0f%% of the total\'s'
          % (max(gm_rs) - min(gm_rs),
             100.0 * (max(gm_rs) - min(gm_rs)) / max(1e-9, max(gm_dc) - min(gm_dc))))
    print('         movement.  Pairing cancels PHYSICS error (ADR-004\'s argument); it does')
    print('         NOT cancel GEOMETRY unless both schedulers respond to it alike.')
    caps = capfrac[DECOMP]
    cm = mean(caps); dm = mean(gm_dc)
    sxy = sum((c - cm) * (d - dm) for c, d in zip(caps, gm_dc))
    sxx = sum((c - cm) ** 2 for c in caps)
    syy = sum((d - dm) ** 2 for d in gm_dc)
    r = sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 0.0
    print('      -> capacity confound: corr(available capacity %%, Dc loss) = %+.3f, '
          'r^2 = %.3f' % (r, r * r))
    print('         so %.0f%% of the between-geometry loss variance is capacity the'
          % (100.0 * r * r))
    print('         arrangement removed and %.0f%% is the ARRANGEMENT itself.'
          % (100.0 * (1 - r * r)))
    print()
    print('    U11 CROSS-CHECK -- share of LOST frames that are reorder-ring late-discards')
    print('    (U11 measured 78-96% for Dc and 95-97% for the oracle, canonical only):')
    for sch in ('Dc', 'oracle'):
        sh = []
        for g in range(GEOMS):
            d = R[K3(DECOMP, g)][sch]
            for sd in d:
                sh.append(100.0 * d[sd]['late'] / max(1e-9, late_lost(d[sd]['deliv'],
                                                                     d[sd]['loss'])))
        print('      %-7s ensemble late-share  min=%5.1f%%  med=%5.1f%%  max=%5.1f%%'
              % (sch, min(sh), med(sh), max(sh)))
    sys.stdout.flush()

    # ================= G3  count axis =======================================
    print()
    print('=' * 112)
    print('G3  THE COUNT AXIS.  Same source, same TOTAL outage time, split into k EQUAL')
    print('    events placed uniformly.  k swept over the derived representable range.')
    print('    Read as a SURFACE -- no prior over k is assumed, and none is needed.')
    print('    cell: %s @ %.2f   %d geometries x %d jitter seeds per k'
          % (DECOMP, B3_LOAD, KGEOMS, KSEEDS))
    print('=' * 112)
    kbad = dict(count=0, dur=0, window=0, zero=0, overlap=0, cap0=0)
    for (k, g), rec in krecs.items():
        b = validate(rec, T, k=k)
        for k_ in kbad:
            kbad[k_] += b[k_]
    print('  representable range for this mix: k in [1, %d]' % kmax)
    print('  G3 draw validation: %s -> %s'
          % ('  '.join('%s=%d' % (k_, kbad[k_]) for k_ in sorted(kbad)),
             'OK' if all(v == 0 for v in kbad.values()) else 'VOID'))
    print('  %5s %11s %11s %12s %10s %13s' % ('k', 'Dc loss%', 'oracle%', 'residual pt',
                                              'cap%', 'geom spread'))
    dk = []
    for k in KS:
        dcs = [mean(ser(('K', k, g), 'Dc', 'loss')) for g in range(KGEOMS)]
        ors = [mean(ser(('K', k, g), 'oracle', 'loss')) for g in range(KGEOMS)]
        cps = []
        for g in range(KGEOMS):
            gg, gr = cap_integral(krecs[(k, g)])
            cps.append(100.0 * gg / gr)
        dk.append(med(dcs))
        print('  %5d %11.3f %11.3f %12.3f %10.3f %13.3f'
              % (k, med(dcs), med(ors), med(dcs) - med(ors), med(cps), max(dcs) - min(dcs)))
    print('  -> Dc loss across the count axis: min=%.3f at k=%d, max=%.3f at k=%d, '
          'range=%.3f pt' % (min(dk), KS[dk.index(min(dk))], max(dk),
                            KS[dk.index(max(dk))], max(dk) - min(dk)))
    print('  -> the canonical counts are k=2 and k=3.  Where they sit on this axis is')
    print('     printed above, not argued.')
    sys.stdout.flush()

    # ================= G4  the bars =========================================
    print()
    print('=' * 112)
    print('G4  THE LOSS BARS, RE-SCORED PER GEOMETRY')
    print('=' * 112)
    print('  B3(loss)  `median over seeds of (Dc loss - oracle loss) <= 0`.  Gated as PAIRED')
    print('            (.github/scripts/rig_paired_gate.py:116).')
    print('  B2        `Dc loss <= ewma loss + 0.5`.  The comparison is paired; the 0.5 pt')
    print('            TOLERANCE is absolute.  Gated as PAIRED (same file:116).')
    print('  B5(loss)  `adding a source reduces Dc loss`, Dc at N vs Dc at N+1.  DIFFERENT')
    print('            RIGS -- nothing cancels, and the added source brings its own')
    print('            hand-placed schedule.  Gated as RELATIVE (same file:117).')
    print()

    # ---- B3 ----
    print('  --- B3(loss), all six battery mixes, load %.2f ---' % B3_LOAD)
    print('  %-9s %12s %9s %8s | %10s %10s %10s %9s %11s'
          % ('mix', 'canon paired', 'record', 'verdict', 'geom min', 'geom med',
             'geom max', 'spread', 'PASS rate'))
    b3_repro = True
    for (lab, names) in MIXES:
        d = R[K3(lab, 'canon')]
        cp = [d['Dc'][sd]['loss'] - d['oracle'][sd]['loss'] for sd in sorted(d['Dc'])]
        if CSEEDS == 24 and abs(med(cp) - RECORD_B3[lab]) > 0.001:
            b3_repro = False
        gmeds, np_ = [], 0
        for g in range(GEOMS):
            dg = R[K3(lab, g)]
            p = [dg['Dc'][sd]['loss'] - dg['oracle'][sd]['loss'] for sd in sorted(dg['Dc'])]
            gmeds.append(med(p))
            if med(p) <= 0.0:
                np_ += 1
        print('  %-9s %+12.3f %+9.3f %8s | %+10.3f %+10.3f %+10.3f %9.3f %7d/%d %s'
              % (lab, med(cp), RECORD_B3[lab], 'PASS' if med(cp) <= 0 else 'FAIL',
                 min(gmeds), med(gmeds), max(gmeds), max(gmeds) - min(gmeds), np_, GEOMS,
                 'geom-stable' if np_ in (0, GEOMS) else 'GEOMETRY-DEPENDENT'))
    print('  REPRODUCTION vs highn_u11u12.txt:72-127 (canonical, SEEDS=24): %s'
          % ('MATCH on all %d mixes' % len(MIXES) if b3_repro and CSEEDS == 24
             else ('MISMATCH -- this probe is not the rig the record was made on'
                   if CSEEDS == 24 else 'not attempted (CSEEDS=%d)' % CSEEDS)))

    # ---- B2 ----
    print()
    print('  --- B2, five cells (four recorded FAILs + one thin PASS) ---')
    print('  %-13s %12s %9s %8s | %10s %10s %10s %9s %11s'
          % ('cell', 'canon paired', 'record', 'verdict', 'geom min', 'geom med',
             'geom max', 'spread', 'PASS rate'))
    b2_repro = True
    for (lab, load) in B2_CELLS:
        key = (lab, 'canon', load, None)
        d = R[key]
        cp = [d['Dc'][sd]['loss'] - d['ewma'][sd]['loss'] for sd in sorted(d['Dc'])]
        rec_ = RECORD_B2[(lab, load)]
        if CSEEDS == 24 and abs(med(cp) - rec_) > 0.001:
            b2_repro = False
        gmeds, np_ = [], 0
        for g in range(GEOMS):
            dg = R[(lab, g, load, None)]
            p = [dg['Dc'][sd]['loss'] - dg['ewma'][sd]['loss'] for sd in sorted(dg['Dc'])]
            gmeds.append(med(p))
            if med(p) <= 0.5:
                np_ += 1
        print('  %-13s %+12.3f %+9.3f %8s | %+10.3f %+10.3f %+10.3f %9.3f %7d/%d %s'
              % ('%s@%.2f' % (lab, load), med(cp), rec_,
                 'PASS' if med(cp) <= 0.5 else 'FAIL', min(gmeds), med(gmeds), max(gmeds),
                 max(gmeds) - min(gmeds), np_, GEOMS,
                 'geom-stable' if np_ in (0, GEOMS) else 'GEOMETRY-DEPENDENT'))
    print('  REPRODUCTION vs highn_u11u12.txt:75-110 (canonical, SEEDS=24): %s'
          % ('MATCH on all %d cells' % len(B2_CELLS) if b2_repro and CSEEDS == 24
             else ('MISMATCH -- this probe is not the rig the record was made on'
                   if CSEEDS == 24 else 'not attempted (CSEEDS=%d)' % CSEEDS)))
    print('  The bar\'s tolerance is 0.5 pt.  Compare it to the spread column.')

    # ---- B5 ----
    print()
    print('  --- B5(loss), nested chain, one absolute offer = 0.95 x nominal(N5-het) = %.0f'
          % B5_OFFER)
    canon_chain = [med(ser((lab, 'canon', None, B5_OFFER), 'Dc', 'loss'))
                   for (lab, _) in CHAIN]
    print('  canonical chain Dc loss%%: %s'
          % '  '.join('%s=%.3f' % (CHAIN[i][0], canon_chain[i]) for i in range(len(CHAIN))))
    print('  record  (highn_u11u12.txt:179-182): %s -> %s'
          % ('  '.join('%s=%.2f' % (CHAIN[i][0], RECORD_B5[CHAIN[i][0]])
                       for i in range(len(CHAIN))),
             ('MATCH' if all(abs(canon_chain[i] - RECORD_B5[CHAIN[i][0]]) <= 0.005
                             for i in range(len(CHAIN))) else 'MISMATCH')
             if CSEEDS == 24 else 'not attempted (CSEEDS=%d)' % CSEEDS))
    csteps = [canon_chain[i + 1] - canon_chain[i] for i in range(len(CHAIN) - 1)]
    step_pass = [0] * (len(CHAIN) - 1)
    step_vals = [[] for _ in range(len(CHAIN) - 1)]
    allpass = 0
    for g in range(GEOMS):
        ch = [mean(ser((lab, g, None, B5_OFFER), 'Dc', 'loss')) for (lab, _) in CHAIN]
        steps = [ch[i + 1] - ch[i] for i in range(len(CHAIN) - 1)]
        for i, s in enumerate(steps):
            step_vals[i].append(s)
            if s < 0:
                step_pass[i] += 1
        if all(s < 0 for s in steps):
            allpass += 1
    print('  %-16s %11s %11s %11s %11s %12s' % ('step', 'canon', 'geom min', 'geom med',
                                                'geom max', 'PASS rate'))
    for i in range(len(CHAIN) - 1):
        print('  %-16s %+11.3f %+11.3f %+11.3f %+11.3f %8d/%d %s'
              % ('%s->%s' % (CHAIN[i][0], CHAIN[i + 1][0]), csteps[i], min(step_vals[i]),
                 med(step_vals[i]), max(step_vals[i]), step_pass[i], GEOMS,
                 'geom-stable' if step_pass[i] in (0, GEOMS) else 'GEOMETRY-DEPENDENT'))
    print('  whole chain monotone on %d/%d geometries (canonical: %s)'
          % (allpass, GEOMS, 'PASS' if all(s < 0 for s in csteps) else 'FAIL'))
    sys.stdout.flush()

    # ================= verdict ==============================================
    print()
    print('=' * 112)
    print('VERDICT')
    print('=' * 112)
    if not (g0_ok and det and nc_ok and corr_ok):
        print('  SAMPLER INVALID -- every number above is VOID.')
    print('  OPEN AND REPORTED, NOT GUESSED: nothing here measures the TRUE distribution of')
    print('  stall count, duration and position on a real tether.  The ensemble prior is')
    print('  uniform over what the rig can represent, which is a statement about the rig,')
    print('  not about the world.  Only ADR-004 condition 2 -- a hardware trace -- can')
    print('  supply the real one.  Until then the ensemble is a SENSITIVITY, and the honest')
    print('  reading of any absolute-loss number is "canonical value +- the geometry spread')
    print('  printed above", not the canonical value alone.')
    print('  Reported as measured.  No bar was widened, no scheduler was tuned, and no file')
    print('  outside this one was edited.')
    print('  elapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
