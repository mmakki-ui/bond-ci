#!/usr/bin/env python3
# P4 measurement: D'' (sched='Dpp') vs pull, N2 EDGE rig (bottleneck at client
# socket), loads 0.65/0.85. Bar: Dpp gp within 1% of pull gp at both loads
# (target ~69330@0.65, ~87438@0.85), loss<=4.2% at 0.85.
# Instrumented metric = res_tx (ADMITTED-DUPLICATE bytes/copies), NOT armed_frac
# (nomination/mir_offered may stay high; what must drop is ADMISSION).
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1] + xs[n//2]) / 2.0

T = 9.0
SEEDS = 24
archs = [RM.cellA(RM.DROPS_A), RM.eth()]
defs_edge = RM.build_rig(archs, bottleneck='edge')
nom = sum(a['base'] for a in archs)

print("=" * 78)
print("P4 -- D'' (sched='Dpp') vs pull, N2 EDGE (cellA+eth), bottleneck='edge'")
print("T=%.1fs SEEDS=%d nom=%.0f" % (T, SEEDS, nom))
print("=" * 78)

TARGET_GP = {0.65: 69330.0, 0.85: 87438.0}
overall_pass = True
rows = {}
for load in (0.65, 0.85):
    of = lambda t, _n=nom, _L=load: _L * _n
    out = {}
    for sch in ('pull', 'Dpp'):
        gp = []; ls = []; p95 = []; p99 = []; rtx = []; miro = []; mira = []; af = []
        for sd in range(SEEDS):
            m = RM.SimD(defs_edge, of, T, sd, sched=sch).run()
            gp.append(m['gp']); ls.append(m['loss']); p95.append(m['p95']); p99.append(m['p99'])
            rtx.append(m['res_tx']); miro.append(m['mir_off']); mira.append(m['mir_aged'])
            af.append(m['armed_frac'])
        out[sch] = dict(gp=med(gp), loss=med(ls), p95=med(p95), p99=med(p99),
                         res_tx=med(rtx), mir_off=med(miro), mir_aged=med(mira),
                         armed=med(af))
    rows[load] = out
    p = out['pull']; d = out['Dpp']
    dev_pct = 100.0 * (d['gp'] - p['gp']) / p['gp']
    gp_ok = abs(dev_pct) <= 1.0
    loss_ok = (d['loss'] <= 4.2) if load == 0.85 else True
    tgt = TARGET_GP[load]
    tgt_dev = 100.0 * (d['gp'] - tgt) / tgt
    row_pass = gp_ok and loss_ok
    overall_pass = overall_pass and row_pass
    print("load=%.2f" % load)
    print("  pull : gp=%8.1f loss=%5.2f%% p95=%6.1fms p99=%6.1fms" %
          (p['gp'], p['loss'], p['p95'], p['p99']))
    print("  Dpp  : gp=%8.1f loss=%5.2f%% p95=%6.1fms p99=%6.1fms  res_tx=%.0f mir_off=%.0f mir_aged=%.0f armed_frac=%.4f" %
          (d['gp'], d['loss'], d['p95'], d['p99'], d['res_tx'], d['mir_off'], d['mir_aged'], d['armed']))
    print("  Dpp vs pull gp dev = %+.3f%%  (bar: |dev|<=1%%)  -> %s" %
          (dev_pct, "OK" if gp_ok else "FAIL"))
    print("  Dpp gp vs expected target %.0f: dev = %+.3f%%" % (tgt, tgt_dev))
    if load == 0.85:
        print("  Dpp loss=%.2f%% (bar: <=4.2%%) -> %s" % (d['loss'], "OK" if loss_ok else "FAIL"))
    print("  ROW: %s" % ("PASS" if row_pass else "FAIL"))
    print()

print("=" * 78)
print("P4 VERDICT:", "PASS" if overall_pass else "FAIL")
print("=" * 78)
