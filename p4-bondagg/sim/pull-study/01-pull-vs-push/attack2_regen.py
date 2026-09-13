#!/usr/bin/env python3
# =============================================================================
# attack2_regen.py -- ADVERSARIAL attack #2 on the ms-gate's regen/drain-EWMA.
# Uses the REAL PullSim + run_push from pull_study.py (unmodified logic).
# The study found ONE starvation ratchet, fixed it with probe-up regen
# (drain_ewma += 0.02*(cap0-drain_ewma) when idle).  Attack the fix with stall
# patterns it was NOT tuned on: rapid flapping, asymmetric duty, soft partial
# dips, correlated-both-tethers.  Look for: (a) starvation (tether share stuck
# ~0 after revive), (b) oscillation (share variance), (c) push-like lag return.
# =============================================================================
import sys, math, statistics
from pull_study import (PullSim, run_push, agg, med, MKEYS, NPathSpec, eth_cap)


def cap_from_windows(base, amp, period, windows, wval=0.0, floor=3000.0):
    """windows: list of (a,b); cap forced to wval inside them, else swing."""
    def f(t):
        for (a, b) in windows:
            if a <= t < b:
                return wval
        return max(floor, base + amp*math.sin(2*math.pi*t/period))
    return f


def share_stats(m, tet_idx=0):
    """post-revive tether share behaviour from share_win: mean + variance + min."""
    sw = m['share_win']
    sh = [s[tet_idx] for (t, s) in sw if t > 1.0]
    if not sh:
        return 0.0, 0.0, 0.0
    return (sum(sh)/len(sh), statistics.pstdev(sh) if len(sh) > 1 else 0.0, min(sh))


def revive_lag(m, tet_idx, revive_t, healthy_thresh=0.12, cap=1.5):
    """time after a revive instant until tether share climbs back above thresh."""
    for (t, s) in m['share_win']:
        if t >= revive_t and s[tet_idx] >= healthy_thresh:
            return t - revive_t
    return cap


def run_case(name, tcap, seeds, T=10.0, offer_scale=0.85):
    ecap = eth_cap()
    offer = offer_scale*(29000+78000); ofn = lambda t: offer
    def specs():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    push = [run_push(specs(), ofn, T, sd) for sd in range(seeds)]
    pm   = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40).run()
            for sd in range(seeds)]
    pml  = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40, lat_bias=True).run()
            for sd in range(seeds)]
    pb   = [PullSim(specs(), ofn, T, sd, lbuf_ms=40).run() for sd in range(seeds)]
    a = agg(push, MKEYS); b = agg(pm, MKEYS); c = agg(pml, MKEYS); d = agg(pb, MKEYS)
    # share dynamics from a single representative seed
    sh_mean, sh_std, sh_min = share_stats(pm[0])
    dgp  = 100*(b['gp']/a['gp']-1) if a['gp'] else 0
    dgpl = 100*(c['gp']/a['gp']-1) if a['gp'] else 0
    print(f"[{name}]")
    print(f"   PUSH      gp={a['gp']:6.0f} loss={a['loss_pct']:4.1f}% p95={a['p95']:3.0f} tdrop={a['taildrops']:5.0f}")
    print(f"   PULL bytes gp={d['gp']:6.0f} loss={d['loss_pct']:4.1f}% p95={d['p95']:3.0f} tdrop={d['taildrops']:5.0f}")
    print(f"   PULL ms   gp={b['gp']:6.0f} loss={b['loss_pct']:4.1f}% p95={b['p95']:3.0f} tdrop={b['taildrops']:5.0f} ({dgp:+.0f}%)"
          f"  tshare mean={sh_mean:.2f} std={sh_std:.2f} min={sh_min:.2f}")
    print(f"   PULL ms+l gp={c['gp']:6.0f} loss={c['loss_pct']:4.1f}% p95={c['p95']:3.0f} tdrop={c['taildrops']:5.0f} ({dgpl:+.0f}%)")
    return dict(push=a, pms=b, pml=c, pb=d)


def main():
    try: sys.stdout.reconfigure(encoding='utf-8')
    except Exception: pass
    seeds = 8 if 'quick' in sys.argv else 20
    print("#"*80)
    print(f"# ATTACK 2  REGEN / DRAIN-EWMA ROBUSTNESS  seeds={seeds}")
    print("#   +% is PULL gp vs PUSH gp.  Watch tshare min (starvation) & std (oscillation).")
    print("#"*80)

    # 1. RAPID FLAPPING: on/off every ~150ms for a 2s stretch (regen has ~ (1/0.02)*
    #    10ms = 500ms time-constant; flapping faster than that could ratchet).
    flaps = []
    t = 2.0
    while t < 4.0:
        flaps.append((t, t+0.15)); t += 0.30
    run_case("rapid-flap 150ms on/off x2s",
             cap_from_windows(29000, 24000, 3.1, flaps), seeds); print()

    # 2. ASYMMETRIC: long 0.9s stall, then only 0.3s revive, repeated -- little
    #    healthy window to re-backlog & re-measure => worst case for busy-gate.
    asym = [(2.2, 3.1), (3.4, 4.3), (4.6, 5.5), (5.8, 6.7)]
    run_case("asymmetric long-stall/short-revive",
             cap_from_windows(29000, 24000, 3.1, asym), seeds); print()

    # 3. SOFT PARTIAL DIP: cap to 15% (4350), not 0 -- socket still drains slowly,
    #    busy-gate keeps measuring a LOW rate; does drain_ewma track or lock low?
    run_case("soft partial dip to 15%%",
             cap_from_windows(29000, 24000, 3.1,
                              [(2.5,3.3),(4.5,5.3),(6.5,7.3)], wval=4350.0), seeds); print()

    # 4. CORRELATED both tethers stall together (N=3): a shared radio-congestion
    #    event both cell paths hit at once -> shared FIFO has nowhere to drain.
    print("[correlated-both-stall N=3]")
    tA = cap_from_windows(29000, 24000, 3.1, [(3.0,3.8),(6.0,6.8)])
    tB = cap_from_windows(22000, 17000, 2.3, [(3.0,3.8),(6.0,6.8)])  # SAME windows
    ecap = eth_cap(); offer = 0.85*(29000+22000+78000); ofn=lambda t: offer
    def specs3():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tA),
                NPathSpec(23000, 70, 20.0, 0.010, cap_fn=tB),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    for sc in ('push', 'pull-ms', 'pull-ms-lat'):
        if sc == 'push':
            ms = [run_push(specs3(), ofn, 10.0, sd) for sd in range(seeds)]
        elif sc == 'pull-ms':
            ms = [PullSim(specs3(), ofn, 10.0, sd, gate='ms', target_ms=40).run()
                  for sd in range(seeds)]
        else:
            ms = [PullSim(specs3(), ofn, 10.0, sd, gate='ms', target_ms=40,
                          lat_bias=True).run() for sd in range(seeds)]
        a = agg(ms, MKEYS)
        print(f"   {sc:12s} gp={a['gp']:6.0f} loss={a['loss_pct']:4.1f}% "
              f"p95={a['p95']:3.0f} tdrop={a['taildrops']:5.0f}")


if __name__ == '__main__':
    main()
