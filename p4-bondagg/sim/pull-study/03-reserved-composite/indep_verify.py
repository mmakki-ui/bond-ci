#!/usr/bin/env python3
# INDEPENDENT verifier for reserved_local.py (candidate 'local', sched='Dp').
# Written from scratch by the verify agent. Does NOT import build agent scripts.
import sys, math
sys.path.insert(0, ".")
import reserved_local as R
import reserved_dp   as DP
from ackclock_sim import Sim

SEEDS = list(range(24))
T = 9.0
SHARED = ['gp','loss','p50','p95','p99','depth','tdrop','tshare','hol','qdrops','late','deliv']

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1]+xs[n//2])/2.0

def rig(arches, bn):
    return R.build_rig(arches, bottleneck=bn)

def nom_of(arches):
    return sum(a['base'] for a in arches)

def offer(load, nom):
    return lambda t: load * nom

def run_simd(arches, bn, load, sched, seed, **kw):
    defs = rig(arches, bn); nom = nom_of(arches)
    return R.SimD(defs, offer(load, nom), T, seed, sched=sched, **kw).run()

def run_simd_dp_module(arches, bn, load, sched, seed, **kw):
    defs = DP.build_rig(arches, bn); nom = nom_of(arches)
    return DP.SimD(defs, offer(load, nom), T, seed, sched=sched, **kw).run()

def run_ref(arches, bn, load, seed):
    # reference pull, mirror OFF (clean isolation), same physics import
    defs = rig(arches, bn); nom = nom_of(arches)
    return Sim(defs, offer(load, nom), T, seed, sched='pull', mirror=False).run()

# archetype sets
def A_N2():  return [R.cellA(R.DROPS_A), R.eth()]
def A_N3():  return [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]
def A_STEADY_N2(): return [R.eth(), R.wifi()]
def A_STEADY_N3(): return [R.eth(), R.wifi(), R.wifi()]
def A_SPOTTY_N2(): return [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B)]
def A_SPOTTY_N3(): return [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]

fails = []

# ---------------- CHECK 2: SimD('pull') == Sim('pull', mirror=False) ----------
print("=== CHECK 2: SimD('pull') byte-matches ackclock Sim('pull') ===")
c2_mismatch = 0; c2_total = 0
for arches, tag in [(A_N2(),'N2'), (A_N3(),'N3')]:
    for bn in ('mid','edge'):
        for load in (0.65, 0.85):
            for seed in SEEDS:
                a = run_simd(arches, bn, load, 'pull', seed)
                b = run_ref(arches, bn, load, seed)
                for k in SHARED:
                    c2_total += 1
                    if abs(a[k]-b[k]) > 1e-9:
                        c2_mismatch += 1
                        if c2_mismatch <= 8:
                            print(f"  MISMATCH {tag}/{bn}/L{load}/s{seed}/{k}: SimD={a[k]!r} Sim={b[k]!r}")
print(f"  pull-equivalence comparisons: {c2_total}, mismatches: {c2_mismatch}")
if c2_mismatch: fails.append("CHECK2 pull!=Sim")
else: print("  CHECK 2 PASS")

# ---------------- D INTACT: reserved_local.SimD('D') == reserved_dp.SimD('D') --
print("\n=== D INTACT: reserved_local.SimD('D') == reserved_dp.SimD('D') ===")
d_mismatch = 0; d_total = 0
ALLK = ['gp','loss','p50','p95','p99','depth','tdrop','tshare','hol','qdrops',
        'late','deliv','res_tx','mir_off','mir_aged','armed_frac']
for arches, tag in [(A_N2(),'N2'), (A_N3(),'N3')]:
    for bn in ('mid','edge'):
        for load in (0.65, 0.85):
            for (rf, ttl) in [(0.25,200.0),(0.10,120.0),(0.40,300.0)]:
                for seed in SEEDS[:8]:
                    a = run_simd(arches, bn, load, 'D', seed, reserve_frac=rf, ttl_ms=ttl)
                    b = run_simd_dp_module(arches, bn, load, 'D', seed, reserve_frac=rf, ttl_ms=ttl)
                    for k in ALLK:
                        d_total += 1
                        if abs(a[k]-b[k]) > 1e-9:
                            d_mismatch += 1
                            if d_mismatch <= 8:
                                print(f"  MISMATCH {tag}/{bn}/L{load}/rf{rf}/s{seed}/{k}: local={a[k]!r} dp={b[k]!r}")
