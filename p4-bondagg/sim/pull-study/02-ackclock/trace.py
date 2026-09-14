#!/usr/bin/env python3
# Time-trace C on MID-drop: per-tick path0/path1 cap, lam, budget, inflight,
# sends, pool depth, downstream backlog. See where C mis-admits.
import sys
sys.path.insert(0, '.')
from ackclock_sim import Sim, make_defs, PKT_KB

off = 0.85 * (29000 + 78000)
ofn = lambda t: off
dfn = lambda: make_defs('mid', local_mult=20.0)

CG = float(sys.argv[1]) if len(sys.argv) > 1 else 1.25
GATE = sys.argv[2] if len(sys.argv) > 2 else 'restart'  # 'restart' | 'loose' | 'const'

class TSim(Sim):
    def run(s):
        import math
        nticks = int(round(s.T / 0.01)); DT = 0.01
        s._front_lo = 0; s._maxarr = -1
        s.trace = []
        for tk in range(nticks):
            now = tk * DT
            # override rising gate for experiment
            self_gate = GATE
            caps = [s.defs[i]['cap_fn'](now) for i in range(s.N)]
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            s._process_acks(now); s._rto_reclaim(now)
            s._process_echoes(now); s._c_update(now)
            if GATE == 'loose':
                for i in range(s.N):
                    lo = s.lam_hist[i][0][1] if s.lam_hist[i] else 0.0
                    s.rising[i] = s.lam[i] > 1.05 * lo
            elif GATE == 'const':
                for i in range(s.N):
                    s.rising[i] = False
            offer = s.offer_fn(now); s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq[seq] = now; s.arr[seq] = None
                s.sent_on[seq] = set()
                if now > s.warm: s.offered_post += 1
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                seq = s.fifo.popleft(); s.qdrops += 1
            def local_ms(i):
                return s.local[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
            def room(i):
                if lcaps[i] <= 0: return False
                if local_ms(i) >= s.target_ms: return False
                inflight = s._c_inflight(i)
                if not s.has_reading[i]: return True
                if inflight < s.probe_frames and (now - s.last_send_t[i]) >= s.probe_int:
                    return True
                return inflight < max(1.0, s._c_budget(i))
            sent_this = [0, 0]
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = [i for i in range(s.N) if room(i)]
                if not cand: break
                cand.sort(key=local_ms)
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        s.sent_cum[i] += 1; s.flight_ts[i].append(now)
                        s.send_t[seq] = now; s.last_send_t[i] = now
                        sent_this[i] += 1; placed = True; break
                if not placed: break
            # mirror
            if s.mirror and not s.fifo:
                blocker = s._mirror_target()
                if blocker is not None:
                    mcand = [i for i in range(s.N) if room(i) and i not in s.sent_on[blocker]]
                    mcand.sort(key=local_ms)
                    for i in mcand[:1]:
                        if s.local[i].offer(blocker, s.enq[blocker], lcaps[i]):
                            s.sent_on[blocker].add(i); s.sent_cum[i] += 1
                            s.flight_ts[i].append(now); s.send_t[blocker] = now
                            s.last_send_t[i] = now
            if not s.fifo:
                for i in range(s.N):
                    if lcaps[i] <= 0 or local_ms(i) >= s.target_ms: continue
                    if not s.has_reading[i]: s.applim_t[i] = now
                    elif s._c_inflight(i) < s._c_budget(i): s.applim_t[i] = now
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (seq, enq, x1) in exited:
                    s.down[i].offer(seq, enq, dcaps[i])
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (seq, enq, x2) in delivered:
                    s._deliver(i, seq, x2, now); dk += PKT_KB
                s.deliv_hist[i].append((now, dk))
                aE = math.exp(-DT / 0.10)
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += 0.02*(s.defs[i]['cap_fn'](0.0)-s.drain_ewma[i])
                s.push_est[i] = s._lagged_deliv(i, now) or s.push_est[i]
            for i in range(s.N):
                while s.deliv_hist[i] and s.deliv_hist[i][0][0] < now-0.6:
                    s.deliv_hist[i].popleft()
            s._advance_front()
            if s._front_lo < s.next_seq and s.arr.get(s._front_lo) is None and s._maxarr > s._front_lo:
                s.hol_block_events += 1
            if tk % 10 == 0:
                s.trace.append((now, dcaps[0], s.lam[0], s._c_budget(0), s._c_inflight(0),
                                s.down[0].backlog_kb/PKT_KB, len(s.fifo),
                                s.rising[0], sent_this[0], sent_this[1]))
        return s.finalize()

sim = TSim(dfn(), ofn, 10.0, 0, sched='C', c_derive_hold=False, cruise_gain=CG)
r = sim.run(); r_trace = sim.trace
print("gate=%s cruise=%.2f gp=%.0f loss=%.1f p50=%.0f p95=%.0f tdrop=%.0f qd=%.0f late=%.0f lost=%.0f" % (
    GATE, CG, r['gp'], r['loss'], r['p50'], r['p95'], r['tdrop'], r['qdrops'], r['late'], r['c_lost']))
print("  t   dcap0  lam0  budg0  infl0  dbklg0  pool  rise s0 s1")
for (now, dc, lam, bg, inf, db, pool, ri, s0, s1) in r_trace:
    if 2.0 <= now <= 4.2:  # around first dropout (2.6-3.0)
        print("%4.2f %6.0f %5.0f %5.1f %5.0f %6.0f %5d %d %3d %3d" % (
            now, dc, lam, bg, inf, db, pool, ri, s0, s1))
