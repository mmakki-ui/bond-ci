#!/usr/bin/env python3
# sched_model v2 — offline emulator for the bond-agg rate controller.
# Ctl mirrors paths.go OnQ/tickIncrease EXACTLY (fields, constants,
# branch order). v2: per-frame QTrack jitter emulation (atom-at-zero
# draws, min-tracker with +0.02ms/frame drift, last-frame-per-report),
# N-seed statistical grading. Iterate here; port winners in one edit.
import random, sys

DT = 0.010
REPORT = 0.100
LAG = 0.350
HOLD_MS = 350.0

CongQMs, BigQMs = 40.0, 200.0
IncKbStep, DecMult, BigDec = 150.0, 0.85, 0.7
IncFreeze = 0.600
PKT_KB = 9.79  # 1224B frames

class Ctl:
    def __init__(s, floor, tune):
        s.t = tune
        s.rate = floor * 0.25
        s.floor = floor
        s.capHint = floor
        s.qEwma = 0.0; s.qInit = False
        s.lastDec = -9.0; s.lastBig = -9.0; s.lastInc = 0.0
        s.hqCnt = 0; s.reLearn = False; s.dirtyRep = 0
        s.born = 0.0
        s.qJit = 0.0
        s.prevQ = 0.0
        s.warmed = False
        s.graceLeft = 0
        s.spCnt = 0
        s.events = []
        s.decays = 0

    def _jit(s):
        return s.t['jitK'] * s.qJit if s.t['jitAware'] else 0.0

    def onq(s, now, qms):
        if not s.qInit:
            s.qEwma, s.qInit = qms, True
            return
        prev = s.qEwma
        s.qEwma = s.qEwma * 0.7 + qms * 0.3
        s.qJit = s.qJit * 0.9 + abs(qms - s.qEwma) * 0.1
        if now - s.born < s.t['warmup']:
            return
        g = s.t.get('warmGrace', 0)
        if g and not s.warmed:
            s.warmed = True
            s.graceLeft = g - 1
            s.qEwma = qms; s.qJit = 0.0; s.dirtyRep = 0; s.prevQ = qms
            return
        if s.graceLeft > 0:
            # grace: stall aftermath can arrive LOW-first (stale pong byte
            # before the inflated one) — keep updating state, act on nothing.
            s.graceLeft -= 1
            s.prevQ = qms
            return
        jit = s._jit()
        if qms >= CongQMs + jit:
            s.dirtyRep += 1
        else:
            s.dirtyRep = 0
        spikeThr = max(150.0, s.qEwma + 4 * s.qJit) if s.t['jitAware'] else 150.0
        if qms > spikeThr:
            s.spCnt += 1
        else:
            s.spCnt = 0
        need = s.t.get('spikeConfirm', 1)
        if s.spCnt >= need and prev < 80 + jit:
            if now - s.lastBig > 0.8:
                if s.t.get('hintAtCut') and now - s.lastBig > 1.5:
                    s.capHint = s.rate * 0.9  # cut on a fresh episode IS
                    # the cliff sighting; continuous cut-trains (overload)
                    # excluded by the 1.5s freshness gate
                s.rate *= 0.5
                h = s.capHint * 0.9
                if s.capHint > 0 and s.rate > h:
                    s.rate = h
                s.rate = max(s.rate, s.floor * 0.25)
                s.events.append((now, 'SPIKE', s.rate, qms))
                s.lastBig = now; s.lastDec = now
            return
        eC = CongQMs + jit
        if s.qEwma > eC:
            fresh_cross = prev <= eC and s.dirtyRep >= 2
            if s.t.get('capGate') and (now - s.lastBig < 1.5 or now - s.lastDec < 0.6):
                fresh_cross = False  # crossing against our own undrained
                # backlog is not cliff evidence: kills the hint ratchet
            if fresh_cross:
                s.capHint = s.rate * 0.85
                s.reLearn = False
                s.events.append((now, 'CROSS', s.rate, s.capHint))
            if qms > 200 + jit:
                s.hqCnt += 1
            else:
                s.hqCnt = 0
            gate = s.capHint == 0 or s.rate < s.capHint * 0.6 or (s.t.get('pinDrain', 0) > 0 and s.hqCnt >= s.t['pinDrain'])
            if s.hqCnt >= 3 and now - s.lastBig > 0.8 and gate:
                s.rate = max(s.floor * 0.10, 100.0)
                s.events.append((now, 'DRAIN', s.rate, qms))
                s.capHint = 0; s.reLearn = True
                s.hqCnt = 0; s.lastBig = now; s.lastDec = now
            elif s.qEwma > BigQMs + jit:
                cad = 0.3 if (s.hqCnt >= 3 and gate) else 0.8
                if now - s.lastBig > cad:
                    if s.t.get('hintAtCut') and now - s.lastBig > 1.5:
                        s.capHint = s.rate * 0.9
                    s.rate *= BigDec
                    h = s.capHint * 0.9
                    if s.capHint > 0 and s.rate > h:
                        s.rate = h
                    s.rate = max(s.rate, s.floor * 0.25)
                    s.lastBig = now; s.lastDec = now
            elif now - s.lastDec > 0.2:
                if not (s.t.get('drainHold') and qms < s.prevQ - 5):
                    # decay only while the queue is still BUILDING; riding
                    # the ewma down after a big cut already fixed the cause
                    # just floor-grinds the rate.
                    s.rate = max(s.rate * DecMult, s.floor * 0.25)
                    s.decays += 1
                    s.lastDec = now
        else:
            s.hqCnt = 0
        s.prevQ = qms

    def tick(s, now):
        if now - s.lastInc < 0.2:
            return
        s.lastInc = now
        eC = CongQMs + s._jit()
        if s.qInit and s.qEwma <= eC * 0.6 and now - s.lastDec > IncFreeze:
            step = IncKbStep / 2 if s.reLearn else IncKbStep
            if s.capHint > 0 and s.rate > s.capHint * 0.9:
                step = 10 + s.rate * 0.01
            s.rate = min(s.rate + step, 60000.0)

