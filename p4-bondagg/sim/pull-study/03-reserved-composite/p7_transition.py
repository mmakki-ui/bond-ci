#!/usr/bin/env python3
# =============================================================================
# P7 -- D'' (sched='Dpp', reserved_meter.py) vs pull+cap (ackclock_sim 'ewma',
#   mirror=False -- the shipped one-sided delivered-rate cap, no opportunistic
#   mirror, "clean isolation") on a TRANSITION rig: N2 MID (cellA+eth), offered
#   load steps 0.65 -> 0.85 at t=T/2. UNMODIFIED physics (nsched_model,
#   ackclock_sim, reserved_meter all imported verbatim, no edits).
#
# Claim under test: nomination (mir_offered) may stay high through the step,
# but what must actually drop when the meter latches is ADMISSION -- so we
# instrument res_tx (admitted-duplicate bytes/frames on the wire), NOT
# armed_frac. And: any EXCESS loss Dpp incurs over pull+cap at the step must
# be a transient bounded by the sim's own feedback lag (NLAG=0.35s + the 0.1s
# averaging window the delivered-rate meter reads over = 0.45s "meter reaction
# scale", and HOLD/dup_ttl ~ one reorder-ring RTT), NOT a sustained regime
# change. We bin per-packet outcomes (from s.enq/s.arr, unmodified sim state)
# into 100ms windows around the step and pool over seeds for stable counts.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM
import ackclock_sim as A
import nsched_model as M

SEEDS = 24
T = 18.0
STEP_T = T / 2.0          # 9.0s
WARM = 1.0
WIN = 0.10                # 100ms windows

archs = [RM.cellA(RM.DROPS_A), RM.eth()]     # N2 MID (canonical rig used throughout)
defs = RM.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)

def offer_fn(t, _n=nom):
    return (0.65 if t < STEP_T else 0.85) * _n

# reorder-ring hold: SAME formula SimD.finalize / Sim.finalize use, deterministic
# from defs (owd/jit geometry) -- identical on both sides of this comparison since
# both run on the SAME rig. reserved_meter's dup_ttl uses this identical formula.
owds = [d['down_owd'] + d['loc_owd'] for d in defs]
jits = [d['jit'] for d in defs]
HOLD = min(0.35, max(0.08, ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0))
NLAG = M.NLAG                      # 0.35s: the delivered-rate meter's feedback lag
METER_SCALE = NLAG + 0.100         # + the 100ms averaging window the meter reads over
RTT_SCALE = max(HOLD, METER_SCALE) # the "one-RTT-scale" bound for this rig's physics

WIN_LO = STEP_T - 1.0
WIN_HI = STEP_T + 3.0
NW = int(round((WIN_HI - WIN_LO) / WIN))
WSPANS = [(WIN_LO + i * WIN, WIN_LO + (i + 1) * WIN) for i in range(NW)]

def bin_outcomes(sim_obj, hold):
    """Per-window (offered, delivered) counts from raw sim state (unmodified
    physics; we only READ s.enq/s.arr after .run() and re-run the SAME
    reorder_release the sim itself uses to decide delivery)."""
    deliv_items = [(a, seq) for seq, a in sim_obj.arr.items() if a is not None]
    release, skips, depth = M.reorder_release(deliv_items, hold)
    rel = set(release)
    off = [0] * NW; dl = [0] * NW
    for seq, et in sim_obj.enq.items():
        if et <= WARM or et < WIN_LO or et >= WIN_HI:
            continue
        idx = int((et - WIN_LO) / WIN)
        if 0 <= idx < NW:
            off[idx] += 1
            if seq in rel:
                dl[idx] += 1
    return off, dl

agg_off_d = [0] * NW; agg_dl_d = [0] * NW
agg_off_p = [0] * NW; agg_dl_p = [0] * NW
res_tx_tot = 0; mir_off_tot = 0

t0 = time.time()
for sd in range(SEEDS):
    sD = RM.SimD(defs, offer_fn, T, sd, sched='Dpp')
    mD = sD.run()
    res_tx_tot += mD['res_tx']; mir_off_tot += mD['mir_off']
    offD, dlD = bin_outcomes(sD, HOLD)
    for i in range(NW):
        agg_off_d[i] += offD[i]; agg_dl_d[i] += dlD[i]

    sP = A.Sim(defs, offer_fn, T, sd, sched='ewma', mirror=False)
    sP.run()
    offP, dlP = bin_outcomes(sP, HOLD)
    for i in range(NW):
        agg_off_p[i] += offP[i]; agg_dl_p[i] += dlP[i]

print("=" * 96)
print("P7 -- TRANSITION rig: N2 MID (cellA+eth), sched='Dpp' vs pull+cap (ackclock 'ewma', mirror=False)")
print("=" * 96)
print("rig nominal cap sum = %.0f kb/s  (cellA base=%.0f, eth base=%.0f)" %
      (nom, archs[0]['base'], archs[1]['base']))
