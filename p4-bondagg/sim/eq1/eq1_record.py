#!/usr/bin/env python3
# =============================================================================
# eq1_record.py -- U9 / EQ-1.  Record a DATAPATH TRACE from the two-stage rig
# (ADR-004's authoritative oracle) so the Go pull core can be replayed against
# it and compared BYTE-WISE.
#
# ADR-004 condition 1 says "the Go port must match the rig byte-for-byte on
# recorded traces".  Nothing recorded a trace until this file, so the condition
# had never been testable, let alone tested.
#
# -----------------------------------------------------------------------------
# WHAT A TRACE HAS TO CONTAIN FOR THE COMPARISON TO MEAN ANYTHING
# -----------------------------------------------------------------------------
# The Go core and the rig do not share a state space.  The rig is a
# single-threaded fixed-tick fluid simulator whose admission gate is a
# backlog/drain-rate ESTIMATE (`_local_ms(i) < target_ms`); the Go core is N
# goroutines whose admission gate is a real socket refusing a write.  So a trace
# cannot be "the inputs" alone -- the two would diverge on the first tick for
# reasons that have nothing to do with the port's correctness.
#
# A trace therefore carries FOUR things, and the split between the first three
# and the fourth is the whole design:
#
#   (1) THE ARRIVAL PROCESS.  Every enqueue, in order, at its tick.  The rig
#       stamps seq at enqueue in app order; so does PullFIFO.Enqueue.  This is
#       directly comparable.
#   (2) THE PHYSICS EVENTS.  Per-link stage-2 capacity per tick, plus the
#       dropout intervals and the owd/jit geometry.  These are RECORDED FOR
#       REPRODUCIBILITY AND AUDIT -- the Go core cannot consume a kb/s number,
#       it has no rate anywhere.  They are what lets a reader re-derive (3).
#   (3) THE ADMISSION DECISIONS.  For every draw the rig made: which link
#       attempted which seq, and whether the link's stage took it.  This is the
#       rig's room()/draw-order, SUPPLIED to the Go core rather than compared
#       against it -- see NOT COVERED below.  It is what makes the two systems
#       commensurable at all.
#   (4) THE OUTPUTS.  The emitted frame stream (as WIRE BYTES), the shed set,
#       and a pool digest at every tick boundary.  This is what is compared.
#
# -----------------------------------------------------------------------------
# WHAT IS THEREFORE PROVEN, AND WHAT IS NOT
# -----------------------------------------------------------------------------
# PROVEN (byte-wise, per frame, in order):
#   * seq is stamped at enqueue in app order and travels with the frame body.
#   * the pool is a strict FIFO under interleaved draw / rollback / shed.
#   * the pool bound sheds OLDEST-FIRST and sheds exactly the same frames the
#     oracle sheds, at the same tick (pool digest equality every tick).
#   * a refused frame is returned to the HEAD with its ORIGINAL enq stamp and is
#     re-offered before any younger frame (S2's rollback half).
#   * a refusal does not burn fseq: the per-link fseq series is exactly the
#     per-link ACCEPT ordinal the oracle produced, which is the only thing the
#     peer's loss meter can be measured against.
#   * pathID == the link the oracle placed the frame on.
#
# NOT COVERED, and not silently:
#   * DRAW ORDER (pull.go S1).  The oracle sorts hungriest-first on _local_ms;
#     the Go core substitutes mutex acquisition order.  The trace SUPPLIES the
#     order, so EQ-1 cannot adjudicate it.  pull.go@'is the adjudicator for S1 and S2' nominates EQ-1 as the
#     adjudicator for S1; that is not achievable by any trace comparison,
#     because the Go core has no observable counterpart of _local_ms to compare.
#     eq1_free_test.go measures the CONSEQUENCE (per-link share divergence)
#     instead; that is a measurement, not a proof.
#   * room().  Same reason: the oracle's estimator gate is an input here.
#   * S2(a), the in-flight understatement of the pool bound.  A drawn-but-unsent
#     frame is out of the Go pool and invisible to the bound; the oracle is
#     single threaded and has no such state, so there is nothing to compare
#     against.  Bounded by construction at N frames.
#   * THE AGE LIMB of the pool bound.  The oracle has no age limb at all -- its
#     bound is bytes only (reserved_composite.py@'while len(s.fifo) * PKT_KB > s.maxq_kb').
#     The replay runs with
#     maxAge = 0 for exactly that reason.  The Go age limb is an ADDITION with
#     no oracle counterpart and EQ-1 says nothing about it.
#   * The wire TIMESTAMP field, header bytes [8:12].  It is time.Now() and is
#     not reproducible.  It is MASKED in the byte comparison; the other 12
#     header bytes and the whole payload are compared.
#   * Everything downstream of the send: reorder ring, hold, loss meter, server.
#   * E2b (cap) and E2c (lightning) -- not built in Go, so sched='Dc' is not
#     comparable.  This records sched='pull' only, which is E2a's counterpart.
#
# -----------------------------------------------------------------------------
# ORACLE PIN (ADR-004 amendment + U35)
# -----------------------------------------------------------------------------
# There are TWO materially different ackclock_sim.py and TWO nsched_model.py in
# this tree and ADR-004 originally named the wrong one.  This file does not let
# sys.path decide: it loads each module from an EXPLICIT absolute path, asserts
# __file__ afterwards, and records the sha256 of all three in the trace header.
# A replay whose header shas do not match the tree is a replay against a
# different oracle and is VOID.  That is now ENFORCED, not merely asserted:
# eq1_selfcheck.check_pin and the Go eq1Init both read the three sha_ keys and
# fail the run on any drift.  Round 1 recorded the pin and never read it, and
# the fixtures' pin was already stale on the merge target while every gate
# stayed green -- a documented rule with no reader is not a rule.
#
# The remedy when the pin fires is `--rerecord`, below: it re-records a trace
# from ITS OWN header parameters against the tree's oracle and prints which
# totals moved.  A drift that changes nothing prints UNCHANGED on every field;
# a drift that changes the oracle's behaviour prints the fields it changed.
# Neither outcome is a licence to skip the check.
#
# Usage:
#   cd p4-bondagg/sim/eq1
#   python eq1_record.py --scenario n3-het --load 0.85 --seed 0 --T 9.0 \
#                        --out traces/n3-het.eq1.gz
#   python eq1_record.py --list
#   python eq1_record.py --rerecord traces/n2-het-edge.eq1.gz    # after a drift
# =============================================================================
import argparse
import gzip
import hashlib
import importlib.util
import io
import os
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.abspath(os.path.join(HERE, '..'))
RIG = os.path.join(SIM, 'pull-study', '03-reserved-composite')

