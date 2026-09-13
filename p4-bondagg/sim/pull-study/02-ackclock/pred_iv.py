#!/usr/bin/env python3
# Prediction (iv): ACK COMPRESSION -- reverse-path acks/echoes batched onto an
# 80ms grid (receiver-side ack coalescing). PASS if C ~unaffected (its lambda
# estimate is delta-cum/delta-server-time, which spans the batch since each
# echo/ack carries the server timestamp -> the SLOPE survives compression)
# where B collapses (B's credit release is a discrete per-seq ack event; batching
# does not lose info but B's canonical config uses RTO=350 for the "silence floor"
# and a bounded window W -- check whether coarse batching alone, even WITH B's
# canonical floor, still degrades B's admission cadence / gp vs the ack_comp=0
# baseline, and whether removing the floor makes it worse (deadlock)).
#
# Rig: MID-drop (make_defs('mid', local_mult=20.0)), canonical floor config for
# both schedulers as primary comparison (B: rto_ms=350, mirror=True, w_ms=50;
# C: probe_frames=4 default), plus a floor-OFF variant on B for depth.
import sys, time
sys.path.insert(0, '.')
from ackclock_sim import Sim, agg, make_defs

SEEDS = 24
T = 10.0
off2 = 0.85 * (29000 + 78000)
dfn = lambda: make_defs('mid', local_mult=20.0)

def A(sched, **kw):
    return agg([Sim(dfn(), lambda t: off2, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)])

def row(label, m):
    print("  %-28s gp=%7.0f loss=%5.1f%%  p50=%4.0f p95=%4.0f p99=%4.0f  tdrop=%5.0f qdrops=%5.0f late=%5.0f  c_lost=%5.0f c_probe=%5.0f" % (
        label, m['gp'], m['loss'], m['p50'], m['p95'], m['p99'], m['tdrop'], m['qdrops'], m['late'],
        m.get('c_lost', 0), m.get('c_probe', 0)))

t0 = time.time()
print("=" * 100)
print(f"PREDICTION iv: ack compression batched 80ms. rig=MID-drop seeds={SEEDS}")
print("=" * 100)

print("\n--- ack_comp_ms = 0 (baseline, no compression) ---")
b0 = A('ack', w_ms=50, rto_ms=350, mirror=True, ack_comp_ms=0.0)
c0 = A('C', ack_comp_ms=0.0)
row("B (rto=350, floor ON)", b0)
row("C (probe=4, floor ON)", c0)

print("\n--- ack_comp_ms = 80 (batched) ---")
b80        = A('ack', w_ms=50, rto_ms=350, mirror=True, ack_comp_ms=80.0)
b80_nofloor= A('ack', w_ms=50, rto_ms=None, mirror=True, ack_comp_ms=80.0)
c80        = A('C', ack_comp_ms=80.0)
row("B (rto=350, floor ON)",   b80)
row("B (rto=None, floor OFF)", b80_nofloor)
row("C (probe=4, floor ON)",   c80)

print(f"\nelapsed {time.time()-t0:.0f}s")
