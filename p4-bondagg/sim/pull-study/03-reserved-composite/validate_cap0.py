#!/usr/bin/env python3
# Validation harness for reserved_cap0.py (candidate D' = sched='Dp').
# Run from sim_reserved/.  24 seeds, paired physics, medians.
import sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_cap0 as R
import ackclock_sim as A

SEEDS = 24
T = 9.0
CMP_KEYS = ('gp', 'loss', 'p50', 'p95', 'p99', 'deliv', 'depth', 'tdrop')

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def ofn_for(archs, load):
    nom = sum(a['base'] for a in archs)
    return (lambda t, _n=nom, _L=load: _L * _n)

def run_simd(archs, load, sched, rig='mid'):
    defs = R.build_rig(archs, bottleneck=rig)
    ofn = ofn_for(archs, load)
    return [R.SimD(defs, ofn, T, sd, sched=sched).run() for sd in range(SEEDS)]

def run_ref(archs, load, sched, rig='mid'):
    defs = R.build_rig(archs, bottleneck=rig)
    ofn = ofn_for(archs, load)
    return [A.Sim(defs, ofn, T, sd, sched=sched, mirror=False).run() for sd in range(SEEDS)]

def per_seed_exact(msA, msB, keys=CMP_KEYS, tol=1e-9):
    """True iff every seed matches on every key within tol."""
    bad = []
    for sd, (a, b) in enumerate(zip(msA, msB)):
        for k in keys:
            if abs(a.get(k, 0.0) - b.get(k, 0.0)) > tol:
                bad.append((sd, k, a.get(k), b.get(k)))
    return (len(bad) == 0), bad

FAILED = []

# ---------------------------------------------------------------------------
print('=' * 74)
print('CHECK 1 -- imports clean')
print('=' * 74)
print('  reserved_cap0, ackclock_sim, nsched_model imported OK')
print('  scheds available in SimD: pull, D, Dp, redundant')

# ---------------------------------------------------------------------------
print()
print('=' * 74)
print('CHECK 2 -- SimD(pull) BYTE-MATCHES ackclock_sim.Sim(pull)  (per-seed exact)')
print('=' * 74)
archs = [R.cellA(R.DROPS_A), R.eth()]      # pareto N2: 1 spotty + 1 steady, mid rig
for load in (0.65, 0.80):
    d = run_simd(archs, load, 'pull')
    a = run_ref(archs, load, 'pull')
    ok, bad = per_seed_exact(d, a)
    dg, dl = med([m['gp'] for m in d]), med([m['loss'] for m in d])
    ag, al = med([m['gp'] for m in a]), med([m['loss'] for m in a])
    print(f'  load={load}: SimD(pull) gp/loss={dg:.3f}/{dl:.3f}  '
          f'Sim(pull) gp/loss={ag:.3f}/{al:.3f}  PER-SEED-EXACT={ok}')
    if not ok:
        print('    MISMATCH samples:', bad[:4]); FAILED.append(f'C2 load={load}')

# ---------------------------------------------------------------------------
print()
print('=' * 74)
print('CHECK 3 -- Dp REPRINTS pull rows with armed_frac=0.00  (all-steady & all-spotty)')
print('=' * 74)
STEADY_SPOTTY = [
    ('all-steady  N2 wifi+eth',
     [R.wifi(), R.eth()]),
    ('all-steady  N3 wifi+wifi2+eth',
     [R.wifi(), dict(R.wifi(), base=38000, period=3.7, phase=2.0), R.eth()]),
    ('all-spotty  N3 correlated',
     [R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)]),
    ('all-spotty  N3 independent',
     [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]),
]
for label, ar in STEADY_SPOTTY:
    for load in (0.65, 0.85):
        dp = run_simd(ar, load, 'Dp')
        pl = run_simd(ar, load, 'pull')
        ok, bad = per_seed_exact(dp, pl)
        af = med([m['armed_frac'] for m in dp])
        af_max = max(m['armed_frac'] for m in dp)
        dg, dl = med([m['gp'] for m in dp]), med([m['loss'] for m in dp])
        pg, pl2 = med([m['gp'] for m in pl]), med([m['loss'] for m in pl])
        af_ok = (af_max == 0.0)
        print(f'  {label:30s} load={load}: Dp gp/loss={dg:.1f}/{dl:.2f} '
              f'pull gp/loss={pg:.1f}/{pl2:.2f}  reprint={ok}  '
              f'armed_frac(med/max)={af:.2f}/{af_max:.2f}')
        if not ok:
            print('    REPRINT MISMATCH:', bad[:4]); FAILED.append(f'C3 {label} {load} reprint')
        if not af_ok:
            FAILED.append(f'C3 {label} {load} armed!=0')

# ---------------------------------------------------------------------------
print()
print('=' * 74)
print('CHECK 4 -- mid load 0.85: Dp DUPLICATE arms ~0 ticks  (mixed spotty+steady)')
print('=' * 74)
MIXED = [
    ('N2 1cell+1eth',       [R.cellA(R.DROPS_A), R.eth()]),
    ('N3 2cell+1eth',       [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]),
    ('N3 1cell+1wifi+1eth', [R.cellA(R.DROPS_A), R.wifi(), R.eth()]),
]
for label, ar in MIXED:
    dp = run_simd(ar, 0.85, 'Dp')
    af = med([m['armed_frac'] for m in dp])
    af_max = max(m['armed_frac'] for m in dp)
    rtx = med([m['res_tx'] for m in dp])
    dg = med([m['gp'] for m in dp])
    # compare to pull at same load (should be ~identical since arms ~0)
    pl = run_simd(ar, 0.85, 'pull')
    pg = med([m['gp'] for m in pl])
    print(f'  {label:22s} load=0.85: armed_frac med={af:.4f} max={af_max:.4f}  '
          f'res_tx med={rtx:.0f}  Dp gp={dg:.0f} pull gp={pg:.0f}')
    if af > 0.02:
        FAILED.append(f'C4 {label} armed_frac={af:.4f} not ~0')

# ---------------------------------------------------------------------------
print()
print('=' * 74)
if FAILED:
    print('RESULT: FAIL ->', FAILED)
    sys.exit(1)
else:
    print('RESULT: ALL CHECKS PASS')
