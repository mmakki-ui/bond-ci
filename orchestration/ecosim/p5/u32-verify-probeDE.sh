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
WORK=$(mktemp -d); SHADOW="$WORK/shadow"
trap 'rm -rf "$WORK"' EXIT
setup() {
    rm -rf "$WORK"; mkdir -p "$WORK/etc/bond" "$WORK/run/bond" "$WORK/fakebin" "$SHADOW"
    export ECOSIM_STATE="$WORK"
    for b in engarde-client bond-agg bond-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"; done
    echo lightning > "$WORK/etc/bond/mode"; echo wgclient1 > "$WORK/etc/bond/wg-logical"
    echo "203.0.113.9:51820" > "$WORK/direct"; echo "203.0.113.9:51820" > "$WORK/ep"
    echo 1 > "$WORK/capable"; echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"; echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in engarde-client bond-agg bond-ecod bond-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"; done
    export PATH="$SHADOW:$BIN:$PATH"
    export BOND_DIR="$WORK/etc/bond" RUN_DIR="$WORK/run/bond" DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    export SVC="$BIN/svc-engarde" AGG_SVC="$BIN/svc-agg" ECOD_SVC="$BIN/svc-ecod" WDOG_SVC="$BIN/svc-watchdog"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client" AGG_BIN="$WORK/fakebin/bond-agg" ECOD_BIN="$WORK/fakebin/bond-ecod"
    export XCTL="$P5/bond-xctl" LOGGER="$BIN/logger"
}
fact(){ echo "$2" > "$WORK/$1"; }
bctl(){ sh "$P5/bondctl" "$@" >>"$WORK/ledger" 2>&1; }
runw(){ echo 0 > "$WORK/run/bond/wd_last"; MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
r(){ cat "$WORK/running.$1" 2>/dev/null; }
st(){ echo "  agg=$(r bond-agg) eng=$(r engarde-client) ep=$(cat "$WORK/ep")"; }
brk_ip(){ printf '#!/bin/sh\nexit 1\n' > "$SHADOW/ip"; chmod +x "$SHADOW/ip"; }
brk_ubus(){ printf '#!/bin/sh\nexit 1\n' > "$SHADOW/ubus"; chmod +x "$SHADOW/ubus"; }
unbrk(){ rm -f "$SHADOW/ip" "$SHADOW/ubus"; }

echo "##### PROBE D: transient \`ip\` failure for ONE tick (ubus healthy, N=3) #####"
setup; fact nwan 3; bctl on; bctl mode speed; echo "T0:"; st
brk_ip; runw; unbrk; echo "T1 (ip exits 1 during the tick):"; st
runw; echo "T2 (ip healthy again):"; st
echo "-- ledger tail --"; tail -6 "$WORK/ledger"

echo
echo "##### PROBE E: transient \`ubus\` failure for ONE tick (ip healthy, N=3) #####"
setup; fact nwan 3; bctl on; bctl mode speed; echo "T0:"; st
brk_ubus; runw; unbrk; echo "T1 (ubus exits 1 during the tick):"; st
runw; echo "T2:"; st
echo "-- ledger tail --"; tail -6 "$WORK/ledger"
