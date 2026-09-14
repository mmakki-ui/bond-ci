#!/usr/bin/env python3
# instrument the ack-clock equilibrium on MID to see why it under-utilizes.
import sys
from ackclock_sim import Sim, make_defs, PKT_KB, DT
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
T = 10.0

def diag(sched, **kw):
    s = Sim(make_defs('mid', local_mult=20.0), ofn, T, 0, sched=sched, **kw)
    # monkeypatch: sample inflight, pool, per-path delivered rate over a steady window
    infl = [[] for _ in range(s.N)]; pool = []; dr = [0]*s.N
    orig_deliver = s._deliver
    def rec_deliver(i, seq, x2, now):
        orig_deliver(i, seq, x2, now)
    s._deliver = rec_deliver
    nticks = int(round(T/DT))
    # re-run manually to sample
    s._front_lo = 0; s._maxarr = -1
    delivered_ct = [0]*s.N
    for tk in range(nticks):
        now = tk*DT
        caps=[s.defs[i]['cap_fn'](now) for i in range(s.N)]
        dcaps=[s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
        lcaps=[s._local_cap(i,now) for i in range(s.N)]
        s._process_acks(now); s._rto_reclaim(now)
        off=s.offer_fn(now); s.frac+=off*DT/PKT_KB; nfr=int(s.frac); s.frac-=nfr
        for _ in range(nfr):
            seq=s.next_seq; s.next_seq+=1; s.fifo.append(seq); s.enq[seq]=now; s.arr[seq]=None; s.sent_on[seq]=set()
            if now>s.warm: s.offered_post+=1
        while len(s.fifo)*PKT_KB>s.maxq_kb:
            s.fifo.popleft(); s.qdrops+=1
        def local_ms(i): return s.local[i].backlog_kb/max(1.0,s.drain_ewma[i])*1000.0
        def room(i):
            if lcaps[i]<=0: return False
            if local_ms(i)>=s.target_ms: return False
            return len(s.inflight[i])<s.W[i]
        guard=0
        while s.fifo and guard<100000:
            guard+=1
            cand=[i for i in range(s.N) if room(i)]
            if not cand: break
            cand.sort(key=local_ms)
            seq=s.fifo[0]; placed=False
            for i in cand:
                if s.local[i].offer(seq,s.enq[seq],lcaps[i]):
                    s.fifo.popleft(); s.assigned[i]+=1; s.sent_on[seq].add(i); s.inflight[i][seq]=now; placed=True; break
            if not placed: break
        for i in range(s.N):
            exited=s.local[i].drain(lcaps[i],now,s.rng)
            for (seq,enq,x1) in exited:
                s.down[i].offer(seq,enq,dcaps[i])
            delv=s.down[i].drain(dcaps[i],now,s.rng)
            for (seq,enq,x2) in delv:
                s._deliver(i,seq,x2,now);
                if now>2.0 and now<8.0: delivered_ct[i]+=1
            import math
            aE=math.exp(-DT/0.10)
            if s.local[i].backlog_kb>1e-6: s.drain_ewma[i]=s.drain_ewma[i]*aE+s.local[i].drain_rate*(1-aE)
            else: s.drain_ewma[i]+=0.02*(s.defs[i]['cap_fn'](0.0)-s.drain_ewma[i])
        if 2.0<now<8.0:
            for i in range(s.N): infl[i].append(len(s.inflight[i]))
            pool.append(len(s.fifo))
    def mean(x): return sum(x)/len(x) if x else 0
    print(f"  {sched} {kw}")
    for i in range(s.N):
        rate = delivered_ct[i]*PKT_KB/6.0
        print(f"    path{i}: W={s.W[i]:.0f} mean_inflight={mean(infl[i]):.0f} "
              f"deliv_rate={rate:6.0f}kb/s  (cap0={s.defs[i]['cap_fn'](0.0):.0f})")
    print(f"    mean pool={mean(pool):.0f} frames  qdrops={s.qdrops}")

diag('ack', wmult=1.0, mirror=False, rto_ms=250)
diag('ack', wmult=2.0, mirror=False, rto_ms=250)
diag('ack', wmult=4.0, mirror=False, rto_ms=250)
