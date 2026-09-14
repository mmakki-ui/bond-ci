#!/usr/bin/env python3
# =============================================================================
# mpath_model.py  --  N-path speed-mode scheduler emulator HARNESS  (v0.1)
#
# The offline test rig that ANY speed-mode packet scheduler plugs into. Sibling
# to sched_model.py (the single-path rate-controller emulator); mirrors its
# discipline EXACTLY: seeded RNG only, NO wall-clock, fixed DT tick, kilobit
# units, per-frame service+queue with a 300ms tail-drop (pathsim.py), and the
# fec.go tierCtl (K in {0,20,12,8}, strengths 0<20<12<8). Run it locally:
#   %LOCALAPPDATA%\Programs\Python\Python312\python.exe mpath_model.py
#
# WHAT IT MEASURES (the speed-mode objective, docs/.../design/speed-mode.md):
#   maximize delivered POST-FEC throughput  +  minimize IN-ORDER delivery
#   latency, without the head-of-line (reorder) trap. Per scenario it grades a
#   scheduler on: delivered kb/s vs the ideal (sum of EFFECTIVE capacities),
#   in-order latency p50/p95, reorder depth, per-path utilisation, role flaps.
#
# -----------------------------------------------------------------------------
# THE SCHEDULER PLUG-IN INTERFACE  (this is the whole contract; one function)
# -----------------------------------------------------------------------------
# A scheduler is any object exposing:
#
#     name : str
#     reset(n_paths: int) -> None          # called once at scenario start
#     schedule(now, paths, pkt) -> int     # per-packet: return a path index
#
#   now   : float   simulated seconds since start (NEVER wall-clock).
#   pkt   : Pkt     the frame to place -> .seq (int, -1 for parity),
#                   .is_parity (bool), .size_kb (float).
#   paths : list[PathState]  one live snapshot per path -- exactly what a real
#           scheduler could MEASURE at the sender (estimates, not ground truth):
#               .index                    int
#               .alive                    bool   (down paths must not be chosen)
#               .est_capacity_kb          float  link capacity estimate (kb/s)
#               .est_effective_capacity_kb float capacity * (1 - FEC_tax(loss))
#               .est_rtt_ms               float  smoothed round-trip
#               .est_owd_ms               float  one-way (= rtt/2)
#               .est_queue_ms             float  current backlog wait
#               .est_jitter_ms            float  jitter sigma estimate
#               .est_loss                 float  observed loss fraction (EWMA)
#               .inflight                 float  ~frames queued ahead
#
#   RETURN an integer path index. Returning a dead path is treated as a drop
#   (the harness will not crash) so a correct scheduler must honour .alive.
#
# To drop in the real ECF/BLEST scheduler later: implement one class with the
# three members above and add it to BASELINES (or pass it to run_scenarios).
# NOTHING else in this file needs to change -- the receiver (reorder+FEC),
# metrics and scenarios are scheduler-agnostic.
#
# -----------------------------------------------------------------------------
# DESIGN-DOC AMBIGUITIES + WHAT WE ASSUMED (documented per task requirement)
# -----------------------------------------------------------------------------
#  A1. Per-path vs global FEC. The doc's effective-capacity formula is per-path
#      (capacity_i * (1 - FEC_overhead(loss_i))) but the daemon runs ONE global
#      tierCtl over aggregate peerloss. We do BOTH, at their correct layers:
#        - RECEIVER FEC: a single global tierCtl (fec.go mirror) drives K and
#          real parity frames (which consume path capacity -> the throughput
#          tax is emergent, not bolted on).
#        - SCHEDULER SIGNAL: PathState.est_effective_capacity_kb prices EACH
#          path's own loss via tierK(loss_i) -> 1/K overhead, so a scheduler
#          can deprioritise a lossy path (the doc's "falls out of the fill").
#      The grading "ideal" = sum_i true_capacity_i*(1 - FEC_tax(true_loss_i)).
#  A2. RTT vs OWD. Doc says "RTT"; the receiver needs one-way delay. We store
#      rtt and use owd = rtt/2 for arrival timing; schedulers see both.
#  A3. Reorder Hold. ring.go's Hold is configurable (HoldMax ~350ms). We use
#      REORDER_HOLD below; large enough that a heterogeneous path's late frames
#      inflate LATENCY (the HoL trap we want to expose) rather than silently
#      skip. Value chosen so the sanity contrast (RR vs weighted) is visible.
#  A4. Feedback lag. Real loss feedback is delayed ~RTT. The FEC loss estimate
#      is aggregated over a 500ms reporter window and EWMA-smoothed (0.7/0.3,
#      matching main.go), giving the loss->FEC->fill loop ~1-2 windows of lag
#      (the doc's oscillation concern is observable in the K trace).
#  A5. Recovery timing. An exactly-1-loss group is reconstructable once its
#      parity + K-1 members have arrived; the recovered frame enters the
#      reorder buffer at max(arrival of those pieces) (fec.go evidence gate is
#      approximated by "parity present AND exactly one member missing").
#  A6. "Estimates". A real sender's estimates lag reality. We model only the
#      capacity estimate lag (CAP_EST_TAU EWMA, so collapse triggers a real
#      promotion transient); rtt/jitter/queue/loss are exposed live/EWMA. Added
#      estimator staleness is out of scope for THIS harness.
#  A7. FEC loss signal. This harness is OPEN-LOOP (fixed offer, no rate
#      controller -- that is sched_model.py's job). So overspill produces
#      persistent congestion tail-drops that, if counted as loss, would
#      spuriously drive FEC. We therefore drive the tierCtl from LINK loss only
#      (random in-flight loss), excluding congestion drops -- modelling the
#      daemon's steady state where its rate controller has already removed
#      congestion. Result: clean lossless paths keep K=0; a genuinely lossy
#      path raises K and recovers, with no false FEC on overspill.
#  A-minRTT. "with spare capacity" == cwnd space in MPTCP; this open-loop rig
#      has no cwnd, so minRTT is pure latency-first (see MinRTT docstring).
# =============================================================================

