#!/bin/sh
# Regenerate the two studies that DERIVE what latency_gate.py is allowed to gate.
# Neither runs in CI: the geometry study is 5 full batteries and the mutation
# matrix's slowest defect is minutes per scenario. CI runs the SUBSET recorded in
# latency_gate.py (one clean battery + four fast defects) and re-derives nothing.
#
# Run from p4-bondagg/sim/latency-bars:   sh out/RUNME.sh
#
# Total ~12 min on this PC (Python 3.12, no parallelism inside the battery).
set -e
cd "$(dirname "$0")/.."
PY="${PY:-python}"

# --- study 1: which bars survive a change of STALL GEOMETRY ------------------
# canonical = the hand-placed DROPS_*. Integers select `rig_checks.phase_drops`
# rotations (U33's corrected randomiser: count- and duration-preserving, no
# interval over t=0). Widening the sample is adding integers to this list.
for g in canonical 3 7 11 19; do
  echo "== geometry $g"
  SEEDS=6 GEO="$g" $PY -u latency_battery.py > "out/geo_$g.txt" 2>&1
done
$PY geometry_split.py

# --- study 2: which DEFECT reddens which bar --------------------------------
# SEEDS=2: these are gross injections and the question is whether the VERDICT
# flips, not what the margin is. `none` is the clean control the matrix is read
# against. `hold-quantile` is included here and deliberately NOT in the gate's
# matrix -- holdlib.dyn_release re-sorts its window on every block and takes
# minutes per scenario.
for d in none rank-static rank-hungriest rank-mid-meter hold-gran warmup-max ratchet-x3; do
  echo "== defect $d"
  SEEDS=2 DEFECT="$d" $PY -u latency_battery.py > "out/mut_$d.txt" 2>&1
done
$PY mutation_matrix.py

echo
echo "Now reconcile .github/scripts/latency_gate.py by hand:"
echo "  GATED / REPORTED   <- out/geometry.md minus out/mutations.md's NO RED DEMO"
echo "  MUTATIONS          <- out/mutations.md"
echo "  MUST_FAIL          <- the FAIL lines in out/geo_canonical.txt, GATED ids only"
echo "  PIN                <- python .github/scripts/latency_gate.py --rehash"
echo "  MARGIN_PIN         <- SEEDS=6 T=9.0 PYTHONHASHSEED=0 \\"
echo "                        python .github/scripts/latency_gate.py --remargin"
echo "and say in the commit message which one moved and why. Never add a baseline"
echo "entry to go green, and never regenerate MARGIN_PIN to clear a MOVED row"
echo "without saying what moved: the delta IS the finding. --rehash deliberately"
echo "does not touch MARGIN_PIN -- 'dilute, --rehash, commit' is the attack that"
echo "put four weakened bars through this gate at exit 0."
