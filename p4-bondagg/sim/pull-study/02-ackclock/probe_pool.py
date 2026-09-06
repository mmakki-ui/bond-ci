#!/usr/bin/env python3
# "pooled water + shallow pool": is the pool actually shallow, or does the shared
# client FIFO balloon under MID load? Sweep maxq_ms (pool depth) and also
# instrument actual pool occupancy + stage backlogs on one seed.
import sys
sys.path.insert(0,'.')
from ackclock_sim import Sim, agg, make_defs, PKT_KB
off=0.85*(29000+78000)
SEEDS=24

print("=== MID-drop: sweep client-pool depth maxq_ms (B ack, w=50, floor350) ===")
print("    downstream Stage qmax is fixed at 300ms (QMAX_MS) regardless.")
for mq in (300,150,80,40,20):
    a=agg([Sim(make_defs('mid',local_mult=20.0),lambda t:off,10.0,sd,
               sched='ack',w_ms=50,rto_ms=350,mirror=True,maxq_ms=mq).run() for sd in range(SEEDS)])
    print("  maxq=%3dms  gp=%6.0f loss=%4.1f p50=%4.0f p95=%4.0f p99=%4.0f qdrops=%5.0f"%
          (mq,a['gp'],a['loss'],a['p50'],a['p95'],a['p99'],a['qdrops']))

# instrument one seed: sample pool FIFO length + stage backlogs each tick
print("\n=== instrument one MID-drop B seed: where does the latency live? ===")
import ackclock_sim as AC
DT=AC.DT
def instrumented(defs_fn, **kw):
    s=Sim(defs_fn(), lambda t:off, 10.0, 0, sched='ack', **kw)
    orig_run=s.run
    samples={'fifo':[], 'loc':[], 'down':[]}
    # monkeypatch: wrap the per-tick by hooking finalize won't help; re-run loop via trace of drain
    # Instead: patch Stage.drain to record backlog after each drain call is too noisy.
    # Simplest: run, but sample by overriding _process_acks (called once/tick at top).
    orig_pa=s._process_acks
    def hook(now):
        samples['fifo'].append(len(s.fifo)*PKT_KB)  # kb in client pool
        samples['loc'].append(sum(st.backlog_kb for st in s.local))
        samples['down'].append(sum(st.backlog_kb for st in s.down))
        return orig_pa(now)
    s._process_acks=hook
    r=s.run()
    import statistics as st
    def stats(x):
        x=sorted(x); n=len(x)
        return (x[n//2], x[int(0.95*(n-1))], max(x))
    print("  pool FIFO kb  : med=%6.0f p95=%6.0f max=%6.0f  (maxq_kb=%.0f)"%(*stats(samples['fifo']), s.maxq_kb))
    print("  local backlog : med=%6.0f p95=%6.0f max=%6.0f"%stats(samples['loc']))
    print("  down  backlog : med=%6.0f p95=%6.0f max=%6.0f"%stats(samples['down']))
    print("  as ms @ agg cap0=%.0f: pool med=%.0fms down med=%.0fms"%(
        (29000+78000), stats(samples['fifo'])[0]/(29000+78000)*1000,
        stats(samples['down'])[0]/(29000+78000)*1000))
    return r
instrumented(lambda: make_defs('mid',local_mult=20.0), w_ms=50, rto_ms=350, mirror=True)