import random
from collections import Counter

# ---- global constants (mirror sched_model.py / pathsim.py) ------------------
DT           = 0.010     # tick, seconds
PKT_KB       = 9.79      # kilobits per 1224B frame (sched_model.py)
DROP_Q       = 0.30      # tail-drop when queue wait exceeds this (pathsim.py)
REORDER_HOLD = 0.250     # receiver reorder max hold before skip (A3)
REPORT       = 0.50      # loss-reporter window (main.go 500ms)
CAP_EST_TAU  = 0.50      # capacity-estimate EWMA time constant (A6)
LOSS_ALPHA   = 0.02      # per-frame loss-estimate EWMA weight
WARMUP       = 1.00      # seconds of ramp excluded from graded metrics


# =============================================================================
# FEC tierCtl mirror  (daemon/fec.go)
# =============================================================================
def tierK(loss_pct):                       # fec.go tierK
    if loss_pct < 0.4: return 0            # off
    if loss_pct < 2.0: return 20           # ~5% overhead (~1% operating point)
    if loss_pct < 4.5: return 12           # ~8%
    return 8                                # 12.5% (~5%+)

def kStrength(k):                          # fec.go kStrength (0 < 20 < 12 < 8)
    return {0: 0, 20: 1, 12: 2, 8: 3}.get(k, 3)

def oneWeaker(k):                          # fec.go oneWeaker
    return {8: 12, 12: 20}.get(k, 0)

def fec_tax(loss_frac):
    """Effective-capacity FEC overhead for a path's loss (A1 scheduler signal).
    tierK sets the parity ratio; overhead = 1/K (one parity per K data)."""
    k = tierK(loss_frac * 100.0)
    return 0.0 if k == 0 else 1.0 / k

class TierCtl:
    """fec.go tierCtl: strengthen instantly, weaken one step after 4 straight
    weaker candidates. No collapse-hold here (that is a daemon control-plane
    coupling; the harness drives K purely from observed loss)."""
    def __init__(s):
        s.cnt = 0
    def step(s, cur, nk):
        if kStrength(nk) > kStrength(cur):
            s.cnt = 0
            return nk, True
        if nk == cur:
            s.cnt = 0
            return cur, False
        s.cnt += 1
        if s.cnt >= 4:
            s.cnt = 0
            return oneWeaker(cur), True
        return cur, False


# =============================================================================
# Path model  (per-frame service + queue + tail-drop + jitter + loss)
# =============================================================================
class PathSpec:
    """Static description of one WAN source. cap_fn/alive_fn make capacity and
    liveness time-varying (collapse, hotplug); otherwise constant."""
    def __init__(s, cap, rtt_ms, jitter_ms=0.0, loss=0.0, cap_fn=None,
                 alive_fn=None):
        s.cap0 = cap; s.rtt_ms = rtt_ms; s.jitter_ms = jitter_ms; s.loss = loss
        s.cap_fn = cap_fn; s.alive_fn = alive_fn

