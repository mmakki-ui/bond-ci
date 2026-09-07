#!/usr/bin/env python3
# Is the RTT-fairness "fix" (window >= maxRTT) real, or does it just make the
# window NON-BINDING so B degenerates to pull (i.e. turns off the ack-clock)?
import sys
sys.path.insert(0,'.')
from ackclock_sim import Sim, agg, HUGE, PKT_KB
offR=0.85*(40000+40000)
def rtt_defs():
    c=lambda t:40000.0
    return [dict(cap_fn=c,local_cap_fn=c,loc_owd=5.0,down_owd=1.0,jit=2.0,jit_stage='local',down_cap_fn=lambda t:HUGE,down_qmax=HUGE),
            dict(cap_fn=c,local_cap_fn=c,loc_owd=60.0,down_owd=1.0,jit=2.0,jit_stage='local',down_cap_fn=lambda t:HUGE,down_qmax=HUGE)]
SEEDS=24
def rr(nm,sched,kw):
    a=agg([Sim(rtt_defs(),lambda t:offR,10.0,sd,sched=sched,**kw).run() for sd in range(SEEDS)])
    print("  %-26s gp=%6.0f loss=%4.1f p50=%4.0f p95=%4.0f tshr=%.2f"%(nm,a['gp'],a['loss'],a['p50'],a['p95'],a['tshare']))

print("=== RTT rig: maxRTT = 2*(60+1)=122ms. Does w=150 'fix' == pull? ===")
rr('pull (no window)','pull',{})
rr('B w=50 (<maxRTT)','ack',dict(w_ms=50,rto_ms=350,mirror=True))
rr('B w=122 (=maxRTT)','ack',dict(w_ms=122,rto_ms=350,mirror=True))
rr('B w=150 (>maxRTT)','ack',dict(w_ms=150,rto_ms=350,mirror=True))
rr('B w=300 (>>maxRTT)','ack',dict(w_ms=300,rto_ms=350,mirror=True))
# how many frames is W at w=150? W = cap0*(w/1000)/PKT_KB
for wm in (50,122,150,300):
    W=max(4.0,40000.0*(wm/1000.0)/PKT_KB)
    # BDP in frames at owd60 path: rate*RTT = 40000*0.122/PKT_KB
    bdp_hi=40000.0*0.122/PKT_KB
    print("    w_ms=%d -> W=%.0f frames ; BDP(high-RTT path,122ms)=%.0f frames -> window %s BDP"%
          (wm,W,bdp_hi,"binds below" if W<bdp_hi else ">= (non-binding)"))
