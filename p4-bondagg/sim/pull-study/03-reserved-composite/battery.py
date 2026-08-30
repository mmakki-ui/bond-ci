#!/usr/bin/env python3
# =============================================================================
# battery.py -- the full measurement battery for scheduler D (reserved-mirror),
# N-generic, vs pull / A(ewma-cap) / push / oracle / full-redundant, across N,
# source-mix, rig (EDGE / MID-drop / MID-shape) and reserve size r, at a SPARE
# load and a TIGHT load (the reserve rides spare, so load is the key axis).
# Physics = nsched_model (UNMODIFIED).  medians over SEEDS.  paired seeds.
# =============================================================================
import sys, math
import reserved_dp as R
import ackclock_sim as A

SEEDS = 8 if 'quick' in sys.argv else 24
T = 10.0
RS = [0.05, 0.15, 0.30]          # in-flight-scale -> mid -> full-stream(~redundant)
LOADS = [0.65, 0.85]             # spare / tight

MK = ['gp', 'loss', 'p50', 'p95', 'p99', 'tdrop', 'depth']

def runD(defs, ofn, sched='D', r=0.0, ttl=200.0):
    return A.agg([R.SimD(defs, ofn, T, sd, sched=sched, reserve_frac=r,
                         ttl_ms=ttl).run() for sd in range(SEEDS)])

def runRef(defs, ofn, sched):
    return A.agg([A.Sim(defs, ofn, T, sd, sched=sched, mirror=False).run()
                  for sd in range(SEEDS)])

def nomsum(archs):
    return sum(a['base'] for a in archs_of(archs))

def archs_of(archs):
    return archs

def scenario(title, archetypes, bottlenecks=('edge', 'mid', 'mid_shape')):
    """Print the full scheduler x rig x (load,r) table for one N-mix."""
    nom = sum(a['base'] for a in archetypes)
    nspot = sum(1 for a in archetypes if a['spotty'])
    print('=' * 118)
    print('%s   | N=%d  spotty=%d/%d  nominal_agg=%d kb/s'
          % (title, len(archetypes), nspot, len(archetypes), nom))
    print('=' * 118)
    for bn in bottlenecks:
        real_bn = 'mid' if bn == 'mid_shape' else bn
        shape = (bn == 'mid_shape')
        defs = build(archetypes, real_bn, shape)
        print('  --- rig: %-9s ---' % bn)
        print('    %-16s | %s' % ('', '   '.join('%-25s' % ('load=%.2f' % L) for L in LOADS)))
        hdr = '    %-16s | ' % 'scheduler'
        hdr += '   '.join('%7s %5s %4s %4s' % ('gp', 'loss', 'p95', 'p99') for L in LOADS)
        print(hdr)
        def rowvals(fn):
            cells = []
            for L in LOADS:
                ofn = (lambda t, _L=L: _L * nom)
                m = fn(defs, ofn)
                cells.append('%7.0f %5.1f %4.0f %4.0f' % (m['gp'], m['loss'], m['p95'], m['p99']))
            return '   '.join(cells)
        print('    %-16s | %s' % ('pull', rowvals(lambda d, o: runRef(d, o, 'pull'))))
        print('    %-16s | %s' % ('A(ewma-cap)', rowvals(lambda d, o: runRef(d, o, 'ewma'))))
        print('    %-16s | %s' % ('push', rowvals(lambda d, o: runRef(d, o, 'push'))))
        print('    %-16s | %s' % ('oracle', rowvals(lambda d, o: runRef(d, o, 'oracle'))))
        for r in RS:
            tag = 'D r=%.2f' % r
            print('    %-16s | %s' % (tag, rowvals(lambda d, o, _r=r: runD(d, o, 'D', _r))))
        print('    %-16s | %s' % ('redundant', rowvals(lambda d, o: runD(d, o, 'redundant'))))
        # D reserve diagnostics at the two loads (armed frac, mirror tx, aged)
        diag = []
        for L in LOADS:
            ofn = (lambda t, _L=L: _L * nom)
            m = runD(defs, ofn, 'D', 0.15)
            diag.append('armed=%.2f res_tx=%.0f aged=%.0f' % (m['armed_frac'], m['res_tx'], m['mir_aged']))
        print('    %-16s | %s' % ('  [D r=.15 diag]', '   '.join('%-25s' % d for d in diag)))
        print()


def build(archetypes, bn, shape=False):
    archs = []
    for a in archetypes:
        a = dict(a)
        if shape and a['spotty']:
            a['shape'] = 4000.0            # carrier throttle (never full outage)
        archs.append(a)
    return R.build_rig(archs, bottleneck=bn)


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    print('#' * 118)
    print('# SCHEDULER D (RESERVED-MIRROR, N-GENERIC) BATTERY   seeds=%d  T=%.0fs  medians  physics=nsched_model(unmodified)' % (SEEDS, T))
    print('#   references (pull/A=ewma-cap/push/oracle) = ackclock_sim.Sim mirror=False (identical two-stage physics)')
    print('#   D reserve r: 0.05 in-flight-scale | 0.15 mid | 0.30 ~full-stream.  loads: 0.65 spare | 0.85 tight')
    print('#' * 118)

    # 1. N=2  1 spotty + 1 steady
    scenario('N2  1 cell(spotty) + 1 eth(steady)',
             [R.cellA(R.DROPS_A), R.eth()])

    # 2. N=3  2 spotty + 1 steady
    scenario('N3  2 cell(spotty) + 1 eth(steady)',
             [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()])

    # 3. N=3  1 spotty + 2 steady
    scenario('N3  1 cell(spotty) + 1 wifi(steady) + 1 eth(steady)',
             [R.cellA(R.DROPS_A), R.wifi(), R.eth()])

    # 4. N=4 heterogeneous: 2 cell + 1 wifi + 1 eth
    scenario('N4  2 cell(spotty) + 1 wifi(steady) + 1 eth(steady) [heterogeneous]',
             [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.wifi(), R.eth()])

    # 5a. ALL-SPOTTY N=3 correlated (shared stall windows)
    scenario('N3  ALL-SPOTTY correlated (shared stall windows)',
             [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)])

    # 5b. ALL-SPOTTY N=3 independent (staggered stalls)
    scenario('N3  ALL-SPOTTY independent (staggered stalls)',
             [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)])

    # 6a. ALL-STEADY N=2 (no at-risk -> D must be a no-op)
    scenario('N2  ALL-STEADY (wifi + eth) -- no-op check',
             [R.wifi(), R.eth()])

    # 6b. ALL-STEADY N=3
    scenario('N3  ALL-STEADY (wifi + wifi2 + eth) -- no-op check',
             [R.wifi(), dict(R.wifi(), base=38000, period=3.7, phase=2.0), R.eth()])


if __name__ == '__main__':
    main()
