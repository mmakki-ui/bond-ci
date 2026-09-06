#!/usr/bin/env python3
# Validation of D' (sched='Dp') in reserved_local.py. Faithful literal gate:
#   NATIVE   = pure pull; DUPLICATE = at-risk frame -> host iff local_ms<target/2
#              AND drain_ewma >= 0.75*windowed_max(drain_ewma); TTL = reorder hold;
#              NO r/budget/cap0.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_local as L
import reserved_dp as D
import ackclock_sim as A

SH = ['gp','loss','p50','p95','p99','deliv','tshare','hol','qdrops','late','depth','tdrop']
def med(xs):
    xs=sorted(xs); n=len(xs); return xs[n//2] if n%2 else (xs[n//2-1]+xs[n//2])/2.0
T=9.0; SEEDS=24

t0=time.time()
print("="*78)
print("CHECK 1 -- imports clean")
print("="*78)
print("  reserved_local, reserved_dp, ackclock_sim, nsched_model imported OK")
print("  constants: DUP_HEALTH_FRAC=%.2f DRAIN_WIN=%.2fs  target/2=%.1fms" %
      (L.DUP_HEALTH_FRAC, L.DRAIN_WIN, 40.0/2))

print("="*78)
print("CHECK 2 -- reserved_local.SimD('pull') byte-matches ackclock_sim.Sim('pull')")
print("="*78)
archs=[L.cellA(L.DROPS_A), L.eth()]; defs=L.build_rig(archs,bottleneck='mid')
nom=sum(a['base'] for a in archs); ofn=lambda t:0.8*nom
badP=0
for sd in range(SEEDS):
    mL=L.SimD(defs,ofn,T,sd,sched='pull').run()
    mA=A.Sim(defs,ofn,T,sd,sched='pull',mirror=False).run()
    if not all(mL[k]==mA[k] for k in SH): badP+=1
print("  byte-match over %d seeds (12 shared metrics): %s" % (SEEDS, badP==0))

# D intact
badD=0
for sd in range(SEEDS):
    mL=L.SimD(defs,ofn,T,sd,sched='D',reserve_frac=0.15).run()
    mD=D.SimD(defs,ofn,T,sd,sched='D',reserve_frac=0.15).run()
    if not all(mL[k]==mD[k] for k in mL): badD+=1
print("  (D kept intact) reserved_local.SimD('D') == reserved_dp.SimD('D'): %s" % (badD==0))

print("="*78)
print("CHECK 3 -- all-steady AND all-spotty => Dp reprints pull rows, armed_frac=0.00")
print("="*78)
cases={
 'all-steady N2 (eth+wifi)':[L.eth(), L.wifi()],
 'all-steady N3 (eth+wifi+eth)':[L.eth(), L.wifi(), L.eth()],
 'all-spotty N2 (cellA+cellB)':[L.cellA(L.DROPS_A), L.cellB(L.DROPS_B)],
 'all-spotty N3 (cellA+cellB+cellC)':[L.cellA(L.DROPS_A), L.cellB(L.DROPS_B), L.cellC(L.DROPS_C)],
}
c3_ok=True
for name,ar in cases.items():
    dfs=L.build_rig(ar,bottleneck='mid'); nm=sum(a['base'] for a in ar)
    for load in (0.65,0.85):
        of=lambda t,_n=nm,_L=load:_L*_n
        bad=0; afmax=0.0
        for sd in range(SEEDS):
            mp=L.SimD(dfs,of,T,sd,sched='pull').run()
            md=L.SimD(dfs,of,T,sd,sched='Dp').run()
            if not all(mp[k]==md[k] for k in SH): bad+=1
            afmax=max(afmax,md['armed_frac'])
        ok=(bad==0 and afmax==0.0); c3_ok=c3_ok and ok
        print("  %-34s load=%.2f  reprints_pull=%s armed_max=%.4f  %s" %
              (name,load,bad==0,afmax,'OK' if ok else 'FAIL'))
print("  CHECK 3:", "PASS" if c3_ok else "FAIL")

print("="*78)
print("CHECK 4 -- mid load 0.85 => Dp duplicate arms ~0 ticks")
print("="*78)
for rig in ('mid','edge'):
    for name,ar in [('N2 cellA+eth',[L.cellA(L.DROPS_A), L.eth()]),
                    ('N3 2cell+eth',[L.cellA(L.DROPS_A), L.cellB(L.DROPS_B), L.eth()])]:
        dfs=L.build_rig(ar,bottleneck=rig); nm=sum(a['base'] for a in ar)
        for load in (0.65,0.85):
            of=lambda t,_n=nm,_L=load:_L*_n
            af=[];rtx=[]
            for sd in range(SEEDS):
                m=L.SimD(dfs,of,T,sd,sched='Dp').run()
                af.append(m['armed_frac']);rtx.append(m['res_tx'])
            print("  %-4s %-13s load=%.2f  armed_frac med=%.4f (max=%.4f)  res_tx med=%.0f" %
                  (rig,name,load,med(af),max(af),med(rtx)))

print("="*78)
print("PERFORMANCE -- Dp vs pull vs D (MID rig, medians %d seeds): is Dp a good candidate?" % SEEDS)
print("="*78)
for name,ar in [('N2 cellA+eth',[L.cellA(L.DROPS_A), L.eth()]),
                ('N3 2cell+eth',[L.cellA(L.DROPS_A), L.cellB(L.DROPS_B), L.eth()])]:
    dfs=L.build_rig(ar,bottleneck='mid'); nm=sum(a['base'] for a in ar)
    for load in (0.65,0.85):
        of=lambda t,_n=nm,_L=load:_L*_n
        out={}
        for sch in ('pull','Dp','D'):
            g=[];l=[];p99=[];af=[]
            for sd in range(SEEDS):
                kw={'sched':sch}
                if sch=='D': kw['reserve_frac']=0.15
                m=L.SimD(dfs,of,T,sd,**kw).run()
                g.append(m['gp']);l.append(m['loss']);p99.append(m['p99']);af.append(m['armed_frac'])
            out[sch]=(med(g),med(l),med(p99),med(af))
        print("  %-13s load=%.2f | pull %6.0f/%4.1f/%4.0f || Dp %6.0f/%4.1f/%4.0f armed=%.2f || D %6.0f/%4.1f/%4.0f armed=%.2f" %
              (name,load,*out['pull'][:3],*out['Dp'],*out['D']))
print("(cells: gp / loss%% / p99ms)")
print("\nelapsed %.1fs" % (time.time()-t0))