print(f"  D comparisons: {d_total}, mismatches: {d_mismatch}")
if d_mismatch: fails.append("D not intact")
else: print("  D INTACT PASS")

# ---------------- CHECK 3: all-steady & all-spotty -> pull rows, armed 0 -------
print("\n=== CHECK 3: degenerate all-steady / all-spotty -> pull rows, armed 0.00 ===")
c3_ok = True
for name, arches in [('all-steady N2', A_STEADY_N2()), ('all-steady N3', A_STEADY_N3()),
                     ('all-spotty N2', A_SPOTTY_N2()), ('all-spotty N3', A_SPOTTY_N3())]:
    for bn in ('mid','edge'):
        for load in (0.65, 0.85):
            armed_vals = []; row_match = True
            for seed in SEEDS:
                dp = run_simd(arches, bn, load, 'Dp', seed)
                pl = run_simd(arches, bn, load, 'pull', seed)
                armed_vals.append(dp['armed_frac'])
                for k in SHARED:
                    if abs(dp[k]-pl[k]) > 1e-9:
                        row_match = False
            amax = max(armed_vals)
            ok = (amax == 0.0) and row_match
            c3_ok = c3_ok and ok
            print(f"  {name:14s} {bn:4s} L{load}: armed_max={amax:.4f} pull_row_match={row_match} res_tx0={dp['res_tx']} -> {'OK' if ok else 'FAIL'}")
if not c3_ok: fails.append("CHECK3 degenerate")
else: print("  CHECK 3 PASS")

# ---------------- CHECK 4: MID load 0.85 -> armed ~0 ? -------------------------
print("\n=== CHECK 4: MID (and EDGE) load 0.85 -> Dp armed_frac ===")
def arm_stats(arches, bn, load):
    av = [run_simd(arches, bn, load, 'Dp', s)['armed_frac'] for s in SEEDS]
    return med(av), min(av), max(av)
c4_results = {}
for arches, tag in [(A_N2(),'N2'), (A_N3(),'N3')]:
    for bn in ('mid','edge'):
        for load in (0.65, 0.85):
            m,lo,hi = arm_stats(arches, bn, load)
            c4_results[(tag,bn,load)] = m
            print(f"  {tag} {bn:4s} L{load}: armed_frac med={m:.4f} min={lo:.4f} max={hi:.4f}")
# CHECK 4 bar: MID load 0.85 armed ~0 (define ~0 as median <= 0.05)
mid_085 = [c4_results[('N2','mid',0.85)], c4_results[('N3','mid',0.85)]]
check4_pass = all(v <= 0.05 for v in mid_085)
print(f"  MID L0.85 armed medians: N2={mid_085[0]:.4f} N3={mid_085[1]:.4f} -> CHECK4 {'PASS' if check4_pass else 'FAIL (armed NOT ~0)'}")
if not check4_pass: fails.append("CHECK4 armed-not-zero")

# ---------------- net effect on MID (is arming harmless or net-negative?) ------
print("\n=== MID net-effect sanity (gp/loss%/p99 medians, L0.85) ===")
for arches, tag in [(A_N2(),'N2'), (A_N3(),'N3')]:
    for bn in ('mid','edge'):
        rows = {sc: [] for sc in ('pull','Dp','D')}
        for seed in SEEDS:
            rows['pull'].append(run_simd(arches, bn, 0.85, 'pull', seed))
            rows['Dp'].append(run_simd(arches, bn, 0.85, 'Dp', seed))
            rows['D'].append(run_simd(arches, bn, 0.85, 'D', seed, reserve_frac=0.25, ttl_ms=200.0))
        def m3(sc): return (med([r['gp'] for r in rows[sc]]), med([r['loss'] for r in rows[sc]]), med([r['p99'] for r in rows[sc]]))
        p=m3('pull'); d=m3('Dp'); dd=m3('D')
        print(f"  {tag} {bn:4s} | pull {p[0]:.0f}/{p[1]:.1f}/{p[2]:.0f} | Dp {d[0]:.0f}/{d[1]:.1f}/{d[2]:.0f} | D {dd[0]:.0f}/{dd[1]:.1f}/{dd[2]:.0f}")

print("\n================ SUMMARY ================")
print("FAILS:", fails if fails else "none")
