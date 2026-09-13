#!/usr/bin/env python3
# Adversarial root-cause tests on the MID failure.
#  T1: is c_repair='age' the culprit? try c_repair='raw' (inflight = sent-recv_reading, no age-purge)
#      -- and re-test ack-loss on 'raw' (does it lose deadlock-immunity? -> proves the tradeoff)
#  T2: is the failure just a tau policy mismatch? sweep target_ms 40->150 on MID for C.
#      (downstream path RTTmin ~62ms already > tau=40ms budget)
import sys, time
sys.path.insert(0, '.')
from ackclock_sim import Sim, agg, make_defs

T=10.0; off2=0.85*(29000+78000); SEEDS=int(sys.argv[1]) if len(sys.argv)>1 else 10
dfn=lambda: make_defs('mid', local_mult=20.0)
def A(sched, seeds=SEEDS, **kw):
    return agg([Sim(dfn(), lambda t:off2, T, sd, sched=sched, **kw).run() for sd in range(seeds)])

t0=time.time()
print(f"MID-drop, seeds={SEEDS}. A(ewma) reference and C variants.")
a=A('ewma', mirror=True); print(f"  A ewma            gp={a['gp']:.0f} loss={a['loss']:.1f}% p50={a['p50']:.0f} p95={a['p95']:.0f}")
c=A('C');                  print(f"  C default(age,t40) gp={c['gp']:.0f} loss={c['loss']:.1f}% p50={c['p50']:.0f} p95={c['p95']:.0f} c_lost={c['c_lost']:.0f} qdrops={c['qdrops']:.0f}")

print("\n-- T1: c_repair='raw' (no wall-clock age-purge; inflight=sent-recv_reading) --")
craw=A('C', c_repair='raw'); print(f"  C raw (t40)        gp={craw['gp']:.0f} loss={craw['loss']:.1f}% p50={craw['p50']:.0f} p95={craw['p95']:.0f} c_lost={craw['c_lost']:.0f} qdrops={craw['qdrops']:.0f}")
craw15=A('C', c_repair='raw', ack_loss=0.15); print(f"  C raw + ackloss15% gp={craw15['gp']:.0f} loss={craw15['loss']:.1f}%   (age-immunity lost? -> deadlock/collapse)")
craw35=A('C', c_repair='raw', ack_loss=0.35); print(f"  C raw + ackloss35% gp={craw35['gp']:.0f} loss={craw35['loss']:.1f}%")

print("\n-- T2: tau (target_ms) sweep on default C (age). RTTmin(down path0)~62ms --")
for tau in (40,60,80,100,120,150):
    m=A('C', target_ms=float(tau))
    print(f"  C age tau={tau:3d}ms      gp={m['gp']:.0f} loss={m['loss']:.1f}% p50={m['p50']:.0f} p95={m['p95']:.0f} c_lost={m['c_lost']:.0f} qdrops={m['qdrops']:.0f}")
print(f"\nelapsed {time.time()-t0:.0f}s")
