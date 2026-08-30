#!/usr/bin/env python3
# =============================================================================
# SECTION 4: ACK-PATH CAVEATS (stress the ack-clock's Achilles heels)
#   (a) reverse-path ACK LOSS   (b) ACK COMPRESSION (bursty ack arrival)
#   (c) RTT-UNFAIRNESS (low-RTT path returns credits faster -> hogs?)
#   + does the coarse PACING-TIMER FLOOR (rto) fix ack-loss / compression?
# =============================================================================
import sys, math, time
from ackclock_sim import Sim, agg, make_defs, tether_cap, eth_cap, HUGE, QMAX_MS
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
T = 10.0

def runset(defs_fn, offer, scheds):
    ofn = lambda t: offer
    return {name: agg([Sim(defs_fn(), ofn, T, sd, sched=sched, **kw).run()
                       for sd in range(SEEDS)]) for (name, sched, kw) in scheds}

def line(tag, a, extra=""):
    print("  %-30s gp=%6.0f loss=%5.1f p50=%4.0f p95=%4.0f p99=%4.0f depth=%5.0f tshr=%.2f %s" %
          (tag, a['gp'], a['loss'], a['p50'], a['p95'], a['p99'], a['depth'], a['tshare'], extra))

off2 = 0.85 * (29000 + 78000)

def main():
    t0 = time.time()
    print("#"*78); print(f"# SECTION 4: ACK-PATH CAVEATS  seeds={SEEDS}"); print("#"*78)

    # ---- (a) reverse-path ACK LOSS: no-floor vs pacing-floor ----
    print("\n=== 4a. REVERSE-PATH ACK LOSS (does it jam the window? does the floor fix it?) ===")
    for rig, dfn in [("EDGE", lambda: make_defs('edge')),
                     ("MID-drop", lambda: make_defs('mid', local_mult=20.0))]:
        print(f"  -- {rig} --")
        for al in (0.0, 0.15, 0.35):
            sc = [(f"B ackloss={al} NO-floor", 'ack', dict(w_ms=50, rto_ms=None, mirror=True, ack_loss=al)),
                  (f"B ackloss={al} floor350", 'ack', dict(w_ms=50, rto_ms=350, mirror=True, ack_loss=al))]
            r = runset(dfn, off2, sc)
            for nm, _, _ in sc:
                line(nm, r[nm])
        print()

    # ---- (b) ACK COMPRESSION (bursty ack arrival) ----
    print("=== 4b. ACK COMPRESSION (acks batched every N ms -> bursty credit release) ===")
    for rig, dfn in [("EDGE", lambda: make_defs('edge')),
                     ("MID-drop", lambda: make_defs('mid', local_mult=20.0))]:
        print(f"  -- {rig} --")
        for comp in (0.0, 40.0, 80.0):
            sc = [(f"B comp={comp}ms floor350", 'ack', dict(w_ms=50, rto_ms=350, mirror=True, ack_comp_ms=comp))]
            r = runset(dfn, off2, sc)
            line(f"B comp={comp}ms floor350", r[f"B comp={comp}ms floor350"])
        print()

    # ---- (c) RTT-UNFAIRNESS: equal cap, very different RTT ----
    print("=== 4c. RTT-UNFAIRNESS (two EQUAL-cap paths, owd 5ms vs 60ms). tshr=low-RTT share ===")
    print("      fair share = 0.50. does the low-RTT path hog? does per-RTT window sizing fix it?")
    def rtt_defs(mode='edge'):
        # path0 = LOW rtt (owd 5), path1 = HIGH rtt (owd 60). equal steady cap 40Mb.
        c = lambda t: 40000.0
        if mode == 'edge':
            return [dict(cap_fn=c, local_cap_fn=c, loc_owd=5.0, down_owd=1.0, jit=2.0,
                         jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
                    dict(cap_fn=c, local_cap_fn=c, loc_owd=60.0, down_owd=1.0, jit=2.0,
                         jit_stage='local', down_cap_fn=lambda t: HUGE, down_qmax=HUGE)]
    offR = 0.85 * (40000 + 40000)
    sc = [
        ("push", 'push', {}),
        ("oracle", 'oracle', {}),
        ("B w=50 (fixed ms)", 'ack', dict(w_ms=50, rto_ms=350, mirror=True)),
        ("B w=150 (>=maxRTT)", 'ack', dict(w_ms=150, rto_ms=350, mirror=True)),
        ("B w_frames=64 (EQUAL frames)", 'ack', dict(w_frames=64, rto_ms=350, mirror=True)),
    ]
    r = runset(lambda: rtt_defs('edge'), offR, sc)
    for nm, _, _ in sc:
        line(nm, r[nm], extra="(tshr=low-RTT path0 share)")
    print(f"\n(section 4 elapsed {time.time()-t0:.0f}s)")

if __name__ == '__main__':
    main()
