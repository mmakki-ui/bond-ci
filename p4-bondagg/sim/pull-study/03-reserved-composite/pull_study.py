#!/usr/bin/env python3
# =============================================================================
# pull_study.py  --  PUSH(ETA-argmin) vs PULL(work-conserving/water-filling)
#
# Model study (rule-8 honest): does a lightweight CLIENT-SIDE work-conserving
# PULL scheduler beat the current per-packet push-ETA-argmin for SPOTTY +
# widely-different sources (cell/USB tether + ethernet)?
#
# Reuses the VALIDATED physics from nsched_model.py:
#   * PathProc         : true fluid FIFO queue (kb), 300ms tail-drop, owd,
#                        gaussian jitter, GE burst, base/coupled loss, liveness,
#                        time-varying cap_fn (the stall/dropout/swing injector).
#   * reorder_release  : the validated receiver ring (epoch-Hold flush).
#   * NSim variant='eif_real' : the CURRENT push = Smith-q̂ ETA argmin +
#                        backpressure + control FSM + CapEst + Ctl.  The FULL,
#                        strongest push (not a strawman).
#
# PULL model (honest, client-side, thin server):
#   * one SHARED client-side send FIFO (app byte order = seq order).
#   * each path has a LOCAL uplink buffer occupancy = PathProc.backlog_kb.  For a
#     CLIENT->SERVER uplink the bottleneck buffer physically sits at the client
#     edge (tether/modem/qdisc/socket), so the client observes its fill LAG-FREE
#     (socket backpressure / EWOULDBLOCK).  This is the physical basis for pull
#     reacting faster than push's pong-lagged q̂ -- NOT an idealized oracle.
#   * a path DRAWS the head packet only while its local buffer has room
#     (backlog_kb < LBUF_KB, a fixed socket-buffer byte budget ~ LBUF_MS @ nominal
#     cap).  hungriest-first (lowest buffer-ms) = water-filling; a stalled link
#     (cap->0) drains nothing, its buffer stays full, it stops drawing; healthy
#     links drain the shared FIFO.  If NO path can take the head it WAITS in the
#     shared FIFO (work-conserving: never stranded behind a committed-dead path).
#   * NO pong-q̂, NO Smith predictor, NO CapEst, NO DEAD-detection for
#     scheduling.  Liveness is FREE: a down path returns 'down' on send.
#   * honesty knobs measured: LBUF_MS (buffer depth = stall reaction time vs
#     jitter-smoothing), finite client FIFO bound (maxq), reorder/late_discard
#     cost, client-FIFO wait counted INTO latency (send_time = enqueue instant).
#
# FEC is OFF for both (isolates the SCHEDULER; FEC is an orthogonal layer that
# pull can carry identically).  Physics stall trace is a DETERMINISTIC cap_fn(t)
# shared by both schedulers -> identical stalls; only per-send loss/jitter draws
# differ, averaged over seeds (medians), exactly like nsched's runN discipline.
#
# Run: %LOCALAPPDATA%\Programs\Python\Python312\python.exe pull_study.py [quick]
# =============================================================================
import math, sys, random
from collections import deque
import nsched_model as M

PathProc        = M.PathProc
reorder_release = M.reorder_release
NPathSpec       = M.NPathSpec
NSim            = M.NSim
PKT_KB          = M.PKT_KB
DT              = M.DT
QMAX_MS         = M.QMAX_MS

