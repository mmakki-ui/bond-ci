#!/bin/sh
# =============================================================================
# Gate-level RED demonstrations for the OBJ-D latency gate. Run from the u14
# worktree ROOT:   sh p4-bondagg/sim/latency-bars/out/reddemo.sh
#
# EXIT CODES ARE REAL HERE. The previous version of this script ran the gate as
#   "$PY" "$G" > out.txt 2>&1 || true
#   echo "rc=$?"
# which prints the exit status of `true`, i.e. 0, every single time. Every rc
# line in the old out/red-demos.txt was therefore 0 regardless of what the gate
# did, and the file evidenced no exit code at all. Fixed: `set +e`, capture `$?`
# on the next line, `set -e` back.
#
# Each demo edits ONE file, runs the gate, restores, and the restore is verified
# against the committed pin at the end.
# =============================================================================
set -e
W="$PWD"
PY="${PY:-$LOCALAPPDATA/Programs/Python/Python312/python.exe}"
G=.github/scripts/latency_gate.py
B=p4-bondagg/sim/latency-bars/latency_battery.py
E=p4-bondagg/sim/modes-r2-study/expF_marginal.py
O="${TMPDIR:-$LOCALAPPDATA/Temp}"

cp "$B" "$O/B.bak"; cp "$E" "$O/E.bak"; cp "$G" "$O/G.bak"

run_gate() {   # $1 = output file. Sets $rc to the gate's REAL exit code.
  set +e
  SEEDS=6 T=9.0 PYTHONHASHSEED=0 "$PY" "$G" > "$1" 2>&1
  rc=$?
  set -e
}

repin() {      # re-measure the HASH pin, exactly as an attacker would
  "$PY" "$G" --rehash 2>/dev/null > "$O/newpin.txt"
  "$PY" - "$G" "$O/newpin.txt" <<'PY'
import sys, re
g, np = sys.argv[1], sys.argv[2]
s = open(g, encoding='utf-8').read()
new = open(np, encoding='utf-8').read()
s = re.sub(r"PIN = \{\n.*?\n\}", "PIN = {\n" + new.rstrip() + "\n}", s, count=1, flags=re.S)
open(g, 'w', encoding='utf-8', newline='\n').write(s)
PY
}

echo "############ DEMO D -- the instrument was EDITED and not re-measured"
"$PY" - "$B" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
a = "        p95_m - p95_s, 'p95=%.0f max=%.0f' % (p95_s, p95_m))"
b = "        p95_m + 100.0 - p95_s, 'p95=%.0f max=%.0f' % (p95_s, p95_m))"
assert s.count(a) == 1, s.count(a)
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(a, b, 1))
PY
run_gate "$O/red_D.txt"; echo "rc=$rc  (expect 2 -- hash pin)"; tail -12 "$O/red_D.txt"
cp "$O/B.bak" "$B"

echo
echo "############ DEMO B -- SPD-2b DILUTED and the hash pin dutifully re-measured"
"$PY" - "$B" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
a = "        p95_m - p95_s, 'p95=%.0f max=%.0f' % (p95_s, p95_m))"
b = "        p95_m + 100.0 - p95_s, 'p95=%.0f max=%.0f' % (p95_s, p95_m))"
assert s.count(a) == 1
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(a, b, 1))
PY
repin
run_gate "$O/red_B.txt"; echo "rc=$rc  (expect 1 -- margin pin + MUST_FAIL not hit)"
sed -n '/MARGIN PIN --/,$p' "$O/red_B.txt" | head -14
sed -n '/GATE FAIL -- .*MUST_FAIL/,$p' "$O/red_B.txt" | head -8
cp "$O/B.bak" "$B"; cp "$O/G.bak" "$G"

echo
echo "############ DEMO C -- SPD-6b HOLLOWED (always true) + hash pin re-measured"
"$PY" - "$B" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
a = "        s1 - s3, 'seg3=%.4f seg1=%.4f' % (s3, s1))"
b = "        s1 + 1.0 - s3, 'seg3=%.4f seg1=%.4f' % (s3, s1))"
assert s.count(a) == 1
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(a, b, 1))
PY
repin
run_gate "$O/red_C.txt"; echo "rc=$rc  (expect 1 -- margin pin + mutation)"
sed -n '/MARGIN PIN --/,$p' "$O/red_C.txt" | head -10
sed -n '/MUTATION MATRIX/,$p' "$O/red_C.txt" | head -14
cp "$O/B.bak" "$B"; cp "$O/G.bak" "$G"

