#!/usr/bin/env python3
# =============================================================================
# dpp_degen_check.py -- P5 DEGENERACY MEASUREMENT for D'' (sched='Dpp'),
# reserved_meter.py.  UNMODIFIED physics (nsched_model, ackclock_sim) imported
# via reserved_meter / reserved_dp exactly as shipped -- nothing here touches
# the sim internals.
#
# CLAIM UNDER TEST (P5): in the two DEGENERATE rigs where D'' has no work to
# do by construction --
#   ALL-STEADY  (no spotty-class path -> at_risk empty -> never armed)
#   ALL-SPOTTY  (every path spotty-class -> host set empty -> never armed,
#                whether the stalls are CORRELATED (shared dropout windows,
#                DROPS_CORR on every path) or INDEPENDENT (per-path offset
#                dropout schedules DROPS_A/B/C))
# -- sched='Dpp' must reprint the sched='pull' row BYTE-FOR-BYTE on every
# shared metric, AND admitted-duplicate bytes (res_tx) must be EXACTLY 0.
# Per Fable: the metric that must collapse in these rigs is ADMISSION
# (res_tx), not nomination -- so mir_offered is measured and reported but is
# NOT part of the pass/fail gate (armed=False in every degenerate tick makes
# mir_offered==0 too, as a consequence, not the criterion).
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as R
import reserved_dp as D
import ackclock_sim as A

# metrics that must byte-match between pull and Dpp rows (res_tx/mir_offered/
# mir_aged/armed_frac are NOT in here -- pull doesn't emit them meaningfully
# the same way; those are checked separately as the D'' admission gate itself)
SH = ['gp', 'loss', 'p50', 'p95', 'p99', 'deliv', 'tshare', 'hol', 'qdrops',
      'late', 'depth', 'tdrop']

T = 9.0; SEEDS = 24

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

t0 = time.time()

print("=" * 84)
print("CHECK 1 -- imports clean (UNMODIFIED physics)")
print("=" * 84)
print("  reserved_meter, reserved_dp, ackclock_sim, nsched_model imported OK")
print("  D'' constants: target_ms=40.0 (ackclock 'ewma' cap threshold, reused verbatim)")

print("=" * 84)
print("CHECK 2 -- reserved_meter.SimD('pull') byte-matches ackclock_sim.Sim('pull'),")
print("           and sched='D' stays byte-identical to reserved_dp.SimD('D')")
print("=" * 84)
archs0 = [R.cellA(R.DROPS_A), R.eth()]
defs0 = R.build_rig(archs0, bottleneck='mid')
nom0 = sum(a['base'] for a in archs0)
ofn0 = lambda t, _n=nom0: 0.8 * _n
badP = badD = 0
for sd in range(SEEDS):
    mR = R.SimD(defs0, ofn0, T, sd, sched='pull').run()
    mA = A.Sim(defs0, ofn0, T, sd, sched='pull', mirror=False).run()
    if not all(mR[k] == mA[k] for k in SH): badP += 1
    mR2 = R.SimD(defs0, ofn0, T, sd, sched='D', reserve_frac=0.15).run()
    mD2 = D.SimD(defs0, ofn0, T, sd, sched='D', reserve_frac=0.15).run()
    if not all(mR2[k] == mD2[k] for k in mR2): badD += 1
print("  reserved_meter.SimD('pull') == ackclock_sim.Sim('pull')  over %d seeds: %s" %
      (SEEDS, badP == 0))
print("  reserved_meter.SimD('D')    == reserved_dp.SimD('D')     over %d seeds: %s" %
      (SEEDS, badD == 0))
check2_ok = (badP == 0 and badD == 0)

print("=" * 84)
print("CHECK 3 / P5 -- DEGENERATE RIGS: Dpp reprints pull byte-for-byte, res_tx=0")
print("=" * 84)

cases = {
    'ALL-STEADY N2 (eth+wifi)':        [R.eth(), R.wifi()],
    'ALL-STEADY N3 (eth+wifi+eth)':    [R.eth(), R.wifi(), R.eth()],
    'ALL-SPOTTY N3 correlated':        [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)],
    'ALL-SPOTTY N3 independent':       [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)],
}

p5_ok = True
rows = []
for name, ar in cases.items():
    dfs = R.build_rig(ar, bottleneck='mid')
    nm = sum(a['base'] for a in ar)
    for load in (0.65, 0.85):
        of = lambda t, _n=nm, _L=load: _L * _n
        bad = 0; rtx_max = 0; mo_max = 0; af_max = 0.0
        for sd in range(SEEDS):
            mp = R.SimD(dfs, of, T, sd, sched='pull').run()
            md = R.SimD(dfs, of, T, sd, sched='Dpp').run()
            if not all(mp[k] == md[k] for k in SH): bad += 1
            rtx_max = max(rtx_max, md['res_tx'])
            mo_max = max(mo_max, md['mir_off'])
            af_max = max(af_max, md['armed_frac'])
        ok = (bad == 0 and rtx_max == 0)
        p5_ok = p5_ok and ok
        rows.append((name, load, bad, rtx_max, mo_max, af_max, ok))
        print("  %-28s load=%.2f  reprints_pull=%2d/%d  res_tx_max=%d  "
              "mir_offered_max=%d  armed_max=%.4f  %s" %
              (name, load, SEEDS - bad, SEEDS, rtx_max, mo_max, af_max,
               'OK' if ok else 'FAIL'))

print("=" * 84)
print("P5 VERDICT: sched='Dpp' reprints pull rows byte-for-byte with admitted-dup")
print("bytes res_tx=0, across ALL-STEADY(N2,N3) and ALL-SPOTTY(N3 correlated+independent)")
print("x loads(0.65,0.85), %d seeds each: %s" % (SEEDS, "PASS" if (check2_ok and p5_ok) else "FAIL"))
print("=" * 84)
print("\nelapsed %.1fs" % (time.time() - t0))

sys.exit(0 if (check2_ok and p5_ok) else 1)
