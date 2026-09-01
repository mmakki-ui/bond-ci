#!/usr/bin/env python3
# expH: per-MODE loss<->latency frontier of the reorder hold, incl. hold==0 and
# DELIVER-ON-ARRIVAL (no in-order wait at all — the leading `speed` candidate:
# the RT-video app runs its own jitter buffer; serial buffers add).
# speed = VSim v2 / GSim g2 (the settled key); max = v0/g0 (hungriest).
# Call regime weighted (3 Mbps); spill/saturation kept as the exception.
# hold==0 via a termination-fixed reorder_release copy, byte-verified inert
# for hold>0.
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

INF = float('inf')
TICK = 1.0     # model granularity, ms (DT)
DEADLINE = 50.0  # ms: stated datapath share of the G.114 ~150ms one-way budget

# ---- reorder_release with the hold==0 livelock fix --------------------------
# ONE change vs nsched_model.reorder_release: the flush branch is skipped --
# ONLY when hold<=0 -- in the no-progress state (present empty AND the next
# pending arrival's seq <= next_seq), letting that arrival advance the clock.
# For hold>0 the added clauses are never consulted (short-circuit on hold>0.0):
# byte-identical by construction; verified below anyway.
def reorder_release_z(items, hold):
    if not items:
        return {}, 0, 0
    arr = sorted(items)
    n = len(arr)
    max_seq = max(s for _, s in arr)
    next_seq = min(s for _, s in arr)
    present = {}; release = {}
    skips = 0; max_depth = 0
    blocked_at = None; ptr = 0
    while ptr < n or next_seq <= max_seq:
        t_arr = arr[ptr][0] if ptr < n else INF
        t_hold = (blocked_at + hold) if blocked_at is not None else INF
        if t_arr == INF and t_hold == INF:
            break
        flushable = (hold > 0.0 or present or ptr >= n
                     or arr[ptr][1] > next_seq)          # <- the only change
        if t_hold <= t_arr and flushable:
            clock = t_hold
            if present:
                target = max(present)
                while next_seq <= target:
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = clock if clock > a else a
                    else:
                        skips += 1
                    next_seq += 1
            else:
                tgt = arr[ptr][1] if ptr < n else max_seq + 1
                while next_seq < tgt:
                    skips += 1
                    next_seq += 1
            blocked_at = None
        else:
            clock = t_arr
            while ptr < n and arr[ptr][0] == t_arr:
                sq = arr[ptr][1]
                if sq >= next_seq and sq not in release:
                    present[sq] = t_arr
                ptr += 1
        while next_seq in present:
            a = present.pop(next_seq)
            release[next_seq] = clock if clock > a else a
            next_seq += 1
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None:
                blocked_at = clock
        else:
            blocked_at = None
        if len(present) > max_depth:
            max_depth = len(present)
    return release, skips, max_depth

def _stats(sim, pairs, warm=1.0):
    """pairs: list of (seq, delivery_time). Percentiles + loss + deadline hit +
    freeze (max inter-delivery gap, the app-visible stall) + max ring wait."""
    lat = sorted((rt - sim.enq[sq]) * 1000.0 for sq, rt in pairs
                 if sim.enq[sq] > warm)
    deliv = len(lat)
    gp = deliv * M.PKT_KB / (sim.T - warm)
    loss = 100.0 * (sim.offered_post - deliv) / sim.offered_post if sim.offered_post else 0.0
    dl = 100.0 * sum(1 for x in lat if x <= DEADLINE) / sim.offered_post \
        if sim.offered_post else 0.0
    rts = sorted(rt for sq, rt in pairs if sim.enq[sq] > warm)
    frz = max((b - a for a, b in zip(rts, rts[1:])), default=0.0) * 1000.0
    wmax = max(((rt - sim.arr[sq]) for sq, rt in pairs
                if sim.enq[sq] > warm and sim.arr.get(sq) is not None), default=0.0) * 1000.0
    return dict(gp=gp, loss=max(0.0, loss), p50=pct(lat, .5), p95=pct(lat, .95),
                p99=pct(lat, .99), dl=dl, frz=frz, wmax=wmax)

def score_hold(sim, hold_ms):
    items = [(a, sq) for sq, a in sim.arr.items() if a is not None]
    release, skips, depth = reorder_release_z(items, hold_ms / 1000.0)
    return _stats(sim, list(release.items()))

def score_arrival(sim):
    """Deliver-on-arrival: dedup-only ring, zero wait, no discard, no order."""
    pairs = [(sq, a) for sq, a in sim.arr.items() if a is not None]
    st = _stats(sim, pairs)
    g = late_gaps(sim.arr)             # frames that arrive after a higher seq
    n = len(pairs)
    st['ooo'] = 100.0 * len(g) / n if n else 0.0
    return st

