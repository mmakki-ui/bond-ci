#!/usr/bin/env python3
# smoke_composite.py -- SMOKE ONLY for the COMPOSITE Dc (reserved_composite.py).
#   (1) imports
#   (2) SimD('pull') == ackclock Sim('pull')  (3 seeds, key metrics byte-equal)
#   (3) SimD('Dc') runs 1 seed
#   (4) FIX-CHECK: SimD('Dc') at N2 MID 0.85 (24 seeds) -> native backs off:
#       loss near ewma (~6%), NOT pull (~13%).  res_tx + tshare instrumented.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_composite as RC
import ackclock_sim as A

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

print("[1] imports OK: reserved_composite, ackclock_sim")

# ---- rig: N2 MID = 1 cellA(spotty) + 1 eth(steady) ----
archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
T = 9.0
KEYS = ['gp', 'loss', 'p50', 'p95', 'p99', 'deliv', 'tdrop', 'tshare']

# ---- [2] SimD('pull') == ackclock Sim('pull') ----
of65 = lambda t, _n=nom: 0.65 * _n
print("\n[2] SimD('pull') vs ackclock Sim('pull')  (3 seeds, key metrics):")
all_match = True
for sd in range(3):
    md = RC.SimD(defs, of65, T, sd, sched='pull').run()
    ma = A.Sim(defs, of65, T, sd, sched='pull', mirror=False).run()
    match = all(abs(md[k] - ma[k]) < 1e-9 for k in KEYS)
    all_match = all_match and match
    print("   seed %d: %s  (gp %.3f/%.3f loss %.4f/%.4f deliv %d/%d)" %
          (sd, 'MATCH' if match else 'DIFF', md['gp'], ma['gp'],
           md['loss'], ma['loss'], md['deliv'], ma['deliv']))
print("   -> pull byte-match: %s" % ('PASS' if all_match else 'FAIL'))

# ---- [3] SimD('Dc') runs 1 seed ----
print("\n[3] SimD('Dc') runs 1 seed at 0.85:")
of85 = lambda t, _n=nom: 0.85 * _n
m1 = RC.SimD(defs, of85, T, 0, sched='Dc').run()
print("   seed0: gp=%.0f loss=%.2f%% p95=%.1f res_tx=%d tshare=%.3f armed=%.2f  RUNS-OK" %
      (m1['gp'], m1['loss'], m1['p95'], m1['res_tx'], m1['tshare'], m1['armed_frac']))

# ---- [4] FIX-CHECK: Dc loss near ewma, not pull (24 seeds, 0.85) ----
print("\n[4] FIX-CHECK  N2 MID load=0.85  (24 seeds, medians):")
SEEDS = 24
dc = {k: [] for k in ('gp', 'loss', 'res_tx', 'tshare')}
pu = {'loss': []}; ew = {'loss': []}
for sd in range(SEEDS):
    m = RC.SimD(defs, of85, T, sd, sched='Dc').run()
    for k in dc: dc[k].append(m[k])
    pu['loss'].append(A.Sim(defs, of85, T, sd, sched='pull', mirror=False).run()['loss'])
    ew['loss'].append(A.Sim(defs, of85, T, sd, sched='ewma', mirror=False).run()['loss'])
dc_loss = med(dc['loss']); pu_loss = med(pu['loss']); ew_loss = med(ew['loss'])
print("   Dc   : gp=%.0f loss=%.2f%% res_tx=%.0f tshare=%.3f" %
      (med(dc['gp']), dc_loss, med(dc['res_tx']), med(dc['tshare'])))
print("   pull : loss=%.2f%%   ewma : loss=%.2f%%" % (pu_loss, ew_loss))
# native backed off if Dc loss is at/below the ewma cap band, well under pull.
mid = (ew_loss + pu_loss) / 2.0
fix_ok = dc_loss <= mid and dc_loss <= ew_loss + 2.0
print("   fix-check: Dc loss %.2f%% <= midpoint(%.2f) AND <= ewma+2 (%.2f)  -> %s" %
      (dc_loss, mid, ew_loss + 2.0, 'PASS (native capped)' if fix_ok else 'FAIL'))
print("\nSMOKE OVERALL: %s" % ('PASS' if (all_match and fix_ok) else 'FAIL'))
