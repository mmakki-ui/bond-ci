#!/usr/bin/env python3
import sys
sys.path.insert(0, ".")
from concurrent.futures import ProcessPoolExecutor
import iv_worker as W

SEEDS = list(range(24))
def med(xs):
    xs=sorted(xs); n=len(xs)
    return xs[n//2] if n%2 else (xs[n//2-1]+xs[n//2])/2.0

fails=[]
if __name__=="__main__":
    ex = ProcessPoolExecutor(max_workers=14)

    # CHECK 2
    tasks=[(name,bn,load,s) for name in ('N2','N3') for bn in ('mid','edge')
           for load in (0.65,0.85) for s in SEEDS]
    mm=0; tot=0; ex_shown=0
    for (args,bad,detail) in ex.map(W.job_c2, tasks):
        tot+=len(W.SHARED); mm+=len(bad)
        if bad and ex_shown<6:
            ex_shown+=1; print("C2 MISMATCH", args, detail)
    print(f"CHECK2 pull-equiv: comparisons={tot} mismatches={mm} -> {'PASS' if mm==0 else 'FAIL'}")
    if mm: fails.append("CHECK2")

    # D INTACT
    tasks=[(name,bn,load,rf,ttl,s) for name in ('N2','N3') for bn in ('mid','edge')
           for load in (0.65,0.85) for (rf,ttl) in [(0.25,200.0),(0.10,120.0),(0.40,300.0)]
           for s in SEEDS[:8]]
    mm=0; tot=0; shown=0
    for (args,bad) in ex.map(W.job_dintact, tasks):
        tot+=1
        if bad:
            mm+=1
            if shown<6: shown+=1; print("D MISMATCH", args, bad)
    print(f"D-INTACT: runs={tot} mismatched_runs={mm} -> {'PASS' if mm==0 else 'FAIL'}")
    if mm: fails.append("D-intact")

    # CHECK 3
    tasks=[(name,bn,load,s) for name in ('STEADY2','STEADY3','SPOTTY2','SPOTTY3')
           for bn in ('mid','edge') for load in (0.65,0.85) for s in SEEDS]
    from collections import defaultdict
    agg=defaultdict(lambda:{'arm':[],'rowbad':False,'res_tx':[]})
    for (args,armed,res_tx,rowbad) in ex.map(W.job_c3, tasks):
        name,bn,load,s = args
        k=(name,bn,load); agg[k]['arm'].append(armed); agg[k]['res_tx'].append(res_tx)
        if rowbad: agg[k]['rowbad']=True
    c3ok=True
    for k in sorted(agg):
        amax=max(agg[k]['arm']); rowbad=agg[k]['rowbad']; rtmax=max(agg[k]['res_tx'])
        ok=(amax==0.0) and (not rowbad)
        c3ok=c3ok and ok
        print(f"CHECK3 {k[0]:8s} {k[1]:4s} L{k[2]}: armed_max={amax:.4f} res_tx_max={rtmax} pull_row_match={not rowbad} -> {'OK' if ok else 'FAIL'}")
    if not c3ok: fails.append("CHECK3")

    # CHECK 4 + arm sweep across loads
    tasks=[(name,bn,load,s) for name in ('N2','N3') for bn in ('mid','edge')
           for load in (0.55,0.65,0.75,0.85) for s in SEEDS]
    armagg=defaultdict(list)
    for (args,armed) in ex.map(W.job_arm, tasks):
        name,bn,load,s=args; armagg[(name,bn,load)].append(armed)
    print("\nCHECK4 armed_frac medians (arm vs load):")
    for k in sorted(armagg):
        v=armagg[k]; print(f"  {k[0]} {k[1]:4s} L{k[2]}: med={med(v):.4f} min={min(v):.4f} max={max(v):.4f}")
    mid85=[med(armagg[('N2','mid',0.85)]), med(armagg[('N3','mid',0.85)])]
    check4=all(x<=0.05 for x in mid85)
    print(f"CHECK4 MID L0.85 armed medians N2={mid85[0]:.4f} N3={mid85[1]:.4f} -> {'PASS (~0)' if check4 else 'FAIL (armed NOT ~0)'}")
    if not check4: fails.append("CHECK4")

    # NET EFFECT
    tasks=[(name,bn,0.85,s) for name in ('N2','N3') for bn in ('mid','edge') for s in SEEDS]
    netagg=defaultdict(lambda:{'pull':[],'Dp':[],'D':[]})
    for (args,d) in ex.map(W.job_net, tasks):
        name,bn,load,s=args
        netagg[(name,bn)]['pull'].append(d['pull'])
        netagg[(name,bn)]['Dp'].append(d['Dp'])
        netagg[(name,bn)]['D'].append(d['D'])
    print("\nNET EFFECT L0.85 (gp/loss%/p99 medians; Dp also armed):")
    for k in sorted(netagg):
        p=netagg[k]['pull']; dp=netagg[k]['Dp']; dd=netagg[k]['D']
        pm=(med([x[0] for x in p]),med([x[1] for x in p]),med([x[2] for x in p]))
        dm=(med([x[0] for x in dp]),med([x[1] for x in dp]),med([x[2] for x in dp]),med([x[3] for x in dp]))
        ddm=(med([x[0] for x in dd]),med([x[1] for x in dd]),med([x[2] for x in dd]))
        print(f"  {k[0]} {k[1]:4s} | pull {pm[0]:.0f}/{pm[1]:.1f}/{pm[2]:.0f} | Dp {dm[0]:.0f}/{dm[1]:.1f}/{dm[2]:.0f} (arm {dm[3]:.2f}) | D {ddm[0]:.0f}/{ddm[1]:.1f}/{ddm[2]:.0f}")

    ex.shutdown()
    print("\nSUMMARY fails:", fails if fails else "none")
