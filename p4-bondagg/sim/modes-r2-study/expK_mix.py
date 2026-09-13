#!/usr/bin/env python3
# expK: CALL + concurrent BULK in `speed` (one tunnel, one seq space).
#   Q3 regime change: call metrics with bulk present vs absent.
#   Q2 bounded WAIT window (delay-to-heal, NO discard) — does it heal the bulk's
#      inner reordering at zero cost to the call? W swept incl. derived (ratchet).
# Flow tags: cake-precedence replay — within each tick's enqueue batch the call's
# 3 Mbps worth of frames are first (cake on wgclient1 gives the sparse flow
# precedence); reconstructed post-hoc from enq times, zero sim changes.
import sys, time
sys.path.insert(0, '.')
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import nsched_model as M
from holdlib import late_gaps, pct, med
from expF_marginal import VSim
from expG_mid import GSim

PKT_KB = M.PKT_KB; DT = M.DT
DEADLINE = 50.0
CALL = 3000.0

def tag_flows(sim, call_rate=CALL):
    """Replay the enqueue accumulator: first floor(credit) frames of each tick's
    batch are call frames (cake precedence)."""
    flow = {}
    seqs = sorted(sim.enq)           # seq order == enqueue order
    credit = 0.0
    i = 0
    while i < len(seqs):
        t = sim.enq[seqs[i]]
        j = i
        while j < len(seqs) and sim.enq[seqs[j]] == t:
            j += 1
        credit += call_rate * DT / PKT_KB * max(1, round((t - sim.enq[seqs[i-1]]) / DT)) \
            if i else call_rate * DT / PKT_KB
        k = i
        while k < j and credit >= 1.0:
            flow[seqs[k]] = 'c'; credit -= 1.0; k += 1
        while k < j:
            flow[seqs[k]] = 'b'; k += 1
        i = j
    return flow

def resq_wait(arr, W_ms):
    """Bounded-WAIT resequencer, NO discard: buffer early frames up to W waiting
    for a gap; on timeout skip forward (deliver buffered in order); a frame
    arriving after its slot was given up is delivered IMMEDIATELY out of order.
    Returns {seq: (deliv_t, ooo)}. W=0 == deliver-on-arrival."""
    W = W_ms / 1000.0
    items = sorted((a, sq) for sq, a in arr.items() if a is not None)
    if not items: return {}
    out = {}
    nxt = min(sq for _, sq in items)
    buf = {}
    blocked = None
    maxd = -1        # highest seq delivered so far (ooo detector)
    def deliver(sq, t):
        nonlocal maxd
        out[sq] = (t, sq < maxd)
        if sq > maxd: maxd = sq
    for (t, sq) in items:
        # fire due timeouts before this arrival
        while blocked is not None and blocked + W <= t and buf:
            tt = blocked + W
            nxt = min(buf)                    # give up on the missing run
            while nxt in buf:
                deliver(nxt, tt); buf.pop(nxt); nxt += 1
            blocked = tt if buf else None
        if sq < nxt:
            deliver(sq, t)                    # late after give-up: OOO now
        elif sq == nxt:
            deliver(sq, t); nxt += 1
            while nxt in buf:
                deliver(nxt, t); buf.pop(nxt); nxt += 1
            blocked = t if buf else None
        else:
            buf[sq] = t
            if blocked is None: blocked = t
    while buf:                                # tail flush
        tt = (blocked + W) if blocked is not None else items[-1][0]
        nxt = min(buf)
        while nxt in buf:
            deliver(nxt, tt); buf.pop(nxt); nxt += 1
        blocked = tt if buf else None
    return out

