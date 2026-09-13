#!/usr/bin/env python3
# Architecture-review reproduction: does the MEASURED-LOCAL yardstick (reserved_local
# Dp) really collapse at MID load 0.85 like the cap0 yardstick, and is the gate
# structurally blind (host local_ms ~0, drain_ewma ~= its own windowed max on
# every tick, at every load)?  N2 cellA+eth, 24 seeds, T=9s, medians.
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_local as L

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1]+xs[n//2])/2.0

T = 9.0; SEEDS = 24
archs = [L.cellA(L.DROPS_A), L.eth()]
nom = sum(a['base'] for a in archs)

for rig in ('mid', 'edge'):
    defs = L.build_rig(archs, bottleneck=rig)
    for load in (0.55, 0.65, 0.75, 0.85):
        of = lambda t, _n=nom, _L=load: _L*_n
        rows = {}
        for sch in ('pull', 'Dp'):
            gp=[]; ls=[]; af=[]; rtx=[]; p95=[]
            for sd in range(SEEDS):
                m = L.SimD(defs, of, T, sd, sched=sch).run()
                gp.append(m['gp']); ls.append(m['loss']); af.append(m['armed_frac'])
                rtx.append(m['res_tx']); p95.append(m['p95'])
            rows[sch] = (med(gp), med(ls), med(af), med(rtx), med(p95))
        p = rows['pull']; d = rows['Dp']
        print("%s load=%.2f | pull gp=%7.0f loss=%5.1f p95=%4.0f | Dp gp=%7.0f "
              "loss=%5.1f p95=%4.0f armed=%.3f res_tx=%d" %
              (rig, load, p[0], p[1], p[4], d[0], d[1], d[4], d[2], int(d[3])))

# ---- mechanism probe: eth-host gate signals under Dp, mid, one seed, per-tick ----
print()
print("gate probe (mid, seed 0, Dp): fraction of ticks each gate clause is TRUE on the eth host")
defs = L.build_rig(archs, bottleneck='mid')
for load in (0.55, 0.85):
    of = lambda t, _n=nom, _L=load: _L*_n
    s = L.SimD(defs, of, T, 0, sched='Dp')
    # monkey-patch run loop is invasive; instead sample by stepping a copy manually
    # cheap probe: rerun with instrumentation via subclass
    class Probe(L.SimD):
        def __init__(s2, *a, **k):
            super().__init__(*a, **k)
            s2.g_ms = 0; s2.g_dr = 0; s2.g_both = 0; s2.nt = 0
        def _local_ms(s2, i):
            return super()._local_ms(i)
    pr = Probe(defs, of, T, 0, sched='Dp')
    # instrument by wrapping the healthy computation: easiest is to sample post-run
    # counters via a shim on _drain_wmax calls on the eth index (1)
    orig_run = L.SimD.run
    ms_true = dr_true = both = nt = 0
    # do a manual tick loop replicating the gate on host index 1 (eth)
    import math
    from collections import deque
    sim = L.SimD(defs, of, T, 0, sched='Dp')
    DT = L.DT
    ntick = int(round(T/DT))
    # run the real sim but sample gates each tick via a generator-style copy:
    # simplest faithful approach: patch armed accounting by subclassing run is heavy;
    # instead re-implement sampling inside a copy of run is error-prone. Use a
    # lightweight proxy: run the sim, but sample s.drain_ewma/_local_ms via a hook
    # on _drain_wmax (called once per path per tick inside the Dp branch).
    calls = {'n':0}
    samples = []
    orig_wmax = L.SimD._drain_wmax
    def wmax_hook(s2, i):
        v = orig_wmax(s2, i)
        if i == 1:  # eth host
            samples.append((s2._local_ms(1), s2.drain_ewma[1], v))
        return v
    L.SimD._drain_wmax = wmax_hook
    m = L.SimD(defs, of, T, 0, sched='Dp').run()
    L.SimD._drain_wmax = orig_wmax
    n = len(samples)
    ms_ok = sum(1 for (ms, de, wm) in samples if ms < 20.0)
    dr_ok = sum(1 for (ms, de, wm) in samples if de >= 0.75*wm)
    bo = sum(1 for (ms, de, wm) in samples if ms < 20.0 and de >= 0.75*wm)
    mean_ms = sum(ms for ms, _, _ in samples)/max(1, n)
    print("  load=%.2f: samples=%d  local_ms<20: %.3f  drain>=0.75*wmax: %.3f  "
          "BOTH: %.3f  mean local_ms=%.2f  (armed_frac=%.3f)" %
          (load, n, ms_ok/max(1,n), dr_ok/max(1,n), bo/max(1,n), mean_ms,
           m['armed_frac']))
