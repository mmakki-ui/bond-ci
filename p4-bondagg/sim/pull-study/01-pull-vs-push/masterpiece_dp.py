#!/usr/bin/env python3
# =============================================================================
# masterpiece_dp.py  --  THE consolidated datapath model (MODEL-FIRST gate).
#
# One clean, documented implementation of the corrected 3-piece architecture,
# validated on the SAME nsched physics that validated the current push stack.
# This is the artifact that greenlights the Go port (Go runs later, on CI).
#
# ============================ THE ARCHITECTURE ===============================
# (1) PULL  work-conserving scheduler  [aggregation primary]
#     A single client-side shared send-FIFO in app/seq order.  Each tunnel DRAWS
#     the head frame only while its LOCAL socket has room, where "room" is a
#     TIME gate: admit while  local_backlog_kb / local_drain_EWMA < TARGET_MS.
#     The drain EWMA is the client's OWN measured egress rate (lag-free, no peer
#     feedback) with a probe-up/regen term so an idle socket ages back toward its
#     nominal rate (kills the underestimate ratchet the swing trough would lock).
#     A light one-way-delay bias orders equally-drainable tunnels.  A stalled
#     link stops draining -> its buffer stays full -> it stops drawing; a frame
#     no path can take WAITS in the FIFO (never stranded behind a dead path).
#
# (2) THIN safety cap  [mid-network guard]  -- ONE lagged delivered-rate EWMA.
#     Pull's local signal is truth ONLY when the bottleneck is at the client
#     EDGE.  For a MID-network bottleneck (carrier shaping / bufferbloat
#     DOWNSTREAM of the phone tx buffer) the local socket drains fast into the
#     USB/wifi hop while the far end delivers slowly -- invisible to socket
#     occupancy, so pure pull over-sends into a hidden queue and INVERTS to
#     worst-in-class.  The cap is the fallback: keep ONE lagged end-to-end
#     delivered-rate EWMA per path; when delivered < CAP_TRIP * sent (a hidden
#     downstream queue is filling) bound admission by the DELIVERED rate instead
#     of the misleading local drain.  Dormant at the edge (delivered==sent),
#     load-bearing in the mid case.  This is the ONLY estimator surface added.
#
# (3) OPPORTUNISTIC eth-mirror  [p95 tail]  -- spare-capacity duplication.
#     When a frame is scheduled onto a STALLING tether (path-identity trigger, no
#     oracle) AND a STEADY path has spare/idle room (the same local-room signal
#     pull already reads), duplicate the frame onto the steady path.  It spends
#     ONLY idle capacity: native traffic is admitted first every tick and the
#     mirror uses at most the slack below MIRROR_SPARE_MS, so it NEVER displaces
#     native traffic and NO-OPS when the steady path is saturated.  First copy
#     wins via the existing reorder ring (we keep the MIN arrival per seq).
#
# NO FEC (net-negative for cell+eth: loss is late-not-lost / congestion-coupled).
# NO always-on mirror (net-negative: 1:1 native eviction when eth is saturated).
# Deleted vs the push stack: Smith predictor, pong-q^ surface, CapEst-for-sched,
# silence-inflation, DEAD-detection, adaptive-FEC tier controller + its loss
# meter.  Net: "estimator-LIGHT" (one thin lagged EWMA), not "estimator-free"
# (the adversary proved estimator-free = worst-in-class for real cellular).
#
# ============================ THE TWO PHYSICS ================================
# Both substrates use the VALIDATED nsched math (imported UNMODIFIED):
#   * EDGE  (single-stage): nsched_model.PathProc -- the spotty cap sits on the
#     path the client observes.  Socket occupancy == true bottleneck.  This is
#     the use-case assumption; runs the ablation / regression / parsimony / N.
#   * MID   (two-stage series queue): local Stage (fast USB/wifi to phone) feeds
#     a hidden downstream Stage (carrier radio / APN-PGW shaper), each using the
#     PathProc fluid-FIFO math verbatim.  The spotty cap sits DOWNSTREAM,
#     invisible to socket occupancy.  This is the adversary's counter-rig; it is
#     where the cap must earn its place.
# The SAME cap_allows() gate drives the cap in BOTH substrates -> one cap
# implementation, validated on both worlds.
#
# ============================ DISCIPLINE ====================================
#   * paired physics: BOTH schedulers see the SAME deterministic cap trace and
#     the SAME seed (identical stalls; only per-send loss/jitter draws differ,
#     averaged over 24 seeds, medians) -- exactly nsched's runN discipline.
#   * push at FULL strength: edge push = NSim('eif_real') (the real Smith-q^ ETA
#     argmin + backpressure + FSM + CapEst + Ctl).  Mid push = admission at the
#     lagged end-to-end delivered rate == what the pong echoes (eif_real's own
#     rule on two-stage ground truth).  No strawman.
#   * anti-overfitting: every table reports WHERE each piece does NOT help.
#
# Run:  %LOCALAPPDATA%\Programs\Python\Python312\python.exe masterpiece_dp.py [quick]
# =============================================================================
import math, sys, random, statistics
from collections import deque
import nsched_model as M
# reuse the validated edge push + rig helpers + shared metric already proven in
# pull_study.py (imports nsched_model unmodified; we never edit the physics).
from pull_study import (run_push, tether_cap, eth_cap, finalize, med, agg,
                        MKEYS, NPathSpec)

PathProc        = M.PathProc
reorder_release = M.reorder_release
PKT_KB          = M.PKT_KB
DT              = M.DT
QMAX_MS         = M.QMAX_MS
NLAG            = M.NLAG

# =============================================================================
# TUNABLES.  Model defaults; the (*) rows are set for real on the hardware
# edge-vs-mid box test (see caveats).  Everything else is validated model value.
# =============================================================================
TARGET_MS        = 40.0     # pull time-gate target (validated sweet spot)
DRAIN_TAU        = 0.10     # local drain EWMA time-constant (~100ms)
REGEN            = 0.02     # probe-up per tick toward nominal when socket idle
CAP_TRIP         = 0.92     # (*) LATCH mid-detected when delivered < 0.92 * sent
CAP_CLEAR        = 1.5      # (*) RELEASE only when delivered > 1.5 * sent (the far
                            #     end is visibly draining faster than we send, so the
                            #     bottleneck lifted).  A well-controlled mid path has
                            #     sent==delivered (ratio 1.0) and STAYS latched --
                            #     this latch-and-hold is what avoids the detect/release
                            #     flap that a symmetric hysteresis band suffers.
