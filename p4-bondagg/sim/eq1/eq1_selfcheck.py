#!/usr/bin/env python3
# =============================================================================
# eq1_selfcheck.py -- U9 / EQ-1.  Two jobs, both about the HARNESS rather than
# about the Go daemon:
#
#   1. COMPLETENESS.  Replay a trace with a minimal, independent implementation
#      of the pool semantics and check that it reproduces the recorded emission
#      sha256, every per-tick pool digest and every per-tick shed count.  If it
#      does, the trace CONTAINS enough to reconstruct the oracle's outputs --
#      which is the property a trace format has to have before any port can be
#      judged against it.  It says nothing about the Go code.
#
#   2. TEETH.  `--mutate` breaks one specific rule in this replay and the run
#      must FAIL.  Each mutation is a defect the Go core could plausibly have,
#      so a mutation that still passes would prove the comparison is blind to
#      that defect.  This is the negative control for the whole unit; without it
#      "the digests matched" is not evidence of anything.
#
# Usage:
#   python eq1_selfcheck.py traces/*.eq1.gz
#   python eq1_selfcheck.py --mutate rollback-tail traces/n3-spot-edge.eq1.gz
#   python eq1_selfcheck.py --mutate-all traces/n3-spot-edge.eq1.gz
# =============================================================================
import argparse
import glob
import gzip
import hashlib
import os
import sys
from collections import deque

# ---------------------------------------------------------------------------
# THE ORACLE PIN, ENFORCED.
#
# eq1_record.py records the sha256 of the three oracle files it loaded and says
# a replay whose header shas do not match the tree is void.  Round 1 RECORDED
# that pin and never CHECKED it, which is the same as not having it: the
# fixtures' pin was already stale on `dev` (U35 rewrote reserved_composite.py's
# header the same day) and every gate stayed green.  This reads it.
#
# The remedy for a fired pin is mechanical and is named in the failure message:
# `python eq1_record.py --rerecord <trace>` re-records the trace from its own
# header parameters against the tree's oracle and prints exactly which totals
# moved.  A pin failure is not a licence to skip the check -- there is no flag
# to skip it.
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.abspath(os.path.join(HERE, '..'))
RIG = os.path.join(SIM, 'pull-study', '03-reserved-composite')
PIN = {
    'nsched_model': os.path.join(SIM, 'nsched_model.py'),
    'ackclock_sim': os.path.join(RIG, 'ackclock_sim.py'),
    'reserved_composite': os.path.join(RIG, 'reserved_composite.py'),
}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()

MUTATIONS = {
    'none': 'no change (must PASS)',
    'rollback-tail': 'Return pushes the refused frame to the TAIL, not the head',
    'rollback-drop': 'Return drops the refused frame instead of restoring it',
    'fseq-burn': 'a refused write consumes an fseq (fabricates peer loss)',
    'shed-newest': 'the pool bound sheds the NEWEST frame, not the oldest',
    'no-bound': 'the pool bound is not applied at all',
    'bound-at-tick': 'the bound runs once per 10ms tick instead of on every mutation',
    'bound-at-ctl': 'the bound runs once per 100ms control tick (the U7 round-1 defect)',
    'seq-at-draw': 'seq is stamped when a link draws, not at enqueue',
    'pathid-zero': 'every frame is emitted with pathID 0',
    # Not a defect the Go core could have -- a defect THE PIN CHECK could have.
    # It perturbs the tree sha the pin is compared against, so a run that still
    # passes proves the pin is not being read.  It is in the matrix for the same
    # reason the others are: an unchecked check is indistinguishable from none.
    'oracle-pin': 'the tree oracle drifts from the one the trace was recorded against',
}

_RAMP = None


