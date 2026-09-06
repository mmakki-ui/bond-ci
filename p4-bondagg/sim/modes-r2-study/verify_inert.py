#!/usr/bin/env python3
# INDEPENDENT re-verification of the reorder_release(hold==0) fix inertness.
# Pre-fix function re-implemented HERE from git HEAD text (not imported), then
# compared byte-wise against the PATCHED nsched_model.reorder_release on real
# runs from BOTH rigs at 1/18/43/93/223/343 ms.
import sys, time
WT = r"C:/Users/mmakk/Claude Code/bond/.claude/worktrees/agent-a6b06a6d245073543/p4-bondagg/sim"
sys.path[0:0] = [WT + "/pull-study/03-reserved-composite", WT]
import reserved_composite as RC
import nsched_model as M

INF = float('inf')


def reorder_release_PRE(items, hold):
    """git-HEAD text of nsched_model.reorder_release, verbatim, pre-fix."""
    if not items:
        return {}, 0, 0
    arr = sorted(items)
    n = len(arr)
    max_seq = max(s for _, s in arr)
    next_seq = min(s for _, s in arr)
    present = {}; release = {}
    skips = 0; max_depth = 0
    blocked_at = None; ptr = 0
    while ptr < n or next_seq <= max_seq:
        t_arr = arr[ptr][0] if ptr < n else INF
        t_hold = (blocked_at + hold) if blocked_at is not None else INF
        if t_arr == INF and t_hold == INF:
            break
        if t_hold <= t_arr:
            clock = t_hold
            if present:
                target = max(present)
                while next_seq <= target:
                    a = present.pop(next_seq, None)
                    if a is not None:
                        release[next_seq] = clock if clock > a else a
                    else:
                        skips += 1
                    next_seq += 1
            else:
                tgt = arr[ptr][1] if ptr < n else max_seq + 1
                while next_seq < tgt:
                    skips += 1
                    next_seq += 1
            blocked_at = None
        else:
            clock = t_arr
            while ptr < n and arr[ptr][0] == t_arr:
                sq = arr[ptr][1]
                if sq >= next_seq and sq not in release:
                    present[sq] = t_arr
                ptr += 1
        while next_seq in present:
            a = present.pop(next_seq)
            release[next_seq] = clock if clock > a else a
            next_seq += 1
        if next_seq <= max_seq and next_seq not in present:
            if blocked_at is None:
                blocked_at = clock
        else:
            blocked_at = None
        if len(present) > max_depth:
            max_depth = len(present)
    return release, skips, max_depth


HOLDS = (0.001, 0.018, 0.043, 0.093, 0.223, 0.343)
RIGS = [
    ('edge-S3-90k', RC.build_rig([RC.eth(), RC.wifi(), RC.cellA(RC.DROPS_A)],
                                 bottleneck='edge'), lambda t: 90000.0, 'D'),
    ('mid-N2-0.65', RC.build_rig([RC.cellA(RC.DROPS_A), RC.eth()],
                                 bottleneck='mid'), lambda t: 0.65 * 107000, 'Dc'),
    ('edge-S4-50k', RC.build_rig([RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B),
                                  RC.cellC(RC.DROPS_C)], bottleneck='edge'),
     lambda t: 50000.0, 'D'),
]
bad = 0
for tag, defs, of, sch in RIGS:
    for sd in (0, 1, 2):
        sim = RC.SimD(defs, of, 9.0, sd, sched=sch,
                      reserve_frac=(0.0 if sch == 'D' else 0.25))
        sim.run()
        items = [(a, sq) for sq, a in sim.arr.items() if a is not None]
        for h in HOLDS:
            r0, k0, d0 = reorder_release_PRE(items, h)
            r1, k1, d1 = M.reorder_release(items, h)
            ok = (r0 == r1 and k0 == k1 and d0 == d1)
            if not ok:
                bad += 1
                print("  DIVERGENCE %s sd=%d hold=%.3f" % (tag, sd, h), flush=True)
        t0 = time.time()
        rz, kz, dz = M.reorder_release(items, 0.0)
        print("  %s sd=%d n=%d: hold>0 IDENTICAL at %s ms | hold=0 -> %.2fs "
              "rel=%d skips=%d depth=%d"
              % (tag, sd, len(items), "/".join("%.0f" % (h * 1000) for h in HOLDS),
                 time.time() - t0, len(rz), kz, dz), flush=True)
print("VERDICT: %s" % ("INERT (0 divergences)" if bad == 0 else "%d DIVERGENCES" % bad))