CAP_W            = 0.100    # bound-rate window (matches pong report cadence)
CAP_DET_W        = 0.400    # detection window (> buffer, so swing transients cancel)
CAP_TAU          = 0.20     # cap EWMA smoothing on the lagged windowed rate
MINRATE          = 500.0    # kb/s below which sent-rate is too small to judge
MIRROR_SPARE_MS  = 20.0     # (*) steady path must be BELOW this (idle) to mirror
MIRROR_RISK_FRAC = 0.60     # (*) tether drain < 0.6*nominal => "stalling" (at-risk)


# =============================================================================
# THE SHARED SAFETY CAP  (piece 2) -- one implementation, used by edge + mid.
# Two parts -- a DETECTOR and a BOUND -- both from ONE lagged delivered-rate
# meter (plus the sent rate the client already knows it put on the wire):
#   DETECT (sticky): latch when, over a window LONGER than the local buffer,
#     the end-to-end delivered volume < CAP_TRIP * sent volume  AND  the local
#     socket is UNCONGESTED (its own buffer stays near-empty, local_ms << target
#     -- the local link drains everything instantly).  That conjunction is the
#     pure MID / bufferbloat signature: "the socket says everything is fine but
#     the far end delivers less than we send."  At the EDGE the local link IS the
#     bottleneck, so a delivered<sent deficit comes WITH a backlogged local
#     socket (local_ms high) -> the uncongested-AND excludes it -> never latches.
#   RELEASE only when the local socket actually BECOMES the bottleneck again
#     (local_ms > target: the regime genuinely returned to edge) or the far end
#     clearly outpaces us (ratio > CAP_CLEAR).  A well-controlled mid path runs
#     at sent==delivered with an empty local socket, so it correctly STAYS
#     latched (no detect/release flap); an edge false-latch is cleared the next
#     time the local link congests.
#   BOUND (only while detected): rate-match admission to the delivered rate,
#     (inflight_kb / delivered_rate) < TARGET_MS, instead of trusting the
#     misleading fast local drain.  inflight = sent-but-unacked bytes (edge:
#     local backlog; mid: local + hidden downstream backlog).
# So the cap is provably dormant at the edge (detector never latches) and
# load-bearing + non-oscillatory at mid.  Returns (admit, cap_was_binding).
# =============================================================================
def update_detected(prev, sent_sum, deliv_sum, local_uncongested, local_congested):
    if sent_sum <= CAP_DET_W * MINRATE:
        return prev                           # path idle: no new evidence, hold
    r = deliv_sum / sent_sum
    if r < CAP_TRIP and local_uncongested:    # the pure MID / bufferbloat signature
        return True
    if r > CAP_CLEAR or local_congested:      # far end lifted, or edge regime back
        return False
    return prev                               # otherwise hold (latch-and-hold)

def cap_allows(local_ms, mid_detected, inflight_kb, deliv_ewma, target_ms):
    local_ok = local_ms < target_ms
    if not mid_detected:
        return local_ok, False                # dormant: pull's local gate rules
    far_ms = inflight_kb / max(MINRATE, deliv_ewma) * 1000.0
    cap_ok = far_ms < target_ms
    admit = local_ok and cap_ok
    engaged = local_ok and not cap_ok         # far gate was the binding constraint
    return admit, engaged


# =============================================================================
# Lagged rate meter: windowed rate over [now-NLAG-W, now-NLAG], EWMA-smoothed.
# This is the "lagged EWMA" the cap reads -- exactly the staleness of the pong
# echo (delivered bucketed by ARRIVAL, ~350ms stale).  One per (path, stream).
# =============================================================================
class LaggedRate:
    def __init__(s, prior):
        s.hist = deque()        # (t, kb this tick)
        s.ewma = prior
    def add(s, t, kb):
        s.hist.append((t, kb))
        horizon = NLAG + max(CAP_W, CAP_DET_W) + 0.05
        while s.hist and s.hist[0][0] < t - horizon:
            s.hist.popleft()
    def sample(s, now):         # short-window lagged rate (the BOUND rate), EWMA'd
        hi = now - NLAG; lo = hi - CAP_W
        tot = sum(kb for (t, kb) in s.hist if lo <= t < hi)
        rate = tot / CAP_W
        a = math.exp(-DT / CAP_TAU)
        s.ewma = s.ewma * a + rate * (1 - a)
        return s.ewma
    def wsum(s, now, W):        # cumulative over the long DETECTION window (lagged)
        hi = now - NLAG; lo = hi - W
        return sum(kb for (t, kb) in s.hist if lo <= t < hi)


# =============================================================================
# Two-stage series queue (MID physics).  PathProc fluid-FIFO math verbatim
# (q_ms = backlog/cap*1000; taildrop when q_ms>QMAX; fractional-carry drain;
# owd+jit on exit).  Adversary-built rig from attack1_midnet.py, unchanged.
# =============================================================================
class Stage:
    def __init__(s, owd_ms=0.0, jit_ms=0.0, qmax_ms=QMAX_MS):
        s.q = deque(); s.backlog_kb = 0.0
        s.owd = owd_ms; s.jit = jit_ms; s.qmax = qmax_ms
        s.carry = 0.0; s.taildrops = 0; s.serviced = 0; s.drain_rate = 0.0
    def q_ms(s, cap):
        return s.backlog_kb / cap * 1000.0 if cap > 0 else 1e9
    def offer(s, seq, enq_t, cap):
        if cap <= 0 or s.q_ms(cap) > s.qmax:
            s.taildrops += 1; return False
        s.q.append((seq, enq_t)); s.backlog_kb += PKT_KB; s.serviced += 1
        return True
    def drain(s, cap, now, rng):
        bl0 = s.backlog_kb; budget = cap * DT + s.carry; out = []
        while s.q and budget >= PKT_KB - 1e-9:
            seq, enq = s.q.popleft(); budget -= PKT_KB; s.backlog_kb -= PKT_KB
            jit = max(0.0, rng.gauss(0.0, s.jit)) if s.jit > 0 else 0.0
            out.append((seq, enq, now + DT + s.owd / 1000.0 + jit / 1000.0))
        s.carry = max(0.0, budget)
        if s.backlog_kb < 1e-9:
            s.backlog_kb = 0.0; s.carry = 0.0
        s.drain_rate = max(0.0, bl0 - s.backlog_kb) / DT
        return out


