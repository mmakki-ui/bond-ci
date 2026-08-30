#!/usr/bin/env python3
# =============================================================================
# measure_dc_n2mid.py -- Dc (sched='Dc', reserved_composite.py) measurement,
#   N2 MID(hidden-downstream) rig: 1 cellA (spotty) + 1 eth (steady host).
#
# Physics: reserved_composite.py (Dc = Dpp + native NOW cap-gated by the SAME
#   ackclock 'ewma' one-sided delivered-rate meter, UNMODIFIED nsched_model
#   physics) vs ackclock_sim.Sim reference schedulers pull / ewma (A, the
#   shipped one-sided delivered-rate cap) / oracle (unreachable upper bound),
#   run with mirror=False so the ONLY mirroring anywhere in the study is Dc's
#   meter-gated duplicate (clean isolation, matches measure_dpp_n2mid.py's
#   convention). SEEDS are shared 0..SEEDS-1 across every scheduler at a given
#   load (paired).
#
# Dpp (reserved_composite.py sched='Dpp') is run alongside PURELY as the
# eviction-spiral WITNESS: Dpp left native UNCAPPED (nat_cap=HUGE == pure
# pull), so once the pool is loaded the spotty (cellA) link's native share
# (tshare) walks UP with load as native keeps dumping frames onto the
# already-deficit spotty path (the reported 23%->58% pattern). Dc restores
# the native cap (room() == _meter_ok), so the walk should be bounded.
#
# Instrumented per (load, sched): gp/loss/p50/p95/p99 (all) + res_tx =
#   ADMITTED-DUPLICATE frames (Dc/Dpp only) + tshare = spotty-link (index0=
#   cellA) NATIVE assigned share (all) -- the eviction-spiral watch.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

import reserved_composite as RC
import ackclock_sim as A

PKT_KB = RC.PKT_KB

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

T = 9.0
SEEDS = 24
LOADS = [0.65, 0.75, 0.85, 0.95]
SCHEDS = ['Dc', 'pull', 'ewma', 'oracle']
METRICS = ['gp', 'loss', 'p50', 'p95', 'p99']

archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs = RC.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
print("rig: N2 MID(hidden-downstream) = 1 cellA(spotty, DROPS_A) + 1 eth(steady)")
print("nominal aggregate cap0 sum = %.0f kb/s ; T=%.1fs SEEDS=%d target_ms=40.0 (paired seeds)" %
      (nom, T, SEEDS))
print()

t0 = time.time()
results = {}      # (load, sched) -> dict of medians (gp/loss/p50/p95/p99/tshare[/res_tx])
dpp_results = {}  # load -> dict (Dpp witness: gp/loss/tshare/res_tx)

for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    for sch in SCHEDS:
        vals = {m: [] for m in METRICS}
        rtx = []; ts = []
        for sd in range(SEEDS):
            if sch == 'Dc':
                m = RC.SimD(defs, of, T, sd, sched='Dc').run()
                rtx.append(m['res_tx'])
            else:
                m = A.Sim(defs, of, T, sd, sched=sch, mirror=False).run()
            for k in METRICS:
                vals[k].append(m[k])
            ts.append(m['tshare'])
        row = {k: med(vals[k]) for k in METRICS}
        row['tshare'] = med(ts)
        if sch == 'Dc':
            row['res_tx'] = med(rtx)
        results[(load, sch)] = row
    # ---- Dpp eviction-spiral witness (native left uncapped -- the bug) ----
    dl = []; dts = []; drtx = []; dgp = []
    for sd in range(SEEDS):
        m = RC.SimD(defs, of, T, sd, sched='Dpp').run()
        dl.append(m['loss']); dts.append(m['tshare']); drtx.append(m['res_tx']); dgp.append(m['gp'])
    dpp_results[load] = {'loss': med(dl), 'tshare': med(dts), 'res_tx': med(drtx), 'gp': med(dgp)}
    print("  ...load=%.2f done (%.1fs elapsed)" % (load, time.time() - t0))

print()

# =============================================================================
print("=" * 112)
print("REPORT -- Dc vs pull / A(ewma cap) / oracle  (medians, %d seeds, paired)" % SEEDS)
print("=" * 112)
hdr = "%-6s %-7s %9s %7s %7s %7s %7s %10s %8s" % \
      ('load', 'sched', 'gp', 'loss%', 'p50ms', 'p95ms', 'p99ms', 'res_tx', 'tshare')