TRACE_VERSION = 2

# Wire constants, mirrored from p4-bondagg/daemon/frame.go.  Duplicated here on
# purpose: the recorder builds the EXPECTED frame bytes independently of the Go
# code, so a divergence in the wire layout shows up as a byte mismatch rather
# than as two copies of the same mistake.
MAGIC = 0xB0
VER = 2
FLAG_DATA = 0x0
HDR_LEN = 16


# ---------------------------------------------------------------------------
# ORACLE PIN -- explicit path load, asserted, sha-recorded.
# ---------------------------------------------------------------------------
def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def _load_pinned(name, path):
    path = os.path.abspath(path)
    if not os.path.exists(path):
        raise SystemExit('EQ1 PIN: %s does not exist at %s' % (name, path))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    got = os.path.abspath(mod.__file__)
    if got != path:
        raise SystemExit('EQ1 PIN: %s loaded from %s, wanted %s' % (name, got, path))
    return mod


PIN = {
    'nsched_model': os.path.join(SIM, 'nsched_model.py'),
    'ackclock_sim': os.path.join(RIG, 'ackclock_sim.py'),
    'reserved_composite': os.path.join(RIG, 'reserved_composite.py'),
}
# Order matters: the later modules do `import ackclock_sim` / `import
# nsched_model`, and sys.modules is already populated by then, so sys.path never
# gets a vote.
M = _load_pinned('nsched_model', PIN['nsched_model'])
A = _load_pinned('ackclock_sim', PIN['ackclock_sim'])
RC = _load_pinned('reserved_composite', PIN['reserved_composite'])

PKT_KB = M.PKT_KB          # kilobits per frame (9.79 kb == 1224 B)
DT = M.DT
FRAME_BYTES = int(round(PKT_KB * 1000.0 / 8.0))     # 1224
PAYLOAD_BYTES = FRAME_BYTES - HDR_LEN               # 1208

