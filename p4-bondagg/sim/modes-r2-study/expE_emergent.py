#!/usr/bin/env python3
# expE: is `speed` = pull + latency-ordered draw (lat_bias), with the active set
# EMERGENT (no admission machinery)? Measures per-source share, gap census,
# latency and gp across the load ladder, V0 (hungriest) vs V1 (lat-ordered).
import sys, time
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import ackclock_sim as A
from holdlib import late_gaps, score, pct, med

T = 9.0; SEEDS = 6
t0 = time.time()

RIGS = {
    'S3 eth+wifi+cellA': ([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)],
                          [30000, 60000, 90000, 115000, 140000]),
    'S4 cellA+B+C':      ([RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C)],
                          [15000, 30000, 50000]),
}
print("rig/load V: gp loss%% p50/p95 | share per source | ngaps gap99 gapmax | late@bestfix")
for rig, (archs, loads) in RIGS.items():
    defs = RC.build_rig(archs, bottleneck='edge')
    for L in loads:
        for lb in (False, True):
            of = lambda t, _L=L: float(_L)
            c = {k: [] for k in ('gp','loss','p50','p95','sh','ng','g99','gmx','late')}
            for sd in range(SEEDS):
                sim = A.Sim(defs, of, T, sd, sched='pull', mirror=False, lat_bias=lb)
                r = sim.run()
                c['gp'].append(r['gp']); c['loss'].append(r['loss'])
                tot = sum(sim.assigned) or 1
                c['sh'].append([a/tot for a in sim.assigned])
                g = sorted(late_gaps(sim.arr))
                c['ng'].append(len(g))
                c['g99'].append(pct(g,.99) if g else 0.0)
                c['gmx'].append(g[-1] if g else 0.0)
                # latency scored with the gap-derived hold this run would ratchet to
                h = max(0.010, (g[-1] if g else 0.0)/1000.0)
                sc = score(sim.arr, sim.enq, h)
                c['p50'].append(sc['p50']); c['p95'].append(sc['p95']); c['late'].append(sc['late'])
            sh = [med([s[i] for s in c['sh']]) for i in range(len(archs))]
            print("%-18s %6d %s: gp=%6.0f loss=%5.2f p50=%4.0f p95=%4.0f | sh=%s | ng=%5.0f g99=%5.1f gmx=%5.1f late=%5.1f (%.0fs)"
                  % (rig, L, 'V1' if lb else 'V0', med(c['gp']), med(c['loss']),
                     med(c['p50']), med(c['p95']),
                     "/".join("%.2f" % x for x in sh),
                     med(c['ng']), med(c['g99']), med(c['gmx']), med(c['late']),
                     time.time()-t0))
print("total %.0fs" % (time.time()-t0))
