#!/usr/bin/env python3
# =============================================================================
# Scheduler C prediction (vi): N=3 correlated (both EDGE and MID regimes) +
# A at edge-severe (the missing control -- probe_final.py's severity table
# only ever compared pull/push/B, never A ewma or C).
# C vs pull / A(ewma) / push / oracle.  gp/loss/p50/p95.  24 seeds, medians,
# paired physics.  Rigs reused VERBATIM from final.py (make_defs3, tA/tB) and
# probe_final.py (edge-severe tether cap trace).
# =============================================================================
import sys, time
from ackclock_sim import Sim, agg, make_defs, tether_cap, eth_cap, HUGE, QMAX_MS

try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
T = 10.0

CORE = [
    ("pull",   'pull',   {}),
    ("A ewma", 'ewma',   dict(mirror=True)),
    ("push",   'push',   {}),
    ("oracle", 'oracle', {}),
    ("C",      'C',      {}),
]
ORDER = [c[0] for c in CORE]


def runset(defs_fn, offer, scheds=CORE):
    ofn = lambda t: offer
    out = {}
    for name, sched, kw in scheds:
        ms = [Sim(defs_fn(), ofn, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)]
        out[name] = agg(ms)
    return out


def hdr():
    print("    %-10s %7s %6s %5s %5s %5s %6s %6s" %
          ("scheduler", "gp", "loss%", "p50", "p95", "p99", "tdrop", "late"))


def show(tag, res, order=ORDER):
    print(f"  [{tag}]")
    hdr()
    for name in order:
        a = res[name]
        print("    %-10s %7.0f %6.1f %5.0f %5.0f %5.0f %6.0f %6.0f" %
              (name, a['gp'], a['loss'], a['p50'], a['p95'], a['p99'], a['tdrop'], a['late']))
    print()
    return res


# ---- N=3 defs builder (verbatim from final.py: two spotty tethers + steady eth) ----
def make_defs3(mode, tA, tB, ecap):
    if mode == 'edge':
        return [
            dict(cap_fn=tA, local_cap_fn=tA, loc_owd=25.0, down_owd=2.0, jit=25.0,
                 jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
            dict(cap_fn=tB, local_cap_fn=tB, loc_owd=20.0, down_owd=2.0, jit=20.0,
                 jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
            dict(cap_fn=ecap, local_cap_fn=ecap, loc_owd=8.0, down_owd=1.0, jit=1.0,
                 jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
        ]
    return [
        dict(cap_fn=tA, local_cap_fn=lambda t: 30000 * 20, loc_owd=2.0, down_owd=25.0,
             jit=25.0, jit_stage='down', down_cap_fn=tA, down_qmax=QMAX_MS),
        dict(cap_fn=tB, local_cap_fn=lambda t: 23000 * 20, loc_owd=2.0, down_owd=20.0,
             jit=20.0, jit_stage='down', down_cap_fn=tB, down_qmax=QMAX_MS),
        dict(cap_fn=ecap, local_cap_fn=lambda t: 78000 * 20, loc_owd=1.0, down_owd=8.0,
             jit=1.0, jit_stage='down', down_cap_fn=ecap, down_qmax=QMAX_MS),
    ]


def main():
    t0 = time.time()
    print("#" * 88)
    print(f"# SCHEDULER C PREDICTION (vi): N=3 correlated (EDGE+MID) + A at edge-severe  seeds={SEEDS}")
    print("#" * 88)

    ecap = eth_cap()
    tA = tether_cap(base=30000, amp=22000, period=3.1, dropouts=[(a, a + 0.4) for a in (2.6, 6.0)])
    tB = tether_cap(base=23000, amp=17000, period=2.7, dropouts=[(a, a + 0.4) for a in (2.8, 6.2)])
    off3 = 0.85 * (30000 + 23000 + 78000)

    print("\n=== N=3 correlated [MID] (2 tethers drop together + eth; both hard-drop regime) ===")
    r_mid = show("correlated N=3 [mid]",
                 runset(lambda: make_defs3('mid', tA, tB, ecap), off3))

    print("=== N=3 correlated [EDGE] (2 tethers drop together + eth; both edge-bottleneck regime) ===")
    r_edge = show("correlated N=3 [edge]",
                  runset(lambda: make_defs3('edge', tA, tB, ecap), off3))

    print("=== EDGE-SEVERE (N=2, single tether+eth, 4x 700ms dropouts) -- A/C added as the missing control ===")
    off2 = 0.85 * (29000 + 78000)
    tc_severe = tether_cap(dropouts=[(a, a + 0.70) for a in (2.2, 4.0, 5.8, 7.6)])
    r_severe = show("edge-severe",
                    runset(lambda: make_defs('edge', tcap=tc_severe, ecap=ecap), off2))

    print(f"(elapsed {time.time()-t0:.0f}s)")

    # ---------------- verdicts ----------------
    print("\n" + "#" * 88)
    print("# VERDICTS (vi)")
    print("#" * 88)

    def pf(cond):
        return "PASS" if cond else "FAIL"

    for tag, r in (("N=3 MID", r_mid), ("N=3 EDGE", r_edge), ("edge-severe", r_severe)):
        c = r["C"]; pu = r["pull"]; a = r["A ewma"]; ph = r["push"]; o = r["oracle"]
        # C should not be worse than the weaker of pull/A on gp, and loss should
        # track (or beat) A ewma's loss (A is the closest existing estimator-based
        # comparator); p95 should not blow up past push's p95.
        gp_ok = c['gp'] >= min(pu['gp'], a['gp']) * 0.97
        loss_ok = c['loss'] <= a['loss'] + 1.0
        p95_ok = c['p95'] <= max(ph['p95'], a['p95']) * 1.15
        overall = gp_ok and loss_ok and p95_ok
        print(f"[{tag}] C gp={c['gp']:.0f} loss={c['loss']:.1f} p50={c['p50']:.0f} p95={c['p95']:.0f}  |  "
              f"pull gp={pu['gp']:.0f} loss={pu['loss']:.1f}  A gp={a['gp']:.0f} loss={a['loss']:.1f}  "
              f"push gp={ph['gp']:.0f} loss={ph['loss']:.1f}  oracle gp={o['gp']:.0f} loss={o['loss']:.1f}")
        print(f"   gp_ok(>=min(pull,A)*0.97)={pf(gp_ok)}  loss_ok(<=A+1.0)={pf(loss_ok)}  "
              f"p95_ok(<=max(push,A)*1.15)={pf(p95_ok)}  => {pf(overall)}")


if __name__ == '__main__':
    main()
