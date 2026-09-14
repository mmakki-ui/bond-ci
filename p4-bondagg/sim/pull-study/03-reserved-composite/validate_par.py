#!/usr/bin/env python3
# Parallel validation of D' (sched='Dp'), reserved_local.py.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
from concurrent.futures import ProcessPoolExecutor
import reserved_local as L
import reserved_dp as D
import ackclock_sim as A

SH=['gp','loss','p50','p95','p99','deliv','tshare','hol','qdrops','late','depth','tdrop']
T=9.0; SEEDS=24
def med(xs):
    xs=sorted(xs); n=len(xs); return xs[n//2] if n%2 else (xs[n//2-1]+xs[n//2])/2.0

def w(task):
    kind, archs, bott, load, sched, seed = task
    dfs=L.build_rig(archs,bottleneck=bott); nom=sum(a['base'] for a in archs)
    of=(lambda t,_n=nom,_L=load:_L*_n)
    if kind=='pullmatch':
        mL=L.SimD(dfs,of,T,seed,sched='pull').run()
        mA=A.Sim(dfs,of,T,seed,sched='pull',mirror=False).run()
        return (kind,seed,int(all(mL[k]==mA[k] for k in SH)))
    if kind=='dintact':
        mL=L.SimD(dfs,of,T,seed,sched='D',reserve_frac=0.15).run()
        mD=D.SimD(dfs,of,T,seed,sched='D',reserve_frac=0.15).run()
        return (kind,seed,int(all(mL[k]==mD[k] for k in mL)))
    if kind=='reprint':
        mp=L.SimD(dfs,of,T,seed,sched='pull').run()
        md=L.SimD(dfs,of,T,seed,sched='Dp').run()
        return (kind,(bott,load,tuple(a.get('spotty',False) for a in archs),len(archs)),
                int(all(mp[k]==md[k] for k in SH)), md['armed_frac'])
    # perf/arming
    kw={'sched':sched}
    if sched=='D': kw['reserve_frac']=0.15
    m=L.SimD(dfs,of,T,seed,**kw).run()
    return (kind,(bott,load,sched,'%s'%[a.get('spotty') for a in archs]),
            m['gp'],m['loss'],m['p99'],m['armed_frac'],m['res_tx'])

def main():
    t0=time.time()
    NM=[L.cellA(L.DROPS_A), L.eth()]
    tasks=[]
    for sd in range(SEEDS):
        tasks.append(('pullmatch',NM,'mid',0.8,'pull',sd))
        tasks.append(('dintact',NM,'mid',0.8,'D',sd))
    reprint_cases=[('steadyN2',[L.eth(),L.wifi()]),
                   ('steadyN3',[L.eth(),L.wifi(),L.eth()]),
                   ('spottyN2',[L.cellA(L.DROPS_A),L.cellB(L.DROPS_B)]),
                   ('spottyN3',[L.cellA(L.DROPS_A),L.cellB(L.DROPS_B),L.cellC(L.DROPS_C)])]
    for nm,ar in reprint_cases:
        for load in (0.65,0.85):
            for sd in range(SEEDS):
                tasks.append(('reprint',ar,'mid',load,'Dp',sd))
    perf_cases=[('N2',[L.cellA(L.DROPS_A),L.eth()]),
                ('N3',[L.cellA(L.DROPS_A),L.cellB(L.DROPS_B),L.eth()])]
    for nm,ar in perf_cases:
        for bott in ('mid','edge'):
            for load in (0.65,0.85):
                for sched in ('pull','Dp','D'):
                    for sd in range(SEEDS):
                        tasks.append(('perf',ar,bott,load,sched,sd))

    res={}
    with ProcessPoolExecutor(max_workers=12) as ex:
        for r in ex.map(w, tasks, chunksize=4):
            res.setdefault(r[0],[]).append(r[1:])

    print("="*80)
    print("CHECK 1 -- imports clean: reserved_local, reserved_dp, ackclock_sim, nsched_model  OK")
    print("  constants DUP_HEALTH_FRAC=%.2f DRAIN_WIN=%.2fs target/2=%.0fms" % (L.DUP_HEALTH_FRAC,L.DRAIN_WIN,20))
    pm=[v for (_,v) in res['pullmatch']]
    di=[v for (_,v) in res['dintact']]
    print("="*80)
    print("CHECK 2 -- SimD('pull') byte-matches ackclock Sim('pull'): %d/%d seeds  => %s" %
          (sum(pm),len(pm),'PASS' if all(pm) else 'FAIL'))
    print("  (D intact) reserved_local.SimD('D')==reserved_dp.SimD('D'): %d/%d => %s" %
          (sum(di),len(di),'PASS' if all(di) else 'FAIL'))

    print("="*80)
    print("CHECK 3 -- all-steady AND all-spotty => reprint pull rows, armed_frac=0.00")
    agg={}
    for (key,match,af) in res['reprint']:
        d=agg.setdefault(key,[0,0,0.0])
        d[0]+=1; d[1]+=match; d[2]=max(d[2],af)
    c3=True
    for key in sorted(agg):
        n,mt,afmax=agg[key]; ok=(mt==n and afmax==0.0); c3=c3 and ok
        bott,load,spot,N=key
        cls='all-spotty' if all(spot) else ('all-steady' if not any(spot) else 'mixed')
        print("  %-11s N=%d load=%.2f  reprint=%d/%d  armed_max=%.4f  %s" %
              (cls,N,load,mt,n,afmax,'OK' if ok else 'FAIL'))
    print("  CHECK 3 => %s" % ('PASS' if c3 else 'FAIL'))

    print("="*80)
    print("CHECK 4 -- mid load 0.85 => Dp arms ~0 ticks  (medians over %d seeds)" % SEEDS)
    perf={}
    for (key,gp,loss,p99,af,rtx) in res['perf']:
        perf.setdefault(key,{'gp':[],'loss':[],'p99':[],'af':[],'rtx':[]})
        perf[key]['gp'].append(gp);perf[key]['loss'].append(loss);perf[key]['p99'].append(p99)
        perf[key]['af'].append(af);perf[key]['rtx'].append(rtx)
    for bott in ('mid','edge'):
        for spotstr in ("[True, False]","[True, True, False]"):
            for load in (0.65,0.85):
                k=(bott,load,'Dp',spotstr)
                if k in perf:
                    print("  %-4s spot=%-16s load=%.2f  armed med=%.4f (max=%.4f) res_tx med=%.0f" %
                          (bott,spotstr,load,med(perf[k]['af']),max(perf[k]['af']),med(perf[k]['rtx'])))

    print("="*80)
    print("PERFORMANCE -- Dp vs pull vs D (medians, gp/loss%%/p99ms):")
    for bott in ('mid','edge'):
        for spotstr in ("[True, False]","[True, True, False]"):
            for load in (0.65,0.85):
                row="  %-4s spot=%-16s load=%.2f |" % (bott,spotstr,load)
                for sched in ('pull','Dp','D'):
                    k=(bott,load,sched,spotstr)
                    if k in perf:
                        row+=" %s %6.0f/%4.1f/%4.0f%s|"%(sched,med(perf[k]['gp']),med(perf[k]['loss']),med(perf[k]['p99']),
                                                         (' a%.2f '%med(perf[k]['af'])) if sched!='pull' else ' ')
                print(row)
    print("\nelapsed %.1fs  (tasks=%d)" % (time.time()-t0,len(tasks)))

if __name__=='__main__':
    main()
