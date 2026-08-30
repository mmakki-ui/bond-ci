#!/usr/bin/env python3
# =============================================================================
# q3_sizing.py -- honest reserve SIZING: does an in-flight-window-scale reserve
# suffice, or must r grow to full-stream (== redundant, aggregation collapses)?
# Fine r-sweep on MID-drop N=2, at a spare and a mid load.  r expressed also as
# absolute reserved kb/s and as multiples of the spotty in-flight window (BDP).
# =============================================================================
import sys
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0; SEEDS = 24
LOADS = [0.60, 0.75]
RS = [0.0, 0.02, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40]
ARCHS = [R.cellA(R.DROPS_A), R.eth()]
CELL_BDP = 29000 * 2 * (25 + 2) / 1000.0 / 1000.0 * 1000.0  # kb ~ cap*RTT

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def work(task):
    (load, sched, seed) = task
    defs = R.build_rig(ARCHS, bottleneck='mid')
    nom = sum(a['base'] for a in ARCHS)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=float(sched.split(':')[1])).run()
    elif sched == 'redundant':
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    return (load, sched, {k: m.get(k, 0.0) for k in ('gp', 'loss', 'p99', 'res_tx', 'mir_aged', 'tdrop')})

def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    scheds = ['pull', 'ewma', 'oracle'] + ['D:%.2f' % r for r in RS if r > 0] + ['redundant']
    tasks = [(L, s, sd) for L in LOADS for s in scheds for sd in range(SEEDS)]
    acc = {}
    with ProcessPoolExecutor(max_workers=14) as ex:
        for (L, s, m) in ex.map(work, tasks, chunksize=4):
            acc.setdefault((L, s), []).append(m)
    def agg(L, s, k): return med([d[k] for d in acc[(L, s)]])
    print('#' * 96)
    print('# Q3  RESERVE SIZING  MID-drop N=2 (1 cell + 1 eth).  cell in-flight window (BDP) ~ %.0f kb' % CELL_BDP)
    print('#     eth nominal 78000 kb/s ; cell full stream ~26000 kb/s (~r 0.33 of eth).  seeds=%d' % SEEDS)
    print('#' * 96)
    for L in LOADS:
        print('=' * 96)
        print('load=%.2f    reserved-kb = r*78000 ;  in-flight-windows = reserved-kb / %.0f' % (L, CELL_BDP))
        print('  %-11s %8s %7s %7s %8s %8s %8s' % ('r', 'resv_kb', 'gp', 'loss%', 'p99', 'res_tx', 'aged'))
        for s in scheds:
            if s.startswith('D:'):
                r = float(s.split(':')[1]); rk = r * 78000
                lab = 'D r=%.2f (%.1f BDP)' % (r, rk / CELL_BDP)
            else:
                rk = 0; lab = s
            print('  %-18s %6.0f %7.0f %7.1f %7.0f %8.0f %8.0f' % (
                lab, rk, agg(L, s, 'gp'), agg(L, s, 'loss'), agg(L, s, 'p99'),
                agg(L, s, 'res_tx'), agg(L, s, 'mir_aged')))
        print()

if __name__ == '__main__':
    main()