# payload pattern: byte j of frame `seq` is (seq*31 + j) & 0xFF.  A 256-byte
# ramp rotated by (seq*31)&0xFF, so it is a slice, not a per-byte loop.  The Go
# replay builds the identical bytes; a body attached to the wrong seq shows up.
_RAMP = bytes(range(256)) * (PAYLOAD_BYTES // 256 + 2)


def _payload(seq):
    off = (seq * 31) & 0xFF
    return _RAMP[off:off + PAYLOAD_BYTES]


# ---------------------------------------------------------------------------
# Scenarios.  N-GENERIC: a scenario is a LIST of archetypes of any length; the
# recorder reads N from len(), never from a constant, and the trace declares N
# in its header with exactly N link records.  Nothing here is 2-shaped.
# ---------------------------------------------------------------------------
def scenarios():
    return {
        'n1-cell':  [RC.cellA(RC.DROPS_A)],
        'n2-het':   [RC.cellA(RC.DROPS_A), RC.eth()],
        'n3-het':   [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.eth()],
        'n4-het':   [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.wifi(), RC.eth()],
        'n5-het':   [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
                     RC.wifi(), RC.eth()],
        'n4-teth':  [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
                     RC.eth()],
        'n5-corr':  [RC.cellA(RC.DROPS_CORR), RC.cellB(RC.DROPS_CORR),
                     RC.cellC(RC.DROPS_CORR), RC.wifi(), RC.eth()],
        # all-spotty: no steady class anywhere.  Included because a mix with no
        # steady host is the degenerate case every N-generic claim has to survive.
        'n3-spot':  [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C)],
    }


LABELS = {
    29000: 'cellA', 22000: 'cellB', 17000: 'cellC', 45000: 'wifi', 78000: 'eth',
}


# ---------------------------------------------------------------------------
# Instrumentation.  The rig source is NOT modified: the recorder wraps three
# things on the INSTANCE -- the offer callable of each local Stage, the offer_fn
# (called exactly once per tick, before anything touches the pool), and the pool
# deque itself.
# ---------------------------------------------------------------------------
class RecFifo(deque):
    """The rig's send-FIFO with append/popleft observed.

    The rig pops the pool for exactly two reasons under sched='pull':
      * the byte bound sheds the oldest frame (reserved_composite.py@'while len(s.fifo) * PKT_KB > s.maxq_kb')
      * PIECE 1 placed the head frame on a link (reserved_composite.py@'s.fifo.popleft(); s.assigned[i] += 1')
    They are told apart by a pending-accept marker set by the offer wrapper and
    consumed by the very next popleft.  That discriminator is not asserted, it
    is CHECKED: at the end of the run the shed count must equal s.qdrops and the
    placement count must equal sum(s.assigned), or the recorder aborts.
    """

    def __init__(self, rec):
        super().__init__()
        self.rec = rec

    def append(self, seq):
        super().append(seq)
        self.rec.on_arrival(seq)

    def popleft(self):
        seq = super().popleft()
        self.rec.on_pop(seq)
        return seq


