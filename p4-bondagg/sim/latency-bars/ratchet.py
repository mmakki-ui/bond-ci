#!/usr/bin/env python3
# =============================================================================
# ratchet.py -- the LATENESS RATCHET reorder hold, as an executable function.
# Task U14 (docs/ROADMAP.md epic 1, OBJ-D).
#
# WHY THIS FILE EXISTS
# -----------------------------------------------------------------------------
# The ratchet is the derived hold that replaces the six invented constants in the
# shipping formulas (`paths.go:102` +250, clamped to [HoldMin, HoldMax] =
# [150, 350] ms at `main.go:21-22`; `nsched_model.py:1412` +130/floor 80).
# `paths.go:74` is the `Hold()` signature and `:43` states the formula in prose;
# neither carries the constant. It is SPECIFIED in
# `docs/knowledge/design/modes-max-speed-design.md` sec 4.4 (and r1
# `p4-bondagg/sim/modes-r2-study/fable-modes-design.md` sec 4.4) and, before this
# unit, IMPLEMENTED NOWHERE:
#
#   * `modes-r2-study/holdlib.py:51  dyn_release()` is the QUANTILE hold, which
#     the design REFUTES (r1 sec 4.2). (It was cited as `:57` -- `:51` is the
#     def, re-measured with `grep -n 'def dyn_release' holdlib.py`.)
#   * `modes-r2-study/expF_marginal.py:98`, `expG_mid.py:133`, and
#     `expH_frontier.py:175` all build a "ratchet" that is
#     `max(late_gaps(whole run)) + TICK` applied as a FIXED hold -- a
#     CLAIRVOYANT upper bound, not the online statistic. It knows the largest
#     burst before the run starts. Useful as a bound; it is not the design.
#     (Cited as :97 / :132 / :180; all three were off by one to five lines.)
#
# So HOLD-1..4 could not be gated against anything until the online form existed.
# This is that form, and HOLD-4 is its unit test.
#
# THE DEFINITION, verbatim from the design (r1 sec 4.4 / r2 sec 4.4):
#
#     hold = max(L observed since last reset, seed) + granularity
#
#     L(f) = arrival(f) - t_block(f)   for every frame that arrives after the
#            ring wanted it, where t_block is when the frontier first blocked on
#            (or passed) f's seq. One definition covers BOTH late frames and
#            hole-stragglers (frames run-skipped behind a genuine loss).
#     seed = spread(D-hat) over member paths at the last reset (0 while one path).
#     granularity = the ring tick period. THE ONLY FLOOR.
#     reset = path-set membership change (hotplug add/remove, FSM DEAD/revive).
#             windowLESS: no time constant, by construction (r1 sec 4.2 measured
#             the window failing in BOTH directions).
#
# GRANULARITY IS 10 ms HERE, AND THE STUDY SAID 1 ms. Corrected, with the check:
#   `nsched_model.py:62  DT = 0.010` -- the model tick is 10 ms.
#   `modes-r2-study/expH_frontier.py:21  TICK = 1.0  # model granularity, ms (DT)`
# is wrong by 10x, and every "+2*gran" tolerance in the r1 bar table (sec 8) was
# computed against it. `holdlib.py:51` had it right -- the `dyn_release` default
# is `gran_ms=10.0`, converted at `:63` and applied as the floor at `:68`. (This
# was cited as `holdlib.py:96`, which is the un-censoring branch, not the
# default.) The battery takes granularity from `M.DT * 1000` so it cannot drift
# from the model again, and `latency_battery._gran_guard()` asserts that against
# nsched_model.py's SOURCE plus r1 sec 8's <=10 ms bound.
#
# STRUCTURE: the release loop below is `holdlib.py:66-119 dyn_release()` with ONE
# substitution -- `hold_now()` returns the ratchet instead of a trailing-window
# quantile. Kept deliberately close to that function so the two are diffable: the
# quantile form is the refuted alternative and the difference between them should
# stay one expression, not one file.
# =============================================================================
INF = float('inf')


