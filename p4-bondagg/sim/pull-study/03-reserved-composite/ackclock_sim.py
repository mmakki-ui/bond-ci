#!/usr/bin/env python3
# =============================================================================
# ackclock_sim.py -- ACK-CLOCKED POOLED-WATER PULL (Van Jacobson self-clocking)
#   vs the current hybrid (pull + statistical delivered-rate EWMA cap) + PUSH + ORACLE.
#
# PHYSICS (reused verbatim, never edited):
#   * nsched_model constants PKT_KB/DT/QMAX_MS/NLAG and reorder_release (the
#     VALIDATED receiver ring).  imported UNMODIFIED.
#   * Two fluid FIFO queues in SERIES per path -- the exact PathProc math copied
#     from scratchpad/sim/attack1_midnet.py (Stage). Stage-1 = observed local
#     socket (drains fast in MID); Stage-2 = hidden downstream shaper (the true
#     spotty cap in MID). EDGE = spotty cap on stage-1, stage-2 passthrough.
#
# SCHEDULERS on the SAME two-stage ground truth + SAME deterministic cap trace +
# SAME seeds (paired physics). All share ONE pooled send-FIFO (work-conserving):
#   pull    : draw while LOCAL ms-gate open (blind to stage-2) -- the 13% collapse.
#   ewma  A : pull local ms-gate AND a lagged delivered-rate EWMA cap on inflight
#             (the current statistical hybrid) + opportunistic mirror.
#   ack   B : pull local ms-gate AND a bounded in-flight (unacked) WINDOW; acks
#             modeled explicitly (server acks per path/seq, ack traverses the
#             reverse-path delay). NO statistical cap. + opportunistic mirror.
#   push    : admit at the LAGGED end-to-end delivered rate (eif_real pong-echo).
#   oracle  : admit at the instantaneous true stage-2 cap (unreachable upper bound).
# =============================================================================
# CANONICAL FOR: the reserved/composite study line, the ADR-004 gated datapath
#   oracle (`.github/scripts/rig_paired_gate.py` -> `highn_battery.py`), and
#   `p4-bondagg/sim/modes-r2-study/`.  THIS IS THE COPY EVERY PUBLISHED COMPOSITE
#   NUMBER WAS MEASURED ON.
#
# THERE IS A SECOND, DIFFERENT `ackclock_sim.py` at `../02-ackclock/`.  It is not
#   stale and is not a duplicate: it is the LATER revision of the `sched='C'`
#   research line (it alone has `c_mode`, `lam_used`/`lam_samp`/`LAM_MAX_WIN`,
#   `probe_frames` default 4, RTT subsampling, and different `_c_budget` /
#   `_pace_rate` derivations), and it is REQUIRED to reproduce that line's
#   committed outputs.  ADR-004 named it as the rig's oracle for a day; that was
#   wrong (amended `2c052b4`).  Full evidence, both directions, in
#   `../rig_pin.py`.  Measured: the two copies give IDENTICAL results for every
#   scheduler this line runs (ewma / pull / oracle / Dc) and differ only under
#   `sched='C'`, which this line never runs (U35, 2026-08-30).
#
# WHICH FILE AM I RUNNING?  Not a sys.path question any more:
#   python -c "import rig_pin, ackclock_sim; print(rig_pin.describe())"
# =============================================================================
import math, sys, random, heapq, os as _os, importlib.util as _ilu
from collections import deque


def _rig_pin():
    """Load ../rig_pin.py BY PATH -- never through sys.path, which is the very
    thing U35 exists to stop deciding which file runs."""
    p = _os.path.realpath(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                                        _os.pardir, 'rig_pin.py'))
    m = sys.modules.get('rig_pin')
    if m is not None and _os.path.normcase(_os.path.realpath(
            getattr(m, '__file__', '') or '')) == _os.path.normcase(p):
        return m
    spec = _ilu.spec_from_file_location('rig_pin', p)
    m = _ilu.module_from_spec(spec)
    sys.modules['rig_pin'] = m
    spec.loader.exec_module(m)
    return m


rig_pin = _rig_pin()
#: this file asserts WHICH copy of the oracle it is, from its own __file__
STUDY_LINE = rig_pin.claim(__file__, '03-reserved-composite')
#: the physics, loaded by path from p4-bondagg/sim/ -- NOT pull-study/variants/
M = rig_pin.pin_physics(__file__)
PHYSICS_FILE = _os.path.abspath(M.__file__)
ORACLE_FILE = _os.path.abspath(__file__)

PKT_KB = M.PKT_KB; DT = M.DT; QMAX_MS = M.QMAX_MS; NLAG = M.NLAG
reorder_release = M.reorder_release


