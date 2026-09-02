#!/usr/bin/env python3
# =============================================================================
# measure_dc_n2edge.py -- COMPOSITE Dc (sched='Dc') measurement, N2 EDGE rig
#   (bottleneck at client socket): 1 cellA (spotty) + 1 eth (steady host).
#
# Physics: reserved_composite.py (Dc datapath, UNMODIFIED nsched_model physics,
#   pull/D/Dpp/redundant kept byte-for-byte vs reserved_meter.py) vs
#   ackclock_sim.Sim reference schedulers pull / ewma ('A', the shipped
#   one-sided delivered-rate cap: room() = local-inflight<target AND
#   far-inflight<target) / oracle (unreachable upper bound), run with
#   mirror=False so the ONLY mirroring anywhere in the study is Dc's
#   meter-gated duplicate (clean isolation, matches measure_dpp_n2mid.py /
#   measure_dpp_p4.py convention).
#
# THE BUG under test: Dpp shipped the meter-gated duplicate but left NATIVE
#   admission UNCAPPED (nat_cap=HUGE == pure pull); at high load on the MID
#   rig that native flood drove PULL-level loss via an eviction spiral
#   (spotty-link native share tshare 23->58%). Dc restores the native cap:
#   native room() == _meter_ok (the SAME ackclock 'ewma' one-sided cap the
#   duplicate already used). This is the STANDING-LIGHTNING EDGE TAX check --
#   on the EDGE rig (bottleneck at the client socket, spotty cap already
#   visible locally) Dc's native cap is expected to cost a SMALL, BOUNDED
#   tax vs raw ewma, because native-first priority (PIECE 1 fully drains
#   with native pull before any duplicate is admitted in PIECE 2) bounds it.
#
# Instrumented: gp/loss/p50/p95/p99 (all schedulers) + res_tx = ADMITTED-
#   DUPLICATE frames (Dc only) + tshare = spotty-link (cellA) native/assigned
#   share (all schedulers -- the eviction-spiral watch metric).
#
# PASS bar (both loads 0.65, 0.85): Dc gp within 1% of ewma gp; Dc p95 within
#   ewma p95 + ~10ms.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

import reserved_composite as RC
import ackclock_sim as A

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

T = 9.0
SEEDS = 24
LOADS = [0.65, 0.85]
GP_TOL_PCT = 1.0     # |dev| <= 1% of ewma gp
P95_TOL_MS = 10.0    # Dc p95 <= ewma p95 + 10ms

archs = [RC.cellA(RC.DROPS_A), RC.eth()]
defs_edge = RC.build_rig(archs, bottleneck='edge')
nom = sum(a['base'] for a in archs)

print("=" * 90)
print("Dc (sched='Dc') vs pull / A(ewma) / oracle -- N2 EDGE (cellA+eth), bottleneck='edge'")
print("T=%.1fs SEEDS=%d (paired) nom=%.0f target_ms=40.0" % (T, SEEDS, nom))
print("=" * 90)
print()

t0 = time.time()
results = {}   # (load, sched) -> dict of medians
for load in LOADS:
    of = lambda t, _n=nom, _L=load: _L * _n
    for sch in ('Dc', 'pull', 'ewma', 'oracle'):
        gp = []; ls = []; p50 = []; p95 = []; p99 = []
        ts = []; rtx = []; miro = []; mira = []; af = []
        for sd in range(SEEDS):
            if sch == 'Dc':
                m = RC.SimD(defs_edge, of, T, sd, sched='Dc').run()
                rtx.append(m['res_tx']); miro.append(m['mir_off'])
                mira.append(m['mir_aged']); af.append(m['armed_frac'])
            else:
                m = A.Sim(defs_edge, of, T, sd, sched=sch, mirror=False).run()
            gp.append(m['gp']); ls.append(m['loss'])
            p50.append(m['p50']); p95.append(m['p95']); p99.append(m['p99'])
            ts.append(m['tshare'])
        row = dict(gp=med(gp), loss=med(ls), p50=med(p50), p95=med(p95),
                    p99=med(p99), tshare=med(ts))
        if sch == 'Dc':
            row.update(res_tx=med(rtx), mir_off=med(miro), mir_aged=med(mira),
                        armed=med(af))
        results[(load, sch)] = row

def g(load, sch, k):
    return results[(load, sch)][k]

print("=" * 90)
print("REPORT (medians, %d paired seeds)" % SEEDS)
print("=" * 90)
hdr = "%-6s %-6s %9s %7s %7s %7s %7s %8s %10s" % \
      ('load', 'sched', 'gp', 'loss%', 'p50ms', 'p95ms', 'p99ms', 'tshare', 'res_tx')
print(hdr)
print("-" * len(hdr))
for load in LOADS:
    for sch in ('Dc', 'pull', 'ewma', 'oracle'):
        r = results[(load, sch)]
        rtx_s = ("%10.0f" % r['res_tx']) if sch == 'Dc' else (" " * 10)
        print("%-6.2f %-6s %9.0f %7.2f %7.1f %7.1f %7.1f %8.3f %10s" %
              (load, sch, r['gp'], r['loss'], r['p50'], r['p95'], r['p99'],
               r['tshare'], rtx_s))
    print()

print("=" * 90)
print("PASS/FAIL -- Dc vs A(ewma): gp within %.1f%%, p95 within +%.0fms" %
      (GP_TOL_PCT, P95_TOL_MS))
print("=" * 90)
overall_pass = True
for load in LOADS:
    dc = results[(load, 'Dc')]; ew = results[(load, 'ewma')]; pu = results[(load, 'pull')]
    gp_dev_pct = 100.0 * (dc['gp'] - ew['gp']) / ew['gp']
    gp_ok = abs(gp_dev_pct) <= GP_TOL_PCT
    p95_delta = dc['p95'] - ew['p95']
    p95_ok = p95_delta <= P95_TOL_MS
    row_pass = gp_ok and p95_ok
    overall_pass = overall_pass and row_pass
    print("load=%.2f" % load)
    print("  pull : gp=%8.1f loss=%5.2f%% p95=%6.1fms tshare=%.3f" %
          (pu['gp'], pu['loss'], pu['p95'], pu['tshare']))
    print("  ewma : gp=%8.1f loss=%5.2f%% p95=%6.1fms tshare=%.3f" %
          (ew['gp'], ew['loss'], ew['p95'], ew['tshare']))
    print("  Dc   : gp=%8.1f loss=%5.2f%% p95=%6.1fms tshare=%.3f  res_tx=%.0f mir_off=%.0f mir_aged=%.0f armed_frac=%.4f" %
          (dc['gp'], dc['loss'], dc['p95'], dc['tshare'],
           dc['res_tx'], dc['mir_off'], dc['mir_aged'], dc['armed']))
    print("  Dc vs ewma gp dev  = %+.3f%%  (bar: |dev|<=%.1f%%)      -> %s" %
          (gp_dev_pct, GP_TOL_PCT, "OK" if gp_ok else "FAIL"))
    print("  Dc vs ewma p95 delta = %+.1fms (bar: <=+%.0fms)         -> %s" %
          (p95_delta, P95_TOL_MS, "OK" if p95_ok else "FAIL"))
    print("  ROW: %s" % ("PASS" if row_pass else "FAIL"))
    print()

print("=" * 90)
print("DC N2-EDGE VERDICT:", "PASS" if overall_pass else "FAIL")
print("=" * 90)
print("elapsed %.1fs" % (time.time() - t0))
