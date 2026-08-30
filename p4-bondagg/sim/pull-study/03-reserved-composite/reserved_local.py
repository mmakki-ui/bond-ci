#!/usr/bin/env python3
# =============================================================================
# reserved_local.py -- SCHEDULER D  (sched='D')  AND  D'  (sched='Dp').
#   A byte-for-byte copy of reserved_dp.py (scheduler D + pull/redundant self-
#   checks, all kept INTACT) with ONE addition: sched='Dp', the D' candidate.
#
# The product owner's proposal, measured model-first on the SAME validated
# physics (nsched_model, imported UNMODIFIED) and the SAME two-stage rig +
# reference schedulers (pull / A=ewma-cap / push / oracle) that validated the
# datapath, so every number here is paired and apples-to-apples.
#
# =========================== THE CANDIDATE (D', sched='Dp') ==================
# D' is the HARDWARE-ROBUST variant of D: the mirror-arm decision uses NO
# nominal cap0 anywhere -- the yardstick is PURELY MEASURED local headroom.
# Motivation: on real links cap0 (the interface nominal, known at bind time)
# can OVERSTATE a spotty link's true delivered rate, so a cap0-referenced health
# test (D's `drain_ewma >= 0.75*cap0`) can mis-classify.  D' throws cap0 out of
# the decision path entirely and judges each host against ITS OWN recent best.
#
# ONE work-conserving admission loop, TWO frame classes:
#   NATIVE    : plain PULL -- head frame to the hungriest drainable path while
#               local_ms < target.  Byte-for-byte the validated pull admission
#               (unthrottled: NO reserve carve-out, NO (1-r) native cap).  The
#               one-sided delivered-rate cap that the SHIPPED datapath layers on
#               native admission is inherited as-is -- it is native's own
#               production feature, not part of this candidate's novelty, and in
#               this clean-isolation rig native reduces to the pull baseline
#               (so the degenerate cases reprint pull rows byte-for-byte).
#   DUPLICATE : this candidate's gate.  A frame drawn natively onto an AT-RISK
#               (spotty-class, currently-carrying) path is duplicated onto a HOST
#               iff, from PURELY MEASURED LOCAL signals (NO nominal cap0):
#                 (1) local_ms(host) < target/2  -- genuine LOCAL socket headroom;
#                 (2) drain_ewma[host] >= 0.75 * WMAX, WMAX = a short windowed-MAX
#                     (DRAIN_WIN) of that host's OWN recent drain_ewma -- i.e. the
#                     host is draining near its OWN recent best.  D compared
#                     drain_ewma to the NOMINAL cap0 (which can OVERSTATE a spotty
#                     link's true rate); D' makes the yardstick self-relative, so
#                     cap0 never enters the decision (the hardware-robust variant).
#               NO reserve fraction r, NO mir_budget/tot_budget accounting, NO TTL
#               knob: a duplicate stays eligible for exactly the REORDER-RING HOLD
#               (dup_ttl == finalize's hold, first-copy-wins window), then ages out.
#               Work-conserving: once the gate opens the copy is admitted, bounded
#               only by the host's own local ms-gate (re-checked at admit).
#   CAVEAT (measured & reported below): the two gate signals are PURELY LOCAL, and
#               in the MID rig the local socket is BLIND to the hidden downstream --
#               so this gate cannot detect a steady host's true load there and does
#               NOT arm ~0 at high load in the MID blind spot (see validation).
#   N-generic  : host / at-risk range over range(N); no privileged path.
# Degenerate behaviours (REQUIRED, verified):
#   all-steady -> no at_risk source          -> never armed -> pull, armed_frac 0.
#   all-spotty -> every alive path is at_risk -> no host     -> pull, armed_frac 0.
#
# =========================== THE IDEA (scheduler D) ==========================
# =========================== THE IDEA (scheduler D) ==========================
# Pure client-side PULL over ONE shared pool across N paths (the validated local
# ms-gate), PLUS:
#   (a) RESERVE a static fraction r of the AGGREGATE currently-healthy capacity,
#       spread across WHICHEVER paths are healthy right now.  The reserve is
#       OPEN-LOOP: it is a fraction of each healthy host's NOMINAL cap0 (config,
#       known at bind time from the interface), NOT of any runtime delivered-rate
#       meter.  Realised as a native admission rate-cap of (1-r)*cap0 on each
#       host plus a mirror rate-budget of r*cap0 on each host.  There is NO
#       privileged "eth": the host set is every path that is HEALTHY this tick.
#   (b) Continuously MIRROR every packet drawn onto an AT-RISK source path onto
#       the reserve headroom of the healthy hosts.  "At-risk" = PATH IDENTITY:
#       a path whose interface class is spotty/high-variance (a cell/USB tether)
#       that is currently carrying traffic.  NO oracle, NO delivered-rate meter,
#       NO ack ledger -- the spotty path's frames are duplicated PRE-EMPTIVELY,
#       so an invisible mid-network stall is TOLERATED (the frame is already on a
#       healthy host) rather than DETECTED.
#   (c) FIRST-COPY-WINS via the existing reorder ring (arr[seq] = min arrival).
#
# =========================== N-GENERICITY (the point) ========================
# Nothing here is hardcoded to 2 or to a named path:
#   * source set  = { i : spotty_class[i] and alive[i] }        (per-path, dynamic)
#   * host set    = { i : healthy[i] and not at_risk[i] }       (per-path, dynamic)
#   * reserve     = r * sum(cap0[h] for h in hosts)             (over the live host set)
#   * mirror is SPREAD across all hosts with reserve room (hungriest-first), so
#     the insurance rides whatever mix of links happens to be healthy now.
# Degenerate behaviours fall out for free:
#   * all-steady  (no spotty_class path)  -> source set empty -> reserve never
#     armed -> native uses the FULL pipe -> D is byte-for-byte pull (no-op, 0 cost).
#   * all-spotty  correlated               -> when every path stalls together the
#     host set is EMPTY -> the reserve cannot cover -> honest loss (== pull).
#   * all-spotty  independent              -> a momentarily-healthy spotty path
#     hosts the mirror of a stalled sibling -> partial coverage.
#
# reference schedulers (pull / ewma / push / oracle) are the VALIDATED
# ackclock_sim.Sim implementations, run with mirror=False so the ONLY mirroring
# in the study is D's reserve (clean isolation).  'redundant' = full duplication
# on every healthy path (the max-cost / no-aggregation ceiling), implemented here.
# =============================================================================
import math, random
from collections import deque
import nsched_model as M
from ackclock_sim import Stage, HUGE, tether_cap, eth_cap, med, agg