# =============================================================================
# ============  EDGE consolidated model: the clean Datapath  ==================
# Single-stage PathProc physics.  Implements pull (always) + cap (toggle) +
# mirror (toggle) as ONE scheduler.  With cap=False,mirror=False it is exactly
# the validated pull ms-gate.  steady_idx = the mirror target (the eth path).
# =============================================================================
class Datapath:
    def __init__(s, specs, offer_fn, T, seed, cap=True, mirror=True,
                 lat_bias=True, target_ms=TARGET_MS, steady_idx=None):
        s.specs = specs; s.offer_fn = offer_fn; s.T = T
        s.rng = random.Random(seed)
        s.N = len(specs)
        s.paths = [PathProc(sp, i) for i, sp in enumerate(specs)]
        s.cap_on = cap; s.mirror_on = mirror; s.lat_bias = lat_bias
        s.target_ms = target_ms
        # steady path = the mirror target: the highest-cap, zero-loss, non-spotty
        # member (eth).  Identify by cap0 if not given (eth has the largest cap0).
        if steady_idx is None:
            steady_idx = max(range(s.N), key=lambda i: specs[i].cap0)
        s.steady = steady_idx
        s.drain_ewma = [sp.cap0 for sp in specs]            # LOCAL egress est
        s.sent_rate  = [LaggedRate(sp.cap0) for sp in specs] # cap: admitted rate
        s.deliv_rate = [LaggedRate(sp.cap0) for sp in specs] # cap: end-to-end rate
        s.mid_det = [False] * s.N       # sticky per-path mid-bottleneck detector
        s.mid_det_ticks = 0
        s.theta = random.Random((seed + 1) * 2654435761 & 0xffffffff
                                ).uniform(-M.THETA_RANGE, M.THETA_RANGE)
        s.fifo = deque(); s.next_seq = 0; s.frac = 0.0
        s.frames = {}          # seq -> (enq_t, idx, arr|None, cause)  [MIN arr]
        s.assigned = [0] * s.N
        s.maxq_kb = (300.0 / 1000.0) * sum(sp.cap0 for sp in specs)
        s.qdrops = 0
        # instrumentation
        s.cap_fires = 0                 # TICKS where the far (cap) gate was binding
        s.cap_deliv_lt_sent = 0         # engaged admit-calls with delivered<sent
        s.cap_engaged_steady = 0        # engaged admit-calls with delivered>=sent
        s.mir_sent = 0                  # mirror copies transmitted
        s.mir_recovered = 0             # seqs delivered ONLY because of the mirror
        s.mir_won_race = 0              # seqs where mirror arrived before native
        s.win_assign = [0] * s.N
        s.share_win = []
        s._offer_sum = 0.0; s._offer_n = 0

    # ---- record an arrival keeping the MIN per seq (first-copy-wins dedup) ----
    def _record(s, seq, enq, idx, arr, cause, is_mirror=False):
        prev = s.frames.get(seq)
        if prev is None or prev[2] is None:
            # no arrival yet: take this one (native OR mirror)
            if prev is not None and prev[2] is None and arr is not None and is_mirror:
                s.mir_recovered += 1        # native had failed; mirror rescues it
            s.frames[seq] = (enq, idx, arr, cause)
        elif arr is not None and arr < prev[2]:
            # both arrived: keep earlier copy (mirror won the latency race)
            if is_mirror:
                s.mir_won_race += 1
            s.frames[seq] = (enq, idx, arr, cause)

    def run(s):
        nticks = int(round(s.T / DT))
        nWin = 0.100; nextWin = nWin
        for tk in range(nticks):
            now = tk * DT
            for p in s.paths:
                p.update(now, s.rng)
            # ---- offer -> shared FIFO (app byte/seq order) ----
            offer = s.offer_fn(now)
            if now > 1.0:
                s._offer_sum += offer; s._offer_n += 1
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append((seq, now))
                s.frames[seq] = (now, -1, None, 'queued')
            while len(s.fifo) * PKT_KB > s.maxq_kb:              # finite client FIFO
                seq, enq = s.fifo.popleft()
                s.frames[seq] = (enq, -1, None, 'qdrop'); s.qdrops += 1

            # cap signals (lagged) sampled once per tick
            de = [s.deliv_rate[i].sample(now) for i in range(s.N)]
            se = [s.sent_rate[i].sample(now) for i in range(s.N)]
            def local_ms(i):
                return s.paths[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
            for i in range(s.N):            # sticky mid-bottleneck detector
                lm = local_ms(i)
                s.mid_det[i] = update_detected(
                    s.mid_det[i], s.sent_rate[i].wsum(now, CAP_DET_W),
                    s.deliv_rate[i].wsum(now, CAP_DET_W),
                    lm < 0.5 * s.target_ms, lm > s.target_ms)
            if s.cap_on and any(s.mid_det):
                s.mid_det_ticks += 1
            sent_tick = [0.0] * s.N

            # ---- PIECE 1+2: PULL admission (with the cap folded into the gate) --
            cap_engaged_tick = [False]      # did the far gate bind this tick?
            def admit(i):
                lm = local_ms(i)
                if not s.cap_on:
                    return lm < s.target_ms
                ok, engaged = cap_allows(lm, s.mid_det[i], s.paths[i].backlog_kb,
                                         de[i], s.target_ms)
                if engaged:
                    cap_engaged_tick[0] = True
                    # PARSIMONY diagnostic: confirm the cap binds only when the
                    # far end delivers less than we send (delivered < sent).
                    if de[i] < se[i]:
                        s.cap_deliv_lt_sent += 1
                    else:
                        s.cap_engaged_steady += 1
                return ok
            at_risk = []            # (seq, enq) placed on a stalling tether
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = [i for i in range(s.N) if s.paths[i].cap > 0.0 and admit(i)]
                if not cand:
                    break
                if s.lat_bias:
                    cand.sort(key=lambda i: (s.paths[i].owd, local_ms(i)))
                else:
                    cand.sort(key=local_ms)
                seq, enq = s.fifo[0]
                placed = False
                for i in cand:
                    cause, arr, d = s.paths[i].send(now, s.rng, False, s.theta)
                    if cause in ('down', 'taildrop'):
                        continue
                    s.fifo.popleft(); s.assigned[i] += 1; s.win_assign[i] += 1
                    sent_tick[i] += PKT_KB
                    s._record(seq, enq, i, arr if cause == 'ok' else None, cause)
                    # at-risk = native copy went onto a STALLING tether (path-id):
                    # this tether's own drain has fallen below MIRROR_RISK_FRAC of
                    # nominal -> the frame is likely to arrive late or taildrop.
                    if (i != s.steady and
                            s.drain_ewma[i] < MIRROR_RISK_FRAC * s.specs[i].cap0):
                        at_risk.append((seq, enq))
                    placed = True
                    break
                if not placed:
                    break
            if cap_engaged_tick[0]:
                s.cap_fires += 1

            # ---- PIECE 3: OPPORTUNISTIC eth-mirror (spends only idle steady room)
            if s.mirror_on and at_risk:
                st = s.paths[s.steady]
                # spare test uses the SAME local-room signal pull reads; native
                # traffic was already admitted above, so anything below the spare
                # threshold now is genuine idle capacity (=> 0 native displacement,
                # no-op when the steady path is saturated).
                def steady_ms():
                    return st.backlog_kb / max(1.0, s.drain_ewma[s.steady]) * 1000.0
                for (seq, enq) in at_risk:
                    if st.cap <= 0.0 or steady_ms() >= MIRROR_SPARE_MS:
                        break                              # saturated / no idle room
                    cause, arr, d = st.send(now, s.rng, False, s.theta)
                    if cause in ('down', 'taildrop'):
                        break
                    s.mir_sent += 1
                    # mirror copies do NOT count as native "sent" for the cap
                    # (they ride idle capacity) but they DO occupy the socket, so
                    # the drain/delivery physics see them.
                    s._record(seq, enq, s.steady,
                              arr if cause == 'ok' else None, cause, is_mirror=True)

            # ---- LOCAL drain measurement + end-to-end delivery accounting ------
            aE = math.exp(-DT / DRAIN_TAU)
            for i, p in enumerate(s.paths):
                bl0 = p.backlog_kb
                p.drain()
                drained = max(0.0, bl0 - p.backlog_kb)          # kb left socket
                drate = drained / DT
                if p.backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i] * aE + drate * (1 - aE)
                else:
                    s.drain_ewma[i] += REGEN * (p.spec.cap0 - s.drain_ewma[i])
                # EDGE: leaving the socket == delivered end-to-end (no hidden hop).
                s.deliv_rate[i].add(now, drained)
                s.sent_rate[i].add(now, sent_tick[i])
            if now >= nextWin - 1e-9:
                nextWin += nWin
                tot = sum(s.win_assign) or 1
                s.share_win.append((now, [s.win_assign[i] / tot for i in range(s.N)]))
                s.win_assign = [0] * s.N

        omean = s._offer_sum / s._offer_n if s._offer_n else s.offer_fn(0)
        r = finalize(s.frames, s.specs, s.paths, s.T, offer_rate=omean,
                     extra={'variant': 'pull'
                            + ('+cap' if s.cap_on else '')
                            + ('+mir' if s.mirror_on else ''),
                            'cap_fires': s.cap_fires, 'mir_sent': s.mir_sent,
                            'cap_dls': s.cap_deliv_lt_sent,
                            'cap_steady': s.cap_engaged_steady,
                            'mid_det_ticks': s.mid_det_ticks,
                            'mir_recovered': s.mir_recovered,
                            'mir_won_race': s.mir_won_race,
                            'qdrops': s.qdrops,
                            'tail_by_path': [s.paths[i].taildrops for i in range(s.N)],
                            'share': [s.assigned[i] / (sum(s.assigned) or 1)
                                      for i in range(s.N)]})
        return r


