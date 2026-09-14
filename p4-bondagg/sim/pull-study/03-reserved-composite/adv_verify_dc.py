#!/usr/bin/env python3
# INDEPENDENT adversarial reproduction of the Dc composite decisive points.
# Does NOT reuse measure_dc_n2mid.py's harness beyond the physics/rig builders.
# Reproduces: mid 0.85 AND 0.95 bars (gp>=0.99*ewma AND loss<=ewma+0.5pt),
# the 0.65 win, and an INDEPENDENT tshare-timeline reconstruction (no 23->58 walk).
import sys, time
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
print("INDEPENDENT REPRO -- N2 MID cellA+eth  nom=%.0f  T=%.1f  SEEDS=%d" % (nom, T, SEEDS))

def run_one(sch, of, sd):
    if sch in ('Dc', 'Dpp'):
        return RC.SimD(defs, of, T, sd, sched=sch).run()
    return A.Sim(defs, of, T, sd, sched=sch, mirror=False).run()

t0 = time.time()
LOADS = [0.65, 0.85, 0.95]
agg = {}
for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    cols = {s: {'gp': [], 'loss': [], 'ts': []} for s in ('Dc', 'ewma', 'pull', 'Dpp')}
    paired = []  # (Dc_loss - ewma_loss) per seed
    for sd in range(SEEDS):
        r = {s: run_one(s, of, sd) for s in ('Dc', 'ewma', 'pull', 'Dpp')}
        for s in cols:
            cols[s]['gp'].append(r[s]['gp'])
            cols[s]['loss'].append(r[s]['loss'])
            cols[s]['ts'].append(r[s]['tshare'])
        paired.append(r['Dc']['loss'] - r['ewma']['loss'])
    agg[load] = {s: {k: med(cols[s][k]) for k in cols[s]} for s in cols}
    agg[load]['_paired'] = paired
    print("  load %.2f done (%.1fs)" % (load, time.time() - t0))

print("\n%-6s %-6s %10s %8s %8s" % ("load", "sched", "gp", "loss%", "tshare"))
for load in LOADS:
    for s in ('Dc', 'ewma', 'pull', 'Dpp'):
        d = agg[load][s]
        print("%-6.2f %-6s %10.0f %8.2f %8.3f" % (load, s, d['gp'], d['loss'], d['ts']))
    print()

print("=" * 70)
print("BAR CHECKS")
print("=" * 70)
# 0.65 win: gp within/above ~68295 target-ish, loss<=2%
d = agg[0.65]
win_gp = d['Dc']['gp']; win_loss = d['Dc']['loss']
print("0.65 WIN: Dc gp=%.0f (ewma=%.0f, pull=%.0f) loss=%.2f%% -> gp>=ewma:%s loss<=2%%:%s"
      % (win_gp, d['ewma']['gp'], d['pull']['gp'], win_loss,
         win_gp >= d['ewma']['gp'], win_loss <= 2.0))
for load in (0.85, 0.95):
    d = agg[load]
    dc_gp, dc_loss = d['Dc']['gp'], d['Dc']['loss']
    ew_gp, ew_loss = d['ewma']['gp'], d['ewma']['loss']
    dpp_gp, dpp_loss = d['Dpp']['gp'], d['Dpp']['loss']
    ok_gp = dc_gp >= 0.99 * ew_gp
    ok_loss = dc_loss <= ew_loss + 0.5
    p = d['_paired']
    over = sum(1 for x in p if x > 0.5)
    print("-" * 70)
    print("%.2f: gp Dc=%.0f vs 0.99*ewma=%.0f -> %s (no-recollapse)  [Dpp=%.0f]"
          % (load, dc_gp, 0.99 * ew_gp, "PASS" if ok_gp else "FAIL", dpp_gp))
    print("      loss Dc=%.2f%% vs ewma+0.5=%.2f%% -> %s   [Dpp loss=%.2f%%]"
          % (dc_loss, ew_loss + 0.5, "PASS" if ok_loss else "FAIL", dpp_loss))
    print("      paired Dc-ewma: median=%+.3f mean=%+.3f min=%+.3f max=%+.3f  seeds>0.5pt=%d/%d"
          % (med(p), sum(p) / len(p), min(p), max(p), over, SEEDS))

# ---- INDEPENDENT within-run tshare timeline via truncated-T (0.95) ----
print("=" * 70)
print("TSHARE TIMELINE (independent truncated-T reconstruction) load=0.95")
print("=" * 70)
CK = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]
TL_SEEDS = 12
of95 = lambda t, _n=nom, _L=0.95: _L * _n
for sch in ('Dc', 'Dpp', 'ewma'):
    cum = {sd: [] for sd in range(TL_SEEDS)}
    for sd in range(TL_SEEDS):
        for tt in CK:
            if sch in ('Dc', 'Dpp'):
                o = RC.SimD(defs, of95, tt, sd, sched=sch)
            else:
                o = A.Sim(defs, of95, tt, sd, sched=sch, mirror=False)
            o.run()
            cum[sd].append(list(o.assigned))
    win = []
    for wi in range(len(CK)):
        a0 = asum = 0
        for sd in range(TL_SEEDS):
            prev = cum[sd][wi - 1] if wi > 0 else [0, 0]
            cur = cum[sd][wi]
            a0 += cur[0] - prev[0]
            asum += (cur[0] + cur[1]) - (prev[0] + prev[1])
        win.append(a0 / asum if asum else 0.0)
    print("  %-5s : %s   min=%.3f max=%.3f monotonic_up=%s"
          % (sch, " ".join("%.3f" % w for w in win), min(win), max(win),
             all(win[i] <= win[i + 1] + 1e-9 for i in range(len(win) - 1))))
print("\nelapsed %.1fs" % (time.time() - t0))
