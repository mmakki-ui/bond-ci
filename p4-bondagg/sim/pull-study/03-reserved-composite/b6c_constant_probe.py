#!/usr/bin/env python3
# =============================================================================
# b6c_constant_probe.py -- U13 round 3.  THE ARTIFACT BEHIND TWO CORRECTED
# CLAIMS, and the demonstration that B6c closes the hole B6a left open.
#
# WHY THIS EXISTS.  Round 2 wrote, in hold.go, in highn_battery.py and in
# ROADMAP.md, "as it stands B6 would score a hold of ten seconds as an
# improvement".  That sentence was never run.  Measured, it is FALSE and wrong in
# the SAFE direction: a 10s constant trips `B6-CTRL subst B6a force := patient(T)`
# (10s > T = 9.0s) and the job exits 1.  What was actually true, and what nobody
# had written down or bounded, is the interval BELOW T -- and an independent
# verify demonstrated it with a 3-SECOND constant hold that passed the whole gate
# with a byte-identical baseline fail set while making ZERO observations.
#
# WHAT THIS MEASURES, on the same Dc traces the battery scores:
#   (1) For each constant hold c, substituted for the ratchet: does B6a alone
#       pass?  B6a is `med(late(ratchet) - late(hold in force)) < 0`, so a longer
#       hold wins it by discarding fewer arrived frames.  This prints the blind
#       spot as a table instead of as an adjective.
#   (2) For the same c: does B6c pass?  B6c is (c1) the hold must have been
#       RAISED by an observation at least once, and (c2) it must not exceed the
#       largest lateness the trace ACTUALLY EXHIBITED.  A constant raises nothing,
#       so c1 kills every constant at every length -- the whole class, not a range.
#   (3) The derived hold itself, on the same rows, so the bar is not just
#       rejecting things: it must PASS what ships.
#
# NOT A GATE.  The gated version of (2) is in highn_battery.py and runs on every
# battery run, including the four `subst B6c ratchet := ...` CTRL limbs.  This
# file is the sweep that sized the problem; its output is b6c_constant_probe.txt.
#
# RUN:  SEEDS=3 T=9.0 RIG=mid PYTHONHASHSEED=0 WORKERS=8 \
#         PYTHONPATH=../../.. python b6c_constant_probe.py
# =============================================================================
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import highn_battery as HB
import reserved_composite as RC

CONSTS = [0.02, 0.08, 0.15, 0.25, 0.35, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0]
LOADS = HB.LOADS