def flow_stats(sim, out, flow, which, warm=1.0):
    sel = [(sq, dt_, ooo) for sq, (dt_, ooo) in out.items()
           if flow.get(sq) == which and sim.enq[sq] > warm]
    lat = sorted((dt_ - sim.enq[sq]) * 1000.0 for sq, dt_, _ in sel)
    off = sum(1 for sq, e in sim.enq.items()
              if flow.get(sq) == which and e > warm)
    deliv = len(lat)
    loss = 100.0 * (off - deliv) / off if off else 0.0
    dl = 100.0 * sum(1 for x in lat if x <= DEADLINE) / off if off else 0.0
    ooo = 100.0 * sum(1 for _, _, o in sel if o) / deliv if deliv else 0.0
    rts = sorted(dt_ for _, dt_, _ in sel)
    frz = max((b - a for a, b in zip(rts, rts[1:])), default=0.0) * 1000.0
    gp = deliv * PKT_KB / (sim.T - warm)
    return dict(loss=max(0.0, loss), p50=pct(lat, .5), p95=pct(lat, .95),
                p99=pct(lat, .99), dl=dl, ooo=ooo, frz=frz, gp=gp)

S3 = RC.build_rig([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)], bottleneck='edge')
MIDD = RC.build_rig([RC.cellA(RC.DROPS_A), RC.eth()], bottleneck='mid')
SC = [
    ('S3 call ALONE      ', 'V', S3, 3000.0),
    ('S3 call+bulk  30k  ', 'V', S3, 30000.0),   # fits best path
    ('S3 call+bulk  90k  ', 'V', S3, 90000.0),   # spill (eth+wifi)
    ('S3 call+bulk 140k  ', 'V', S3, 140000.0),  # deep saturation
    ('mid call ALONE     ', 'G', MIDD, 3000.0),
    ('mid call+bulk 0.65 ', 'G', MIDD, 0.65 * 107000),
]
SEEDS = 6
t00 = time.time()
for (name, kind, defs, L) in SC:
    of = lambda t, _L=L: float(_L)
    pol = {}
    t0 = time.time()
    for sd in range(SEEDS):
        sim = (VSim(defs, of, 9.0, sd, vkey='v2') if kind == 'V'
               else GSim(defs, of, 9.0, sd, gkey='g2'))
        sim.run()
        flow = tag_flows(sim)
        g = late_gaps(sim.arr)
        ratch = (max(g) if g else 0.0) + 1.0
        for pn, W in [('W=0/arr', 0.0), ('W=tick', 1.0), ('W=ratch', ratch),
                      ('W=20', 20.0), ('W=40', 40.0), ('W=343', 343.0)]:
            out = resq_wait(sim.arr, W)
            pol.setdefault(pn, {'c': [], 'b': [], 'W': []})
            pol[pn]['c'].append(flow_stats(sim, out, flow, 'c'))
            pol[pn]['b'].append(flow_stats(sim, out, flow, 'b'))
            pol[pn]['W'].append(W)
        print("  .. %s seed %d/%d ratch=%.0f ncall=%d (%.0fs)"
              % (name.strip(), sd + 1, SEEDS, ratch,
                 sum(1 for v in flow.values() if v == 'c'), time.time() - t0),
              flush=True)
    print("== %s (seeds=%d)" % (name.strip(), SEEDS))
    print("   %-8s %11s | CALL: %5s %5s %5s %6s %5s | BULK: %6s %5s %5s %6s"
          % ('policy', 'W mn/md/mx', 'p95', 'p99', 'dl50', 'frz', 'loss',
             'gp', 'p95', 'ooo%', 'loss'))
    for pn, d in pol.items():
        c, b, Ws = d['c'], d['b'], d['W']
        print("   %-8s %3.0f/%3.0f/%3.0f | %11.0f %5.0f %5.1f %6.0f %5.2f | %12.0f %5.0f %5.1f %6.2f"
              % (pn, min(Ws), med(Ws), max(Ws),
                 med([x['p95'] for x in c]), med([x['p99'] for x in c]),
                 med([x['dl'] for x in c]), med([x['frz'] for x in c]),
                 med([x['loss'] for x in c]),
                 med([x['gp'] for x in b]), med([x['p95'] for x in b]),
                 med([x['ooo'] for x in b]), med([x['loss'] for x in b])),
              flush=True)
print("TOTAL %.0fs" % (time.time() - t00))
