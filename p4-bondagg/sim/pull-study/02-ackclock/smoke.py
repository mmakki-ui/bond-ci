#!/usr/bin/env python3
# smoke test: does the unified harness reproduce attack1's baseline numbers?
# attack1 mid-drop: pull gp~78915 loss~13.1 ; push gp~87008 loss~4.2 ; oracle gp~88166 loss~3.0
# attack1 edge    : pull gp~90182 loss~0.7  ; push gp~89436 loss~1.6 ; oracle gp~90374 loss~0.5
import sys
from ackclock_sim import Sim, agg, make_defs
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

seeds = 16; T = 10.0
offer = 0.85 * (29000 + 78000); ofn = lambda t: offer

def row(tag, defs_fn, scheds):
    print(f"  {tag}")
    for sched in scheds:
        ms = [Sim(defs_fn(), ofn, T, sd, sched=sched, mirror=False).run() for sd in range(seeds)]
        a = agg(ms)
        print(f"    {sched:8s} gp={a['gp']:6.0f} loss={a['loss']:5.1f} p50={a['p50']:4.0f} "
              f"p95={a['p95']:4.0f} p99={a['p99']:4.0f} depth={a['depth']:4.0f} "
              f"tdrop={a['tdrop']:5.0f} tshr={a['tshare']:.2f}")

print("EDGE (spotty cap on local socket):")
row("edge", lambda: make_defs('edge'), ['pull', 'push', 'oracle'])
print("MID-drop (spotty cap downstream, hard dropouts):")
row("mid", lambda: make_defs('mid', local_mult=20.0), ['pull', 'push', 'oracle'])
