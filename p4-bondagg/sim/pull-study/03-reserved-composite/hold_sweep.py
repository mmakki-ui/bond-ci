#!/usr/bin/env python3
# =============================================================================
# hold_sweep.py -- WHAT DOES THE REORDER HOLD ACTUALLY COST?
#
# The question Mo raised: speed mode was designed for goodput/loss; latency was
# never designed for, and the reorder hold is arbitrary scaffolding. Three
# DIFFERENT formulas ship today:
#   daemon/paths.go Hold():   clamp(spread + 3*jit + 250ms, 150..350)
#   sim/nsched_model.py:1403: clamp(spread + 3*jit + 130ms,  80..350)
#   ackclock_sim hold_legacy: same as nsched (130/80..350)
# Mo's proposal: hold = max(RTT over ACTIVE) + jitter  (drop the x3 and the
# constant), i.e. spread + 1*jit.
#
# METHOD: the hold is applied POST-HOC in finalize() -- it does not feed back
# into the scheduler in this sim. So ONE simulation run can be scored under
# EVERY hold policy: perfectly paired, zero re-run variance.
#
# HONEST LIMITATION (state it, do not hide it): because hold is post-hoc here,
# this measures the DELIVERY-SIDE cost of the hold only. In the real daemon the
# hold also feeds the loss meter (main.go: lossM[p].Data(fseq, now, hd)), so a
# shorter hold reports loss sooner and can perturb control. That coupling is
# NOT modelled here and must be checked before shipping a shorter hold.
# =============================================================================
import sys, os, time
try: sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
except Exception: pass
# RUN THIS UNBUFFERED AND SCOPED:
#   SEEDS=3 RIGS=edge2 PYTHONPATH=../.. python -u hold_sweep.py
# Lesson paid for once (2026-08-29): the full matrix redirected to a file with no
# -u produced ZERO output for an hour and was killed with nothing to show, while
# the single-rig question it was asked took 2 SECONDS. Scope to the rig that
# answers the question, print per seed, never run it blind.

import reserved_composite as RC
import ackclock_sim as A
from nsched_model import reorder_release

PKT_KB = A.PKT_KB

T = 9.0
SEEDS = int(os.environ.get('SEEDS', '12'))
LOADS = [float(x) for x in os.environ.get('LOADS', '0.35,0.65,0.85').split(',')]
# RIGS: comma list of {edge2, mid2, edge3}; default edge2 (the cheap one that
# answers the hold-cost question). Opt into the rest deliberately.
RIGS = os.environ.get('RIGS', 'edge2').split(',')


def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


# ---- hold policies: name -> (spread_ms, maxjit_ms) -> hold_ms ---------------
def clamp(v, lo, hi):
    return max(lo, min(hi, v))


POLICIES = [
    ('daemon    (spread+3j+250, 150..350)', lambda s, j: clamp(s + 3 * j + 250.0, 150.0, 350.0)),
    ('model     (spread+3j+130,  80..350)', lambda s, j: clamp(s + 3 * j + 130.0, 80.0, 350.0)),
    ('spread+3j (no constant)            ', lambda s, j: clamp(s + 3 * j, 0.0, 350.0)),
    ('spread+2j                          ', lambda s, j: clamp(s + 2 * j, 0.0, 350.0)),
    ('spread+1j  <- Mo: max(RTT-act)+jit ', lambda s, j: clamp(s + 1 * j, 0.0, 350.0)),
    ('spread only                        ', lambda s, j: clamp(s, 0.0, 350.0)),
    # NB hold=0 HANGS: nsched_model.reorder_release() does not terminate at hold==0
    # (clock cannot advance past blocked_at; every positive hold returns in ~0.02s).
    # Measured 2026-08-29 -- this is what burned an hour. The zero-hold / ring-delete
    # option is therefore UNMEASURABLE in this model until reorder_release is fixed.
    # 1ms == the model tick, the smallest evaluable stand-in.
    ('granularity only (1ms model tick)  ', lambda s, j: 1.0),
]


