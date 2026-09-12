#!/usr/bin/env python3
# Adversarial reproduction harness -- run from sim_reserved/ dir.
import sys
sys.stdout.reconfigure(encoding='utf-8')
import reserved_dp as R
import ackclock_sim as A

def med(xs):
    xs=sorted(xs); n=len(xs)
    return xs[n//2] if n%2 else (xs[n//2-1]+xs[n//2])/2.0

def run_sched(archs, load, sched, seeds, rig='mid', r=0.15):
    defs = R.build_rig(archs, bottleneck=rig)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t,_n=nom,_L=load: _L*_n)
    gps=[]; losses=[]; afs=[]
    for sd in range(seeds):
        if sched.startswith('D:'):
            rr=float(sched.split(':')[1])
            m=R.SimD(defs,ofn,9.0,sd,sched='D',reserve_frac=rr,ttl_ms=200.0).run()
        elif sched=='redundant':
            m=R.SimD(defs,ofn,9.0,sd,sched='redundant').run()
        elif sched=='Dpull':
            m=R.SimD(defs,ofn,9.0,sd,sched='pull').run()
        else:
            m=A.Sim(defs,ofn,9.0,sd,sched=sched,mirror=False).run()
        gps.append(m['gp']); losses.append(m['loss']); afs.append(m.get('armed_frac',0.0))
    return med(gps),med(losses),med(afs)

print("="*70)
print("TEST A: SimD('pull') == ackclock Sim('pull')  (apples-to-apples foundation)")
print("="*70)
# use the pareto N2 config: 1 spotty cellA + 1 steady eth, mid rig, load 0.80
archs=[R.cellA(R.DROPS_A), R.eth()]
for load in (0.65,0.80):
    dg,dl,_=run_sched(archs,load,'Dpull',24)
    ag,al,_=run_sched(archs,load,'pull',24)
    match = abs(dg-ag)<1e-6 and abs(dl-al)<1e-6
    print(f"  load={load}: SimD(pull)={dg:.1f}/{dl:.2f}  A.Sim(pull)={ag:.1f}/{al:.2f}  EXACT_MATCH={match}")

print()
print("="*70)
print("TEST B: reproduce myslice N3 2sp+1st (win@0.65 / collapse@0.85), 24 seeds")
print("="*70)
archs=[R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()]
for load in (0.65,0.85):
    for sched in ('pull','D:0.15','oracle'):
        g,l,af=run_sched(archs,load,sched,24)
        print(f"  load={load} {sched:8s}: gp={g:.0f} loss={l:.1f} armed={af:.2f}")

print()
print("="*70)
print("TEST C: N-GENERICITY at N=1 (single path) -- no crash, sensible degenerate")
print("="*70)
# N=1 steady -> no spotty source -> no-op vs pull
for label,archs in (('N1 steady(eth)',[R.eth()]),
                    ('N1 spotty(cellA)',[R.cellA(R.DROPS_A)])):
    gp_pull,l_pull,_=run_sched(archs,0.65,'pull',12)
    gp_d,l_d,af=run_sched(archs,0.65,'D:0.15',12)
    noop = abs(gp_pull-gp_d)<1e-6 and abs(l_pull-l_d)<1e-6
    print(f"  {label}: pull={gp_pull:.0f}/{l_pull:.1f}  D={gp_d:.0f}/{l_d:.1f}  armed={af:.2f}  identical_to_pull={noop}")

print()
print("="*70)
print("TEST D: knee localization -- N2 mid, r sweep at load 0.70 and 0.75")
print("  (adversarial: synthesis says 0.75 'still in win zone', 0.85 first collapse)")
print("="*70)
archs=[R.cellA(R.DROPS_A), R.eth()]
for load in (0.70,0.75):
    gp_p,l_p,_=run_sched(archs,load,'pull',24)
    print(f"  --- load={load}  pull baseline gp={gp_p:.0f}/{l_p:.1f} ---")
    for rr in (0.10,0.15,0.20,0.25):
        g,l,af=run_sched(archs,load,f'D:{rr}',24)
        dg=100.0*(g-gp_p)/gp_p
        verdict = 'WIN' if (g>gp_p and l<l_p) else ('COLLAPSE' if g<gp_p*0.97 else 'neutral/loss')
        print(f"    D r={rr:.2f}: gp={g:.0f} loss={l:.1f}  Δgp={dg:+.1f}%  -> {verdict}")