class PathState:
    """Read-only snapshot handed to the scheduler (the measurable surface)."""
    __slots__ = ('index', 'alive', 'est_capacity_kb', 'est_effective_capacity_kb',
                 'est_rtt_ms', 'est_owd_ms', 'est_queue_ms', 'est_jitter_ms',
                 'est_loss', 'inflight')

class Path:
    def __init__(s, spec):
        s.spec = spec
        s.cap = spec.cap0            # true capacity now (kb/s)
        s.est_cap = spec.cap0        # lagged capacity estimate
        s.rtt_ms = spec.rtt_ms
        s.jitter_ms = spec.jitter_ms
        s.loss = spec.loss
        s.next_free = 0.0            # next instant the link is idle
        s.loss_ewma = spec.loss      # observed-loss estimate
        s.serviced = 0               # frames that consumed capacity (util)
        s.taildrops = 0
        s.rndlost = 0
        s.assigned = 0               # frames the scheduler placed here
        s.cap_integral = 0.0         # sum cap*DT (for utilisation + ideal)
        s.eff_integral = 0.0         # sum cap*(1-tax(loss))*DT (ideal ceiling)
        s._alive = True

    def update(s, now):
        s.cap = s.spec.cap_fn(now) if s.spec.cap_fn else s.spec.cap0
        s._alive = s.spec.alive_fn(now) if s.spec.alive_fn else True
        # lagged capacity estimate (A6): first-order EWMA toward true cap
        s.est_cap += (s.cap - s.est_cap) * (DT / CAP_EST_TAU)
        s.cap_integral += s.cap * DT
        s.eff_integral += s.cap * (1.0 - fec_tax(s.loss)) * DT

    def alive(s):
        return s._alive

    def state(s, now, out):
        out.index = s.idx
        out.alive = s._alive
        out.est_capacity_kb = s.est_cap
        out.est_effective_capacity_kb = s.est_cap * (1.0 - fec_tax(s.loss_ewma))
        out.est_rtt_ms = s.rtt_ms
        out.est_owd_ms = s.rtt_ms / 2.0
        out.est_queue_ms = max(0.0, s.next_free - now) * 1000.0
        out.est_jitter_ms = s.jitter_ms
        out.est_loss = s.loss_ewma
        svc_ms = PKT_KB / s.cap * 1000.0 if s.cap > 0 else 1e9
        out.inflight = out.est_queue_ms / svc_ms if svc_ms > 0 else 0.0
        return out

    def send(s, now, rng):
        """Transmit one frame. Returns (arrival_time, cause):
          ('ok')   delivered -> arrival time (float)
          ('drop') congestion tail-drop (queue > 300ms) -> None  [backpressure]
          ('loss') random in-flight LINK loss -> None
        Mutates queue + estimators. Mirrors pathsim.Path.delay. The cause split
        lets the FEC loss estimator (A7) ignore congestion drops and track only
        link loss -- as the daemon does at steady state once its rate controller
        (out of scope for this scheduler harness) has removed congestion."""
        if not s._alive or s.cap <= 0:
            return None, 'drop'
        svc = PKT_KB / s.cap                       # service time (s)
        start = max(now, s.next_free)
        if start - now > DROP_Q:                    # tail-drop (no capacity use)
            s.taildrops += 1
            return None, 'drop'
        s.next_free = start + svc
        s.serviced += 1                             # consumed capacity
        if s.loss > 0 and rng.random() < s.loss:    # random link loss in flight
            s.rndlost += 1
            s._obs_loss(1)
            return None, 'loss'
        s._obs_loss(0)
        owd = s.rtt_ms / 2.0 / 1000.0
        jit = max(0.0, rng.gauss(0.0, s.jitter_ms)) / 1000.0
        return start + svc + owd + jit, 'ok'

    def _obs_loss(s, lost):
        s.loss_ewma += (lost - s.loss_ewma) * LOSS_ALPHA


# =============================================================================
# Packet
# =============================================================================
class Pkt:
    __slots__ = ('seq', 'is_parity', 'size_kb')
    def __init__(s, seq, is_parity=False):
        s.seq = seq; s.is_parity = is_parity; s.size_kb = PKT_KB