# ---- verification -----------------------------------------------------------
def verify():
    print("VERIFY reorder_release_z ...", flush=True)
    defs3 = RC.build_rig([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)], bottleneck='edge')
    s1 = VSim(defs3, lambda t: 90000.0, 9.0, 0, vkey='v2'); s1.run()
    defsm = RC.build_rig([RC.cellA(RC.DROPS_A), RC.eth()], bottleneck='mid')
    s2 = GSim(defsm, lambda t: 0.65 * 107000, 9.0, 0, gkey='g0'); s2.run()
    for tag, s in (('edge-v2', s1), ('mid-g0', s2)):
        items = [(a, sq) for sq, a in s.arr.items() if a is not None]
        for h in (0.001, 0.043, 0.343):
            r0, k0, d0 = M.reorder_release(items, h)
            r1, k1, d1 = reorder_release_z(items, h)
            assert r0 == r1 and k0 == k1, "DIVERGENCE %s hold=%s" % (tag, h)
        t0 = time.time()
        rz, kz, dz = reorder_release_z(items, 0.0)
        print("  %s: hold>0 byte-identical (1/43/343ms); hold=0 terminated %.2fs"
              " (rel=%d skips=%d)" % (tag, time.time() - t0, len(rz), kz), flush=True)

verify()

# ---- scenarios --------------------------------------------------------------
S3 = RC.build_rig([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)], bottleneck='edge')
S4 = RC.build_rig([RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C)],
                  bottleneck='edge')
MIDD = RC.build_rig([RC.cellA(RC.DROPS_A), RC.eth()], bottleneck='mid')
NOM = 107000.0
SC = [
    # ---- call regime (the speed NORMAL operating point) ----
    ('speed CALL S3   3k', 'V', S3, 3000.0, 'v2'),
    ('speed CALL S4   3k', 'V', S4, 3000.0, 'v2'),   # only-spotty, dropouts mid-call
    ('speed CALL mid  3k', 'G', MIDD, 3000.0, 'g2'), # tether+eth, hidden mid
    # ---- spill / saturation (the exception) ----
    ('speed edge S3  90k', 'V', S3, 90000.0, 'v2'),
    ('speed mid  N2 0.65', 'G', MIDD, 0.65 * NOM, 'g2'),
    ('speed mid  N2 0.85', 'G', MIDD, 0.85 * NOM, 'g2'),
    # ---- max (bulk objective; existing analysis) ----
    ('max   edge S3  90k', 'V', S3, 90000.0, 'v0'),
    ('max   edge S3 140k', 'V', S3, 140000.0, 'v0'),
    ('max   edge S4  50k', 'V', S4, 50000.0, 'v0'),
    ('max   mid  N2 0.65', 'G', MIDD, 0.65 * NOM, 'g0'),
    ('max   mid  N2 0.85', 'G', MIDD, 0.85 * NOM, 'g0'),
]
SEEDS = 6
t00 = time.time()
for (name, kind, defs, L, key) in SC:
    of = lambda t, _L=L: float(_L)
    pol = {}; holds_seen = {}
    t0 = time.time()
    plist_names = None
    for sd in range(SEEDS):
        sim = (VSim(defs, of, 9.0, sd, vkey=key) if kind == 'V'
               else GSim(defs, of, 9.0, sd, gkey=key))
        sim.run()
        tot = sum(sim.assigned) or 1
        act = [i for i in range(sim.N) if sim.assigned[i] / tot > 0.01]
        owds = [defs[i]['down_owd'] + defs[i]['loc_owd'] for i in act]
        jits = [defs[i]['jit'] for i in act]
        sp = (max(owds) - min(owds)) if len(owds) > 1 else 0.0
        j = max(jits) if jits else 0.0
        g = late_gaps(sim.arr)
        ratch = (max(g) if g else 0.0) + TICK
        plist = [('arrival', None), ('zero', 0.0), ('tick', TICK),
                 ('spread', max(sp, TICK)), ('sp+1j', max(sp + j, TICK)),
                 ('sp+2j', max(sp + 2 * j, TICK)), ('sp+3j', max(sp + 3 * j, TICK)),
                 ('ratchet', ratch), ('343', 343.0)]
        plist_names = [p for p, _ in plist]
        for pn, h in plist:
            sc = score_arrival(sim) if h is None else score_hold(sim, h)
            pol.setdefault(pn, []).append(sc)
            holds_seen.setdefault(pn, []).append(-1.0 if h is None else h)
        print("  .. %s seed %d/%d act=%s sp=%.0f j=%.0f ratch=%.0f (%.0fs)"
              % (name, sd + 1, SEEDS, act, sp, j, ratch, time.time() - t0), flush=True)
    print("== %s  (seeds=%d)" % (name, SEEDS))
    print("   %-8s %13s %9s %7s %6s %6s %6s %6s %6s %6s %6s" %
          ('policy', 'hold mn/md/mx', 'gp', 'loss%', 'p50', 'p95', 'p99',
           'dl50', 'frz', 'wmax', 'ooo'))
    for pn in plist_names:
        rows = pol[pn]; hs = holds_seen[pn]
        ooo = med([x.get('ooo', -1) for x in rows])
        print("   %-8s %3.0f/%4.0f/%4.0f %9.0f %7.2f %6.0f %6.0f %6.0f %6.1f %6.0f %6.0f %6s" %
              (pn, min(hs), med(hs), max(hs),
               med([x['gp'] for x in rows]), med([x['loss'] for x in rows]),
               med([x['p50'] for x in rows]), med([x['p95'] for x in rows]),
               med([x['p99'] for x in rows]),
               med([x['dl'] for x in rows]),
               med([x['frz'] for x in rows]), med([x['wmax'] for x in rows]),
               ('%.1f' % ooo) if ooo >= 0 else '-'), flush=True)
print("TOTAL %.0fs" % (time.time() - t00))
