#!/usr/bin/env python3
# pull_exp.py -- experiment driver for the PUSH vs PULL study (imports pull_study)
import sys, math
from pull_study import (PullSim, run_push, agg, med, MKEYS, NPathSpec,
                        tether_cap, eth_cap, PKT_KB)


def react_time(share_win, tet_idx, t0, thresh=0.05, cap=2.0):
    for (t, sh) in share_win:
        if t > t0 and sh[tet_idx] < thresh:
            return t - t0
    return cap


def wasted_on(frames, tet_idx, t0, t1):
    tot = 0; lost = 0
    for seq, (st, idx, arr, c) in frames.items():
        if idx == tet_idx and t0 <= st < t1:
            tot += 1
            if arr is None:
                lost += 1
    return tot, lost


def win_gp_frames(frames, release, t0, t1):
    rel = set(release)
    n = sum(1 for seq, (st, idx, arr, c) in frames.items()
            if t0 <= st < t1 and seq in rel)
    return n * PKT_KB / (t1 - t0)


def line(tag, m):
    return (f"  {tag:<16} gp={m['gp']:6.0f} util={100*m['util']:4.1f}% "
            f"loss={m['loss_pct']:4.1f}% p50={m['p50']:3.0f} p95={m['p95']:3.0f} "
            f"p99={m['p99']:3.0f} depth={m['depth']:5.0f} "
            f"late={m['late_discard']:4.0f} tdrop={m['taildrops']:4.0f}")


def exp_steady(seeds, T=10.0):
    print("=" * 78)
    print("EXP1  STEADY SPOTTY  N=2  tether(swing 5-53Mb +periodic 400ms dropouts)")
    print("      + ethernet(steady 66-90Mb).  offer=85% mean-total.  FEC off.")
    print("=" * 78)
    drops = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
    tcap = tether_cap(dropouts=drops); ecap = eth_cap()
    offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    def specs():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    push = [run_push(specs(), ofn, T, sd) for sd in range(seeds)]
    print(line("PUSH argmin", agg(push, MKEYS)))
    print(f"    push tether-share={med([m['share'][0] for m in push]):.2f}")
    pushf = [run_push(specs(), ofn, T, sd, fec='auto') for sd in range(seeds)]
    print(line("PUSH +FEC(auto)", agg(pushf, MKEYS))
          + "   (FEC on push; pull can carry the same per-path FEC)")
    for lb in (20, 40, 80, 150):
        pl = [PullSim(specs(), ofn, T, sd, lbuf_ms=lb).run() for sd in range(seeds)]
        am = agg(pl, MKEYS)
        print(line(f"PULL bytes lb={lb}", am)
              + f"  tshare={med([m['share'][0] for m in pl]):.2f}")
    for tm in (40, 80):
        pm = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=tm).run()
              for sd in range(seeds)]
        print(line(f"PULL ms tgt={tm}", agg(pm, MKEYS))
              + f"  tshare={med([m['share'][0] for m in pm]):.2f}")
    pll = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40, lat_bias=True).run()
           for sd in range(seeds)]
    print(line("PULL ms+lat t=40", agg(pll, MKEYS)))