def run(cap_fn, offer_kb, jit_ms, blip, T, tune, seed):
    random.seed(seed)
    c = Ctl(2000.0, tune)
    backlog = 0.0
    hist = []
    sent_ok = sent_lost = 0.0
    minoff = None
    held = []
    prestall = 0.0
    t = 0.0; nextrep = 0.1
    q_at = []  # true q per step for lag lookup
    while t < T:
        cap = cap_fn(t)
        send = min(offer_kb, c.rate) * DT
        q_ms = backlog / cap * 1000.0
        if q_ms > 300.0:
            sent_lost += send
        else:
            backlog += send
            if q_ms > HOLD_MS:
                sent_lost += send
            else:
                sent_ok += send
        backlog = max(0.0, backlog - cap * DT)
        q_at.append(q_ms)
        hist.append((t, q_ms, c.rate, cap))
        if t >= nextrep:
            nextrep += REPORT
            qlag = q_at[int(max(0.0, t - LAG) / DT)]
            in_blip = blip and blip[0] <= t < blip[0] + blip[1]
            extra = blip[2] if in_blip else 0.0
            # per-frame QTrack over this report window: last frame reports
            nfr = max(1, int(min(offer_kb, c.rate) / PKT_KB / 10.0))
            qm = 0.0
            for _ in range(nfr):
                off = qlag + max(0.0, random.gauss(0, jit_ms)) + extra
                if minoff is None or off < minoff:
                    minoff = off
                else:
                    minoff += 0.02
                qm = max(0.0, off - minoff)
            if in_blip:
                held.append(qm)  # the stall delays the PONGS too: nothing
                # arrives to pre-decay the ewma; it all flushes at once
            else:
                if held:
                    c.onq(t, prestall)  # stale pong byte flushes first
                for h2 in held:
                    c.onq(t, h2)
                held.clear()
                c.onq(t, qm)
                prestall = qm
        c.tick(t)
        t += DT
    return c, hist, sent_ok, sent_lost

def m_common(c, hist, ok, lost, tail_from, cap_true):
    tail = [r for (t, q, r, cp) in hist if t > tail_from]
    mean = sum(tail) / len(tail)
    sd = (sum((x - mean) ** 2 for x in tail) / len(tail)) ** 0.5
    return {
        'mean': mean, 'sd': sd,
        'loss': lost / max(1e-9, ok + lost),
        'spikes': sum(1 for e in c.events if e[1] == 'SPIKE'),
        'drains': sum(1 for e in c.events if e[1] == 'DRAIN'),
        'poison': any(e[1] == 'CROSS' and e[3] < cap_true * 0.75 for e in c.events),
        'decays': c.decays,
    }

