#!/usr/bin/env python3
# =============================================================================
# attack1_midnet.py -- ADVERSARIAL attack #1 on the PULL conclusion.
#
# Load-bearing claim under test (pull_study.py lines 22-24):
#   "For a CLIENT->SERVER uplink the bottleneck buffer PHYSICALLY sits at the
#    client edge (tether/modem/qdisc/socket), so the client observes its fill
#    LAG-FREE (socket backpressure / EWOULDBLOCK)."
#
# That is the EDGE-BOTTLENECK assumption.  This script builds a MID-NETWORK
# bottleneck: the client's socket buffer drains fast into a LOCAL link
# (USB / wifi-to-phone), and the TRUE rate limit (carrier radio / APN-PGW
# shaper) sits ONE HOP DOWNSTREAM, invisible to the client's socket occupancy.
#
# Physics: two fluid FIFO queues in SERIES per tether, each using the EXACT
# PathProc math (q_ms = backlog/cap*1000; taildrop when q_ms > QMAX_MS; svc;
# owd; fractional-carry drain) copied verbatim from nsched_model.PathProc --
# NOT edited.  Stage-1 = observed local socket (cap = local_cap).  Stage-2 =
# hidden downstream shaper (cap = the study's tether_cap(t) trace).
#
# Three schedulers on the SAME two-stage ground truth + SAME deterministic cap
# trace + SAME seeds (paired physics):
#   PULL   : admits while the LOCAL (stage-1) ms-gate is open  (blind to stage-2)
#   PUSH   : admits at the LAGGED end-to-end DELIVERED rate (= stage-2 drain,
#            delayed NLAG=350ms) -- exactly what nsched's pong echoes
#            (deliv_sched bucketed by ARRIVAL, nsched_model.py line 614-619).
#   ORACLE : admits at the instantaneous stage-2 cap (unreachable; upper bound).
#
# local_mult sweeps EDGE (local_cap == down_cap, co-located) -> MID (local_cap
# >> down_cap).  If pull collapses only as local_mult grows, the pull win is
# CONDITIONAL on edge-bottleneck.
# =============================================================================
import math, sys, random
from collections import deque
import nsched_model as M

PKT_KB = M.PKT_KB; DT = M.DT; QMAX_MS = M.QMAX_MS; NLAG = M.NLAG


def tether_cap(base=29000.0, amp=24000.0, period=3.1, dropouts=(), floor=3000.0):
    def f(t):
        for (a, b) in dropouts:
            if a <= t < b:
                return 0.0
        return max(floor, base + amp * math.sin(2 * math.pi * t / period))
    return f

def eth_cap(base=78000.0, amp=12000.0, period=5.0):
    return lambda t: base + amp * math.sin(2 * math.pi * t / period + 1.0)


class Stage:
    """One fluid FIFO queue, PathProc math verbatim.  Holds per-frame FIFO of
    (seq, enq_t) for ordering + a fluid backlog_kb.  Taildrops on ENQUEUE when
    the standing queue already exceeds QMAX_MS worth (congestion backpressure)."""
    def __init__(s, owd_ms=0.0, jit_ms=0.0, qmax_ms=QMAX_MS):
        s.q = deque()            # (seq, enq_t)
        s.backlog_kb = 0.0
        s.owd = owd_ms; s.jit = jit_ms; s.qmax = qmax_ms
        s.carry = 0.0
        s.taildrops = 0; s.serviced = 0
        s.drain_rate = 0.0       # kb/s actually drained last tick (LOCAL egress)

    def q_ms(s, cap):
        return s.backlog_kb / cap * 1000.0 if cap > 0 else 1e9

    def offer(s, seq, enq_t, cap):
        # taildrop if standing queue exceeds the 300ms fluid bound (PathProc rule)
        if cap <= 0 or s.q_ms(cap) > s.qmax:
            s.taildrops += 1
            return False
        s.q.append((seq, enq_t)); s.backlog_kb += PKT_KB; s.serviced += 1
        return True

    def drain(s, cap, now, rng):
        """Drain up to cap*DT kb; return list of (seq, enq_t, exit_t) that left."""
        bl0 = s.backlog_kb
        budget = cap * DT + s.carry
        out = []
        while s.q and budget >= PKT_KB - 1e-9:
            seq, enq = s.q.popleft()
            budget -= PKT_KB; s.backlog_kb -= PKT_KB
            jit = max(0.0, rng.gauss(0.0, s.jit)) if s.jit > 0 else 0.0
            exit_t = now + DT + s.owd / 1000.0 + jit / 1000.0
            out.append((seq, enq, exit_t))
        s.carry = max(0.0, budget)
        if s.backlog_kb < 1e-9:
            s.backlog_kb = 0.0; s.carry = 0.0
        s.drain_rate = max(0.0, bl0 - s.backlog_kb) / DT
        return out