# =============================================================================
# Baseline schedulers  (validate that the harness measures the right trade)
# =============================================================================
class RoundRobin:
    """Blind rotation over alive paths. Aggregates capacity but ignores
    capacity/RTT heterogeneity -> overloads slow paths and desynchronises
    arrivals => high reorder + head-of-line latency. The HoL demonstrator."""
    name = "round-robin"
    def reset(s, n): s.i = 0; s.n = n
    def schedule(s, now, paths, pkt):
        for _ in range(s.n):
            s.i = (s.i + 1) % s.n
            if paths[s.i].alive:
                return s.i
        return 0

class WeightedCapacity:
    """Smooth weighted-round-robin by EFFECTIVE capacity (credit/deficit). Keeps
    per-path load proportional to capacity => balanced queues, synchronised
    arrivals => aggregates with far less reorder than RR."""
    name = "weighted-cap"
    def reset(s, n): s.credit = [0.0] * n; s.n = n
    def schedule(s, now, paths, pkt):
        tot = 0.0; best = -1; bestc = None
        for p in paths:
            if not p.alive:
                continue
            w = max(1.0, p.est_effective_capacity_kb)
            s.credit[p.index] += w
            tot += w
            if bestc is None or s.credit[p.index] > bestc:
                bestc = s.credit[p.index]; best = p.index
        if best < 0:
            return 0
        s.credit[best] -= tot
        return best

class MinRTT:
    """Latency-first: always the lowest-RTT ALIVE path (queue-tie broken by
    smaller queue). The textbook MPTCP minRTT weakness -- it never fills a path
    and moves on, so under OVERSPILL it piles onto the fast path, tail-drops the
    excess, and does NOT aggregate; on a CAPACITY collapse it cannot re-role (it
    ranks by propagation RTT, blind to throughput). Its virtue: single-path =>
    no cross-path reorder and bounded latency (no HoL explosion).

    NOTE (assumption A-minRTT): MPTCP's "with spare capacity" means congestion-
    window space. This open-loop harness has no cwnd, so a capacity-aware spill
    would turn minRTT into a work-conserving aggregator -- defeating its role as
    the non-aggregating baseline. We keep it pure latency-first by design."""
    name = "min-rtt"
    def reset(s, n): s.n = n
    def schedule(s, now, paths, pkt):
        best = None
        for p in paths:
            if not p.alive:
                continue
            if best is None or p.est_rtt_ms < best.est_rtt_ms or (
                    p.est_rtt_ms == best.est_rtt_ms and p.est_queue_ms < best.est_queue_ms):
                best = p
        return best.index if best is not None else 0

BASELINES = [RoundRobin(), WeightedCapacity(), MinRTT()]


# =============================================================================
# Receiver: in-order reorder buffer  (ring.go semantics, offline)
# =============================================================================
def reorder_release(items, hold):
    """items: list of (arrival_time, seq) for every frame that reached the RX
    (originals + FEC-recovered). Simulates ring.go's in-order release with a
    per-head Hold timeout and its OVERDUE-EPOCH flush (when the head gap times
    out, every buffered frame that has itself aged >= Hold is released in one
    epoch, skipping all missing seqs before the newest overdue one -- ring.go
    drain()). Without the epoch flush, scattered drops would each cost a serial
    Hold and latency would diverge; the epoch bounds it to ~Hold + path spread.
    Returns (release_time{seq}, skips, max_depth). release_time = the instant
    the frame is emitted in order (its own arrival if no gap ahead, else when
    the blocking gap clears or its Hold expires)."""
    if not items:
        return {}, 0, 0
    arr = sorted(items)                      # by (time, seq)
    n = len(arr)
    max_seq = max(s for _, s in arr)
    next_seq = min(s for _, s in arr)
    present = {}                             # seq -> arrival_time (buffered)
    release = {}
    skips = 0
    max_depth = 0
    blocked_at = None                        # when the current head gap formed
    ptr = 0
    INF = float('inf')
    while ptr < n or next_seq <= max_seq:
        t_arr = arr[ptr][0] if ptr < n else INF
        t_hold = (blocked_at + hold) if blocked_at is not None else INF
        if t_arr == INF and t_hold == INF:
            break
        if t_hold <= t_arr:                  # head gap timed out -> overdue epoch
            clock = t_hold
            if present:                      # flush every buffered frame (all
                target = max(present)        # aged >= Hold given small spread),
                while next_seq <= target:    # skipping the missing seqs before.
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = clock if clock > a else a
                    else:
                        skips += 1
                    next_seq += 1
            else:                            # nothing buffered: skip to next arrival
                tgt = arr[ptr][1] if ptr < n else max_seq + 1
                while next_seq < tgt:
                    skips += 1
                    next_seq += 1
            blocked_at = None
        else:                                # ingest all arrivals at t_arr
            clock = t_arr
            while ptr < n and arr[ptr][0] == t_arr:
                s = arr[ptr][1]
                if s >= next_seq and s not in release:
                    present[s] = t_arr
                ptr += 1
        while next_seq in present:           # release the in-order run
            a = present.pop(next_seq)
            release[next_seq] = clock if clock > a else a
            next_seq += 1
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None:           # head gap: (re)start its Hold timer
                blocked_at = clock
        else:
            blocked_at = None
        if len(present) > max_depth:
            max_depth = len(present)
    return release, skips, max_depth