def sA(tune, seed):
    c, h, ok, lost = run(lambda t: 2000.0, 4000.0, 0.5, None, 8.0, tune, seed)
    return m_common(c, h, ok, lost, 5.0, 2000.0)

def sB(tune, seed):
    c, h, ok, lost = run(lambda t: 2000.0 if t < 3 else 600.0, 3300.0, 0.5, None, 10.0, tune, seed)
    m = m_common(c, h, ok, lost, 7.5, 600.0)
    rec = [t for (t, q, r, cp) in h if t > 3.0 and q < 80.0]
    m['recover'] = (rec[0] - 3.0) if rec else 99.0
    m['pin'] = sum(DT for (t, q, r, cp) in h if t > 3.0 and q > 300.0)
    return m

def sC(tune, seed):
    c, h, ok, lost = run(lambda t: 2000.0, 4000.0, 0.5, None, 8.0, tune, seed)
    return m_common(c, h, ok, lost, 3.0, 2000.0)

def sD(tune, seed):
    c, h, ok, lost = run(lambda t: 2000.0, 1200.0, 40.0, None, 8.0, tune, seed)
    return m_common(c, h, ok, lost, 5.0, 2000.0)

def sF(tune, seed):
    # startup stall during the ramp: 300ms delay step at t=0.5 for 0.3s,
    # heavy offer — the box's daemon-spinup fingerprint.
    c, h, ok, lost = run(lambda t: 2000.0, 4000.0, 0.5, (1.3, 0.4, 300.0), 8.0, tune, seed)
    return m_common(c, h, ok, lost, 5.0, 2000.0)

def sE(tune, seed):
    c, h, ok, lost = run(lambda t: 2000.0, 1200.0, 0.5, (2.0, 0.3, 300.0), 8.0, tune, seed)
    return m_common(c, h, ok, lost, 5.0, 2000.0)

def agg(fn, tune, n=30):
    ms = [fn(tune, s) for s in range(n)]
    def mean(k): return sum(m[k] for m in ms) / n
    def rate(k): return sum(1 for m in ms if m[k]) / n
    def p95(k):
        v = sorted(m[k] for m in ms); return v[int(0.95 * (n - 1))]
    return ms, mean, rate, p95

def report(tune, label):
    print(f"-- {label} tune={tune}")
    res = {}
    ms, mean, rate, p95 = agg(sA, tune); res['A'] = ok = (1550 <= mean('mean') <= 2100 and rate('poison') == 0 and mean('drains') == 0 and p95('loss') < 0.02)
    print(f"A ramp    {'PASS' if ok else 'FAIL'} mean={mean('mean'):.0f} sd={mean('sd'):.0f} poisonR={rate('poison'):.2f} drains={mean('drains'):.1f} loss95={p95('loss'):.2%}")
    ms, mean, rate, p95 = agg(sB, tune); res['B'] = ok = (p95('recover') < 2.0 and p95('pin') < 1.2 and 400 <= mean('mean') <= 660)
    print(f"B collapse {'PASS' if ok else 'FAIL'} rec95={p95('recover'):.1f}s pin95={p95('pin'):.1f}s tail={mean('mean'):.0f}")
    ms, mean, rate, p95 = agg(sC, tune); res['C'] = ok = (mean('mean') >= 1550 and mean('drains') == 0)
    print(f"C overload {'PASS' if ok else 'FAIL'} mean={mean('mean'):.0f} drains={mean('drains'):.1f}")
    ms, mean, rate, p95 = agg(sD, tune); res['D'] = ok = (rate('poison') == 0 and mean('mean') >= 1100 and mean('sd') < 150 and mean('spikes') <= 0.2 and mean('drains') == 0)
    print(f"D jitter   {'PASS' if ok else 'FAIL'} mean={mean('mean'):.0f} sd={mean('sd'):.0f} poisonR={rate('poison'):.2f} spikes={mean('spikes'):.1f} decays={mean('decays'):.1f} drains={mean('drains'):.2f}")
    dpr = rate('poison'); dspk = mean('spikes')
    ms, mean, rate, p95 = agg(sE, tune); res['E'] = ok = (rate('poison') == 0 and mean('mean') >= 1100 and mean('drains') == 0)
    print(f"E blip     {'PASS' if ok else 'FAIL'} mean={mean('mean'):.0f} poisonR={rate('poison'):.2f} drains={mean('drains'):.2f}")
    ms, mean, rate, p95 = agg(sF, tune); res['F'] = ok = (rate('poison') == 0 and mean('mean') >= 1550 and mean('spikes') <= 0.2)
    print(f"F stall    {'PASS' if ok else 'FAIL'} mean={mean('mean'):.0f} poisonR={rate('poison'):.2f} spikes={mean('spikes'):.1f}")
    print(f"== {label}: {sum(res.values())}/6 ==")
    return res, dpr, dspk