print(hdr)
print("-" * len(hdr))
for load in LOADS:
    for sch in SCHEDS:
        r = results[(load, sch)]
        rtx_s = ("%10.0f" % r['res_tx']) if sch == 'Dc' else (" " * 10)
        print("%-6.2f %-7s %9.0f %7.2f %7.1f %7.1f %7.1f %10s %8.3f" %
              (load, sch, r['gp'], r['loss'], r['p50'], r['p95'], r['p99'], rtx_s, r['tshare']))
    dp = dpp_results[load]
    print("%-6.2f %-7s %9.0f %7.2f %7s %7s %7s %10.0f %8.3f  <- Dpp (BUG witness, native uncapped)" %
          (load, 'Dpp', dp['gp'], dp['loss'], '', '', '', dp['res_tx'], dp['tshare']))
    print()

# =============================================================================
print("=" * 112)
print("TSHARE TIMELINE -- spotty-link (cellA) NATIVE assigned share vs load")
print("  the eviction-spiral watch: Dpp's known bug walks this 23%% -> 58%% as native")
print("  floods the deficit spotty link once its own cap is gone; Dc restores the cap.")
print("=" * 112)
print("%-6s %10s %12s %10s %10s %10s" % ('load', 'Dc', 'Dpp(BUG)', 'pull', 'ewma', 'oracle'))
for load in LOADS:
    print("%-6.2f %10.3f %12.3f %10.3f %10.3f %10.3f" %
          (load, results[(load, 'Dc')]['tshare'], dpp_results[load]['tshare'],
           results[(load, 'pull')]['tshare'], results[(load, 'ewma')]['tshare'],
           results[(load, 'oracle')]['tshare']))
print()

dc_ts_series = [results[(l, 'Dc')]['tshare'] for l in LOADS]
dpp_ts_series = [dpp_results[l]['tshare'] for l in LOADS]
ewma_ts_series = [results[(l, 'ewma')]['tshare'] for l in LOADS]
dc_ts_walk = max(dc_ts_series) - min(dc_ts_series)
dpp_ts_walk = max(dpp_ts_series) - min(dpp_ts_series)
ewma_ts_walk = max(ewma_ts_series) - min(ewma_ts_series)
print("Dc   tshare walk (max-min across 0.65..0.95) = %.3f (%.1f pts)  series=%s" %
      (dc_ts_walk, dc_ts_walk * 100, ["%.3f" % v for v in dc_ts_series]))
print("Dpp  tshare walk (BUG witness, same range)    = %.3f (%.1f pts)  series=%s" %
      (dpp_ts_walk, dpp_ts_walk * 100, ["%.3f" % v for v in dpp_ts_series]))
print("ewma tshare walk (reference, same range)      = %.3f (%.1f pts)  series=%s" %
      (ewma_ts_walk, ewma_ts_walk * 100, ["%.3f" % v for v in ewma_ts_series]))
print()

# =============================================================================
def g(load, sch, k):
    return results[(load, sch)][k]

print("=" * 112)
print("PASS/FAIL")
print("=" * 112)

# ---- load=0.65: moderate win SURVIVES capped native ----
TARGET_65 = 68295.0
p65_gp = g(0.65, 'Dc', 'gp') >= TARGET_65 * 0.985
p65_loss = g(0.65, 'Dc', 'loss') <= 2.0
p65 = p65_gp and p65_loss
print("load=0.65 (moderate win survives capped native):")
print("  gp=%.0f  (target~%.0f, need>=%.0f [-1.5%%])  -> %s" %
      (g(0.65, 'Dc', 'gp'), TARGET_65, TARGET_65 * 0.985, 'PASS' if p65_gp else 'FAIL'))
print("  loss=%.2f%%  (need<=2.0%%)                     -> %s" %
      (g(0.65, 'Dc', 'loss'), 'PASS' if p65_loss else 'FAIL'))
print("  0.65 OVERALL: %s" % ('PASS' if p65 else 'FAIL'))
print()

# ---- load=0.85 and load=0.95: priority damper holds where static reserve
#      (the older sched='D') knee'd at 0.75 -- gp>=0.99*ewma AND loss<=ewma+0.5pt
hi_pass = {}
for load in (0.85, 0.95):
    ew_gp = g(load, 'ewma', 'gp'); ew_loss = g(load, 'ewma', 'loss')
    dc_gp = g(load, 'Dc', 'gp'); dc_loss = g(load, 'Dc', 'loss')
    ok_gp = dc_gp >= 0.99 * ew_gp
    ok_loss = dc_loss <= ew_loss + 0.5
    ok = ok_gp and ok_loss
    hi_pass[load] = ok
    print("load=%.2f (priority damper holds vs ewma):" % load)
    print("  gp:   Dc=%.0f  ewma=%.0f  need>=0.99*ewma=%.0f    -> %s" %
          (dc_gp, ew_gp, 0.99 * ew_gp, 'PASS' if ok_gp else 'FAIL'))
    print("  loss: Dc=%.2f%%  ewma=%.2f%%  need<=ewma+0.5=%.2f%%  -> %s" %
          (dc_loss, ew_loss, ew_loss + 0.5, 'PASS' if ok_loss else 'FAIL'))
    print("  %.2f OVERALL: %s" % (load, 'PASS' if ok else 'FAIL'))
    print()

