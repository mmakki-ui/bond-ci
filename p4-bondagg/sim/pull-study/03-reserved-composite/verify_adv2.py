#!/usr/bin/env python3
import sys
sys.stdout.reconfigure(encoding='utf-8')
import reserved_dp as R

def med(xs):
    xs=sorted(xs); n=len(xs)
    return xs[n//2] if n%2 else (xs[n//2-1]+xs[n//2])/2.0

def run(archs, load, r, seeds, sch=True):
    defs=R.build_rig(archs,bottleneck='mid')
    nom=sum(a['base'] for a in archs)
    ofn=(lambda t,_n=nom,_L=load:_L*_n)
    gp=[];loss=[];af=[];rtx=[]
    for sd in range(seeds):
        m=R.SimD(defs,ofn,9.0,sd,sched='D',reserve_frac=r,ttl_ms=200.0,spotty_can_host=sch).run()
        gp.append(m['gp']);loss.append(m['loss']);af.append(m['armed_frac']);rtx.append(m['res_tx'])
    return med(gp),med(loss),med(af),med(rtx)

print("="*70)
print("TEST E: all-spotty INDEPENDENT -- does spotty_can_host=True give partial")
print("  coverage & degrade gracefully?  (synthesis flags this branch UNVERIFIED)")
print("="*70)
archs=[R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)]  # staggered
for load in (0.65,0.85):
    # baseline pull-equivalent (default host policy, cannot arm)
    g0,l0,a0,_=run(archs,load,0.15,12,sch=False)
    # relaxed: a momentarily-healthy spotty sibling may host
    g1,l1,a1,r1=run(archs,load,0.15,12,sch=True)
    print(f"  load={load}:")
    print(f"    spotty_can_host=False: gp={g0:.0f} loss={l0:.1f} armed={a0:.2f}  (== pull, honest degrade)")
    print(f"    spotty_can_host=True : gp={g1:.0f} loss={l1:.1f} armed={a1:.2f} res_tx={r1:.0f}")
    better = 'HELPS' if g1>g0*1.01 else ('HARMS' if g1<g0*0.99 else 'neutral')
    print(f"    -> partial-coverage verdict: {better}")

print()
print("="*70)
print("TEST F: all-spotty CORRELATED -- graceful degrade with relaxed host policy?")
print("="*70)
archs=[R.cellA(R.DROPS_CORR), R.cellB(R.DROPS_CORR), R.cellC(R.DROPS_CORR)]
for load in (0.65,0.85):
    g0,l0,a0,_=run(archs,load,0.15,12,sch=False)
    g1,l1,a1,r1=run(archs,load,0.15,12,sch=True)
    print(f"  load={load}: host=False gp={g0:.0f}/{l0:.1f} armed={a0:.2f} | host=True gp={g1:.0f}/{l1:.1f} armed={a1:.2f} rtx={r1:.0f}")