T0 = {'warmup': 1.5, 'jitAware': False, 'jitK': 0.0}
res0, dpr0, dspk0 = report(T0, "CURRENT (validation)")
valid = dpr0 >= 0.10 or dspk0 >= 0.5
print(f"MODEL {'VALID' if valid else 'NOT VALID'}: D poisonRate={dpr0:.2f} spikeMean={dspk0:.2f}")
report({'warmup': 1.5, 'jitAware': True, 'jitK': 2.0, 'drainHold': True, 'warmGrace': 3, 'spikeConfirm': 2, 'pinDrain': 6}, "CAND grace3+spike2+pinDrain6")

# ============================================================================
# FEC / receiver-loss layer  (S3 estimator-adapt peerloss: staleness + fix)
# ADDITIVE ONLY. Does NOT touch class Ctl or scenarios A-F. Every new behavior
# is tune-gated. Uses an isolated RNG (random.Random per seed) so the A-F
# output above is byte-identical. Mirrors:
#   main.go:387-406  reporter EWMA (500ms window) + byte quantize (lp=min(200,
#                    int(e*2+.5)); decode /2)  and  tc.Step on decoded lossPeer
#   fec.go:126-208   tierCtl.Step (strengthen-instant, 4-streak relax-only,
#                    optional holdUntil weaken-freeze) + gc() PRE-FEC accounting
#                    (rawLost += k-len(have)) + displacement(>64)/age retirement
# Tune keys: {fecRetire:'disp'|'age', fecRetireAge:0.6, fecCouple:bool,
#            fecHold:2.5, fecCollapseK:8}
# ============================================================================

FEC_CAP1 = 2000.0  # path-1 link capacity kb/s; never collapses (sB2)

def _tierK(lp):                       # fec.go:9 tierK
    if lp < 0.4: return 0
    if lp < 2.0: return 20
    if lp < 4.5: return 12
    return 8

def _kStrength(k):                    # fec.go:130 (0 < 20 < 12 < 8)
    return {0: 0, 20: 1, 12: 2, 8: 3}.get(k, 3)

def _oneWeaker(k):                    # fec.go:143
    return {8: 12, 12: 20}.get(k, 0)

