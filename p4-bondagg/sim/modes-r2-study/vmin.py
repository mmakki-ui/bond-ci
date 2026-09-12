#!/usr/bin/env python3
# MINIMAL independent check of ONE claim: at the edge, does hold LENGTH move latency?
# Scope: N2 edge rig, pull, load 0.85 only. Per-seed progress, unbuffered.
import sys, os, time
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
import reserved_composite as RC, ackclock_sim as A
from nsched_model import reorder_release
SEEDS = int(os.environ.get("SEEDS", "3"))
HOLDS = [40.0, 343.0]
archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck="edge")
nom = sum(a["base"] for a in archs)
of = lambda t: 0.85 * nom
def score(sim, h):
    items = [(a, s) for s, a in sim.arr.items() if a is not None]
    rel, skips, _ = reorder_release(items, h / 1000.0)
    keep = set(rel)
    late = sum(1 for (a, s) in items if s not in keep and sim.enq.get(s, 0) > sim.warm)
    lat = sorted((rt - sim.enq[s]) * 1000.0 for s, rt in rel.items() if sim.enq[s] > sim.warm)
    p = lambda q: lat[min(len(lat) - 1, int(q * (len(lat) - 1)))] if lat else 0.0
    return p(.5), p(.95), p(.99), late
print("seed  hold   p50    p95    p99   late", flush=True)
acc = {h: [] for h in HOLDS}
t0 = time.time()
for sd in range(SEEDS):
    sim = A.Sim(defs, of, 9.0, sd, sched="pull", mirror=False); sim.run()
    for h in HOLDS:
        r = score(sim, h); acc[h].append(r)
        print("%4d %5.0f %6.1f %6.1f %6.1f %6d   (%.0fs)" % (sd, h, r[0], r[1], r[2], r[3], time.time() - t0), flush=True)
print("\nMEDIANS over %d seeds" % SEEDS, flush=True)
med = lambda xs: sorted(xs)[len(xs) // 2]
for h in HOLDS:
    c = list(zip(*acc[h]))
    print("hold=%5.0f  p50=%6.1f p95=%6.1f p99=%6.1f late=%6d" %
          (h, med(c[0]), med(c[1]), med(c[2]), med(c[3])), flush=True)
