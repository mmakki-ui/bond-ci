#!/usr/bin/env python3
# expJ: does `speed` demote a degrading primary under all THREE degradation
# types, and does the rank need a delivered-quality term?
#   DEG-EDGE : primary local cap 20000 -> 1500 during [3,5)  (socket backs up)
#   DEG-MID  : same but the cap is the HIDDEN downstream stage (socket fine)
#   DEG-LOSS : primary drops 5% of frames during [3,5), latency unchanged
# Keys: K1 = static-floor + local_ms (current design)
#       K2 = last-delivered-delay + local_ms       (event-driven, windowless)
#       K3 = K2 / (1 - p̂loss)  (expected latency per USEFUL frame; p̂ over the
#            pre-existing 500ms loss-report cadence, 250ms maturity lag)
# Call offer 3 Mbps. Delivery scored as ARRIVAL (speed's chosen delivery).
# Reported: primary-share timeline (200ms buckets over [2.6,5.4)), demote time,
# window call stats, skew spike.
import sys, time, math
from collections import deque
sys.path.insert(0, '.')
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import reserved_composite as RC
import nsched_model as M
from holdlib import late_gaps, pct, med
from expF_marginal import VSim

PKT_KB = M.PKT_KB; DT = M.DT
DEADLINE = 50.0
MAT = 0.25   # loss maturity lag (~owd+jitter bound; detection, not a hold)
LWIN = 0.50  # loss-estimate window == pre-existing LossIval cadence

PRIM = dict(spotty=True, base=20000, amp=1000, period=5.0,
            dropouts=[(3.0, 5.0)], shape=1500.0, floor=3000.0,
            loc_owd_edge=8.0, down_owd_edge=2.0, jit=2.0)
PRIM_NOSHAPE = dict(PRIM, dropouts=[])
SEC = RC.wifi()   # 16ms, jit 8, steady clean

class KSim(VSim):
    """VSim with pluggable rank key, per-frame loss injection, draw log,
    last-delivered-delay + windowed loss estimate per path."""
    def __init__(s, defs, of, T, sd, kmode='K1', lossp=None):
        super().__init__(defs, of, T, sd, vkey='v2')
        s.kmode = kmode
        s.lossp = lossp or (lambda t, i: 0.0)
        s.lastD = [s.owd[i] for i in range(s.N)]     # ms
        s.sentlog = [deque() for _ in range(s.N)]    # (t, seq) awaiting maturity
        s.matured = [deque() for _ in range(s.N)]    # (t, lost01) matured samples
        s.drawlog = []
        s.injected = 0

    def _phat(s, i, now):
        q = s.matured[i]
        while q and q[0][0] < now - MAT - LWIN:
            q.popleft()
        if not q:
            return 0.0
        return sum(x for _, x, _u in q) / len(q)

    def _hhat(s, i, now):
        # deadline-hit rate: P(delivered AND within DEADLINE), the derived
        # loss+latency fusion (B = the stated external budget, no coefficient)
        q = s.matured[i]
        while q and q[0][0] < now - MAT - LWIN:
            q.popleft()
        if not q:
            return 1.0
        return sum(u for _, _x, u in q) / len(q)

    def _key(s, i, now):
        if s.kmode == 'K1':
            return s.owd[i] + s._local_ms(i)
        base = s.lastD[i] + s._local_ms(i)
        if s.kmode == 'K2':
            return base
        if s.kmode == 'K4':
            return (-s._hhat(i, now), base)
        return base / max(1e-6, 1.0 - s._phat(i, now))

    def run(s):
        nt = int(round(s.T / DT)); s.nticks = nt
        aE = math.exp(-DT / RC.DRAIN_TAU)
        for tk in range(nt):
            now = tk * DT
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq[seq] = now; s.arr[seq] = None
                s.sent_on[seq] = set()
                if now > s.warm: s.offered_post += 1
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                s.fifo.popleft(); s.qdrops += 1
            alive = [lcaps[i] > 0 for i in range(s.N)]
            def room(i):
                return alive[i] and s._local_ms(i) < s.target_ms
            guard = 0
            while s.fifo and guard < 200000:
                guard += 1
                cand = [i for i in range(s.N) if room(i)]
                if not cand: break
                cand.sort(key=lambda i: s._key(i, now))
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        s.drawlog.append((now, i))
                        s.sentlog[i].append((now, seq))
                        placed = True; break
                if not placed: break
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (sq, enq, x1) in exited:
                    s.down[i].offer(sq, enq, dcaps[i])
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                for (sq, enq, x2) in delivered:
                    if s.rng.random() < s.lossp(now, i):
                        s.injected += 1
                        continue                      # path loss: frame vanishes
                    if s.arr.get(sq) is None or x2 < s.arr[sq]:
                        s.arr[sq] = x2
                    s.lastD[i] = (x2 - enq) * 1000.0
                # mature loss samples
                q = s.sentlog[i]
                while q and q[0][0] < now - MAT:
                    t0, sq0 = q.popleft()
                    got = s.arr.get(sq0) is not None
                    u = 1 if (got and (s.arr[sq0] - s.enq[sq0]) * 1000.0 <= DEADLINE) else 0
                    s.matured[i].append((t0, 0 if got else 1, u))
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += RC.REGEN * (s.cap0[i] - s.drain_ewma[i])
        return None

