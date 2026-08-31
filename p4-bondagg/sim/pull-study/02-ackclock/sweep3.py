#!/usr/bin/env python3
import sys, time
from ackclock_sim import Sim, agg, make_defs
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 10
T = 10.0
offer = 0.85*(29000+78000); ofn=lambda t: offer
dfn = lambda: make_defs('mid', local_mult=20.0)

def run(sched, **kw):
    ms=[Sim(dfn(), ofn, T, sd, sched=sched, **kw).run() for sd in range(seeds)]
    a=agg(ms); a['qdrops']=agg(ms).get('qdrops',0); return a
def pr(tag, a):
    print(f"  {tag:34s} gp={a['gp']:6.0f} loss={a['loss']:5.1f} p50={a['p50']:4.0f} "
          f"p95={a['p95']:4.0f} depth={a['depth']:4.0f} tdrop={a['tdrop']:5.0f} qdr={a['qdrops']:5.0f}")

t0=time.time()
pr("push", run('push'))
pr("oracle", run('oracle'))
print("-- symmetric w, mirror ON, rto=400 --")
for w in (50, 70, 90):
    pr(f"B w={w}", run('ack', w_ms=w, rto_ms=400, mirror=True))
print("-- symmetric w, mirror OFF, rto=400 --")
for w in (50, 70, 90):
    pr(f"B w={w} nomir", run('ack', w_ms=w, rto_ms=400, mirror=False))
print("-- asymmetric (wt,we), mirror OFF, rto=400 --")
for wt,we in [(50,50),(50,90),(50,150),(70,150),(90,150)]:
    pr(f"B wt={wt} we={we} nomir", run('ack', w_ms=[wt,we], rto_ms=400, mirror=False))
print("-- asymmetric (wt,we), mirror ON, rto=400 --")
for wt,we in [(50,50),(50,90),(50,150),(70,150)]:
    pr(f"B wt={wt} we={we} mir", run('ack', w_ms=[wt,we], rto_ms=400, mirror=True))
print(f"elapsed {time.time()-t0:.1f}s")