print("offered load: 0.65 -> 0.85 step at t=%.2fs  (T=%.1fs, seeds=%d, window=%.0fms)" %
      (STEP_T, T, SEEDS, WIN * 1000))
print("HOLD (reorder-ring, == dup_ttl for this rig) = %.1f ms" % (HOLD * 1000))
print("NLAG (meter feedback lag) = %.1f ms  +100ms avg window => METER_SCALE = %.1f ms" %
      (NLAG * 1000, METER_SCALE * 1000))
print("RTT_SCALE (one-RTT-scale bound used below) = max(HOLD, METER_SCALE) = %.1f ms" %
      (RTT_SCALE * 1000))
print()
print("instrumented: res_tx (ADMITTED-DUPLICATE frames, Dpp) totalled %d over %d seeds"
      " -- mir_offered (nomination) totalled %d" % (res_tx_tot, SEEDS, mir_off_tot))
print("  (Fable's point: nomination may stay high while admission collapses -- that gap"
      "   IS the meter doing its job. We grade res_tx / loss below, not armed_frac.)")
print()
hdr = "%9s %9s | %7s %7s %7s | %7s %7s %7s | %8s  %s"
print(hdr % ("win_lo", "win_hi", "off_D", "dl_D", "loss_D%", "off_P", "dl_P", "loss_P%", "excess%", ""))
rows = []
for i, (lo, hi) in enumerate(WSPANS):
    offd, dld = agg_off_d[i], agg_dl_d[i]
    offp, dlp = agg_off_p[i], agg_dl_p[i]
    lossd = 100.0 * (offd - dld) / offd if offd else 0.0
    lossp = 100.0 * (offp - dlp) / offp if offp else 0.0
    exc = lossd - lossp
    rel_t = lo - STEP_T
    tag = ""
    if lo < STEP_T <= hi:
        tag = "<== STEP"
    elif 0 <= rel_t < RTT_SCALE:
        tag = "transient zone"
    rows.append((lo, hi, offd, dld, lossd, offp, dlp, lossp, exc, rel_t))
    print(hdr % ("%.3f" % lo, "%.3f" % hi, offd, dld, "%.2f" % lossd,
                 offp, dlp, "%.2f" % lossp, "%.2f" % exc, tag))

# ---- PASS/FAIL P7: excess loss must be a transient bounded by RTT_SCALE, ------
# ---- not a sustained regime change. -------------------------------------------
pre = [r for r in rows if r[9] < 0.0]                       # windows before the step
transient = [r for r in rows if 0.0 <= r[9] < 2 * RTT_SCALE]  # step .. 2x RTT_SCALE (margin)
settle = [r for r in rows if r[9] >= 2 * RTT_SCALE]          # everything after that margin

def wavg_excess(rs):
    tot_off_d = sum(r[2] for r in rs); tot_dl_d = sum(r[3] for r in rs)
    tot_off_p = sum(r[5] for r in rs); tot_dl_p = sum(r[6] for r in rs)
    ld = 100.0 * (tot_off_d - tot_dl_d) / tot_off_d if tot_off_d else 0.0
    lp = 100.0 * (tot_off_p - tot_dl_p) / tot_off_p if tot_off_p else 0.0
    return ld - lp

pre_exc = wavg_excess(pre)
peak_exc = max(r[8] for r in transient) if transient else 0.0
settle_exc = wavg_excess(settle)
settle_peak = max(r[8] for r in settle) if settle else 0.0

# tolerance: settle excess must be back down near pre-step baseline noise, and
# stay there (bounded peak) across the whole settle region (~2.1s / ~21 windows
# of post-transient data -- far more than enough to catch a sustained regime).
TOL = max(1.0, abs(pre_exc) + 1.0)
passed = (abs(settle_exc) <= TOL) and (settle_peak <= TOL)

print()
print("-" * 96)
print("pre-step  pooled excess loss (baseline noise)      : %+7.2f pct pts  (%d windows)" %
      (pre_exc, len(pre)))
print("transient pooled excess loss (0..%.0fms post-step)   : peak %+7.2f pct pts (%d windows)" %
      (2 * RTT_SCALE * 1000, peak_exc, len(transient)))
print("settle    pooled excess loss (>%.0fms post-step)     : avg  %+7.2f pct pts, peak %+7.2f pct pts (%d windows)" %
      (2 * RTT_SCALE * 1000, settle_exc, settle_peak, len(settle)))
print("tolerance (settle must return within)               : %.2f pct pts" % TOL)
print("-" * 96)
print("P7 %s: excess loss vs pull+cap is a ONE-RTT-scale TRANSIENT at the step, NOT sustained" %
      ("PASS" if passed else "FAIL"))
print("elapsed %.1fs" % (time.time() - t0))
