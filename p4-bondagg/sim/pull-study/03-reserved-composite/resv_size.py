#!/usr/bin/env python3
# =============================================================================
# resv_size.py -- ASSIGNED SLICE: reserve-SIZE Pareto for D (reserved-mirror),
# N=2 (1 spotty + 1 steady), rigs EDGE and MID (drop + shape), vs the reference
# schedulers pull / A(ewma-cap) / push / oracle / full-redundant.
#
# Reserve-size sweep (the x-axis of the Pareto), not a fine r-scan:
#   none          r=0.00  (D degenerates to pull; the 0-cost floor)
#   in-flight-BDP r=0.02  (reserve == ~1x the spotty path's in-flight window,
#                          same anchor q3_sizing.py established: r*eth_cap /
#                          CELL_BDP ~= 1.0 at r=0.02 for cellA+eth)
#   25%           r=0.25  (quarter of host nominal capacity reserved)
#   50%           r=0.50  (half of host nominal capacity reserved)
#   full          r=1.00  (whole host nominal capacity available to the
#                          mirror when native doesn't need it -- the top of
#                          D's own knob, distinct from the separate
#                          'redundant' scheduler which unconditionally
#                          duplicates every frame with no TTL/at-risk gate)
#
# Same rig/scenario builders (R.build_rig, R.cellA/eth, R.DROPS_A), same paired
# physics (nsched_model unmodified), same schedulers (ackclock_sim.Sim for the
# references, reserved_dp.SimD for D and redundant) as every sibling script in
# this directory. Nothing here re-implements the mechanism.
# =============================================================================
import sys
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0
SEEDS = 24
LOADS = [0.65, 0.85]          # spare / tight, same convention as battery2.py
ARCHS = [R.cellA(R.DROPS_A), R.eth()]     # N=2: 1 spotty (cellA) + 1 steady (eth)
RIGS = ['edge', 'mid', 'mid_shape']       # EDGE, MID-drop, MID-shape

RSIZES = [('none', 0.00), ('in-flight-BDP', 0.02), ('25%', 0.25),
          ('50%', 0.50), ('full', 1.00)]
REFSCHEDS = ['pull', 'ewma', 'push', 'oracle']   # A(cap) == ewma
REDUNDANT = 'redundant'

CELL_BDP = 29000 * 2 * (25 + 2) / 1000.0          # kb, same formula as q3_sizing.py


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def work(task):
    (bn, shape, load, sched, seed) = task
    archs = []
    for a in ARCHS:
        a = dict(a)
        if shape and a.get('spotty'):
            a['shape'] = 4000.0        # carrier throttle, never full outage
        archs.append(a)
    defs = R.build_rig(archs, bottleneck=bn)
    nom = sum(a['base'] for a in ARCHS)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        r = float(sched.split(':')[1])
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=r, ttl_ms=200.0).run()
    elif sched == REDUNDANT:
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    keep = {k: m[k] for k in ('gp', 'loss', 'p99', 'res_tx', 'mir_aged', 'armed_frac') if k in m}
    return (bn, load, sched, keep)


def build_tasks():
    tasks = []
    for bn_label in RIGS:
        real_bn = 'mid' if bn_label == 'mid_shape' else bn_label
        shape = (bn_label == 'mid_shape')
        scheds = ['D:%.2f' % r for (_, r) in RSIZES] + REFSCHEDS + [REDUNDANT]
        for load in LOADS:
            for sched in scheds:
                for sd in range(SEEDS):
                    tasks.append((bn_label, real_bn, shape, load, sched, sd))
    return tasks


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    raw_tasks = build_tasks()
    tasks = [(real_bn, shape, load, sched, sd) for (bn_label, real_bn, shape, load, sched, sd) in raw_tasks]
    labels = [bn_label for (bn_label, real_bn, shape, load, sched, sd) in raw_tasks]
    print('# resv_size tasks: %d  (seeds=%d T=%.0f)' % (len(tasks), SEEDS, T), file=sys.stderr)
    acc = {}
    done = 0
    with ProcessPoolExecutor(max_workers=14) as ex:
        for lbl, (bn, load, sched, m) in zip(labels, ex.map(work, tasks, chunksize=4)):
            acc.setdefault((lbl, load, sched), []).append(m)
            done += 1
            if done % 500 == 0:
                print('  ..%d/%d' % (done, len(tasks)), file=sys.stderr)

    def aggm(lst, k):
        return med([d.get(k, 0.0) for d in lst])

    print('#' * 108)
    print('# RESERVE-SIZE PARETO -- N=2 (1 spotty[cellA] + 1 steady[eth]), EDGE + MID(drop) + MID(shape)')
    print('# D reserve sizes: none=0.00 | in-flight-BDP=0.02 (~1x cellA BDP=%.0fkb, r*eth_cap/BDP~=1) | 25%%=0.25 | 50%%=0.50 | full=1.00' % CELL_BDP)
    print('# refs: pull / A(ewma-cap) / push / oracle = ackclock_sim.Sim(mirror=False) ; redundant = full duplication (reserved_dp.SimD)')
    print('# seeds=%d T=%.0fs medians, paired physics (nsched_model unmodified)' % (SEEDS, T))
    print('#' * 108)
    for bn_label in RIGS:
        print('=' * 108)
        print('RIG: %s' % bn_label)
        print('=' * 108)
        hdr = '  %-20s | %s' % ('reserve size / sched',
              '  ||  '.join('%22s' % ('load=%.2f  gp/loss%%/p99' % L) for L in LOADS))
        print(hdr)
        print('  ' + '-' * 104)
        for (rlabel, r) in RSIZES:
            sched = 'D:%.2f' % r
            row = '  %-20s | ' % rlabel
            for L in LOADS:
                lst = acc.get((bn_label, L, sched), [])
                if not lst:
                    row += '%22s  ' % '-'
                    continue
                row += '%9.0f/%4.1f/%5.0f  ' % (aggm(lst, 'gp'), aggm(lst, 'loss'), aggm(lst, 'p99'))
            print(row)
        print('  ' + '-' * 104)
        for sched in REFSCHEDS + [REDUNDANT]:
            row = '  %-20s | ' % sched
            for L in LOADS:
                lst = acc.get((bn_label, L, sched), [])
                if not lst:
                    row += '%22s  ' % '-'
                    continue
                row += '%9.0f/%4.1f/%5.0f  ' % (aggm(lst, 'gp'), aggm(lst, 'loss'), aggm(lst, 'p99'))
            print(row)
        # D reserve mechanics diagnostics (armed_frac / res_tx / mir_aged) at load=0.85
        print('  [D diag @ load=%.2f]  res_tx = mirror copies sent, mir_aged = at-risk frames TTL-expired uncovered' % LOADS[-1])
        for (rlabel, r) in RSIZES:
            sched = 'D:%.2f' % r
            lst = acc.get((bn_label, LOADS[-1], sched), [])
            if lst:
                print('    %-16s armed=%.2f res_tx=%.0f aged=%.0f' % (
                    rlabel, aggm(lst, 'armed_frac'), aggm(lst, 'res_tx'), aggm(lst, 'mir_aged')))
        print()


if __name__ == '__main__':
    main()
