#!/usr/bin/env python3
# expA: measure what the reorder hold costs and what the observed late-arrival
# gap distribution really is, on the settled datapath's own runs.
# One sim run -> many hold policies (post-hoc rescoring, zero re-run variance).
import sys, time, math
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import ackclock_sim as A
import nsched_model as M

reorder_release = M.reorder_release
INF = float('inf')

def pct(sorted_xs, p):
    if not sorted_xs: return 0.0
    return sorted_xs[min(len(sorted_xs)-1, int(p*(len(sorted_xs)-1)))]

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1]+xs[n//2])/2.0

# ---- observed late gaps: gap(s) = arr(s) - min_{s'>s} arr(s'), if > 0 -------
def late_gaps(arr):
    seqs = sorted(sq for sq, a in arr.items() if a is not None)
    m = INF; gaps = []
    for sq in reversed(seqs):
        a = arr[sq]
        if a > m:
            gaps.append((a - m) * 1000.0)   # ms
        if a < m: m = a
    return gaps

# ---- score a run under a FIXED hold ----------------------------------------
def score(arr, enq, hold, warm=1.0):
    items = [(a, sq) for sq, a in arr.items() if a is not None]
    release, skips, depth = reorder_release(items, hold)
    rel = set(release)
    late = sum(1 for (a, sq) in items if sq not in rel and enq.get(sq, 0) > warm)
    lat = sorted((rt - enq[sq]) * 1000.0 for sq, rt in release.items() if enq[sq] > warm)
    nd = len(lat)
    return dict(p50=pct(lat,.5), p95=pct(lat,.95), p99=pct(lat,.99),
                late=late, skips=skips, deliv=nd)

# ---- DYNAMIC derived-hold resequencer (online, receiver-side only) ---------
# hold(t) = quantile q of observed late-gap samples in the trailing W seconds.
# Sample sources: (1) blocked head arrives -> now - blocked_at;
# (2) already-skipped seq arrives late -> now - passed_time[seq] (un-censoring).
# Warm-up: no samples -> hold = 0 (one path => no reorder => correct).
def dyn_release(arr, enq, q, W, warm=1.0, gran_ms=10.0):
    items = sorted((a, sq) for sq, a in arr.items() if a is not None)
    if not items: return dict(p50=0,p95=0,p99=0,late=0,skips=0,deliv=0,holds=[])
    n = len(items)
    max_seq = max(sq for _, sq in items)
    next_seq = min(sq for _, sq in items)
    present = {}; release = {}
    passed = {}          # seq -> time frontier passed it (skip instant)
    samples = []         # (t, gap_ms) sorted by t
    holds = []           # (t, hold_ms) trace
    skips = 0; ptr = 0
    blocked_at = None
    gran = gran_ms / 1000.0
    def hold_now(t):
        lo = t - W
        xs = sorted(g for (ts, g) in samples if ts >= lo)
        h = pct(xs, q) / 1000.0 if xs else 0.0
        return max(h, gran)      # timer granularity = the only floor
    while ptr < n or next_seq <= max_seq:
        t_arr = items[ptr][0] if ptr < n else INF
        t_hold = (blocked_at + hold_now(blocked_at)) if blocked_at is not None else INF
        if t_arr == INF and t_hold == INF: break
        if t_hold <= t_arr:
            clock = t_hold
            if present:
                target = max(present)
                while next_seq <= target:
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = max(clock, a)
                    else:
                        skips += 1; passed[next_seq] = clock
                    next_seq += 1
            else:
                tgt = items[ptr][1] if ptr < n else max_seq + 1
                while next_seq < tgt:
                    skips += 1; passed[next_seq] = clock
                    next_seq += 1
            blocked_at = None
        else:
            clock = t_arr
            while ptr < n and items[ptr][0] == t_arr:
                sq = items[ptr][1]
                if sq >= next_seq and sq not in release:
                    present[sq] = t_arr
                elif sq in passed:        # un-censoring: late arrival of a skipped seq
                    samples.append((t_arr, (t_arr - passed.pop(sq)) * 1000.0))
                ptr += 1
        moved = False
        while next_seq in present:
            a = present.pop(next_seq)
            if blocked_at is not None and a >= blocked_at and next_seq not in release:
                samples.append((a, (a - blocked_at) * 1000.0))  # head waited, arrived
            release[next_seq] = max(clock, a)
            next_seq += 1; moved = True
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None or moved:
                blocked_at = clock
                holds.append((clock, hold_now(clock) * 1000.0))
        else:
            blocked_at = None
    rel = set(release)
    late = sum(1 for (a, sq) in items if sq not in rel and enq.get(sq, 0) > warm)
    lat = sorted((rt - enq[sq]) * 1000.0 for sq, rt in release.items() if enq[sq] > warm)
    return dict(p50=pct(lat,.5), p95=pct(lat,.95), p99=pct(lat,.99),
                late=late, skips=skips, deliv=len(lat),
                hold_med=med([h for _, h in holds]) if holds else 0.0,
                hold_max=max([h for _, h in holds]) if holds else 0.0)

# ---- run battery ------------------------------------------------------------
T = 9.0; SEEDS = 8
archs = [RC.cellA(RC.DROPS_A), RC.eth()]
nom = sum(a['base'] for a in archs)
CONFIGS = [
    ('mid/Dc',   RC.build_rig(archs, bottleneck='mid'),  'Dc'),
    ('edge/pull',RC.build_rig(archs, bottleneck='edge'), 'pull'),
]
HOLD_SWEEP = [0.010, 0.020, 0.040, 0.080, 0.120, 0.160, 0.223, 0.343]
DYN_GRID = [(0.99, 3.0), (1.0, 3.0), (0.99, 1.0), (0.95, 3.0)]

t0 = time.time()
for load in (0.65, 0.85):
    of = lambda t, _n=nom, _L=load: _L * _n
    for (name, defs, sch) in CONFIGS:
        gap_all = []
        fx = {h: {k: [] for k in ('p50','p95','p99','late','deliv')} for h in HOLD_SWEEP}
        dyn = {qg: {k: [] for k in ('p50','p95','p99','late','deliv','hold_med','hold_max')}
               for qg in DYN_GRID}
        gp_list = []
        for sd in range(SEEDS):
            if sch == 'Dc':
                sim = RC.SimD(defs, of, T, sd, sched='Dc'); r = sim.run()
            else:
                sim = A.Sim(defs, of, T, sd, sched='pull', mirror=False); r = sim.run()
            gp_list.append(r['gp'])
            g = late_gaps(sim.arr)
            gap_all.append(sorted(g))
            for h in HOLD_SWEEP:
                sc = score(sim.arr, sim.enq, h)
                for k in fx[h]: fx[h][k].append(sc[k])
            for qg in DYN_GRID:
                sc = dyn_release(sim.arr, sim.enq, qg[0], qg[1])
                for k in dyn[qg]: dyn[qg][k].append(sc[k])
        # pooled gap stats
        pool = sorted(x for g in gap_all for x in g)
        ndel = med([fx[HOLD_SWEEP[-1]]['deliv'][i] for i in range(SEEDS)])
        print("\n== %s load=%.2f  gp(med)=%.0f  (%.0fs elapsed)" %
              (name, load, med(gp_list), time.time()-t0))
        if pool:
            print("   gaps: n(med/run)=%.0f  p50=%.1f p90=%.1f p99=%.1f p999=%.1f max=%.1f ms"
                  % (med([len(g) for g in gap_all]), pct(pool,.5), pct(pool,.9),
                     pct(pool,.99), pct(pool,.999), pool[-1]))
            print("   late-frac (gaps/deliv) = %.3f" % (len(pool)/SEEDS/max(1.0,ndel)))
        print("   %-9s %7s %7s %7s %7s" % ("hold_ms", "p50", "p95", "p99", "late"))
        for h in HOLD_SWEEP:
            tag = {0.223:'model', 0.343:'daemon'}.get(h, '')
            print("   %-9s %7.0f %7.0f %7.0f %7.1f  %s" %
                  ("%.0f" % (h*1000), med(fx[h]['p50']), med(fx[h]['p95']),
                   med(fx[h]['p99']), med(fx[h]['late']), tag))
        for qg in DYN_GRID:
            d = dyn[qg]
            print("   dyn q=%.2f W=%.0fs: p50=%.0f p95=%.0f p99=%.0f late=%.1f hold_med=%.0f hold_max=%.0f"
                  % (qg[0], qg[1], med(d['p50']), med(d['p95']), med(d['p99']),
                     med(d['late']), med(d['hold_med']), med(d['hold_max'])))
print("\ntotal %.0fs" % (time.time()-t0))