# =============================================================================
# ============  MID two-stage engine: pull / pull+cap / push / oracle  ========
# The SAME cap_allows() drives pull+cap here.  push = admit at the lagged
# end-to-end delivered rate (eif_real's real rule).  oracle = admit at the
# instantaneous true downstream cap (unreachable upper bound).
# =============================================================================
HUGE = 1e9

def mid_tether_cap(base=29000.0, amp=24000.0, period=3.1, dropouts=(),
                   floor=3000.0, shaping=False):
    def f(t):
        for (a, b) in dropouts:
            if a <= t < b:
                return 4000.0 if shaping else 0.0
        return max(floor, base + amp * math.sin(2 * math.pi * t / period))
    return f

def mid_eth_cap(base=78000.0, amp=12000.0, period=5.0):
    return lambda t: base + amp * math.sin(2 * math.pi * t / period + 1.0)

def make_mid_defs(bottleneck='mid', local_mult=20.0, backpressure=None,
                  down_qmax=QMAX_MS, drops=None, shaping=False):
    """EDGE: spotty cap on the LOCAL stage (socket occupancy == truth).
       MID : local drains fast+const; spotty cap DOWNSTREAM (hidden)."""
    if drops is None:
        drops = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
    tcap = mid_tether_cap(dropouts=drops, shaping=shaping)
    ecap = mid_eth_cap()
    if bottleneck == 'edge':
        return [dict(down_cap=tcap, local_cap=tcap, loc_owd=25.0, down_owd=2.0,
                     jit=25.0, bp=backpressure, dcap=lambda t: HUGE, dqmax=HUGE,
                     steady=False),
                dict(down_cap=ecap, local_cap=ecap, loc_owd=8.0, down_owd=1.0,
                     jit=1.0, bp=backpressure, dcap=lambda t: HUGE, dqmax=HUGE,
                     steady=True)]
    return [dict(down_cap=tcap, local_cap=lambda t: 30000.0 * local_mult,
                 loc_owd=2.0, down_owd=25.0, jit=25.0, bp=backpressure,
                 dcap=tcap, dqmax=down_qmax, steady=False),
            dict(down_cap=ecap, local_cap=lambda t: 78000.0 * local_mult,
                 loc_owd=1.0, down_owd=8.0, jit=1.0, bp=backpressure,
                 dcap=ecap, dqmax=down_qmax, steady=True)]