def payload(seq, nbytes):
    global _RAMP
    if _RAMP is None:
        _RAMP = bytes(range(256)) * (nbytes // 256 + 2)
    off = (seq * 31) & 0xFF
    return _RAMP[off:off + nbytes]


def frame_bytes(idx, seq, fseq, meta):
    hdr = bytearray(16)
    hdr[0] = int(meta['magic'])
    hdr[1] = (int(meta['ver']) << 4) | 0
    hdr[2] = idx & 0xFF
    hdr[3] = 0
    hdr[4:8] = (seq & 0xFFFFFFFF).to_bytes(4, 'big')
    hdr[8:12] = b'\x00\x00\x00\x00'
    hdr[12:16] = (fseq & 0xFFFFFFFF).to_bytes(4, 'big')
    return bytes(hdr) + payload(seq, int(meta['payload_bytes']))


def lines(path):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rb') as fh:
        for raw in fh:
            yield raw.decode('ascii').rstrip('\n')


class Fail(Exception):
    pass


def check_pin(meta, mutate='none'):
    """The header pin, read rather than admired.

    A trace is a recording of ONE oracle.  If the tree's oracle is not that
    oracle, the replay is comparing against something the trace never saw and
    every subsequent digest match is meaningless.
    """
    for name in sorted(PIN):
        key = 'sha_' + name
        want = meta.get(key)
        if not want:
            raise Fail('ORACLE PIN: trace header has no %s -- it predates the '
                       'pin and cannot be validated' % key)
        path = PIN[name]
        if not os.path.exists(path):
            raise Fail('ORACLE PIN: %s is not in this tree at %s' % (name, path))
        got = sha256_file(path)
        if mutate == 'oracle-pin':
            got = 'deadbeef' + got[8:]
        if got != want:
            raise Fail('ORACLE PIN VOID: %s is %s in this tree, the trace was '
                       'recorded against %s. The trace is a recording of a '
                       'DIFFERENT oracle. Remedy: python eq1_record.py '
                       '--rerecord <trace>'
                       % (os.path.basename(path), got[:12], want[:12]))


def replay(path, mutate='none'):
    meta = None
    n = 0
    pool = deque()
    nbytes = 0
    maxb = 0
    fb = 0
    qdrops = 0
    lastqd = 0
    tickshed = 0
    tick = -1
    fseq = []
    assigned = []
    arrivals = placed = refused = injected = skipped = shed = 0
    emis = hashlib.sha256()
    body = hashlib.sha256()
    trailer = None
    totals = None
    next_seq = 0

    def bound(forced=False):
        nonlocal nbytes, qdrops
        if mutate == 'no-bound':
            return
        if mutate in ('bound-at-tick', 'bound-at-ctl') and not forced:
            return
        while len(pool) > 1 and nbytes > maxb:
            if mutate == 'shed-newest':
                pool.pop()
            else:
                pool.popleft()
            nbytes -= fb
            qdrops += 1

    def tick_boundary():
        nonlocal lastqd, tickshed, shed
        if mutate == 'bound-at-tick' or (mutate == 'bound-at-ctl' and tick % 10 == 0):
            bound(forced=True)
        got = qdrops - lastqd
        if got != tickshed:
            raise Fail('tick %d: shed %d, oracle shed %d' % (tick, got, tickshed))
        lastqd = qdrops
        shed += got
        tickshed = 0

    def draw(idx, want, refuse):
        nonlocal nbytes, next_seq
        if not pool:
            raise Fail('tick %d: draw on link %d but the pool is EMPTY' % (tick, idx))
        seq = pool.popleft()
        nbytes -= fb
        if want is not None and seq != want:
            raise Fail('tick %d: link %d drew seq %d, oracle drew %d'
                       % (tick, idx, seq, want))
        if refuse:
            if mutate == 'fseq-burn':
                fseq[idx] += 1
            if mutate == 'rollback-drop':
                return None
            if mutate == 'rollback-tail':
                pool.append(seq)
            else:
                pool.appendleft(seq)
            nbytes += fb
            bound()
            return None
        return seq

    for line in lines(path):
        if line.startswith('E|'):
            trailer = line[2:]
            break
        body.update((line + '\n').encode('ascii'))
        if not line or line[0] == '#':
            continue
        f = line.split('|')
        k = f[0]
        if k == 'V':
            if f[1] != '2':
                raise Fail('trace version %s, this replay speaks 2' % f[1])
        elif k == 'M':
            meta = dict(kv.split('=', 1) for kv in f[1:])
            check_pin(meta, mutate)
            n = int(meta['n'])
            fb = int(meta['frame_bytes'])
            maxb = int(meta['pool_max_bytes'])
            fseq = [0] * n
            assigned = [0] * n
        elif k in ('L', 'C', 'Cd'):
            pass
        elif k == 'T':
            tick_boundary()
            tick = int(f[1])
        elif k == 'A':
            want = int(f[1])
            seq = next_seq if mutate != 'seq-at-draw' else None
            next_seq += 1
            if mutate == 'seq-at-draw':
                # stamp at draw: park a placeholder and number it on the way out
                seq = -1
            elif seq != want:
                raise Fail('tick %d: stamped seq %d, oracle stamped %d'
                           % (tick, seq, want))
            pool.append(seq if seq is not None else -1)
            nbytes += fb
            bound()
            arrivals += 1
        elif k == 'S':
            tickshed += 1
        elif k == 'D':
            idx = int(f[1])
            want = int(f[2])
            if f[3] == 'a':
                fs = int(f[4])
                got = draw(idx, None if mutate == 'seq-at-draw' else want, False)
                if mutate == 'seq-at-draw':
                    got = placed          # a draw-order sequence number
                if fseq[idx] != fs:
                    raise Fail('tick %d: link %d fseq %d, oracle %d'
                               % (tick, idx, fseq[idx], fs))
                pid = 0 if mutate == 'pathid-zero' else idx
                emis.update(frame_bytes(pid, got, fseq[idx], meta))
                fseq[idx] += 1
                assigned[idx] += 1
                placed += 1
            else:
                draw(idx, want, True)
                refused += 1
        elif k == 'R':
            if len(f) > 1 and f[1]:
                for s in f[1].split(','):
                    if not pool:
                        skipped += 1
                        continue
                    draw(int(s), None, True)
                    injected += 1
        elif k == 'P':
            wn = int(f[2])
            h = hashlib.sha256()
            for s in pool:
                h.update((s & 0xFFFFFFFF).to_bytes(4, 'big'))
            if len(pool) != wn or h.hexdigest()[:32] != f[3]:
                raise Fail('tick %s: pool diverged -- oracle depth=%d digest=%s, '
                           'replay depth=%d digest=%s'
                           % (f[1], wn, f[3], len(pool), h.hexdigest()[:32]))
        elif k == 'X':
            totals = dict(kv.split('=', 1) for kv in f[1:])
        else:
            raise Fail('unknown record %r' % k)

    tick_boundary()
    if totals is None:
        raise Fail('no X totals line -- trace truncated')
    if body.hexdigest() != trailer:
        raise Fail('trace body sha256 mismatch -- trace corrupt')
    got = emis.hexdigest()
    if got != totals['emission_sha256']:
        raise Fail('EMISSION STREAM DIVERGED: oracle %s, replay %s'
                   % (totals['emission_sha256'], got))
    for name, val in (('arrivals', arrivals), ('placed', placed),
                      ('refused', refused), ('shed', shed)):
        if int(totals[name]) != val:
            raise Fail('%s: oracle %s, replay %d' % (name, totals[name], val))
    wa = [int(x) for x in totals['assigned'].split(',')]
    if wa != assigned:
        raise Fail('assigned: oracle %s, replay %s' % (wa, assigned))
    return dict(n=n, ticks=tick + 1, arrivals=arrivals, placed=placed,
                shed=shed, injected=injected, skipped=skipped,
                emission=got[:16])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('traces', nargs='+')
    ap.add_argument('--mutate', default='none', choices=sorted(MUTATIONS))
    ap.add_argument('--mutate-all', action='store_true')
    a = ap.parse_args()

    paths = []
    for p in a.traces:
        paths.extend(sorted(glob.glob(p)) or [p])

    rc = 0
    if a.mutate_all:
        muts = sorted(MUTATIONS)
        killed = {m: [] for m in muts}
        print('MUTATION MATRIX -- `.` = trace passed (BLIND to the mutation), '
              '`X` = trace failed (mutation KILLED)')
        print('%-16s %s' % ('mutation', ' '.join('%-2d' % i for i in range(len(paths)))))
        for i, p in enumerate(paths):
            print('#  trace %d = %s' % (i, p))
        for m in muts:
            row = []
            for p in paths:
                try:
                    replay(p, m)
                    row.append('. ')
                except Fail:
                    row.append('X ')
                    killed[m].append(p)
            print('%-16s %s   %s' % (m, ' '.join(row), MUTATIONS[m]))
        print()
        for m in muts:
            if m == 'none':
                if killed[m]:
                    print('FAIL  the unmutated replay does not reproduce %s'
                          % killed[m])
                    rc = 1
                continue
            if not killed[m]:
                print('BLIND %-16s no trace in this set detects it' % m)
                rc = 1
        if rc == 0:
            print('OK    every mutation is killed by at least one trace, and the '
                  'unmutated replay reproduces every trace')
        return rc

    for p in paths:
        try:
            r = replay(p, a.mutate)
            print('PASS %-28s N=%d ticks=%d arr=%d placed=%d shed=%d inj=%d '
                  'skip=%d emis=%s'
                  % (p.split('/')[-1], r['n'], r['ticks'], r['arrivals'],
                     r['placed'], r['shed'], r['injected'], r['skipped'],
                     r['emission']))
        except Fail as e:
            print('FAIL %-28s %s' % (p.split('/')[-1], e))
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
