#!/usr/bin/env python3
# =============================================================================
# measure_dpp_n2mid.py -- D'' (sched='Dpp') measurement, N2 MID(hidden-downstream)
#   rig: 1 cellA (spotty) + 1 eth (steady host).
#
# Physics: reserved_meter.py (Dpp datapath, UNMODIFIED nsched_model physics) vs
#   ackclock_sim.Sim reference schedulers pull / ewma ('A', the shipped one-sided
#   delivered-rate cap) / oracle (unreachable upper bound), run with mirror=False
#   so the ONLY mirroring anywhere in the study is Dpp's meter-gated duplicate
#   (clean isolation -- matches confirm_falsify.py / validate_local.py convention).
#
# Instrumented: gp/loss/p50/p95/p99 (all schedulers) + res_tx = ADMITTED-DUPLICATE
#   frames (Dpp only; each frame == PKT_KB kb on the wire, so res_tx is the
#   ADMISSION metric per Fable's note -- nomination (mir_offered) may stay high,
#   what must drop is ADMISSION).
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

import reserved_meter as RM
import ackclock_sim as A

PKT_KB = RM.PKT_KB

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

T = 9.0
SEEDS = 24
LOADS = [0.55, 0.60, 0.65, 0.75, 0.85, 0.90]
SCHEDS = ['Dpp', 'pull', 'ewma', 'oracle']
METRICS = ['gp', 'loss', 'p50', 'p95', 'p99']

archs = [RM.cellA(RM.DROPS_A), RM.eth()]
defs = RM.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
print("rig: N2 MID(hidden-downstream) = 1 cellA(spotty, DROPS_A) + 1 eth(steady)")
print("nominal aggregate cap0 sum = %.0f kb/s ; T=%.1fs SEEDS=%d target_ms=40.0" % (nom, T, SEEDS))
print()

t0 = time.time()
results = {}   # (load, sched) -> dict of medians
for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    for sch in SCHEDS:
        vals = {m: [] for m in METRICS}
        rtx = []
        for sd in range(SEEDS):
            if sch == 'Dpp':
                m = RM.SimD(defs, of, T, sd, sched='Dpp').run()
                rtx.append(m['res_tx'])
            else:
                m = A.Sim(defs, of, T, sd, sched=sch, mirror=False).run()
            for k in METRICS:
                vals[k].append(m[k])
        row = {k: med(vals[k]) for k in METRICS}
        if sch == 'Dpp':
            row['res_tx'] = med(rtx)
        results[(load, sch)] = row

print("=" * 100)
print("REPORT -- Dpp vs pull / A(ewma cap) / oracle  (medians, %d seeds)" % SEEDS)
print("=" * 100)
hdr = "%-6s %-7s %9s %7s %7s %7s %7s %10s" % \
      ('load', 'sched', 'gp', 'loss%', 'p50ms', 'p95ms', 'p99ms', 'res_tx')
print(hdr)
print("-" * len(hdr))
for load in LOADS:
    for sch in SCHEDS:
        r = results[(load, sch)]
        rtx_s = ("%10.0f" % r['res_tx']) if sch == 'Dpp' else (" " * 10)
        print("%-6.2f %-7s %9.0f %7.2f %7.1f %7.1f %7.1f %10s" %
              (load, sch, r['gp'], r['loss'], r['p50'], r['p95'], r['p99'], rtx_s))
    print()

# =============================================================================
# PASS/FAIL bars
# =============================================================================
def g(load, sch, k):
    return results[(load, sch)][k]

print("=" * 100)
print("PASS/FAIL")
print("=" * 100)

# ---- P1 (win) ----
p1_55 = (g(0.55, 'Dpp', 'gp') >= 57000) and (g(0.55, 'Dpp', 'loss') <= 2.0)
p1_65 = (g(0.65, 'Dpp', 'gp') >= 66500) and (g(0.65, 'Dpp', 'loss') <= 3.0) \
        and (g(0.65, 'Dpp', 'p95') <= 100.0)
p1 = p1_55 and p1_65
print("P1 (win):")
print("  0.55  gp=%.0f (need>=57000) loss=%.2f%% (need<=2%%)                -> %s" %
      (g(0.55, 'Dpp', 'gp'), g(0.55, 'Dpp', 'loss'), 'PASS' if p1_55 else 'FAIL'))
print("  0.65  gp=%.0f (need>=66500) loss=%.2f%% (need<=3%%) p95=%.1f (need<=100) -> %s" %
      (g(0.65, 'Dpp', 'gp'), g(0.65, 'Dpp', 'loss'), g(0.65, 'Dpp', 'p95'), 'PASS' if p1_65 else 'FAIL'))
print("  P1 OVERALL: %s" % ('PASS' if p1 else 'FAIL'))
print()

# ---- P2 (collapse-gone) ----
rtx65 = g(0.65, 'Dpp', 'res_tx'); rtx85 = g(0.85, 'Dpp', 'res_tx')
p2_gp = g(0.85, 'Dpp', 'gp') >= 83400
p2_loss = g(0.85, 'Dpp', 'loss') <= 7.5
p2_rtx_abs = rtx85 <= 2000.0
p2_rtx_rel = rtx85 <= 0.10 * rtx65 if rtx65 > 0 else (rtx85 == 0)
p2 = p2_gp and p2_loss and p2_rtx_rel
print("P2 (collapse-gone):")
print("  0.85  gp=%.0f (need>=83400)  -> %s" % (g(0.85, 'Dpp', 'gp'), 'PASS' if p2_gp else 'FAIL'))
print("  0.85  loss=%.2f%% (need<=7.5%%) -> %s" % (g(0.85, 'Dpp', 'loss'), 'PASS' if p2_loss else 'FAIL'))
print("  res_tx(0.65)=%.0f  res_tx(0.85)=%.0f" % (rtx65, rtx85))
print("  res_tx(0.85)<=~2000 abs check -> %s" % ('PASS' if p2_rtx_abs else 'FAIL(informational)'))
print("  res_tx(0.85)<=10%% of res_tx(0.65) [%.1f]  -> %s" %
      (0.10 * rtx65, 'PASS' if p2_rtx_rel else 'FAIL'))
print("  P2 OVERALL (gp AND loss AND res_tx<=10%% of 0.65): %s" % ('PASS' if p2 else 'FAIL'))
print()

# ---- P3 (smooth knee) ----
print("P3 (smooth knee):")
p3_knee_all = True
for load in LOADS:
    dpp_gp = g(load, 'Dpp', 'gp')
    best = max(g(load, 'pull', 'gp'), g(load, 'ewma', 'gp'))
    need = best * 0.98
    ok = dpp_gp >= need
    p3_knee_all = p3_knee_all and ok
    print("  load=%.2f  Dpp gp=%.0f  max(pull,ewma) gp=%.0f  need>=%.0f (max-2%%) -> %s" %
          (load, dpp_gp, best, need, 'PASS' if ok else 'FAIL'))
p3_loss75 = g(0.75, 'Dpp', 'loss') <= 8.0
print("  0.75  loss=%.2f%% (need<=8%%) -> %s" % (g(0.75, 'Dpp', 'loss'), 'PASS' if p3_loss75 else 'FAIL'))
p3 = p3_knee_all and p3_loss75
print("  P3 OVERALL: %s" % ('PASS' if p3 else 'FAIL'))
print()

print("=" * 100)
print("SUMMARY: P1=%s  P2=%s  P3=%s" %
      ('PASS' if p1 else 'FAIL', 'PASS' if p2 else 'FAIL', 'PASS' if p3 else 'FAIL'))
print("=" * 100)
print("elapsed %.1fs" % (time.time() - t0))