echo
echo "############ DEMO E -- THE VERIFY ATTACK: FOUR gated bars diluted at once,"
echo "############           hash pin re-measured exactly as DEMO B/C prescribe."
echo "############ This exact edit set exited 0 / GATE PASS before the fix, with all"
echo "############ four mutation rows '-> ok'. It is the fourth weakened-green gate"
echo "############ in this project and it is what MARGIN_PIN exists to stop."
"$PY" - "$B" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
subs = [
    # 1. SPD-3a: accepted goodput loss widened from 1% to 40%
    ("    CAL['SPD3_GP'] = 0.99", "    CAL['SPD3_GP'] = 0.60"),
    # 2. HOLD-1d: the ONE-EVENT burst allowance becomes a twenty-event allowance
    ("        lf + burst - lr, 'late=%.0f fixed=%.0f burst=%.0f' % (lr, lf, burst))",
     "        lf + 20.0 * burst - lr, 'late=%.0f fixed=%.0f burst=%.0f' % (lr, lf, burst))"),
    # 3. HOLD-2b: same, mid
    ("        lfm + burstm - lrm, 'late=%.0f fixed=%.0f burst=%.0f' % (lrm, lfm, burstm))",
     "        lfm + 20.0 * burstm - lrm, 'late=%.0f fixed=%.0f burst=%.0f' % (lrm, lfm, burstm))"),
    # 4. HOLD-4a: an EXACT unit identity given half a model tick of slop
    ("        ulp_margin(h1, G), 'hold=%.3f gran=%.3f' % (h1, G))",
     "        5.0 - abs(h1 - G), 'hold=%.3f gran=%.3f' % (h1, G))"),
]
for a, b in subs:
    assert s.count(a) == 1, (s.count(a), a)
    s = s.replace(a, b, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
PY
repin
run_gate "$O/red_E.txt"; echo "rc=$rc  (expect 1 -- margin pin, four MOVED rows)"
sed -n '/MARGIN PIN --/,$p' "$O/red_E.txt" | head -16
echo "-- and the mutation matrix, which passed this attack before the fix:"
sed -n '/MUTATION MATRIX/,$p' "$O/red_E.txt" | sed -n '7,12p'
cp "$O/B.bak" "$B"; cp "$O/G.bak" "$G"

echo
echo "############ DEMO F -- GRANULARITY INFLATED AT THE SOURCE (r1 sec 8 limb 2)"
echo "############ HOLD-4 alone cannot see this: raise nsched_model.DT and GRAN, TOL,"
echo "############ the ratchet floor and every HOLD-4 expectation move TOGETHER."
cp p4-bondagg/sim/nsched_model.py "$O/N.bak"
"$PY" - p4-bondagg/sim/nsched_model.py <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
a = "\nDT = 0.010\n"; b = "\nDT = 0.030\n"
assert s.count(a) == 1
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(a, b, 1))
PY
run_gate "$O/red_F.txt"; echo "rc=$rc  (expect 2 -- _gran_guard trips before any physics runs)"
grep -A7 'GRAN GUARD FAILED' "$O/red_F.txt" | head -10
cp "$O/N.bak" p4-bondagg/sim/nsched_model.py

echo
echo "############ DEMO A -- the SYSTEM UNDER TEST regresses (speed key -> hungriest)"
"$PY" - "$E" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
a = ("                else:  # v2: marginal completion = flight + current local wait\n"
     "                    cand.sort(key=lambda i: s.owd[i] + s._local_ms(i))")
b = ("                else:  # v2 REGRESSED for the U14 gate demo: hungriest-first\n"
     "                    cand.sort(key=s._local_ms)")
assert s.count(a) == 1
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(a, b, 1))
PY
run_gate "$O/red_A.txt"; echo "rc=$rc  (expect 1 -- margin pin + MUST_FAIL + NEW fails + mutation)"
sed -n '/MARGIN PIN --/,$p' "$O/red_A.txt" | head -8
sed -n '/BAR FAILURES BY CLASS/,$p' "$O/red_A.txt" | head -24
cp "$O/E.bak" "$E"

echo
echo "############ RESTORED -- both pins must match the committed values"
"$PY" "$G" --rehash 2>/dev/null
git -C "$W" status --short