# ---------------------------------------------------------------------------
# One fluid FIFO queue -- PathProc math verbatim from attack1_midnet.Stage.
# ---------------------------------------------------------------------------
class Stage:
    def __init__(s, owd_ms=0.0, jit_ms=0.0, qmax_ms=QMAX_MS):
        s.q = deque()            # (seq, enq_t)
        s.backlog_kb = 0.0
        s.owd = owd_ms; s.jit = jit_ms; s.qmax = qmax_ms
        s.carry = 0.0
        s.taildrops = 0; s.serviced = 0
        s.drain_rate = 0.0

    def q_ms(s, cap):
        return s.backlog_kb / cap * 1000.0 if cap > 0 else 1e9

    def offer(s, seq, enq_t, cap):
        if cap <= 0 or s.q_ms(cap) > s.qmax:
            s.taildrops += 1
            return False
        s.q.append((seq, enq_t)); s.backlog_kb += PKT_KB; s.serviced += 1
        return True

    def drain(s, cap, now, rng):
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


HUGE = 1e9


# ---------------------------------------------------------------------------
# Unified pooled-water simulator. sched in {pull, ewma, ack, push, oracle}.
# ---------------------------------------------------------------------------
class Sim:
    def __init__(s, path_defs, offer_fn, T, seed, sched='ack',
                 target_ms=40.0, lat_bias=False, wmult=1.0, w_frames=None,
                 w_ms=None, maxq_ms=300.0,
                 ack_loss=0.0, ack_comp_ms=0.0, rto_ms=None, pace_floor=False,
                 mirror=True,
                 # ---- scheduler C (unifying datapath law) knobs ----
                 c_repair='age', c_derive_hold=False,
                 cwnd_gain=1.25, startup_gain=2.0, cruise_gain=1.0, pace_burst=4.0,
                 probe_frames=1, probe_int_ms=25.0,
                 lam_win_ms=100.0, rttmin_win_ms=2500.0, loss_slack_ms=20.0):
        s.defs = path_defs; s.offer_fn = offer_fn; s.T = T
        s.rng = random.Random(seed)
        s.ack_rng = random.Random((seed + 7) * 2654435761 & 0xffffffff)
        s.N = len(path_defs); s.sched = sched
        s.target_ms = target_ms; s.lat_bias = lat_bias
        s.mirror = mirror
        s.local = [Stage(owd_ms=d['loc_owd'],
                         jit_ms=(d['jit'] if d.get('jit_stage') == 'local' else 0.0))
                   for d in path_defs]
        s.down = [Stage(owd_ms=d['down_owd'],
                        jit_ms=(d['jit'] if d.get('jit_stage', 'down') == 'down' else 0.0),
                        qmax_ms=d.get('down_qmax', QMAX_MS)) for d in path_defs]
        s.drain_ewma = [d['cap_fn'](0.0) for d in path_defs]   # LOCAL egress est (lag-free)
        s.fifo = deque(); s.next_seq = 0; s.frac = 0.0
        s.enq = {}                # seq -> app offer instant
        s.arr = {}                # seq -> earliest delivery time or None
        s.sent_on = {}            # seq -> set(paths sent on)  (mirror dedup)
        s.assigned = [0] * s.N
        s.maxq_kb = (maxq_ms / 1000.0) * sum(d['cap_fn'](0.0) for d in path_defs)
        s.qdrops = 0
        s.offered_post = 0; s.warm = 1.0
        # push lagged delivered-rate est
        s.deliv_hist = [deque() for _ in range(s.N)]
        s.push_est = [d['cap_fn'](0.0) for d in path_defs]
        # ---- ACK-CLOCK state ----
        # per-path in-flight (sent-but-unacked) frames: seq -> sent_time
        s.inflight = [dict() for _ in range(s.N)]
        s.ack_heap = []           # (ack_arrival_t, path, seq)
        s.ack_loss = ack_loss     # reverse-path ack loss prob (Q4)
        s.ack_comp_ms = ack_comp_ms   # ack compression: batch acks every N ms (Q4)
        s._ack_buf = []           # buffered ack arrivals awaiting a compression tick
        s._last_comp_flush = -1.0
        s.pace_floor = pace_floor # coarse pacing-timer floor: also release credit on a timer
        # RTO: reclaim a credit if a frame is unacked longer than rto (dead-path recovery)
        s.rto = (rto_ms / 1000.0) if rto_ms is not None else None
        # window (frames) per path. w_frames overrides; else BDP = cap0 * RTT * wmult.
        # W_i (frames). Precedence: w_frames (scalar) > w_ms (inflight-time horizon,
        # Little's law: sojourn ~= w_ms at cap0) > wmult*BDP(2*owd). All STATIC config
        # (from nominal cap0 + known owd) -- NO running rate estimator.
        s.W = []
        for pi, d in enumerate(path_defs):
            wmi = w_ms[pi] if isinstance(w_ms, (list, tuple)) else w_ms
            if w_frames is not None:
                s.W.append(w_frames)
            elif wmi is not None:
                s.W.append(max(4.0, d['cap_fn'](0.0) * (wmi / 1000.0) / PKT_KB))
            else:
                rtt = 2.0 * (d['loc_owd'] + d['down_owd']) / 1000.0
                s.W.append(max(4.0, d['cap_fn'](0.0) * rtt / PKT_KB * wmult))
        s.hol_block_events = 0    # ticks the in-order frontier was stalled with sends ahead

        # ============================================================
        # SCHEDULER C -- the unifying datapath law:
        #   inflight_i <= lambda_i * (RTTmin_i + tau)   (conservation seen as
        #   FLOW, closed by Little).  lambda_i measured from the far-end
        #   CUMULATIVE received-frame counter (a water-meter dial), inflight_i
        #   reconciled map-free from that same meter, RTTmin_i from echo
        #   timestamps, tau = target_ms (policy).  NO nominal-cap window, NO
        #   per-seq credit map, NO RTO-for-credit, NO EWMA-alpha.
        # ============================================================
        s.c_repair = c_repair            # 'age' (map-free loss reconcile) | 'raw'
        s.c_derive_hold = c_derive_hold  # derive reorder hold from measured RTTmin spread
        s.tau = target_ms / 1000.0       # latency budget (seconds) -- SAME policy knob as A/pull
        s.cwnd_gain = cwnd_gain          # CWND (max-inflight) gain -> bounds QUEUE ~ tau (p50 guard)
        s.startup_gain = startup_gain    # PACING gain while the rate is rising (drain backlog fast)
        s.cruise_gain = cruise_gain      # PACING gain at steady state (pace == delivered rate)
        s.pace_burst = pace_burst        # pacer token-bucket depth (frames) -> anti-clump
        s.pace_tokens = [0.0] * s.N
        s.probe_frames = probe_frames    # max-silence keep-alive depth (1 = "one frame per probe")
        s.probe_int = probe_int_ms / 1000.0
        s.LAM_WIN = lam_win_ms / 1000.0          # windowed delta/delta-t horizon (fast-down)
        s.RTTMIN_WIN = rttmin_win_ms / 1000.0    # long-window RTTmin horizon
        s.LOSS_SLACK = loss_slack_ms / 1000.0    # extra slack before declaring a frame lost
        s.sent_cum = [0] * s.N           # frames placed on path i (sender counter)
        s.recv_cum_srv = [0] * s.N       # TRUE far-end arrivals on path i (server counter)
        s.recv_reading = [0] * s.N       # last echoed recv_cum (absolute, monotone) seen by sender
        s.reading_hist = [deque() for _ in range(s.N)]   # (server_ts, recv_cum) for lambda
        s.echo_heap = []                 # (arrival_local_t, i, recv_cum_snap, server_ts, enq)
        s._echo_buf = []                 # compression buffer
        s._echo_last_flush = -1.0
        s.lam = [0.0] * s.N              # delivered-rate estimate (frames/sec) -- NO cap0 prior
        s.lam_hist = [deque() for _ in range(s.N)]
        s.rising = [False] * s.N
        s.c_startup = [True] * s.N        # BBR STARTUP mode: fast-fill on cold start/recovery
        s.lam_peak = [0.0] * s.N          # peak lambda seen this startup (plateau detector)
        s.lam_peak_t = [0.0] * s.N        # time of last new peak
        s.STARTUP_HOLD = 0.15             # exit startup when lambda plateaus this long (s)
        s.rtt_samp = [deque() for _ in range(s.N)]       # (t, rtt) round-trip samples
        s.rttmin = [None] * s.N          # long-window min RTT (seconds), MEASURED
        s.rtt_sigma = [0.0] * s.N        # measured RTT jitter (seconds)
        s.has_reading = [False] * s.N    # has the meter produced a reading yet?
        s.last_send_t = [-1e9] * s.N     # for the max-silence probe timer
        s.applim_t = [-1e9] * s.N        # last time path i was app-limited (pool-starved w/ room)
        s.send_t = {}                    # seq -> path-send instant (TCP-timestamp for RTT); NOT
                                         # a credit map -- losing an entry loses only an RTT sample
        s.flight_ts = [deque() for _ in range(s.N)]      # send-times FIFO (map-free inflight)
        s.removed = [0] * s.N            # frames removed from flight (delivered or declared lost)
        s.lost_cum = [0] * s.N           # frames declared lost by age (forward loss)
        s.c_overshoot = 0.0              # peak inflight-over-budget observed (frames) -- diagnostic
        s.c_probe_sends = 0              # frames sent purely as keep-alive probes

    def _c_inflight(s, i):
        if s.c_repair == 'age':
            return len(s.flight_ts[i])
        return s.sent_cum[i] - s.recv_reading[i]

    def _c_budget(s, i):
        # CWND: max in-flight (Little).  Gain is startup_gain while filling the
        # pipe (cold start / recovery -- the path IS delivering, so the extra fill
        # is queue, never loss), else cwnd_gain (low -> bounds QUEUE ~ tau -> p50
        # near oracle, and MINIMISES the blind overshoot when a path collapses).
        rttm = s.rttmin[i] if s.rttmin[i] is not None else 0.0
        g = s.startup_gain if s.c_startup[i] else s.cwnd_gain
        return g * s.lam[i] * (rttm + s.tau)

    def _pace_rate(s, i):
        # PACING rate (frames/sec): send AT the delivered rate, FASTER while in
        # STARTUP so a backlog drains without a single-tick clump (which would
        # arrive out-of-order -> late discards).
        gain = s.startup_gain if s.c_startup[i] else s.cruise_gain
        return gain * s.lam[i]

    def _local_cap(s, i, t):
        d = s.defs[i]
        lc = d['local_cap_fn'](t)
        if d.get('backpressure'):
            lc = min(lc, d['cap_fn'](t) * d['backpressure'])
        return lc

    def _lagged_deliv(s, i, now):
        t_hi = now - NLAG; t_lo = t_hi - 0.100
        tot = 0.0
        for (t, dk) in s.deliv_hist[i]:
            if t_lo <= t < t_hi:
                tot += dk
        return tot / 0.100 if tot > 0 else 0.0

    def _deliver(s, i, seq, x2, now):
        """A copy of seq arrived at the server on path i at x2. Record earliest
        delivery, and generate an ack that returns over the reverse path."""
        if s.arr.get(seq) is None or x2 < s.arr[seq]:
            s.arr[seq] = x2
            if seq > s._maxarr:
                s._maxarr = seq
        rev = (s.defs[i]['loc_owd'] + s.defs[i]['down_owd']) / 1000.0
        if s.sched == 'C':
            # Far-end CUMULATIVE received-frame counter advances on EVERY arrival
            # (the meter dial turns even if the echo is later lost/compressed).
            s.recv_cum_srv[i] += 1
            if s.ack_loss > 0.0 and s.ack_rng.random() < s.ack_loss:
                return                  # reading (echo) LOST -- idempotent: next reading repairs
            # echo carries the ABSOLUTE dial value + server timestamp + the frame's
            # PATH-SEND instant (TCP-timestamp echo) so the sender samples the true
            # NETWORK rtt -- NOT the app-offer time, which would fold in pool-queue wait.
            heapq.heappush(s.echo_heap,
                           (x2 + rev, i, s.recv_cum_srv[i], x2, s.send_t.get(seq, x2)))
            return
        # server acks receipt per path/seq; ack traverses reverse-path delay ~ RTT/2
        if s.ack_loss > 0.0 and s.ack_rng.random() < s.ack_loss:
            return                      # ack LOST on the reverse path (Q4)
        heapq.heappush(s.ack_heap, (x2 + rev, i, seq))

    def _process_acks(s, now):
        arrived = []
        while s.ack_heap and s.ack_heap[0][0] <= now + 1e-12:
            _, i, seq = heapq.heappop(s.ack_heap)
            arrived.append((i, seq))
        if s.ack_comp_ms > 0.0:
            # ACK COMPRESSION: physically-arrived acks are HELD and released in a
            # burst only on a coarse grid (receiver batches acks) -> credits free in
            # clumps -> bursty sends.
            s._ack_buf.extend(arrived)
            grid = s.ack_comp_ms / 1000.0
            if (round(now / grid) * grid) <= now + 1e-9 and \
               now - s._last_comp_flush >= grid - 1e-9:
                s._last_comp_flush = now
                for (i, seq) in s._ack_buf:
                    s.inflight[i].pop(seq, None)
                s._ack_buf = []
            return
        for (i, seq) in arrived:
            s.inflight[i].pop(seq, None)   # credit freed

    def _process_echoes(s, now):
        """Deliver far-end meter readings back to the sender. Idempotent under
        echo LOSS (each reading carries the ABSOLUTE dial value, so a missed
        reading loses nothing) and under ACK COMPRESSION (readings carry the
        SERVER timestamp, so a burst of readings still yields the correct slope
        d(dial)/d(t) spanning the batch)."""
        arrived = []
        while s.echo_heap and s.echo_heap[0][0] <= now + 1e-12:
            arrived.append(heapq.heappop(s.echo_heap))
        if s.ack_comp_ms > 0.0:
            s._echo_buf.extend(arrived)
            grid = s.ack_comp_ms / 1000.0
            if (round(now / grid) * grid) <= now + 1e-9 and \
               now - s._echo_last_flush >= grid - 1e-9:
                s._echo_last_flush = now
                batch = s._echo_buf; s._echo_buf = []
            else:
                return
        else:
            batch = arrived
        for (at, i, rc, sts, enq) in batch:
            rtt = at - enq                     # round-trip sample (app-offer -> echo-back)
            if rtt > 1e-6:
                s.rtt_samp[i].append((now, rtt))
            if rc > s.recv_reading[i]:
                s.recv_reading[i] = rc         # absolute dial -> monotone, self-repairing
            s.reading_hist[i].append((sts, rc))

    def _c_update(s, now):
        """Per-tick meter maths: windowed lambda (delta dial / delta server-time,
        naturally fast-DOWN, app-limited-guarded so idle does not ratchet it
        down), windowed RTTmin + jitter, and the map-free inflight reconcile."""
        for i in range(s.N):
            rh = s.reading_hist[i]
            while len(rh) > 2 and rh[-1][0] - rh[0][0] > s.LAM_WIN:
                rh.popleft()
            lam_meas = 0.0
            if len(rh) >= 2 and rh[-1][0] > rh[0][0]:
                lam_meas = (rh[-1][1] - rh[0][1]) / (rh[-1][0] - rh[0][0])
            applim = (now - s.applim_t[i]) < s.LAM_WIN
            if applim:
                s.lam[i] = max(s.lam[i], lam_meas)   # BBR app-limited flag: no down-ratchet
            else:
                s.lam[i] = lam_meas                  # windowed delta/dt -> fast down, no EWMA lag
            s.lam_hist[i].append((now, s.lam[i]))
            while s.lam_hist[i] and s.lam_hist[i][0][0] < now - 1.5 * s.LAM_WIN:
                s.lam_hist[i].popleft()
            lam_old = s.lam_hist[i][0][1] if s.lam_hist[i] else 0.0
            # rising = the delivered rate is climbing -> pace FASTER to drain any
            # backlog. This only lifts the PACING rate; the CWND (cwnd_gain) still
            # bounds the queue, so a rising-phase over-fill cannot inflate p50.
            s.rising[i] = s.lam[i] > 1.05 * lam_old
            # ---- BBR STARTUP mode transitions (a MODE, so the fill gain persists
            # through the WHOLE ramp, not just the first window) ----
            if s.c_startup[i]:
                if s.lam[i] > 1.02 * s.lam_peak[i]:
                    s.lam_peak[i] = s.lam[i]; s.lam_peak_t[i] = now
                elif now - s.lam_peak_t[i] >= s.STARTUP_HOLD:
                    s.c_startup[i] = False           # lambda plateaued -> pipe full -> cruise
            else:
                if s.lam[i] > 0.0 and lam_old < 0.25 * s.lam[i]:
                    # sharp (>4x/150ms) rise from a low rate -> a stall just ended:
                    # re-enter STARTUP to refill fast (sinusoidal ripples never do this)
                    s.c_startup[i] = True; s.lam_peak[i] = s.lam[i]; s.lam_peak_t[i] = now
            # per-tick pacing allowance = one tick of the pacing rate + a small
            # fixed burst slack. Reset each tick (no cross-tick accumulation) so an
            # idle path cannot save up a huge burst -- that is the anti-clump.
            s.pace_tokens[i] = s._pace_rate(i) * DT + s.pace_burst
            rs = s.rtt_samp[i]
            while rs and rs[0][0] < now - s.RTTMIN_WIN:
                rs.popleft()
            if rs:
                vals = [r for _, r in rs]
                s.rttmin[i] = min(vals)
                m = sum(vals) / len(vals)
                s.rtt_sigma[i] = (sum((v - m) ** 2 for v in vals) / len(vals)) ** 0.5
                s.has_reading[i] = True
            if s.c_repair == 'age':
                ft = s.flight_ts[i]
                target = s.recv_reading[i]
                while s.removed[i] < target and ft:
                    ft.popleft(); s.removed[i] += 1          # delivered -> leave the flight (FIFO)
                rttm = s.rttmin[i] if s.rttmin[i] is not None else 0.0
                age_thr = rttm + s.tau + 3.0 * s.rtt_sigma[i] + s.LOSS_SLACK
                while ft and (now - ft[0]) > age_thr:
                    ft.popleft(); s.removed[i] += 1; s.lost_cum[i] += 1   # too old -> declared LOST

    def _rto_reclaim(s, now):
        # Coarse PACING-TIMER FLOOR / RTO: free a credit if it has been unacked
        # longer than rto (a frame is deemed lost, or its ack was lost/late). This
        # is the estimator-free timer that (a) recovers credit after a stalled path
        # revives and (b) keeps a path sending when reverse-path acks are lost or
        # compressed. Without it, lost acks permanently jam the window.
        if s.rto is None:
            return
        for i in range(s.N):
            if not s.inflight[i]:
                continue
            dead = [seq for seq, st in s.inflight[i].items() if now - st > s.rto]
            for seq in dead:
                s.inflight[i].pop(seq, None)

    def _advance_front(s):
        """advance the in-order frontier past the delivered contiguous prefix."""
        while s._front_lo < s.next_seq and s.arr.get(s._front_lo) is not None:
            s._front_lo += 1

    def _mirror_target(s):
        """smallest undelivered, already-SENT seq (at/after frontier) that still
        has a path not yet sent-on; bounded forward scan (cheap)."""
        s._advance_front()
        hi = min(s.next_seq, s._front_lo + 96)
        for seq in range(s._front_lo, hi):
            if s.arr.get(seq) is None and len(s.sent_on.get(seq, ())) > 0:
                return seq
        return None

    def run(s):
        nticks = int(round(s.T / DT))
        s._front_lo = 0; s._maxarr = -1
        for tk in range(nticks):
            now = tk * DT
            caps = [s.defs[i]['cap_fn'](now) for i in range(s.N)]
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            s._process_acks(now)
            s._rto_reclaim(now)
            if s.sched == 'C':
                s._process_echoes(now)
                s._c_update(now)
            # ---- offer -> pooled send-FIFO ----
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq[seq] = now; s.arr[seq] = None
                s.sent_on[seq] = set()
                if now > s.warm:
                    s.offered_post += 1
            # shallow-pool admission bound (finite client FIFO)
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                seq = s.fifo.popleft(); s.qdrops += 1  # oldest dropped (overflow)
                # dropped from pool before any send -> stays arr=None (lost)
            # ---- gates ----
            def local_ms(i):
                return s.local[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
            def room(i):
                if lcaps[i] <= 0:
                    return False
                if s.sched == 'pull':
                    return local_ms(i) < s.target_ms
                if s.sched == 'ewma':
                    if local_ms(i) >= s.target_ms:
                        return False
                    est = max(1.0, s.push_est[i])
                    inflight_kb = s.local[i].backlog_kb + s.down[i].backlog_kb
                    return inflight_kb / est * 1000.0 < s.target_ms
                if s.sched == 'ack':
                    if local_ms(i) >= s.target_ms:
                        return False
                    return len(s.inflight[i]) < s.W[i]
                if s.sched == 'C':
                    # LOCAL ms-gate = the zero-RTT EDGE instance of the SAME law
                    # (bound the LOCAL in-flight time backlog/local-drain < tau).
                    if local_ms(i) >= s.target_ms:
                        return False
                    inflight = s._c_inflight(i)
                    # Before the first meter reading returns, the only signal is
                    # local egress: pace by the local gate (pipe is empty -> a
                    # bounded 1-RTT fill, the app-rate caps the cold-start overshoot).
                    if not s.has_reading[i]:
                        return True
                    # max-silence probe: keep the meter alive on an idle/stalled
                    # path (one frame per probe-interval) so lambda can re-measure.
                    if inflight < s.probe_frames and (now - s.last_send_t[i]) >= s.probe_int:
                        return True
                    # END-TO-END flow bound (Little): inflight <= lambda*(RTTmin+tau)
                    # AND paced: hold a token bucket at pace_gain*lambda (anti-clump).
                    if s.pace_tokens[i] < 1.0:
                        return False
                    return inflight < max(1.0, s._c_budget(i))
                if s.sched == 'push':
                    est = max(1.0, s.push_est[i])
                    inflight_kb = s.local[i].backlog_kb + s.down[i].backlog_kb
                    return inflight_kb / est * 1000.0 < s.target_ms
                # oracle
                est = max(1.0, caps[i])
                inflight_kb = s.local[i].backlog_kb + s.down[i].backlog_kb
                return inflight_kb / est * 1000.0 < s.target_ms
            # ---- pooled-water draw: head frame to hungriest drainable path ----
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = [i for i in range(s.N) if room(i)]
                if not cand:
                    break
                if s.lat_bias:
                    cand.sort(key=lambda i: (s.defs[i]['down_owd'] + s.defs[i]['loc_owd'],
                                             local_ms(i)))
                else:
                    cand.sort(key=local_ms)
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1
                        s.sent_on[seq].add(i)
                        if s.sched == 'C':
                            if s._c_inflight(i) < s.probe_frames and \
                               (now - s.last_send_t[i]) >= s.probe_int and \
                               s._c_inflight(i) >= max(1.0, s._c_budget(i)):
                                s.c_probe_sends += 1     # this send was a keep-alive probe
                            s.sent_cum[i] += 1
                            s.flight_ts[i].append(now)
                            s.send_t[seq] = now
                            s.last_send_t[i] = now
                            s.pace_tokens[i] = max(0.0, s.pace_tokens[i] - 1.0)
                        else:
                            s.inflight[i][seq] = now
                        placed = True; break
                if not placed:
                    break
            # ---- opportunistic spare-capacity MIRROR (A and B, identical) ----
            # when the pool is empty but a healthy path still has room+credit, send
            # a duplicate of the in-order HOL blocker so a straggler can't stall the
            # ring. receiver dedups (reorder_release takes first arrival).
            if s.mirror and not s.fifo and s.sched in ('ewma', 'ack', 'C'):
                blocker = s._mirror_target()
                if blocker is not None:
                    mcand = [i for i in range(s.N)
                             if room(i) and i not in s.sent_on[blocker]]
                    if s.lat_bias:
                        mcand.sort(key=lambda i: (s.defs[i]['down_owd'] + s.defs[i]['loc_owd'],))
                    else:
                        mcand.sort(key=local_ms)
                    for i in mcand[:1]:     # at most one mirror copy per tick (opportunistic)
                        if s.local[i].offer(blocker, s.enq[blocker], lcaps[i]):
                            s.sent_on[blocker].add(i)
                            if s.sched == 'C':
                                s.sent_cum[i] += 1
                                s.flight_ts[i].append(now)
                                s.send_t[blocker] = now
                                s.last_send_t[i] = now
                                s.pace_tokens[i] = max(0.0, s.pace_tokens[i] - 1.0)
                            else:
                                s.inflight[i][blocker] = now
            # ---- C: mark app-limited paths (had budget room but the pool was dry) ----
            if s.sched == 'C' and not s.fifo:
                for i in range(s.N):
                    if lcaps[i] <= 0 or local_ms(i) >= s.target_ms:
                        continue
                    if not s.has_reading[i]:
                        s.applim_t[i] = now
                    elif s._c_inflight(i) < s._c_budget(i):
                        s.applim_t[i] = now
                    # diagnostic: peak inflight over the flow budget (blind overshoot)
                    if s.has_reading[i]:
                        ov = s._c_inflight(i) - s._c_budget(i)
                        if ov > s.c_overshoot:
                            s.c_overshoot = ov
            # ---- stage-1 drain -> stage-2 ; stage-2 drain -> deliver + ack ----
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (seq, enq, x1) in exited:
                    if not s.down[i].offer(seq, enq, dcaps[i]):
                        pass                # downstream taildrop = this copy LOST
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                dk = 0.0
                for (seq, enq, x2) in delivered:
                    s._deliver(i, seq, x2, now); dk += PKT_KB
                s.deliv_hist[i].append((now, dk))
                aE = math.exp(-DT / 0.10)
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i] * aE + s.local[i].drain_rate * (1 - aE)
                else:
                    s.drain_ewma[i] += 0.02 * (s.defs[i]['cap_fn'](0.0) - s.drain_ewma[i])
                s.push_est[i] = s._lagged_deliv(i, now) or s.push_est[i]
            for i in range(s.N):
                while s.deliv_hist[i] and s.deliv_hist[i][0][0] < now - 0.6:
                    s.deliv_hist[i].popleft()
            if getattr(s, '_do_trace', False) and tk % 5 == 0:
                s._trace.append((now, dcaps[0], caps[0], s.lam[0],
                                 s._c_budget(0), s._c_inflight(0),
                                 s.down[0].backlog_kb / PKT_KB, len(s.fifo),
                                 1 if s.c_startup[0] else 0, s.pace_tokens[0]))
            # HOL diagnostic (O(1)): frontier blocked while a LATER seq already delivered
            s._advance_front()
            if s._front_lo < s.next_seq and s.arr.get(s._front_lo) is None \
                    and s._maxarr > s._front_lo:
                s.hol_block_events += 1
        return s.finalize()

    def finalize(s):
        owds = [s.defs[i]['down_owd'] + s.defs[i]['loc_owd'] for i in range(s.N)]
        jits = [d['jit'] for d in s.defs]
        s.hold_legacy = min(0.35, max(0.08,
                        ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0))
        s.hold_derived = None
        if s.sched == 'C' and any(r is not None for r in s.rttmin):
            # DERIVE the reorder hold from the MEASURED RTTmin spread (delete the
            # 130ms constant): forward-arrival skew = half the round-trip RTTmin
            # spread, plus a measured-jitter margin (3 sigma).  No magic constant.
            rmins = [r for r in s.rttmin if r is not None]
            spread = (max(rmins) - min(rmins)) if len(rmins) > 1 else 0.0
            sig = max(s.rtt_sigma) if any(s.rtt_sigma) else 0.0
            s.hold_derived = min(0.35, max(0.08, 0.5 * spread + 3.0 * sig))
        if s.sched == 'C' and s.c_derive_hold and s.hold_derived is not None:
            hold = s.hold_derived
        else:
            hold = s.hold_legacy
        deliv_items = [(a, seq) for seq, a in s.arr.items() if a is not None]
        release, skips, depth = reorder_release(deliv_items, hold)
        rel_seqs = set(release)
        late_discard = sum(1 for (a, sq) in deliv_items
                           if sq not in rel_seqs and s.enq.get(sq, 0) > s.warm)
        Teff = s.T - s.warm
        lat = []; deliv_data = 0
        for seq, rt in release.items():
            st = s.enq[seq]
            if st > s.warm:
                deliv_data += 1; lat.append((rt - st) * 1000.0)
        lat.sort()
        def pct(p): return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))] if lat else 0.0
        gp = deliv_data * PKT_KB / Teff
        loss = 100.0 * (s.offered_post - deliv_data) / s.offered_post if s.offered_post else 0.0
        return {'gp': gp, 'loss': max(0.0, loss), 'p50': pct(.5), 'p95': pct(.95),
                'p99': pct(.99), 'depth': depth,
                'tdrop': sum(st.taildrops for st in s.down) + sum(st.taildrops for st in s.local),
                'tshare': s.assigned[0] / (sum(s.assigned) or 1),
                'hol': s.hol_block_events, 'qdrops': s.qdrops,
                'late': late_discard, 'deliv': deliv_data,
                # ---- C diagnostics ----
                'c_overshoot': s.c_overshoot, 'c_probe': s.c_probe_sends,
                'c_lost': sum(s.lost_cum),
                'hold_legacy': 1000.0 * s.hold_legacy,
                'hold_derived': (1000.0 * s.hold_derived) if s.hold_derived is not None else 0.0,
                'rttmin_lo': 1000.0 * min([r for r in s.rttmin if r is not None], default=0.0),
                'rttmin_hi': 1000.0 * max([r for r in s.rttmin if r is not None], default=0.0)}


