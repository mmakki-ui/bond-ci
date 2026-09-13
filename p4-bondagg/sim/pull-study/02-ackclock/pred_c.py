#!/usr/bin/env python3
# =============================================================================
# Scheduler C predictions (i) and (ii) -- reuses ackclock_sim.py verbatim.
# (i) MID-drop AND MID-shape: C vs pull/A/push/oracle -- gp/loss/p50/p95/p99
# (ii) EDGE: C p95 vs pull/A
# 24 seeds, paired physics, medians.
# =============================================================================
import sys, time
from ackclock_sim import Sim, agg, make_defs

try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24
T = 10.0
off2 = 0.85 * (29000 + 78000)

CORE = [
    ("pull",   'pull',   {}),
    ("push",   'push',   {}),
    ("oracle", 'oracle', {}),
    ("A ewma", 'ewma',   dict(mirror=True)),
    ("C",      'C',      {}),   # all defaults from Sim.__init__ (estimator-free law)
]
ORDER = [c[0] for c in CORE]


def runset(defs_fn, offer, scheds):
    ofn = lambda t: offer
    out = {}
    for name, sched, kw in scheds:
        ms = [Sim(defs_fn(), ofn, T, sd, sched=sched, **kw).run() for sd in range(SEEDS)]
        out[name] = agg(ms)
    return out


def hdr():
    print("    %-10s %7s %6s %5s %5s %5s %6s %6s %6s" %
          ("scheduler", "gp", "loss%", "p50", "p95", "p99", "depth", "tdrop", "late"))


def show(tag, res, order):
    print(f"  [{tag}]")
    hdr()
    for name in order:
        a = res[name]
        print("    %-10s %7.0f %6.1f %5.0f %5.0f %5.0f %6.0f %6.0f %6.0f" %
              (name, a['gp'], a['loss'], a['p50'], a['p95'], a['p99'],
               a['depth'], a['tdrop'], a['late']))
    return res


def main():
    t0 = time.time()
    print("#" * 78)
    print(f"# SCHEDULER C PREDICTIONS  seeds={SEEDS}")
    print("#" * 78)

    print("\n=== EDGE (spotty cap on local socket) ===")
    r_edge = show("EDGE", runset(lambda: make_defs('edge'), off2, CORE), ORDER)
    print(f"  (EDGE elapsed {time.time()-t0:.0f}s)")

    print("\n=== MID-drop (spotty cap downstream, hard 400ms dropouts) ===")
    r_middrop = show("MID-drop",
                      runset(lambda: make_defs('mid', local_mult=20.0), off2, CORE), ORDER)
    print(f"  (MID-drop elapsed {time.time()-t0:.0f}s)")

    print("\n=== MID-shape (downstream throttle to 4Mb, NO outage) ===")
    r_midshape = show("MID-shape",
                       runset(lambda: make_defs('mid', local_mult=20.0, shaping=True), off2, CORE), ORDER)
    print(f"  (MID-shape elapsed {time.time()-t0:.0f}s)")

    print(f"\n(elapsed {time.time()-t0:.0f}s)")

    # ---------------- verdicts ----------------
    print("\n" + "#" * 78)
    print("# VERDICTS")
    print("#" * 78)

    def pf(cond):
        return "PASS" if cond else "FAIL"

    # (i) MID-drop AND MID-shape: PASS if C loss<=A loss AND C p50~=oracle(~100ms)
    for tag, r in (("MID-drop", r_middrop), ("MID-shape", r_midshape)):
        c = r["C"]; a = r["A ewma"]; o = r["oracle"]
        loss_ok = c['loss'] <= a['loss']
        p50_ok = abs(c['p50'] - o['p50']) <= 15.0 and abs(c['p50'] - 100.0) <= 25.0
        print(f"(i) [{tag}] C loss={c['loss']:.1f} vs A loss={a['loss']:.1f} "
              f"(C<=A: {pf(loss_ok)})   C p50={c['p50']:.0f} vs oracle p50={o['p50']:.0f} "
              f"(~100ms, within tol: {pf(p50_ok)})   => {pf(loss_ok and p50_ok)}")

    # (ii) EDGE: C p95 within ~10% of pull p95 (known baseline 242)
    c = r_edge["C"]; pu = r_edge["pull"]; a = r_edge["A ewma"]
    within10 = abs(c['p95'] - pu['p95']) <= 0.10 * pu['p95']
    print(f"(ii) [EDGE] C p95={c['p95']:.0f} vs pull p95={pu['p95']:.0f} (known baseline 242) "
          f"vs A p95={a['p95']:.0f} (known baseline 311)   "
          f"|delta|={abs(c['p95']-pu['p95']):.0f} (<=10% of pull={0.10*pu['p95']:.1f}: {pf(within10)})   "
          f"=> {pf(within10)}")


if __name__ == '__main__':
    main()
