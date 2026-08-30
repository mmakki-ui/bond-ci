#!/usr/bin/env python3
# Measurement driver: selective HEDGING vs FEC-auto vs FEC-off on the
# spotty-tether + steady-eth use case.  Uses the (scratch-copy) nsched_model
# NSim with the added hedge/hedge_free machinery.  Prose findings printed.
import sys, statistics as st
import nsched_model as N
PKT = N.PKT_KB

SEEDS = int(sys.argv[1]) if len(sys.argv) > 1 else 24

def med(xs): return st.median(xs)
def mn(xs):  return sum(xs)/len(xs)

def periodic_stall(base, dip, period, dur, phase=0.0):
    """Deterministic tether cap stall: dips to `dip` for `dur`s every `period`s."""
    def f(t):
        return dip if ((t - phase) % period) < dur else base
    return f

# ---- rigs: (name, specs_builder) --------------------------------------------
# steady eth = path0 (cap 2000, owd 30, jit 1, loss 0).  spotty tether = path1.
def rig_moderate():
    eth = N.NPathSpec(2000, 30, 1.0, 0.0)
    teth = N.NPathSpec(1400, 60, 20.0, 0.01,
                       cap_fn=periodic_stall(1400, 400, 3.0, 0.6),
                       ge=(0.02, 0.15, 3.0, 0.20))     # ~2.4% burst loss, jit x3 in bad
    return [eth, teth]

def rig_severe():
    eth = N.NPathSpec(2000, 30, 1.0, 0.0)
    teth = N.NPathSpec(1400, 60, 35.0, 0.015,
                       cap_fn=periodic_stall(1400, 200, 2.5, 0.9),
                       ge=(0.03, 0.12, 4.0, 0.30))     # deeper stall, burstier, jit x4
    return [eth, teth]

def rig_n3():
    # steady eth + a second steady path + spotty tether (mirror -> fastest steady)
    eth = N.NPathSpec(2000, 30, 1.0, 0.0)
    eth2 = N.NPathSpec(1200, 45, 1.0, 0.0)
    teth = N.NPathSpec(1000, 70, 25.0, 0.01,
                       cap_fn=periodic_stall(1000, 300, 3.0, 0.7),
                       ge=(0.02, 0.15, 3.0, 0.22))
    return [eth, eth2, teth]

RIGS = {'moderate': rig_moderate, 'severe': rig_severe, 'n3': rig_n3}

def run_cfg(rig_fn, offer, T, cfg, seeds):
    specs = rig_fn()
    ms = []
    for sd in range(seeds):
        specs = rig_fn()
        if cfg == 'off':
            m = N.NSim(specs, lambda t: offer, T, sd, 'eif_real', fec_mode='off').run()
        elif cfg == 'auto':
            m = N.NSim(specs, lambda t: offer, T, sd, 'eif_real', fec_mode='auto').run()
        elif cfg == 'hedge':
            m = N.NSim(specs, lambda t: offer, T, sd, 'eif_real', fec_mode='off',
                       hedge=True).run()
        elif cfg == 'hedge_free':
            m = N.NSim(specs, lambda t: offer, T, sd, 'eif_real', fec_mode='off',
                       hedge=True, hedge_free=True).run()
        elif cfg == 'hedge_auto':
            m = N.NSim(specs, lambda t: offer, T, sd, 'eif_real', fec_mode='auto',
                       hedge=True).run()
        ms.append(m)
    return ms

def agg(ms):
    Teff = ms[0]['T'] - 1.0
    d = {
        'gp':   med([m['gp'] for m in ms]),
        'loss': med([m['loss_pp'] for m in ms]),
        'p50':  med([m['p50'] for m in ms]),
        'p95':  med([m['p95'] for m in ms]),
        'p99':  med([m['p99'] for m in ms]),
        'late': med([m['late_discard'] for m in ms]),
        'txd':  med([m['txdrops'] for m in ms]),
        'tail': med([m['taildrops'] for m in ms]),
        'share_teth': med([m['share'][-1] for m in ms]),   # last path = tether (rigs put it last)
        'tail_eth': med([m['taildrops_by_path'][0] for m in ms]),      # eth displacement
        'tail_teth': med([m['taildrops_by_path'][-1] for m in ms]),
        'recovered': med([m['recovered'] for m in ms]),
        'recov_frac': med([m['recov_frac'] for m in ms]),
        'sl_total': med([m['sl_total'] for m in ms]),
        'hedge_sent': med([m['hedge_sent'] for m in ms]),
        'bw_cost_kbs': med([m['hedge_sent'] for m in ms]) * PKT / Teff,
    }
    # hedge decomposition (only meaningful for hedge cfgs)
    hs = [m['hedge'] for m in ms]
    if any(h['spotty_total'] for h in hs):
        d['h_spotty_total'] = med([h['spotty_total'] for h in hs])
        d['h_failed'] = med([h['spotty_failed'] for h in hs])
        d['h_ideal'] = med([h['mirror_arrived_of_failed'] for h in hs])
        d['h_realized'] = med([h['realized_saved'] for h in hs])
        d['h_late_flush'] = med([h['mirror_late_flushed'] for h in hs])
        d['h_both_fail'] = med([h['both_failed'] for h in hs])
        d['h_first'] = med([h['mirror_first_delivered'] for h in hs])
    return d