class Recorder:
    def __init__(self, out, meta):
        self.out = out
        self.meta = meta
        self.tick = -1
        self.pending = None          # (link_idx, seq) from the last accepted offer
        self.n_shed = 0
        self.n_placed = 0
        self.n_arr = 0
        self.n_refuse = 0
        self.n_excl = 0
        self.fseq = None             # per-link accept ordinal == the wire fseq
        self.assigned = None
        self.emis = hashlib.sha256()  # rolling digest of emitted wire bytes
        self.body = hashlib.sha256()  # rolling digest of the trace text
        self.first_tick_seen = False
        self.alive = ''

    # -- trace text ---------------------------------------------------------
    def w(self, line):
        b = (line + '\n').encode('ascii')
        self.body.update(b)
        self.out.write(b)

    # -- hooks --------------------------------------------------------------
    def on_tick(self, now, sim):
        if self.pending is not None:
            raise SystemExit('EQ1 REC: an accepted offer was never popped '
                             '(tick %d) -- the pop discriminator is unsound '
                             'for this scheduler' % self.tick)
        if self.first_tick_seen:
            self.emit_pool(sim)
        self.first_tick_seen = True
        self.tick += 1
        # room() for sched='pull' is `alive[i] and _local_ms(i) < target_ms`
        # (reserved_composite.py@'def room(i):', with nat_cap=HUGE).  It is recomputed
        # here, at the same point in the tick PIECE 1 will first evaluate it and
        # from the same state -- nothing between offer_fn and PIECE 1 touches
        # local[].backlog_kb or drain_ewma.
        #
        # `a=` is the alive mask; the room() exclusion set is recorded at the
        # END of the tick's draw loop instead (see on_draw_end) because that is
        # the only moment it is non-empty.
        alive = ''.join('1' if sim._local_cap(i, now) > 0 else '0'
                        for i in range(len(sim.defs)))
        self.alive = alive
        self.w('T|%d|%d|a=%s' % (self.tick, int(round(now * 1e9)), alive))

    def on_draw_end(self, sim):
        """Fires once per tick, immediately after PIECE 1's draw loop has broken
        and before anything drains -- i.e. at the exact state in which the loop
        stopped.

        WHY THIS EXISTS.  In the oracle a link that fails room() is simply
        absent from `cand`: it never attempts, so the oracle NEVER emits an
        attempted-and-refused event, and its `if not placed: break` branch is
        dead in practice (measured: 0 offer refusals across every trace recorded
        here).  What actually stops the loop is room() CLOSING as the local
        backlog grows during the tick -- so the refusal set is empty at the top
        of the tick and non-empty at the bottom, which is why it is sampled
        here.

        The Go core has no foreknowledge of room(): a link discovers it cannot
        send by drawing and having the socket refuse, then rolling the frame
        back (pull.go S2).  So the rollback path has NO oracle counterpart to be
        compared against, and EQ-1 tests it as a TRANSPARENCY property instead:
        injecting a refused draw for exactly the links the oracle had excluded
        when it stopped must leave the emitted stream bit-identical.  A rollback
        that pushed to the tail, dropped the frame, or burned an fseq would
        change the stream and fail.
        """
        excl = [i for i in range(len(sim.defs))
                if self.alive[i] == '1' and sim._local_ms(i) >= sim.target_ms]
        self.n_excl += len(excl)
        self.w('R|' + ','.join(str(i) for i in excl))

    def on_arrival(self, seq):
        self.n_arr += 1
        self.w('A|%d' % seq)

    def on_offer(self, idx, seq, ok):
        if ok:
            self.pending = (idx, seq)
        else:
            self.n_refuse += 1
            self.w('D|%d|%d|r' % (idx, seq))

    def on_pop(self, seq):
        if self.pending is not None:
            idx, pseq = self.pending
            self.pending = None
            if pseq != seq:
                raise SystemExit('EQ1 REC: placement pop %d != accepted seq %d'
                                 % (seq, pseq))
            self.n_placed += 1
            f = self.fseq[idx]
            self.fseq[idx] += 1
            self.assigned[idx] += 1
            self.w('D|%d|%d|a|%d' % (idx, seq, f))
            self.emis.update(self.frame_bytes(idx, seq, f))
        else:
            self.n_shed += 1
            self.w('S|%d|b' % seq)

    # -- wire bytes ---------------------------------------------------------
    def frame_bytes(self, idx, seq, fseq):
        """The frame the Go core must put on the wire for this placement, with
        the txstamp field [8:12] MASKED to zero (it is time.Now(); see the
        header).  Built from the frame.go layout independently of the Go code."""
        hdr = bytearray(HDR_LEN)
        hdr[0] = MAGIC
        hdr[1] = (VER << 4) | (FLAG_DATA & 0x0F)
        hdr[2] = idx & 0xFF
        hdr[3] = 0
        hdr[4:8] = (seq & 0xFFFFFFFF).to_bytes(4, 'big')
        hdr[8:12] = b'\x00\x00\x00\x00'
        hdr[12:16] = (fseq & 0xFFFFFFFF).to_bytes(4, 'big')
        return bytes(hdr) + _payload(seq)

    # -- pool digest --------------------------------------------------------
    def emit_pool(self, sim):
        h = hashlib.sha256()
        for s in sim.fifo:
            h.update((s & 0xFFFFFFFF).to_bytes(4, 'big'))
        self.w('P|%d|%d|%s' % (self.tick, len(sim.fifo), h.hexdigest()[:32]))