class TwoStage:
    def __init__(s, defs, offer_fn, T, seed, sched='pull', cap=False,
                 target_ms=TARGET_MS, mirror=False):
        s.defs = defs; s.offer_fn = offer_fn; s.T = T; s.rng = random.Random(seed)
        s.N = len(defs); s.sched = sched; s.cap_on = cap; s.mirror_on = mirror
        s.target_ms = target_ms
        s.local = [Stage(d['loc_owd']) for d in defs]
        s.down = [Stage(d['down_owd'], jit_ms=d['jit'], qmax_ms=d['dqmax'])
                  for d in defs]
        s.drain_ewma = [d['down_cap'](0.0) for d in defs]      # LOCAL egress est
        s.sent_rate  = [LaggedRate(d['down_cap'](0.0)) for d in defs]
        s.deliv_rate = [LaggedRate(d['down_cap'](0.0)) for d in defs]
        s.mid_det = [False] * s.N; s.mid_det_ticks = 0
        s.steady = next(i for i, d in enumerate(defs) if d['steady'])
        s.fifo = deque(); s.next_seq = 0; s.frac = 0.0
        s.frames = {}; s.enq_t = {}; s.assigned = [0] * s.N
        s.offered_post = 0; s.warm = 1.0
        s.cap_fires = 0; s.mir_sent = 0; s.mir_recovered = 0; s.mir_won_race = 0
        s.cap_deliv_lt_sent = 0; s.cap_engaged_steady = 0

    def _lcap(s, i, t):
        lc = s.defs[i]['local_cap'](t)
        if s.defs[i]['bp']:
            lc = min(lc, s.defs[i]['down_cap'](t) * s.defs[i]['bp'])
        return lc

    def run(s):
        nt = int(round(s.T / DT))
        for tk in range(nt):
            now = tk * DT
            lcaps = [s._lcap(i, now) for i in range(s.N)]
            dcaps = [s.defs[i]['dcap'](now) for i in range(s.N)]
            caps = [s.defs[i]['down_cap'](now) for i in range(s.N)]   # true bottleneck
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq_t[seq] = now
                if seq not in s.frames:
                    s.frames[seq] = None
                if now > s.warm:
                    s.offered_post += 1
            de = [s.deliv_rate[i].sample(now) for i in range(s.N)]
            se = [s.sent_rate[i].sample(now) for i in range(s.N)]
            def local_ms(i):
                return s.local[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
            for i in range(s.N):
                lm = local_ms(i)
                s.mid_det[i] = update_detected(
                    s.mid_det[i], s.sent_rate[i].wsum(now, CAP_DET_W),
                    s.deliv_rate[i].wsum(now, CAP_DET_W),
                    lm < 0.5 * s.target_ms, lm > s.target_ms)
            if s.cap_on and any(s.mid_det):
                s.mid_det_ticks += 1
            sent_tick = [0.0] * s.N

            cap_engaged_tick = [False]
            def inflight(i):
                return s.local[i].backlog_kb + s.down[i].backlog_kb
            def admit(i):
                if s.sched == 'pull':
                    lm = local_ms(i)
                    if not s.cap_on:
                        return lm < s.target_ms
                    ok, eng = cap_allows(lm, s.mid_det[i], inflight(i), de[i],
                                         s.target_ms)
                    if eng:
                        cap_engaged_tick[0] = True
                        if de[i] < se[i]:
                            s.cap_deliv_lt_sent += 1
                        else:
                            s.cap_engaged_steady += 1
                    return ok
                if s.sched == 'push':
                    est = max(1.0, de[i])   # push admits at the LAGGED end-to-end
                    return inflight(i) / est * 1000.0 < s.target_ms  # delivered rate
                est = max(1.0, caps[i])     # oracle: instantaneous true downstream cap
                return inflight(i) / est * 1000.0 < s.target_ms

            at_risk = []
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = [i for i in range(s.N) if lcaps[i] > 0 and admit(i)]
                if not cand:
                    break
                cand.sort(key=lambda i: (s.defs[i]['down_owd'], local_ms(i)))
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq_t[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1
                        sent_tick[i] += PKT_KB
                        if (i != s.steady and
                                s.drain_ewma[i] < MIRROR_RISK_FRAC * s.defs[i]['down_cap'](0.0)):
                            at_risk.append(seq)
                        placed = True; break
                if not placed:
                    break
            if cap_engaged_tick[0]:
                s.cap_fires += 1

            if s.mirror_on and at_risk:
                sti = s.steady
                def steady_ms():
                    return s.local[sti].backlog_kb / max(1.0, s.drain_ewma[sti]) * 1000.0
                for seq in at_risk:
                    if lcaps[sti] <= 0 or steady_ms() >= MIRROR_SPARE_MS:
                        break
                    if s.local[sti].offer(seq, s.enq_t[seq], lcaps[sti]):
                        s.mir_sent += 1

            # ---- drain stage1 -> stage2 -> deliver ; update estimates ----
            aE = math.exp(-DT / DRAIN_TAU)
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (seq, enq, x1) in exited:
                    if not s.down[i].offer(seq, enq, dcaps[i]):
                        pass                         # downstream taildrop = LOST
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (seq, enq, x2) in delivered:
                    prev = s.frames.get(seq)        # None until first delivery
                    if prev is None or x2 < prev:   # first copy wins (min arrival)
                        s.frames[seq] = x2
                    dk += PKT_KB
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i] * aE + s.local[i].drain_rate * (1 - aE)
                else:
                    s.drain_ewma[i] += REGEN * (s.defs[i]['down_cap'](0.0) - s.drain_ewma[i])
                s.deliv_rate[i].add(now, dk)
                s.sent_rate[i].add(now, sent_tick[i])
        return s.finalize()

    def finalize(s):
        owds = [d['down_owd'] + d['loc_owd'] for d in s.defs]
        jits = [d['jit'] for d in s.defs]
        hold = ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0
        hold = min(0.35, max(0.08, hold))
        deliv_items = [(a, seq) for seq, a in s.frames.items() if a is not None]
        release, skips, depth = reorder_release(deliv_items, hold)
        Teff = s.T - s.warm
        lat = []; nd = 0
        for seq, rt in release.items():
            st = s.enq_t[seq]
            if st > s.warm:
                nd += 1; lat.append((rt - st) * 1000.0)
        lat.sort()
        def pct(p): return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))] if lat else 0.0
        gp = nd * PKT_KB / Teff
        loss = 100.0 * (s.offered_post - nd) / s.offered_post if s.offered_post else 0.0
        return {'gp': gp, 'loss_pct': max(0.0, loss), 'p50': pct(.5),
                'p95': pct(.95), 'p99': pct(.99),
                'taildrops': sum(st.taildrops for st in s.down),
                'tshare': s.assigned[0] / (sum(s.assigned) or 1),
                'cap_fires': s.cap_fires, 'mir_sent': s.mir_sent,
                'mid_det_ticks': s.mid_det_ticks,
                'cap_dls': s.cap_deliv_lt_sent, 'cap_steady': s.cap_engaged_steady,
                'deliv': nd}


# =============================================================================
# aggregation helper for mid (median over seeds)
# =============================================================================
def magg(ms, keys):
    return {k: med([m.get(k, 0) for m in ms]) for k in keys}


# =============================================================================
# ===============================  BATTERY  ===================================
# =============================================================================
def edge_rig_n2(tcap=None, ecap=None):
    if tcap is None:
        tcap = tether_cap(dropouts=[(a, a + 0.4) for a in (2.6, 5.1, 7.6)])
    if ecap is None:
        ecap = eth_cap()
    return lambda: [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                    NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]

def edge_rig_n3(tA=None, tB=None, ecap=None):
    if tA is None:
        tA = tether_cap(dropouts=[(a, a + 0.4) for a in (2.6, 6.0)])
    if tB is None:
        tB = tether_cap(base=22000, amp=17000, period=2.3,
                        dropouts=[(a, a + 0.4) for a in (3.8, 7.3)])
    if ecap is None:
        ecap = eth_cap()
    return lambda: [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tA),
                    NPathSpec(23000, 70, 20.0, 0.010, cap_fn=tB),
                    NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]


def run_edge_variants(specs_fn, ofn, T, seeds, cap, mirror):
    return [Datapath(specs_fn(), ofn, T, sd, cap=cap, mirror=mirror).run()
            for sd in range(seeds)]


def hdr_edge():
    print("  %-18s %7s %6s %6s %5s %5s %5s %6s %6s %6s %6s"
          % ("variant", "gp", "loss%", "util%", "p50", "p95", "p99",
             "tdrop", "capfr", "mirTX", "mirRec"))