def paired_dgp(a_ms, b_ms):
    """median paired gp diff a-b and count of seeds where a>b (only valid when
    native physics is identical, i.e. b=off and a in {hedge_free})."""
    diffs = [a['gp'] - b['gp'] for a, b in zip(a_ms, b_ms)]
    pos = sum(1 for x in diffs if x > 0)
    return med(diffs), pos, len(diffs)

def report_rig(rig_name, rig_fn, offers, T, seeds, cfgs):
    print("=" * 88)
    print(f"RIG: {rig_name}   (T={T}s, seeds={seeds})   steady eth=path0, spotty tether=last path")
    print("=" * 88)
    for offer in offers:
        print(f"\n--- offer={offer} kb/s  (eth cap 2000; spill onto tether when offer>~eth headroom) ---")
        runs = {c: run_cfg(rig_fn, offer, T, c, seeds) for c in cfgs}
        A = {c: agg(runs[c]) for c in cfgs}
        off = A['off']
        hdr = f"{'cfg':<11}{'gp':>7}{'dgp/off':>9}{'loss%':>7}{'p50':>6}{'p95':>6}{'p99':>6}{'late':>6}{'txd':>6}{'tail':>6}{'teth%':>7}{'bwcost':>8}"
        print(hdr)
        for c in cfgs:
            a = A[c]
            dgp = a['gp'] - off['gp']
            print(f"{c:<11}{a['gp']:>7.0f}{dgp:>+9.0f}{a['loss']:>7.2f}"
                  f"{a['p50']:>6.0f}{a['p95']:>6.0f}{a['p99']:>6.0f}"
                  f"{a['late']:>6.0f}{a['txd']:>6.0f}{a['tail']:>6.0f}"
                  f"{a['share_teth']*100:>6.0f}%{a['bw_cost_kbs']:>8.0f}")
        # FEC recovery reality-check (how much does auto's parity actually repair?)
        au = A['auto']
        print(f"  FEC-auto repair: recovered={au['recovered']:.0f} of "
              f"single-loss-groups={au['sl_total']:.0f} (recov_frac={au['recov_frac']:.2f}); "
              f"eth-taildrop off={off['tail_eth']:.0f} auto={au['tail_eth']:.0f} "
              f"hedge={A['hedge']['tail_eth']:.0f}")
        # paired hedge_free vs off (clean isolation of pure recovery)
        if 'hedge_free' in cfgs:
            dpg, pos, n = paired_dgp(runs['hedge_free'], runs['off'])
            hf = A['hedge_free']
            print(f"  hedge_free PAIRED vs off: dgp med={dpg:+.0f} kb/s ({pos}/{n} seeds >0)")
            if 'h_failed' in hf:
                print(f"  hedge_free recovery: spotty_failed={hf['h_failed']:.0f} "
                      f"ideal(mirror arrived)={hf['h_ideal']:.0f} "
                      f"realized(in-ring)={hf['h_realized']:.0f} "
                      f"late-flushed={hf['h_late_flush']:.0f} both-fail={hf['h_both_fail']:.0f} "
                      f"| mirror-beat-spotty(latency)={hf['h_first']:.0f}")
        if 'hedge' in cfgs:
            h = A['hedge']
            if 'h_failed' in h:
                print(f"  hedge(faithful) recovery: spotty_total={h['h_spotty_total']:.0f} "
                      f"failed={h['h_failed']:.0f} ideal={h['h_ideal']:.0f} "
                      f"realized={h['h_realized']:.0f} late-flush={h['h_late_flush']:.0f} "
                      f"both-fail={h['h_both_fail']:.0f} | teth-share={h['share_teth']*100:.0f}% "
                      f"(vs off {off['share_teth']*100:.0f}%) -> feedback")

if __name__ == '__main__':
    cfgs = ['off', 'auto', 'hedge', 'hedge_auto', 'hedge_free']
    report_rig('moderate', rig_moderate, [1800, 2200, 2600, 3000], 14.0, SEEDS, cfgs)
    report_rig('severe',   rig_severe,   [2200, 2600, 3000], 14.0, SEEDS, cfgs)
    report_rig('n3',       rig_n3,       [2600, 3000, 3600], 14.0, SEEDS, cfgs)