PKT_KB = M.PKT_KB; DT = M.DT; QMAX_MS = M.QMAX_MS; NLAG = M.NLAG
reorder_release = M.reorder_release

# ---- meter-free classifier constants (all LOCAL / config, no far-end signal) --
HEALTH_FRAC = 0.75     # host must be draining >= 75% of its nominal cap0 locally
DRAIN_TAU   = 0.10     # local drain EWMA (~100ms), pull's own lag-free egress est
REGEN       = 0.02     # idle-socket probe-up toward nominal (pull's regen term)

# ---- D' (sched='Dp') classifier constants -- PURELY MEASURED local, NO cap0 ---
DUP_HEALTH_FRAC = 0.75  # host's drain_ewma must be >= 75% of its OWN recent
                        # windowed-MAX drain_ewma (self-relative, cap0-free health)
DRAIN_WIN       = 0.50  # horizon (s) of that windowed-MAX of the host's own drain_ewma


class SimD:
    """PULL + N-generic reserved-mirror (sched='D'), the D' hardware-robust
    candidate (sched='Dp'), full 'redundant', or a self-check 'pull'.
    D  : reserve_frac r in [0,1); ttl_ms bounds mirror eligibility; host-health
         referenced to nominal cap0 (HEALTH_FRAC*cap0); reserve budget r*cap0.
         Sweeping (r, ttl) is the honest reserve-sizing sweep.
    Dp : NO r, NO budget, NO ttl knob (dup_ttl == reorder-ring hold), NO cap0 --
         host-health is PURELY MEASURED (local_ms<target/2 AND drain_ewma near the
         host's OWN windowed-MAX drain).  reserve_frac/ttl_ms are ignored for Dp."""

    def __init__(s, path_defs, offer_fn, T, seed, sched='D', reserve_frac=0.25,
                 ttl_ms=200.0, target_ms=40.0, lat_bias=False, maxq_ms=300.0,
                 strict_partition=False, spotty_can_host=False):
        s.defs = path_defs; s.offer_fn = offer_fn; s.T = T
        s.rng = random.Random(seed)
        s.N = len(path_defs); s.sched = sched
        s.r = reserve_frac; s.ttl = ttl_ms / 1000.0
        s.strict_partition = strict_partition
        s.spotty_can_host = spotty_can_host   # let a momentarily-healthy spotty path host
        s.target_ms = target_ms; s.lat_bias = lat_bias
        s.spotty = [bool(d.get('spotty', False)) for d in path_defs]
        s.cap0 = [d['cap_fn'](0.0) for d in path_defs]        # NOMINAL cap (config)
        s.local = [Stage(owd_ms=d['loc_owd'],
                         jit_ms=(d['jit'] if d.get('jit_stage') == 'local' else 0.0))
                   for d in path_defs]
        s.down = [Stage(owd_ms=d['down_owd'],
                        jit_ms=(d['jit'] if d.get('jit_stage', 'down') == 'down' else 0.0),
                        qmax_ms=d.get('down_qmax', QMAX_MS)) for d in path_defs]
        s.drain_ewma = [d['cap_fn'](0.0) for d in path_defs]  # LOCAL egress est (lag-free)
        # Dp: per-host FIFO of (t, drain_ewma) for the windowed-MAX self-relative
        # health test.  D judged host-health against the NOMINAL cap0, which on real
        # links can OVERSTATE a spotty path's true rate; D' throws cap0 out and
        # judges drain_ewma against the host's OWN recent windowed-MAX instead.
        # Populated only when sched=='Dp' -> D/pull/redundant code paths untouched.
        s.drain_win = [deque() for _ in range(s.N)]
        # Dp: the duplicate's TTL is NOT a knob -- it is exactly the reorder-ring
        # hold (finalize's first-copy-wins window), derived from owd/jit geometry.
        owds_i = [d['down_owd'] + d['loc_owd'] for d in path_defs]
        jits_i = [d['jit'] for d in path_defs]
        s.dup_ttl = min(0.35, max(0.08,
                        ((max(owds_i) - min(owds_i)) + 3.0 * max(jits_i) + 130.0) / 1000.0))
        s.fifo = deque(); s.next_seq = 0; s.frac = 0.0
        s.enq = {}; s.arr = {}; s.sent_on = {}
        s.assigned = [0] * s.N
        s.maxq_kb = (maxq_ms / 1000.0) * sum(s.cap0)
        s.qdrops = 0; s.offered_post = 0; s.warm = 1.0
        s.mirror_q = deque()             # (seq, enq, queued_t)  at-risk frames awaiting a copy
        s.res_tx = 0                     # mirror copies actually transmitted
        s.mir_offered = 0                # at-risk frames that entered the mirror_q
        s.mir_aged = 0                   # mirror_q frames dropped by TTL (never covered)
        s.armed_ticks = 0                # ticks the reserve was armed (>=1 source & >=1 host)
        s.nticks = 0
        s.hol_block_events = 0           # ticks the in-order frontier stalled with a later seq delivered
        s._front_lo = 0; s._maxarr = -1

    # ---- role classification (all meter-free: identity + LOCAL drain) ----------
    def _local_ms(s, i):
        return s.local[i].backlog_kb / max(1.0, s.drain_ewma[i]) * 1000.0

    def _drain_wmax(s, i):
        # Dp: the MAX of host i's OWN drain_ewma over the last DRAIN_WIN seconds
        # (its recent best local egress).  Self-relative -- NO cap0, no far-end.
        dw = s.drain_win[i]
        return max(v for (_, v) in dw) if dw else s.drain_ewma[i]

    def run(s):
        nt = int(round(s.T / DT)); s.nticks = nt
        aE = math.exp(-DT / DRAIN_TAU)
        for tk in range(nt):
            now = tk * DT
            lcaps = [s._local_cap(i, now) for i in range(s.N)]
            dcaps = [s.defs[i]['down_cap_fn'](now) for i in range(s.N)]
            # ---- offer -> pooled send-FIFO (app/seq order) ----
            offer = s.offer_fn(now)
            s.frac += offer * DT / PKT_KB
            nfr = int(s.frac); s.frac -= nfr
            for _ in range(nfr):
                seq = s.next_seq; s.next_seq += 1
                s.fifo.append(seq); s.enq[seq] = now; s.arr[seq] = None
                s.sent_on[seq] = set()
                if now > s.warm:
                    s.offered_post += 1
            while len(s.fifo) * PKT_KB > s.maxq_kb:
                seq = s.fifo.popleft(); s.qdrops += 1

            alive = [lcaps[i] > 0 for i in range(s.N)]
            # source  = spotty-CLASS path currently carrying traffic (identity, meter-free)
            at_risk = [s.spotty[i] and alive[i] for i in range(s.N)]
            if s.sched == 'Dp':
                # ----- D' host-health: PURELY MEASURED local, NO cap0 -----------
                # Track each host's OWN recent drain_ewma; a host qualifies only
                # when (1) it has genuine LOCAL headroom (local_ms < target/2) AND
                # (2) it is draining near its OWN windowed-MAX (drain_ewma >=
                # 0.75*WMAX).  The yardstick never touches cap0 -- a spotty link
                # whose nominal cap0 overstates its true rate cannot be mis-judged.
                for i in range(s.N):
                    dw = s.drain_win[i]
                    dw.append((now, s.drain_ewma[i]))
                    while dw and dw[0][0] < now - DRAIN_WIN:
                        dw.popleft()
                healthy = [alive[i] and s._local_ms(i) < 0.5 * s.target_ms
                           and s.drain_ewma[i] >= DUP_HEALTH_FRAC * s._drain_wmax(i)
                           for i in range(s.N)]
                # host = a currently-healthy STEADY-class path (no privileged path;
                # host/at-risk both range over range(N)).  A spotty path is never a
                # host: its own local health does not prove its hidden downstream.
                host = [healthy[i] and not at_risk[i] for i in range(s.N)]
                armed = (any(at_risk) and any(host))
            else:
                # healthy = alive, local socket not backlogged, draining near nominal
                healthy = [alive[i] and s._local_ms(i) < s.target_ms
                           and s.drain_ewma[i] >= HEALTH_FRAC * s.cap0[i]
                           for i in range(s.N)]
                # host    = a currently-healthy path.  Default: STEADY-class only, because
                # in the MID blind spot a spotty path's LOCAL health does not prove its
                # (hidden) downstream is healthy -- mirroring onto it may just die again.
                # spotty_can_host=True relaxes this so a momentarily-healthy spotty path
                # may host a stalled sibling (the all-spotty-independent coverage test).
                if s.spotty_can_host:
                    host = [healthy[i] for i in range(s.N)]
                else:
                    host = [healthy[i] and not at_risk[i] for i in range(s.N)]
                armed = (s.sched == 'D' and s.r > 0.0
                         and any(at_risk) and any(host))
            if armed:
                s.armed_ticks += 1
            # WORK-CONSERVING open-loop reserve, sized off each host's NOMINAL cap0.
            # Native is PURE PULL (unchanged) -- it never yields to the reserve.  The
            # mirror rides only the NOMINAL spare native leaves this tick (offer cap
            # cap0*DT, static/config, meter-free), and at most r*cap0*DT of it.  So
            # the reserve costs ~0 when a host is busy with native (e.g. while a
            # spotty path is stalled and pull is already rerouting onto the host),
            # and spends up to r of the host only when genuine nominal slack exists.
            #   strict_partition=True reverts to a HARD (1-r) native throttle (the
            #   naive "carve it out" reading) -- kept as an ablation; it starves the
            #   host when a stalled source dumps load onto it (measured, net-negative).
            # Dp uses NONE of this: mir_budget stays 0, tot_budget/nat_cap stay HUGE
            # (native = pure unthrottled pull); the duplicate is bounded ONLY by the
            # host's own local ms-gate, checked at admit time in PIECE 2.
            mir_budget = [0.0] * s.N; tot_budget = [HUGE] * s.N
            nat_cap = [HUGE] * s.N
            if armed and s.sched == 'D':
                for i in range(s.N):
                    if host[i]:
                        mir_budget[i] = s.r * s.cap0[i] * DT
                        tot_budget[i] = s.cap0[i] * DT
                        if s.strict_partition:
                            nat_cap[i] = (1.0 - s.r) * s.cap0[i] * DT
            nat_kb = [0.0] * s.N; mir_kb = [0.0] * s.N

            # ---------------- PIECE 1: native PULL admission --------------------
            def room(i):
                if not alive[i] or s._local_ms(i) >= s.target_ms:
                    return False
                return nat_kb[i] + PKT_KB <= nat_cap[i] + 1e-9
            guard = 0
            while s.fifo and guard < 200000:
                guard += 1
                if s.sched == 'redundant':
                    # full redundancy: the head frame is offered to EVERY path with
                    # room (identical copies, first-wins).  No aggregation ceiling
                    # above the best single path -- the max-cost robustness anchor.
                    seq = s.fifo[0]; any_room = False
                    for i in range(s.N):
                        if not alive[i] or s._local_ms(i) >= s.target_ms:
                            continue
                        any_room = True
                        if i in s.sent_on[seq]:
                            continue
                        if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                            s.assigned[i] += 1; s.sent_on[seq].add(i)
                    if not any_room:
                        break
                    s.fifo.popleft()
                    continue
                # D / pull: head frame -> hungriest drainable path with native room
                cand = [i for i in range(s.N) if room(i)]
                if not cand:
                    break
                if s.lat_bias:
                    cand.sort(key=lambda i: (s.defs[i]['down_owd'] + s.defs[i]['loc_owd'],
                                             s._local_ms(i)))
                else:
                    cand.sort(key=s._local_ms)
                seq = s.fifo[0]; placed = False
                for i in cand:
                    if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
                        s.fifo.popleft(); s.assigned[i] += 1; s.sent_on[seq].add(i)
                        nat_kb[i] += PKT_KB
                        if armed and at_risk[i]:
                            s.mirror_q.append((seq, s.enq[seq], now))
                            s.mir_offered += 1
                        placed = True; break
                if not placed:
                    break

            # ---------------- PIECE 2: drain the reserve (the mirror) -----------
            # Spread at-risk copies across whichever hosts have reserve room now.
            # Dp: TTL == the reorder-ring hold (dup_ttl, not a knob); host room is
            # bounded ONLY by the host's own local ms-gate (local_ms < target/2),
            # with NO mir_budget/tot_budget accounting (work-conserving duplicate).
            ttl = s.dup_ttl if s.sched == 'Dp' else s.ttl
            if armed and s.mirror_q:
                mguard = 0
                while s.mirror_q and mguard < 200000:
                    mguard += 1
                    seq, enq, qt = s.mirror_q[0]
                    if now - qt > ttl:                   # aged out: exposure window closed
                        s.mirror_q.popleft(); s.mir_aged += 1; continue
                    if s.arr.get(seq) is not None:       # already delivered (native or prior copy)
                        s.mirror_q.popleft(); continue
                    if s.sched == 'Dp':
                        # re-check local headroom at admit time: piling copies onto
                        # the host grows its local backlog, so local_ms rises and the
                        # gate self-closes (work-conserving, no budget accounting).
                        hc = [h for h in range(s.N) if host[h]
                              and h not in s.sent_on[seq]
                              and s._local_ms(h) < 0.5 * s.target_ms]
                    else:
                        hc = [h for h in range(s.N) if host[h]
                              and h not in s.sent_on[seq]
                              and s._local_ms(h) < s.target_ms
                              and mir_kb[h] + PKT_KB <= mir_budget[h] + 1e-9
                              and nat_kb[h] + mir_kb[h] + PKT_KB <= tot_budget[h] + 1e-9]
                    if not hc:
                        break                            # no reserve room this tick; keep for next
                    if s.lat_bias:
                        hc.sort(key=lambda h: (s.defs[h]['down_owd'] + s.defs[h]['loc_owd'],
                                               s._local_ms(h)))
                    else:
                        hc.sort(key=s._local_ms)
                    h = hc[0]
                    if s.local[h].offer(seq, enq, lcaps[h]):
                        mir_kb[h] += PKT_KB; s.sent_on[seq].add(h); s.res_tx += 1
                    s.mirror_q.popleft()
                # trim any stale head left behind
                while s.mirror_q and now - s.mirror_q[0][2] > ttl:
                    s.mirror_q.popleft(); s.mir_aged += 1

            # ---------------- drain stage1 -> stage2 -> deliver -----------------
            for i in range(s.N):
                exited = s.local[i].drain(lcaps[i], now, s.rng)
                for (seq, enq, x1) in exited:
                    s.down[i].offer(seq, enq, dcaps[i])       # downstream taildrop = copy LOST
                delivered = s.down[i].drain(dcaps[i], now, s.rng)
                for (seq, enq, x2) in delivered:
                    if s.arr.get(seq) is None or x2 < s.arr[seq]:
                        s.arr[seq] = x2
                        if seq > s._maxarr:
                            s._maxarr = seq
                if s.local[i].backlog_kb > 1e-6:
                    s.drain_ewma[i] = s.drain_ewma[i] * aE + s.local[i].drain_rate * (1 - aE)
                else:
                    s.drain_ewma[i] += REGEN * (s.cap0[i] - s.drain_ewma[i])
            # HOL diagnostic: in-order frontier blocked while a LATER seq already delivered
            while s._front_lo < s.next_seq and s.arr.get(s._front_lo) is not None:
                s._front_lo += 1
            if s._front_lo < s.next_seq and s.arr.get(s._front_lo) is None \
                    and s._maxarr > s._front_lo:
                s.hol_block_events += 1
        return s.finalize()

    def _local_cap(s, i, t):
        d = s.defs[i]
        lc = d['local_cap_fn'](t)
        if d.get('backpressure'):
            lc = min(lc, d['cap_fn'](t) * d['backpressure'])
        return lc

    def finalize(s):
        owds = [s.defs[i]['down_owd'] + s.defs[i]['loc_owd'] for i in range(s.N)]
        jits = [d['jit'] for d in s.defs]
        hold = min(0.35, max(0.08,
                   ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0))
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
        tdrop = sum(st.taildrops for st in s.down) + sum(st.taildrops for st in s.local)
        return {'gp': gp, 'loss': max(0.0, loss), 'p50': pct(.5), 'p95': pct(.95),
                'p99': pct(.99), 'depth': depth, 'tdrop': tdrop, 'late': late_discard,
                'deliv': deliv_data, 'qdrops': s.qdrops,
                'tshare': s.assigned[0] / (sum(s.assigned) or 1),
                'res_tx': s.res_tx, 'mir_off': s.mir_offered, 'mir_aged': s.mir_aged,
                'hol': s.hol_block_events,
                'armed_frac': s.armed_ticks / max(1, s.nticks)}


