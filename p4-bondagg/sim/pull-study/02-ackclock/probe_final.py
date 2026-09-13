#!/usr/bin/env python3
import sys
sys.path.insert(0,'.')
from ackclock_sim import Sim, agg, make_defs, tether_cap, eth_cap
import heapq
off=0.85*(29000+78000); SEEDS=24
def A(dfn,sched,**kw): return agg([Sim(dfn(),lambda t:off,10.0,sd,sched=sched,**kw).run() for sd in range(SEEDS)])

# ---- Attack 4: severity table WITH pull (does B beat PULL under severe stall, or only push?) ----
print("=== EDGE stall severity: pull vs push vs B (build only showed push vs B) ===")
ecap=eth_cap()
sevs=[("none",tether_cap(dropouts=[])),
      ("mild",tether_cap(dropouts=[(a,a+0.25) for a in (3.0,6.0)])),
      ("medium",tether_cap(dropouts=[(a,a+0.40) for a in (2.6,5.1,7.6)])),
      ("severe",tether_cap(dropouts=[(a,a+0.70) for a in (2.2,4.0,5.8,7.6)]))]
for nm,tc in sevs:
    dfn=lambda tc=tc: make_defs('edge',tcap=tc,ecap=ecap)
    pu=A(dfn,'pull'); ph=A(dfn,'push'); b=A(dfn,'ack',w_ms=50,rto_ms=350,mirror=True)
    print("  %-7s pull gp=%6.0f loss=%3.1f p95=%3.0f | push gp=%6.0f loss=%3.1f p95=%3.0f | B gp=%6.0f loss=%3.1f p95=%3.0f"%
          (nm,pu['gp'],pu['loss'],pu['p95'],ph['gp'],ph['loss'],ph['p95'],b['gp'],b['loss'],b['p95']))

# ---- Attack 1: HONEST reverse ack path. Current model: ack delay = fixed propagation only.
# Stress: add reverse-path queueing delay that GROWS when the path's downstream is
# congested (shared-medium radio: uplink stall => downlink also delayed), + reverse jitter.
class SimHonestAck(Sim):
    def __init__(s,*a,rev_pen_ms=0.0,rev_jit_ms=0.0,**k):
        super().__init__(*a,**k); s.rev_pen=rev_pen_ms/1000.0; s.rev_jit=rev_jit_ms/1000.0
        s._now=0.0
    def run(s):
        # capture 'now' via _process_acks hook
        return super().run()
    def _deliver(s,i,seq,x2,now):
        if s.arr.get(seq) is None or x2 < s.arr[seq]:
            s.arr[seq]=x2
            if seq> s._maxarr: s._maxarr=seq
        rev=(s.defs[i]['loc_owd']+s.defs[i]['down_owd'])/1000.0
        # congestion-coupled reverse penalty: if downstream cap is low now, ack is delayed
        dcap=s.defs[i]['down_cap_fn'](now); cap0=s.defs[i]['cap_fn'](0.0)
        cong = max(0.0, 1.0 - dcap/max(1.0,cap0))   # 0 healthy .. ~1 during stall
        pen = s.rev_pen*cong
        jit = abs(s.ack_rng.gauss(0.0,s.rev_jit)) if s.rev_jit>0 else 0.0
        if s.ack_loss>0.0 and s.ack_rng.random()<s.ack_loss: return
        heapq.heappush(s.ack_heap,(x2+rev+pen+jit,i,seq))
def AH(dfn,**kw): return agg([SimHonestAck(dfn(),lambda t:off,10.0,sd,sched='ack',**kw).run() for sd in range(SEEDS)])
print("\n=== Attack1: honest congestion-coupled reverse ack path (MID-drop, B w=50 rto350) ===")
dfn=lambda: make_defs('mid',local_mult=20.0)
base=A(dfn,'ack',w_ms=50,rto_ms=350,mirror=True)
print("  ideal ack (fixed prop)      gp=%6.0f loss=%3.1f p50=%3.0f p95=%3.0f"%(base['gp'],base['loss'],base['p50'],base['p95']))
for pen,jit in [(0,10),(50,0),(100,0),(200,0),(100,20)]:
    r=AH(dfn,w_ms=50,rto_ms=350,mirror=True,rev_pen_ms=pen,rev_jit_ms=jit)
    print("  rev_pen=%3dms jit=%2dms         gp=%6.0f loss=%3.1f p50=%3.0f p95=%3.0f"%(pen,jit,r['gp'],r['loss'],r['p50'],r['p95']))
