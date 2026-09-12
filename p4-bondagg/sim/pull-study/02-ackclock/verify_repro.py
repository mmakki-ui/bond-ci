#!/usr/bin/env python3
# Independent reproduction of the core table + validation vs attack1_midnet.
import sys, time
sys.path.insert(0, '.')
sys.path.insert(0, '../sim')
from ackclock_sim import Sim, agg, make_defs
import importlib.util

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
off = 0.85 * (29000 + 78000)
BCFG = dict(w_ms=50, rto_ms=350, mirror=True)
CORE = [("pull",'pull',{}), ("push",'push',{}), ("oracle",'oracle',{}),
        ("A ewma",'ewma',dict(mirror=True)), ("B ack",'ack',BCFG)]

def runset(defs_fn):
    out={}
    for nm,sc,kw in CORE:
        ms=[Sim(defs_fn(), lambda t:off, 10.0, sd, sched=sc, **kw).run() for sd in range(SEEDS)]
        out[nm]=agg(ms)
    return out

print("=== REPRO core, seeds=%d ==="%SEEDS)
for tag,dfn in [("EDGE", lambda: make_defs('edge')),
                ("MID-drop", lambda: make_defs('mid', local_mult=20.0)),
                ("MID-shape", lambda: make_defs('mid', local_mult=20.0, shaping=True))]:
    r=runset(dfn)
    print("[%s]"%tag)
    for nm,_,_ in CORE:
        a=r[nm]
        print("  %-8s gp=%6.0f loss=%4.1f p50=%4.0f p95=%4.0f p99=%4.0f depth=%5.0f tdrop=%5.0f late=%5.0f"%
              (nm,a['gp'],a['loss'],a['p50'],a['p95'],a['p99'],a['depth'],a['tdrop'],a['late']))

# ---- VALIDATION: does ackclock_sim's pull/push/oracle match attack1_midnet exactly? ----
print("\n=== VALIDATION vs attack1_midnet.TwoStageSim (same defs, pull/push/oracle) ===")
spec = importlib.util.spec_from_file_location("a1", "../sim/attack1_midnet.py")
a1 = importlib.util.module_from_spec(spec); spec.loader.exec_module(a1)
for tag, mk_new, mk_old in [
    ("EDGE", lambda: make_defs('edge'), lambda: a1.make_defs('edge')),
    ("MID",  lambda: make_defs('mid', local_mult=20.0), lambda: a1.make_defs('mid', local_mult=20.0))]:
    for sc in ('pull','push','oracle'):
        new = agg([Sim(mk_new(), lambda t:off, 10.0, sd, sched=sc).run() for sd in range(SEEDS)])
        old = agg([a1.TwoStageSim(mk_old(), lambda t:off, 10.0, sd, sched=sc).run() for sd in range(SEEDS)])
        match = abs(new['gp']-old['gp'])<1 and abs(new['loss']-old['loss'])<0.05
        print("  %-5s %-7s NEW gp=%6.0f loss=%4.1f | OLD gp=%6.0f loss=%4.1f  %s"%
              (tag,sc,new['gp'],new['loss'],old['gp'],old['loss'], "MATCH" if match else "**DIFF**"))
