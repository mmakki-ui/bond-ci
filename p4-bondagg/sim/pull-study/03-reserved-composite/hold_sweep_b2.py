#!/usr/bin/env python3
# =============================================================================
# hold_sweep_b2.py -- U13 round 2, blocker B2.  IS THE HOLD BAR A GATE AT ALL?
#
# A bar is only a gate if it MOVES over the range a real regression would occupy.
# Round 1's B6b was `late(hold in force) < late(ring.go's 10ms floor)`.  This
# sweeps the hold in force over {0,10,20,30,40,60,80,100,130,175,250,350,500} ms
# on every one of the 18 (mix, load) cells x SEEDS seeds and prints, per cell:
#   * median late-discard at each hold, plus the ratchet, the patient hold
#     (T, discards nothing) and the formula's own value;
#   * B6b's verdict at each hold;
#   * the RECOVERY RATIO (late(floor)-late(h))/(late(floor)-late(patient)), which
#     is the continuous quantity the verdict is a threshold on.
#
# RESULT (hold_sweep_b2.txt, SEEDS=6): B6b flips between 10ms and 20ms and prints
# PASS on 18/18 cells for EVERY hold from 20ms to 500ms, while the recovery ratio
# moves from 0.25 to 0.98 across that same range.  The shipped clamp is [80,350]ms.
# So the bar tolerated a 4x-17x shortening of the hold -- ~50x tolerance -- and was
# blind to it.  That measurement is why B6a and B6b were re-derived; see the U13
# round-2 block in highn_battery.py.
#
# This is a RESEARCH ARTIFACT, not a CI gate.  Nothing runs it in CI.
# Run:  SEEDS=6 WORKERS=$(nproc) python -u hold_sweep_b2.py > hold_sweep_b2.txt
# from 03-reserved-composite.
# =============================================================================
import os, sys, time
sys.path.insert(0, '.')
sys.path.insert(0, '../..')
from concurrent.futures import ProcessPoolExecutor
import highn_battery as H
import reserved_composite as RC

SEEDS = int(os.environ.get('SEEDS', '6'))
WORKERS = int(os.environ.get('WORKERS', '8'))
T = 9.0

# The realistic regression range: the shipped clamp is [80ms, 350ms] in the rig
# and [150, 350] in Go. 0 = no hold at all; 10ms = the ring floor.
GRID = [0.0, 0.010, 0.020, 0.030, 0.040, 0.060, 0.080, 0.100,
        0.130, 0.175, 0.250, 0.350, 0.500]


def task(t):
    si, archs, load, seed = t
    defs = RC.build_rig(archs, bottleneck='mid')
    nom = sum(a['base'] for a in archs)
    o = H.make_sim(defs, (lambda tt, _n=nom, _L=load: _L * _n), T, seed, 'Dc')
    m = o.run()
    out = {}
    for h in GRID:
        out[h] = H.hold_score(o, H.FixedHold(h), None)['late']
    out['ratchet'] = H.hold_score(o, H.LatenessRatchet(), None)['late']
    out['patient'] = H.hold_score(o, H.FixedHold(T), None)['late']
    out['formula'] = H.formula_hold(o)
    out['f_late'] = H.hold_score(o, H.FixedHold(out['formula']), None)['late']
    return (si, load, seed, out)


def main():
    scen = H.SCENARIOS()
    tasks = [(si, archs, L, sd)
             for si, (t_, archs, c_) in enumerate(scen)
             for L in H.LOADS for sd in range(SEEDS)]
    res = {}
    t0 = time.time()
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, L, sd, out) in ex.map(task, tasks, chunksize=1):
            res.setdefault((si, L), []).append(out)
            done += 1
            print('  ..%d/%d %.0fs' % (done, len(tasks), time.time() - t0),
                  file=sys.stderr)
    med = H.med
    print('SEEDS=%d  cells=%d' % (SEEDS, len(res)))
    hdr = 'cell'.ljust(46) + ''.join(('%7s' % ('%.0f' % (h * 1000))) for h in GRID)
    print(hdr + '%8s%8s%8s' % ('ratch', 'patient', 'formula'))
    for si, (title, archs, c_) in enumerate(scen):
        for L in H.LOADS:
            b = res[(si, L)]
            row = ('%s @%.2f' % (title[:38], L)).ljust(46)
            row += ''.join('%7d' % med([x[h] for x in b]) for h in GRID)
            row += '%8d%8d%8d' % (med([x['ratchet'] for x in b]),
                                  med([x['patient'] for x in b]),
                                  med([x['f_late'] for x in b]))
            print(row)
    # ---- bar verdicts as a function of the hold in force ----
    print()
    print('B6b  med(late(h) - late(floor=10ms)) < 0   -- PASS=P FAIL=F')
    print('cell'.ljust(46) + ''.join('%7s' % ('%.0f' % (h * 1000)) for h in GRID))
    for si, (title, archs, c_) in enumerate(scen):
        for L in H.LOADS:
            b = res[(si, L)]
            row = ('%s @%.2f' % (title[:38], L)).ljust(46)
            for h in GRID:
                v = med([x[h] - x[0.010] for x in b])
                row += '%7s' % ('P' if v < 0 else 'F')
            print(row)
    print()
    print('CANDIDATE: RECOVERY RATIO  rec(h) = (late(floor) - late(h)) / (late(floor) - late(patient))')
    print('cell'.ljust(46) + ''.join('%7s' % ('%.0f' % (h * 1000)) for h in GRID)
          + '%8s' % 'ratch')
    for si, (title, archs, c_) in enumerate(scen):
        for L in H.LOADS:
            b = res[(si, L)]
            row = ('%s @%.2f' % (title[:38], L)).ljust(46)

            def rec(key):
                vs = []
                for x in b:
                    den = x[0.010] - x['patient']
                    if den <= 0:
                        continue
                    vs.append((x[0.010] - x[key]) / den)
                return med(vs) if vs else float('nan')
            for h in GRID:
                row += '%7.3f' % rec(h)
            row += '%8.3f' % rec('ratchet')
            print(row)


if __name__ == '__main__':
    main()
