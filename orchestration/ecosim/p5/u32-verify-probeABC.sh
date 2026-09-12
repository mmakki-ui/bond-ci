#!/bin/sh
# U32 VERIFY PROBE -- independent verifier, branch u32-verify. NOT part of any gate.
# Drives the REAL deploy/p5 artifacts under the Layer-2 shim world.
#   usage: sh <this> <repo-root-in-POSIX-form>   e.g. /c/Users/.../worktrees/u32
#   NOTE: the repo root MUST be a POSIX path. A Windows "C:/..." arg poisons PATH
#   (":" is the PATH separator) and every shim silently disappears -> false results.
set -u
REPO="$1"
P5="$REPO/deploy/p5"
BIN="$REPO/orchestration/ecosim/p5/bin"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
setup() {
    rm -rf "$WORK"; mkdir -p "$WORK/etc/bond" "$WORK/run/bond" "$WORK/fakebin"
    export ECOSIM_STATE="$WORK"
    for b in engarde-client bond-agg bond-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"; done
    echo lightning > "$WORK/etc/bond/mode"; echo wgclient1 > "$WORK/etc/bond/wg-logical"
    echo "203.0.113.9:51820" > "$WORK/direct"; echo "203.0.113.9:51820" > "$WORK/ep"
    echo 1 > "$WORK/capable"; echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"; echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in engarde-client bond-agg bond-ecod bond-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"; done
    export PATH="$BIN:$PATH"
    export BOND_DIR="$WORK/etc/bond" RUN_DIR="$WORK/run/bond" DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    export SVC="$BIN/svc-engarde" AGG_SVC="$BIN/svc-agg" ECOD_SVC="$BIN/svc-ecod" WDOG_SVC="$BIN/svc-watchdog"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client" AGG_BIN="$WORK/fakebin/bond-agg" ECOD_BIN="$WORK/fakebin/bond-ecod"
    export XCTL="$P5/bond-xctl" LOGGER="$BIN/logger"
}
fact(){ echo "$2" > "$WORK/$1"; }
bctl(){ sh "$P5/bondctl" "$@" >>"$WORK/ledger" 2>&1; }
runw(){ echo 0 > "$WORK/run/bond/wd_last"; MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
runw_real(){ MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
r(){ cat "$WORK/running.$1" 2>/dev/null; }
rst(){ cat "$WORK/restarts.$1" 2>/dev/null || echo 0; }
st(){ echo "  agg=$(r bond-agg) eng=$(r engarde-client) ep=$(cat "$WORK/ep") mode=$(cat "$WORK/etc/bond/mode") applied=$(cat "$WORK/etc/bond/applied_wans" 2>/dev/null) AGG_PATHS=$(grep '^AGG_PATHS=' "$WORK/etc/bond/agg_env" 2>/dev/null) eng_restarts=$(rst engarde-client) agg_restarts=$(rst bond-agg)"; }

echo "########## PROBE A: ONE-TICK BLIP (N=3 -> 1 for a single tick -> 3) ##########"
setup; fact nwan 3; bctl on; bctl mode speed
echo "T0 (steady speed, N=3):"; st
fact nwan 1;  runw; echo "T1 (blip observed, one tick):"; st
fact nwan 3;  runw; echo "T2 (world restored, one tick):"; st
runw;              echo "T3:"; st
runw;              echo "T4:"; st

echo
echo "########## PROBE B: N=0 (all routes gone, ubus still answering) ##########"
setup; fact nwan 3; bctl on; bctl mode speed
echo "T0:"; st
fact nwan 0; runw; echo "T1 (N=0):"; st
runw;              echo "T2:"; st
fact nwan 3; runw; echo "T3 (restored):"; st
echo "-- ledger tail --"; tail -14 "$WORK/ledger"

echo
echo "########## PROBE C: real COOLDOWN, blip recovery latency ##########"
setup; fact nwan 3; bctl on; bctl mode speed
fact nwan 1; runw; echo "after teardown tick:"; st
echo "wd_last=$(cat "$WORK/run/bond/wd_last")  now=$(date +%s)"
fact nwan 3
runw_real; echo "next tick WITHOUT rewinding cooldown:"; st
runw_real; echo "another tick:"; st
