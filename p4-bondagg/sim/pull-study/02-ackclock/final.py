#!/usr/bin/env python3
# =============================================================================
# FINAL comparison: ACK-CLOCKED POOLED-WATER PULL (B) vs the statistical hybrid
# (A) vs PUSH / ORACLE / PULL-only, across EDGE / MID / regression / Q4 rigs.
# 24 seeds, medians, paired physics (same deterministic cap trace per rig).
# =============================================================================
import sys, math, time
from ackclock_sim import (Sim, agg, make_defs, tether_cap, eth_cap,
                          HUGE, QMAX_MS, PKT_KB)
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
T = 10.0

# canonical B config (estimator-free): symmetric window ~50ms inflight horizon,
# coarse RTO/pacing-floor 350ms, opportunistic mirror on.
BCFG = dict(w_ms=50, rto_ms=350, mirror=True)


def runset(defs_fn, offer, scheds):
    ofn = lambda t: offer
    out = {}
    for name, sched, kw in scheds:
        ms = [Sim(defs_fn(), ofn, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)]
        out[name] = agg(ms)
    return out

def hdr():
    print("    %-14s %7s %6s %5s %5s %5s %6s %6s %6s" %
          ("scheduler", "gp", "loss%", "p50", "p95", "p99", "depth", "tdrop", "late"))

def show(tag, res, order):
    print(f"  [{tag}]")
    hdr()
    for name in order:
        a = res[name]
        print("    %-14s %7.0f %6.1f %5.0f %5.0f %5.0f %6.0f %6.0f %6.0f" %
              (name, a['gp'], a['loss'], a['p50'], a['p95'], a['p99'],
               a['depth'], a['tdrop'], a['late']))
    print()

CORE = [
    ("pull",   'pull',   {}),
    ("push",   'push',   {}),
    ("oracle", 'oracle', {}),
    ("A ewma",  'ewma',  dict(mirror=True)),
    ("B ack",   'ack',   BCFG),
    ("B ack+lat",'ack',  dict(**BCFG, lat_bias=True)),
]
ORDER = [c[0] for c in CORE]


# ---- N=3 defs builder (two spotty tethers + steady eth) ----
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
        dict(cap_fn=tA, local_cap_fn=lambda t: 30000*20, loc_owd=2.0, down_owd=25.0,
             jit=25.0, jit_stage='down', down_cap_fn=tA, down_qmax=QMAX_MS),
        dict(cap_fn=tB, local_cap_fn=lambda t: 23000*20, loc_owd=2.0, down_owd=20.0,
             jit=20.0, jit_stage='down', down_cap_fn=tB, down_qmax=QMAX_MS),
        dict(cap_fn=ecap, local_cap_fn=lambda t: 78000*20, loc_owd=1.0, down_owd=8.0,
             jit=1.0, jit_stage='down', down_cap_fn=ecap, down_qmax=QMAX_MS),
    ]


def main():
    t0 = time.time()
    off2 = 0.85 * (29000 + 78000)
    print("#" * 78)
    print(f"# ACK-CLOCK STUDY  seeds={SEEDS}  B={BCFG}")
    print("#" * 78)

    # ============ SECTION 1: core rigs (edge / mid) ============
    print("\n=== 1. CORE: EDGE vs MID-network bottleneck ===")
    show("EDGE  (spotty cap on local socket)",
         runset(lambda: make_defs('edge'), off2, CORE), ORDER)
    show("MID-drop  (spotty cap downstream, hard 400ms dropouts)",
         runset(lambda: make_defs('mid', local_mult=20.0), off2, CORE), ORDER)
    show("MID-shape (downstream throttle to 4Mb, NO outage -- purest hidden cap)",
         runset(lambda: make_defs('mid', local_mult=20.0, shaping=True), off2, CORE), ORDER)

    # ============ SECTION 2: EDGE win magnitude (severity) ============
    print("=== 2. EDGE stall-severity (does B keep pull's lag-free stall win vs push?) ===")
    ecap = eth_cap()
    sevs = [
        ("none",   tether_cap(dropouts=[])),
        ("mild",   tether_cap(dropouts=[(a, a+0.25) for a in (3.0, 6.0)])),
        ("medium", tether_cap(dropouts=[(a, a+0.40) for a in (2.6, 5.1, 7.6)])),
        ("severe", tether_cap(dropouts=[(a, a+0.70) for a in (2.2, 4.0, 5.8, 7.6)])),
    ]
    for nm, tc in sevs:
        res = runset(lambda tc=tc: make_defs('edge', tcap=tc, ecap=ecap), off2, CORE)
        p = res['push']; b = res['B ack']
        dgp = 100*(b['gp']/p['gp'] - 1) if p['gp'] else 0
        print(f"  edge-{nm:7s}  push gp={p['gp']:6.0f} loss={p['loss']:4.1f} p95={p['p95']:4.0f}"
              f"  |  B gp={b['gp']:6.0f} loss={b['loss']:4.1f} p95={b['p95']:4.0f}"
              f"  ({dgp:+.0f}% gp vs push)")
    print()

    # ============ SECTION 3: regression rigs ============
    print("=== 3. REGRESSION rigs (anti-overfitting) ===")
    flap = tether_cap(dropouts=[(a, a+0.22) for a in (1.6,2.4,3.2,4.0,4.8,5.6,6.4,7.2,8.0)])
    longstall = tether_cap(dropouts=[(3.0, 4.5)])
    def softdip(t):
        for (a, b) in [(2.6, 3.3), (5.1, 5.8), (7.6, 8.3)]:
            if a <= t < b:
                return 1800.0
        return tether_cap(dropouts=[])(t)
    for mode in ('edge', 'mid'):
        mk = (lambda tc: (lambda: make_defs(mode, tcap=tc, local_mult=20.0)))
        show(f"rapid-flap [{mode}] (9x 220ms dropouts)", runset(mk(flap), off2, CORE), ORDER)
        show(f"asym-long-stall [{mode}] (single 1.5s outage)", runset(mk(longstall), off2, CORE), ORDER)
    show("soft-partial-dip [edge] (throttle to 1.8Mb, no outage)",
         runset(lambda: make_defs('edge', tcap=softdip, ecap=ecap), off2, CORE), ORDER)

    # correlated both-tethers N=3 (mid)
    tA = tether_cap(base=30000, amp=22000, period=3.1, dropouts=[(a, a+0.4) for a in (2.6, 6.0)])
    tB = tether_cap(base=23000, amp=17000, period=2.7, dropouts=[(a, a+0.4) for a in (2.8, 6.2)])  # overlaps A
    off3 = 0.85 * (30000 + 23000 + 78000)
    show("correlated N=3 [mid] (2 tethers drop together + eth)",
         runset(lambda: make_defs3('mid', tA, tB, ecap), off3, CORE), ORDER)
    show("correlated N=3 [edge] (2 tethers drop together + eth)",
         runset(lambda: make_defs3('edge', tA, tB, ecap), off3, CORE), ORDER)

    print(f"\n(section 1-3 elapsed {time.time()-t0:.0f}s)")


if __name__ == '__main__':
    main()
