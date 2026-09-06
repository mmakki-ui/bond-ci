#!/usr/bin/env python3
# =============================================================================
# highn_battery.py -- HIGH-N (N=4, N=5) as a SCORED case, not a smoke test.
#
# WHY: bonding exists for the regime where required throughput EXCEEDS what the
# present sources supply -- and the answer to that is MORE SOURCES.  So high-N is
# the MOTIVATING regime, yet the study's evidence was N=2 / N=3 heavy, N=4 had
# ONE scenario, and N=5 existed only as an assert-nothing "ran without error"
# smoke test (myslice_baseline.py).  The client box already declares FOUR WAN
# interfaces (docs/INTENT.md), so N=4 is CURRENT HARDWARE, not a growth scenario.
#
# WHAT: the settled composite (reserved_composite.SimD sched='Dc') scored against
# the SAME paired references the N=2 headline used (ackclock_sim.Sim 'ewma' = the
# shipped one-sided delivered-rate cap, 'pull' = uncapped work-conserving, 'Dpp' =
# the uncapped-native predecessor), on heterogeneous N=4 / N=5 mixes, with REAL
# PASS BARS.
#
# PHYSICS: nsched_model.py imported UNMODIFIED (two levels up), exactly as every
# other script in this study.  Rigs/archetypes are reserved_composite's own
# builders -- NO new archetype and NO new numeric knob is introduced by this file.
#
# ---------------------------------------------------------------------------
# BARS -- every bar is either the EXISTING composite bar shape (adv_verify_dc.py)
# or a relation to a PAIRED reference run.  Nothing is picked here.
#
#   B1  NO-COLLAPSE (gp)   : Dc gp >= 0.99 * ewma gp            [loads .85/.95]
#         shape verbatim from adv_verify_dc.py -- the composite must not collapse
#         versus the shipped cap it is built out of.
#   B2  LOSS-PARITY        : Dc loss <= ewma loss + 0.5 pt      [loads .85/.95]
#         shape verbatim from adv_verify_dc.py.  KNOWN HONEST FAIL AT N=2
#         (adv_verify_dc.out: +0.845 pt @0.85, +0.655 pt @0.95, 24/24 seeds).
#         Inherited UNWEAKENED so the high-N rows are comparable to that record.
#   B3  SPARE-LOAD WIN     : Dc gp >= ewma gp AND Dc loss <= ORACLE loss  [load .65]
#         (a) gp half: shape verbatim from adv_verify_dc.py.  UNCHANGED.
#         (b) loss half: the absolute 'Dc loss <= 2%' constant is RETIRED here and
#             replaced by a PAIRED relation to a reference run.  See the U11 block
#             below for the measurement that justified it and the honest record of
#             what the old constant did.
#
# --- U11: WHY B3's ABSOLUTE HALF WAS RETIRED (evidence: coverage_oracle.txt) ---
# highn.txt recorded 'Dc loss <= 2%' failing at EVERY N>=3 (3.07..5.39%).  Fable's
# review called that a mis-derived bar but made the call PROVISIONAL on measuring
# the residual.  coverage_oracle.py ran both halves of that discriminating
# experiment, 24 paired seeds, six mixes, load 0.65:
#
#  (a) ORACLE-PAIRED COVERAGE  (loss_pull-loss_X)/(loss_pull-loss_oracle):
#      Dc = 1.220 (N2) 1.094 (N3) 1.115 (N4) 1.199 (N5) 1.050 (N4-teth) 1.112 (N5-corr).
#      NOT falling with N -- N5 (1.199) is level with N2 (1.220) and both exceed N3.
#      The variation tracks SPOTTY FRACTION, not N.  Fable's 'mechanism is leaking
#      coverable loss as N grows' branch is REFUTED.
#  (b) SHED-VS-LATE DECOMPOSITION of Dc's own 0.65 loss (instrument self-checked
#      against the simulator's own `late` counter, 0/144 runs disagreeing):
#        copies shed while a steady host's meter was still open  = 0, ALL SIX MIXES.
#        copies shed with every steady meter latched             = 0% on the four
#          chain mixes, 11.1% (N4-teth) / 15.9% (N5-corr) -- capacity arithmetic,
#          exactly the intent-consistent case.
#      So the duplication gate has NO fault.  What DOES dominate is Fable's (ii):
#        78-96% of every lost frame ARRIVED and was then discarded by the reorder
#        ring as late.  This is NOT specific to Dc -- it is 50-62% for pull and
#        95-97% for the ORACLE.  The oracle's own residual loss at 0.65 is
#        4.11-6.08% at N>=3 and is almost entirely ring discard.
#
# FABLE'S EXACT SHAPE WAS TRIED AND REJECTED.  'coverage >= coverage(N=2) - eps',
#   with eps pre-registered as the reference cell's own per-seed spread (median-min
#   = 0.0129 over 24 seeds), FAILS Dc on 5/6 mixes -- it is STRICTER than the bar it
#   was meant to correct.  The reason is structural, not numeric: coverage(N=2) is
#   not an intent boundary, it is just another measurement, and it inherits N=2's
#   mix-specific advantage (one spotty source, abundant steady slack).  That shape
#   turns MIX HETEROGENEITY into a fake leak signal.  Widening eps until Dc passed
#   would have derived it from the failing observation -- gaming, condition 1.  The
#   oracle relation below has a real boundary at 1.0 and needs no epsilon at all.
#
# CONSEQUENCE, and the four-condition test (fable-highn-review.md):
#   1. DERIVATION SOURCE -- 'Dc loss <= oracle loss' is a relation to a PAIRED
#      reference run, which is this file's own stated bar rule (see the header
#      above: "either the EXISTING composite bar shape or a relation to a PAIRED
#      reference run.  Nothing is picked here").  B3's loss half was the ONLY bar
#      in this file that broke that rule.  Nothing is derived from the 3.07/5.39
#      numbers that failed.  DISCLOSED: coverage>1 was observed before 1.0 was
#      adopted as the boundary; the defence is that 1.0 is the ONE structural point
#      on that scale (the reference relation itself), not a level fitted to Dc --
#      a fitted threshold would have been 1.04, and epsilon-padding it would be.
#   2. PRE-REGISTRATION -- the rule it restores predates this battery, in this
#      file's own header and in the project's no-arbitrary-constants guardrail.
#   3. FALSIFIABILITY -- validated against mechanism-removed controls on the same
#      evidence: it FAILS ewma (no duplication) on 6/6 mixes and Dpp (no native
#      cap) on 2/6 (N3 0.711, N4-teth 0.735).  It is not theatre.
#   4. THE RECORD SURVIVES -- the old constant's five failures stay written in
#      highn.txt, and this run still PRINTS Dc's absolute 0.65 loss beside the
#      oracle floor so the retired constant's number remains visible.
#
# WHAT THIS BAR DOES NOT COVER (named, not hidden): the reorder-hold geometry.
#   The ring discard above is common-mode -- it sits in both sides of the new
#   relation and so cancels out of it.  B3's 2% was accidentally the only bar in
#   the battery that saw it, and it is NOT replaced in that role: it needs its own
#   bar, against the derived hold (ROADMAP U13 / OBJ-B).  Recorded as an open
#   question, not silently absorbed.
#   B4a NO-EVICTION-SPIRAL : spotty-class native share(Dc) <= share(pull)
#         PAIRED, constant-free.  pull is the UNCAPPED baseline in which the
#         eviction spiral (spotty native share 23%->58%) was observed; the
#         composite exists to cap exactly that, so it must never be worse than
#         pull.  Generalised N-generically:
#             share = sum(assigned[i] for i in spotty-class) / sum(assigned)
#         At N=2 with cellA at index 0 this IS the recorded 'tshare' metric, so
#         the N=2 row stays comparable to adv_verify_dc.out.
#   B4b NO-WALK            : the within-run spotty-share timeline (independent
#         truncated-T reconstruction, same method as adv_verify_dc.py) must not
#         be monotonically non-decreasing across all checkpoints.
#   B5  SCALING (high-N specific, DERIVED from the motivating requirement)
#         On a NESTED chain N2 c N3 c N4-het c N5-het, offered the SAME ABSOLUTE
#         rate, so the small configs are genuinely over-subscribed -- the
#         motivating regime -- each added source must BUY something:
#             gp strictly increases   AND   loss strictly decreases.
#         The offer is derived from the rig's own nominal aggregate; no constant.
#
#         U12 -- TWO offers, because ONE was not a test of the last step.  At
#         0.85 x nominal(N5-het) = 162,350 the N=5 step is UNDER-STRESSED by its
#         own admission: N4-het's nominal aggregate is already 174,000, so N4 is
#         not over-subscribed at all and N=5 buys only +1,277 gp (highn.txt:159).
#         The second chain is offered LOADS[-1] x nominal(N5-het) ~= 181,450 --
#         ABOVE N4-het's nominal, so N4 genuinely cannot carry it and the N=5 step
#         is a real capacity test.  No new constant: the multipliers are LOADS[1]
#         and LOADS[-1], the same load fractions the main table already uses.
#
# HONEST-FAIL POLICY: bars are reported as measured.  Nothing here tunes the
# scheduler, and no bar is weakened to go green.
# ---------------------------------------------------------------------------
# Env: SEEDS (default 24), WORKERS (default 14), T (default 9.0), RIG (default
# 'mid' -- the meter-free blind spot, the hard case, as adv_verify_dc used).
# =============================================================================
import os, sys, time
from concurrent.futures import ProcessPoolExecutor

