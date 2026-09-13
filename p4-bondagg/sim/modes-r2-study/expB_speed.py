#!/usr/bin/env python3
# expB: the `speed` active-set ladder — latency vs capacity per latency-ranked
# subset, on pull, edge rig. Plus expC: lat_bias (latency-ordered draw) ablation.
import sys, time
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import ackclock_sim as A
from holdlib import late_gaps, score, dyn_release, pct, med

T = 9.0; SEEDS = 6
t0 = time.time()

SETS = {
    'S1 eth':            [RC.eth()],
    'S2 eth+wifi':       [RC.eth(), RC.wifi()],
    'S3 eth+wifi+cellA': [RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)],
    'S4 cellA+B+C':      [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C)],
}
LOADS = [20000, 60000, 90000, 115000, 140000]
CAP = {'S1 eth': 78000, 'S2 eth+wifi': 123000, 'S3 eth+wifi+cellA': 152000,
       'S4 cellA+B+C': 68000}

print("set / load: gp loss%% | legacy-hold p50/p95 | dyn(q.99,W3) p50/p95 hold_med | gap p99/max")
for name, archs in SETS.items():
    defs = RC.build_rig(archs, bottleneck='edge')
    for L in LOADS:
        if L > 1.05 * CAP[name]: continue
        if name == 'S4 cellA+B+C' and L > 60000: continue
        of = lambda t, _L=L: float(_L)
        cols = {k: [] for k in ('gp','loss','lp50','lp95','dp50','dp95','dh','g99','gmx','late_d')}
        for sd in range(SEEDS):
            sim = A.Sim(defs, of, T, sd, sched='pull', mirror=False)
            r = sim.run()
            cols['gp'].append(r['gp']); cols['loss'].append(r['loss'])
            cols['lp50'].append(r['p50']); cols['lp95'].append(r['p95'])
            d = dyn_release(sim.arr, sim.enq, 0.99, 3.0)
            cols['dp50'].append(d['p50']); cols['dp95'].append(d['p95'])
            cols['dh'].append(d['hold_med']); cols['late_d'].append(d['late'])
            g = sorted(late_gaps(sim.arr))
            cols['g99'].append(pct(g,.99) if g else 0.0)
            cols['gmx'].append(g[-1] if g else 0.0)
        print("%-19s %6d: gp=%6.0f loss=%5.2f | leg %5.0f/%5.0f | dyn %5.0f/%5.0f h=%4.0f late=%4.1f | gap99=%5.1f max=%6.1f  (%.0fs)"
              % (name, L, med(cols['gp']), med(cols['loss']),
                 med(cols['lp50']), med(cols['lp95']),
                 med(cols['dp50']), med(cols['dp95']), med(cols['dh']), med(cols['late_d']),
                 med(cols['g99']), med(cols['gmx']), time.time()-t0))

# ---- expC: latency-ordered draw vs hungriest-first (pull, S3, edge) --------
print("\nexpC: lat_bias ablation, S3 edge, pull")
defs = RC.build_rig(SETS['S3 eth+wifi+cellA'], bottleneck='edge')
for L in (100000, 140000):
    for lb in (False, True):
        of = lambda t, _L=L: float(_L)
        g_, gp_, p95_, dp95_ = [], [], [], []
        for sd in range(8):
            sim = A.Sim(defs, of, T, sd, sched='pull', mirror=False, lat_bias=lb)
            r = sim.run()
            gp_.append(r['gp']); p95_.append(r['p95'])
            d = dyn_release(sim.arr, sim.enq, 0.99, 3.0)
            dp95_.append(d['p95'])
            g = sorted(late_gaps(sim.arr)); g_.append(pct(g,.99) if g else 0.0)
        print("  load=%6d lat_bias=%-5s gp=%6.0f p95(leg)=%5.0f p95(dyn)=%5.0f gap99=%5.1f"
              % (L, lb, med(gp_), med(p95_), med(dp95_), med(g_)))
print("total %.0fs" % (time.time()-t0))