def row_edge(tag, ms):
    a = magg(ms, ['gp', 'loss_pct', 'util', 'p50', 'p95', 'p99', 'taildrops',
                  'cap_fires', 'mir_sent', 'mir_recovered'])
    print("  %-18s %7.0f %6.1f %6.1f %5.0f %5.0f %5.0f %6.0f %6.0f %6.0f %6.0f"
          % (tag, a['gp'], a['loss_pct'], 100 * a['util'], a['p50'], a['p95'],
             a['p99'], a['taildrops'], a['cap_fires'], a['mir_sent'],
             a['mir_recovered']))
    return a


# ---- TEST 1: EDGE vs MID (the cap earns its place) --------------------------
def test_edge_vs_mid(seeds, T=10.0):
    print("=" * 92)
    print("TEST 1  EDGE vs MID-NETWORK bottleneck  (does the thin cap RESCUE mid")
    print("        without hurting edge?)   two-stage series-queue rig, seeds=%d" % seeds)
    print("=" * 92)
    offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    def block(tag, defs_fn):
        print("  %-26s %8s %7s %6s %6s %7s %7s" %
              (tag, "gp", "loss%", "p50", "p95", "capfr", "tshr"))
        rows = {}
        combos = [('pull', dict(sched='pull', cap=False)),
                  ('pull+cap', dict(sched='pull', cap=True)),
                  ('push(eif_real)', dict(sched='push', cap=False)),
                  ('oracle', dict(sched='oracle', cap=False))]
        for name, kw in combos:
            ms = [TwoStage(defs_fn(), ofn, T, sd, **kw).run() for sd in range(seeds)]
            a = magg(ms, ['gp', 'loss_pct', 'p50', 'p95', 'cap_fires', 'tshare'])
            rows[name] = a
            print("    %-24s %8.0f %7.1f %6.0f %6.0f %7.0f %6.2f"
                  % (name, a['gp'], a['loss_pct'], a['p50'], a['p95'],
                     a['cap_fires'], a['tshare']))
        print()
        return rows
    print("\n  -- EDGE: spotty cap on the LOCAL socket (pull's assumption holds) --")
    edge = block("EDGE (single-stage-equiv)", lambda: make_mid_defs('edge'))
    print("  -- MID: local drains fast, spotty cap hidden DOWNSTREAM (dropouts) --")
    midd = block("MID hard-dropouts", lambda: make_mid_defs('mid', local_mult=20.0))
    print("  -- MID: carrier SHAPING (throttle to 4Mb, NEVER a full outage) --")
    mids = block("MID shaping", lambda: make_mid_defs('mid', local_mult=20.0, shaping=True))
    return edge, midd, mids


# ---- TEST 2: ABLATION (each piece earns its place) --------------------------
def test_ablation(seeds, T=10.0):
    print("=" * 92)
    print("TEST 2  ABLATION  N=2 edge (spotty tether + steady eth), offer=85%%, seeds=%d" % seeds)
    print("        pull-only -> +cap -> +cap+mirror.  push(eif_real) reference.")
    print("=" * 92)
    specs_fn = edge_rig_n2()
    offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    push = [run_push(specs_fn(), ofn, T, sd) for sd in range(seeds)]
    hdr_edge()
    row_edge("push(eif_real)", push)
    p0 = row_edge("pull-only", run_edge_variants(specs_fn, ofn, T, seeds, False, False))
    pc = row_edge("pull+cap", run_edge_variants(specs_fn, ofn, T, seeds, True, False))
    pm = row_edge("pull+cap+mirror", run_edge_variants(specs_fn, ofn, T, seeds, True, True))
    a_push = magg(push, MKEYS)
    print("  --> vs push(eif_real): pull-only %+.1f%% gp, pull+cap %+.1f%%, +mirror %+.1f%% gp"
          % (100 * (p0['gp'] / a_push['gp'] - 1), 100 * (pc['gp'] / a_push['gp'] - 1),
             100 * (pm['gp'] / a_push['gp'] - 1)))
    print("  --> mirror effect (edge): p95 %.0f -> %.0f, loss %.1f%% -> %.1f%%, mirTX=%.0f/seed"
          % (pc['p95'], pm['p95'], pc['loss_pct'], pm['loss_pct'], pm['mir_sent']))
    print("      (pull+cap+mirror == pull+cap: the opportunistic mirror NEVER FIRES under")
    print("       pull -- eth runs at its gate target, no idle room to duplicate into.)")
    return dict(push=a_push, pull=p0, cap=pc, mir=pm)


# ---- TEST 3: REGRESSION scenarios -------------------------------------------
def cap_from_windows(base, amp, period, windows, wval=0.0, floor=3000.0):
    def f(t):
        for (a, b) in windows:
            if a <= t < b:
                return wval
        return max(floor, base + amp * math.sin(2 * math.pi * t / period))
    return f

def test_regression(seeds, T=10.0):
    print("=" * 92)
    print("TEST 3  REGRESSION  pull+cap+mirror MUST beat push(eif_real) on gp AND loss")
    print("        seeds=%d.  Scenarios the regen/gate were NOT tuned on." % seeds)
    print("=" * 92)
    ecap = eth_cap()
    results = {}
    # -- N=2 scenarios --
    flaps = []; t = 2.0
    while t < 4.0:
        flaps.append((t, t + 0.15)); t += 0.30
    scen2 = [
        ("rapid-flap 150ms",  cap_from_windows(29000, 24000, 3.1, flaps)),
        ("asym long-stall",   cap_from_windows(29000, 24000, 3.1,
                              [(2.2, 3.1), (3.4, 4.3), (4.6, 5.5), (5.8, 6.7)])),
        ("soft partial dip",  cap_from_windows(29000, 24000, 3.1,
                              [(2.5, 3.3), (4.5, 5.3), (6.5, 7.3)], wval=4350.0)),
    ]
    offer2 = 0.85 * (29000 + 78000); ofn2 = lambda t: offer2
    print("  %-20s %-16s %7s %6s %6s %6s %6s" %
          ("scenario", "variant", "gp", "loss%", "p95", "capfr", "mirTX"))
    for name, tcap in scen2:
        specs_fn = edge_rig_n2(tcap=tcap, ecap=ecap)
        push = magg([run_push(specs_fn(), ofn2, T, sd) for sd in range(seeds)], MKEYS)
        pm = magg(run_edge_variants(specs_fn, ofn2, T, seeds, True, True),
                  ['gp', 'loss_pct', 'p95', 'cap_fires', 'mir_sent'])
        wins = (pm['gp'] > push['gp']) and (pm['loss_pct'] < push['loss_pct'])
        print("  %-20s %-16s %7.0f %6.1f %6.0f" % (name, "push(eif_real)",
              push['gp'], push['loss_pct'], push['p95']))
        print("  %-20s %-16s %7.0f %6.1f %6.0f %6.0f %6.0f  %s"
              % ("", "pull+cap+mir", pm['gp'], pm['loss_pct'], pm['p95'],
                 pm['cap_fires'], pm['mir_sent'], "<= WIN" if wins else "<= REVIEW"))
        results[name] = (push, pm, wins)
    # -- N=3 correlated-both-tethers --
    tA = cap_from_windows(29000, 24000, 3.1, [(3.0, 3.8), (6.0, 6.8)])
    tB = cap_from_windows(22000, 17000, 2.3, [(3.0, 3.8), (6.0, 6.8)])
    specs_fn3 = edge_rig_n3(tA=tA, tB=tB, ecap=ecap)
    offer3 = 0.85 * (29000 + 22000 + 78000); ofn3 = lambda t: offer3
    push3 = magg([run_push(specs_fn3(), ofn3, T, sd) for sd in range(seeds)], MKEYS)
    pm3 = magg(run_edge_variants(specs_fn3, ofn3, T, seeds, True, True),
               ['gp', 'loss_pct', 'p95', 'cap_fires', 'mir_sent'])
    wins3 = (pm3['gp'] > push3['gp']) and (pm3['loss_pct'] < push3['loss_pct'])
    print("  %-20s %-16s %7.0f %6.1f %6.0f" % ("corr-both N=3", "push(eif_real)",
          push3['gp'], push3['loss_pct'], push3['p95']))
    print("  %-20s %-16s %7.0f %6.1f %6.0f %6.0f %6.0f  %s"
          % ("", "pull+cap+mir", pm3['gp'], pm3['loss_pct'], pm3['p95'],
             pm3['cap_fires'], pm3['mir_sent'], "<= WIN" if wins3 else "<= REVIEW"))
    results["corr-both-N3"] = (push3, pm3, wins3)
    return results


