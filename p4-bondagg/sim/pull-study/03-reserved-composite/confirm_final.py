#!/usr/bin/env python3
import sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_cap0 as R
import ackclock_sim as A
T = 4.0; SEEDS = 8
KEYS = ('gp','loss','p50','p95','p99','deliv','depth','tdrop')
def ex(a,b): return all(abs(a.get(k,0)-b.get(k,0))<1e-9 for k in KEYS for a,b in [(a,b)])
def match(A_,B_): return all(all(abs(x.get(k,0)-y.get(k,0))<1e-9 for k in KEYS) for x,y in zip(A_,B_))
def simd(ar,rig,load,s):
    d=R.build_rig(ar,bottleneck=rig); nom=sum(a['base'] for a in ar)
    o=lambda t,_n=nom,_L=load:_L*_n
    return [R.SimD(d,o,T,i,sched=s).run() for i in range(SEEDS)]
def ref(ar,rig,load,s):
    d=R.build_rig(ar,bottleneck=rig); nom=sum(a['base'] for a in ar)
    o=lambda t,_n=nom,_L=load:_L*_n
    return [A.Sim(d,o,T,i,sched=s,mirror=False).run() for i in range(SEEDS)]

print('imports OK; scheds: pull, D, Dp, redundant')
# 1 pull byte-match
ar=[R.cellA(R.DROPS_A),R.eth()]
print('pull byte-match (mid,0.8):', match(simd(ar,'mid',0.8,'pull'), ref(ar,'mid',0.8,'pull')))
# 2 all-steady + all-spotty reprint & armed=0
for lbl,a2,rig,load in [('steady wifi+eth',[R.wifi(),R.eth()],'mid',0.85),
                        ('spotty corr',[R.cellA(R.DROPS_CORR),R.cellB(R.DROPS_CORR),R.cellC(R.DROPS_CORR)],'mid',0.85)]:
    dp=simd(a2,rig,load,'Dp'); pl=simd(a2,rig,load,'pull')
    print(f'{lbl}: reprint={match(dp,pl)} armed_max={max(m["armed_frac"] for m in dp):.2f}')
# 3 mid 0.85 mixed arming
dp=simd(ar,'mid',0.85,'Dp')
print('mixed mid 0.85 Dp armed_frac(med of 8):', sorted(m['armed_frac'] for m in dp)[4])
