#!/usr/bin/env python3
# =============================================================================
# b4_geometry_estab.py -- U13 round 2, blocker B4.  IS B6a's TIGHTEST CELL
# GEOMETRY-ESTABLISHED, or is its verdict decided by the hand-placed stalls?
#
# U33 measured that the rig samples ONE stall geometry and that paired margins
# move ~1 pt across the rotation family, so any bar verdict resting on a margin
# below that is not established.  B6a's canonical margins run +65 .. +5664 frames;
# only N2-het@0.65 (+65 on 454) is small enough to be in doubt.
#
# RESULT (b4_geometry_estab.txt): NOT ESTABLISHED at load 0.65 --
# med(ratchet - force) spans [-192.5, +56.0] over 48 rotations, 10/48 of the WRONG
# SIGN.  Established at 0.85 and 0.95 (0/48, worst margin -1096), and B6b's new
# clamp-floor reference is established at all three loads (0/48, worst -3301).
# So N2-het@0.65 is REPORTED AND NOT GATED (B6A_UNESTABLISHED in highn_battery.py).
#
# RESEARCH ARTIFACT, not a CI gate.
# Run:  SEEDS=6 GEOM=48 WORKERS=$(nproc) python -u b4_geometry_estab.py #         > b4_geometry_estab.txt
# from 03-reserved-composite.
# =============================================================================
# B4: is B6a's TIGHTEST cell geometry-established?
# N2-het is the only cell whose paired margin (65 frames on 454) sits inside the
# ~1 pt / order-of-magnitude geometry noise floor U33 measured.  Re-run it over
# GEOM count- and duration-preserving stall-phase rotations (rig_checks.phase_drops,
# U33's corrected randomiser) x SEEDS jitter seeds x 3 loads and ask whether
# med(late(ratchet) - late(formula)) < 0 survives every geometry.
import os, sys, time
sys.path.insert(0, '.')
sys.path.insert(0, '../..')
from concurrent.futures import ProcessPoolExecutor
import highn_battery as H
import reserved_composite as RC
import rig_checks as RK

SEEDS = int(os.environ.get('SEEDS', '6'))
GEOM = int(os.environ.get('GEOM', '48'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T = 9.0
GEOM_SEED_BASE = 5000


def task(t):
    g, load, seed = t
    drops = RK.phase_drops('cellA', GEOM_SEED_BASE + g, T)
    archs = [RC.cellA(drops), RC.eth()]
    defs = RC.build_rig(archs, bottleneck='mid')
    nom = sum(a['base'] for a in archs)
    o = H.make_sim(defs, (lambda tt, _n=nom, _L=load: _L * _n), T, seed, 'Dc')
    o.run()
    h = H.formula_hold(o)
    f = H.hold_score(o, H.FixedHold(h), None)['late']
    r = H.hold_score(o, H.LatenessRatchet(), None)['late']
    c80 = H.hold_score(o, H.FixedHold(0.08), None)['late']
    return (g, load, seed, f, r, c80)


def main():
    tasks = [(g, L, sd) for g in range(GEOM) for L in H.LOADS
             for sd in range(SEEDS)]
    res = {}
    t0 = time.time()
    n = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (g, L, sd, f, r, c80) in ex.map(task, tasks, chunksize=2):
            res.setdefault((g, L), []).append((f, r, c80))
            n += 1
            if n % 50 == 0:
                print('  ..%d/%d %.0fs' % (n, len(tasks), time.time() - t0),
                      file=sys.stderr)
    med = H.med
    print('N2-het  cellA + eth   GEOM=%d rotations x SEEDS=%d jitter seeds x %d loads'
          ' = %d runs' % (GEOM, SEEDS, len(H.LOADS), len(tasks)))
    for L in H.LOADS:
        viol_a = viol_b = 0
        margins = []
        mb = []
        for g in range(GEOM):
            b = res[(g, L)]
            ma = med([r - f for (f, r, c) in b])         # B6a: want < 0
            mbb = med([f - c for (f, r, c) in b])        # B6b: want < 0
            margins.append(ma)
            mb.append(mbb)
            if not (ma < 0):
                viol_a += 1
            if not (mbb < 0):
                viol_b += 1
        margins.sort()
        mb.sort()
        print('  load=%.2f  B6a med(ratchet-force): min %+.1f  median %+.1f  max %+.1f'
              '  | violations %d/%d' % (L, margins[0], med(margins), margins[-1],
                                        viol_a, GEOM))
        print('            B6b med(force-clamp80): min %+.1f  median %+.1f  max %+.1f'
              '  | violations %d/%d' % (mb[0], med(mb), mb[-1], viol_b, GEOM))


if __name__ == '__main__':
    main()
