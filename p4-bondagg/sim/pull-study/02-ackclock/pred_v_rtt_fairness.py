#!/usr/bin/env python3
# =============================================================================
# Scheduler C prediction (v): RTT-fairness.
# Two EQUAL-CAP paths (flat 50000 KB/s each, no dropouts, small symmetric
# jitter for realistic seed variance) differing ONLY in one-way owd: 5ms vs
# 60ms (RTT 10ms vs 120ms after the model's symmetric-reverse-path doubling).
# 'edge'-shape single-stage bottleneck (down stage = HUGE passthrough) so the
# ONLY asymmetry between the two paths is RTT, not capacity or queueing
# structure.
#
# PASS if C's low-RTT-path share (tshare, path0) stays ~=0.50 using C's
# DEFAULT config (no per-deployment window tuning) -- contrasted against B
# (ack), which uses ONE static w_ms=50 window (the SAME canonical config used
# everywhere else in this study) sized for the ~10-30ms RTTs seen in the
# EDGE/MID rigs, and so is NOT retuned for a 120ms-RTT path here.
# =============================================================================
import sys, time
from ackclock_sim import Sim, agg, HUGE, QMAX_MS

try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
T = 10.0
CAP = 50000.0          # KB/s, IDENTICAL on both paths -- physics is symmetric
OWD_LO = 5.0            # ms one-way
OWD_HI = 60.0           # ms one-way
JIT = 3.0                # ms, SAME on both paths (small, symmetric -- not a fairness confound)

def make_defs_rtt():
    capfn = lambda t: CAP
    return [
        dict(cap_fn=capfn, local_cap_fn=capfn, loc_owd=OWD_LO, down_owd=0.0,
             jit=JIT, jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
        dict(cap_fn=capfn, local_cap_fn=capfn, loc_owd=OWD_HI, down_owd=0.0,
             jit=JIT, jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
    ]

# saturate: offer > combined cap so both paths are genuinely contended
# (steady contention exposes any window-imposed throughput asymmetry).
OFFER = 1.10 * (2 * CAP)
BCFG = dict(w_ms=50, rto_ms=350, mirror=True)   # canonical B config, UNCHANGED

CORE = [
    ("pull",     'pull',   {}),
    ("push",     'push',   {}),
    ("oracle",   'oracle', {}),
    ("A ewma",   'ewma',   dict(mirror=True)),
    ("B ack",    'ack',    BCFG),
    ("C",        'C',      {}),   # all-defaults: NO per-deployment tuning
]

def runset():
    ofn = lambda t: OFFER
    out = {}
    for name, sched, kw in CORE:
        ms = [Sim(make_defs_rtt(), ofn, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)]
        out[name] = agg(ms)
    return out

def main():
    t0 = time.time()
    print("#" * 88)
    print(f"# SCHEDULER C PREDICTION (v): RTT-FAIRNESS  seeds={SEEDS}  "
          f"cap={CAP:.0f}KB/s both paths, owd {OWD_LO:.0f}ms vs {OWD_HI:.0f}ms, "
          f"offer={OFFER:.0f} (sat={OFFER/(2*CAP):.2f}x)")
    print("#" * 88)
    r = runset()
    print("    %-10s %7s %6s %5s %5s %5s %7s %6s" %
          ("scheduler", "gp", "loss%", "p50", "p95", "p99", "tshare0", "tdrop"))
    for name, _, _ in CORE:
        a = r[name]
        print("    %-10s %7.0f %6.1f %5.0f %5.0f %5.0f %7.3f %6.0f" %
              (name, a['gp'], a['loss'], a['p50'], a['p95'], a['p99'], a['tshare'], a['tdrop']))
    print(f"\n(elapsed {time.time()-t0:.0f}s)")

    print("\n" + "#" * 88)
    print("# VERDICT (v)")
    print("#" * 88)
    c = r["C"]; b = r["B ack"]; pu = r["pull"]; ph = r["push"]; o = r["oracle"]; a = r["A ewma"]
    tol = 0.05
    c_ok = abs(c['tshare'] - 0.50) <= tol
    print(f"C     tshare0={c['tshare']:.3f}  |delta from 0.50|={abs(c['tshare']-0.50):.3f}  "
          f"(tol {tol}) => {'PASS' if c_ok else 'FAIL'}")
    print(f"B ack tshare0={b['tshare']:.3f}  (same canonical w_ms=50 config used everywhere else, "
          f"NOT retuned for 60ms owd -- shown for contrast, not part of the PASS condition)")
    print(f"pull={pu['tshare']:.3f}  push={ph['tshare']:.3f}  oracle={o['tshare']:.3f}  "
          f"A ewma={a['tshare']:.3f}  (context: window-free/rate-based scheds)")
    print(f"\n(v) RTT-fairness: C low-RTT share ~=0.50 with NO per-deployment window tuning "
          f"=> {'PASS' if c_ok else 'FAIL'}")

if __name__ == '__main__':
    main()