def run_fec(kind, tune, seed):
    """One FEC/receiver-loss run over the global frame stream. ~no ring.
    kind: 'sB2' (S3 collapse mirror) | 'sG' (1% steady) | 'sH' (5% steady).
    Returns per-seed telemetry: graded, stats(1Hz lossPeer), ksamp(1Hz K),
    lptl[(t,lossPeer)], kstr[strengthen times]."""
    rng = random.Random(seed)                 # isolated: A-F untouched
    # ---- scenario config ----
    if kind == 'sB2':
        T, offer_pps = 13.8, 340.0
        collapse_t = 3.0; cap0_hi, cap0_lo = 2000.0, 600.0
        r1 = 1400.0; r0_hi, r0_floor = 2000.0, 500.0
        steady = 0.0
        tsc  = collapse_t + rng.uniform(0.45, 0.90)   # r0 spike-cut instant
        tflr = collapse_t + rng.uniform(1.65, 2.85)   # r0 reaches 500 floor
    else:
        T, offer_pps = 12.0, 250.0
        collapse_t = None; cap0_hi = cap0_lo = 2000.0
        r1 = 1500.0; r0_hi = r0_floor = 1500.0
        steady = 0.01 if kind == 'sG' else 0.05
        tsc = tflr = 1e9

    def cap0_of(t):
        if collapse_t is None or t < collapse_t: return cap0_hi
        return cap0_lo

    # ---- tune ----
    scheme = tune.get('fecRetire', 'disp')
    retAge = tune.get('fecRetireAge', 0.6)
    couple = tune.get('fecCouple', False)
    hold   = tune.get('fecHold', 2.5)
    collK  = tune.get('fecCollapseK', 8)
    # r0 spike-cut depth (fraction of r0_hi). Ctl SPIKE is rate*=0.5 but the
    # capHint*0.9 clamp + possible DRAIN pin the post-cut rate lower; 0.4
    # calibrates the collapse-burst magnitude to the architect prototype
    # (A graded median ~2.0). Loss remains pure rate-share (spec): modelling
    # a fully queue-aware reroute masks the collapse entirely (0 loss).
    spikeB = tune.get('fecSpikeBase', 0.4)

    def r0_of(t):
        if kind != 'sB2' or t < tsc: return r0_hi
        if t >= tflr: return r0_floor
        base = r0_hi * spikeB                           # SPIKE cut (rate*=0.5)
        cad = max(1e-6, (tflr - tsc) / 2.0)
        return max(r0_floor, base * (0.7 ** int((t - tsc) / cad)))  # 0.7-walk

    # ---- state ----
    K = 0; tc_cnt = 0; holdUntil = -1.0
    g_k = 0; g_start = 0; g_lost = []          # open TX group (FecTx)
    groups = {}; order = []                    # RX ledger (start -> (k,born,nlost))
    sLossE = 0.0
    wLost = wSeen = wDel = wSkip = 0.0         # 500ms window accumulators
    q = [0.0, 0.0]; seq = 0; frac = 0.0; lossPeer = 0.0
    coupled = False
    stats = []; ksamp = []; lptl = []; kstr = []
    t = 0.0; nRep = 0.5; nStep = 0.05; nStat = 1.0
    offer_kbps = offer_pps * PKT_KB

    def _send(p, cap0_now):
        # One frame onto path p. per-path queue in ms: q+svc>300 -> drop
        # (tail-drop). Returns lost(bool); mutates q. Drain is DT*1000/DT.
        cp = cap0_now if p == 0 else FEC_CAP1
        sv = PKT_KB / cp * 1000.0 if cp > 0 else 1e9
        if q[p] + sv > 300.0:
            return True
        q[p] += sv
        return steady > 0 and rng.random() < steady   # steady rx-loss

    while t < T - 1e-9:
        # ---- collapse -> FEC coupling (fires at the r0 spike-cut) ----
        if kind == 'sB2' and not coupled and t >= tsc:
            coupled = True
            if couple:                               # pinDrain pattern
                holdUntil = t + hold; tc_cnt = 0
                if _kStrength(K) < _kStrength(collK): # NEVER weaken (guard)
                    K = collK; g_k = 0; g_lost = []; kstr.append(t)

        cap0 = cap0_of(t); r0 = r0_of(t)
        total = r0 + r1
        sent = min(offer_kbps, total)                # ctl caps offer (backpressure)
        share0 = r0 / total if total > 0 else 0.0    # per-path assign by rate share
        frac += sent * DT / PKT_KB
        nfr = int(frac); frac -= nfr

        for _ in range(nfr):
            # ---- DATA frame `seq`: path assignment (rate share) + loss ----
            p = 0 if rng.random() < share0 else 1
            lost = _send(p, cap0)
            wDel += (0 if lost else 1); wSkip += (1 if lost else 0)
            # ---- TX group assembler (parity = one extra frame) ----
            if g_k == 0 and K > 0:
                g_k = K; g_start = seq; g_lost = []
            if g_k > 0:
                g_lost.append(lost)
                if len(g_lost) == g_k:                # group complete -> parity
                    pp = 0 if rng.random() < share0 else 1
                    par_lost = _send(pp, cap0)        # same loss process
                    # RX ledger entry ONLY if its parity is delivered
                    if not par_lost:
                        nlost = sum(g_lost)           # rebuild iff exactly-1-loss
                        groups[g_start] = (g_k, t, nlost)  # pre-FEC: have=k-nlost
                        order.append(g_start)
                        while len(order) > 64:        # displacement retire + 64 backstop
                            st = order.pop(0); gk, gb, gl = groups.pop(st)
                            if gl > 0: wLost += gl     # gc(): rawLost += k-len(have)
                            wSeen += gk                # rawSeen += k
                    g_k = 0; g_lost = []
            seq += 1

        # queues drain in real time: DT*1000 ms per DT
        q[0] = max(0.0, q[0] - DT * 1000.0)
        q[1] = max(0.0, q[1] - DT * 1000.0)

        # ---- 500ms reporter window (main.go:392-403) ----
        if t >= nRep:
            nRep += 0.5
            if scheme == 'age':                       # age sweep off TakeRaw cadence
                while order and (t - groups[order[0]][1] > retAge):
                    st = order.pop(0); gk, gb, gl = groups.pop(st)
                    if gl > 0: wLost += gl
                    wSeen += gk
            if wSeen > 0:                             # FEC accounting path
                sLossE = sLossE * 0.7 + (wLost / wSeen * 100.0) * 0.3
            elif (wDel + wSkip) > 0:                  # skips-based fallback (K=0)
                sLossE = sLossE * 0.7 + (wSkip / (wDel + wSkip) * 100.0) * 0.3
            wLost = wSeen = wDel = wSkip = 0.0

        # ---- tierCtl.Step @20Hz (fec.go Step + holdUntil freeze) ----
        if t >= nStep:
            nStep += 0.05
            lp = min(200, int(sLossE * 2 + 0.5))      # byte quantize (encode)
            lossPeer = lp / 2.0                        # decode (/2)
            nk = _tierK(lossPeer)
            if _kStrength(nk) > _kStrength(K):         # strengthen-instant
                if K != nk: kstr.append(t)
                K = nk; tc_cnt = 0; g_k = 0; g_lost = []
            elif nk == K:
                tc_cnt = 0
            elif t < holdUntil:
                pass                                   # weakening frozen (hold)
            else:
                tc_cnt += 1                            # 4-streak relax-only
                if tc_cnt >= 4:
                    tc_cnt = 0; K = _oneWeaker(K); g_k = 0; g_lost = []

        # ---- 1Hz telemetry ----
        if t >= nStat:
            nStat += 1.0
            stats.append(lossPeer); ksamp.append(K); lptl.append((t, lossPeer))

        t += DT

    graded = sorted(stats[-6:-1])[2] if len(stats) >= 6 else (max(stats) if stats else 0.0)
    return {'graded': graded, 'stats': stats, 'ksamp': ksamp, 'lptl': lptl, 'kstr': kstr}


