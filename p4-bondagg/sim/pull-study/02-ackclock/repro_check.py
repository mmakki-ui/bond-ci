#!/usr/bin/env python3
# Baseline reproduction gate before running assigned predictions iii/iv.
import sys, time
sys.path.insert(0, '.')
from ackclock_sim import Sim, agg, make_defs

SEEDS = 24
T = 10.0
off2 = 0.85 * (29000 + 78000)

def A(dfn, sched, **kw):
    return agg([Sim(dfn(), lambda t: off2, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)])

t0 = time.time()
edge_pull = A(lambda: make_defs('edge'), 'pull')
mid_pull  = A(lambda: make_defs('mid', local_mult=20.0), 'pull')
mid_push  = A(lambda: make_defs('mid', local_mult=20.0), 'push')
print(f"EDGE pull: gp={edge_pull['gp']:.0f} loss={edge_pull['loss']:.1f}%  (expect ~90182 / 0.7%)")
print(f"MID  pull: gp={mid_pull['gp']:.0f} loss={mid_pull['loss']:.1f}%  (expect ~78916 / 13.1%)")
print(f"MID  push: gp={mid_push['gp']:.0f} loss={mid_push['loss']:.1f}%  (expect ~87010 / 4.2%)")
print(f"elapsed {time.time()-t0:.0f}s")