def late_runs(arr):
    """Maximal contiguous seq runs that arrive AFTER a higher seq already did.

    Returns a list of run lengths (frames). Used for the ONE-EVENT bound in
    HOLD-1/HOLD-2: the ratchet provably cannot cover the first macro event on a
    path set (design r1 sec 4.4, "first-macro-event honesty"), so its late count
    may exceed a clairvoyant fixed hold's by at most one event's frames.

    Structural, no constant, no threshold: a frame is late iff some higher seq
    arrived before it, which is exactly the condition an in-order ring blocks on.
    """
    seqs = sorted(sq for sq, a in arr.items() if a is not None)
    m = INF
    late = set()
    for sq in reversed(seqs):
        a = arr[sq]
        if a > m:
            late.add(sq)
        if a < m:
            m = a
    runs = []
    cur = 0
    prev = None
    for sq in seqs:
        if sq in late and (prev is None or sq == prev + 1):
            cur += 1
        elif sq in late:
            runs.append(cur) if cur else None
            cur = 1
        else:
            if cur:
                runs.append(cur)
            cur = 0
        prev = sq
    if cur:
        runs.append(cur)
    return runs


def ratchet_release(items, gran_ms, seed_ms=0.0, resets=()):
    """Online lateness-ratchet in-order release.

    items   : [(arrival_time_s, seq)]
    gran_ms : ring tick period, ms. The only floor. Physical, not a knob.
    seed_ms : spread(D-hat) at the last reset, ms. 0 while one path.
    resets  : sorted times (s) of path-set membership changes. The ratchet drops
              back to `seed` at each. Empty = no membership event in the trace,
              which is the case for every post-hoc rescoring in this battery
              (the rigs hold their path set for the whole run).

    Returns (release{seq: time}, skips, holds) where `holds` is the [(t, hold_ms)]
    trace -- HOLD-4 asserts on it directly.
    """
    items = sorted((a, sq) for (a, sq) in items)
    if not items:
        return {}, 0, []
    n = len(items)
    max_seq = max(sq for _, sq in items)
    next_seq = min(sq for _, sq in items)
    gran = gran_ms / 1000.0
    seed = seed_ms / 1000.0
    present = {}
    release = {}
    passed = {}          # seq -> time the frontier passed it (skip instant)
    holds = []
    skips = 0
    ptr = 0
    blocked_at = None
    maxL = 0.0           # THE ratchet: max L since the last reset
    rst = list(resets)
    ri = 0

    def hold_now(t):
        nonlocal maxL, ri
        while ri < len(rst) and rst[ri] <= t:
            maxL = 0.0          # membership change -> back to the seed
            ri += 1
        return max(maxL, seed) + gran

    while ptr < n or next_seq <= max_seq:
        t_arr = items[ptr][0] if ptr < n else INF
        t_hold = (blocked_at + hold_now(blocked_at)) if blocked_at is not None else INF
        if t_arr == INF and t_hold == INF:
            break
        if t_hold <= t_arr:
            clock = t_hold
            if present:
                target = max(present)
                while next_seq <= target:
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = max(clock, a)
                    else:
                        skips += 1
                        passed[next_seq] = clock
                    next_seq += 1
            else:
                tgt = items[ptr][1] if ptr < n else max_seq + 1
                while next_seq < tgt:
                    skips += 1
                    passed[next_seq] = clock
                    next_seq += 1
            blocked_at = None
        else:
            clock = t_arr
            while ptr < n and items[ptr][0] == t_arr:
                sq = items[ptr][1]
                if sq >= next_seq and sq not in release:
                    present[sq] = t_arr
                elif sq in passed:
                    # hole-straggler: a run-skipped seq arrives after all. This is
                    # the un-censored half of L, and the design measures it as
                    # load-bearing (gap-only sampling cost 4427 late at S3@90k).
                    maxL = max(maxL, t_arr - passed.pop(sq))
                ptr += 1
        moved = False
        while next_seq in present:
            a = present.pop(next_seq)
            if blocked_at is not None and a >= blocked_at and next_seq not in release:
                maxL = max(maxL, a - blocked_at)     # head waited, then arrived
            release[next_seq] = max(clock, a)
            next_seq += 1
            moved = True
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None or moved:
                blocked_at = clock
                holds.append((clock, hold_now(clock) * 1000.0))
        else:
            blocked_at = None
    return release, skips, holds
