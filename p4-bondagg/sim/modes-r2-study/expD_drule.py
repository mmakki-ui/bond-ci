#!/usr/bin/env python3
# expD: the D-rule — physics-derived reorder give-up, zero invented constants.
#   A missing frame m with any successor buffered was ENQUEUED before every
#   buffered successor (single FIFO => seq order == enqueue order). So
#   arr(m) <= tau_min_buffered + D_slowest, where D_i = per-path delay
#   (arrival - enqueue-stamp), measured on every arriving frame. Give up when
#   now - tau_min(present) > max_i Dmax_i over paths that could carry m.
#   Windowed max (W) is the only residual parameter -> sensitivity-swept.
# Compares against fixed holds on the same runs (paired, zero re-run variance).
import sys, time
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import ackclock_sim as A
from holdlib import late_gaps, score, pct, med

INF = float('inf')

def drule_release(arr, enq, sent_on, W, warm=1.0, gran_ms=10.0):
    """Post-hoc D-rule resequencer. Per-path Dmax over trailing W seconds,
    D = (first-arrival - enqueue) of each delivered frame, path = its sent_on
    (pull: singleton). Give-up for blocked head when
    now - min(enq of buffered) > Dmax(active paths). Floor = timer granularity."""
    items = sorted((a, sq) for sq, a in arr.items() if a is not None)
    if not items: return dict(p50=0,p95=0,p99=0,late=0,skips=0,deliv=0)
    n = len(items); gran = gran_ms/1000.0
    max_seq = max(sq for _, sq in items); next_seq = min(sq for _, sq in items)
    present = {}   # seq -> (arr_t)
    ptau = {}      # seq -> enq (for buffered)
    release = {}; passed = {}
    dwin = {}      # path -> deque of (t, D_sec)
    from collections import deque as dq
    skips = 0; ptr = 0
    waits = []     # realized waits at give-up (diagnostic)
    def dmax(t):
        m = 0.0
        for p, q in dwin.items():
            while q and q[0][0] < t - W: q.popleft()
            for (_, D) in q:
                if D > m: m = D
        return max(m, gran)
    def feed(t, sq):
        a_ = t; D = a_ - enq[sq]
        for p in sent_on.get(sq, ()):
            dwin.setdefault(p, dq()).append((t, D))
    while ptr < n or next_seq <= max_seq:
        t_arr = items[ptr][0] if ptr < n else INF
        if present and next_seq not in present:
            tau0 = min(ptau[s] for s in present)
            t_give = tau0 + dmax(items[ptr-1][0] if ptr else 0.0)
        else:
            t_give = INF
        if t_arr == INF and t_give == INF:
            if present:
                # trailing buffered frames: flush at their arrival (sim end)
                for s in sorted(present):
                    if s >= next_seq: release[s] = present[s]
                break
            break
        if t_give <= t_arr:
            clock = max(t_give, items[ptr-1][0] if ptr else 0.0)
            # skip missing seqs up to first present, then deliver the run
            while next_seq <= max_seq and next_seq not in present:
                skips += 1; passed[next_seq] = clock; next_seq += 1
            while next_seq in present:
                a_ = present.pop(next_seq); ptau.pop(next_seq, None)
                release[next_seq] = max(clock, a_); next_seq += 1
        else:
            clock = t_arr
            while ptr < n and items[ptr][0] == t_arr:
                sq = items[ptr][1]
                feed(t_arr, sq)
                if sq >= next_seq and sq not in release:
                    present[sq] = t_arr; ptau[sq] = enq[sq]
                ptr += 1
            while next_seq in present:
                a_ = present.pop(next_seq); ptau.pop(next_seq, None)
                release[next_seq] = max(clock, a_); next_seq += 1
    rel = set(release)
    late = sum(1 for (a, sq) in items if sq not in rel and enq.get(sq, 0) > warm)
    lat = sorted((rt - enq[sq])*1000.0 for sq, rt in release.items() if enq[sq] > warm)
    return dict(p50=pct(lat,.5), p95=pct(lat,.95), p99=pct(lat,.99),
                late=late, skips=skips, deliv=len(lat))

if __name__ == '__main__':
    T = 9.0; SEEDS = 6
    t0 = time.time()
    CONFIGS = [
        ('canon edge/pull 0.85', [RC.cellA(RC.DROPS_A), RC.eth()], 'edge', 0.85, None),
        ('canon mid/Dc 0.85',    [RC.cellA(RC.DROPS_A), RC.eth()], 'mid',  0.85, None),
        ('S2 eth+wifi pull 90k', [RC.eth(), RC.wifi()], 'edge', None, 90000),
        ('S3 all pull 140k',     [RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)], 'edge', None, 140000),
    ]
    for (name, archs, bn, loadf, loadabs) in CONFIGS:
        defs = RC.build_rig(archs, bottleneck=bn)
        nom = sum(a['base'] for a in archs)
        L = loadabs if loadabs else loadf * nom
        of = lambda t, _L=L: float(_L)
        res = {w: {k: [] for k in ('p50','p95','p99','late')} for w in (0.5, 1.0, 3.0)}
        fixed = {h: {k: [] for k in ('p50','p95','p99','late')} for h in (0.04, 0.12, 0.223, 0.343)}
        for sd in range(SEEDS):
            sch = 'Dc' if (len(CONFIGS) and 'Dc' in name) else 'pull'
            if sch == 'Dc':
                sim = RC.SimD(defs, of, T, sd, sched='Dc'); sim.run()
            else:
                sim = A.Sim(defs, of, T, sd, sched='pull', mirror=False); sim.run()
            for w in res:
                d = drule_release(sim.arr, sim.enq, sim.sent_on, w)
                for k in res[w]: res[w][k].append(d[k])
            for h in fixed:
                sc = score(sim.arr, sim.enq, h)
                for k in fixed[h]: fixed[h][k].append(sc[k])
        print("\n== %s (%.0fs)" % (name, time.time()-t0))
        for h in sorted(fixed):
            f = fixed[h]
            print("   fixed %3.0fms: p50=%4.0f p95=%4.0f p99=%4.0f late=%5.1f"
                  % (h*1000, med(f['p50']), med(f['p95']), med(f['p99']), med(f['late'])))
        for w in sorted(res):
            r = res[w]
            print("   D-rule W=%.1fs: p50=%4.0f p95=%4.0f p99=%4.0f late=%5.1f"
                  % (w, med(r['p50']), med(r['p95']), med(r['p99']), med(r['late'])))
    print("total %.0fs" % (time.time()-t0))