# =============================================================================
# Simulator
# =============================================================================
def simulate(specs, offer_fn, scheduler, T, seed, fec_mode='auto'):
    """One deterministic run. fec_mode: 'auto' (tierCtl) | 'on' (floor K=20) |
    'off' (no parity). Returns a metrics dict."""
    rng = random.Random(seed)
    paths = [Path(sp) for sp in specs]
    for i, p in enumerate(paths):
        p.idx = i
    N = len(paths)
    scheduler.reset(N)
    snaps = [PathState() for _ in range(N)]

    frames = {}                 # seq -> (send_time, path_idx, arrival|None)
    groups = []                 # (start, K, [member seqs], parity_arrival|None)
    next_seq = 0
    frac = 0.0

    # FEC / tierCtl state
    tier = TierCtl()
    K = 0
    g_members = []              # open TX group members (seqs)
    g_start = None
    sLossE = 0.0                # smoothed observed link loss (%)
    wSeen = wLinkLost = 0.0     # per-window: transmitted data frames / link-lost
    lossPeer = 0.0
    k_samples = []

    # flap tracking: per-window primary (most-assigned path), committed with a
    # hysteresis band so a near-tie does not register as a role change. A flap =
    # the committed primary genuinely changing (e.g. a collapse promotion). A
    # good adaptive scheduler holds this near 0; a blind one that can never
    # re-role also reads 0 (its failure shows up in delivered throughput).
    FLAP_MARGIN = 1.25
    win_counts = Counter()
    committed_primary = None
    flaps = 0

    offer_sum = 0.0; offer_ticks = 0
    nRep = REPORT; nStep = 0.05
    nticks = int(round(T / DT))

    def emit_parity(now):
        nonlocal g_members, g_start
        pkt = Pkt(-1, is_parity=True)
        idx = scheduler.schedule(now, snaps, pkt)
        if idx < 0 or idx >= N or not paths[idx].alive():
            idx = _fallback(paths)
        parr = None
        if idx is not None:
            parr, _ = paths[idx].send(now, rng)     # parity consumes capacity
            paths[idx].assigned += 1
        groups.append((g_start, K, list(g_members), parr))
        g_members = []; g_start = None

    for tk in range(nticks):
        now = tk * DT
        for p in paths:
            p.update(now)
        for i, p in enumerate(paths):
            p.state(now, snaps[i])

        # ---- offer -> integer frames this tick ----
        offer = offer_fn(now)
        offer_sum += offer; offer_ticks += 1
        frac += offer * DT / PKT_KB
        nfr = int(frac); frac -= nfr

        for _ in range(nfr):
            seq = next_seq; next_seq += 1
            pkt = Pkt(seq, is_parity=False)
            idx = scheduler.schedule(now, snaps, pkt)
            if idx < 0 or idx >= N or not paths[idx].alive():
                idx = _fallback(paths)
            arr, cause = (None, 'drop')
            if idx is not None:
                arr, cause = paths[idx].send(now, rng)
                paths[idx].assigned += 1
                win_counts[idx] += 1
            frames[seq] = (now, idx, arr)
            # ---- FEC link-loss estimator input (A7: skip congestion drops) ----
            if cause != 'drop':
                wSeen += 1
                if cause == 'loss':
                    wLinkLost += 1
            # ---- TX FEC group assembly ----
            if K > 0:
                if g_start is None:
                    g_start = seq
                g_members.append(seq)
                if len(g_members) == K:
                    emit_parity(now)

        # ---- reporter window (500ms): observed link loss -> EWMA ----
        if now >= nRep:
            nRep += REPORT
            if wSeen > 0:
                sLossE = sLossE * 0.7 + (wLinkLost / wSeen * 100.0) * 0.3
            wSeen = wLinkLost = 0.0
            # flap accounting (hysteretic) on the report cadence
            if win_counts:
                leader = max(win_counts, key=lambda k_: win_counts[k_])
                if committed_primary is None:
                    committed_primary = leader
                elif leader != committed_primary and \
                        win_counts[leader] > win_counts[committed_primary] * FLAP_MARGIN:
                    committed_primary = leader
                    flaps += 1
            win_counts = Counter()

        # ---- tierCtl @20Hz ----
        if now >= nStep:
            nStep += 0.05
            if fec_mode == 'off':
                K = 0
            else:
                lp = min(200, int(sLossE * 2 + 0.5)); lossPeer = lp / 2.0
                nk = tierK(lossPeer)
                newK, changed = tier.step(K, nk)
                if fec_mode == 'on' and newK == 0:
                    newK = 20; changed = changed or (K != 20)
                if changed and newK != K:
                    K = newK
                    g_members = []; g_start = None    # abort open group (SetK)
            k_samples.append(K)

    # =========================================================================
    # RECEIVER post-pass: FEC recovery -> reorder -> metrics
    # =========================================================================
    delivered_items = []        # (arrival_time, seq) reaching the reorder ring
    recovered = 0
    for seq, (st, idx, arr) in frames.items():
        if arr is not None:
            delivered_items.append((arr, seq))
    if fec_mode != 'off':
        for (start, k, members, parr) in groups:
            if parr is None or k <= 0:
                continue
            missing = [m for m in members if frames[m][2] is None]
            if len(missing) != 1:
                continue                        # recover exactly-1-loss only
            pieces = [parr] + [frames[m][2] for m in members if frames[m][2] is not None]
            rec_t = max(pieces)                 # reconstructable when last piece in
            delivered_items.append((rec_t, missing[0]))
            recovered += 1

    send_time = {seq: frames[seq][0] for seq in frames}
    release, rx_skips, max_depth = reorder_release(delivered_items, REORDER_HOLD)

    # ---- metrics (post-warmup) ----
    Teff = T - WARMUP
    lat = []
    deliv_data = 0
    for seq, rt in release.items():
        if send_time[seq] > WARMUP:
            deliv_data += 1
            lat.append((rt - send_time[seq]) * 1000.0)
    lat.sort()
    def pct(p):
        if not lat: return 0.0
        return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))]

    delivered_kbps = deliv_data * PKT_KB / Teff
    # ideal ceiling: sum of true effective capacities (time-averaged), capped
    # by what was actually offered.
    sum_eff = sum(p.eff_integral for p in paths) / T
    avg_offer = offer_sum / max(1, offer_ticks)
    ceiling = min(avg_offer, sum_eff)
    eff_pct = 100.0 * delivered_kbps / ceiling if ceiling > 0 else 0.0

    util = []
    for p in paths:
        carried = p.serviced * PKT_KB
        util.append(100.0 * carried / p.cap_integral if p.cap_integral > 0 else 0.0)

    # steady K tail (operating FEC tier)
    ktail = Counter(k_samples[len(k_samples)//4:])
    k_oper = ktail.most_common(1)[0][0] if ktail else 0

    sent_data = next_seq
    path_drops = sum(p.taildrops + p.rndlost for p in paths)

    return {
        'scheduler': scheduler.name,
        'delivered_kbps': delivered_kbps,
        'ceiling_kbps': ceiling,
        'offer_kbps': avg_offer,
        'sum_eff_cap': sum_eff,
        'eff_pct': eff_pct,
        'p50_ms': pct(0.50),
        'p95_ms': pct(0.95),
        'reorder_depth': max_depth,
        'rx_skips': rx_skips,
        'flaps': flaps,
        'util': util,
        'sent_data': sent_data,
        'deliv_data': deliv_data,
        'recovered': recovered,
        'path_drops': path_drops,
        'k_oper': k_oper,
    }


def _fallback(paths):
    for p in paths:
        if p.alive():
            return p.idx
    return None


# =============================================================================
# Scenario battery  (speed-mode.md Method step 2)
# =============================================================================
class Scenario:
    def __init__(s, name, specs, offer_fn, T, note='', fec='auto'):
        s.name = name; s.specs = specs; s.offer_fn = offer_fn
        s.T = T; s.note = note; s.fec = fec

def const(v):
    return lambda t: v

def scenarios():
    S = []

    # 1) single-path low load: offer well under one path; N=2 available.
    S.append(Scenario(
        "single-lowload",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(1500, 45, 5.0, 0.0)],
        const(900), 8.0,
        "offer 900 < best 2000; expect ~1 path, low latency, ~0 reorder"))

    # 2) overspill aggregate (heterogeneous cap + RTT): the HoL demonstrator.
    S.append(Scenario(
        "overspill-het",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(500, 120, 2.0, 0.0)],
        const(2200), 8.0,
        "offer 2200 > best 2000 < sum 2500; RR overloads slow path (HoL)"))

    # 3) path collapse mid-run: path0 2000->600 at t=4 (S3 case, re-roling).
    S.append(Scenario(
        "collapse",
        [PathSpec(2000, 40, 1.0, 0.0, cap_fn=lambda t: 2000 if t < 4.0 else 600),
         PathSpec(1500, 50, 2.0, 0.0)],
        const(2600), 10.0,
        "path0 cap 2000->600 @4s; expect primary promotion, 1 flap"))

    # 4) heavy-jitter path.
    S.append(Scenario(
        "heavy-jitter",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(2000, 35, 40.0, 0.0)],
        const(3000), 8.0,
        "path1 jitter sigma=40ms; reorder from jitter, not queue"))

    # 5) lossy path (FEC-cost): path1 5% loss -> tierCtl to strong tier.
    S.append(Scenario(
        "lossy",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(1500, 40, 2.0, 0.05)],
        const(2800), 10.0,
        "path1 5% loss; auto-FEC should reach K=8/12 and recover"))

    # 6) N=3 overspill.
    S.append(Scenario(
        "overspill-N3",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(1200, 55, 3.0, 0.0),
         PathSpec(800, 90, 4.0, 0.0)],
        const(3600), 8.0,
        "N=3, offer 3600 > best 2000 < sum 4000"))

    # 7) N=4 overspill.
    S.append(Scenario(
        "overspill-N4",
        [PathSpec(2000, 30, 1.0, 0.0), PathSpec(1500, 45, 2.0, 0.0),
         PathSpec(1000, 70, 3.0, 0.0), PathSpec(600, 110, 5.0, 0.0)],
        const(4600), 8.0,
        "N=4, offer 4600 > best 2000 < sum 5100"))

    return S


