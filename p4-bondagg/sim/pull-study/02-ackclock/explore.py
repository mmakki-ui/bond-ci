#!/usr/bin/env python3
import sys, time
from ackclock_sim import Sim, agg, make_defs
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
T = 10.0
offer = 0.85 * (29000 + 78000); ofn = lambda t: offer

def run(defs_fn, sched, **kw):
    ms = [Sim(defs_fn(), ofn, T, sd, sched=sched, **kw).run() for sd in range(seeds)]
    return agg(ms)

def pr(tag, a):
    print(f"    {tag:22s} gp={a['gp']:6.0f} loss={a['loss']:5.1f} p50={a['p50']:4.0f} "
          f"p95={a['p95']:4.0f} p99={a['p99']:4.0f} depth={a['depth']:4.0f} "
          f"hol={a['hol']:4.0f} tdrop={a['tdrop']:5.0f} tshr={a['tshare']:.2f}")

t0 = time.time()
for rig, dfn in [("EDGE", lambda: make_defs('edge')),
                 ("MID-drop", lambda: make_defs('mid', local_mult=20.0)),
                 ("MID-shape", lambda: make_defs('mid', local_mult=20.0, shaping=True))]:
    print(f"== {rig} ==")
    pr("push (ref)", run(dfn, 'push'))
    pr("oracle (ref)", run(dfn, 'oracle'))
    pr("A ewma+mir", run(dfn, 'ewma', mirror=True))
    for wm in (0.5, 1.0, 2.0):
        pr(f"B ack wm={wm} +mir", run(dfn, 'ack', wmult=wm, mirror=True, rto_ms=250))
    pr("B ack wm=1 lat +mir", run(dfn, 'ack', wmult=1.0, lat_bias=True, mirror=True, rto_ms=250))
    print()
print(f"elapsed {time.time()-t0:.1f}s  seeds={seeds}")