# =============================================================================
# Shared finalize: identical latency/gp/reorder metric for BOTH schedulers,
# extracted to match nsched_model.NSim._metrics (fec='off' path) EXACTLY.
# frames: seq -> (send_t, idx, arr|None, cause).  send_t = app-offer instant.
# =============================================================================
def finalize(frames, specs, paths, T, offer_rate=None, extra=None):
    deliv_items = [(arr, seq) for seq, (st, idx, arr, c) in frames.items()
                   if arr is not None]
    owds = [sp.owd_ms for sp in specs]
    jits = [paths[i].jit for i in range(len(paths))]
    hold = ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0
    hold = min(0.35, max(0.08, hold))
    release, skips, depth = reorder_release(deliv_items, hold)
    rel_seqs = set(release)
    late_discard = sum(1 for (a, sq) in deliv_items if sq not in rel_seqs)
    WARM = 1.0
    Teff = T - WARM
    lat = []
    deliv_data = 0
    for seq, rt in release.items():
        st = frames[seq][0]
        if st > WARM:
            deliv_data += 1
            lat.append((rt - st) * 1000.0)
    lat.sort()
    def pct(p):
        return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))] if lat else 0.0
    gp = deliv_data * PKT_KB / Teff
    sum_eff = sum(p.eff_integral for p in paths) / T          # ideal ceiling kb/s
    N = len(paths)
    # FAIR loss: offered load is the same offer_fn for push & pull; measure the
    # fraction of the OFFERED (post-warm) byte-rate not delivered as goodput.
    # This captures ALL drops uniformly (backpressure-txdrop that never enters
    # push's frames dict, taildrop, qdrop, link loss, ring late_discard).
    if offer_rate is not None:
        loss_pct = max(0.0, 100.0 * (1.0 - gp / offer_rate))
    else:
        offered = sum(1 for seq, (st, idx, arr, c) in frames.items() if st > WARM)
        loss_pct = 100.0 * (offered - deliv_data) / offered if offered else 0.0
    r = {
        'gp': gp, 'sum_eff': sum_eff, 'util': gp / sum_eff if sum_eff else 0.0,
        'p50': pct(0.50), 'p95': pct(0.95), 'p99': pct(0.99),
        'depth': depth, 'skips': skips, 'late_discard': late_discard,
        'taildrops': sum(p.taildrops for p in paths),
        'deliv': deliv_data, 'loss_pct': loss_pct,
        'release': release,
        'serviced': [paths[i].serviced for i in range(N)],
        'cap_int': [paths[i].cap_integral / T for i in range(N)],   # mean true cap
    }
    if extra:
        r.update(extra)
    return r


