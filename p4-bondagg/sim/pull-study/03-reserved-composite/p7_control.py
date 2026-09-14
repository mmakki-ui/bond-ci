#!/usr/bin/env python3
# =============================================================================
# P7 control -- is the elevated excess loss seen late in the "settle" region of
# p7_transition.py (t~11.4-12.0s, ~2.4-3.0s AFTER the step) actually caused by
# the STEP, or is it an artifact of cellA's own periodic capacity trace
# (period=3.1s, no dropout flag needed past t=8.0 -- cap_trace's sine dips
# toward floor=3000 every cycle) that would show up at those SAME absolute
# times regardless of a step ever happening?
#
# Same rig/seeds/hold/windowing as p7_transition.py. THREE conditions, same
# seeds, compared at the SAME absolute-time windows:
#   flat65  : offered load constant 0.65*nom for the whole run (pre-step regime)
#   flat85  : offered load constant 0.85*nom for the whole run (post-step regime,
#             but with NO step -- Dpp has been living at 0.85 since t=0)
#   step    : 0.65 -> 0.85 at t=T/2 (the p7_transition.py condition)
# If flat85's excess-loss timeline reproduces the same late spikes at the same
# absolute times as step's settle region, the spikes are a rig artifact
# (cellA's cycle x sustained high load), NOT a step-transient -- i.e. P7's
# actual question (does the STEP cause sustained excess loss) is answered by
# comparing step's settle region to flat85, not to zero.
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
import reserved_meter as RM
import ackclock_sim as A
import nsched_model as M

SEEDS = 24
T = 18.0
STEP_T = T / 2.0
WARM = 1.0
WIN = 0.10

archs = [RM.cellA(RM.DROPS_A), RM.eth()]
defs = RM.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)

def mk_offer(kind):
    if kind == 'flat65':
        return lambda t, _n=nom: 0.65 * _n
    if kind == 'flat85':
        return lambda t, _n=nom: 0.85 * _n
    return lambda t, _n=nom: (0.65 if t < STEP_T else 0.85) * _n

owds = [d['down_owd'] + d['loc_owd'] for d in defs]
jits = [d['jit'] for d in defs]
HOLD = min(0.35, max(0.08, ((max(owds) - min(owds)) + 3.0 * max(jits) + 130.0) / 1000.0))

WIN_LO = 1.0
WIN_HI = T
NW = int(round((WIN_HI - WIN_LO) / WIN))
WSPANS = [(WIN_LO + i * WIN, WIN_LO + (i + 1) * WIN) for i in range(NW)]

def bin_outcomes(sim_obj, hold):
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

results = {}
t0 = time.time()
for kind in ('flat65', 'flat85', 'step'):
    offer_fn = mk_offer(kind)
    agg_off_d = [0] * NW; agg_dl_d = [0] * NW
    agg_off_p = [0] * NW; agg_dl_p = [0] * NW
    for sd in range(SEEDS):
        sD = RM.SimD(defs, offer_fn, T, sd, sched='Dpp'); sD.run()
        offD, dlD = bin_outcomes(sD, HOLD)
        for i in range(NW):
            agg_off_d[i] += offD[i]; agg_dl_d[i] += dlD[i]
        sP = A.Sim(defs, offer_fn, T, sd, sched='ewma', mirror=False); sP.run()
        offP, dlP = bin_outcomes(sP, HOLD)
        for i in range(NW):
            agg_off_p[i] += offP[i]; agg_dl_p[i] += dlP[i]
    results[kind] = (agg_off_d, agg_dl_d, agg_off_p, agg_dl_p)
    print("  ...%s done (%.1fs elapsed)" % (kind, time.time() - t0))

def excess_at(kind, i):
    off_d, dl_d, off_p, dl_p = results[kind]
    offd, dld, offp, dlp = off_d[i], dl_d[i], off_p[i], dl_p[i]
    lossd = 100.0 * (offd - dld) / offd if offd else 0.0
    lossp = 100.0 * (offp - dlp) / offp if offp else 0.0
    return lossd - lossp, lossd, lossp

print()
print("=" * 108)
print("CONTROL -- late-window excess loss (Dpp - pull+cap): step's SETTLE region vs flat85 at SAME absolute t")
print("=" * 108)
print("%9s %9s | %8s %8s %8s | %8s %8s %8s | %8s %8s %8s" %
      ("win_lo", "win_hi", "exc_step", "lossD_st", "lossP_st",
       "exc_f85", "lossD_85", "lossP_85", "exc_f65", "lossD_65", "lossP_65"))
focus_lo, focus_hi = STEP_T, STEP_T + 3.0
for i, (lo, hi) in enumerate(WSPANS):
    if lo < focus_lo or lo >= focus_hi:
        continue
    e_st, ld_st, lp_st = excess_at('step', i)
    e_85, ld_85, lp_85 = excess_at('flat85', i)
    e_65, ld_65, lp_65 = excess_at('flat65', i)
    print("%9.3f %9.3f | %8.2f %8.2f %8.2f | %8.2f %8.2f %8.2f | %8.2f %8.2f %8.2f" %
          (lo, hi, e_st, ld_st, lp_st, e_85, ld_85, lp_85, e_65, ld_65, lp_65))

# ---- verdict: correlate step's settle-region excess against flat85's excess ---
# at the SAME absolute windows. If they track (step's late excess ~= flat85's
# excess at those same times), the late loss is a cellA-cycle x sustained-load
# artifact, not caused by the step -- so P7's real answer comes from comparing
# step's settle region to flat85 (its own post-step steady state), not to 0.
print()
diffs = []
for i, (lo, hi) in enumerate(WSPANS):
    if lo < focus_lo or lo >= focus_hi:
        continue
    e_st, _, _ = excess_at('step', i)
    e_85, _, _ = excess_at('flat85', i)
    diffs.append((lo, e_st - e_85))
mean_abs_resid = sum(abs(d) for _, d in diffs) / len(diffs)
max_abs_resid = max(abs(d) for _, d in diffs)
print("step vs flat85, per-window excess RESIDUAL (step_excess - flat85_excess) over t=[%.1f,%.1f):" %
      (focus_lo, focus_hi))
print("  mean |residual| = %.2f pct pts, max |residual| = %.2f pct pts" % (mean_abs_resid, max_abs_resid))
print()
print("full-run (t=1.0..%.1fs) excess-loss timeline, flat65 vs flat85 (is the cellA-cycle artifact real "
      "and does it also hit flat65, or only kick in at load=0.85?):" % T)
print("%9s %9s | %8s %8s | %8s %8s" % ("win_lo", "win_hi", "exc_f65", "loss_D65", "exc_f85", "loss_D85"))
for i, (lo, hi) in enumerate(WSPANS):
    e_65, ld_65, _ = excess_at('flat65', i)
    e_85, ld_85, _ = excess_at('flat85', i)
    if abs(e_65) > 8.0 or abs(e_85) > 8.0:
        print("%9.3f %9.3f | %8.2f %8.2f | %8.2f %8.2f  <-- spike" % (lo, hi, e_65, ld_65, e_85, ld_85))
print("elapsed %.1fs" % (time.time() - t0))
