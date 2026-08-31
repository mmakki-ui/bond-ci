#!/usr/bin/env python3
# =============================================================================
# myslice_battery.py -- ASSIGNED SLICE ONLY (Reserved-N / N + mix sweep agent).
# Scenarios:
#   N=3  2 spotty + 1 steady
#   N=3  1 spotty + 2 steady
#   N=4  heterogeneous (2 cell + 1 wifi + 1 eth, varied owd/jit/cap)
#   N=3  ALL-SPOTTY correlated  (should collapse to pull-like, honest loss)
#   N=3  ALL-SPOTTY independent (partial coverage expected)
#   N=2  ALL-STEADY  (confirm ~zero cost)
#   N=3  ALL-STEADY  (confirm ~zero cost)
# rig=mid (meter-free blind spot -- the hard case), loads=[0.65,0.85], 24 seeds.
# =============================================================================
import sys, math, json
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0
SEEDS = 24
LOADS = [0.65, 0.85]
SCHEDS = ['pull', 'ewma', 'push', 'oracle', 'D:0.05', 'D:0.15', 'D:0.30', 'redundant']
RIG = 'mid'   # the harder / meter-free blind-spot bottleneck placement


def work(task):
    (key, archetypes, load, sched, seed) = task
    defs = R.build_rig(archetypes, bottleneck=RIG)
    nom = sum(a['base'] for a in archetypes)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        r = float(sched.split(':')[1])
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=r, ttl_ms=200.0).run()
    elif sched == 'redundant':
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    keep = {k: m[k] for k in ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop',
                              'res_tx', 'mir_aged', 'armed_frac') if k in m}
    return (key, sched, load, seed, keep)


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def SCENARIOS():
    return [
        ('N3  2 spotty(cellA+cellB) + 1 steady(eth)',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]),
        ('N3  1 spotty(cellA) + 2 steady(wifi+eth)',
         [R.cellA(R.DROPS_A), R.wifi(), R.eth()]),
        ('N4  heterogeneous: 2 cell + 1 wifi + 1 eth',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.wifi(), R.eth()]),
        ('N3  ALL-SPOTTY correlated (shared stalls)',
         [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)]),
        ('N3  ALL-SPOTTY independent (staggered stalls)',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]),
        ('N2  ALL-STEADY (wifi + eth)',
         [R.wifi(), R.eth()]),
        ('N3  ALL-STEADY (wifi + wifi2 + eth)',
         [R.wifi(), dict(R.wifi(), base=38000, period=3.7, phase=2.0), R.eth()]),
    ]


def build_tasks():
    tasks = []
    for si, (title, archs) in enumerate(SCENARIOS()):
        for load in LOADS:
            for sched in SCHEDS:
                for sd in range(SEEDS):
                    tasks.append((si, archs, load, sched, sd))
    return tasks


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = SCENARIOS()
    tasks = build_tasks()
    print('# myslice tasks: %d  (seeds=%d T=%.0f rig=%s)' % (len(tasks), SEEDS, T, RIG), file=sys.stderr)
    res = {}
    done = 0
    with ProcessPoolExecutor(max_workers=14) as ex:
        for (si, sched, load, seed, m) in ex.map(work, tasks, chunksize=4):
            res.setdefault(si, {}).setdefault(sched, {}).setdefault(load, []).append(m)
            done += 1
            if done % 500 == 0:
                print('  ..%d/%d' % (done, len(tasks)), file=sys.stderr)

    def aggm(lst, k):
        return med([d.get(k, 0.0) for d in lst])

    print('#' * 110)
    print('# MYSLICE (Reserved-N / N + mix sweep)  seeds=%d T=%.0fs medians  rig=%s  physics=nsched_model(UNMODIFIED)' % (SEEDS, T, RIG))
    print('#' * 110)
    for si, (title, archs) in enumerate(scen):
        nom = sum(a['base'] for a in archs)
        nspot = sum(1 for a in archs if a['spotty'])
        print('=' * 110)
        print('%s   | N=%d spotty=%d nominal_agg=%d' % (title, len(archs), nspot, nom))
        print('=' * 110)
        print('  %-14s | %s' % ('scheduler',
              '  ||  '.join('%7s %5s %4s %4s %5s %5s' % ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop')
                            for L in LOADS)))
        for sched in SCHEDS:
            cells = []
            for L in LOADS:
                lst = res.get(si, {}).get(sched, {}).get(L, [])
                if not lst:
                    cells.append('%7s %5s %4s %4s %5s %5s' % ('-', '-', '-', '-', '-', '-'))
                    continue
                cells.append('%7.0f %5.1f %4.0f %4.0f %5.0f %5.0f' % (
                    aggm(lst, 'gp'), aggm(lst, 'loss'), aggm(lst, 'p50'),
                    aggm(lst, 'p95'), aggm(lst, 'p99'), aggm(lst, 'tdrop')))
            print('  %-14s | %s' % (sched, '  ||  '.join(cells)))
        dcells = []
        for L in LOADS:
            lst = res.get(si, {}).get('D:0.15', {}).get(L, [])
            if lst:
                dcells.append('armed=%.2f res_tx=%.0f aged=%.0f' % (
                    aggm(lst, 'armed_frac'), aggm(lst, 'res_tx'), aggm(lst, 'mir_aged')))
            else:
                dcells.append('-')
        print('  %-14s | %s' % ('[D.15 diag]', '  ||  '.join('%-30s' % d for d in dcells)))
        print()


if __name__ == '__main__':
    main()
