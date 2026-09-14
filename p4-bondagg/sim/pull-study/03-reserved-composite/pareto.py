#!/usr/bin/env python3
# =============================================================================
# pareto.py -- throughput-vs-robustness of D as a function of LOAD (spare), r,
# and spotty-fraction.  The reserve rides spare, so load is the decisive axis.
# MID-drop rig (the meter-free blind spot).  Parallel worker (Windows-safe).
# =============================================================================
import sys
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0
SEEDS = 24
LOADS = [0.50, 0.60, 0.70, 0.80, 0.90]
RS = [0.0, 0.05, 0.10, 0.20, 0.30, 0.40]

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

# scenarios: (name, archetypes)
def scen_list():
    return [
        ('N2 (1sp+1st, spotty-frac 0.50)', [R.cellA(R.DROPS_A), R.eth()]),
        ('N3 (2sp+1st, spotty-frac 0.67)', [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]),
        ('N4 (2sp+2st, spotty-frac 0.50)', [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.wifi(), R.eth()]),
    ]

def work(task):
    (sidx, archs, load, sched, seed) = task
    defs = R.build_rig(archs, bottleneck='mid')
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        r = float(sched.split(':')[1])
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=r).run()
    elif sched == 'redundant':
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    return (sidx, load, sched, {k: m.get(k, 0.0) for k in ('gp', 'loss', 'p99')})

def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    scens = scen_list()
    scheds = ['pull', 'ewma', 'oracle'] + ['D:%.2f' % r for r in RS if r > 0] + ['redundant']
    tasks = []
    for si, (nm, archs) in enumerate(scens):
        for load in LOADS:
            for sched in scheds:
                for sd in range(SEEDS):
                    tasks.append((si, archs, load, sched, sd))
    print('# pareto tasks: %d' % len(tasks), file=sys.stderr)
    acc = {}
    with ProcessPoolExecutor(max_workers=14) as ex:
        for (si, load, sched, m) in ex.map(work, tasks, chunksize=4):
            acc.setdefault((si, load, sched), []).append(m)
    def agg(si, load, sched, k):
        return med([d[k] for d in acc[(si, load, sched)]])
    print('#' * 100)
    print('# D THROUGHPUT-vs-ROBUSTNESS PARETO  (MID-drop rig, seeds=%d)  gp / loss%% / p99ms   medians' % SEEDS)
    print('#' * 100)
    for si, (nm, archs) in enumerate(scens):
        print('=' * 100)
        print(nm)
        print('=' * 100)
        hdr = '  %-11s | ' % 'sched' + ' '.join('%16s' % ('load=%.2f' % L) for L in LOADS)
        print(hdr)
        for sched in scheds:
            row = '  %-11s | ' % sched
            for L in LOADS:
                row += '%6.0f/%4.1f/%3.0f ' % (agg(si, L, sched, 'gp'),
                                               agg(si, L, sched, 'loss'),
                                               agg(si, L, sched, 'p99'))
            print(row)
        print()

if __name__ == '__main__':
    main()