class KSimMid(KSim):
    """Mid variant: the Dc far-meter gate, lightning DISABLED to isolate the key
    (flagged: shipped mid behaviour also has spotty-class duplication)."""
    def _far_ms(s, i):
        est = max(1.0, s.push_est[i])
        return (s.local[i].backlog_kb + s.down[i].backlog_kb) / est * 1000.0

    def __init__(s, defs, of, T, sd, kmode='K1', lossp=None):
        super().__init__(defs, of, T, sd, kmode=kmode, lossp=lossp)
        s.deliv_hist = [deque() for _ in range(s.N)]
        s.push_est = [d['cap_fn'](0.0) for d in defs]

    def _lagged_deliv(s, i, now):
        t_hi = now - M.NLAG; t_lo = t_hi - 0.100
        tot = 0.0
        for (t, dk) in s.deliv_hist[i]:
            if t_lo <= t < t_hi:
                tot += dk
        return tot / 0.100 if tot > 0 else 0.0

    def _meter_ok(s, i):
        if s._local_ms(i) >= s.target_ms:
            return False
        return s._far_ms(i) < s.target_ms

    def run(s):
        nt = int(round(s.T / DT)); s.nticks = nt
        aE = math.exp(-DT / RC.DRAIN_TAU)
        for tk in range(nt):
            now = tk * DT
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq[seq] = now; s.arr[seq] = None
                s.sent_on[seq] = set()
                if now > s.warm: s.offered_post += 1
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                s.fifo.popleft(); s.qdrops += 1
            alive = [lcaps[i] > 0 for i in range(s.N)]
            def room(i):
                return alive[i] and s._meter_ok(i)
            guard = 0
            while s.fifo and guard < 200000:
                guard += 1
                cand = [i for i in range(s.N) if room(i)]
                if not cand: break
                cand.sort(key=lambda i: s._key(i, now))
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        s.drawlog.append((now, i))
                        s.sentlog[i].append((now, seq))
                        placed = True; break
                if not placed: break
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (sq, enq, x1) in exited:
                    s.down[i].offer(sq, enq, dcaps[i])
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (sq, enq, x2) in delivered:
                    if s.rng.random() < s.lossp(now, i):
                        s.injected += 1; continue
                    if s.arr.get(sq) is None or x2 < s.arr[sq]:
                        s.arr[sq] = x2
                    s.lastD[i] = (x2 - enq) * 1000.0
                    dk += PKT_KB
                s.deliv_hist[i].append((now, dk))
                s.push_est[i] = s._lagged_deliv(i, now) or s.push_est[i]
                while s.deliv_hist[i] and s.deliv_hist[i][0][0] < now - 0.6:
                    s.deliv_hist[i].popleft()
                q = s.sentlog[i]
                while q and q[0][0] < now - MAT:
                    t0, sq0 = q.popleft()
                    got = s.arr.get(sq0) is not None
                    u = 1 if (got and (s.arr[sq0] - s.enq[sq0]) * 1000.0 <= DEADLINE) else 0
                    s.matured[i].append((t0, 0 if got else 1, u))
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += RC.REGEN * (s.cap0[i] - s.drain_ewma[i])
        return None