def _fec_agg(kind, tune, n=30):
    return [run_fec(kind, tune, s) for s in range(n)]

def _median(xs):
    s = sorted(xs); m = len(s)
    return s[m // 2] if m % 2 else (s[m // 2 - 1] + s[m // 2]) / 2.0

def _p75(xs):
    s = sorted(xs); return s[int(0.75 * (len(s) - 1))]

def _shape(res, burst_end=5.0):
    # A validity shape (per seed): non-monotone lp after burst-end OR a K
    # re-tighten (strengthen) >=3s post-burst.
    tl = [v for (tt, v) in res['lptl'] if tt > burst_end + 0.5]
    nonmono = any(tl[j] > tl[i] + 0.5 for i in range(len(tl)) for j in range(i + 1, len(tl)))
    retighten = any(tk >= burst_end + 3.0 for tk in res['kstr'])
    return nonmono or retighten

def _ktail(reslist, drop=3, thr=0.10):
    # Steady K-tail as OPERATING tiers: over the settled tail (ramp dropped),
    # tiers with >=10% dwell across seeds. Filters single-window boundary
    # touches (the exactly-mirrored reporter produces these at 1% loss with
    # ~125 frames/window, as does the box). Also returns full occupancy +
    # mean tier-switches/run (the note's A-vs-B calmness metric).
    from collections import Counter
    occ = Counter(); sw = 0
    for r in reslist:
        tail = r['ksamp'][drop:]
        occ.update(tail)
        sw += sum(1 for i in range(1, len(tail)) if tail[i] != tail[i - 1])
    tot = max(1, sum(occ.values()))
    oper = {k for k in occ if occ[k] >= thr * tot}
    occ_s = " ".join(f"K{k}={100*occ[k]/tot:.0f}%" for k in sorted(occ))
    return oper, occ_s, sw / len(reslist)

def fec_report():
    print()
    print("=" * 68)
    print("FEC / RECEIVER-LOSS LAYER  (S3 peerloss staleness reproduce + fix)")
    print("  grade = sorted(stats[-6:-1])[2] over 1Hz lossPeer; 30 seeds")
    print("=" * 68)
    tuneA  = {'fecRetire': 'disp'}
    tuneB  = {'fecRetire': 'age', 'fecRetireAge': 0.6}
    tuneBc = {'fecRetire': 'age', 'fecRetireAge': 0.6, 'fecCouple': True,
              'fecHold': 2.5, 'fecCollapseK': 8}
    A  = _fec_agg('sB2', tuneA)
    B  = _fec_agg('sB2', tuneB)
    Bc = _fec_agg('sB2', tuneBc)
    gA, gB, gBc = [r['graded'] for r in A], [r['graded'] for r in B], [r['graded'] for r in Bc]
    medA, medB, medBc = _median(gA), _median(gB), _median(gBc)
    passA  = sum(1 for g in gA  if g <= 3.0)
    passB  = sum(1 for g in gB  if g <= 3.0)
    passBc = sum(1 for g in gBc if g <= 3.0)
    shapeN = sum(1 for r in A if _shape(r))
    shape_ok = (shapeN >= 0.25 * 30) and (medA >= 2.0 * max(medB, 1e-9))
    print(f"A  disp (CURRENT)   graded med={medA:4.2f}  p75={_p75(gA):4.2f}  "
          f"pass<=3.0 {passA:2d}/30   shape {shapeN:2d}/30")
    print(f"   A-VALIDITY: {'HOLDS' if shape_ok else 'FAILS'}   "
          f"(shape>=8/30: {shapeN>=8};  medA>=2*medB: {medA:.2f}>={2*medB:.2f})")
    print(f"B  age 0.6          graded med={medB:4.2f}  p75={_p75(gB):4.2f}  "
          f"pass<=3.0 {passB:2d}/30")
    print(f"   B-FIX BAR: p75<=2.5 {'PASS' if _p75(gB)<=2.5 else 'FAIL'} ; "
          f"pass>=27/30 {'PASS' if passB>=27 else 'FAIL'}")
    print(f"B+ age 0.6 +couple  graded med={medBc:4.2f}  p75={_p75(gBc):4.2f}  "
          f"pass<=3.0 {passBc:2d}/30   ({'>=B PASS' if passBc>=passB else '<B FAIL'})")
    print("-" * 68)
    print("Steady guards (K-tail = operating tiers >=10% dwell; disp=current, age=fix)")
    for kind, target in (('sG', {20}), ('sH', {8, 12})):
        gd = _fec_agg(kind, {'fecRetire': 'disp'})
        ga = _fec_agg(kind, {'fecRetire': 'age', 'fecRetireAge': 0.6})
        odA, occA, swA = _ktail(gd)
        odB, occB, swB = _ktail(ga)
        lbl = '1%@250pps' if kind == 'sG' else '5%@250pps'
        ok = odB <= target                         # acceptance: operating set
        calm = 'calmer' if swB <= swA else 'flappier'
        print(f"{kind} {lbl}  age K-tail={sorted(odB)} subset{sorted(target)} "
              f"{'PASS' if ok else 'FAIL'}")
        print(f"   age: {occB}  {swB:.2f} sw/run ({calm} than disp)   |   "
              f"disp: {occA}  {swA:.2f} sw/run")
    print("=" * 68)
    if 'debug' in sys.argv:
        for lbl, res in (('A/disp', A[0]), ('B/age', B[0]), ('B+couple', Bc[0])):
            print(f"-- seed0 {lbl}: (t, lossPeer, K)")
            print("   " + " ".join(f"{tt:.0f}:{v:.1f}/{k}"
                  for (tt, v), k in zip(res['lptl'], res['ksamp'])))

if 'nofec' not in sys.argv:
    fec_report()