# =============================================================================
# PULL / work-conserving scheduler.  Shares PathProc physics + reorder_release.
# =============================================================================
class PullSim:
    def __init__(s, specs, offer_fn, T, seed, lbuf_ms=40.0, lat_bias=False,
                 maxq_ms=300.0, theta=None, gate='bytes', target_ms=40.0):
        s.specs = specs; s.offer_fn = offer_fn; s.T = T
        s.rng = random.Random(seed)
        s.N = len(specs)
        s.paths = [PathProc(sp, i) for i, sp in enumerate(specs)]
        # fixed per-path socket-buffer byte budget ~ LBUF_MS worth at NOMINAL cap
        s.lbuf_kb = [(lbuf_ms / 1000.0) * sp.cap0 for sp in specs]
        s.lat_bias = lat_bias
        # gate='bytes' : admit while socket occupancy (bytes) < lbuf_kb  (pure,
        #   strictly-observable, but a fixed byte buffer overshoots the 300ms
        #   queue bound on a DEGRADED link -> taildrops).
        # gate='ms'    : admit while backlog / LOCAL-drain-rate < target_ms.  The
        #   local drain rate = how fast THIS socket's buffer empties = the client's
        #   OWN egress throughput, measured lag-free (NOT the 350ms-lagged pong
        #   capacity).  Converts the byte buffer to a TIME buffer using only local
        #   info -> kills the degraded-link taildrop without any peer feedback.
        s.gate = gate; s.target_ms = target_ms
        s.drain_ewma = [sp.cap0 for sp in specs]   # local egress kb/s (prior=nominal)
        s.maxq_kb = (maxq_ms / 1000.0) * sum(sp.cap0 for sp in specs)
        if theta is not None:
            s.theta = float(theta)
        else:
            s.theta = random.Random((seed + 1) * 2654435761 & 0xffffffff
                                    ).uniform(-M.THETA_RANGE, M.THETA_RANGE)
        s.fifo = deque()                 # (seq, enq_t) app-order shared queue
        s.next_seq = 0; s.frac = 0.0
        s.frames = {}                    # seq -> (enq_t, idx, arr|None, cause)
        s.assigned = [0] * s.N
        s.qdrops = 0                     # client FIFO overflow drops
        s.fifo_wait_ticks = 0            # sum of ticks packets waited (diag)
        # instrumentation windows
        s.win_assign = [0] * s.N
        s.share_win = []                 # (t, [share_i])
        s.q_trace = [[] for _ in range(s.N)]
        s._offer_sum = 0.0; s._offer_n = 0

    def run(s):
        nticks = int(round(s.T / DT))
        nWin = 0.100
        nextWin = nWin
        for tk in range(nticks):
            now = tk * DT
            for p in s.paths:
                p.update(now, s.rng)
            for i in range(s.N):
                s.q_trace[i].append(s.paths[i].q_ms)
            # ---- offer -> enqueue into shared FIFO (app byte/seq order) ----
            offer = s.offer_fn(now)
            if now > 1.0:
                s._offer_sum += offer; s._offer_n += 1
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append((seq, now))
                s.frames[seq] = (now, -1, None, 'queued')
            # ---- client FIFO bound: overflow -> drop oldest (finite buffer) ----
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                seq, enq = s.fifo.popleft()
                s.frames[seq] = (enq, -1, None, 'qdrop'); s.qdrops += 1
            # ---- PULL: paths draw the head while they have local room ----
            # buffer-ms of path i = backlog_kb / cap (its LOCAL, lag-free fill).
            def room(i):
                if s.gate == 'ms':
                    bl_ms = s.paths[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0
                    return bl_ms < s.target_ms
                return s.paths[i].backlog_kb < s.lbuf_kb[i]
            def fill(i):
                if s.gate == 'ms':
                    return s.paths[i].backlog_kb / max(1.0, s.drain_ewma[i])
                return s.paths[i].backlog_kb / s.lbuf_kb[i]
            guard = 0
            while s.fifo and guard < 100000:
                guard += 1
                cand = [i for i in range(s.N)
                        if s.paths[i].cap > 0.0 and room(i)]
                if not cand:
                    break                                    # all full/stalled
                if s.lat_bias:
                    # hybrid: prefer lower-owd path, tiebreak by socket fill.  owd
                    # is a slow-varying, lag-insensitive estimate (NOT the lagged
                    # q̂) -> cheap; used only to ORDER equally-drainable paths.
                    cand.sort(key=lambda i: (s.paths[i].owd, fill(i)))
                else:
                    # water-filling: hungriest = lowest socket FILL.  In 'bytes'
                    # mode this is pure socket occupancy (SO_SNDBUF / EWOULDBLOCK,
                    # no capacity knowledge).  In 'ms' mode it is backlog / LOCAL
                    # egress-rate EWMA -- the rate is the client's OWN measured
                    # send throughput, lag-free (not the peer's pong capacity).
                    cand.sort(key=fill)
                placed = False
                for i in cand:
                    seq, enq = s.fifo[0]
                    cause, arr, d = s.paths[i].send(now, s.rng, False, s.theta)
                    if cause in ('down', 'taildrop'):
                        continue                             # try next path
                    s.fifo.popleft()
                    s.assigned[i] += 1; s.win_assign[i] += 1
                    s.frames[seq] = (enq, i,
                                     arr if cause == 'ok' else None, cause)
                    placed = True
                    break
                if not placed:
                    break                                    # nobody took head
            s.fifo_wait_ticks += len(s.fifo)
            # ---- LOCAL drain measurement: how many bytes actually left each
            # socket this tick (backlog delta from drain()).  This is the client's
            # OWN egress throughput -- observable lag-free, no peer feedback.  EWMA
            # ~100ms.  For a client-edge (tether/USB) bottleneck it tracks the true
            # link rate; it is NOT the 350ms-lagged pong-derived capacity. --------
            aE = math.exp(-DT / 0.10)                # ~100ms tau
            for i, p in enumerate(s.paths):
                bl0 = p.backlog_kb
                p.drain()
                drained_rate = max(0.0, bl0 - p.backlog_kb) / DT      # kb/s this tick
                # busy-gate: trust the sample as a CAPACITY estimate only when the
                # socket stayed backlogged (drain was rate-limited, not demand-
                # limited).  A stalled socket stays backlogged with drain=0 -> the
                # EWMA decays toward 0 -> ms-gate closes.  All LOCAL, no lag.
                if p.backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i] * aE + drained_rate * (1 - aE)
                elif s.gate == 'ms':
                    # REGEN (probe-up): an idle socket gives no capacity sample, so
                    # a busy-gated estimate can RATCHET stuck-low (a swing trough
                    # locks it, then the tight buffer never lets it re-backlog to
                    # measure recovery -> the path is starved).  Age back toward the
                    # nominal prior when idle -- the local analogue of CapEst's
                    # probe-up/regen.  This is the estimator complexity the time-
                    # gate reintroduces (the byte-gate needs none).
                    s.drain_ewma[i] += 0.02 * (s.paths[i].spec.cap0 - s.drain_ewma[i])
            if now >= nextWin - 1e-9:
                nextWin += nWin
                tot = sum(s.win_assign) or 1
                s.share_win.append((now, [s.win_assign[i] / tot
                                          for i in range(s.N)]))
                s.win_assign = [0] * s.N
        omean = s._offer_sum / s._offer_n if s._offer_n else s.offer_fn(0)
        vn = 'pull_' + s.gate + ('_lat' if s.lat_bias else '')
        return finalize(s.frames, s.specs, s.paths, s.T, offer_rate=omean,
                        extra={'variant': vn,
                               'share': [s.assigned[i] / (sum(s.assigned) or 1)
                                         for i in range(s.N)],
                               'qdrops': s.qdrops,
                               'share_win': s.share_win,
                               'frames': s.frames,
                               'q_trace': s.q_trace})


