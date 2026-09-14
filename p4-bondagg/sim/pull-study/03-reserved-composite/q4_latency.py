#!/usr/bin/env python3
# =============================================================================
# q4_latency.py -- SUDDEN-STALL latency.  Does first-copy-wins-via-reserve avoid
# the retransmit / head-of-line penalty that pull-alone pays when a path stalls?
# ONE clean hidden downstream stall on the spotty path; measure the delivery-tail
# (p95/p99/max), HoL-block events, and late-discards, for pull / A / D / oracle.
# MID rig (hidden stall) and EDGE rig (visible stall) for contrast.
# =============================================================================
import sys
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0; SEEDS = 24
STALL = [(4.0, 4.7)]           # one 700ms hidden stall on the spotty path
LOADS = [0.60, 0.85]

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def archs():
    return [R.cellA(STALL), R.eth()]

def work(task):
    (bn, load, sched, seed) = task
    defs = R.build_rig(archs(), bottleneck=bn)
    nom = sum(a['base'] for a in archs())
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched.startswith('D:'):
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=float(sched.split(':')[1])).run()
    elif sched == 'redundant':
        m = R.SimD(defs, ofn, T, seed, sched='redundant').run()
    else:
        m = A.Sim(defs, ofn, T, seed, sched=sched, mirror=False).run()
    return (bn, load, sched, {k: m.get(k, 0.0) for k in
            ('gp', 'loss', 'p50', 'p95', 'p99', 'hol', 'late', 'tdrop')})

def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    scheds = ['pull', 'ewma', 'D:0.30', 'oracle']
    rigs = ['edge', 'mid']
    tasks = [(bn, L, s, sd) for bn in rigs for L in LOADS for s in scheds for sd in range(SEEDS)]
    acc = {}
    with ProcessPoolExecutor(max_workers=4) as ex:
        for (bn, L, s, m) in ex.map(work, tasks, chunksize=4):
            acc.setdefault((bn, L, s), []).append(m)
    def agg(bn, L, s, k): return med([d[k] for d in acc[(bn, L, s)]])
    print('#' * 92)
    print('# Q4  SUDDEN-STALL LATENCY  one 700ms stall on the spotty path.  seeds=%d' % SEEDS)
    print('#   HoL = ticks the in-order frontier was blocked while a later seq had arrived (retransmit/HoL wait)')
    print('#' * 92)
    for bn in rigs:
        stall_kind = 'VISIBLE (socket stalls)' if bn == 'edge' else 'HIDDEN downstream (meter-free blind spot)'
        print('=' * 92)
        print('rig=%s  stall=%s' % (bn, stall_kind))
        print('=' * 92)
        for L in LOADS:
            print('  load=%.2f' % L)
            print('    %-10s %7s %6s %5s %5s %6s %6s %6s' %
                  ('sched', 'gp', 'loss', 'p50', 'p95', 'p99', 'HoL', 'late'))
            for s in scheds:
                print('    %-10s %7.0f %6.1f %5.0f %5.0f %6.0f %6.0f %6.0f' % (
                    s, agg(bn, L, s, 'gp'), agg(bn, L, s, 'loss'), agg(bn, L, s, 'p50'),
                    agg(bn, L, s, 'p95'), agg(bn, L, s, 'p99'), agg(bn, L, s, 'hol'),
                    agg(bn, L, s, 'late')))
            print()

if __name__ == '__main__':
    main()