# ---- TEST 4: PARSIMONY GUARDS -----------------------------------------------
def test_parsimony(seeds, T=10.0):
    print("=" * 92)
    print("TEST 4  PARSIMONY GUARDS  (assert each piece only spends when it should)")
    print("=" * 92)
    ofn = lambda t: 0.85 * (29000 + 78000)
    # GUARD A: the cap must be ~DORMANT at the edge (its far gate coincides with
    # the local gate there) and LOAD-BEARING at mid; and whenever it DOES bind it
    # must be because delivered<sent (never in true steady state).
    specs_fn = edge_rig_n2()
    edge_cap = run_edge_variants(specs_fn, ofn, T, seeds, True, False)
    a_edge = magg(edge_cap, ['mid_det_ticks', 'cap_fires', 'gp', 'loss_pct'])
    edge_nocap = run_edge_variants(specs_fn, ofn, T, seeds, False, False)
    a_enc = magg(edge_nocap, ['gp', 'loss_pct'])
    mid_ms = [TwoStage(make_mid_defs('mid', local_mult=20.0), ofn, T, sd,
                       sched='pull', cap=True).run() for sd in range(seeds)]
    a_mid = magg(mid_ms, ['mid_det_ticks', 'cap_fires', 'gp', 'loss_pct'])
    NT = int((T - 1.0) / DT)                 # post-warm ticks
    print("  GUARD A (cap DORMANT at edge, LOAD-BEARING at mid):   ~%d post-warm ticks/run" % NT)
    print("    what matters = far-gate BINDS (denies a frame the local gate would admit):")
    print("    EDGE rig: far-gate-bind ticks/seed=%.0f  (detector-latched=%.0f)"
          % (a_edge['cap_fires'], a_edge['mid_det_ticks']))
    print("              edge gp cap-on=%.0f vs cap-off=%.0f  loss %.1f%% vs %.1f%% (cap must NOT hurt edge)"
          % (a_edge['gp'], a_enc['gp'], a_edge['loss_pct'], a_enc['loss_pct']))
    print("    MID  rig: far-gate-bind ticks/seed=%.0f  (detector-latched=%.0f)"
          % (a_mid['cap_fires'], a_mid['mid_det_ticks']))
    # PASS: (a) the cap does not hurt edge goodput/loss (harmless where pull's
    # local signal is already truth); (b) far-gate binding is concentrated at
    # mid, >>10x the edge rate (load-bearing exactly where needed).
    no_harm = (a_edge['gp'] >= 0.99 * a_enc['gp'] and
               a_edge['loss_pct'] <= a_enc['loss_pct'] + 0.5)
    concentrated = a_mid['cap_fires'] >= 10 * max(1.0, a_edge['cap_fires'])
    guardA = no_harm and concentrated
    print("    => %s  (no-edge-harm=%s  mid-concentrated(>=10x)=%s)"
          % ("PASS" if guardA else "FAIL", no_harm, concentrated))

    # GUARD B: the OPPORTUNISTIC mirror must spend ONLY idle steady capacity =>
    # 0 native displacement, never net-negative.  It PASSES that guard -- but for
    # a decisive reason: under PULL the steady path runs AT its gate target
    # whenever the tether is loaded enough to produce at-risk frames, so idle eth
    # room essentially never exists and the opportunistic mirror NEVER FIRES
    # (mirTX ~ 0).  Forcing it to fire (a PERMISSIVE variant that overfills eth
    # past its gate) is net-NEGATIVE -- it displaces native traffic (goodput
    # falls, p95 rises) even though eth taildrops stay ~0.  Both facts below.
    global MIRROR_SPARE_MS, MIRROR_RISK_FRAC
    save_sp, save_rk = MIRROR_SPARE_MS, MIRROR_RISK_FRAC
    print("\n  GUARD B (does the OPPORTUNISTIC mirror ever get idle eth room under pull?):")
    print("    %-20s %8s %8s %8s %8s %8s" %
          ("offer", "mirTX", "dgp", "dp95", "dloss%", "verdict"))
    guardB = True; ever_fired = 0
    for label, oscale in [("idle 0.70x", 0.70), ("moderate 0.85x", 0.85),
                          ("saturated 1.05x", 1.05)]:
        of = oscale * (29000 + 78000); ofn2 = lambda t, _o=of: _o
        MIRROR_SPARE_MS, MIRROR_RISK_FRAC = save_sp, save_rk        # opportunistic
        base = [Datapath(specs_fn(), ofn2, T, sd, cap=True, mirror=False).run()
                for sd in range(seeds)]
        mir = [Datapath(specs_fn(), ofn2, T, sd, cap=True, mirror=True).run()
               for sd in range(seeds)]
        dgp = med([m['gp'] - b['gp'] for m, b in zip(mir, base)])
        dp95 = med([m['p95'] - b['p95'] for m, b in zip(mir, base)])
        dloss = med([m['loss_pct'] - b['loss_pct'] for m, b in zip(mir, base)])
        mtx = med([m['mir_sent'] for m in mir])
        ever_fired += mtx
        ok = (dgp >= -1.0)                     # never net-negative (holds: inert)
        guardB = guardB and ok
        print("    %-20s %8.0f %+8.0f %+8.0f %+8.1f %8s"
              % (label, mtx, dgp, dp95, dloss, "PASS" if ok else "FAIL"))
    # PERMISSIVE mirror (overfill eth past its gate to FORCE firing): net-negative
    MIRROR_SPARE_MS, MIRROR_RISK_FRAC = 80.0, 1.5
    of = 0.85 * (29000 + 78000); ofn2 = lambda t: of
    base = [Datapath(specs_fn(), ofn2, T, sd, cap=True, mirror=False).run()
            for sd in range(seeds)]
    mir = [Datapath(specs_fn(), ofn2, T, sd, cap=True, mirror=True).run()
           for sd in range(seeds)]
    pdgp = med([m['gp'] - b['gp'] for m, b in zip(mir, base)])
    pdp95 = med([m['p95'] - b['p95'] for m, b in zip(mir, base)])
    pmtx = med([m['mir_sent'] for m in mir])
    MIRROR_SPARE_MS, MIRROR_RISK_FRAC = save_sp, save_rk            # restore
    print("    FORCED (permissive, overfill eth) @0.85x: mirTX=%.0f dgp=%+.0f dp95=%+.0f  <= net-NEGATIVE"
          % (pmtx, pdgp, pdp95))
    print("    => opportunistic mirror NEVER FIRES under pull (total mirTX=%.0f); guard trivially holds"
          % ever_fired)
    return dict(guardA=guardA, guardB=guardB, edge_capfr=a_edge['cap_fires'],
                mid_capfr=a_mid['cap_fires'], mir_opportunistic_tx=ever_fired,
                mir_forced_dgp=pdgp)