# =============================================================================
# ================  N-GENERIC RIG BUILDERS  (arbitrary N & mix)  ==============
# A path archetype is a dict of physical knobs + a 'spotty' identity class.
# build_rig turns a list of archetypes into EDGE or MID two-stage path_defs that
# both SimD and the ackclock reference Sim consume (extra keys are ignored there).
#   EDGE : the spotty cap sits on the LOCAL stage (socket occupancy == truth).
#   MID  : local drains fast+const; the spotty cap is hidden DOWNSTREAM (stage-2),
#          invisible to socket occupancy -- the meter-free blind spot.
# =============================================================================
def cap_trace(base, amp, period, dropouts=(), floor=3000.0, shape=None):
    def f(t):
        for (a, b) in dropouts:
            if a <= t < b:
                return shape if shape is not None else 0.0
        return max(floor, base + amp * math.sin(2 * math.pi * t / period))
    return f

def steady_trace(base, amp, period, phase=1.0):
    return lambda t: base + amp * math.sin(2 * math.pi * t / period + phase)


def build_rig(archetypes, bottleneck='mid', local_mult=20.0):
    """archetypes: list of dicts with keys
         spotty(bool), base, amp, period, dropouts, shape(None|kb),
         loc_owd, down_owd, jit  (owd/jit split follows edge/mid convention)."""
    defs = []
    for a in archetypes:
        if a['spotty']:
            trace = cap_trace(a['base'], a['amp'], a['period'],
                              a.get('dropouts', ()), a.get('floor', 3000.0),
                              a.get('shape', None))
        else:
            trace = steady_trace(a['base'], a['amp'], a['period'], a.get('phase', 1.0))
        if bottleneck == 'edge':
            defs.append(dict(cap_fn=trace, local_cap_fn=trace,
                             loc_owd=a['loc_owd_edge'], down_owd=a['down_owd_edge'],
                             jit=a['jit'], jit_stage='local',
                             backpressure=None, down_cap_fn=lambda t: HUGE,
                             down_qmax=HUGE, spotty=a['spotty']))
        else:
            loc = a['base'] * local_mult
            defs.append(dict(cap_fn=trace,
                             local_cap_fn=(lambda t, _l=loc: _l),
                             loc_owd=a['down_owd_edge'], down_owd=a['loc_owd_edge'],
                             jit=a['jit'], jit_stage='down',
                             backpressure=None, down_cap_fn=trace,
                             down_qmax=QMAX_MS, spotty=a['spotty']))
    return defs


