#!/usr/bin/env python3
# Baseline / import sanity check for MYSLICE agent before trusting any results.
import sys
try:
    import reserved_dp as R
    import ackclock_sim as A
    import nsched_model as M
except Exception as e:
    print("IMPORT FAIL: %r" % (e,))
    sys.exit(1)

print("import OK: reserved_dp, ackclock_sim, nsched_model")
print("DT=%r PKT_KB=%r QMAX_MS=%r" % (M.DT, M.PKT_KB, M.QMAX_MS))

# self-check: SimD sched='pull' vs the validated A.Sim sched='pull' (mirror=False)
# on the same N=2 rig/seed/load -- should be close (both are pure hungriest-first
# pull admission over the pooled FIFO; not required to be byte-identical since
# SimD's local-drain classifier differs slightly from A.Sim's, but gp/loss should
# land in the same neighborhood as a sanity floor).
archs = [R.cellA(R.DROPS_A), R.eth()]
defs = R.build_rig(archs, bottleneck='mid')
nom = sum(a['base'] for a in archs)
ofn = lambda t: 0.8 * nom
T = 9.0
seed = 0
try:
    mD = R.SimD(defs, ofn, T, seed, sched='pull').run()
    mA = A.Sim(defs, ofn, T, seed, sched='pull', mirror=False).run()
except Exception as e:
    print("BASELINE RUN FAIL: %r" % (e,))
    sys.exit(1)

print("SimD(pull)  gp=%.0f loss=%.2f" % (mD['gp'], mD['loss']))
print("A.Sim(pull) gp=%.0f loss=%.2f" % (mA['gp'], mA['loss']))
gp_rel = abs(mD['gp'] - mA['gp']) / max(1.0, mA['gp'])
print("gp relative diff = %.3f" % gp_rel)
if gp_rel > 0.25:
    print("BASELINE WARN: SimD pull-mode diverges >25%% from validated A.Sim pull")
else:
    print("BASELINE OK: SimD pull-mode within sanity band of validated A.Sim pull")

# N-genericity smoke test at N=1, N=5 (degenerate + beyond the studied range) to
# make sure nothing in SimD assumes exactly 2 or 3 paths.
for n_extra in (0, 3):
    archs2 = [R.cellA(R.DROPS_A)] + [R.eth() for _ in range(n_extra)]
    defs2 = R.build_rig(archs2, bottleneck='mid')
    nom2 = sum(a['base'] for a in archs2)
    ofn2 = lambda t, _n=nom2: 0.7 * _n
    m2 = R.SimD(defs2, ofn2, T, seed, sched='D', reserve_frac=0.15).run()
    print("N=%d (1 spotty + %d eth) D:0.15  gp=%.0f loss=%.2f  (ran without error)" %
          (1 + n_extra, n_extra, m2['gp'], m2['loss']))
print("N-GENERICITY SMOKE TEST OK")