# =============================================================================
# Reporting
# =============================================================================
SEEDS = 8

def agg(specs, offer_fn, scheduler, T, fec):
    """Mean over SEEDS deterministic runs."""
    runs = [simulate(specs, offer_fn, scheduler, T, sd, fec) for sd in range(SEEDS)]
    m = {}
    keys = ['delivered_kbps', 'ceiling_kbps', 'offer_kbps', 'sum_eff_cap',
            'eff_pct', 'p50_ms', 'p95_ms', 'reorder_depth', 'rx_skips',
            'flaps', 'recovered', 'path_drops']
    for k in keys:
        m[k] = sum(r[k] for r in runs) / len(runs)
    m['util'] = [sum(r['util'][i] for r in runs) / len(runs)
                 for i in range(len(specs))]
    m['k_oper'] = Counter(r['k_oper'] for r in runs).most_common(1)[0][0]
    m['sent_data'] = sum(r['sent_data'] for r in runs) / len(runs)
    return m

def run_report(scheds=None):
    scheds = scheds or BASELINES
    print("=" * 100)
    print("N-PATH SPEED-MODE SCHEDULER EMULATOR  --  baseline validation")
    print(f"  DT={DT*1000:.0f}ms  PKT={PKT_KB}kb  tail-drop>{DROP_Q*1000:.0f}ms  "
          f"reorderHold={REORDER_HOLD*1000:.0f}ms  seeds={SEEDS}  (deterministic)")
    print("  deliv=in-order post-FEC kb/s | ceil=min(offer, sum eff-cap) | "
          "eff%=deliv/ceil | p50/95=in-order latency | rdepth=reorder buffer")
    print("=" * 100)

    for sc in scenarios():
        caps = ", ".join(f"P{i}={s.cap0}kb/{s.rtt_ms:.0f}ms/j{s.jitter_ms:.0f}/l{s.loss*100:.0f}%"
                         for i, s in enumerate(sc.specs))
        print(f"\n### {sc.name}  (N={len(sc.specs)})  {sc.note}")
        print(f"    paths: {caps}   offer~{sc.offer_fn(sc.T/2):.0f}kb/s  fec={sc.fec}")
        print(f"    {'scheduler':<13} {'deliv':>7} {'ceil':>6} {'eff%':>5} "
              f"{'p50':>6} {'p95':>7} {'rdep':>5} {'skips':>6} {'flap':>4} "
              f"{'rcov':>5} {'K':>3}  util%")
        for scd in scheds:
            m = agg(sc.specs, sc.offer_fn, scd, sc.T, sc.fec)
            util_s = "/".join(f"{u:.0f}" for u in m['util'])
            print(f"    {scd.name:<13} {m['delivered_kbps']:>7.0f} "
                  f"{m['ceiling_kbps']:>6.0f} {m['eff_pct']:>4.0f}% "
                  f"{m['p50_ms']:>5.0f} {m['p95_ms']:>6.0f} "
                  f"{m['reorder_depth']:>5.0f} {m['rx_skips']:>6.0f} "
                  f"{m['flaps']:>4.1f} {m['recovered']:>5.0f} "
                  f"{m['k_oper']:>3} {'':1}{util_s}")

    print("\n" + "=" * 100)
    print("SANITY CHECKS (harness measures the throughput/latency/reorder trade)")
    _sanity()
    print("=" * 100)

