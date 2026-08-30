import sys
from ackclock_sim import Sim, agg, make_defs
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
offer=0.85*(29000+78000); ofn=lambda t: offer; T=10.0; seeds=10
def run(dfn,sched,**kw): return agg([Sim(dfn(),ofn,T,sd,sched=sched,**kw).run() for sd in range(seeds)])
def pr(tag,a): print(f"  {tag:26s} gp={a['gp']:6.0f} loss={a['loss']:5.1f} late={a['late']:5.0f} qdr={a['qdrops']:5.0f} p50={a['p50']:4.0f} p95={a['p95']:4.0f} p99={a['p99']:4.0f}")
for rig,dfn in [("MID-drop",lambda: make_defs('mid',local_mult=20.0)),("MID-shape",lambda: make_defs('mid',local_mult=20.0,shaping=True))]:
    print(f"== {rig}: shallow-pool sweep ==")
    for mq in (300,150,80):
        pr(f"push maxq={mq}",run(dfn,'push',maxq_ms=mq))
    for mq in (300,150,80):
        pr(f"B w=50 maxq={mq}",run(dfn,'ack',w_ms=50,rto_ms=400,mirror=True,maxq_ms=mq))
    print()
