#!/usr/bin/env python3
# =============================================================================
# p6_dpp_meter.py -- P6 (knee-follows-N test) for D'' (sched='Dpp') in
#   reserved_meter.py.  UNMODIFIED physics (nsched_model via reserved_meter's
#   own import chain).  Reference schedulers pull/ewma/oracle are the VALIDATED
#   ackclock_sim.Sim implementations (mirror=False -- clean isolation, matches
#   validate_local.py / myslice_battery.py convention).
#
# RIG: N3 MID = 2 spotty (cellA + cellB) + 1 steady (eth)  [== myslice's
#   "N3 2 spotty(cellA+cellB) + 1 steady(eth)", nominal_agg=129000 -- the exact
#   scenario that produced the historical numbers quoted in P6].
# Instrumented: gp, loss, res_tx (ADMITTED-DUPLICATE bytes/copies for Dpp; the
#   reference scheds carry no mirroring in this baseline comparison -> res_tx
#   is not meaningful for them and is omitted).
#
# P6 pass criteria:
#   load 0.65: Dpp gp >= 73000  AND  Dpp loss <= 12%
#              (context: static D:0.30 collapsed to 58644/30.0%; static D:0.15
#               won at 73913/11.7% -- Dpp must land at/above that knee WITHOUT
#               being hand-tuned to this N -- no static r choice is being reused)
#   load 0.85: Dpp gp >= 0.98 * ewma_gp   (ewma_gp measured THIS run; historical
#              ewma ~99752 from myslice.txt is a fidelity cross-check, not the
#              threshold itself)
# =============================================================================
import sys, time
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass

import reserved_meter as RM
import ackclock_sim as A

T = 9.0
SEEDS = 24
LOADS = [0.65, 0.85]
RIG = 'mid'

def med(xs):
    xs = sorted(xs); n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0

def main():
    t0 = time.time()
    archs = [RM.cellA(RM.DROPS_A), RM.cellB(RM.DROPS_B), RM.eth()]
    defs = RM.build_rig(archs, bottleneck=RIG)
    nom = sum(a['base'] for a in archs)
    nspot = sum(1 for a in archs if a['spotty'])

    print('=' * 100)
    print('P6 -- D\'\' (sched=Dpp, reserved_meter.py) vs pull / A(ewma) / oracle')
    print('RIG: N3 MID = 2 spotty(cellA+cellB) + 1 steady(eth)  N=%d spotty=%d nominal_agg=%d'
          % (len(archs), nspot, nom))
    print('T=%.1fs seeds=%d  physics=nsched_model (UNMODIFIED, via reserved_meter)' % (T, SEEDS))
    print('=' * 100)

    results = {}   # load -> sched -> {'gp':[], 'loss':[], 'res_tx':[]}
    for load in LOADS:
        ofn = (lambda t, _n=nom, _L=load: _L * _n)
        results[load] = {}
        for sched in ('pull', 'ewma', 'oracle', 'Dpp'):
            gp = []; loss = []; res_tx = []
            for sd in range(SEEDS):
                if sched == 'Dpp':
                    m = RM.SimD(defs, ofn, T, sd, sched='Dpp').run()
                    res_tx.append(m['res_tx'])
                else:
                    m = A.Sim(defs, ofn, T, sd, sched=sched, mirror=False).run()
                gp.append(m['gp']); loss.append(m['loss'])
            results[load][sched] = {
                'gp': med(gp), 'loss': med(loss),
                'res_tx': med(res_tx) if res_tx else None,
            }

    print('\n%-8s %-8s %10s %8s %10s' % ('load', 'sched', 'gp', 'loss%', 'res_tx'))
    print('-' * 50)
    for load in LOADS:
        for sched in ('pull', 'ewma', 'oracle', 'Dpp'):
            r = results[load][sched]
            rtx = '%10.0f' % r['res_tx'] if r['res_tx'] is not None else '%10s' % '-'
            print('%-8.2f %-8s %10.0f %8.1f %s' % (load, sched, r['gp'], r['loss'], rtx))
        print()

    # ---------------- P6 verdict ----------------
    print('=' * 100)
    print('P6 VERDICT')
    print('=' * 100)

    d65 = results[0.65]['Dpp']
    p65_gp_ok = d65['gp'] >= 73000
    p65_loss_ok = d65['loss'] <= 12.0
    p65_pass = p65_gp_ok and p65_loss_ok
    print('load=0.65  Dpp gp=%.0f (need >=73000: %s)  loss=%.1f%% (need <=12%%: %s)  res_tx=%.0f  -> %s'
          % (d65['gp'], p65_gp_ok, d65['loss'], p65_loss_ok, d65['res_tx'],
             'PASS' if p65_pass else 'FAIL'))
    print('  context: static D:0.30 historically collapsed to 58644/30.0%%; static D:0.15 won'
          ' at 73913/11.7%% (myslice.txt) -- Dpp must clear the knee no static r finds unaided.')

    d85 = results[0.85]['Dpp']
    e85 = results[0.85]['ewma']
    thresh85 = 0.98 * e85['gp']
    p85_pass = d85['gp'] >= thresh85
    print('\nload=0.85  ewma gp=%.0f (historical ~99752, this-run fidelity check: %s)'
          % (e85['gp'], abs(e85['gp'] - 99752) / 99752 < 0.05))
    print('load=0.85  Dpp gp=%.0f  need >=0.98*ewma=%.0f  -> %s'
          % (d85['gp'], thresh85, 'PASS' if p85_pass else 'FAIL'))
    print('  Dpp loss=%.1f%%  res_tx=%.0f  (ewma loss=%.1f%%, oracle gp=%.0f/loss=%.1f%%)'
          % (d85['loss'], d85['res_tx'], e85['loss'], results[0.85]['oracle']['gp'], results[0.85]['oracle']['loss']))

    overall = p65_pass and p85_pass
    print('\n' + '=' * 100)
    print('P6 OVERALL: %s' % ('PASS' if overall else 'FAIL'))
    print('=' * 100)
    print('\nelapsed %.1fs' % (time.time() - t0))
    return 0 if overall else 1

if __name__ == '__main__':
    sys.exit(main())
