#!/usr/bin/env python3
# Reduced-seed reproduction of the three PASS predictions (ii already in pred_c bg run):
#  (iii) ack-loss 15/35: C survives, B deadlocks
#  (v)   RTT-fairness: C share ~0.500, B skews
import sys, time
sys.path.insert(0, '.')
from ackclock_sim import Sim, agg, make_defs, HUGE

T = 10.0
off2 = 0.85 * (29000 + 78000)
SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 10

def A(dfn, sched, seeds=SEEDS, **kw):
    return agg([Sim(dfn(), lambda t: off2, T, sd, sched=sched, **kw).run() for sd in range(seeds)])

t0 = time.time()
print(f"=== (iii) ack-loss MID-drop, seeds={SEEDS} ===")
dfn = lambda: make_defs('mid', local_mult=20.0)
for loss in (0.15, 0.35):
    b_on  = A(dfn, 'ack', w_ms=50, rto_ms=350, mirror=True, ack_loss=loss)
    b_off = A(dfn, 'ack', w_ms=50, rto_ms=None, mirror=True, ack_loss=loss)
    c_on  = A(dfn, 'C', ack_loss=loss)
    c_off = A(dfn, 'C', ack_loss=loss, probe_frames=0)
    print(f" loss={loss*100:.0f}%  B_floorON gp={b_on['gp']:.0f}/{b_on['loss']:.1f}%  "
          f"B_floorOFF gp={b_off['gp']:.0f}/{b_off['loss']:.1f}%  "
          f"C_floorON gp={c_on['gp']:.0f}/{c_on['loss']:.1f}%  "
          f"C_floorOFF gp={c_off['gp']:.0f}/{c_off['loss']:.1f}%")

# (v) fairness
print(f"\n=== (v) RTT-fairness, seeds={SEEDS} ===")
CAP=50000.0; OWD_LO=5.0; OWD_HI=60.0; JIT=3.0
def make_defs_rtt():
    capfn=lambda t:CAP
    return [dict(cap_fn=capfn,local_cap_fn=capfn,loc_owd=OWD_LO,down_owd=0.0,jit=JIT,jit_stage='local',down_cap_fn=lambda t:HUGE,down_qmax=HUGE),
            dict(cap_fn=capfn,local_cap_fn=capfn,loc_owd=OWD_HI,down_owd=0.0,jit=JIT,jit_stage='local',down_cap_fn=lambda t:HUGE,down_qmax=HUGE)]
OFFER=1.10*(2*CAP)
def Af(sched,**kw): return agg([Sim(make_defs_rtt(),lambda t:OFFER,T,sd,sched=sched,**kw).run() for sd in range(SEEDS)])
for name,sched,kw in (("pull",'pull',{}),("B ack",'ack',dict(w_ms=50,rto_ms=350,mirror=True)),("C",'C',{})):
    m=Af(sched,**kw)
    print(f"  {name:8s} tshare0={m['tshare']:.3f} gp={m['gp']:.0f} loss={m['loss']:.1f}%")
print(f"\nelapsed {time.time()-t0:.0f}s")