def work(task):
    """One (scenario, load, seed) Dc run, re-released under every constant hold
    and under the derived hold, all on the SAME trace."""
    (si, archs, L, seed) = task
    defs = RC.build_rig(archs, bottleneck=HB.RIG)
    nom = sum(a['base'] for a in archs)
    o = RC.SimD(defs, (lambda t, _n=nom, _L=L: _L * _n), HB.T, seed, sched='Dc')
    o.run()
    h = HB.formula_hold(o)
    out = {'hold_f': h}
    out['f_late'] = HB.hold_score(o, HB.FixedHold(h), None)['late']
    wit = HB.LatenessWitness()
    r = HB.hold_score(o, HB.LatenessRatchet(), None, wit)
    out['r_late'] = r['late']
    out['r_hold'] = r['hold']
    out['r_raises'] = r['raises']
    out['wmax'] = r['wmax']
    for c in CONSTS:
        s = HB.hold_score(o, HB.FixedHold(c), None)
        out['c%.2f' % c] = (s['late'], s['raises'], s['p50'], s['p95'])
    # (4) The ROUND-2 SHIPPED RULE, per cell, on the WINDOWED model -- the artifact
    #     behind the 8,213ms figure.  The battery gates this substitution but prints
    #     only the 18-cell median, so the per-cell spread lives here.
    ww = HB.LatenessWitness()
    rw = HB.hold_score(o, HB.LatenessRatchet(), HB.RING_WINDOW, ww)
    uw = HB.hold_score(o, HB.UnfilteredOldRatchet(), HB.RING_WINDOW)
    out['w_hold'] = rw['hold']
    out['w_wmax'] = rw['wmax']
    out['uf_hold'] = uw['hold']
    out['uf_obs'] = uw['obs']
    out['w_obs'] = rw['obs']
    return (si, L, seed, out)


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = HB.SCENARIOS()
    med = HB.med
    print('#' * 110)
    print('# B6c CONSTANT-HOLD PROBE  seeds=%d T=%.1fs rig=%s  (U13 round 3)'
          % (HB.SEEDS, HB.T, HB.RIG))
    print('# A CONSTANT hold substituted for the derived hold, swept.  B6a alone vs B6a+B6c.')
    print('#' * 110)
    tasks = [(si, scen[si][1], L, sd)
             for si in range(len(scen)) for L in LOADS for sd in range(HB.SEEDS)]
    t0 = time.time()
    res = {}
    with ProcessPoolExecutor(max_workers=HB.WORKERS) as ex:
        for (si, L, sd, out) in ex.map(work, tasks):
            res.setdefault((si, L), []).append(out)
    print('# %d runs in %.0fs' % (len(tasks), time.time() - t0))
    print('')
    print('B6a ALONE -- does a CONSTANT hold pass the bar the derived hold is gated on?')
    print('P = PASSES B6a (the gate would be green with a hold derived from nothing)')
    print('%-22s %s' % ('cell', '  '.join('%5.2fs' % c for c in CONSTS)))
    first_pass = {}
    for si in range(len(scen)):
        for L in LOADS:
            rs = res[(si, L)]
            row = []
            fp = None
            for c in CONSTS:
                pa = med([r['c%.2f' % c][0] - r['f_late'] for r in rs])
                ok = pa < 0.0
                row.append('P' if ok else '.')
                if ok and fp is None:
                    fp = c
            first_pass[(si, L)] = fp
            print('%-14s L=%.2f %s' % (scen[si][0].split()[0], L,
                                       '  '.join('%6s' % x for x in row)))
    print('')
    print('B6c -- the same substitutions, gated on the DERIVATION:')
    print('  c1 raises >= 1                       (a constant raises nothing)')
    print('  c2 hold <= max lateness the trace exhibited (measured per-seq by LatenessWitness)')
    print('%-22s %s' % ('cell', '  '.join('%5.2fs' % c for c in CONSTS)))
    n_pass_a = n_pass_c = n_cells = 0
    for si in range(len(scen)):
        for L in LOADS:
            rs = res[(si, L)]
            row = []
            for c in CONSTS:
                c1 = med([r['c%.2f' % c][1] for r in rs]) >= 1
                c2 = med([c - r['wmax'] for r in rs]) <= 0.0
                row.append('P' if (c1 and c2) else '.')
            print('%-14s L=%.2f %s' % (scen[si][0].split()[0], L,
                                       '  '.join('%6s' % x for x in row)))
            n_cells += 1
            n_pass_a += sum(1 for c in CONSTS
                            if med([r['c%.2f' % c][0] - r['f_late'] for r in rs]) < 0.0)
            n_pass_c += sum(1 for c in CONSTS
                            if med([r['c%.2f' % c][1] for r in rs]) >= 1
                            and med([c - r['wmax'] for r in rs]) <= 0.0)
    print('')
    print('TOTAL over %d cells x %d constants = %d substitutions:'
          % (n_cells, len(CONSTS), n_cells * len(CONSTS)))
    print('  pass B6a alone : %d   <- the hole an independent verify walked through'
          % n_pass_a)
    print('  pass B6a+B6c   : %d   <- the whole constant class is rejected at the derivation'
          % n_pass_c)
    print('')
    print('SMALLEST CONSTANT THAT PASSES B6a ALONE, per cell (the blind-spot edge):')
    for si in range(len(scen)):
        for L in LOADS:
            fp = first_pass[(si, L)]
            print('  %-14s L=%.2f  %s' % (scen[si][0].split()[0], L,
                                          ('%.2fs' % fp) if fp else 'none in the swept set'))
    print('')
    print('AND THE DERIVED HOLD ITSELF -- B6c must PASS what ships, or it is not a bar:')
    ok_all = True
    for si in range(len(scen)):
        for L in LOADS:
            rs = res[(si, L)]
            c1 = med([r['r_raises'] for r in rs]) >= 1
            c2 = med([r['r_hold'] - r['wmax'] for r in rs]) <= 0.0
            ok_all = ok_all and c1 and c2
            print('  %-14s L=%.2f  raises=%5d  hold=%6.0fms  max lateness=%6.0fms  -> %s'
                  % (scen[si][0].split()[0], L, med([r['r_raises'] for r in rs]),
                     1000 * med([r['r_hold'] for r in rs]),
                     1000 * med([r['wmax'] for r in rs]),
                     'PASS' if (c1 and c2) else 'FAIL'))
    print('')
    print('DERIVED HOLD PASSES B6c ON EVERY CELL: %s' % ('yes' if ok_all else 'NO'))
    print('')
    print('LATENCY COST OF THE 3s CONSTANT (the demonstrated attack), against the clamp')
    print('FLOOR (80ms, the shortest hold the formula can emit) on the same traces:')
    for si in range(len(scen)):
        for L in LOADS:
            rs = res[(si, L)]
            print('  %-14s L=%.2f  p50 %5.0f -> %5.0f ms   p95 %5.0f -> %5.0f ms'
                  % (scen[si][0].split()[0], L,
                     med([r['c0.08'][2] for r in rs]), med([r['c3.00'][2] for r in rs]),
                     med([r['c0.08'][3] for r in rs]), med([r['c3.00'][3] for r in rs])))
    print('')
    print('THE ROUND-2 SHIPPED RULE (no skipped-seq filter) ON THE WINDOWED MODEL --')
    print('per cell, the divergence that made hold.go learn a hold no lateness supported:')
    print('  %-14s %8s %10s %10s %8s %8s' % ('cell', 'load', 'filtered', 'UNFILTERED',
                                             'ratio', 'maxlate'))
    for si in range(len(scen)):
        for L in LOADS:
            rs = res[(si, L)]
            f = med([r['w_hold'] for r in rs])
            u = med([r['uf_hold'] for r in rs])
            print('  %-14s %8.2f %9.0fms %9.0fms %7.2fx %7.0fms'
                  % (scen[si][0].split()[0], L, 1000 * f, 1000 * u,
                     (u / f) if f > 0 else 0.0, 1000 * med([r['w_wmax'] for r in rs])))
    print('  filtered = what ships after round 3; UNFILTERED = what shipped in round 2.')
    print('  maxlate = the largest lateness the trace exhibited, per-seq (B6c c2 reference).')
    print('  A ratio of 1.00x is a cell whose load never overflows the 2^11 window: no')
    print('  flushTo, so the two rules observe the same events and ARE the same run.')
    print('')
    print('  None of that latency is asserted anywhere: there is no budget for `max` mode')
    print('  (OBJ-D / U14).  B6c rejects the 3s hold because nothing DERIVED it, not because')
    print('  of its cost -- the cost bar is still owed and is still open.')


if __name__ == '__main__':
    main()
