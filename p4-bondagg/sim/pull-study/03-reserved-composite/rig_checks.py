#!/usr/bin/env python3
# =============================================================================
# rig_checks.py -- U10 (docs/ROADMAP.md, EPIC 1) + U33 (Wave-3 landing).
# PROBE THE INSTRUMENT.
#
# U33 re-derives PROBE 2 with a CORRECT phase randomiser.  U10's shipped
# randomiser corrupted the rig on 8/24 seeds (ROADMAP blockers B1/B2/B3); every
# phase-random number below is regenerated and every one is MEASURED by the run
# that produced rig_checks.txt.  PROBE 1 is UNCHANGED -- it was sound, self-gated
# and positively controlled, and U33 did not touch it.
#
# ADR-004 promotes the two-stage pull-study rig to the GATED ORACLE for the
# datapath.  Fable's high-N review ("Question the measuring tool",
# docs/knowledge/design/research/fable-highn-review.md) names four things this
# rig could be SYSTEMATICALLY wrong about that reproducing the N=2 headline
# would NOT catch.  Two are cheap and decisive; this file measures those two.
# (Review items 3 "loss resting on 2-8 discrete stalls at T=9s" and 4 "per-link
# constants tuned at N=2" are NOT covered here -- they stay open under U10.)
#
# This is a MEASUREMENT, not a fix.  It adds NO bar, changes NO scenario, and
# does not touch reserved_composite.py / ackclock_sim.py / battery.py /
# highn_battery.py.  Every scheduler, archetype, rig builder and constant is
# imported from those files unmodified.
#
# ---------------------------------------------------------------------------
# PROBE 1 -- STABLE-SORT TIE-BREAK ORDERING
#   Claim (review item 1): the pooled draw sorts candidates by local inflight-time
#   (reserved_composite.py:342 "cand.sort(key=s._local_ms)", ackclock_sim.py:473
#   "cand.sort(key=local_ms)"; lat_bias defaults False, so this is the live path).
#   In rig='mid' the LOCAL stage drains at base*local_mult (build_rig,
#   local_mult=20.0), so local backlog is usually EXACTLY 0 -> local_ms == 0.0 for
#   several paths at once -> Python's stable sort falls back to LIST ORDER, and
#   every scenario in highn_battery.SCENARIOS() lists the spotty tethers FIRST.
#
#   1.0  PREMISE CENSUS -- per-tick count of paths whose local backlog is exactly
#        0 when the draw loop starts.  If that count is routinely >= 2, the
#        tie-break IS the live decision rule.
#   1a   LITERAL TEST (what the review asked for): permute the archetype list
#        (steady-first, and reversed) on failing B3 cells, same seeds.
#        CONFOUND, stated up front: reserved_composite.SimD and ackclock_sim.Sim
#        share ONE random.Random(seed), consumed per drained frame in path-INDEX
#        order (ackclock_sim.py:62, inside Stage.drain).  Permuting the list
#        therefore ALSO remaps the jitter stream.  A permutation delta is an
#        UPPER bound on the ordering effect.  Control: the same list re-run on a
#        disjoint seed block, which sizes pure RNG reshuffling.
#   1b   CONFOUND-FREE TEST (Dc only): keep the list, the rig and the RNG stream
#        BIT-IDENTICAL and change ONLY the tie-break, by adding eps*rank[i]
#        (eps=1e-12 ms) to _local_ms.  eps is 13 orders below target_ms=40 and
#        below any non-tied difference, so it can only order EXACT ties.
#        SELF-GATE: rank == list order MUST reproduce the baseline bit-for-bit.
#        If it does not, eps is perturbing physics and 1b is void -- reported,
#        not hidden.  (A check that cannot fail on the bug it was written for is
#        theatre; this one fails loudly if eps leaks into the physics.)
#        1b covers 'Dc' only: ackclock_sim's local_ms is a closure inside run(),
#        not a patchable attribute.  Stated, not hidden.
#   1c   POSITIVE CONTROL / SENSITIVITY.  1b can only be believed if the same
#        instrument CAN detect an ordering effect.  So the same rank bias is
#        re-applied at growing magnitudes (1e-12 -> 1.0 ms, all << target_ms=40)
#        and the response curve is printed.  A flat curve at 1e-12 with a live
#        response at 0.1-1.0 ms says the measurement is sensitive and the
#        tie-break null is REAL; a curve that is flat everywhere says the probe
#        is blind and 1b proves nothing.  Without this, 1b would be theatre.
#
# PROBE 2 -- STALL-PHASE DETERMINISM
#   Claim (review item 2): DROPS_A/B/C (reserved_composite.py:542-545) are fixed
#   wall-clock schedules, near non-overlapping by construction.  Seeds vary jitter
#   and arrivals but NOT stall phase -- so "24/24 seeds" overstates independence,
#   and B5's "each added source cuts loss" is partly the favourable
#   non-coincidence of the added source's schedule.
#   TEST: a seeded phase-randomised variant.  Each source's schedule is rotated by
#   an INDEPENDENT per-(seed,source) phase.  A source keeps the same phase across
#   every member of the B5 nested chain, so the chain stays genuinely nested.
#   Re-scored: the N4-teth B3 cell and the whole B5 chain, including a PER-SEED
#   monotonicity count highn_battery.py never computed (it scores B5 on medians).
#
#   ---- CORRECTION, U33 (docs/ROADMAP.md).  THE FIRST RANDOMISER WAS WRONG. ----
#   As committed at 5cf0a4c this file rotated by phi ~ U(0,T) mod T and emitted a
#   wrapped interval as (a2,T) + (0.0, b2-T), and CLAIMED "interval COUNT and total
#   DURATION are preserved exactly".  Both halves of that claim are now measured:
#     * DURATION was preserved.  COUNT WAS NOT -- the split turns a 3-interval
#       schedule into 4.  MEASURED: 8 of 72 (source,seed) pairs.  The old claim is
#       RETRACTED.  Count was precisely the property the probe needed in order to
#       isolate phase from stall population.
#     * The (0.0, b2-T) half is a stall COVERING t=0, and that silently redefines
#       the path's nominal cap to zero for the entire run.  See F1.
#
#   FINDING F1 -- NOT FIXED HERE, IT IS ANOTHER UNIT'S FILE.  The rig's "nominal
#   cap" is cap_fn(0.0): reserved_composite.py:163 (cap0), :170 (drain_ewma),
#   :174 (maxq_kb), :189 (push_est); ackclock_sim.py:101, :107, :112, :134, :137
#   and :547 (drain_ewma is pulled toward cap_fn(0.0) on EVERY tick, all run).
#   The same convention is in reserved_cap0.py:108,115, reserved_dp.py:81,88,
#   reserved_local.py:133,140, reserved_meter.py:126,133,152.  cap_trace
#   (reserved_composite.py:470) returns 0.0 inside a dropout, so ANY schedule with
#   a stall in progress at t=0 does not merely add a stall -- it makes that path
#   nominally dead.  t=0 is load-bearing state, and nothing in the rig defends it.
#   The convention only looks safe because the canonical DROPS_* happen to avoid
#   t=0 (and because sin(0)=0 makes cap_fn(0.0)==base for the spotty archetypes;
#   for the STEADY ones it is already NOT the base -- eth is 88098, not 78000).
#   THE FIX BELONGS IN THE RIG: nominal cap should be a property of the archetype
#   (base/amp/period), not a sample of the trace at one instant.
#
#   WHAT PHASE RANDOMISATION MEANS HERE, physically.  The schedule is a finite
#   stall pattern inside a finite observation window; sliding it cyclically is the
#   only rotation that preserves both count and duration.  A stall straddling the
#   window boundary is REAL geometry -- but under F1 the rig cannot represent it,
#   it turns it into "this path was never there".  So the phase is drawn uniformly
#   over the rotations the rig CAN represent: those whose window boundary falls in
#   an inter-stall GAP.  That set has measure G = T - sum(stall durations), which
#   is DERIVED from the schedule, not chosen (86.7% / 91.1% / 88.3% of rotations
#   for cellA/B/C).  The excluded ~9-13% is NAMED NON-COVERAGE, not a silent drop;
#   it becomes samplable the moment F1 is fixed.
#
#   PROBE 2.0v VALIDATES THE RANDOMISER BEFORE ANY NUMBER IS SCORED: count, total
#   duration, in-window, no-interval-over-t=0, and cap_fn(0.0)==nominal, on every
#   (source,seed) pair; plus a NEGATIVE CONTROL that re-runs the same validator
#   against the OLD wrap-splitting randomiser (kept as phase_drops_wrapsplit) and
#   must FAIL.  A validator that cannot fail is theatre.  If the corrected
#   randomiser fails, PROBE 2's numbers are declared VOID in the output.
#
# NO NEW CONSTANT: eps is a numerical tie-breaker, not a model knob; the phase is
# a uniform draw over a measure derived from the schedule itself, not a tuned
# offset; the 1e-9 tolerances are float-comparison guards, not physics.
#
# Env: SEEDS(24) WORKERS(14) T(9.0) RIG(mid)
# Run:  python rig_checks.py > rig_checks.txt 2> rig_checks.err
# =============================================================================
import os, sys, time, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from concurrent.futures import ProcessPoolExecutor

