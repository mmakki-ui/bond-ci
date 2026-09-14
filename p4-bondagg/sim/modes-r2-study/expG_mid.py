#!/usr/bin/env python3
# expG: does the `speed` ordering survive the MID regime (hidden downstream
# bottleneck, local socket blind)? Dc-composite physics (meter-gated native,
# standing lightning) with three draw orders:
#   g0: hungriest (local_ms)          == settled Dc == `max`
#   g2: owd + local_ms                == V2 key (edge form; blind at mid)
#   g2m: owd + max(local_ms, far_ms)  == V2 key reusing the cap's own meter
# Canonical N2 mid rig (cellA+eth), loads 0.65/0.85, paired seeds.
import sys, time, math
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
from collections import deque
import reserved_composite as RC
import nsched_model as M
from holdlib import late_gaps, score, pct, med

PKT_KB = M.PKT_KB; DT = M.DT

class GSim(RC.SimD):
    def __init__(s, defs, of, T, sd, gkey='g0'):
        super().__init__(defs, of, T, sd, sched='Dc')
        s.gkey = gkey
        s.owd = [d['down_owd'] + d['loc_owd'] for d in defs]

    def _far_ms(s, i):
        est = max(1.0, s.push_est[i])
        return (s.local[i].backlog_kb + s.down[i].backlog_kb) / est * 1000.0

    def _key(s, i):
        if s.gkey == 'g0':  return s._local_ms(i)
        if s.gkey == 'g2':  return s.owd[i] + s._local_ms(i)
        return s.owd[i] + max(s._local_ms(i), s._far_ms(i))   # g2m

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
            at_risk = [s.spotty[i] and alive[i] for i in range(s.N)]
            host = [alive[i] and not at_risk[i] and s._meter_ok(i) for i in range(s.N)]
            armed = (any(at_risk) and any(host))
            if armed: s.armed_ticks += 1
            def room(i):
                return alive[i] and s._meter_ok(i)      # Dc native gate, verbatim
            guard = 0
            while s.fifo and guard < 200000:
                guard += 1
                cand = [i for i in range(s.N) if room(i)]
                if not cand: break
                cand.sort(key=s._key)
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        if armed and at_risk[i]:
                            s.mirror_q.append((seq, s.enq[seq], now)); s.mir_offered += 1
                        placed = True; break
                if not placed: break
            # PIECE 2: standing lightning, verbatim Dc
            ttl = s.dup_ttl
            if armed and s.mirror_q:
                mguard = 0
                while s.mirror_q and mguard < 200000:
                    mguard += 1
                    seq, enq, qt = s.mirror_q[0]
                    if now - qt > ttl:
                        s.mirror_q.popleft(); s.mir_aged += 1; continue
                    if s.arr.get(seq) is not None:
                        s.mirror_q.popleft(); continue
                    hc = [h for h in range(s.N) if host[h]
                          and h not in s.sent_on[seq] and s._meter_ok(h)]
                    if not hc: break
                    hc.sort(key=s._key)
                    h = hc[0]
                    if s.local[h].offer(seq, enq, lcaps[h]):
                        s.sent_on[seq].add(h); s.res_tx += 1
                    s.mirror_q.popleft()
                while s.mirror_q and now - s.mirror_q[0][2] > ttl:
                    s.mirror_q.popleft(); s.mir_aged += 1
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (sq, enq, x1) in exited:
                    s.down[i].offer(sq, enq, dcaps[i])
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (sq, enq, x2) in delivered:
                    if s.arr.get(sq) is None or x2 < s.arr[sq]:
                        s.arr[sq] = x2
                    dk += PKT_KB
                s.deliv_hist[i].append((now, dk))
                s.push_est[i] = s._lagged_deliv(i, now) or s.push_est[i]
                while s.deliv_hist[i] and s.deliv_hist[i][0][0] < now - 0.6:
                    s.deliv_hist[i].popleft()
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += RC.REGEN * (s.cap0[i] - s.drain_ewma[i])
        return s.finalize()

if __name__ == '__main__':
    T = 9.0; SEEDS = 6
    t0 = time.time()
    archs = [RC.cellA(RC.DROPS_A), RC.eth()]
    defs = RC.build_rig(archs, bottleneck='mid')
    nom = sum(a['base'] for a in archs)
    # sanity: GSim g0 must reproduce Dc (hungriest) closely
    print("rig=N2 mid cellA+eth  nom=%d" % nom)
    print("load key: gp loss%% tshare | p50/p95@ratchet late | dup_tx")
    for load in (0.40, 0.65, 0.85):
        for gk in ('g0', 'g2', 'g2m'):
            of = lambda t, _L=load: _L * nom
            c = {k: [] for k in ('gp','loss','ts','p50','p95','late','res')}
            for sd in range(SEEDS):
                sim = GSim(defs, of, T, sd, gkey=gk)
                r = sim.run()
                c['gp'].append(r['gp']); c['loss'].append(r['loss']); c['ts'].append(r['tshare'])
                c['res'].append(r['res_tx'])
                g = sorted(late_gaps(sim.arr))
                h = ((g[-1] if g else 0.0) + 1.0) / 1000.0
                sc = score(sim.arr, sim.enq, max(h, 0.010))
                c['p50'].append(sc['p50']); c['p95'].append(sc['p95']); c['late'].append(sc['late'])
            print("%.2f %-3s: gp=%6.0f loss=%5.2f ts=%.3f | p50=%4.0f p95=%4.0f late=%6.1f | dup=%5.0f (%.0fs)"
                  % (load, gk, med(c['gp']), med(c['loss']), med(c['ts']),
                     med(c['p50']), med(c['p95']), med(c['late']), med(c['res']),
                     time.time()-t0))
    # reference: true Dc for the sanity check
    for load in (0.65, 0.85):
        of = lambda t, _L=load: _L * nom
        c = {k: [] for k in ('gp','loss','ts')}
        for sd in range(SEEDS):
            r = RC.SimD(defs, of, T, sd, sched='Dc').run()
            c['gp'].append(r['gp']); c['loss'].append(r['loss']); c['ts'].append(r['tshare'])
        print("ref Dc %.2f: gp=%6.0f loss=%5.2f ts=%.3f (%.0fs)"
              % (load, med(c['gp']), med(c['loss']), med(c['ts']), time.time()-t0))
    print("total %.0fs" % (time.time()-t0))
