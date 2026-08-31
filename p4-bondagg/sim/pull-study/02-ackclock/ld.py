import sys
from ackclock_sim import Sim, agg, make_defs
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
offer=0.85*(29000+78000); ofn=lambda t: offer; T=10.0; seeds=10
dfn=lambda: make_defs('mid',local_mult=20.0)
def run(sched,**kw): return agg([Sim(dfn(),ofn,T,sd,sched=sched,**kw).run() for sd in range(seeds)])
def pr(tag,a): print(f"  {tag:22s} gp={a['gp']:6.0f} loss={a['loss']:5.1f} tdrop={a['tdrop']:5.0f} late={a['late']:5.0f} qdr={a['qdrops']:4.0f} p50={a['p50']:4.0f} p95={a['p95']:4.0f} depth={a['depth']:4.0f}")
pr("push",run('push')); pr("oracle",run('oracle'))
for w in (50,90):
    pr(f"B sym w={w}",run('ack',w_ms=w,rto_ms=400,mirror=True))
for wt,we in [(50,50),(50,150)]:
    pr(f"B wt={wt} we={we}",run('ack',w_ms=[wt,we],rto_ms=400,mirror=True))