import reserved_composite as RC
import ackclock_sim as A

SEEDS   = int(os.environ.get('SEEDS', '24'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T       = float(os.environ.get('T', '9.0'))
RIG     = os.environ.get('RIG', 'mid')
CTRL_SEED_BASE = 1000          # disjoint seed block for the RNG-reshuffle control

_ORIG_LM = RC.SimD._local_ms
_ORIG_LC = RC.SimD._local_cap
EPS = 1e-12


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def spotty_idx(archs):
    return [i for i, a in enumerate(archs) if a['spotty']]


def make_sim(defs, ofn, tt, seed, sched):
    if sched in ('Dc', 'Dpp', 'D', 'redundant'):
        return RC.SimD(defs, ofn, tt, seed, sched=sched)
    return A.Sim(defs, ofn, tt, seed, sched=sched, mirror=False)


# ---------------------------------------------------------------------------
# archetype specs as (name, drops_override) so a worker can rebuild them with
# either the canonical or a phase-randomised schedule.  Builders are RC's.
# ---------------------------------------------------------------------------
BUILD = {'cellA': RC.cellA, 'cellB': RC.cellB, 'cellC': RC.cellC}
CANON = {'cellA': RC.DROPS_A, 'cellB': RC.DROPS_B, 'cellC': RC.DROPS_C}


def gaps_of(iv, tt):
    """Half-open [x,y) segments of [0,tt) covered by NO interval of iv.
    cap_trace (reserved_composite.py:470) tests 'a <= t < b', so intervals are
    half-open and so are their complements.  N-generic: no assumption on how many
    intervals, whether they touch, or where they sit."""
    out = []; x = 0.0
    for (a, b) in sorted(iv):
        if a > x:
            out.append((x, a))
        x = max(x, b)
    if x < tt:
        out.append((x, tt))
    return out


def phase_drops(name, seed, tt):
    """PHASE RANDOMISATION -- gap-conditioned cyclic rotation.  See PROBE 2 header.

    Slides the whole canonical pattern cyclically by a per-(seed,source) phase,
    drawn uniformly over the rotations whose WINDOW BOUNDARY lands in an
    inter-stall GAP.  Equivalent formulation, and the one implemented: draw the
    cut point c uniformly over the gaps of the canonical schedule, then rotate by
    phi = (tt - c) mod tt.

    GUARANTEED BY CONSTRUCTION, and re-measured every run in PROBE 2.0v:
      * interval COUNT preserved exactly (one interval out per interval in);
      * total DURATION preserved exactly (each (b-a) carried through unchanged);
      * every interval lies inside [0, tt] -- no wrap, so nothing is split;
      * no interval contains t=0, so cap_fn(0.0) stays the path's nominal cap.
    The admissible measure is G = tt - sum(b-a), DERIVED from the schedule, not a
    chosen constant.  The rejected class -- a stall in progress at the window
    boundary -- is real geometry the rig cannot represent (finding F1); it is
    named non-coverage here, not silently dropped."""
    iv = CANON[name]
    gaps = gaps_of(iv, tt)
    G = sum(y - x for (x, y) in gaps)
    r = random.Random('phase|%s|%d' % (name, seed))
    u = r.uniform(0.0, G)
    c = gaps[-1][0]                      # float-edge fallback (u == G exactly)
    for (x, y) in gaps:
        if u < (y - x):
            c = x + u
            break
        u -= (y - x)
    phi = (tt - c) % tt
    return [(((a + phi) % tt), ((a + phi) % tt) + (b - a)) for (a, b) in iv]


def phase_drops_wrapsplit(name, seed, tt):
    """THE DEFECTIVE RANDOMISER (rig_checks.py as committed at 5cf0a4c), kept ONLY
    as the NEGATIVE CONTROL for PROBE 2.0v.  Never used to score anything.
    Rotates by phi ~ U(0,tt) and splits a wrapped interval into (a2,tt) +
    (0.0, b2-tt) -- which raises the count and puts a stall over t=0."""
    r = random.Random('phase|%s|%d' % (name, seed))
    phi = r.uniform(0.0, tt)
    out = []
    for (a, b) in CANON[name]:
        a2 = (a + phi) % tt
        b2 = a2 + (b - a)
        if b2 <= tt:
            out.append((a2, b2))
        else:
            out.append((a2, tt))
            out.append((0.0, b2 - tt))
    return out


def build_archs(spec, seed, phased, tt, dropfn=None):
    """spec: list of (name, drops_override_or_None).
    dropfn: the phase randomiser to use when phased=True (default phase_drops).
    Only PROBE 2.0v's negative control ever passes a different one."""
    if dropfn is None:
        dropfn = phase_drops
    archs = []
    for (name, override) in spec:
        if name == 'wifi':
            archs.append(RC.wifi())
        elif name == 'eth':
            archs.append(RC.eth())
        else:
            if override is not None:
                d = override
            elif phased:
                d = dropfn(name, seed, tt)
            else:
                d = CANON[name]
            archs.append(BUILD[name](d))
    return archs


def nominal_caps(archs):
    """Each path's NOMINAL cap, built the way the rig itself would build it but
    with the dropout schedule REMOVED.  N-generic: reads no path index, assumes
    no archetype class, and goes through RC.build_rig so it is the same object
    the sims consume.  This is the reference cap_fn(0.0) SHOULD equal."""
    clean = [dict(a, dropouts=()) for a in archs]
    return [d['cap_fn'](0.0) for d in RC.build_rig(clean, bottleneck=RIG)]


def cap0_of(archs):
    return [d['cap_fn'](0.0) for d in RC.build_rig(archs, bottleneck=RIG)]


def check_schedules(spec, seed, tt, dropfn):
    """Validate ONE (spec, seed) draw of a phase randomiser.  Returns a dict of
    the four properties the probe depends on, each MEASURED, not asserted."""
    archs_c = build_archs(spec, seed, False, tt)
    archs_p = build_archs(spec, seed, True, tt, dropfn=dropfn)
    bad_count = bad_dur = bad_range = bad_zero = 0
    max_over = 0.0
    for (ac, ap) in zip(archs_c, archs_p):
        ic = list(ac.get('dropouts', ()) or ())
        ip = list(ap.get('dropouts', ()) or ())
        if len(ic) != len(ip):
            bad_count += 1
        if abs(sum(b - a for a, b in ic) - sum(b - a for a, b in ip)) > 1e-9:
            bad_dur += 1
        for (a, b) in ip:
            if a < 0.0 or b > tt + 1e-9:
                bad_range += 1
            max_over = max(max_over, b - tt)
            if a <= 0.0 < b:
                bad_zero += 1
    nom = nominal_caps(archs_p)
    got = cap0_of(archs_p)
    bad_cap = sum(1 for (x, y) in zip(nom, got) if abs(x - y) > 1e-9)
    return {'count': bad_count, 'dur': bad_dur, 'range': bad_range,
            'zero': bad_zero, 'cap0': bad_cap, 'over': max(0.0, max_over),
            'nsrc': sum(1 for a in archs_c if a.get('dropouts'))}


# ---------------------------------------------------------------------------
# scenario specs -- identical membership to highn_battery.SCENARIOS()
# ---------------------------------------------------------------------------
S_N4TETH = [('cellA', None), ('cellB', None), ('cellC', None), ('eth', None)]
S_N5HET  = [('cellA', None), ('cellB', None), ('cellC', None), ('wifi', None), ('eth', None)]
CHAIN = [
    ('N2-het  cellA + eth',                    [('cellA', None), ('eth', None)]),
    ('N3-het  cellA + cellB + eth',            [('cellA', None), ('cellB', None), ('eth', None)]),
    ('N4-het  cellA + cellB + wifi + eth',     [('cellA', None), ('cellB', None), ('wifi', None), ('eth', None)]),
    ('N5-het  cellA+cellB+cellC + wifi + eth', [('cellA', None), ('cellB', None), ('cellC', None), ('wifi', None), ('eth', None)]),
]


# ---------------------------------------------------------------------------
# workers (top-level + plain args so they pickle under Windows spawn)
# ---------------------------------------------------------------------------
def install_rank(rank, mag=EPS):
    if rank is None:
        RC.SimD._local_ms = _ORIG_LM
    else:
        def lm(s, i, _r=tuple(rank), _m=mag, _o=_ORIG_LM):
            return _o(s, i) + _m * _r[i]
        RC.SimD._local_ms = lm


def w_order(task):
    """PROBE 1a: literal list permutation."""
    (tag, spec, perm, load, sched, seed) = task
    spec2 = [spec[k] for k in perm]
    archs = build_archs(spec2, seed, False, T)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    o = make_sim(defs, (lambda t, _n=nom, _L=load: _L * _n), T, seed, sched)
    m = o.run()
    sp = spotty_idx(archs); tot = sum(o.assigned) or 1
    return (tag, perm, load, sched, seed,
            {'gp': m['gp'], 'loss': m['loss'], 'p95': m['p95'],
             'sshare': sum(o.assigned[i] for i in sp) / tot,
             'assigned': list(o.assigned)})


def w_rank(task):
    """PROBE 1b/1c: rank bias on _local_ms; list, rig and RNG held identical.  Dc only."""
    (tag, spec, rankname, rank, mag, load, seed) = task
    archs = build_archs(spec, seed, False, T)
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    install_rank(rank, mag)
    try:
        o = RC.SimD(defs, (lambda t, _n=nom, _L=load: _L * _n), T, seed, sched='Dc')
        m = o.run()
    finally:
        install_rank(None)
    sp = spotty_idx(archs); tot = sum(o.assigned) or 1
    return (tag, rankname, load, seed,
            {'gp': m['gp'], 'loss': m['loss'], 'p95': m['p95'],
             'sshare': sum(o.assigned[i] for i in sp) / tot,
             'assigned': list(o.assigned)})


def w_phase(task):
    """PROBE 2: canonical vs phase-randomised stall schedules."""
    (tag, spec, phased, offer_mode, load, sched, seed) = task
    archs = build_archs(spec, seed, phased, T)
    defs = RC.build_rig(archs, bottleneck=RIG)
    if offer_mode == 'rel':
        nom = sum(a['base'] for a in archs)
        ofn = (lambda t, _n=nom, _L=load: _L * _n)
    else:
        ofn = (lambda t, _o=load: _o)          # absolute offer (B5)
    o = make_sim(defs, ofn, T, seed, sched)
    m = o.run()
    sp = spotty_idx(archs); tot = sum(o.assigned) or 1
    return (tag, phased, sched, seed,
            {'gp': m['gp'], 'loss': m['loss'], 'p95': m['p95'], 'p99': m['p99'],
             'sshare': sum(o.assigned[i] for i in sp) / tot})


# ---------------------------------------------------------------------------
def hdr(t):
    print('=' * 112); print(t); print('=' * 112)


def run_pool(fn, tasks, label, t0):
    out = []
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for r in ex.map(fn, tasks, chunksize=4):
            out.append(r); done += 1
            if done % 200 == 0:
                print('  ..%s %d/%d (%.0fs)' % (label, done, len(tasks), time.time() - t0),
                      file=sys.stderr)
    return out


CELLS_1A = [
    ('N4-teth @0.65', S_N4TETH,
     [('as-is(spotty-first)', (0, 1, 2, 3)),
      ('steady-first',        (3, 0, 1, 2)),
      ('reversed',            (3, 2, 1, 0))]),
    ('N5-het  @0.65', S_N5HET,
     [('as-is(spotty-first)', (0, 1, 2, 3, 4)),
      ('steady-first',        (4, 3, 0, 1, 2)),
      ('reversed',            (4, 3, 2, 1, 0))]),
]

RANKS_1B = [
    ('N4-teth @0.65', S_N4TETH,
     [('rank=list order [SELF-GATE]', (0, 1, 2, 3)),
      ('rank=steady-first',           (1, 2, 3, 0)),
      ('rank=reversed',               (3, 2, 1, 0))]),
    ('N5-het  @0.65', S_N5HET,
     [('rank=list order [SELF-GATE]', (0, 1, 2, 3, 4)),
      ('rank=steady-first',           (2, 3, 4, 1, 0)),
      ('rank=reversed',               (4, 3, 2, 1, 0))]),
]

# 1c sensitivity ladder: same steady-first rank, growing bias, all << target_ms=40.
BIAS_LADDER = [('1e-12 (ties only)', EPS), ('0.001 ms', 1e-3), ('0.01 ms', 1e-2),
               ('0.1 ms', 1e-1), ('1.0 ms', 1.0)]


class _VoidStream(object):
    """stdout wrapper that stamps VOID | on every non-blank line it forwards.

    The 2.0v gate used to compute PHASE_OK and spend it on a LABEL: the banner said
    "ALL PROBE 2 NUMBERS BELOW ARE VOID" and then printed them anyway, unchanged, in
    the same format as a valid run. Nothing parses this file programmatically -- the
    risk is a person lifting a number past a banner they scrolled through, which is
    exactly how the previous version of this probe got its contaminated magnitudes
    into a commit message and into ROADMAP.md.

    So the marking rides on every LINE rather than on one header. Nothing is
    suppressed: a failing run still prints its numbers, because they are what you
    need to diagnose the randomiser. They just cannot be quoted by accident.
    """

    def __init__(self, w):
        self.w = w
        self._bol = True

    def write(self, s):
        for part in s.splitlines(True):
            if self._bol and part.strip():
                self.w.write('VOID | ')
            self.w.write(part)
            self._bol = part.endswith('\n')

    def flush(self):
        self.w.flush()


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    t0 = time.time()
    print('#' * 112)
    print('# rig_checks.py -- U10  PROBING THE ORACLE   seeds=%d  T=%.1fs  rig=%s' % (SEEDS, T, RIG))
    print('# physics/schedulers/archetypes imported UNMODIFIED from reserved_composite.py +')
    print('# ackclock_sim.py (+ nsched_model.py).  No bar is added, changed or re-scored here.')
    print('#' * 112)
    print()

    # =====================================================================
    hdr('PROBE 1.0  PREMISE CENSUS -- how often is the sort key a TIE?')
    print('  Per-tick count of paths whose LOCAL backlog is exactly 0.0 kb at the moment the')
    print('  draw loop starts (local_ms == 0.0 -> tie -> stable sort falls back to LIST ORDER).')
    print('  sched=Dc, seed=0.  N = number of paths.  frames/tick = total frames the draw loop')
    print('  places per tick -- the tie only decides the ORDER OF THE FIRST FEW, because one')
    print('  offer() makes that path\'s local_ms non-zero and the tie is gone.')
    print()
    print('  %-42s %5s %8s %9s %9s %8s %11s' % ('cell', 'N', 'ticks', 'ties>=2', 'ties=N',
                                                'medzero', 'frames/tick'))
    for (tag, spec, load) in (('N4-teth @0.65', S_N4TETH, 0.65),
                              ('N5-het  @0.65', S_N5HET, 0.65),
                              ('N4-teth @0.95', S_N4TETH, 0.95)):
        archs = build_archs(spec, 0, False, T)
        defs = RC.build_rig(archs, bottleneck=RIG)
        nom = sum(a['base'] for a in archs)
        zc = []

        def lc(s, i, now, _o=_ORIG_LC, _z=zc):
            if i == 0:
                _z.append(sum(1 for k in range(s.N) if s.local[k].backlog_kb == 0.0))
            return _o(s, i, now)
        RC.SimD._local_cap = lc
        try:
            o = RC.SimD(defs, (lambda t, _n=nom, _L=load: _L * _n), T, 0, sched='Dc')
            o.run()
        finally:
            RC.SimD._local_cap = _ORIG_LC
        n = len(archs)
        print('  %-42s %5d %8d %8.1f%% %8.1f%% %8.0f %11.1f'
              % (tag, n, len(zc),
                 100.0 * sum(1 for z in zc if z >= 2) / len(zc),
                 100.0 * sum(1 for z in zc if z == n) / len(zc),
                 med(zc), sum(o.assigned) / float(len(zc))))
    print()
    sys.stdout.flush()

    # =====================================================================
    hdr('PROBE 1a  LITERAL ARCHETYPE-LIST PERMUTATION (confounded: shares the RNG stream)')
    tasks = [(tag, spec, perm, 0.65, sch, sd)
             for (tag, spec, perms) in CELLS_1A
             for (pn, perm) in perms
             for sch in ('Dc', 'ewma', 'pull')
             for sd in range(SEEDS)]
    ctasks = [(tag + ' [CTRL]', spec, perms[0][1], 0.65, sch, CTRL_SEED_BASE + sd)
              for (tag, spec, perms) in CELLS_1A
              for sch in ('Dc', 'ewma', 'pull')
              for sd in range(SEEDS)]
    r1 = run_pool(w_order, tasks + ctasks, '1a', t0)
    acc = {}
    for (tag, perm, load, sch, sd, m) in r1:
        acc.setdefault((tag, perm, sch), []).append(m)

    for (tag, spec, perms) in CELLS_1A:
        print('-' * 112)
        print('  %s   members(as-is) = %s' % (tag, ' '.join(n for n, _ in spec)))
        print('  %-22s %-6s %9s %8s %8s %8s   %s'
              % ('order', 'sched', 'gp', 'loss%', 'p95', 'sshare', 'delta vs as-is'))
        for sch in ('Dc', 'ewma', 'pull'):
            base = acc[(tag, perms[0][1], sch)]
            bg = med([d['gp'] for d in base]); bl = med([d['loss'] for d in base])
            bs = med([d['sshare'] for d in base])
            for (pn, perm) in perms:
                v = acc[(tag, perm, sch)]
                g = med([d['gp'] for d in v]); l = med([d['loss'] for d in v])
                s_ = med([d['sshare'] for d in v]); p = med([d['p95'] for d in v])
                dd = '' if pn.startswith('as-is') else \
                    '  dgp=%+7.0f (%+.2f%%)  dloss=%+6.2f pt  dsshare=%+.3f' % (
                        g - bg, 100.0 * (g - bg) / bg, l - bl, s_ - bs)
                print('  %-22s %-6s %9.0f %8.2f %8.0f %8.3f%s' % (pn, sch, g, l, p, s_, dd))
            v = acc[(tag + ' [CTRL]', perms[0][1], sch)]
            g = med([d['gp'] for d in v]); l = med([d['loss'] for d in v])
            s_ = med([d['sshare'] for d in v]); p = med([d['p95'] for d in v])
            print('  %-22s %-6s %9.0f %8.2f %8.0f %8.3f  dgp=%+7.0f (%+.2f%%)  dloss=%+6.2f pt  '
                  'dsshare=%+.3f  <- RNG-only control (seeds %d+)'
                  % ('CTRL other seeds', sch, g, l, p, s_, g - bg,
                     100.0 * (g - bg) / bg, l - bl, s_ - bs, CTRL_SEED_BASE))
        print()
    sys.stdout.flush()

    # =====================================================================
    hdr('PROBE 1b  TIE-BREAK ONLY (eps=1e-12 ms added to _local_ms; list/rig/RNG bit-identical) -- Dc')
    tasks = [(tag, spec, rn, rk, EPS, 0.65, sd)
             for (tag, spec, rr) in RANKS_1B
             for (rn, rk) in rr for sd in range(SEEDS)]
    r2 = run_pool(w_rank, tasks, '1b', t0)
    acc2 = {}
    for (tag, rn, load, sd, m) in r2:
        acc2.setdefault((tag, rn), {})[sd] = m
    gate_ok = True
    for (tag, spec, rr) in RANKS_1B:
        asis = [p for (t_, s_, ps) in CELLS_1A if t_ == tag
                for (n_, p) in ps if n_.startswith('as-is')][0]
        base = {}
        for (t_, perm, load, sch, sd, m) in r1:
            if t_ == tag and sch == 'Dc' and perm == asis:
                base[sd] = m
        print('-' * 112)
        print('  %s' % tag)
        print('  %-30s %9s %8s %8s %8s   %s'
              % ('tie-break rank', 'gp', 'loss%', 'p95', 'sshare',
                 'PAIRED delta vs unpatched baseline'))
        bg = med([base[s]['gp'] for s in base]); bl = med([base[s]['loss'] for s in base])
        bs = med([base[s]['sshare'] for s in base])
        print('  %-30s %9.0f %8.2f %8.0f %8.3f' % ('UNPATCHED baseline', bg, bl,
                                                   med([base[s]['p95'] for s in base]), bs))
        for (rn, rk) in rr:
            v = acc2[(tag, rn)]
            g = med([v[s]['gp'] for s in v]); l = med([v[s]['loss'] for s in v])
            s_ = med([v[s]['sshare'] for s in v]); p = med([v[s]['p95'] for s in v])
            dls = [v[s]['loss'] - base[s]['loss'] for s in sorted(v)]
            dgs = [v[s]['gp'] - base[s]['gp'] for s in sorted(v)]
            dss = [v[s]['sshare'] - base[s]['sshare'] for s in sorted(v)]
            if 'SELF-GATE' in rn:
                ident = all(x == 0.0 for x in dls) and all(x == 0.0 for x in dgs)
                note = '   -> %s' % ('IDENTICAL on %d/%d seeds: probe VALID' % (SEEDS, SEEDS)
                                     if ident else
                                     'NOT IDENTICAL: eps perturbs physics, PROBE 1b VOID')
                if not ident:
                    gate_ok = False
            else:
                dfr = med([sum(abs(a - b) for a, b in zip(v[s]['assigned'],
                                                          base[s]['assigned']))
                           for s in sorted(v)])
                note = ('   dloss med=%+.3f min=%+.3f max=%+.3f pt | dgp med=%+.0f | '
                        'dsshare med=%+.4f | seeds changed=%d/%d | med |dassigned|=%.0f frames'
                        % (med(dls), min(dls), max(dls), med(dgs), med(dss),
                           sum(1 for x in dls if x != 0.0), SEEDS, dfr))
            print('  %-30s %9.0f %8.2f %8.0f %8.3f%s' % (rn, g, l, p, s_, note))
        print()
    print('  PROBE 1b self-gate: %s' % ('PASS (eps orders exact ties only)' if gate_ok
                                        else 'FAIL -- 1b numbers must be discarded'))
    print()
    sys.stdout.flush()

    # =====================================================================
    hdr('PROBE 1c  POSITIVE CONTROL -- is this instrument able to SEE an ordering effect at all?')
    print('  Same steady-first rank, bias magnitude swept from 1e-12 ms (ties only) to 1.0 ms.')
    print('  All magnitudes are << target_ms=40, so none of them closes a gate; they only')
    print('  reorder the draw.  If the numbers move at 0.1/1.0 ms but not at 1e-12, the probe')
    print('  is SENSITIVE and 1b\'s null is a real null.  If nothing moves anywhere, 1b is blind')
    print('  and proves nothing -- which is the failure mode this control exists to catch.')
    print()
    tasks = [(tag, spec, bn, rk, mag, load, sd)
             for (tag, spec, rr) in RANKS_1B
             for (rn, rk) in rr if rn == 'rank=steady-first'
             for (bn, mag) in BIAS_LADDER
             for load in (0.65, 0.95)
             for sd in range(SEEDS)]
    r2c = run_pool(w_rank, tasks, '1c', t0)
    acc2c = {}
    for (tag, bn, load, sd, m) in r2c:
        acc2c.setdefault((tag, load, bn), {})[sd] = m
    for (tag, spec, rr) in RANKS_1B:
        for load in (0.65, 0.95):
            print('-' * 112)
            print('  %s   load=%.2f   rank = steady-first' % (tag.split()[0], load))
            print('  %-20s %9s %8s %8s %8s   %s'
                  % ('bias magnitude', 'gp', 'loss%', 'p95', 'sshare', 'vs the 1e-12 row'))
            ref = acc2c[(tag, load, BIAS_LADDER[0][0])]
            rg = med([ref[s]['gp'] for s in ref]); rl = med([ref[s]['loss'] for s in ref])
            rs = med([ref[s]['sshare'] for s in ref])
            for (bn, mag) in BIAS_LADDER:
                v = acc2c[(tag, load, bn)]
                g = med([v[s]['gp'] for s in v]); l = med([v[s]['loss'] for s in v])
                s_ = med([v[s]['sshare'] for s in v]); p = med([v[s]['p95'] for s in v])
                dfr = med([sum(abs(a - b) for a, b in zip(v[s]['assigned'], ref[s]['assigned']))
                           for s in sorted(v)])
                print('  %-20s %9.0f %8.2f %8.0f %8.3f   dgp=%+7.0f (%+.2f%%)  dloss=%+6.2f pt  '
                      'dsshare=%+.3f  |dassigned|=%.0f'
                      % (bn, g, l, p, s_, g - rg, 100.0 * (g - rg) / rg, l - rl, s_ - rs, dfr))
        print()
    sys.stdout.flush()

    # =====================================================================
    hdr('PROBE 2.0v  VALIDATE THE RANDOMISER ITSELF -- before a single number is scored')
    print('  U10 as committed rotated by phi~U(0,T) and SPLIT a wrapped interval into (a2,T) +')
    print('  (0, b2-T).  Two consequences: the interval COUNT rises (the artifact claimed it did')
    print('  not -- that claim is retracted, see the file header), and a stall lands over t=0.')
    print('  reserved_composite.py:163,170,174,189 and ackclock_sim.py:101,107,112,134,137,547 all')
    print("  read cap_fn(0.0) as the path's NOMINAL cap, so a stall over t=0 sets that path's")
    print('  nominal cap to 0 FOR THE WHOLE RUN.  That is FINDING F1 below; it is a defect in the')
    print('  rig convention, not in the randomiser, and it is not fixed here.')
    print()
    print('  Four properties, MEASURED on every (source,seed) pair, for the corrected randomiser')
    print('  and -- as a NEGATIVE CONTROL that this validator can fail -- for the defective one.')
    print()
    print('  admissible-phase measure per source (G = T - sum(stall durations), DERIVED):')
    for nm in ('cellA', 'cellB', 'cellC'):
        gg = gaps_of(CANON[nm], T)
        G = sum(y - x for (x, y) in gg)
        print('    %-6s  %d stalls  sum(dur)=%.3fs  G=%.3fs  admissible %.1f%%  '
              'excluded (stall straddling the boundary) %.1f%%'
              % (nm, len(CANON[nm]), T - G, G, 100.0 * G / T, 100.0 * (T - G) / T))
    print()
    print('  %-34s %7s %8s %8s %11s %11s %10s'
          % ('randomiser', 'pairs', 'count!=', 'dur!=', 'out-of-win', 'covers t=0', 'cap0!=nom'))
    val = {}
    for (rn, fn) in (('CORRECTED (gap-conditioned)', phase_drops),
                     ('DEFECTIVE (wrap-split) [CTRL]', phase_drops_wrapsplit)):
        tot = {'count': 0, 'dur': 0, 'range': 0, 'zero': 0, 'cap0': 0}
        pairs = 0; over = 0.0; hits = []
        for sd in range(SEEDS):
            c = check_schedules(S_N4TETH, sd, T, fn)
            pairs += c['nsrc']; over = max(over, c['over'])
            for k in tot:
                tot[k] += c[k]
            if c['zero'] or c['cap0'] or c['count']:
                hits.append(sd)
        val[rn] = (tot, pairs, hits)
        print('  %-34s %7d %8d %8d %11d %11d %10d'
              % (rn, pairs, tot['count'], tot['dur'], tot['range'], tot['zero'], tot['cap0']))
    print('  max interval overrun past T on the corrected randomiser: %.3g s (float only)'
          % max(0.0, over))
    print()
    print('  seeds on which the DEFECTIVE randomiser corrupts the rig: %s  (%d/%d)'
          % (val['DEFECTIVE (wrap-split) [CTRL]'][2],
             len(val['DEFECTIVE (wrap-split) [CTRL]'][2]), SEEDS))
    print('  seeds on which the CORRECTED randomiser corrupts the rig: %s  (%d/%d)'
          % (val['CORRECTED (gap-conditioned)'][2],
             len(val['CORRECTED (gap-conditioned)'][2]), SEEDS))
    print()
    print('  cap_fn(0.0) per path (the vector every consumer snapshots as NOMINAL):')
    print('    canonical                      : %s' % cap0_of(build_archs(S_N4TETH, 0, False, T)))
    print('    nominal reference (no dropouts) : %s' % nominal_caps(build_archs(S_N4TETH, 0, False, T)))
    for sd in (11, 0, 10):
        print('    seed %-2d corrected               : %s'
              % (sd, cap0_of(build_archs(S_N4TETH, sd, True, T))))
        print('    seed %-2d defective  [CTRL]       : %s'
              % (sd, cap0_of(build_archs(S_N4TETH, sd, True, T,
                                         dropfn=phase_drops_wrapsplit))))
    tot_ok = val['CORRECTED (gap-conditioned)'][0]
    PHASE_OK = (sum(tot_ok.values()) == 0)
    ctrl_fires = (len(val['DEFECTIVE (wrap-split) [CTRL]'][2]) > 0)
    print()
    print('  PROBE 2.0v GATE: corrected randomiser %s   |   negative control %s'
          % ('CLEAN on %d/%d pairs and %d/%d seeds -- PROBE 2 numbers are VALID'
             % (val['CORRECTED (gap-conditioned)'][1],
                val['CORRECTED (gap-conditioned)'][1], SEEDS, SEEDS) if PHASE_OK
             else 'FAILS -- ALL PROBE 2 NUMBERS BELOW ARE VOID',
             'FIRES (validator is not blind)' if ctrl_fires
             else 'SILENT -- validator proves nothing, treat PROBE 2 as unvalidated'))
    print()
    sys.stdout.flush()

    # Everything from here to the end of PROBE 2b is scored ON the randomiser the gate
    # above just judged. If it failed, every line of it carries the mark -- see
    # _VoidStream. Restored after 2b so the summary is readable either way.
    _real_stdout = sys.stdout
    if not (PHASE_OK and ctrl_fires):
        sys.stdout = _VoidStream(_real_stdout)

    # =====================================================================
    hdr('PROBE 2.0  what the canonical stall schedules actually are')
    print('  NAMED CAVEAT -- the canonical arm sits on a TICK LATTICE and the randomised arm')
    print('  does not.  DT is 0.01 s (nsched_model) and every canonical stall edge below is a')
    print('  whole number of ticks (5 of the 16 are 1 ulp under, which the a <= t < b test')
    print('  in cap_trace treats identically).  So "canonical" is a knife-edge configuration')
    print('  and EVERY phase sample is off it -- a 1e-9 s slide flips boundary-tick membership.')
    print('  MEASURED, not waved away: de-alignment alone (phi=1e-9) accounts for +8% of the')
    print('  reported Dc move, -25% of the ewma move and -1% of pull -- for ewma it pushes')
    print('  the OPPOSITE way, so that move is if anything understated.  It does NOT touch the')
    print('  spread ratio this probe exists to report: jitter-only spread at fixed OFF-tick')
    print('  geometries is 0.12-0.18 pt against 0.14-0.18 pt canonical, so the denominator')
    print('  is not lattice-narrowed and the honest ratios are 12.7-18.4x against the 11-17x')
    print('  printed below.  The printed number is the conservative one.')
    print()
    print('  DROPS_A = %s   (cellA)' % CANON['cellA'])
    print('  DROPS_B = %s   (cellB)' % CANON['cellB'])
    print('  DROPS_C = %s   (cellC)' % CANON['cellC'])
    print('  Every seed shares these EXACT wall-clock windows.  Pairwise overlap over T=%.1fs.' % T)
    print('  The "phase-random" column is MEASURED over the %d seeds of the corrected randomiser,' % SEEDS)
    print('  not assumed -- gap-conditioning makes the analytic dx*dy/T only an approximation.')
    print('  %-16s %14s %14s %14s' % ('pair', 'canonical', 'phase-random', 'dx*dy/T'))
    for (x, y) in (('cellA', 'cellB'), ('cellA', 'cellC'), ('cellB', 'cellC')):
        def _ov(ix, iy):
            return sum(max(0.0, min(b1, b2) - max(a1, a2))
                       for (a1, b1) in ix for (a2, b2) in iy)
        ov = _ov(CANON[x], CANON[y])
        ovs = [_ov(phase_drops(x, sd, T), phase_drops(y, sd, T)) for sd in range(SEEDS)]
        dx = sum(b - a for a, b in CANON[x]); dy = sum(b - a for a, b in CANON[y])
        print('  %-6s x %-6s   %11.3f s %11.3f s %11.3f s   (phase-random range %.3f..%.3f)'
              % (x, y, ov, sum(ovs) / len(ovs), dx * dy / T, min(ovs), max(ovs)))
    print()

    hdr('PROBE 2a  B3 CELL  N4-teth @0.65 -- canonical vs per-seed phase-randomised stalls')
    tasks = [('N4-teth', S_N4TETH, ph, 'rel', 0.65, sch, sd)
             for ph in (False, True) for sch in ('Dc', 'ewma', 'pull') for sd in range(SEEDS)]
    r3 = run_pool(w_phase, tasks, '2a', t0)
    acc3 = {}
    for (tag, ph, sch, sd, m) in r3:
        acc3.setdefault((ph, sch), {})[sd] = m
    print('  %-16s %-6s %9s %8s %8s %8s   %s'
          % ('stalls', 'sched', 'gp', 'loss%', 'p95', 'sshare', 'loss over seeds (min..max)'))
    for sch in ('Dc', 'ewma', 'pull'):
        for ph in (False, True):
            v = acc3[(ph, sch)]
            ls = [v[s]['loss'] for s in sorted(v)]
            print('  %-16s %-6s %9.0f %8.2f %8.0f %8.3f   %6.2f .. %6.2f  (spread %5.2f pt)'
                  % ('phase-random' if ph else 'canonical', sch,
                     med([v[s]['gp'] for s in v]), med(ls),
                     med([v[s]['p95'] for s in v]), med([v[s]['sshare'] for s in v]),
                     min(ls), max(ls), max(ls) - min(ls)))
        c = acc3[(False, sch)]; p = acc3[(True, sch)]
        cg = med([c[s]['gp'] for s in c]); pg = med([p[s]['gp'] for s in p])
        print('        -> phase-random moves %-4s : dgp=%+8.0f (%+.2f%%)   dloss=%+6.2f pt'
              % (sch, pg - cg, 100.0 * (pg - cg) / cg,
                 med([p[s]['loss'] for s in p]) - med([c[s]['loss'] for s in c])))
    dcc = acc3[(False, 'Dc')]; dcp = acc3[(True, 'Dc')]
    ewc = acc3[(False, 'ewma')]; ewp = acc3[(True, 'ewma')]
    print()
    print('  B3(loss) bar (Dc loss <= 2%%) : canonical %.2f%% -> %s   |   phase-random %.2f%% -> %s'
          % (med([dcc[s]['loss'] for s in dcc]),
             'PASS' if med([dcc[s]['loss'] for s in dcc]) <= 2.0 else 'FAIL',
             med([dcp[s]['loss'] for s in dcp]),
             'PASS' if med([dcp[s]['loss'] for s in dcp]) <= 2.0 else 'FAIL'))
    print('  B3(gp)   bar (Dc gp >= ewma gp): canonical %s   |   phase-random %s'
          % ('PASS' if med([dcc[s]['gp'] for s in dcc]) >= med([ewc[s]['gp'] for s in ewc]) else 'FAIL',
             'PASS' if med([dcp[s]['gp'] for s in dcp]) >= med([ewp[s]['gp'] for s in ewp]) else 'FAIL'))
    print('  Dc-vs-ewma paired loss advantage @0.65 (the load-bearing claim "Dc loss ~ half ewma"):')
    for ph, nm in ((False, 'canonical'), (True, 'phase-random')):
        d = acc3[(ph, 'Dc')]; e = acc3[(ph, 'ewma')]
        pr = [d[s]['loss'] - e[s]['loss'] for s in sorted(d)]
        dm = med([d[s]['loss'] for s in d]); em = med([e[s]['loss'] for s in e])
        print('    %-13s Dc %5.2f%%  ewma %5.2f%%   ratio %.2f   paired Dc-ewma med=%+.2f pt, '
              'Dc better on %d/%d seeds' % (nm, dm, em, dm / max(1e-9, em), med(pr),
                                            sum(1 for x in pr if x < 0), SEEDS))
    print()
    print('  WHAT "24/24 SEEDS" IS.  The canonical battery holds stall GEOMETRY fixed and varies')
    print('  only jitter/arrivals across seeds.  Both axes are measured here on the SAME cell, so')
    print('  the ratio below is how much wider the unsampled axis is than the sampled one.')
    print('  %-6s %18s %18s %10s' % ('sched', 'jitter-only spread', 'geometry spread', 'ratio'))
    for sch in ('Dc', 'ewma', 'pull'):
        cl = [acc3[(False, sch)][s]['loss'] for s in sorted(acc3[(False, sch)])]
        pl = [acc3[(True, sch)][s]['loss'] for s in sorted(acc3[(True, sch)])]
        cs = max(cl) - min(cl); ps = max(pl) - min(pl)
        print('  %-6s %15.2f pt %15.2f pt %9.1fx'
              % (sch, cs, ps, ps / max(1e-9, cs)))
    print('  A "24/24 seeds" result is therefore 24 samples of the NARROW axis.  It is not a')
    print('  confidence interval over stall geometry, and no bar margin smaller than the geometry')
    print('  spread above is established by seed count.  Sampling geometry is UNRESOLVED work:')
    print('  this probe randomises PHASE only -- stall COUNT, DURATION and the 2-8-events-at-T=9s')
    print('  population are still the hand-placed ones (U10 review items 3 and 4, still open).')
    print()
    sys.stdout.flush()

    # =====================================================================
    hdr('PROBE 2b  B5 NESTED CHAIN -- does "each added source buys gp and cuts loss" survive?')
    n5 = build_archs(CHAIN[-1][1], 0, False, T)
    offer = 0.85 * sum(a['base'] for a in n5)
    print('  identical absolute offer = 0.85 x nominal(N5-het) = %.0f kb/s (highn_battery B5)' % offer)
    print('  per-seed columns are NEW: highn_battery scores B5 on medians only.')
    tasks = [(ci, spec, ph, 'abs', offer, sch, sd)
             for ci, (t_, spec) in enumerate(CHAIN)
             for ph in (False, True) for sch in ('Dc', 'ewma') for sd in range(SEEDS)]
    r4 = run_pool(w_phase, tasks, '2b', t0)
    acc4 = {}
    for (ci, ph, sch, sd, m) in r4:
        acc4.setdefault((ci, ph, sch), {})[sd] = m
    for sch in ('Dc', 'ewma'):
        for ph in (False, True):
            print('-' * 112)
            print('  sched=%s   stalls=%s' % (sch, 'phase-random' if ph else 'canonical'))
            print('  %-42s %3s %9s %8s %7s %7s   %s'
                  % ('config', 'N', 'gp', 'loss%', 'p95', 'p99',
                     'step (median)                     per-seed'))
            prev = None
            for ci, (title, spec) in enumerate(CHAIN):
                v = acc4[(ci, ph, sch)]
                g = med([v[s]['gp'] for s in v]); l = med([v[s]['loss'] for s in v])
                mark = ''
                if prev is not None:
                    pv = acc4[(ci - 1, ph, sch)]
                    up = sum(1 for s in sorted(v) if v[s]['gp'] > pv[s]['gp'])
                    dn = sum(1 for s in sorted(v) if v[s]['loss'] < pv[s]['loss'])
                    mark = '  dgp=%+7.0f(%s) dloss=%+6.2f(%s)   gp+ %2d/%d  loss- %2d/%d' % (
                        g - prev[0], 'PASS' if g > prev[0] else 'FAIL',
                        l - prev[1], 'PASS' if l < prev[1] else 'FAIL',
                        up, SEEDS, dn, SEEDS)
                print('  %-42s %3d %9.0f %8.2f %7.0f %7.0f%s'
                      % (title, len(build_archs(spec, 0, False, T)), g, l,
                         med([v[s]['p95'] for s in v]), med([v[s]['p99'] for s in v]), mark))
                prev = (g, l)
    print()
    print('  B5 VERDICT (median rule, exactly as highn_battery scores it):')
    for sch in ('Dc', 'ewma'):
        for ph, nm in ((False, 'canonical'), (True, 'phase-random')):
            bad = []
            for ci in range(1, len(CHAIN)):
                a = acc4[(ci - 1, ph, sch)]; b = acc4[(ci, ph, sch)]
                ga = med([a[s]['gp'] for s in a]); la = med([a[s]['loss'] for s in a])
                gb = med([b[s]['gp'] for s in b]); lb = med([b[s]['loss'] for s in b])
                if not gb > ga:
                    bad.append('%s gp %.0f->%.0f' % (CHAIN[ci][0].split()[0], ga, gb))
                if not lb < la:
                    bad.append('%s loss %.2f->%.2f' % (CHAIN[ci][0].split()[0], la, lb))
            print('    %-5s %-13s : %s' % (sch, nm,
                                           'MONOTONIC (all steps pass)' if not bad
                                           else '%d BROKEN STEP(S): %s' % (len(bad), ' ; '.join(bad))))
    sys.stdout = _real_stdout          # PROBE 2 ends here; the mark rides only on it
    print()
    print('elapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