# ---- load=0.75: no explicit bar given (this is the load the OLD static
#      reserve knee'd at) -- reported for completeness, extended check uses
#      the SAME priority-damper formula as 0.85/0.95 for symmetry (labeled
#      as an extension, not part of the spec'd bar set). ----
ew_gp75 = g(0.75, 'ewma', 'gp'); ew_loss75 = g(0.75, 'ewma', 'loss')
dc_gp75 = g(0.75, 'Dc', 'gp'); dc_loss75 = g(0.75, 'Dc', 'loss')
ok_gp75 = dc_gp75 >= 0.99 * ew_gp75
ok_loss75 = dc_loss75 <= ew_loss75 + 0.5
p75_extended = ok_gp75 and ok_loss75
print("load=0.75 (no bar specified -- this is where the OLD static reserve knee'd;")
print("           reported here + an EXTENDED check using the same 0.99*ewma/+0.5pt")
print("           formula as 0.85/0.95, for continuity across the sweep):")
print("  gp:   Dc=%.0f  ewma=%.0f  (0.99*ewma=%.0f)   -> %s [extended, informational]" %
      (dc_gp75, ew_gp75, 0.99 * ew_gp75, 'PASS' if ok_gp75 else 'FAIL'))
print("  loss: Dc=%.2f%%  ewma=%.2f%%  (ewma+0.5=%.2f%%) -> %s [extended, informational]" %
      (dc_loss75, ew_loss75, ew_loss75 + 0.5, 'PASS' if ok_loss75 else 'FAIL'))
print("  0.75 OVERALL (extended, NOT part of the spec'd bar): %s" %
      ('PASS' if p75_extended else 'FAIL'))
print()

# ---- tshare drift bounded: no 23%->58% walk ----
TS_CEIL = 0.45          # well clear of Dpp's ~0.58 bug ceiling
TS_DRIFT_SLACK = 0.15   # Dc's own walk allowed this much beyond ewma's natural walk
ts_bound_ceiling = max(dc_ts_series) <= TS_CEIL
ts_bound_drift = dc_ts_walk <= ewma_ts_walk + TS_DRIFT_SLACK
ts_ok = ts_bound_ceiling and ts_bound_drift
print("tshare drift (eviction-spiral bound):")
print("  Dc max tshare across sweep = %.3f  (need<=%.2f, clear of Dpp's %.3f bug ceiling) -> %s" %
      (max(dc_ts_series), TS_CEIL, max(dpp_ts_series), 'PASS' if ts_bound_ceiling else 'FAIL'))
print("  Dc walk=%.3f vs ewma walk=%.3f  (need<=ewma_walk+%.2f=%.3f)                   -> %s" %
      (dc_ts_walk, ewma_ts_walk, TS_DRIFT_SLACK, ewma_ts_walk + TS_DRIFT_SLACK,
       'PASS' if ts_bound_drift else 'FAIL'))
print("  Dpp (BUG witness) walk=%.3f, series=%s  <- what an uncapped native looks like" %
      (dpp_ts_walk, ["%.3f" % v for v in dpp_ts_series]))
print("  TSHARE OVERALL: %s" % ('PASS' if ts_ok else 'FAIL'))
print()

print("=" * 112)
overall = p65 and hi_pass[0.85] and hi_pass[0.95] and ts_ok
print("SUMMARY (spec'd bars):  0.65=%s  0.85=%s  0.95=%s  tshare-drift=%s  ==>  %s" %
      ('PASS' if p65 else 'FAIL', 'PASS' if hi_pass[0.85] else 'FAIL',
       'PASS' if hi_pass[0.95] else 'FAIL', 'PASS' if ts_ok else 'FAIL',
       'PASS' if overall else 'FAIL'))
print("  (0.75 has no spec'd bar; extended informational check above: %s)" %
      ('PASS' if p75_extended else 'FAIL'))
print("=" * 112)
print("elapsed %.1fs" % (time.time() - t0))
