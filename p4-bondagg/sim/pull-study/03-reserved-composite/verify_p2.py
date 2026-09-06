#!/usr/bin/env python3
# Independent P2 reproduction (adversarial verify). EXACT n2mid design rig,
# loads restricted to {0.65, 0.85}. Canonical import path: reserved_meter sched='Dpp'.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM
import ackclock_sim as A

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

T = 9.0; SEEDS = 24
LOADS = [0.65, 0.85]
SCHEDS = ['Dpp', 'pull', 'ewma', 'oracle']

archs = [RM.cellA(RM.DROPS_A), RM.eth()]
defs = RM.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
print("rig: N2 MID = 1 cellA(DROPS_A) + 1 eth ; nominal_agg=%d ; T=%.1f SEEDS=%d" % (nom, T, SEEDS))

t0 = time.time()
res = {}
for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    for sch in SCHEDS:
        gp=[]; loss=[]; rtx=[]; mof=[]
        for sd in range(SEEDS):
            if sch == 'Dpp':
                m = RM.SimD(defs, of, T, sd, sched='Dpp').run()
                rtx.append(m['res_tx']); mof.append(m['mir_off'])
            else:
                m = A.Sim(defs, of, T, sd, sched=sch, mirror=False).run()
            gp.append(m['gp']); loss.append(m['loss'])
        res[(load,sch)] = dict(gp=med(gp), loss=med(loss),
                               rtx=med(rtx) if rtx else None,
                               mof=med(mof) if mof else None)

print("\n%-6s %-7s %9s %7s %10s %10s" % ('load','sched','gp','loss%','res_tx','mir_off'))
print('-'*55)
for load in LOADS:
    for sch in SCHEDS:
        r=res[(load,sch)]
        rt = ('%10.0f'%r['rtx']) if r['rtx'] is not None else '%10s'%'-'
        mo = ('%10.0f'%r['mof']) if r['mof'] is not None else '%10s'%'-'
        print("%-6.2f %-7s %9.0f %7.2f %s %s" % (load,sch,r['gp'],r['loss'],rt,mo))
    print()

# P2 decision (thresholds from measure_dpp_n2mid.py + task)
g=lambda l,s,k: res[(l,s)][k]
rtx65=g(0.65,'Dpp','rtx'); rtx85=g(0.85,'Dpp','rtx'); mof85=g(0.85,'Dpp','mof')
p2_gp   = g(0.85,'Dpp','gp')   >= 83400
p2_loss = g(0.85,'Dpp','loss') <= 7.5
p2_rtx_abs = rtx85 <= 2000.0
p2_rtx_rel = (rtx85 <= 0.10*rtx65) if rtx65>0 else (rtx85==0)
print("P2  0.85 gp=%.0f (>=83400:%s)  loss=%.2f (<=7.5:%s)" %
      (g(0.85,'Dpp','gp'),p2_gp, g(0.85,'Dpp','loss'),p2_loss))
print("    res_tx0.65=%.0f res_tx0.85=%.0f mir_off0.85=%.0f" % (rtx65,rtx85,mof85))
print("    res_tx0.85<=~2000 abs:%s   res_tx0.85<=10%%*0.65[%.0f]:%s" %
      (p2_rtx_abs, 0.10*rtx65, p2_rtx_rel))
print("    admit/nominate ratio @0.85 = res_tx/mir_off = %.3f" % (rtx85/mof85 if mof85 else 0))
print("P2 OVERALL (gp AND loss AND res_tx<=2000 abs): %s" %
      ('PASS' if (p2_gp and p2_loss and p2_rtx_abs) else 'FAIL'))
print("elapsed %.1fs" % (time.time()-t0))
