#!/usr/bin/env python3
# =============================================================================
# coverage_oracle.py -- U11: THE DISCRIMINATING EXPERIMENT FOR B3.
#
# WHY.  highn.txt records five honest failures of B3's absolute half
# (Dc loss <= 2% at load 0.65) at EVERY N>=3.  Fable's review classified that as
# a MIS-DERIVED BAR: 2.0 is an absolute constant that happens to sit just above
# the N=2 measured point (0.96%), while the intent it proxies -- "at moderate
# load the composite WINS" -- is SLACK-BOUNDED by the design's own degenerate-case
# analysis (all-spotty -> no steady host -> honest loss == pull).  A slack-blind
# constant cannot encode a slack-bounded intent.  BUT that classification is
# PROVISIONAL until the residual is measured: the same five red cells are equally
# consistent with the mechanism LEAKING coverable loss as N grows.
#
# This file runs the two measurements that tell those apart.  It changes NOTHING:
# reserved_composite.py and ackclock_sim.py are imported unmodified, the mixes are
# highn_battery.SCENARIOS() verbatim, and the physics/rig/seeds are the battery's.
#
# ---------------------------------------------------------------------------
# PART A -- ORACLE-PAIRED COVERAGE RATIO   (load 0.65, six mixes, paired seeds)
#
#     coverage = (loss_pull - loss_X) / (loss_pull - loss_oracle)
#
#   pull   = uncapped work-conserving (the floor: no admission control at all)
#   oracle = ackclock_sim.Sim(sched='oracle'), admission gated on the TRUE
#            INSTANTANEOUS stage-2 cap -- the unreachable upper bound, i.e. all
#            the loss that ANY admission-control mechanism could remove.
#   X      = the mechanism under test.
#
#   Reading (Fable):
#     FLAT across N  => the mechanism extracts a CONSTANT FRACTION of what is
#                       extractable; the 2% failures are purely a BAR problem.
#     FALLING with N while the oracle headroom stays open
#                    => the mechanism is LEAKING coverable loss -- a real design
#                       finding, and B3 must NOT be replaced.
#
#   X is run for Dc AND for two NEGATIVE CONTROLS (ewma = the shipped cap with NO
#   duplication; Dpp = duplication with NO native cap).  Those controls exist to
#   VALIDATE THE PROPOSED GATE: a coverage bar that the mechanism-removed variants
#   also pass is theatre and must not be shipped.
#
# ---------------------------------------------------------------------------
# PART B -- SHED-VS-LATE DECOMPOSITION OF Dc's 0.65 LOSS
#
#   Every post-warm frame Dc failed to release is classified.  The classification
#   is made from state reserved_composite ALREADY maintains (arr / sent_on /
#   mirror_q / the reorder ring), read through a SUBCLASS -- reserved_composite.py
#   is not touched:
#
#     never_placed   : never admitted natively at all (client pool overflow) --
#                      native's own capacity arithmetic, not duplication's business.
#     nom_shed       : nominated for a copy, copy NEVER ADMITTED, frame never
#                      arrived.  Split into:
#        .gate_shut     no steady-class host had an OPEN meter anywhere in the
#                       nomination's TTL window -> capacity arithmetic, exactly
#                       the intent-consistent (i) case.
#        .slack_open    a steady host's meter WAS open in that window and the copy
#                       was still not admitted -> a MECHANISM FAULT (gate ordering
#                       or host stage-1 taildrop).  THIS IS THE NUMBER THAT WOULD
#                       FALSIFY "the mechanism does what it claims".
#     nom_dup_lost   : a copy WAS admitted and both copies still died downstream.
#     nom_late       : the frame ARRIVED but the reorder ring discarded it as late
#                      (ring-hold geometry) -- Fable's (ii), a mechanism defect.
#     spotty_native  : landed on a spotty path, never nominated (reserve unarmed).
#     steady_native  : landed on a steady path and died there -- (iii), native loss.
#   Each native class is additionally split arrived-late / never-arrived so ring
#   discards are visible outside the nominated class too.
#
#   The reorder hold used for the reconstruction is s.dup_ttl, which SimD.__init__
#   computes with the SAME expression finalize() uses for `hold` -- so no constant
#   is re-typed here.
#
# ---------------------------------------------------------------------------
# PART C -- epsilon, and the four-condition test.
#
#   Fable's replacement shape is  coverage >= coverage(N=2) - epsilon.  epsilon is
#   DERIVED here, pre-registered before the numbers were seen, as:
#
#     epsilon := the reference cell's OWN per-seed coverage spread, measured as
#                (median - min) over the paired seeds at N=2.
#
#   i.e. the bar tolerates no more than the seed-to-seed noise the reference cell
#   itself exhibits in the very same statistic.  Nothing is picked; if a later mix
#   falls further below the reference than the reference falls below itself across
#   seeds, that is a real loss of coverage and the bar fires.
#
#   Part A's negative controls then answer "can it fail?" empirically.
#
# Env: SEEDS/WORKERS/T/RIG -- same defaults and meaning as highn_battery.py.
# =============================================================================
import os, sys, time
from collections import deque, Counter
from concurrent.futures import ProcessPoolExecutor

