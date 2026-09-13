#!/usr/bin/env python3
# =============================================================================
# battery2.py -- parallel measurement battery for scheduler D (reserved-mirror).
# Worker rebuilds all closures from picklable archetype dicts (Windows-safe).
# =============================================================================
import sys, math, json
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0
SEEDS = 8 if 'quick' in sys.argv else 24
RS = [0.05, 0.15, 0.30]
LOADS = [0.65, 0.85]
SCHEDS = ['pull', 'ewma', 'push', 'oracle', 'D:0.05', 'D:0.15', 'D:0.30', 'redundant']

# ---- picklable worker: one run -> metric dict -------------------------------
def work(task):
    (key, archetypes, bn, shape, load, sched, seed) = task
    archs = []
    for a in archetypes:
        a = dict(a)
        if shape and a.get('spotty'):
            a['shape'] = 4000.0
        archs.append(a)
    defs = R.build_rig(archs, bottleneck=bn)
    nom = sum(a['base'] for a in archetypes)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        r = float(sched.split(':')[1])
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=r, ttl_ms=200.0).run()
    elif sched == 'redundant':
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    keep = {k: m[k] for k in ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop', 'depth',
                              'res_tx', 'mir_aged', 'armed_frac') if k in m}
    return (key, sched, load, seed, keep)


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


# ---- scenario definitions (picklable archetype lists) -----------------------
def SCENARIOS():
    return [
        ('N2  1 cell(spotty) + 1 eth(steady)',
         [R.cellA(R.DROPS_A), R.eth()]),
        ('N3  2 cell(spotty) + 1 eth(steady)',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]),
        ('N3  1 cell(spotty) + 1 wifi(steady) + 1 eth(steady)',
         [R.cellA(R.DROPS_A), R.wifi(), R.eth()]),
        ('N4  2 cell + 1 wifi + 1 eth  [heterogeneous]',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.wifi(), R.eth()]),
        ('N3  ALL-SPOTTY correlated (shared stalls)',
         [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)]),
        ('N3  ALL-SPOTTY independent (staggered stalls)',
         [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]),
        ('N2  ALL-STEADY (wifi + eth)  no-op check',
         [R.wifi(), R.eth()]),
        ('N3  ALL-STEADY (wifi + wifi2 + eth)  no-op check',
         [R.wifi(), dict(R.wifi(), base=38000, period=3.7, phase=2.0), R.eth()]),
    ]

RIGS = ['edge', 'mid', 'mid_shape']


def build_tasks():
    tasks = []
    for si, (title, archs) in enumerate(SCENARIOS()):
        for bn in RIGS:
            real_bn = 'mid' if bn == 'mid_shape' else bn
            shape = (bn == 'mid_shape')
            for load in LOADS:
                for sched in SCHEDS:
                    for sd in range(SEEDS):
                        key = (si, bn)
                        tasks.append((key, archs, real_bn, shape, load, sched, sd))
    return tasks


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = SCENARIOS()
    tasks = build_tasks()
    print('# tasks: %d  (seeds=%d T=%.0f)' % (len(tasks), SEEDS, T), file=sys.stderr)
    # results[(si,bn)][sched][load] = list over seeds of metric dicts
    res = {}
    done = 0
    with ProcessPoolExecutor(max_workers=14) as ex:
        for (key, sched, load, seed, m) in ex.map(work, tasks, chunksize=4):
            res.setdefault(key, {}).setdefault(sched, {}).setdefault(load, []).append(m)
            done += 1
            if done % 500 == 0:
                print('  ..%d/%d' % (done, len(tasks)), file=sys.stderr)

    def aggm(lst, k):
        return med([d.get(k, 0.0) for d in lst])

    print('#' * 120)
    print('# SCHEDULER D (RESERVED-MIRROR, N-GENERIC) BATTERY  seeds=%d T=%.0fs medians  physics=nsched_model(UNMODIFIED)' % (SEEDS, T))
    print('#   refs pull/A(ewma-cap)/push/oracle = ackclock_sim.Sim(mirror=False), same two-stage physics.  D & redundant = reserved_dp.SimD')
    print('#   D reserve r: 0.05 in-flight-scale | 0.15 mid | 0.30 ~full-stream.   loads: 0.65 spare | 0.85 tight')
    print('#' * 120)
    for si, (title, archs) in enumerate(scen):
        nom = sum(a['base'] for a in archs)
        nspot = sum(1 for a in archs if a['spotty'])
        print('=' * 120)
        print('%s   | N=%d spotty=%d nominal_agg=%d' % (title, len(archs), nspot, nom))
        print('=' * 120)
        for bn in RIGS:
            key = (si, bn)
            if key not in res:
                continue
            print('  --- rig %-9s ---   [ %s ]' %
                  (bn, '  '.join('load=%.2f' % L for L in LOADS)))
            print('    %-14s | %s' % ('scheduler',
                  '  ||  '.join('%7s %5s %4s %4s %5s %5s' % ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop')
                                for L in LOADS)))
            for sched in SCHEDS:
                cells = []
                for L in LOADS:
                    lst = res[key].get(sched, {}).get(L, [])
                    if not lst:
                        cells.append('%7s %5s %4s %4s %5s %5s' % ('-', '-', '-', '-', '-', '-'))
                        continue
                    cells.append('%7.0f %5.1f %4.0f %4.0f %5.0f %5.0f' % (
                        aggm(lst, 'gp'), aggm(lst, 'loss'), aggm(lst, 'p50'),
                        aggm(lst, 'p95'), aggm(lst, 'p99'), aggm(lst, 'tdrop')))
                print('    %-14s | %s' % (sched, '  ||  '.join(cells)))
            # D r=0.15 reserve diagnostics
            dcells = []
            for L in LOADS:
                lst = res[key].get('D:0.15', {}).get(L, [])
                if lst:
                    dcells.append('armed=%.2f res_tx=%.0f aged=%.0f' % (
                        aggm(lst, 'armed_frac'), aggm(lst, 'res_tx'), aggm(lst, 'mir_aged')))
                else:
                    dcells.append('-')
            print('    %-14s | %s' % ('[D.15 diag]', '  ||  '.join('%-38s' % d for d in dcells)))
            print()


if __name__ == '__main__':
    main()