def exp_severity(seeds, T=10.0):
    print("=" * 78)
    print("EXP2  STALL SEVERITY SWEEP  N=2  (dropout duty cycle rising).  FEC off.")
    print("=" * 78)
    ecap = eth_cap(); offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    def mk_soft():
        base = tether_cap(dropouts=[], floor=3000.0)
        wins = [(a, a + 0.6) for a in (2.6, 5.1, 7.6)]
        def f(t):
            for (a, b) in wins:
                if a <= t < b:
                    return 1500.0
            return base(t)
        return f
    sevs = [
        ("none    ", tether_cap(dropouts=[])),
        ("mild    ", tether_cap(dropouts=[(a, a + 0.25) for a in (3.0, 6.0)])),
        ("medium  ", tether_cap(dropouts=[(a, a + 0.40) for a in (2.6, 5.1, 7.6)])),
        ("severe  ", tether_cap(dropouts=[(a, a + 0.70) for a in (2.2, 4.0, 5.8, 7.6)])),
        ("soft-dip ", mk_soft()),
    ]
    for name, tcap in sevs:
        def specs():
            return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                    NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
        push = [run_push(specs(), ofn, T, sd) for sd in range(seeds)]
        pull = [PullSim(specs(), ofn, T, sd, lbuf_ms=40).run() for sd in range(seeds)]
        pulm = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40).run()
                for sd in range(seeds)]
        a = agg(push, MKEYS); b = agg(pull, MKEYS); c = agg(pulm, MKEYS)
        dgp = 100 * (b['gp'] / a['gp'] - 1) if a['gp'] else 0
        dgpm = 100 * (c['gp'] / a['gp'] - 1) if a['gp'] else 0
        print(f"  [{name}] PUSH gp={a['gp']:6.0f} loss={a['loss_pct']:4.1f}% "
              f"p95={a['p95']:3.0f} tdrop={a['taildrops']:5.0f}"
              f"  |  PULLbytes gp={b['gp']:6.0f} loss={b['loss_pct']:4.1f}% "
              f"tdrop={b['taildrops']:5.0f} ({dgp:+.0f}%)"
              f"  |  PULLms gp={c['gp']:6.0f} loss={c['loss_pct']:4.1f}% "
              f"p95={c['p95']:3.0f} tdrop={c['taildrops']:5.0f} ({dgpm:+.0f}%)")


def exp_n3(seeds, T=10.0):
    print("=" * 78)
    print("EXP3  N=3  tetherA(swing+dropouts)+tetherB(swing+dropouts,phase)+ethernet")
    print("=" * 78)
    tA = tether_cap(dropouts=[(a, a + 0.4) for a in (2.6, 6.0)])
    tB = tether_cap(base=22000, amp=17000, period=2.3,
                    dropouts=[(a, a + 0.4) for a in (3.8, 7.3)])
    ecap = eth_cap()
    offer = 0.85 * (29000 + 22000 + 78000); ofn = lambda t: offer
    def specs():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tA),
                NPathSpec(23000, 70, 20.0, 0.010, cap_fn=tB),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    push = [run_push(specs(), ofn, T, sd) for sd in range(seeds)]
    print(line("PUSH argmin", agg(push, MKEYS)))
    pl = [PullSim(specs(), ofn, T, sd, lbuf_ms=40).run() for sd in range(seeds)]
    print(line("PULL bytes lb=40", agg(pl, MKEYS)))
    pm = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40).run()
          for sd in range(seeds)]
    print(line("PULL ms tgt=40", agg(pm, MKEYS)))
    pll = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=40, lat_bias=True).run()
           for sd in range(seeds)]
    print(line("PULL ms+lat t=40", agg(pll, MKEYS)))