import reserved_composite as RC
import ackclock_sim as A

SEEDS = int(os.environ.get('SEEDS', '24'))
WORKERS = int(os.environ.get('WORKERS', '14'))
T = float(os.environ.get('T', '9.0'))
RIG = os.environ.get('RIG', 'mid')
LOADS = [0.65, 0.85, 0.95]
SCHEDS = ['Dc', 'ewma', 'pull', 'Dpp']
# B3's loss reference.  Run ONLY at B3's load so the main table stays byte-
# comparable with the highn.txt record; 'oracle' = ackclock_sim.Sim admitting on
# the TRUE instantaneous stage-2 cap (the physics-derived floor for admission
# control).  See the U11 block in the header.
B3_REF = 'oracle'
B3_LOAD = 0.65

# timeline (B4b) -- same checkpoints + seed count as adv_verify_dc.py
CK = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5]
TL_SEEDS = 12
TL_SCHEDS = ['Dc', 'ewma']


# ---------------------------------------------------------------------------
# Scenarios.  Heterogeneous mixes only -- no homogeneous clones.  Every member is
# a reserved_composite archetype (cellA/B/C = spotty tethers with DISTINCT caps,
# periods, owd/jit and DISTINCT dropout schedules; wifi = wifi-as-WAN steady;
# eth = ethernet steady).  The product spec (p5-execution-handover.md s1) is
# "any mix of multiple cell/USB tethers, wifi-as-WAN, ethernet".
#
# The first four form a NESTED chain (each adds exactly one source) -- that chain
# is what B5 scores.
# ---------------------------------------------------------------------------
def SCENARIOS():
    return [
        # -- nested chain --------------------------------------------------
        ('N2-het  cellA + eth',
         [RC.cellA(RC.DROPS_A), RC.eth()], True),
        ('N3-het  cellA + cellB + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.eth()], True),
        ('N4-het  cellA + cellB + wifi + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.wifi(), RC.eth()], True),
        ('N5-het  cellA + cellB + cellC + wifi + eth',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
          RC.wifi(), RC.eth()], True),
        # -- off-chain high-N stress mixes ---------------------------------
        ('N4-teth cellA + cellB + cellC + eth  (tether-heavy 3/1)',
         [RC.cellA(RC.DROPS_A), RC.cellB(RC.DROPS_B), RC.cellC(RC.DROPS_C),
          RC.eth()], False),
        ('N5-corr cellA+cellB+cellC (CORRELATED stalls) + wifi + eth',
         [RC.cellA(RC.DROPS_CORR), RC.cellB(RC.DROPS_CORR), RC.cellC(RC.DROPS_CORR),
          RC.wifi(), RC.eth()], False),
    ]


def spotty_idx(archs):
    return [i for i, a in enumerate(archs) if a['spotty']]


def make_sim(defs, ofn, tt, seed, sched):
    if sched in ('Dc', 'Dpp', 'D', 'redundant'):
        return RC.SimD(defs, ofn, tt, seed, sched=sched)
    return A.Sim(defs, ofn, tt, seed, sched=sched, mirror=False)


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


# ---------------------------------------------------------------------------
# workers (top-level + plain-dict args so they pickle under Windows spawn)
# ---------------------------------------------------------------------------
def work_main(task):
    (si, archs, load, sched, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom, _L=load: _L * _n)
    o = make_sim(defs, ofn, T, seed, sched)
    m = o.run()
    sp = spotty_idx(archs)
    tot = sum(o.assigned) or 1
    m2 = {k: m[k] for k in ('gp', 'loss', 'p50', 'p95', 'p99', 'tdrop') if k in m}
    m2['sshare'] = sum(o.assigned[i] for i in sp) / tot
    return (si, sched, load, seed, m2)


def work_tl(task):
    """One truncated-T run for the spotty-share timeline (B4b)."""
    (si, archs, sched, seed, tt) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    ofn = (lambda t, _n=nom: 0.95 * _n)
    o = make_sim(defs, ofn, tt, seed, sched)
    o.run()
    sp = set(spotty_idx(archs))
    a_sp = sum(o.assigned[i] for i in range(len(o.assigned)) if i in sp)
    a_all = sum(o.assigned)
    return (si, sched, seed, tt, a_sp, a_all)


def work_scale(task):
    """B5: one fixed ABSOLUTE offer applied to every member of the nested chain."""
    (ci, archs, offer, sched, seed) = task
    defs = RC.build_rig(archs, bottleneck=RIG)
    ofn = (lambda t, _o=offer: _o)
    m = make_sim(defs, ofn, T, seed, sched).run()
    return (ci, sched, seed, {'gp': m['gp'], 'loss': m['loss'],
                              'p95': m['p95'], 'p99': m['p99']})


# ---------------------------------------------------------------------------
def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    scen = SCENARIOS()
    t0 = time.time()

    print('#' * 118)
    print('# HIGH-N SCORED BATTERY  (N=4 / N=5 heterogeneous)  seeds=%d  T=%.1fs  rig=%s  medians'
          % (SEEDS, T, RIG))
    print('# physics = nsched_model.py UNMODIFIED   composite = reserved_composite.SimD(sched="Dc")')
    print('# references = ackclock_sim.Sim(ewma|pull, mirror=False) + SimD(Dpp)   PAIRED SEEDS')
    print('#' * 118)
    for (title, archs, chain) in scen:
        nom = sum(a['base'] for a in archs)
        print('#   %-58s N=%d spotty=%d/%d nominal_agg=%7d kb/s %s'
              % (title, len(archs), len(spotty_idx(archs)), len(archs), nom,
                 '[chain]' if chain else ''))
    print('#' * 118)
    sys.stdout.flush()

    # ---------------- main table ----------------
    tasks = [(si, archs, L, sch, sd)
             for si, (t_, archs, c_) in enumerate(scen)
             for L in LOADS for sch in SCHEDS for sd in range(SEEDS)]
    # B3's paired loss reference, at B3's load only (see B3_REF above).
    tasks += [(si, archs, B3_LOAD, B3_REF, sd)
              for si, (t_, archs, c_) in enumerate(scen)
              for sd in range(SEEDS)]
    print('# main-table runs: %d' % len(tasks), file=sys.stderr)
    res = {}
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sch, L, sd, m) in ex.map(work_main, tasks, chunksize=4):
            res.setdefault(si, {}).setdefault(sch, {}).setdefault(L, []).append(m)
            done += 1
            if done % 250 == 0:
                print('  ..main %d/%d  (%.0fs)' % (done, len(tasks), time.time() - t0),
                      file=sys.stderr)

    def agg(si, sch, L, k):
        return med([d[k] for d in res[si][sch][L]])

    for si, (title, archs, chain) in enumerate(scen):
        nom = sum(a['base'] for a in archs)
        print('=' * 118)
        print('%s   | N=%d spotty=%d nominal_agg=%d' % (title, len(archs),
                                                        len(spotty_idx(archs)), nom))
        print('=' * 118)
        print('  %-6s | %s' % ('sched', '  ||  '.join(
            '%-40s' % ('load=%.2f   gp  loss   p95   p99 sshare' % L) for L in LOADS)))
        for sch in SCHEDS:
            cells = []
            for L in LOADS:
                cells.append('%7.0f %5.2f %5.0f %5.0f %6.3f' % (
                    agg(si, sch, L, 'gp'), agg(si, sch, L, 'loss'),
                    agg(si, sch, L, 'p95'), agg(si, sch, L, 'p99'),
                    agg(si, sch, L, 'sshare')))
            print('  %-6s | %s' % (sch, '  ||  '.join('%-40s' % c for c in cells)))
        print()
    sys.stdout.flush()

    # ---------------- B1/B2/B3/B4a ----------------
    fails = []
    print('=' * 118)
    print('BAR CHECKS -- B1 no-collapse | B2 loss-parity | B3 spare-load win | B4a no-eviction-spiral')
    print('=' * 118)
    for si, (title, archs, chain) in enumerate(scen):
        print('-' * 118)
        print('%s' % title)
        dc_gp = agg(si, 'Dc', B3_LOAD, 'gp'); ew_gp = agg(si, 'ewma', B3_LOAD, 'gp')
        dc_ls = agg(si, 'Dc', B3_LOAD, 'loss')
        or_ls = agg(si, B3_REF, B3_LOAD, 'loss')
        ok_a = dc_gp >= ew_gp
        # PAIRED per-seed, same shape as B2 -- not a comparison of two medians.
        b3p = [a_ - b_ for a_, b_ in
               zip([d['loss'] for d in res[si]['Dc'][B3_LOAD]],
                   [d['loss'] for d in res[si][B3_REF][B3_LOAD]])]
        b3_over = sum(1 for x in b3p if x > 0.0)
        ok_b = med(b3p) <= 0.0
        if not ok_a:
            fails.append('B3(gp)   %s load=%.2f: Dc gp %.0f < ewma gp %.0f'
                         % (title, B3_LOAD, dc_gp, ew_gp))
        if not ok_b:
            fails.append('B3(loss) %s load=%.2f: Dc loss %.2f%% > %s loss %.2f%% '
                         '(paired median %+.3f pt, %d/%d seeds worse than the reference)'
                         % (title, B3_LOAD, dc_ls, B3_REF, or_ls,
                            med(b3p), b3_over, SEEDS))
        print('  B3 load=%.2f WIN : Dc gp=%.0f vs ewma=%.0f -> %s | Dc loss=%.2f%% vs %s '
              '%.2f%% -> %s   paired Dc-%s med=%+.3f min=%+.3f max=%+.3f  worse=%d/%d'
              % (B3_LOAD, dc_gp, ew_gp, 'PASS' if ok_a else 'FAIL',
                 dc_ls, B3_REF, or_ls, 'PASS' if ok_b else 'FAIL',
                 B3_REF, med(b3p), min(b3p), max(b3p), b3_over, SEEDS))
        print('    [retired U11] the old absolute half was "Dc loss <= 2.00%%"; on this cell '
              'Dc=%.2f%% -> %s.  Kept visible, not asserted.'
              % (dc_ls, 'would PASS' if dc_ls <= 2.0 else 'would FAIL'))
        for L in (0.85, 0.95):
            dc_gp = agg(si, 'Dc', L, 'gp'); ew_gp = agg(si, 'ewma', L, 'gp')
            dc_ls = agg(si, 'Dc', L, 'loss'); ew_ls = agg(si, 'ewma', L, 'loss')
            ok1 = dc_gp >= 0.99 * ew_gp
            ok2 = dc_ls <= ew_ls + 0.5
            # paired per-seed delta (same shape as adv_verify_dc.py)
            pairs = [a_ - b_ for a_, b_ in
                     zip([d['loss'] for d in res[si]['Dc'][L]],
                         [d['loss'] for d in res[si]['ewma'][L]])]
            over = sum(1 for x in pairs if x > 0.5)
            if not ok1:
                fails.append('B1 %s load=%.2f: Dc gp %.0f < 0.99*ewma %.0f'
                             % (title, L, dc_gp, 0.99 * ew_gp))
            if not ok2:
                fails.append('B2 %s load=%.2f: Dc loss %.2f%% > ewma+0.5 = %.2f%% '
                             '(paired median %+.3f pt, %d/%d seeds >0.5pt)'
                             % (title, L, dc_ls, ew_ls + 0.5, med(pairs), over, SEEDS))
            print('  B1 load=%.2f     : gp Dc=%.0f vs 0.99*ewma=%.0f -> %s'
                  % (L, dc_gp, 0.99 * ew_gp, 'PASS' if ok1 else 'FAIL'))
            print('  B2 load=%.2f     : loss Dc=%.2f%% vs ewma+0.5=%.2f%% -> %s   '
                  'paired Dc-ewma med=%+.3f min=%+.3f max=%+.3f  seeds>0.5pt=%d/%d'
                  % (L, dc_ls, ew_ls + 0.5, 'PASS' if ok2 else 'FAIL',
                     med(pairs), min(pairs), max(pairs), over, SEEDS))
        for L in LOADS:
            s_dc = agg(si, 'Dc', L, 'sshare'); s_pl = agg(si, 'pull', L, 'sshare')
            ok = s_dc <= s_pl
            if not ok:
                fails.append('B4a %s load=%.2f: spotty-share Dc %.3f > pull %.3f'
                             % (title, L, s_dc, s_pl))
            print('  B4a load=%.2f    : spotty-class native share Dc=%.3f vs pull=%.3f -> %s'
                  % (L, s_dc, s_pl, 'PASS' if ok else 'FAIL'))
    sys.stdout.flush()

    # ---------------- B4b spotty-share timeline ----------------
    print('=' * 118)
    print('B4b SPOTTY-SHARE TIMELINE (independent truncated-T reconstruction, load=0.95, %d seeds)'
          % TL_SEEDS)
    print('=' * 118)
    tl_tasks = [(si, archs, sch, sd, tt)
                for si, (t_, archs, c_) in enumerate(scen)
                for sch in TL_SCHEDS for sd in range(TL_SEEDS) for tt in CK]
    print('# timeline runs: %d' % len(tl_tasks), file=sys.stderr)
    cum = {}
    done = 0
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (si, sch, sd, tt, a_sp, a_all) in ex.map(work_tl, tl_tasks, chunksize=4):
            cum.setdefault((si, sch, sd), {})[tt] = (a_sp, a_all)
            done += 1
            if done % 250 == 0:
                print('  ..tl %d/%d  (%.0fs)' % (done, len(tl_tasks), time.time() - t0),
                      file=sys.stderr)
    for si, (title, archs, chain) in enumerate(scen):
        print('  %s' % title)
        for sch in TL_SCHEDS:
            win = []
            for wi, tt in enumerate(CK):
                sp_d = all_d = 0
                for sd in range(TL_SEEDS):
                    cur = cum[(si, sch, sd)][tt]
                    prev = cum[(si, sch, sd)][CK[wi - 1]] if wi > 0 else (0, 0)
                    sp_d += cur[0] - prev[0]
                    all_d += cur[1] - prev[1]
                win.append(sp_d / all_d if all_d else 0.0)
            walk = all(win[i] <= win[i + 1] + 1e-9 for i in range(len(win) - 1))
            if sch == 'Dc' and walk:
                fails.append('B4b %s: Dc spotty-share WALKS UP monotonically: %s'
                             % (title, ' '.join('%.3f' % w for w in win)))
            print('    %-5s : %s   min=%.3f max=%.3f monotonic_up=%s -> %s'
                  % (sch, ' '.join('%.3f' % w for w in win), min(win), max(win),
                     walk, ('FAIL' if walk else 'PASS') if sch == 'Dc' else '-'))
    sys.stdout.flush()

    # ---------------- B5 scaling on the nested chain ----------------
    # U12: TWO offers.  LOADS[1] is the original (under-stresses the N=5 step --
    # N4-het's own nominal already exceeds it); LOADS[-1] puts the offer ABOVE
    # N4-het's nominal so the last step is a real capacity test.
    chain = [(t_, a_) for (t_, a_, c_) in scen if c_]
    nom5 = sum(a['base'] for a in chain[-1][1])
    nom4 = sum(a['base'] for a in chain[-2][1])
    offers = [(LOADS[1], LOADS[1] * nom5), (LOADS[-1], LOADS[-1] * nom5)]
    sc_tasks = [(ci * 10 + oi, archs, off, sch, sd)
                for oi, (fr_, off) in enumerate(offers)
                for ci, (t_, archs) in enumerate(chain)
                for sch in ('Dc', 'ewma') for sd in range(SEEDS)]
    print('# B5 runs: %d' % len(sc_tasks), file=sys.stderr)
    sres = {}
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        for (key, sch, sd, m) in ex.map(work_scale, sc_tasks, chunksize=4):
            sres.setdefault(key, {}).setdefault(sch, []).append(m)
    for oi, (fr_, offer) in enumerate(offers):
        print('=' * 118)
        print('B5 SCALING -- nested chain, IDENTICAL absolute offer = %.2f x nominal(%s) = %.0f kb/s'
              % (fr_, chain[-1][0].split()[0], offer))
        print('   nominal(%s)=%d -> the N=%d member is at %.0f%% of its own nominal; '
              'the N=%d member at %.0f%%'
              % (chain[-2][0].split()[0], nom4, len(chain[-2][1]), 100.0 * offer / nom4,
                 len(chain[-1][1]), 100.0 * offer / nom5))
        if offer <= nom4:
            print('   *** the N=%d member is NOT over-subscribed at this offer -- the LAST step of'
                  % len(chain[-2][1]))
            print('   *** this chain is UNDER-STRESSED and its PASS is weak evidence (U12).')
        else:
            print('   (the motivating regime: EVERY smaller config, including the N=%d one, is'
                  % len(chain[-2][1]))
            print('    genuinely over-subscribed -- so the last step is a real capacity test.)')
        print('=' * 118)
        print('  %-46s %3s %9s %7s %6s %6s' % ('config (Dc)', 'N', 'gp', 'loss%', 'p95', 'p99'))
        prev = None
        for ci, (title, archs) in enumerate(chain):
            key = ci * 10 + oi
            g = med([d['gp'] for d in sres[key]['Dc']])
            l = med([d['loss'] for d in sres[key]['Dc']])
            p95 = med([d['p95'] for d in sres[key]['Dc']])
            p99 = med([d['p99'] for d in sres[key]['Dc']])
            mark = ''
            if prev is not None:
                up = g > prev[0]
                dn = l < prev[1]
                mark = '  dgp=%+.0f(%s) dloss=%+.2f(%s)' % (
                    g - prev[0], 'PASS' if up else 'FAIL',
                    l - prev[1], 'PASS' if dn else 'FAIL')
                if not up:
                    fails.append('B5 offer=%.0f %s: adding a source did NOT increase gp '
                                 '(%.0f -> %.0f)' % (offer, title, prev[0], g))
                if not dn:
                    fails.append('B5 offer=%.0f %s: adding a source did NOT reduce loss '
                                 '(%.2f%% -> %.2f%%)' % (offer, title, prev[1], l))
            print('  %-46s %3d %9.0f %7.2f %6.0f %6.0f%s'
                  % (title, len(archs), g, l, p95, p99, mark))
            prev = (g, l)
        print('  -- ewma (shipped cap) reference on the same chain, same offer --')
        for ci, (title, archs) in enumerate(chain):
            key = ci * 10 + oi
            print('  %-46s %3d %9.0f %7.2f'
                  % (title, len(archs),
                     med([d['gp'] for d in sres[key]['ewma']]),
                     med([d['loss'] for d in sres[key]['ewma']])))

    # ---------------- verdict ----------------
    print('=' * 118)
    print('VERDICT   (honest: bars are reported as measured; nothing was tuned)')
    print('=' * 118)
    if not fails:
        print('  ALL BARS PASS')
    else:
        print('  %d BAR FAILURE(S):' % len(fails))
        for f in fails:
            print('    FAIL  %s' % f)
    print('\nelapsed %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