# =============================================================================
# push wrapper: run NSim(eif_real) and re-key its metrics to the shared schema
# so push and pull are read the SAME way.  NSim already computes gp/p50.. with
# the identical finalize logic (fec='off'); we add util + loss_pct here.
# =============================================================================
def run_push(specs, offer_fn, T, seed, fec='off'):
    m = NSim(specs, offer_fn, T, seed, 'eif_real', fec_mode=fec).run()
    # mean offer post-warm (same basis as pull's fair loss)
    nt = int(round(T / DT))
    osum = 0.0; on = 0
    for tk in range(nt):
        now = tk * DT
        if now > 1.0:
            osum += offer_fn(now); on += 1
    omean = osum / on if on else offer_fn(0)
    m['util'] = m['gp'] / m['sum_eff'] if m['sum_eff'] else 0.0
    m['loss_pct'] = max(0.0, 100.0 * (1.0 - m['gp'] / omean)) if omean else 0.0
    m['variant'] = 'push'
    return m


# =============================================================================
# aggregation over seeds
# =============================================================================
def med(xs):
    s = sorted(xs); n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0

def agg(ms, keys):
    return {k: med([m[k] for m in ms]) for k in keys}

MKEYS = ['gp', 'util', 'loss_pct', 'p50', 'p95', 'p99', 'depth',
         'late_discard', 'taildrops']


# =============================================================================
# Deterministic tether cap trace: swing + hard dropout windows (cap->0).
# =============================================================================
def tether_cap(base=29000.0, amp=24000.0, period=3.1, dropouts=(),
               floor=3000.0):
    def f(t):
        for (a, b) in dropouts:
            if a <= t < b:
                return 0.0                                   # hard stall
        c = base + amp * math.sin(2 * math.pi * t / period)
        return max(floor, c)
    return f

def eth_cap(base=78000.0, amp=12000.0, period=5.0):
    def f(t):
        return base + amp * math.sin(2 * math.pi * t / period + 1.0)
    return f