def exp_estlag(seeds, T=6.0):
    print("=" * 78)
    print("EXP4  ESTIMATE-LAG  single HARD stall tether@t0=3.0 (0.5s).  "
          "push qhat-lag vs pull local-drain.")
    print("=" * 78)
    t0, t1 = 3.0, 3.5
    tcap = tether_cap(dropouts=[(t0, t1)]); ecap = eth_cap()
    offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    def specs():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    W = 0.8
    pr = []; prr = []; pw = []; pwl = []; pex = []; qex = []
    for sd in range(seeds):
        mp = run_push(specs(), ofn, T, sd)
        pr.append(react_time(mp['share_win'], 0, t0))
        tot, lost = wasted_on(mp['frames'], 0, t0, t0 + W); pw.append(lost); pex.append(tot)
        mq = PullSim(specs(), ofn, T, sd, lbuf_ms=40).run()
        prr.append(react_time(mq['share_win'], 0, t0))
        tot2, lost2 = wasted_on(mq['frames'], 0, t0, t0 + W); pwl.append(lost2); qex.append(tot2)
    print(f"  PUSH  frames COMMITTED-to-tether in [t0,t0+0.8s]={med(pex):5.0f}  "
          f"of which LOST(cap=0 down/taildrop)={med(pw):5.0f}   <-- estimate-lag waste")
    print(f"  PULL  frames COMMITTED-to-tether in [t0,t0+0.8s]={med(qex):5.0f}  "
          f"of which LOST={med(pwl):5.0f}   (pull stops committing on real drain)")
    # fine-grained push commit-tail: tether commits per 20ms bin AFTER stall onset
    # (all are LOST since cap=0) -> the raw estimate-lag decay curve.
    push_c = run_push(specs(), ofn, T, 0)
    b = 0.02; tb = t0; cells = []
    while tb < t1 + 0.30 - 1e-9:
        c = sum(1 for seq, (st, idx, arr, cc) in push_c['frames'].items()
                if idx == 0 and arr is None and t0 <= st < tb + b) - sum(cells)
        cells.append(max(0, c)); tb += b
    lastc = 0.0
    for k, c in enumerate(cells):
        if c > 0:
            lastc = (k + 1) * b * 1000
    print(f"  push tether-commit TAIL after t0 (per 20ms, cap=0 so all wasted): "
          f"last commit @ {lastc:.0f}ms")
    print("    " + " ".join(f"{c:2d}" for c in cells) + "   (20ms bins from t0)")
    print("  windowed goodput (Mb/s) around the stall [t0=3.0, revive=3.5]:")
    binsz = 0.25
    push_m = run_push(specs(), ofn, T, 0)
    pull_m = PullSim(specs(), ofn, T, 0, gate='ms', target_ms=40).run()
    hdr = "    t=      "; rowp = "    push:   "; rowl = "    pull:   "
    tt = 2.5
    while tt < 4.5 - 1e-9:
        hdr += f"{tt:5.2f} "
        rowp += f"{win_gp_frames(push_m['frames'], push_m['release'], tt, tt+binsz)/1000:5.1f} "
        rowl += f"{win_gp_frames(pull_m['frames'], pull_m['release'], tt, tt+binsz)/1000:5.1f} "
        tt += binsz
    print(hdr); print(rowp); print(rowl)


def exp_lbuf(seeds, T=10.0):
    print("=" * 78)
    print("EXP5  LBUF HONESTY SWEEP (rule-8: pull is NOT a free perfect signal)")
    print("=" * 78)
    drops = [(a, a + 0.4) for a in (2.6, 5.1, 7.6)]
    tcap = tether_cap(dropouts=drops); ecap = eth_cap()
    offer = 0.85 * (29000 + 78000); ofn = lambda t: offer
    def specs():
        return [NPathSpec(30000, 90, 25.0, 0.008, cap_fn=tcap),
                NPathSpec(78000,  8,  1.0, 0.0,  cap_fn=ecap)]
    t0 = 2.6
    print("  -- gate=BYTES (fixed socket budget; overshoots 300ms on a slow link) --")
    for lb in (10, 20, 40, 80, 150, 300):
        pull = [PullSim(specs(), ofn, T, sd, lbuf_ms=lb).run() for sd in range(seeds)]
        a = agg(pull, MKEYS)
        print(f"  lbuf={lb:3d}ms  gp={a['gp']:6.0f} "
              f"util={100*a['util']:4.1f}%  loss={a['loss_pct']:4.1f}%  "
              f"p95={a['p95']:3.0f}  depth={a['depth']:5.0f} tdrop={a['taildrops']:5.0f}")
    print("  -- gate=MS (local drain-rate EWMA -> time-bounded buffer, no lag) --")
    for tm in (10, 20, 40, 80, 150):
        pull = [PullSim(specs(), ofn, T, sd, gate='ms', target_ms=tm).run()
                for sd in range(seeds)]
        a = agg(pull, MKEYS)
        print(f"  tgt ={tm:3d}ms  gp={a['gp']:6.0f} "
              f"util={100*a['util']:4.1f}%  loss={a['loss_pct']:4.1f}%  "
              f"p95={a['p95']:3.0f}  depth={a['depth']:5.0f} tdrop={a['taildrops']:5.0f}")


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    quick = 'quick' in sys.argv
    seeds = 8 if quick else 24
    print(f"\n{'#'*78}\n# pull_study  --  PUSH(ETA-argmin) vs PULL(work-conserving)  "
          f"seeds={seeds}\n{'#'*78}")
    exp_steady(seeds); print()
    exp_severity(seeds); print()
    exp_n3(seeds); print()
    exp_estlag(seeds); print()
    exp_lbuf(seeds)


if __name__ == '__main__':
    main()
