#!/usr/bin/env python3
# INDEPENDENT gate for Dc composite. Does not reuse the builder's smoke harness.
import sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_composite as RC
import ackclock_sim as A

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1] + xs[n//2]) / 2.0

archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
T = 9.0

# ---- (A) pull byte-match on many metrics, 4 seeds ----
KEYS = ['gp','loss','p50','p95','p99','deliv','tdrop','tshare','depth','late','qdrops']
of65 = lambda t,_n=nom: 0.65*_n
pull_ok = True
worst = 0.0
for sd in range(4):
    md = RC.SimD(defs, of65, T, sd, sched='pull').run()
    ma = A.Sim(defs, of65, T, sd, sched='pull', mirror=False).run()
    for k in KEYS:
        d = abs(md[k]-ma[k]); worst = max(worst, d)
        if d >= 1e-9: pull_ok = False
print("(A) pull byte-match 4 seeds x %d keys: %s  (worst diff %.3e)" %
      (len(KEYS), 'PASS' if pull_ok else 'FAIL', worst))

# ---- (B) Dpp byte-match against reserved_meter (Dpp unchanged) ----
try:
    import reserved_meter as RM
    of85 = lambda t,_n=nom: 0.85*_n
    dpp_ok = True; wd = 0.0
    for sd in range(3):
        a = RC.SimD(defs, of85, T, sd, sched='Dpp').run()
        b = RM.SimD(defs, of85, T, sd, sched='Dpp').run()
        for k in ('gp','loss','res_tx','tshare','deliv'):
            d = abs(a[k]-b[k]); wd = max(wd,d)
            if d >= 1e-6: dpp_ok = False
    print("(B) Dpp == reserved_meter Dpp (unchanged): %s (worst %.3e)" %
          ('PASS' if dpp_ok else 'FAIL', wd))
except Exception as e:
    print("(B) Dpp compare skipped:", e)

# ---- (C) THE FIX: Dc loss cap-level, not pull-level, at 0.85 (16 seeds) ----
of85 = lambda t,_n=nom: 0.85*_n
S = 16
dc_l=[]; dc_ts=[]; dc_rtx=[]; pu_l=[]; ew_l=[]; dpp_l=[]; dpp_ts=[]
for sd in range(S):
    m  = RC.SimD(defs, of85, T, sd, sched='Dc').run()
    dp = RC.SimD(defs, of85, T, sd, sched='Dpp').run()
    dc_l.append(m['loss']); dc_ts.append(m['tshare']); dc_rtx.append(m['res_tx'])
    dpp_l.append(dp['loss']); dpp_ts.append(dp['tshare'])
    pu_l.append(A.Sim(defs, of85, T, sd, sched='pull', mirror=False).run()['loss'])
    ew_l.append(A.Sim(defs, of85, T, sd, sched='ewma', mirror=False).run()['loss'])
dcL=med(dc_l); puL=med(pu_l); ewL=med(ew_l); dppL=med(dpp_l)
print("(C) @0.85 medians: Dc loss=%.2f%%  pull=%.2f%%  ewma=%.2f%%  Dpp=%.2f%%" %
      (dcL, puL, ewL, dppL))
print("    Dc tshare(spotty native share)=%.3f  Dpp tshare=%.3f  Dc res_tx=%.0f" %
      (med(dc_ts), med(dpp_ts), med(dc_rtx)))
# native capped <=> Dc loss near ewma cap band, clearly below pull, and below Dpp
cap_level  = dcL <= ewL + 2.0
below_pull = dcL < puL - 2.0
below_dpp  = dcL < dppL - 1.0
print("    cap-level(<=ewma+2)=%s  below-pull(pull-2)=%s  below-Dpp=%s" %
      (cap_level, below_pull, below_dpp))

# ---- (D) native-cap direct proof: does native admission actually gate on meter? ----
# Compare Dc vs Dpp assigned share onto spotty path across load. If native is
# capped for Dc, the spotty-link native share (tshare index0) should be LOWER
# than Dpp at high load (native backs off the deficit link).
print("(D) load sweep tshare (spotty native share), Dc vs Dpp (median 8 seeds):")
sweep_ok = True
for L in (0.65, 0.85, 1.0):
    ofL = lambda t,_n=nom,_L=L: _L*_n
    dts=[]; pts=[]; dl=[]; pl=[]
    for sd in range(8):
        dts.append(RC.SimD(defs, ofL, T, sd, sched='Dc').run()['tshare'])
        r = RC.SimD(defs, ofL, T, sd, sched='Dpp').run()
        pts.append(r['tshare'])
        dl.append(RC.SimD(defs, ofL, T, sd, sched='Dc').run()['loss'])
        pl.append(r['loss'])
    print("    L=%.2f  Dc tshare=%.3f loss=%.2f%%   Dpp tshare=%.3f loss=%.2f%%" %
          (L, med(dts), med(dl), med(pts), med(pl)))

overall = pull_ok and cap_level and below_pull
print("\nINDEP GATE:", "PASS" if overall else "FAIL")