def record(scn, archs, load, seed, T, rig, out):
    defs = RC.build_rig(archs, bottleneck=rig)
    n = len(defs)
    nom = sum(a['base'] for a in archs)
    offer_kb = load * nom
    base_ofn = (lambda t, _o=offer_kb: _o)

    sim = RC.SimD(defs, base_ofn, T, seed, sched='pull')

    # The oracle's pool bound is a FRAME COUNT dressed as bytes:
    #   while len(fifo) * PKT_KB > maxq_kb
    # Frames are uniform, so this is exactly `len(fifo) > floor(maxq_kb/PKT_KB)`.
    # The Go bound is `bytes > maxBytes` over wireBytes = payload + HdrLen, and
    # every frame is FRAME_BYTES, so the two predicates coincide EXACTLY when
    #   maxBytes = floor(maxq_kb / PKT_KB) * FRAME_BYTES.
    # That is a DERIVATION from the oracle's own constant, not a chosen number,
    # and it is checked below on every tick rather than argued.
    max_frames = int(sim.maxq_kb // PKT_KB)
    max_bytes = max_frames * FRAME_BYTES
    if max_frames < 2:
        raise SystemExit(
            "EQ1 REC: max_frames=%d -- the Go byte limb never empties below "
            "one frame (pull.go@'for f.n > 1 && f.bytes > f.maxBytes') so the "
            "two bounds are NOT equivalent here" % max_frames)

    meta = {
        'v': TRACE_VERSION,
        'scenario': scn, 'sched': 'pull', 'rig': rig,
        'load': '%.6f' % load, 'offer_kb': '%.6f' % offer_kb,
        'seed': seed, 'T': '%.6f' % T, 'dt_ns': int(round(DT * 1e9)),
        'n': n,
        'frame_bytes': FRAME_BYTES, 'payload_bytes': PAYLOAD_BYTES,
        'hdr_len': HDR_LEN, 'ver': VER, 'magic': MAGIC,
        'pkt_kb': '%.6f' % PKT_KB,
        # Arm B needs the LOCAL stage's own parameters to build a faithful fake
        # socket (ackclock_sim.Stage.offer/drain).  target_ms is recorded for the
        # record only -- it is the oracle's estimator gate, which the Go core
        # deliberately does not have.
        'local_qmax_ms': '%.6f' % sim.local[0].qmax,
        'target_ms': '%.6f' % sim.target_ms,
        'maxq_kb': '%.6f' % sim.maxq_kb,
        'pool_max_frames': max_frames,
        'pool_max_bytes': max_bytes,
        'pool_max_age_ns': 0,
        'sha_nsched_model': _sha256(PIN['nsched_model']),
        'sha_ackclock_sim': _sha256(PIN['ackclock_sim']),
        'sha_reserved_composite': _sha256(PIN['reserved_composite']),
    }

    rec = Recorder(out, meta)
    rec.fseq = [0] * n
    rec.assigned = [0] * n

    rec.w('# EQ1TRACE -- U9 / ADR-004 condition 1.  See eq1/README.md.')
    rec.w('V|%d' % TRACE_VERSION)
    rec.w('M|' + '|'.join('%s=%s' % (k, meta[k]) for k in sorted(meta)))
    for i, d in enumerate(defs):
        a = archs[i]
        rec.w('L|%d|%s|%s|%d|%.3f|%.3f|%s' % (
            i, LABELS.get(a['base'], 'link%d' % i),
            'spotty' if a['spotty'] else 'steady', a['base'],
            d['loc_owd'] + d['down_owd'], d['jit'],
            ';'.join('%.4f:%.4f' % (x, y) for (x, y) in a.get('dropouts', ()))))

    # -- install the instrumentation ---------------------------------------
    sim.fifo = RecFifo(rec)

    def mk_offer_wrap(stage, idx):
        orig = stage.offer

        def w(seq, enq_t, cap):
            ok = orig(seq, enq_t, cap)
            rec.on_offer(idx, seq, ok)
            return ok
        return w

    for i in range(n):
        sim.local[i].offer = mk_offer_wrap(sim.local[i], i)

    # local[0].drain is the FIRST thing run() does after the draw loop breaks,
    # so wrapping it gives a once-per-tick hook at exactly that state.  It is a
    # hook, not a behaviour change: it delegates unmodified.
    def mk_drain_wrap(stage):
        orig = stage.drain

        def w(cap, now_, rng):
            rec.on_draw_end(sim)
            return orig(cap, now_, rng)
        return w

    sim.local[0].drain = mk_drain_wrap(sim.local[0])

    # capacity samples: the physics events, recorded per tick per link.  They
    # are audit data -- the Go core consumes none of them.
    cap_fns = [d['down_cap_fn'] for d in defs]
    lcap_fns = [d['local_cap_fn'] for d in defs]
    bound_mismatch = [0]

    def ofn(t):
        rec.on_tick(t, sim)
        # C  = the LOCAL stage capacity, i.e. `lcaps` as PIECE 1 computes it
        #      (reserved_composite.py@'lcaps = [s._local_cap(i, now) for i in range(s.N)]').  This is the one
        #      Arm B needs: the fake socket models the LOCAL stage, which is where
        #      the EDGE rig puts the real cap.
        # Cd = the downstream stage capacity.  Audit only.
        #
        # v1 emitted only the DOWNSTREAM cap under `C`, and in the edge rig that is
        # `lambda t: HUGE` (reserved_composite.py@'down_cap_fn=lambda t: HUGE') -- so Arm B's device queue
        # was clocked at 1e9 kb/s, never refused anything, and reported a peak
        # occupancy of 0 ms on every link of every trace.  The format is v2 for
        # that reason; a v1 trace is refused rather than silently misread.
        rec.w('C|' + '|'.join('%.4f' % sim._local_cap(i, t) for i in range(n)))
        rec.w('Cd|' + '|'.join('%.4f' % f(t) for f in cap_fns))
        # cross-check the two pool-bound predicates on the live pool BEFORE the
        # tick's arrivals: rig `len*PKT_KB > maxq_kb` vs Go `len*FB > maxBytes`.
        ln = len(sim.fifo)
        if (ln * PKT_KB > sim.maxq_kb) != (ln * FRAME_BYTES > max_bytes):
            bound_mismatch[0] += 1
        return base_ofn(t)

    sim.offer_fn = ofn

    m = sim.run()
    rec.emit_pool(sim)

    # -- self-checks: the discriminator has to be provable, not asserted ----
    if rec.n_shed != sim.qdrops:
        raise SystemExit('EQ1 REC: shed events %d != sim.qdrops %d'
                         % (rec.n_shed, sim.qdrops))
    if rec.n_placed != sum(sim.assigned):
        raise SystemExit('EQ1 REC: placements %d != sum(assigned) %d'
                         % (rec.n_placed, sum(sim.assigned)))
    if rec.assigned != list(sim.assigned):
        raise SystemExit('EQ1 REC: per-link placements %s != assigned %s'
                         % (rec.assigned, list(sim.assigned)))
    if rec.n_arr != sim.next_seq:
        raise SystemExit('EQ1 REC: arrivals %d != next_seq %d'
                         % (rec.n_arr, sim.next_seq))
    if bound_mismatch[0]:
        raise SystemExit('EQ1 REC: the frame-count and byte pool-bound '
                         'predicates disagreed on %d ticks -- the derived '
                         'pool_max_bytes is NOT equivalent to the oracle bound'
                         % bound_mismatch[0])

    totals = {
        'arrivals': rec.n_arr, 'placed': rec.n_placed, 'refused': rec.n_refuse,
        'shed': rec.n_shed, 'ticks': rec.tick + 1,
        'room_excluded': rec.n_excl,
        'assigned': ','.join(str(x) for x in sim.assigned),
        'emission_sha256': rec.emis.hexdigest(),
        # rig-side outcome metrics, for the record only.  Nothing downstream of
        # the send is compared by EQ-1.
        'rig_gp': '%.3f' % m['gp'], 'rig_loss': '%.4f' % m['loss'],
        'rig_tdrop': m['tdrop'], 'rig_qdrops': m['qdrops'],
    }
    rec.w('X|' + '|'.join('%s=%s' % (k, totals[k]) for k in sorted(totals)))
    out.write(('E|%s\n' % rec.body.hexdigest()).encode('ascii'))
    return totals, meta


def read_header(path):
    """The M record of an existing trace: everything needed to re-record it."""
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rb') as fh:
        for raw in fh:
            line = raw.decode('ascii').rstrip('\n')
            if line.startswith('M|'):
                return dict(kv.split('=', 1) for kv in line[2:].split('|'))
            if line.startswith(('L|', 'T|')):
                break
    raise SystemExit('EQ1 REC: %s has no M header record' % path)


def read_totals(path):
    """The X record of an existing trace: what it measured."""
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rb') as fh:
        for raw in fh:
            line = raw.decode('ascii').rstrip('\n')
            if line.startswith('X|'):
                return dict(kv.split('=', 1) for kv in line[2:].split('|'))
    raise SystemExit('EQ1 REC: %s has no X totals record' % path)


def rerecord(path):
    """Re-record a trace against THIS tree's oracle, from its own parameters.

    This is the remedy the pin check names.  It is deliberately not a repair:
    it re-runs the recording and REPORTS every total that moved, so a drift that
    changed the oracle's behaviour is visible rather than absorbed.
    """
    old_meta = read_header(path)
    old_tot = read_totals(path)
    scn = old_meta['scenario']
    S = scenarios()
    if scn not in S:
        raise SystemExit('EQ1 REC: %s records scenario %r, which no longer exists'
                         % (path, scn))
    buf = io.BytesIO()
    totals, meta = record(scn, S[scn], float(old_meta['load']),
                          int(old_meta['seed']), float(old_meta['T']),
                          old_meta['rig'], buf)
    raw = buf.getvalue()
    if path.endswith('.gz'):
        with open(path, 'wb') as fh:
            with gzip.GzipFile(fileobj=fh, mode='wb', mtime=0) as gz:
                gz.write(raw)
    else:
        with open(path, 'wb') as fh:
            fh.write(raw)

    moved = 0
    sys.stderr.write('EQ1 RERECORD %s (scenario=%s rig=%s load=%s seed=%s T=%s)\n'
                     % (path, scn, old_meta['rig'], old_meta['load'],
                        old_meta['seed'], old_meta['T']))
    for k in sorted(set(old_tot) | set(totals)):
        a, b = old_tot.get(k), str(totals.get(k))
        if a != b:
            moved += 1
            sys.stderr.write('  CHANGED  %-18s %s -> %s\n' % (k, a, b))
    for k in sorted(PIN):
        a, b = old_meta.get('sha_' + k), meta['sha_' + k]
        if a != b:
            sys.stderr.write('  ORACLE   %-18s %s -> %s\n' % (k, str(a)[:12], b[:12]))
    if moved == 0:
        sys.stderr.write('  every recorded total is UNCHANGED -- the oracle drift '
                         'was cosmetic for this trace\n')
    else:
        sys.stderr.write('  %d total(s) MOVED -- the oracle drift changed its '
                         'behaviour; do not merge this without reading them\n' % moved)
    return moved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rerecord', nargs='+', default=None,
                    help='re-record existing traces IN PLACE from their own '
                         'header parameters against this tree oracle')
    ap.add_argument('--scenario', default='n3-het')
    ap.add_argument('--load', type=float, default=0.85)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--T', type=float, default=9.0)
    ap.add_argument('--rig', default='mid', choices=('mid', 'edge'))
    ap.add_argument('--out', default='-')
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()

    if a.rerecord:
        moved = 0
        for p in a.rerecord:
            moved += rerecord(p)
        return

    S = scenarios()
    if a.list:
        for k, v in S.items():
            print('%-10s N=%d  nominal_agg=%7d kb/s  spotty=%d'
                  % (k, len(v), sum(d['base'] for d in v),
                     sum(1 for d in v if d['spotty'])))
        return

    if a.scenario not in S:
        raise SystemExit('unknown scenario %r (try --list)' % a.scenario)

    buf = io.BytesIO()
    totals, meta = record(a.scenario, S[a.scenario], a.load, a.seed, a.T,
                          a.rig, buf)
    raw = buf.getvalue()

    if a.out == '-':
        sys.stdout.buffer.write(raw)
    else:
        d = os.path.dirname(os.path.abspath(a.out))
        if d:
            os.makedirs(d, exist_ok=True)
        if a.out.endswith('.gz'):
            # mtime=0 so the same trace produces the same file bytes.
            with open(a.out, 'wb') as fh:
                with gzip.GzipFile(fileobj=fh, mode='wb', mtime=0) as gz:
                    gz.write(raw)
        else:
            with open(a.out, 'wb') as fh:
                fh.write(raw)
        sys.stderr.write('EQ1 %s -> %s (%d raw / %d on disk)\n'
                         % (a.scenario, a.out, len(raw),
                            os.path.getsize(a.out)))
    for k in sorted(totals):
        sys.stderr.write('  %-16s %s\n' % (k, totals[k]))


if __name__ == '__main__':
    main()