def call_stats(sim, w0=2.5, w1=6.0, warm=1.0):
    pairs = [(sq, a) for sq, a in sim.arr.items()
             if a is not None and w0 <= sim.enq[sq] < w1]
    lat = sorted((rt - sim.enq[sq]) * 1000.0 for sq, rt in pairs)
    off = sum(1 for sq, e in sim.enq.items() if w0 <= e < w1)
    deliv = len(lat)
    loss = 100.0 * (off - deliv) / off if off else 0.0
    dl = 100.0 * sum(1 for x in lat if x <= DEADLINE) / off if off else 0.0
    rts = sorted(rt for _, rt in pairs)
    frz = max((b - a for a, b in zip(rts, rts[1:])), default=0.0) * 1000.0
    g = late_gaps({sq: a for sq, a in sim.arr.items()
                   if a is not None and w0 <= sim.enq[sq] < w1})
    return dict(loss=max(0.0, loss), p50=pct(lat, .5), p95=pct(lat, .95),
                p99=pct(lat, .99), dl=dl, frz=frz,
                gmax=max(g) if g else 0.0)

def share_timeline(sim, prim=0, t0=2.6, t1=5.4, dt=0.2):
    buckets = []
    nb = int(round((t1 - t0) / dt))
    cnt = [[0, 0] for _ in range(nb)]
    for (t, i) in sim.drawlog:
        if t0 <= t < t1:
            b = int((t - t0) / dt)
            cnt[b][0] += 1 if i == prim else 0
            cnt[b][1] += 1
    for b in range(nb):
        buckets.append(cnt[b][0] / cnt[b][1] if cnt[b][1] else -1.0)
    demote = next((t0 + b * dt for b in range(nb)
                   if t0 + b * dt >= 3.0 and 0 <= buckets[b] <= 0.5), None)
    return buckets, demote

SEEDS = 6
t00 = time.time()
EDGE_DEG = RC.build_rig([PRIM, SEC], bottleneck='edge')
MID_DEG = RC.build_rig([PRIM, SEC], bottleneck='mid')
EDGE_LOSS = RC.build_rig([PRIM_NOSHAPE, SEC], bottleneck='edge')
lossfn = lambda t, i: 0.05 if (i == 0 and 3.0 <= t < 5.0) else 0.0

CASES = [
    ('DEG-EDGE', KSim, EDGE_DEG, None),
    ('DEG-MID ', KSimMid, MID_DEG, None),
    ('DEG-LOSS', KSim, EDGE_LOSS, lossfn),
]
for cname, cls, defs, lfn in CASES:
    for kmode in ('K1', 'K2', 'K3', 'K4'):
        acc = []; tls = []; dms = []
        t0 = time.time()
        for sd in range(SEEDS):
            sim = cls(defs, lambda t: 3000.0, 9.0, sd, kmode=kmode, lossp=lfn)
            sim.run()
            st = call_stats(sim)
            tl, dm = share_timeline(sim)
            acc.append(st); tls.append(tl); dms.append(dm)
            print("  .. %s %s seed %d/%d demote=%s inj=%d (%.0fs)"
                  % (cname, kmode, sd + 1, SEEDS,
                     ('%.1f' % dm) if dm else 'never', sim.injected,
                     time.time() - t0), flush=True)
        nb = len(tls[0])
        mtl = [med([tls[s][b] for s in range(SEEDS)]) for b in range(nb)]
        dnum = [d for d in dms if d is not None]
        print("== %s %s  demote(med)=%s  (n_demoted=%d/%d)" %
              (cname, kmode,
               ('%.1fs' % med(dnum)) if dnum else 'NEVER', len(dnum), SEEDS))
        print("   prim share 2.6->5.4s/0.2: %s" %
              " ".join("%.2f" % x for x in mtl))
        print("   call[2.5,6): loss=%.2f%% p50=%.0f p95=%.0f p99=%.0f dl50=%.1f%% frz=%.0fms gmax=%.0fms"
              % tuple(med([a[k] for a in acc]) for k in
                      ('loss', 'p50', 'p95', 'p99', 'dl', 'frz', 'gmax')), flush=True)
print("TOTAL %.0fs" % (time.time() - t00))
