#!/usr/bin/env python3
# Does B's better EDGE p95 come from genuinely lower latency, or from discarding
# more late frames (moving the tail into the loss bucket)?
# Compute, per scheduler: reported (post-reorder) p95 vs RAW arrival-latency p95
# over ALL arrived post-warm frames (nothing discarded).
import sys
sys.path.insert(0,'.')
from ackclock_sim import Sim, make_defs, PKT_KB
off=0.85*(29000+78000)

def probe(sched, kw, tag, defs_fn, seeds=24):
    rep95=[]; raw95=[]; rawcount=[]; delivcount=[]
    for sd in range(seeds):
        s=Sim(defs_fn(), lambda t:off, 10.0, sd, sched=sched, **kw)
        r=s.run()
        rep95.append(r['p95'])
        # raw arrival latency over ALL arrived post-warm frames
        raw=[(a-s.enq[sq])*1000.0 for sq,a in s.arr.items()
             if a is not None and s.enq.get(sq,0)>s.warm]
        raw.sort()
        raw95.append(raw[int(0.95*(len(raw)-1))] if raw else 0)
        rawcount.append(len(raw))
        delivcount.append(r['deliv'])
    def med(x): x=sorted(x); n=len(x); return x[n//2] if n%2 else (x[n//2-1]+x[n//2])/2
    print("  %-8s reported_p95=%4.0f  RAW_arrival_p95=%4.0f  arrived=%5.0f  released=%5.0f  discarded=%4.0f"%
          (tag, med(rep95), med(raw95), med(rawcount), med(delivcount), med(rawcount)-med(delivcount)))

print("=== EDGE: reported p95 vs raw-arrival p95 (all arrived frames, no discard) ===")
probe('pull',{}, 'pull', lambda: make_defs('edge'))
probe('push',{}, 'push', lambda: make_defs('edge'))
probe('ewma',dict(mirror=True), 'A ewma', lambda: make_defs('edge'))
probe('ack',dict(w_ms=50,rto_ms=350,mirror=True), 'B ack', lambda: make_defs('edge'))