class TwoStageSim:
    """N paths; each path = [local Stage, downstream Stage].  Eth is single-cap
    (local==down, no mid-net gap).  Scheduler chooses which path draws the head."""
    def __init__(s, path_defs, offer_fn, T, seed, sched='pull', target_ms=40.0,
                 lbuf_ms=40.0, lat_bias=False):
        s.defs = path_defs        # list of dict(cap_fn, local_cap_fn, owd, jit, down_owd)
        s.offer_fn = offer_fn; s.T = T; s.rng = random.Random(seed)
        s.N = len(path_defs); s.sched = sched
        s.target_ms = target_ms; s.lbuf_ms = lbuf_ms; s.lat_bias = lat_bias
        s.local = [Stage(owd_ms=d['loc_owd'],
                         jit_ms=(d['jit'] if d.get('jit_stage')=='local' else 0.0))
                   for d in path_defs]
        s.down = [Stage(owd_ms=d['down_owd'],
                        jit_ms=(d['jit'] if d.get('jit_stage','down')=='down' else 0.0),
                        qmax_ms=d.get('down_qmax', QMAX_MS)) for d in path_defs]
        s.drain_ewma = [d['cap_fn'](0.0) for d in path_defs]   # LOCAL egress est
        s.fifo = deque(); s.next_seq = 0; s.frac = 0.0
        s.frames = {}             # seq -> arrival|None
        s.enq_t = {}              # seq -> app offer instant
        s.assigned = [0] * s.N
        # push: lagged end-to-end delivered-rate estimate, per path
        s.deliv_hist = [deque() for _ in range(s.N)]   # (t, delivered_kb this tick)
        s.push_est = [d['cap_fn'](0.0) for d in path_defs]
        s.offered_post = 0; s.warm = 1.0

    def _local_cap(s, i, t):
        d = s.defs[i]
        lc = d['local_cap_fn'](t)
        # backpressure knob: phone caps USB egress to <= downstream cap + slack
        if d.get('backpressure'):
            lc = min(lc, d['cap_fn'](t) * d['backpressure'])
        return lc

    def _lagged_deliv(s, i, now):
        # sum delivered kb in the CAP_REPORT(=100ms) window ending at now-NLAG,
        # i.e. exactly what the pong echoes (bucketed by arrival, 350ms stale).
        t_hi = now - NLAG
        t_lo = t_hi - 0.100
        tot = 0.0
        for (t, dk) in s.deliv_hist[i]:
            if t_lo <= t < t_hi:
                tot += dk
        return tot / 0.100 if tot > 0 else 0.0

    def run(s):
        nticks = int(round(s.T / DT))
        for tk in range(nticks):
            now = tk * DT
            caps = [s.defs[i]['cap_fn'](now) for i in range(s.N)]      # true bottleneck
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)] # downstream stage cap
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            # ---- offer ----
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq_t[seq] = now; s.frames[seq] = None
                if now > s.warm:
                    s.offered_post += 1
            # ---- admission ----
            def local_ms(i):
                return s.local[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
            def push_room(i):
                # admit while local socket NOT above the lagged-est time-bound:
                # target based on the END-TO-END delivered-rate estimate (push's
                # pong Ĉ).  This THROTTLES admission to ~stage-2 cap.
                est = max(1.0, s.push_est[i])
                # frames in flight (local + downstream) vs est drain time
                inflight = s.local[i].backlog_kb + s.down[i].backlog_kb
                return inflight / est * 1000.0 < s.target_ms
            def oracle_room(i):
                est = max(1.0, caps[i])
                inflight = s.local[i].backlog_kb + s.down[i].backlog_kb
                return inflight / est * 1000.0 < s.target_ms
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = []
                for i in range(s.N):
                    # pull sees ONLY the local socket: if local cap>0 it drains and
                    # the gate stays open, no matter what downstream is doing.
                    if lcaps[i] <= 0:
                        continue
                    if s.sched == 'pull':
                        ok = (s.local[i].backlog_kb < (s.lbuf_ms/1000.0)*s.defs[i]['cap_fn'](0.0)) \
                             if False else (local_ms(i) < s.target_ms)
                    elif s.sched == 'push':
                        ok = push_room(i)
                    else:
                        ok = oracle_room(i)
                    if ok:
                        cand.append(i)
                if not cand:
                    break
                if s.lat_bias:
                    cand.sort(key=lambda i: (s.defs[i]['down_owd'], local_ms(i)))
                else:
                    cand.sort(key=lambda i: local_ms(i))
                seq = s.fifo[0]
                placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq_t[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; placed = True
                        break
                if not placed:
                    break
            # ---- stage-1 drain -> feed stage-2 ; stage-2 drain -> deliver ----
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (seq, enq, x1) in exited:
                    # frame leaves local at x1; enters downstream now (tick-approx)
                    if not s.down[i].offer(seq, enq, dcaps[i]):
                        s.frames[seq] = None      # downstream taildrop = LOST
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (seq, enq, x2) in delivered:
                    s.frames[seq] = x2
                    dk += PKT_KB
                s.deliv_hist[i].append((now, dk))
                # update estimates
                aE = math.exp(-DT / 0.10)
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i]*aE + s.local[i].drain_rate*(1-aE)
                else:
                    s.drain_ewma[i] += 0.02*(s.defs[i]['cap_fn'](0.0) - s.drain_ewma[i])
                s.push_est[i] = s._lagged_deliv(i, now) or s.push_est[i]
            # trim deliv_hist
            for i in range(s.N):
                while s.deliv_hist[i] and s.deliv_hist[i][0][0] < now - 0.6:
                    s.deliv_hist[i].popleft()
        return s.finalize()

    def finalize(s):
        owds = [d['down_owd'] + d['loc_owd'] for d in s.defs]
        jits = [d['jit'] for d in s.defs]
        hold = ((max(owds)-min(owds)) + 3.0*max(jits) + 130.0)/1000.0
        hold = min(0.35, max(0.08, hold))
        deliv_items = [(a, seq) for seq, a in s.frames.items() if a is not None]
        release, skips, depth = M.reorder_release(deliv_items, hold)
        Teff = s.T - s.warm
        lat = []; deliv_data = 0
        for seq, rt in release.items():
            st = s.enq_t[seq]
            if st > s.warm:
                deliv_data += 1; lat.append((rt - st)*1000.0)
        lat.sort()
        def pct(p): return lat[min(len(lat)-1, int(p*(len(lat)-1)))] if lat else 0.0
        gp = deliv_data * PKT_KB / Teff
        loss = 100.0*(s.offered_post - deliv_data)/s.offered_post if s.offered_post else 0.0
        return {'gp': gp, 'loss': max(0.0, loss), 'p50': pct(.5), 'p95': pct(.95),
                'p99': pct(.99),
                'tdrop': sum(st.taildrops for st in s.down),
                'tshare': s.assigned[0]/(sum(s.assigned) or 1),
                'deliv': deliv_data}


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n//2] if n % 2 else (xs[n//2-1]+xs[n//2])/2.0

def agg(ms):
    return {k: med([m[k] for m in ms]) for k in ms[0]}


HUGE = 1e9

def make_defs(bottleneck='edge', local_mult=20.0, backpressure=None,
              down_qmax=QMAX_MS, drops=None, shaping=False):
    """bottleneck='edge': spotty cap sits on the LOCAL (observed) stage; downstream
       is passthrough.  Pull's socket occupancy == true bottleneck (study's model).
       bottleneck='mid': LOCAL drains fast+const (USB/wifi to phone); the spotty
       cap sits DOWNSTREAM (carrier), invisible to socket occupancy."""
    if drops is None:
        drops = [(a, a+0.4) for a in (2.6, 5.1, 7.6)]
    if shaping:
        # carrier SHAPING (rate throttle to a low positive floor, no full outage) --
        # the case a socket CANNOT see: bytes keep leaving, downstream just slows.
        def tcap(t, _d=drops):
            for (a, b) in _d:
                if a <= t < b:
                    return 4000.0            # throttled, NOT zero
            return max(3000.0, 29000.0 + 24000.0*math.sin(2*math.pi*t/3.1))
    else:
        tcap = tether_cap(dropouts=drops)
    ecap = eth_cap()
    if bottleneck == 'edge':
        # cap_fn on local; downstream passthrough (huge cap, just owd)
        return [
            dict(cap_fn=tcap, local_cap_fn=tcap, loc_owd=25.0, down_owd=2.0,
                 jit=25.0, jit_stage='local', backpressure=backpressure,
                 down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
            dict(cap_fn=ecap, local_cap_fn=ecap, loc_owd=8.0, down_owd=1.0,
                 jit=1.0, jit_stage='local', backpressure=backpressure,
                 down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
        ]
    # mid: local fast constant, cap_fn downstream
    tloc = lambda t: 30000.0*local_mult
    eloc = lambda t: 78000.0*local_mult
    return [
        dict(cap_fn=tcap, local_cap_fn=tloc, loc_owd=2.0, down_owd=25.0,
             jit=25.0, jit_stage='down', backpressure=backpressure,
             down_cap_fn=tcap, down_qmax=down_qmax),
        dict(cap_fn=ecap, local_cap_fn=eloc, loc_owd=1.0, down_owd=8.0,
             jit=1.0, jit_stage='down', backpressure=backpressure,
             down_cap_fn=ecap, down_qmax=down_qmax),
    ]


def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    seeds = 8 if 'quick' in sys.argv else 16
    T = 10.0
    offer = 0.85*(29000+78000); ofn = lambda t: offer
    hdr = lambda: print("  %-24s %8s %7s %6s %6s %7s %6s" %
                        ("config","gp","loss%","p50","p95","tdrop","tshr"))
    def row(tag, defs_fn):
        for sched in ('pull', 'push', 'oracle'):
            ms = [TwoStageSim(defs_fn(), ofn, T, sd, sched=sched).run()
                  for sd in range(seeds)]
            a = agg(ms)
            print("  %-24s %8.0f %7.1f %6.0f %6.0f %7.0f %6.2f" %
                  (f"{tag} {sched}", a['gp'], a['loss'], a['p50'], a['p95'],
                   a['tdrop'], a['tshare']))
        print()

    print("#"*80)
    print("# ATTACK 1  EDGE vs MID-NETWORK bottleneck.  seeds=%d  offer=85%% mean-total" % seeds)
    print("#"*80)

    print("\n== A. SANITY/EDGE: spotty cap on the LOCAL socket (study's assumption) ==")
    print("   pull SHOULD win here (socket occupancy == true bottleneck).")
    hdr()
    row("edge", lambda: make_defs('edge'))

    print("== B. MID-NET, hard dropouts downstream (carrier taildrops @300ms) ==")
    print("   spotty cap moved DOWNSTREAM; local socket drains fast (lm=20). ")
    hdr()
    row("mid-drop", lambda: make_defs('mid', local_mult=20.0))

    print("== C. MID-NET, carrier SHAPING (throttle to 4Mb, NO full outage) ==")
    print("   the purest hidden bottleneck: bytes always leave the socket. ")
    hdr()
    row("mid-shape", lambda: make_defs('mid', local_mult=20.0, shaping=True))

    print("== D. MID-NET + BACKPRESSURE spectrum (phone flow-controls USB) ==")
    print("   bp=1.0 -> local==down (full edge recovery); bp large -> mid. ")
    hdr()
    for bp in (1.0, 1.2, 1.5, 3.0):
        row(f"mid-bp{bp}", (lambda b=bp: make_defs('mid', local_mult=20.0, backpressure=b)))

    print("== E. MID-NET BUFFERBLOAT (deep 2000ms carrier buffer, drops->delay) ==")
    print("   loss stays low, LATENCY explodes: pull's other failure mode. ")
    hdr()
    row("mid-bloat", lambda: make_defs('mid', local_mult=20.0, down_qmax=2000.0))


if __name__ == '__main__':
    main()
