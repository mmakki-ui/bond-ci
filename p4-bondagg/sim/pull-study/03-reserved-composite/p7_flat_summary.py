#!/usr/bin/env python3
# Aggregate (whole-run) Dpp vs pull+cap at flat 0.65 and flat 0.85, N2 MID
# cellA+eth -- quantifies the standing (non-transient) gap the control run
# revealed, and reports res_tx/mir_off/armed_frac to see whether admission
# is actually self-shedding at flat 0.85 or staying elevated.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM
import ackclock_sim as A

SEEDS = 24
T = 18.0

archs = [RM.cellA(RM.DROPS_A), RM.eth()]
defs = RM.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

t0 = time.time()
for load in (0.65, 0.85):
    of = lambda t, _n=nom, _L=load: _L * _n
    gD=[]; lD=[]; afD=[]; rtx=[]; mo=[]; gP=[]; lP=[]
    for sd in range(SEEDS):
        mD = RM.SimD(defs, of, T, sd, sched='Dpp').run()
        mP = A.Sim(defs, of, T, sd, sched='ewma', mirror=False).run()
        gD.append(mD['gp']); lD.append(mD['loss']); afD.append(mD['armed_frac'])
        rtx.append(mD['res_tx']); mo.append(mD['mir_off'])
        gP.append(mP['gp']); lP.append(mP['loss'])
    print("load=%.2f | Dpp: gp=%7.0f loss=%6.2f%% armed_frac=%.3f res_tx(med)=%.0f mir_off(med)=%.0f "
          "|| pull+cap: gp=%7.0f loss=%6.2f%% || excess_loss=%+6.2f pct pts" %
          (load, med(gD), med(lD), med(afD), med(rtx), med(mo), med(gP), med(lP), med(lD)-med(lP)))
print("elapsed %.1fs" % (time.time()-t0))
