#!/usr/bin/env python3
# Is the MID fix the ACK-CLOCK, or the RTO TIMER?
# At ZERO ack loss, strip the RTO floor. If pure ack-window ~= pull collapse,
# then the credit-reclaim timer (not self-clocking) is doing the work.
# Mechanism: downstream TAILDROPPED frames are never delivered -> never acked ->
# their window credit is only freed by the RTO. Without RTO those credits leak.
import sys
sys.path.insert(0,'.')
from ackclock_sim import Sim, agg, make_defs
off=0.85*(29000+78000)
SEEDS=24
def rr(nm,dfn,**kw):
    a=agg([Sim(dfn(),lambda t:off,10.0,sd,sched=kw.pop('sched','ack'),**kw).run() for sd in range(SEEDS)])
    print("  %-30s gp=%6.0f loss=%4.1f p50=%4.0f p95=%4.0f tdrop=%5.0f"%(nm,a['gp'],a['loss'],a['p50'],a['p95'],a['tdrop']))

print("=== MID-drop: pure ack-window (no RTO) vs window+RTO, ack_loss=0 ===")
rr('pull (collapse baseline)', lambda: make_defs('mid',local_mult=20.0), sched='pull')
rr('B window ONLY (rto=None)', lambda: make_defs('mid',local_mult=20.0), w_ms=50, rto_ms=None, mirror=True)
rr('B window+RTO350 (canonical)', lambda: make_defs('mid',local_mult=20.0), w_ms=50, rto_ms=350, mirror=True)
rr('B window ONLY no-mirror',   lambda: make_defs('mid',local_mult=20.0), w_ms=50, rto_ms=None, mirror=False)
print("  -> if 'window ONLY' ~= pull, the RTO timer (not the ack-clock) is the fix.\n")

print("=== EDGE: same test (does RTO matter at edge?) ===")
rr('pull', lambda: make_defs('edge'), sched='pull')
rr('B window ONLY (rto=None)', lambda: make_defs('edge'), w_ms=50, rto_ms=None, mirror=True)
rr('B window+RTO350', lambda: make_defs('edge'), w_ms=50, rto_ms=350, mirror=True)

print("\n=== sweep RTO value at MID (is 350ms tuned? is it a rate knob?) ===")
for rto in (100,200,350,500,800,None):
    rr(f'B rto={rto}', lambda: make_defs('mid',local_mult=20.0), w_ms=50, rto_ms=rto, mirror=True)
