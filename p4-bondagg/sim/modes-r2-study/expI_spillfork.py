#!/usr/bin/env python3
# expI: does `speed` SPILL AT ALL for a call? Partial degradation mid-call:
# primary cap 20000 -> 1500 kb/s during [3.0,5.0)s (alive the whole time),
# offer = 3 Mbps call.
#   (a) spill      : VSim v2 on [primary, cellB-nodrop]; the key migrates.
#   (b-ideal)      : primary only; app adapts bitrate INSTANTLY to 0.9*cap.
#   (b-lag 0.7s)   : primary only; app adapts 0.7s after degradation onset.
# Scored: whole-run + window [2.5,6.0) (enq-scoped): p50/p95/p99, loss, dl50,
# freeze, delivered rate (the resolution cost of (b)).
# (a) scored under arrival / sp+1j / ratchet / 343; (b) under arrival.
import sys, time
sys.path.insert(0, '.')
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import nsched_model as M
from holdlib import late_gaps, pct, med
from expF_marginal import VSim
from expH_frontier import reorder_release_z

DEADLINE = 50.0
TICK = 1.0

PRIM = dict(spotty=True, base=20000, amp=1000, period=5.0,
            dropouts=[(3.0, 5.0)], shape=1500.0, floor=3000.0,
            loc_owd_edge=8.0, down_owd_edge=2.0, jit=2.0)
SEC = RC.cellB(())          # 33ms owd, jit 28, no dropouts

def stats(sim, pairs, w0=None, w1=None, warm=1.0):
    sel = [(sq, rt) for sq, rt in pairs if sim.enq[sq] > warm and
           (w0 is None or (w0 <= sim.enq[sq] < w1))]
    lat = sorted((rt - sim.enq[sq]) * 1000.0 for sq, rt in sel)
    off = sum(1 for sq, e in sim.enq.items() if e > warm and
              (w0 is None or (w0 <= e < w1)))
    deliv = len(lat)
    span = (w1 - w0) if w0 is not None else (sim.T - warm)
    gp = deliv * M.PKT_KB / span
    loss = 100.0 * (off - deliv) / off if off else 0.0
    dl = 100.0 * sum(1 for x in lat if x <= DEADLINE) / off if off else 0.0
    rts = sorted(rt for _, rt in sel)
    frz = max((b - a for a, b in zip(rts, rts[1:])), default=0.0) * 1000.0
    return dict(gp=gp, loss=max(0.0, loss), p50=pct(lat, .5), p95=pct(lat, .95),
                p99=pct(lat, .99), dl=dl, frz=frz)

def score(sim, hold_ms, w0=None, w1=None):
    items = [(a, sq) for sq, a in sim.arr.items() if a is not None]
    if hold_ms is None:
        pairs = [(sq, a) for sq, a in sim.arr.items() if a is not None]
    else:
        release, _, _ = reorder_release_z(items, hold_ms / 1000.0)
        pairs = list(release.items())
    return stats(sim, pairs, w0, w1)

def offer_flat(t):
    return 3000.0

def offer_adapt(lag):
    def f(t):
        if 3.0 + lag <= t < 5.0:
            return 0.9 * 1500.0
        return 3000.0
    return f

SEEDS = 6
t00 = time.time()
CASES = [
    ('a-spill', RC.build_rig([PRIM, SEC], bottleneck='edge'), offer_flat, 'v2'),
    ('b-ideal', RC.build_rig([PRIM], bottleneck='edge'), offer_adapt(0.0), 'v2'),
    ('b-lag.7', RC.build_rig([PRIM], bottleneck='edge'), offer_adapt(0.7), 'v2'),
]
for cname, defs, of, key in CASES:
    per = {}
    t0 = time.time()
    for sd in range(SEEDS):
        sim = VSim(defs, of, 9.0, sd, vkey=key)
        sim.run()
        g = late_gaps(sim.arr)
        ratch = (max(g) if g else 0.0) + TICK
        tot = sum(sim.assigned) or 1
        act = [round(a / tot, 3) for a in sim.assigned]
        sp = 33.0 + 2.0 - 10.0  # sec owd 35? informational only
        pols = ([('arrival', None), ('sp+1j', 10.0 + 28.0), ('ratchet', ratch),
                 ('343', 343.0)] if cname == 'a-spill' else [('arrival', None)])
        for pn, h in pols:
            per.setdefault(pn, {'full': [], 'win': []})
            per[pn]['full'].append(score(sim, h))
            per[pn]['win'].append(score(sim, h, 2.5, 6.0))
        print("  .. %s seed %d/%d share=%s ratch=%.0f (%.0fs)"
              % (cname, sd + 1, SEEDS, act, ratch, time.time() - t0), flush=True)
    print("== %s" % cname)
    print("   %-8s %-6s %8s %7s %6s %6s %6s %6s %6s" %
          ('policy', 'scope', 'gp', 'loss%', 'p50', 'p95', 'p99', 'dl50', 'frz'))
    for pn in per:
        for scope in ('full', 'win'):
            rows = per[pn][scope]
            print("   %-8s %-6s %8.0f %7.2f %6.0f %6.0f %6.0f %6.1f %6.0f" %
                  (pn, scope, med([x['gp'] for x in rows]),
                   med([x['loss'] for x in rows]), med([x['p50'] for x in rows]),
                   med([x['p95'] for x in rows]), med([x['p99'] for x in rows]),
                   med([x['dl'] for x in rows]), med([x['frz'] for x in rows])),
                  flush=True)
print("TOTAL %.0fs" % (time.time() - t00))
