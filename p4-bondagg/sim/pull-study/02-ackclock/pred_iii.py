#!/usr/bin/env python3
# Prediction (iii): reverse-path ACK LOSS 15% and 35%, WITH and WITHOUT the
# coarse pacing/silence floor -- scheduler C vs scheduler B (ack-clock).
#
# Rig: MID-drop (make_defs('mid', local_mult=20.0)) -- the hard hidden-cap rig
# where B's known weakness under stress shows up (baseline B ack ~86051/5.3%).
#
# "coarse pacing/silence floor":
#   B (sched='ack')  -> rto_ms: the credit-reclaim timer. floor ON = rto_ms=350
#                       (canonical BCFG), floor OFF = rto_ms=None (pure ack-window,
#                       credit can never be reclaimed if the ack is permanently lost).
#   C (sched='C')    -> probe_frames: the MIN-WINDOW keep-alive floor (the
#                       "ESCAPE HATCH" in room() -- `if inflight < probe_frames:
#                       return True`, bypassing the strict age-gate so the meter
#                       never fully latches). floor ON = probe_frames=4 (default),
#                       floor OFF = probe_frames=0 (strict age-gate only; C still
#                       has its independent, ack-INDEPENDENT age-based repair in
#                       c_repair='age', which purges flight_ts by WALL-CLOCK age
#                       regardless of whether any ack/echo ever arrives).
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
print(f"PREDICTION iii: reverse ack loss 15%/35%, WITH/WITHOUT coarse pacing-silence floor. rig=MID-drop seeds={SEEDS}")
print("=" * 100)

for loss in (0.15, 0.35):
    print(f"\n--- ack_loss = {loss*100:.0f}% ---")
    b_floor_on  = A('ack', w_ms=50, rto_ms=350, mirror=True, ack_loss=loss)
    b_floor_off = A('ack', w_ms=50, rto_ms=None, mirror=True, ack_loss=loss)
    c_floor_on  = A('C', ack_loss=loss)                     # probe_frames default=4
    c_floor_off = A('C', ack_loss=loss, probe_frames=0)
    row("B floor ON  (rto=350)",   b_floor_on)
    row("B floor OFF (rto=None)",  b_floor_off)
    row("C floor ON  (probe=4)",   c_floor_on)
    row("C floor OFF (probe=0)",   c_floor_off)

print(f"\nelapsed {time.time()-t0:.0f}s")