# ---- path archetypes (heterogeneous), owd/jit realistic per class -----------
def cellA(dropouts):
    return dict(spotty=True, base=29000, amp=24000, period=3.1, dropouts=dropouts,
                loc_owd_edge=25.0, down_owd_edge=2.0, jit=25.0)
def cellB(dropouts):
    return dict(spotty=True, base=22000, amp=17000, period=2.3, dropouts=dropouts,
                loc_owd_edge=30.0, down_owd_edge=3.0, jit=28.0)
def cellC(dropouts):
    return dict(spotty=True, base=17000, amp=13000, period=1.9, dropouts=dropouts,
                loc_owd_edge=35.0, down_owd_edge=3.0, jit=30.0)
def wifi(dropouts=()):
    # wifi-as-WAN: mid cap, more jitter than eth, mild swing, no hard dropouts by
    # default -> STEADY class (a reliable-ish host), but lower cap than eth.
    return dict(spotty=False, base=45000, amp=9000, period=4.3, phase=0.5,
                loc_owd_edge=12.0, down_owd_edge=4.0, jit=8.0)
def eth():
    return dict(spotty=False, base=78000, amp=12000, period=5.0, phase=1.0,
                loc_owd_edge=8.0, down_owd_edge=1.0, jit=1.0)

# canonical dropout schedules
DROPS_A = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
DROPS_B = [(a, a + 0.4) for a in (3.8, 6.3)]
DROPS_C = [(a, a + 0.35) for a in (2.2, 4.9, 7.1)]
DROPS_CORR = [(a, a + 0.4) for a in (3.0, 6.0)]        # correlated (shared) stalls