import nsched_model as M
import ackclock_sim as A          # noqa: F401  (physics provenance; used via HB)
import reserved_composite as RC
import highn_battery as HB

SEEDS = int(os.environ.get('SEEDS', '24'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T = float(os.environ.get('T', '9.0'))
RIG = os.environ.get('RIG', 'mid')
LOAD = float(os.environ.get('COVLOAD', '0.65'))     # B3's load, unchanged
DT = M.DT

REFS = ['pull', 'oracle']
UNDER_TEST = ['Dc', 'ewma', 'Dpp']                  # Dc + two negative controls


# ---------------------------------------------------------------------------
# Instrumented Dc -- reads reserved_composite's own state, changes none of it.
# ---------------------------------------------------------------------------
class _NomQ(deque):
    """SimD.mirror_q, but every append (== one NOMINATION) is also logged.
    Behaviourally identical to the deque it replaces."""

    def __init__(self, log):
        super().__init__()
        self.log = log

    def append(self, item):
        self.log.append(item)          # (seq, enq, queued_t)
        super().append(item)


class TrackedSimD(RC.SimD):
    """SimD with two read-only probes.  No admission logic is overridden:
       * _local_cap  is called once per path at the TOP of every tick with the
         tick's `now` -- used purely as a clock.
       * _meter_ok   is the steady-host gate; every evaluation is logged with the
         current tick so 'was any steady host open in this window?' is answerable.
    """

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.nom_log = []
        self.mirror_q = _NomQ(self.nom_log)
        self.meter_log = []
        self._tick_now = 0.0

    def _local_cap(self, i, t):
        self._tick_now = t
        return super()._local_cap(i, t)

    def _meter_ok(self, i):
        ok = super()._meter_ok(i)
        self.meter_log.append((self._tick_now, i, ok))
        return ok

    # ---- post-run classification (no simulation state is mutated) ----------
    def decompose(self):
        hold = self.dup_ttl        # == finalize()'s `hold`, same expression
        deliv = [(a, seq) for seq, a in self.arr.items() if a is not None]
        release, _skips, _depth = M.reorder_release(deliv, hold)
        rel = set(release)

        # Per-tick steady-host slack, TWO readings, because _meter_ok is evaluated
        # more than once per tick (once building host[], again per admit in PIECE 2)
        # and admitting copies is exactly what LATCHES it:
        #   open_any  = open at ANY evaluation in the tick.  Counting a shed against
        #               this OVERSTATES the fault -- the meter may have been open at
        #               tick start and latched by the copies admitted in that tick.
        #               It is an UPPER BOUND on 'slack sat idle'.
        #   open_last = open at the LAST evaluation in the tick, i.e. still open when
        #               the mirror loop was done with this tick.  This is the tight
        #               reading, and the one the fault count uses.
        last_ok = {}
        any_ok = {}
        for (t, i, ok) in self.meter_log:
            if self.spotty[i]:
                continue
            k = int(round(t / DT))
            last_ok[(k, i)] = ok
            any_ok[(k, i)] = any_ok.get((k, i), False) or ok
        open_last = {}
        open_any = {}
        for (k, i), ok in last_ok.items():
            open_last[k] = open_last.get(k, False) or ok
        for (k, i), ok in any_ok.items():
            open_any[k] = open_any.get(k, False) or ok
        ttl_ticks = int(round(hold / DT))

        def _win_open(qt, tbl):
            k0 = int(round(qt / DT))
            for k in range(k0, k0 + ttl_ticks + 1):
                if tbl.get(k, False):
                    return True
            return False

        nom = {}
        for (seq, _enq, qt) in self.nom_log:
            if seq not in nom:
                nom[seq] = qt

        c = Counter()
        for seq, st in self.enq.items():
            if st <= self.warm:
                continue
            c['offered'] += 1
            if seq in rel:
                continue
            c['lost'] += 1
            arrived = self.arr.get(seq) is not None
            placed = self.sent_on.get(seq) or set()
            if not placed:
                c['never_placed'] += 1
                continue
            if seq in nom:
                if arrived:
                    c['nom_late'] += 1                    # (ii) ring-TTL discard
                elif len(placed) >= 2:
                    c['nom_dup_lost'] += 1                # copy admitted, both died
                elif _win_open(nom[seq], open_last):
                    c['nom_shed_slack_open'] += 1         # FAULT (tight reading)
                    c['nom_shed_slack_open_any'] += 1
                elif _win_open(nom[seq], open_any):
                    c['nom_shed_gate_shut'] += 1          # (i) capacity arithmetic
                    c['nom_shed_slack_open_any'] += 1     # upper-bound reading only
                else:
                    c['nom_shed_gate_shut'] += 1          # (i) capacity arithmetic
            elif any(self.spotty[i] for i in placed):
                c['spotty_native_late' if arrived else 'spotty_native_lost'] += 1
            else:
                c['steady_native_late' if arrived else 'steady_native_lost'] += 1

        # INSTRUMENT SELF-CHECK: the *_late classes are exactly the frames that
        # ARRIVED and were then dropped by the reorder ring, which is precisely
        # what finalize() counts as `late`.  If these disagree, the reconstruction
        # (hold, release set, sent_on bookkeeping) is wrong and every number below
        # it is worthless -- so it is asserted, not merely printed.
        c['late_reconstructed'] = (c['nom_late'] + c['spotty_native_late']
                                   + c['steady_native_late'])
        c['nominated'] = len(nom)
        c['res_tx'] = self.res_tx
        c['mir_aged'] = self.mir_aged
        c['armed_ticks'] = self.armed_ticks
        c['open_ticks'] = sum(1 for v in open_last.values() if v)
        c['open_ticks_any'] = sum(1 for v in open_any.values() if v)
        c['nticks'] = self.nticks
        return dict(c)


# ---------------------------------------------------------------------------
# workers (top-level, plain args -- Windows spawn)
# ---------------------------------------------------------------------------
def w_cov(task):
    (si, archs, sched, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom: LOAD * _n)
    o = HB.make_sim(defs, ofn, T, seed, sched)
    m = o.run()
    return (si, sched, seed, m['loss'], m['gp'],
            o.offered_post, m['deliv'], m['late'])


def w_dec(task):
    (si, archs, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    o = TrackedSimD(defs, (lambda t, _n=nom: LOAD * _n), T, seed, sched='Dc')
    m = o.run()
    d = o.decompose()
    d['late_simreported'] = m['late']
    d['tdrop'] = m['tdrop']
    d['selfcheck_bad'] = 0 if d['late_reconstructed'] == m['late'] else 1
    return (si, seed, m['loss'], d)


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = HB.SCENARIOS()
    t0 = time.time()

    print('#' * 118)
    print('# U11 DISCRIMINATING EXPERIMENT FOR B3   load=%.2f  seeds=%d  T=%.1fs  rig=%s'
          % (LOAD, SEEDS, T, RIG))
    print('# A: oracle-paired coverage ratio   B: shed-vs-late decomposition of Dc loss')
    print('# physics/mixes/seeds = highn_battery.SCENARIOS(), unmodified')
    print('#' * 118)

    # ------------------------------- PART A --------------------------------
    tasks = [(si, archs, sch, sd)
             for si, (t_, archs, c_) in enumerate(scen)
             for sch in REFS + UNDER_TEST for sd in range(SEEDS)]
    print('# part-A runs: %d' % len(tasks), file=sys.stderr)
    L = {}
    LATE = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sch, sd, loss, gp, offp, deliv, late) in ex.map(w_cov, tasks, chunksize=4):
            L.setdefault(si, {}).setdefault(sch, {})[sd] = loss
            e = LATE.setdefault(si, {}).setdefault(sch, [0, 0, 0])
            e[0] += offp; e[1] += (offp - deliv); e[2] += late
    print('# part-A done %.0fs' % (time.time() - t0), file=sys.stderr)

    cov = {}      # (si, sched) -> list of per-seed coverage
    print('=' * 118)
    print('PART A -- ORACLE-PAIRED COVERAGE   coverage = (loss_pull - loss_X)/(loss_pull - loss_oracle)')
    print('         PAIRED PER SEED.  oracle = admission on the TRUE instantaneous stage-2 cap.')
    print('=' * 118)
    print('  %-42s %3s %7s %7s %7s | %s' % ('mix', 'N', 'pull%', 'orcl%', 'headrm',
                                            'coverage(Dc) med [min..max]'))
    for si, (title, archs, c_) in enumerate(scen):
        pl = med([L[si]['pull'][d] for d in range(SEEDS)])
        oc = med([L[si]['oracle'][d] for d in range(SEEDS)])
        for sch in UNDER_TEST:
            vals = []
            for d in range(SEEDS):
                den = L[si]['pull'][d] - L[si]['oracle'][d]
                if den <= 1e-9:
                    continue
                vals.append((L[si]['pull'][d] - L[si][sch][d]) / den)
            cov[(si, sch)] = vals
        v = cov[(si, 'Dc')]
        print('  %-42s %3d %7.2f %7.2f %7.2f | %6.3f [%6.3f..%6.3f]  n=%d'
              % (title[:42], len(archs), pl, oc, pl - oc,
                 med(v), min(v), max(v), len(v)))
    print()
    print('  NOTE ON SCALE: coverage > 1 is EXPECTED and is not an error.  The oracle is a pure')
    print('  ADMISSION-CONTROL upper bound (mirror=False, no duplication), so the denominator is the')
    print('  loss that ideal admission control alone could remove.  Dc also duplicates, so it can and')
    print('  does remove more than that.  The ratio is a NORMALISER against a per-mix physics-derived')
    print('  yardstick -- read its TREND ACROSS N, not its distance from 1.')
    print()
    print('  per-mix coverage medians by scheduler (Dc vs the mechanism-removed controls)')
    print('  %-42s %3s %9s %9s %9s' % ('mix', 'N', 'Dc', 'ewma', 'Dpp'))
    for si, (title, archs, c_) in enumerate(scen):
        print('  %-42s %3d %9.3f %9.3f %9.3f'
              % (title[:42], len(archs),
                 med(cov[(si, 'Dc')]), med(cov[(si, 'ewma')]), med(cov[(si, 'Dpp')])))
    print()
    print('  per-seed coverage spread AT THE REFERENCE CELL (si=0, N=2) -- the epsilon source')
    v0 = cov[(0, 'Dc')]
    eps = med(v0) - min(v0)
    print('    Dc  median=%.4f  min=%.4f  max=%.4f  (median-min) = EPSILON = %.4f'
          % (med(v0), min(v0), max(v0), eps))
    print('    per-seed: %s' % ' '.join('%.3f' % x for x in sorted(v0)))
    print()
    thr = med(v0) - eps
    print('  PROPOSED BAR  coverage(mix) >= coverage(N=2) - epsilon = %.4f' % thr)
    print('  %-42s %3s %9s %6s | %9s %6s | %9s %6s'
          % ('mix', 'N', 'Dc', 'verd', 'ewma', 'verd', 'Dpp', 'verd'))
    ctl_fail = {'ewma': 0, 'Dpp': 0}
    dc_fail = 0
    for si, (title, archs, c_) in enumerate(scen):
        row = []
        for sch in UNDER_TEST:
            m_ = med(cov[(si, sch)])
            ok = m_ >= thr
            if not ok:
                if sch == 'Dc':
                    dc_fail += 1
                else:
                    ctl_fail[sch] += 1
            row += [m_, 'PASS' if ok else 'FAIL']
        print('  %-42s %3d %9.3f %6s | %9.3f %6s | %9.3f %6s'
              % (title[:42], len(archs), *row))
    print('  GATE VALIDATION: the proposed bar FAILS on ewma %d/%d cells, on Dpp %d/%d cells'
          % (ctl_fail['ewma'], len(scen), ctl_fail['Dpp'], len(scen)))
    print('    (a bar that both mechanism-removed controls also PASS is theatre -> do not ship)')
    print('    Dc fails %d/%d cells under the proposed bar.' % (dc_fail, len(scen)))
    sys.stdout.flush()

    # ------------------------------- PART A3 -------------------------------
    # GATE VALIDATION IN THE BATTERY'S EXACT SHAPE.  Part A's coverage is a ratio;
    # highn_battery's B3 asserts on the PAIRED MEDIAN OF THE DIFFERENCE
    # (med(loss_X - loss_oracle) <= 0).  Median-of-ratios < 1 does not strictly
    # imply median-of-differences > 0, so the adopted bar is evaluated here
    # literally, from these same paired runs, rather than inferred.
    print('=' * 118)
    print('PART A3 -- THE ADOPTED BAR, EVALUATED LITERALLY:  med(loss_X - loss_oracle) <= 0')
    print('           (highn_battery B3 loss half, exact form)  -- ewma and Dpp are the controls')
    print('=' * 118)
    print('  %-42s %3s | %s' % ('mix', 'N', ' '.join('%22s' % s for s in UNDER_TEST)))
    nfail = {s: 0 for s in UNDER_TEST}
    for si, (title, archs, c_) in enumerate(scen):
        cells = []
        for sch in UNDER_TEST:
            dif = [L[si][sch][d] - L[si]['oracle'][d] for d in range(SEEDS)]
            ok = med(dif) <= 0.0
            if not ok:
                nfail[sch] += 1
            cells.append('%+7.3f %4s %2d/%d worse' % (med(dif), 'PASS' if ok else 'FAIL',
                                                      sum(1 for x in dif if x > 0.0), SEEDS))
        print('  %-42s %3d | %s' % (title[:42], len(archs),
                                    ' '.join('%22s' % c for c in cells)))
    print('  ADOPTED-BAR FAILURES:  Dc %d/%d   ewma %d/%d   Dpp %d/%d'
          % (nfail['Dc'], len(scen), nfail['ewma'], len(scen), nfail['Dpp'], len(scen)))
    print('  The bar is only meaningful if the mechanism-removed controls FAIL it.')
    sys.stdout.flush()

    # ------------------------------- PART B --------------------------------
    print('=' * 118)
    print('PART B -- SHED-VS-LATE DECOMPOSITION of Dc loss at load=%.2f (summed over %d seeds)'
          % (LOAD, SEEDS))
    print('   shed.shut = no steady host meter open in the TTL window  -> capacity arithmetic (intent)')
    print('   shed.OPEN = a steady host WAS open and the copy still was not admitted -> FAULT')
    print('   nom_late  = frame ARRIVED, reorder ring discarded it late -> mechanism defect (ii)')
    print('=' * 118)
    dtasks = [(si, archs, sd) for si, (t_, archs, c_) in enumerate(scen)
              for sd in range(SEEDS)]
    print('# part-B runs: %d' % len(dtasks), file=sys.stderr)
    D = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sd, loss, d) in ex.map(w_dec, dtasks, chunksize=4):
            D.setdefault(si, []).append((loss, d))

    keys = ['never_placed', 'nom_shed_gate_shut', 'nom_shed_slack_open',
            'nom_dup_lost', 'nom_late', 'spotty_native_lost', 'spotty_native_late',
            'steady_native_lost', 'steady_native_late']
    hdr = ['nevpl', 'shed.shut', 'shed.OPEN', 'dup_lost', 'nom_late',
           'spN.lost', 'spN.late', 'stN.lost', 'stN.late']
    print('  %-30s %3s %8s %7s | %s' % ('mix', 'N', 'offered', 'lost',
                                        ' '.join('%9s' % h for h in hdr)))
    bad = 0
    for si, (title, archs, c_) in enumerate(scen):
        tot = Counter()
        for (loss, d) in D[si]:
            for k, v in d.items():
                tot[k] += v
        off = tot['offered']; lost = tot['lost']
        print('  %-30s %3d %8d %7d | %s' % (title[:30], len(archs), off, lost,
              ' '.join('%9d' % tot[k] for k in keys)))
        print('  %-30s %3s %8s %7s | %s   (%% of LOST)'
              % ('', '', '', '', ' '.join('%8.1f%%' % (100.0 * tot[k] / max(1, lost))
                                          for k in keys)))
        print('  %-30s   nominated=%d  copies admitted(res_tx)=%d  aged=%d  '
              'armed=%d/%d ticks  steady-meter-open(last-eval)=%d/%d  (any-eval)=%d/%d'
              % ('', tot['nominated'], tot['res_tx'], tot['mir_aged'],
                 tot['armed_ticks'], tot['nticks'], tot['open_ticks'], tot['nticks'],
                 tot['open_ticks_any'], tot['nticks']))
        print('  %-30s   shed.OPEN upper bound (any-eval reading) = %d  (%.1f%% of LOST)'
              % ('', tot['nom_shed_slack_open_any'],
                 100.0 * tot['nom_shed_slack_open_any'] / max(1, lost)))
        print('  %-30s   INSTRUMENT SELF-CHECK: reconstructed late=%d  sim-reported late=%d '
              ' -> %s   (%d/%d runs disagree)'
              % ('', tot['late_reconstructed'], tot['late_simreported'],
                 'OK' if tot['selfcheck_bad'] == 0 else 'BROKEN',
                 tot['selfcheck_bad'], SEEDS))
        bad += tot['selfcheck_bad']
    print()
    print('  DECOMPOSITION VALIDITY: %d/%d runs where the reconstruction disagreed with the'
          ' simulator\'s own late counter.' % (bad, len(scen) * SEEDS))
    if bad:
        print('  ==> PART B IS INVALID.  Do not read the numbers above.')
    sys.stdout.flush()

    # ------------------------------ PART B2 --------------------------------
    # The load-bearing cross-check for "do not replace B3 with a ratio bar".
    # If reorder-ring late-discard dominates EVERY scheduler's loss, then it
    # largely CANCELS in (loss_pull - loss_X)/(loss_pull - loss_oracle), and a
    # coverage bar would be blind to it -- while B3's absolute half is not.
    print('=' * 118)
    print('PART B2 -- IS LATE-DISCARD SPECIFIC TO Dc?  late/lost per scheduler at load=%.2f'
          % LOAD)
    print('   (`late` is the simulator\'s own counter: frames that ARRIVED and the reorder ring dropped)')
    print('=' * 118)
    cols = REFS + UNDER_TEST
    print('  %-42s %3s | %s' % ('mix', 'N', ' '.join('%14s' % c for c in cols)))
    for si, (title, archs, c_) in enumerate(scen):
        cells = []
        for sch in cols:
            offp, lost, late = LATE[si][sch]
            cells.append('%6d %6.1f%%' % (lost, 100.0 * late / max(1, lost)))
        print('  %-42s %3d | %s' % (title[:42], len(archs),
                                    ' '.join('%14s' % c for c in cells)))
    print('  (each cell: total LOST frames over %d seeds, and what %% of them were late-discards)'
          % SEEDS)
    sys.stdout.flush()

    print('=' * 118)
    print('elapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
