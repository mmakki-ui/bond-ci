#!/usr/bin/env python3
# =============================================================================
# allspotty_probe.py -- the degenerate case.  Does letting a MOMENTARILY-HEALTHY
# spotty path host a stalled sibling buy partial coverage when there is NO steady
# host?  correlated (shared stalls) vs independent (staggered).  MID-drop rig.
# =============================================================================
import sys
from concurrent.futures import ProcessPoolExecutor
import reserved_dp as R
import ackclock_sim as A

T = 9.0; SEEDS = 24
LOADS = [0.60, 0.85]

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def archs(kind):
    if kind == 'corr':
        return [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)]
    return [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]

def work(task):
    (kind, load, sched, seed) = task
    aa = archs(kind)
    defs = R.build_rig(aa, bottleneck='mid')
    nom = sum(a['base'] for a in aa)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    if sched == 'pull':
        m = A.Sim(defs, ofn, T, seed, sched='pull', mirror=False).run()
    elif sched == 'ewma':
        m = A.Sim(defs, ofn, T, seed, sched='ewma', mirror=False).run()
    elif sched == 'oracle':
        m = A.Sim(defs, ofn, T, seed, sched='oracle', mirror=False).run()
    else:
        # sched = 'Dsteady:r' or 'Dspotty:r'
        tag, r = sched.split(':'); r = float(r)
        can = (tag == 'Dspotty')
        m = R.SimD(defs, ofn, T, seed, sched='D', reserve_frac=r,
                   spotty_can_host=can).run()
    return (kind, load, sched, {k: m.get(k, 0.0) for k in ('gp', 'loss', 'p99', 'res_tx', 'armed_frac')})

def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    scheds = ['pull', 'ewma', 'oracle',
              'Dsteady:0.15', 'Dsteady:0.30',
              'Dspotty:0.15', 'Dspotty:0.30']
    tasks = [(k, L, s, sd) for k in ('corr', 'indep') for L in LOADS
             for s in scheds for sd in range(SEEDS)]
    acc = {}
    with ProcessPoolExecutor(max_workers=14) as ex:
        for (k, L, s, m) in ex.map(work, tasks, chunksize=4):
            acc.setdefault((k, L, s), []).append(m)
    def agg(k, L, s, key): return med([d[key] for d in acc[(k, L, s)]])
    print('#' * 96)
    print('# ALL-SPOTTY N=3 (no steady host).  MID-drop.  Dsteady=steady-only hosts (no-op here),')
    print('#   Dspotty=allow a momentarily-healthy spotty path to host a stalled sibling.  seeds=%d' % SEEDS)
    print('#' * 96)
    for k in ('corr', 'indep'):
        print('=' * 96)
        print('all-spotty %s' % ('CORRELATED (shared stalls)' if k == 'corr' else 'INDEPENDENT (staggered stalls)'))
        print('=' * 96)
        print('  %-14s | %-24s %-24s' % ('sched', 'load=0.60 gp/loss/p99', 'load=0.85 gp/loss/p99'))
        for s in scheds:
            cells = []
            for L in LOADS:
                cells.append('%6.0f/%4.1f/%3.0f (arm%.2f)' % (
                    agg(k, L, s, 'gp'), agg(k, L, s, 'loss'), agg(k, L, s, 'p99'),
                    agg(k, L, s, 'armed_frac')))
            print('  %-14s | %-28s %-28s' % (s, cells[0], cells[1]))
        print()

if __name__ == '__main__':
    main()
