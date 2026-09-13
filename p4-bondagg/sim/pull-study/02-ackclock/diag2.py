#!/usr/bin/env python3
# time-series: where does the latency/backup come from on MID for small vs large W?
import sys, math
from ackclock_sim import Sim, make_defs, PKT_KB, DT
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
offer = 0.85*(29000+78000); ofn=lambda t: offer; T=10.0

def run_trace(w_ms, rto):
    s=Sim(make_defs('mid',local_mult=20.0), ofn, T, 0, sched='ack', w_ms=w_ms, rto_ms=rto, mirror=True)
    s._front_lo=0; s._maxarr=-1
    nt=int(round(T/DT))
    samp=[]
    for tk in range(nt):
        now=tk*DT
        caps=[s.defs[i]['cap_fn'](now) for i in range(s.N)]
        dcaps=[s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
        lcaps=[s._local_cap(i,now) for i in range(s.N)]
        s._process_acks(now); s._rto_reclaim(now)
        off=s.offer_fn(now); s.frac+=off*DT/PKT_KB; nfr=int(s.frac); s.frac-=nfr
        for _ in range(nfr):
            seq=s.next_seq; s.next_seq+=1; s.fifo.append(seq); s.enq[seq]=now; s.arr[seq]=None; s.sent_on[seq]=set()
            if now>s.warm: s.offered_post+=1
        while len(s.fifo)*PKT_KB>s.maxq_kb: s.fifo.popleft(); s.qdrops+=1
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
            cand.sort(key=local_ms); seq=s.fifo[0]; placed=False
            for i in cand:
                if s.local[i].offer(seq,s.enq[seq],lcaps[i]):
                    s.fifo.popleft(); s.assigned[i]+=1; s.sent_on[seq].add(i); s.inflight[i][seq]=now; placed=True; break
            if not placed: break
        for i in range(s.N):
            exited=s.local[i].drain(lcaps[i],now,s.rng)
            for (seq,enq,x1) in exited: s.down[i].offer(seq,enq,dcaps[i])
            delv=s.down[i].drain(dcaps[i],now,s.rng)
            for (seq,enq,x2) in delv: s._deliver(i,seq,x2,now)
            aE=math.exp(-DT/0.10)
            if s.local[i].backlog_kb>1e-6: s.drain_ewma[i]=s.drain_ewma[i]*aE+s.local[i].drain_rate*(1-aE)
            else: s.drain_ewma[i]+=0.02*(s.defs[i]['cap_fn'](0.0)-s.drain_ewma[i])
        if abs(now*100 - round(now*100))<1e-6 and abs((now/0.25)-round(now/0.25))<0.02:
            samp.append((now, len(s.fifo), len(s.inflight[0]), len(s.inflight[1]),
                         int(s.W[0]), int(s.W[1]), caps[0], s.down[0].backlog_kb, s.down[1].backlog_kb))
    print(f"  w_ms={w_ms} rto={rto}  W0={int(s.W[0])} W1={int(s.W[1])}  qdrops={s.qdrops}")
    print(f"   t    pool  if0  if1   tcap  down0kb down1kb")
    for (t,pool,if0,if1,W0,W1,tc,d0,d1) in samp:
        print(f"  {t:4.2f}  {pool:5d} {if0:4d} {if1:4d}  {tc:6.0f}  {d0:6.0f} {d1:6.0f}")

run_trace(50, 400)
print()
run_trace(120, 150)
