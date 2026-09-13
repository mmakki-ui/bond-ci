#!/usr/bin/env python3
# expF: V0 (hungriest) vs V1 (static latency order) vs V2 (marginal cost:
# owd_i + local_ms_i — ETA at the draw instant, no prediction) — one subclass,
# paired seeds, same physics. V2 is the ECF/EDPF form of `speed`.
import sys, time
SIM = r"C:/Users/mmakk/Claude Code/bond/p4-bondagg/sim"
RCD = SIM + r"/pull-study/03-reserved-composite"
sys.path[0:0] = [RCD, SIM]
import math
from collections import deque
import reserved_composite as RC
import nsched_model as M
from holdlib import late_gaps, score, pct, med

PKT_KB = M.PKT_KB; DT = M.DT; HUGE = 1e18

class VSim(RC.SimD):
    """SimD with sched='D', r=0 (== pure pull) and a pluggable draw order."""
    def __init__(s, defs, of, T, sd, vkey='v0'):
        super().__init__(defs, of, T, sd, sched='D', reserve_frac=0.0)
        s.vkey = vkey
        s.owd = [d['down_owd'] + d['loc_owd'] for d in defs]

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
                if s.vkey == 'v0':
                    cand.sort(key=s._local_ms)
                elif s.vkey == 'v1':
                    cand.sort(key=lambda i: (s.owd[i], s._local_ms(i)))
                else:  # v2: marginal completion = flight + current local wait
                    cand.sort(key=lambda i: s.owd[i] + s._local_ms(i))
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        placed = True; break
                if not placed: break
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (sq, enq, x1) in exited:
                    s.down[i].offer(sq, enq, dcaps[i])
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                for (sq, enq, x2) in delivered:
                    if s.arr.get(sq) is None or x2 < s.arr[sq]:
                        s.arr[sq] = x2
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += RC.REGEN * (s.cap0[i] - s.drain_ewma[i])
        return s.finalize()

if __name__ == '__main__':
    T = 9.0; SEEDS = 6
    t0 = time.time()
    RIGS = {
        'S3': ([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)], [30000, 60000, 90000, 115000, 140000]),
        'S4': ([RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C)], [15000, 30000, 50000]),
    }
    print("rig load V: gp loss%% | share | ng g99 gmx | p50/p95@ratchet late")
    for rig, (archs, loads) in RIGS.items():
        defs = RC.build_rig(archs, bottleneck='edge')
        for L in loads:
            for vk in ('v0', 'v1', 'v2'):
                of = lambda t, _L=L: float(_L)
                c = {k: [] for k in ('gp','loss','sh','ng','g99','gmx','p50','p95','late')}
                for sd in range(SEEDS):
                    sim = VSim(defs, of, T, sd, vkey=vk)
                    r = sim.run()
                    c['gp'].append(r['gp']); c['loss'].append(r['loss'])
                    tot = sum(sim.assigned) or 1
                    c['sh'].append([a/tot for a in sim.assigned])
                    g = sorted(late_gaps(sim.arr))
                    c['ng'].append(len(g)); c['g99'].append(pct(g,.99) if g else 0.0)
                    c['gmx'].append(g[-1] if g else 0.0)
                    h = ((g[-1] if g else 0.0) + 1.0) / 1000.0   # ratchet: max gap + 1 tick
                    sc = score(sim.arr, sim.enq, max(h, 0.010))
                    c['p50'].append(sc['p50']); c['p95'].append(sc['p95']); c['late'].append(sc['late'])
                sh = [med([x[i] for x in c['sh']]) for i in range(len(archs))]
                print("%s %6d %s: gp=%6.0f loss=%5.2f | %s | ng=%5.0f g99=%5.1f gmx=%5.1f | p50=%4.0f p95=%4.0f late=%5.1f (%.0fs)"
                      % (rig, L, vk, med(c['gp']), med(c['loss']),
                         "/".join("%.2f" % x for x in sh), med(c['ng']),
                         med(c['g99']), med(c['gmx']), med(c['p50']), med(c['p95']),
                         med(c['late']), time.time()-t0))
    print("total %.0fs" % (time.time()-t0))