def score(sim, hold_ms):
    """Re-score a finished Sim under an alternative reorder hold."""
    deliv_items = [(a, seq) for seq, a in sim.arr.items() if a is not None]
    release, skips, depth = reorder_release(deliv_items, hold_ms / 1000.0)
    rel = set(release)
    late = sum(1 for (a, sq) in deliv_items
               if sq not in rel and sim.enq.get(sq, 0) > sim.warm)
    Teff = sim.T - sim.warm
    lat = []
    deliv = 0
    for seq, rt in release.items():
        st = sim.enq[seq]
        if st > sim.warm:
            deliv += 1
            lat.append((rt - st) * 1000.0)
    lat.sort()

    def pct(p):
        return lat[min(len(lat) - 1, int(p * (len(lat) - 1)))] if lat else 0.0
    gp = deliv * PKT_KB / Teff
    loss = 100.0 * (sim.offered_post - deliv) / sim.offered_post if sim.offered_post else 0.0
    return dict(gp=gp, loss=max(0.0, loss), p50=pct(.5), p95=pct(.95), p99=pct(.99),
                skips=skips, late=late, hold=hold_ms)


def run_rig(label, defs, nom, scheds):
    print("=" * 108)
    print("RIG: %s   T=%.1fs  SEEDS=%d  (paired: one run scored under every hold policy)" %
          (label, T, SEEDS))
    owds = [d['down_owd'] + d['loc_owd'] for d in defs]
    jits = [d['jit'] for d in defs]
    spread = max(owds) - min(owds)
    mj = max(jits)
    print("   path owds(ms)=%s  jits(ms)=%s  ->  spread=%.1f  max_jit=%.1f" %
          ([round(o, 1) for o in owds], [round(j, 1) for j in jits], spread, mj))
    print("=" * 108)
    for load in LOADS:
        of = lambda t, _n=nom, _L=load: _L * _n
        for sch in scheds:
            acc = {name: [] for name, _ in POLICIES}
            t0 = time.time()
            for sd in range(SEEDS):
                if sch == 'Dc':
                    sim = RC.SimD(defs, of, T, sd, sched='Dc')
                else:
                    sim = A.Sim(defs, of, T, sd, sched=sch, mirror=False)
                sim.run()
                print("    .. load=%.2f sched=%-5s seed %d/%d  (%.0fs)"
                      % (load, sch, sd + 1, SEEDS, time.time() - t0), flush=True)
                for name, fn in POLICIES:
                    acc[name].append(score(sim, fn(spread, mj)))
            print()
            print("  load=%.2f  sched=%s" % (load, sch))
            print("  %-36s %7s %9s %7s %7s %8s %8s %7s" %
                  ('hold policy', 'holdms', 'gp', 'loss%', 'p50ms', 'p95ms', 'p99ms', 'skips'))
            print("  " + "-" * 100)
            base = None
            for name, _ in POLICIES:
                rows = acc[name]
                r = dict(hold=rows[0]['hold'],
                         gp=med([x['gp'] for x in rows]),
                         loss=med([x['loss'] for x in rows]),
                         p50=med([x['p50'] for x in rows]),
                         p95=med([x['p95'] for x in rows]),
                         p99=med([x['p99'] for x in rows]),
                         skips=med([x['skips'] for x in rows]))
                if base is None:
                    base = r
                print("  %-36s %7.0f %9.0f %7.2f %7.1f %8.1f %8.1f %7.0f  %s" %
                      (name, r['hold'], r['gp'], r['loss'], r['p50'], r['p95'], r['p99'],
                       r['skips'],
                       ("" if r is base else "dp50=%+.0f dp95=%+.0f dloss=%+.2f" %
                        (r['p50'] - base['p50'], r['p95'] - base['p95'],
                         r['loss'] - base['loss']))))
            sys.stdout.flush()


t0 = time.time()
archs2 = [RC.cellA(RC.DROPS_A), RC.eth()]
nom2 = sum(a['base'] for a in archs2)
archs3 = [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.eth()]
nom3 = sum(a['base'] for a in archs3)
if 'edge2' in RIGS:
    run_rig("N2 EDGE  cellA+eth", RC.build_rig(archs2, bottleneck='edge'), nom2, ('pull',))
if 'mid2' in RIGS:
    # NOTE: slower than edge2 by a large factor (local_cap = base*20 -> far more
    # frames). Time-box it; do not launch it blind.
    run_rig("N2 MID   cellA+eth", RC.build_rig(archs2, bottleneck='mid'), nom2, ('pull', 'ewma'))
if 'edge3' in RIGS:
    run_rig("N3 EDGE  cellA+cellB+eth", RC.build_rig(archs3, bottleneck='edge'), nom3, ('pull',))

print()
print("elapsed %.1fs" % (time.time() - t0))