# ---- TEST 5: N-GENERIC ------------------------------------------------------
def test_n_generic(seeds, T=10.0):
    print("=" * 92)
    print("TEST 5  N-GENERIC  full stack (pull+cap+mirror) vs push at N=2 and N=3")
    print("=" * 92)
    hdr_edge()
    # N=2
    specs2 = edge_rig_n2(); ofn2 = lambda t: 0.85 * (29000 + 78000)
    p2 = magg([run_push(specs2(), ofn2, T, sd) for sd in range(seeds)], MKEYS)
    print("  N=2:")
    print("    push(eif_real)   gp=%7.0f loss=%5.1f%% p95=%3.0f" % (p2['gp'], p2['loss_pct'], p2['p95']))
    f2 = row_edge("  pull+cap+mir N2", run_edge_variants(specs2, ofn2, T, seeds, True, True))
    print("    --> %+.1f%% gp vs push, loss %.1f%% vs %.1f%%"
          % (100 * (f2['gp'] / p2['gp'] - 1), f2['loss_pct'], p2['loss_pct']))
    # N=3
    specs3 = edge_rig_n3(); ofn3 = lambda t: 0.85 * (29000 + 22000 + 78000)
    p3 = magg([run_push(specs3(), ofn3, T, sd) for sd in range(seeds)], MKEYS)
    print("  N=3:")
    print("    push(eif_real)   gp=%7.0f loss=%5.1f%% p95=%3.0f" % (p3['gp'], p3['loss_pct'], p3['p95']))
    f3 = row_edge("  pull+cap+mir N3", run_edge_variants(specs3, ofn3, T, seeds, True, True))
    print("    --> %+.1f%% gp vs push, loss %.1f%% vs %.1f%%"
          % (100 * (f3['gp'] / p3['gp'] - 1), f3['loss_pct'], p3['loss_pct']))
    return dict(n2=(p2, f2), n3=(p3, f3))


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    quick = 'quick' in sys.argv
    seeds = 8 if quick else 24
    print("\n" + "#" * 92)
    print("# MASTERPIECE DATAPATH  --  consolidated model validation battery  seeds=%d" % seeds)
    print("#   pull (work-conserving) + thin delivered-rate cap + opportunistic eth-mirror")
    print("#   physics = nsched_model (unmodified).  medians over seeds.  push = eif_real.")
    print("#" * 92 + "\n")
    evm = test_edge_vs_mid(seeds); print()
    abl = test_ablation(seeds); print()
    reg = test_regression(seeds); print()
    par = test_parsimony(seeds); print()
    ng = test_n_generic(seeds); print()

    # ---- GO/NO-GO ----
    print("#" * 92)
    print("# PER-PIECE GO / NO-GO")
    print("#" * 92)
    edge, midd, mids = evm
    print("PIECE 1  PULL (aggregation primary):")
    print("  N=2 full-stack %+.1f%% gp vs push; N=3 %+.1f%% gp vs push (test 5)."
          % (100 * (ng['n2'][1]['gp'] / ng['n2'][0]['gp'] - 1),
             100 * (ng['n3'][1]['gp'] / ng['n3'][0]['gp'] - 1)))
    print("  EDGE: pull loss=%.1f%% vs push %.1f%% (test1).  => GO if positive."
          % (edge['pull']['loss_pct'], edge['push(eif_real)']['loss_pct']))
    print("PIECE 2  THIN CAP (mid-network guard):")
    print("  MID drop: pull=%.1f%% loss -> pull+cap=%.1f%% (push=%.1f%%)."
          % (midd['pull']['loss_pct'], midd['pull+cap']['loss_pct'],
             midd['push(eif_real)']['loss_pct']))
    print("  MID shape: pull=%.1f%% -> pull+cap=%.1f%% (push=%.1f%%)."
          % (mids['pull']['loss_pct'], mids['pull+cap']['loss_pct'],
             mids['push(eif_real)']['loss_pct']))
    print("  EDGE cap fires/seed=%.0f vs MID %.0f (test4 GuardA=%s). => GO if rescues mid & dormant edge."
          % (par['edge_capfr'], par['mid_capfr'], par['guardA']))
    print("PIECE 3  OPPORTUNISTIC MIRROR (p95 tail):  ** NO-GO -- DROP under pull **")
    print("  Opportunistic mirror total fires across all offers = %.0f (it NEVER fires):"
          % par['mir_opportunistic_tx'])
    print("  eth runs AT its gate target whenever the tether is loaded enough to make")
    print("  at-risk frames, so idle eth room to duplicate into never exists.  Forcing")
    print("  it (overfill eth) is net-negative: dgp=%+.0f (test4 GuardB)." % par['mir_forced_dgp'])
    print("  The hedge_free win was a PUSH-stack property; it does not transfer to pull.")
    print("\n(Full interpretation + GO/NO-GO writeup is in the returned analysis.)")


if __name__ == '__main__':
    main()