# ---------------------------------------------------------------------------
def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def agg(ms):
    return {k: med([m[k] for m in ms]) for k in ms[0]}


# ---------------------------------------------------------------------------
# Cap traces (from attack1 / pull_study, verbatim shape).
# ---------------------------------------------------------------------------
def tether_cap(base=29000.0, amp=24000.0, period=3.1, dropouts=(), floor=3000.0):
    def f(t):
        for (a, b) in dropouts:
            if a <= t < b:
                return 0.0
        return max(floor, base + amp * math.sin(2 * math.pi * t / period))
    return f

def eth_cap(base=78000.0, amp=12000.0, period=5.0):
    return lambda t: base + amp * math.sin(2 * math.pi * t / period + 1.0)


def make_defs(bottleneck='edge', local_mult=20.0, backpressure=None,
              down_qmax=QMAX_MS, drops=None, shaping=False, tcap=None, ecap=None):
    if drops is None:
        drops = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
    if tcap is None:
        if shaping:
            def tcap(t, _d=drops):
                for (a, b) in _d:
                    if a <= t < b:
                        return 4000.0
                return max(3000.0, 29000.0 + 24000.0 * math.sin(2 * math.pi * t / 3.1))
        else:
            tcap = tether_cap(dropouts=drops)
    if ecap is None:
        ecap = eth_cap()
    if bottleneck == 'edge':
        return [
            dict(cap_fn=tcap, local_cap_fn=tcap, loc_owd=25.0, down_owd=2.0,
                 jit=25.0, jit_stage='local', backpressure=backpressure,
                 down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
            dict(cap_fn=ecap, local_cap_fn=ecap, loc_owd=8.0, down_owd=1.0,
                 jit=1.0, jit_stage='local', backpressure=backpressure,
                 down_cap_fn=lambda t: HUGE, down_qmax=HUGE),
        ]
    tloc = lambda t: 30000.0 * local_mult
    eloc = lambda t: 78000.0 * local_mult
    return [
        dict(cap_fn=tcap, local_cap_fn=tloc, loc_owd=2.0, down_owd=25.0,
             jit=25.0, jit_stage='down', backpressure=backpressure,
             down_cap_fn=tcap, down_qmax=down_qmax),
        dict(cap_fn=ecap, local_cap_fn=eloc, loc_owd=1.0, down_owd=8.0,
             jit=1.0, jit_stage='down', backpressure=backpressure,
             down_cap_fn=ecap, down_qmax=down_qmax),
    ]
