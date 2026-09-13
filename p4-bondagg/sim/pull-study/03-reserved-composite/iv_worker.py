#!/usr/bin/env python3
# Parallel workers for independent verification. Top-level fns so ProcessPool can pickle.
import sys
sys.path.insert(0, ".")
import reserved_local as R
import reserved_dp   as DP
from ackclock_sim import Sim

T = 9.0
SHARED = ['gp','loss','p50','p95','p99','depth','tdrop','tshare','hol','qdrops','late','deliv']
ALLK = SHARED + ['res_tx','mir_off','mir_aged','armed_frac']

def _arches(name):
    m = {
      'N2':      [R.cellA(R.DROPS_A), R.eth()],
      'N3':      [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.eth()],
      'STEADY2': [R.eth(), R.wifi()],
      'STEADY3': [R.eth(), R.wifi(), R.wifi()],
      'SPOTTY2': [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B)],
      'SPOTTY3': [R.cellA(R.DROPS_A), R.cellB(R.DROPS_B), R.cellC(R.DROPS_C)],
    }
    return m[name]

def _nom(a): return sum(x['base'] for x in a)
def _ofn(load, nom): return lambda t: load*nom

def job_c2(args):
    name, bn, load, seed = args
    a = _arches(name); nom=_nom(a)
    sd = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='pull').run()
    rf = Sim(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='pull', mirror=False).run()
    bad = [k for k in SHARED if abs(sd[k]-rf[k])>1e-9]
    return (args, bad, {k:(sd[k],rf[k]) for k in bad})

def job_dintact(args):
    name, bn, load, rf, ttl, seed = args
    a=_arches(name); nom=_nom(a)
    x = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='D', reserve_frac=rf, ttl_ms=ttl).run()
    y = DP.SimD(DP.build_rig(a,bn), _ofn(load,nom), T, seed, sched='D', reserve_frac=rf, ttl_ms=ttl).run()
    bad=[k for k in ALLK if abs(x[k]-y[k])>1e-9]
    return (args, bad)

def job_c3(args):
    name, bn, load, seed = args
    a=_arches(name); nom=_nom(a)
    dp = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='Dp').run()
    pl = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='pull').run()
    rowbad=[k for k in SHARED if abs(dp[k]-pl[k])>1e-9]
    return (args, dp['armed_frac'], dp['res_tx'], rowbad)

def job_arm(args):
    name, bn, load, seed = args
    a=_arches(name); nom=_nom(a)
    dp = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='Dp').run()
    return (args, dp['armed_frac'])

def job_net(args):
    name, bn, load, seed = args
    a=_arches(name); nom=_nom(a)
    pull = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='pull').run()
    dp   = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='Dp').run()
    d    = R.SimD(R.build_rig(a,bn), _ofn(load,nom), T, seed, sched='D', reserve_frac=0.25, ttl_ms=200.0).run()
    return (args, {'pull':(pull['gp'],pull['loss'],pull['p99']),
                   'Dp':(dp['gp'],dp['loss'],dp['p99'],dp['armed_frac']),
                   'D':(d['gp'],d['loss'],d['p99'])})
