#!/usr/bin/env python3
# Paired per-seed Dc-vs-ewma loss breakdown at 0.85/0.95 -- sanity-check
# whether the 0.85/0.95 median overshoot (Dc loss > ewma+0.5pt) is a robust
# signal or seed noise, before reporting a FAIL verdict on that bar.
import sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_composite as RC
import ackclock_sim as A

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

T = 9.0; SEEDS = 24
archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)

for load in (0.85, 0.95):
    of = lambda t, _n=nom, _L=load: _L * _n
    dcl = []; ewl = []; diff = []
    for sd in range(SEEDS):
        dc = RC.SimD(defs, of, T, sd, sched='Dc').run()['loss']
        ew = A.Sim(defs, of, T, sd, sched='ewma', mirror=False).run()['loss']
        dcl.append(dc); ewl.append(ew); diff.append(dc - ew)
    print("=" * 90)
    print("load=%.2f  (Dc loss - ewma loss) per seed, pts:" % load)
    print("  " + "  ".join("%+.2f" % d for d in diff))
    print("  Dc loss median=%.3f%%  ewma loss median=%.3f%%  diff-of-medians=%.3f pts" %
          (med(dcl), med(ewl), med(dcl) - med(ewl)))
    print("  median-of-paired-diffs=%.3f pts   mean-of-paired-diffs=%.3f pts" %
          (med(diff), sum(diff) / len(diff)))
    over = sum(1 for d in diff if d > 0.5)
    print("  seeds with (Dc-ewma) > 0.5pt : %d / %d" % (over, SEEDS))
    print("  min diff=%.3f  max diff=%.3f" % (min(diff), max(diff)))
