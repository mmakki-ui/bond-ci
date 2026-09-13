#!/usr/bin/env python3
# =============================================================================
# measure_dc_tshare_timeline.py -- WITHIN-RUN temporal tshare timeline for
#   Dc/Dpp/ewma at N2 MID (cellA+eth), load=0.95 (also 0.85 for context).
#
# The per-load REPORT in measure_dc_n2mid.py uses SimD.finalize()['tshare'],
# a SINGLE cumulative ratio over the whole T=9s run -- it cannot show whether
# tshare WALKS over time within one run (the "23%->58% eviction-spiral" the
# task asks to watch for). This script reconstructs the INCREMENTAL, windowed
# tshare via REPEATED TRUNCATED RUNS at the SAME seed: SimD.run(..., T=t) for
# t=1..9s is bit-identical up to min(t) ticks for a fixed seed (rng draws,
# offer_fn(now) and every gate depend only on 'now' and the seeded RNG stream,
# never on T itself -- T only bounds the tick loop), so s.assigned (the RAW,
# cumulative per-path wire-send counters SimD/Sim already track, UNMODIFIED)
# at T=t2 minus at T=t1 gives the EXACT native+dup sends in window [t1,t2).
# ZERO changes to reserved_composite.py / ackclock_sim.py -- pure post-hoc
# read of existing public instance state, same technique p7_transition.py
# uses to bin s.enq/s.arr. Pooled (summed) across seeds per window, not
# median-of-ratios, for stable small-window counts.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

import reserved_composite as RC
import ackclock_sim as A

SEEDS = 12
WIN = 1.0                 # 1.0s windows
# truncated-T checkpoints (s). First checkpoint is > s.warm(=1.0s) so
# finalize()'s Teff = T - warm never hits 0 (ZeroDivisionError at T==warm).
CKPTS = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]
LOADS = [0.85, 0.95]
SCHEDS = [('Dc', 'SimD'), ('Dpp', 'SimD'), ('ewma', 'Sim')]

archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)

def assigned_at(sch, kind, of, t, seed):
    if kind == 'SimD':
        obj = RC.SimD(defs, of, t, seed, sched=sch)
    else:
        obj = A.Sim(defs, of, t, seed, sched=sch, mirror=False)
    obj.run()
    return list(obj.assigned)   # [spotty(index0), eth(index1)]

t0 = time.time()
print("=" * 100)
print("TSHARE TIMELINE (within-run, TRUNCATED-T reconstruction) -- N2 MID cellA+eth")
print("windows=%.1fs  checkpoints(s)=%s  seeds=%d  (pooled counts per window)" %
      (WIN, CKPTS, SEEDS))
print("=" * 100)

for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    print()
    print("-" * 100)
    print("load=%.2f  offered=%.0f kb/s" % (load, load * nom))
    print("-" * 100)
    series = {}   # sch -> list of window tshare (pooled)
    for sch, kind in SCHEDS:
        # per-seed cumulative assigned[] at every checkpoint
        cum = {sd: [] for sd in range(SEEDS)}
        for sd in range(SEEDS):
            for t in CKPTS:
                cum[sd].append(assigned_at(sch, kind, of, t, sd))
        win_ts = []
        for wi in range(len(CKPTS)):
            a0 = 0; asum = 0
            for sd in range(SEEDS):
                prev = cum[sd][wi - 1] if wi > 0 else [0, 0]
                cur = cum[sd][wi]
                d0 = cur[0] - prev[0]; dsum = (cur[0] + cur[1]) - (prev[0] + prev[1])
                a0 += d0; asum += dsum
            win_ts.append(a0 / asum if asum else 0.0)
        series[sch] = win_ts
        print("  %-6s :" % sch, end=" ")
        for wi, t in enumerate(CKPTS):
            print("[%.1f-%.1fs]%.3f" % (t - WIN, t, win_ts[wi]), end="  ")
        print()
    # walk summary per scheduler at this load
    print()
    for sch, _ in SCHEDS:
        s = series[sch]
        print("  %-6s walk (max-min over windows) = %.3f (%.1f pts)   min=%.3f max=%.3f  first=%.3f last=%.3f" %
              (sch, max(s) - min(s), (max(s) - min(s)) * 100, min(s), max(s), s[0], s[-1]))

print()
print("=" * 100)
print("elapsed %.1fs" % (time.time() - t0))