def _sanity():
    """Assert the doc's qualitative signatures, each in the regime where it
    manifests: the HoL trap + weighted's aggregation under OVERSPILL; minRTT's
    latency win at LOW LOAD; minRTT's aggregation failure under LARGE overspill;
    FEC engagement on a LOSSY path."""
    def get(name, sched):
        sc = [s for s in scenarios() if s.name == name][0]
        return agg(sc.specs, sc.offer_fn, sched, sc.T, sc.fec), sc

    ov, sc_ov = get("overspill-het", RoundRobin())
    ov_w, _ = get("overspill-het", WeightedCapacity())
    best_ov = max(s.cap0 for s in sc_ov.specs)
    lo_r, _ = get("single-lowload", RoundRobin())
    lo_m, _ = get("single-lowload", MinRTT())
    big_w, sc_big = get("overspill-N4", WeightedCapacity())
    big_m, _ = get("overspill-N4", MinRTT())
    best_big = max(s.cap0 for s in sc_big.specs)
    ls_w, _ = get("lossy", WeightedCapacity())

    checks = [
        ("overspill: RR reorder depth > weighted (HoL trap)",
         ov['reorder_depth'] > ov_w['reorder_depth']),
        ("overspill: RR p95 latency > weighted (HoL trap)",
         ov['p95_ms'] > ov_w['p95_ms']),
        ("overspill: weighted aggregates past best single path",
         ov_w['delivered_kbps'] > best_ov),
        ("low-load: min-rtt p95 <= RR p95 (latency win, no needless spread)",
         lo_m['p95_ms'] <= lo_r['p95_ms']),
        ("low-load: min-rtt reorder <= RR reorder (single clean path)",
         lo_m['reorder_depth'] <= lo_r['reorder_depth']),
        ("big overspill: weighted delivers >> min-rtt (aggregation win)",
         big_w['delivered_kbps'] > big_m['delivered_kbps'] * 1.5),
        ("big overspill: min-rtt does NOT aggregate (~ best single path)",
         big_m['delivered_kbps'] < best_big * 1.15),
        ("lossy path: auto-FEC engages (K>0) and recovers frames",
         ls_w['k_oper'] > 0 and ls_w['recovered'] > 0),
    ]
    allok = True
    for label, ok in checks:
        allok = allok and ok
        print(f"    [{'PASS' if ok else 'FAIL'}] {label}")
    print(f"    ---- {'ALL SANITY CHECKS PASS' if allok else 'SANITY FAILURES'} ----")
    print(f"    overspill-het  RR: deliv={ov['delivered_kbps']:.0f} p95={ov['p95_ms']:.0f} rdep={ov['reorder_depth']:.0f}"
          f"  |  WC: deliv={ov_w['delivered_kbps']:.0f} p95={ov_w['p95_ms']:.0f} rdep={ov_w['reorder_depth']:.0f}")
    print(f"    single-lowload RR: p95={lo_r['p95_ms']:.0f} rdep={lo_r['reorder_depth']:.0f}"
          f"  |  MR: p95={lo_m['p95_ms']:.0f} rdep={lo_m['reorder_depth']:.0f}")
    print(f"    overspill-N4   WC: deliv={big_w['delivered_kbps']:.0f}  |  MR: deliv={big_m['delivered_kbps']:.0f}"
          f"  (best single path={best_big:.0f})")
    print(f"    lossy          WC: K={ls_w['k_oper']} recovered={ls_w['recovered']:.0f}")
    return allok


if __name__ == '__main__':
    run_report()
