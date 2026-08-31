#!/bin/sh
# orchestration/ecosim/p5/run.sh — Layer-2 artifact harness for the P5 DAG
# orchestration. Runs the REAL shipped shell artifacts (bond-xctl, bondctl,
# bond-watchdog, bond-ecod) under hermetic shims (wg/uci/ip/iptables/ubus/
# ping/logger/pgrep + init.d service shims + logical-clock sleep) through a
# lifecycle + fault battery, asserting the node/endpoint/feeder facts and the
# hard invariants after each step. Complements Layer-1 (bond_model.py, which
# proves reference==DAG-candidate exhaustively): Layer-2 proves the actual
# executables behave, reading the SAME bond.dag.
#
# Runs under POSIX sh. On the box this MUST be re-run under busybox sh (CI
# container) before hardware contact (rule 8) — flagged, not yet done here.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
P5="$REPO/deploy/p5"
BIN="$HERE/bin"
# STATELESS: per-invocation isolated work dir so N run.sh instances run IN PARALLEL
# (no shared-state collision — the emulator bottleneck). Override with ECOSIM_WORK=/path
# to pin/inspect; default = a fresh mktemp dir, auto-removed on exit. This also ends the
# in-repo work/ pollution. (Layer-1 bond_model.py is already stateless — pure in-memory.)
WORK="${ECOSIM_WORK:-$(mktemp -d 2>/dev/null || echo "$HERE/work.$$")}"
[ -n "${ECOSIM_WORK:-}" ] || trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
no()  { fail=$((fail+1)); echo "FAIL  $1"; }
asrt(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1 (want '$3' got '$2')"; fi; }

# --- per-scenario fresh world -------------------------------------------
setup() {
    rm -rf "$WORK"; mkdir -p "$WORK/etc/bond" "$WORK/run/bond" "$WORK/fakebin"
    export ECOSIM_STATE="$WORK"
    # fake target binaries (only -x is checked)
    for b in engarde-client bond-agg bond-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"
    done
    # facts / world
    echo lightning       > "$WORK/etc/bond/mode"
    echo wgclient1        > "$WORK/etc/bond/wg-logical"
    echo "203.0.113.9:51820" > "$WORK/direct"
    echo "203.0.113.9:51820" > "$WORK/ep"
    echo 1 > "$WORK/capable"
    echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"
    echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in engarde-client bond-agg bond-ecod bond-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
    # env for the artifacts
    export PATH="$BIN:$PATH"
    export BOND_DIR="$WORK/etc/bond"
    export RUN_DIR="$WORK/run/bond"
    export DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    export SVC="$BIN/svc-engarde"
    export AGG_SVC="$BIN/svc-agg"
    export ECOD_SVC="$BIN/svc-ecod"
    export WDOG_SVC="$BIN/svc-watchdog"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client"
    export AGG_BIN="$WORK/fakebin/bond-agg"
    export ECOD_BIN="$WORK/fakebin/bond-ecod"
    export XCTL="$P5/bond-xctl"
    export LOGGER="$BIN/logger"
}
fact()   { echo "$2" > "$WORK/$1"; }
bctl()   { sh "$P5/bondctl" "$@" >>"$WORK/ledger" 2>&1; }
xctl()   { sh "$P5/bond-xctl" "$@"; }
node()   { sh "$P5/bond-xctl" node 2>/dev/null; }
epv()    { cat "$WORK/ep" 2>/dev/null; }
runw()   { MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
runecod(){ MAXCYCLES=1 CYCLE=0 BONDCTL="$P5/bondctl" SYS_NET="$WORK/sys" PING="$BIN/ping" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1; }
running(){ cat "$WORK/running.$1" 2>/dev/null; }
# hook(): model a wg-ifup re-engage. Production 97-bond backgrounds `bond-xctl
# reconcile &` (hotplug must not block, and reconcile is mode-blind so it can
# never drop the speed feeder -- MF-2(a) dissolved); the harness runs it
# SYNCHRONOUSLY so assertions are deterministic (the reparented grandchild
# can't be waited on).
hook()   { sh "$P5/bond-xctl" reconcile >/dev/null 2>&1; }
# hook_hotplug(): run the REAL 97-bond (tests its ifup/interface/enabled
# guards). When engarde is disabled it exits before backgrounding — silent,
# synchronous, deterministic (the I1 silence guard).
hook_hotplug(){ INTERFACE=wgclient1 ACTION=ifup sh "$P5/97-bond" 2>/dev/null; }
# reboot(): model a box reboot. procd stops every feeder, then rc.d STARTS each
# ENABLED service (speed leaves engarde ALSO enabled, so a reboot-in-speed briefly
# starts BOTH feeders = the boot-time dual-feeder window, spec §9-risk-4), and wg
# comes up direct (GL co-writer). The first reconcile must collapse to one feeder.
reboot() {
    for s in engarde-client bond-agg; do
        if [ "$(cat "$WORK/enabled.$s" 2>/dev/null)" = 1 ]; then echo 1 > "$WORK/running.$s"
        else echo 0 > "$WORK/running.$s"; fi
    done
    fact ep "203.0.113.9:51820"        # wg up at boot -> GL co-writer sets direct
}

echo "===== P5 Layer-2 artifact harness ====="
# NG — N-GENERIC AGGREGATE (U6). Layer-1 (bond_model.py) proves the MODEL is
# parameterised over N; NG-2 there says in terms that the shipped ARTIFACT still
# truncated. These bars close that gap at Layer-2, on the real bond-xctl.
#
# THE DEFECT they catch (bond-xctl build_agg_env, pre-U6):
#     P=$(primary_wan); O=$(live_wans | grep -v "^$P$" | head -1)
#     echo "AGG_PATHS=$P,$O"
#     echo "AGG_W=$(cat .../agg_w || echo 20000,15000)"
# EXACTLY two paths and EXACTLY two weights. A third live source was discarded
# SILENTLY -- no error, no log, and the arity guard's count did not move. The
# client box declares FOUR WANs (docs/INTENT.md:193), so this was lost capacity
# on current hardware.
#
# The world is driven by the ip shim's `nwan` ladder (eth1,usb0,eth0,wwan0 with
# netifd metrics 1,2,3,4 from the ubus fixture) -- N is an input here, never a
# constant, and every bar below is asserted at more than one N.
aggenv() { cat "$WORK/etc/bond/agg_env" 2>/dev/null; }
aggf()   { aggenv | grep "^$1=" | cut -d= -f2-; }   # $1 = AGG_PATHS | AGG_W
ncsv()   { printf '%s' "$1" | tr ',' '\n' | grep -c .; }
# nrouted: the number of DISTINCT routed l3_devices in the source table -- the
# live source set, computed independently of build_agg_env. Distinct devices, not
# rows: `wan` and `wan6` are two netifd interfaces sharing eth1, so a row count
# would over-count the sources by one.
nrouted(){ sh "$P5/bond-xctl" _sources 2>/dev/null \
             | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg {print $2}' | sort -u | grep -c .; }

# NG1 — N=3: every live source is enrolled, in metric order, primary first.
setup; fact nwan 3; bctl on; bctl mode speed
asrt "NG1 N=3 speed engaged"          "$(running bond-agg)" 1
asrt "NG1 N=3 AGG_PATHS carries ALL 3" "$(aggf AGG_PATHS)" "eth1,usb0,eth0"
asrt "NG1 N=3 no source discarded (paths == routed sources)" "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "NG1 N=3 primary is first"       "$(aggf AGG_PATHS | cut -d, -f1)" "$(xctl _primary)"
# AGG_W is positional in bond-agg (parseW, main.go:540): a vector shorter than
# AGG_PATHS silently privileges the leading paths. Arity must track N.
asrt "NG1 N=3 AGG_W arity == N"       "$(ncsv "$(aggf AGG_W)")" 3
asrt "NG1 N=3 AGG_W is the neutral prior (no invented weights)" "$(aggf AGG_W)" "10000,10000,10000"
asrt "NG1 N=3 endpoint :59402"        "$(epv)" "127.0.0.1:59402"
# AGG_SPOTTY (U47): eth1/usb0/eth0 are all proto=dhcp in the fixture and no
# operator metered-fact exists here, so no link is spotty-class at N=3 --
# lightning (E1-gated, off by default) has nothing to nominate on.
asrt "NG1 N=3 AGG_SPOTTY empty (no metered class present)" "$(aggf AGG_SPOTTY)" ""

# NG2 — N=4 (the box's real declared arity): still ALL of them, still ordered.
setup; fact nwan 4; bctl on; bctl mode speed
asrt "NG2 N=4 AGG_PATHS carries ALL 4" "$(aggf AGG_PATHS)" "eth1,usb0,eth0,wwan0"
asrt "NG2 N=4 no source discarded"     "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "NG2 N=4 AGG_W arity == N"        "$(ncsv "$(aggf AGG_W)")" 4
asrt "NG2 N=4 speed engaged (no privileged N)" "$(running bond-agg)" 1
asrt "NG2 N=4 single feeder"           "$(running engarde-client)" 0
# AGG_SPOTTY (U47): wwan0 is the ONE fixture link classified metered without an
# operator fact -- its netifd proto is "qmi" (GL_CELL_PROTOS), so the class
# arrives here by the SAME cellular-proto path _metered() ships, not a new
# rule invented for this test. eth1/usb0/eth0 stay steady (proto=dhcp, no
# $BOND_DIR/metered file in this fixture).
asrt "NG2 N=4 AGG_SPOTTY names the metered link (proto=qmi)" "$(aggf AGG_SPOTTY)" "wwan0"

# NG3 — N=2 is not a special case, it is just the smallest N that aggregates.
setup; fact nwan 2; bctl on; bctl mode speed
asrt "NG3 N=2 AGG_PATHS"       "$(aggf AGG_PATHS)" "eth1,usb0"
asrt "NG3 N=2 AGG_W arity == N" "$(ncsv "$(aggf AGG_W)")" 2
asrt "NG3 N=2 AGG_SPOTTY empty (no metered class present)" "$(aggf AGG_SPOTTY)" ""

# NG4 — arity FLOOR, renamed guard. `enough_sources` (>= 2) is an arity test, not
# a "two WANs" test: N=1 refuses, and N=3/N=4 above pass identically.
setup; fact nwan 1; bctl on; bctl mode eco; bctl mode speed
asrt "NG4 N=1 speed refused, mode kept" "$(cat "$WORK/etc/bond/mode")" eco
asrt "NG4 N=1 no agg"                   "$(running bond-agg)" 0
grep -q '^speed|.*,enough_sources|' "$P5/bond.dag" \
  && ok "NG4 bond.dag speed guard is spelled enough_sources (not two_wans)" \
  || no "NG4 bond.dag speed guard still spelled two_wans"

# NG5 — applied_wans (the engarde/genconf twin of AGG_PATHS) is N-generic too,
# and eco selects the primary ONLY at any N (mode selection must not depend on N).
setup; fact nwan 3; bctl on
asrt "NG5 N=3 lightning applied_wans carries ALL 3" \
     "$(cat "$WORK/etc/bond/applied_wans")" "eth1 usb0 eth0"
bctl mode eco
asrt "NG5 N=3 eco applied_wans is the primary ONLY" \
     "$(cat "$WORK/etc/bond/applied_wans")" "eth1"

# NG6 — a STALE operator agg_w must not be bound POSITIONALLY to the wrong paths.
# `20000,15000` (the old hardcoded pair) on a 3-source box would give paths 1-2
# invented weights and path 3 whatever bond-agg defaults to. Arity mismatch ->
# refuse the file, fall back to the neutral prior. A correctly-sized file IS used.
setup; fact nwan 3; echo "20000,15000" > "$WORK/etc/bond/agg_w"; bctl on; bctl mode speed
asrt "NG6 stale 2-entry agg_w on a 3-source box is REFUSED" "$(aggf AGG_W)" "10000,10000,10000"
# AGG_SPOTTY (U47): agg_w arity handling must not perturb the independent
# spotty-class fact -- still empty at N=3 (no metered link in this fixture).
asrt "NG6 AGG_SPOTTY unaffected by a refused agg_w" "$(aggf AGG_SPOTTY)" ""
setup; fact nwan 3; echo "7,8,9" > "$WORK/etc/bond/agg_w"; bctl on; bctl mode speed
asrt "NG6 correctly-sized operator agg_w IS honoured" "$(aggf AGG_W)" "7,8,9"
asrt "NG6 AGG_SPOTTY unaffected by an honoured agg_w" "$(aggf AGG_SPOTTY)" ""

# NG7 — the N=3 build is STABLE: a healthy speed tick at N=3 must still be a
# no-op. converged() cmp's a FRESH build_agg_env against the live agg_env, so a
# non-deterministically ORDERED builder (e.g. one whose source order depends on
# `ubus list` ordering) would churn agg_env and bounce the EIF datapath every
# tick. Zero bond-agg restarts is the ordering-determinism bar.
setup; fact nwan 3; bctl on; bctl mode speed
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
E0=$(aggenv); runw; runw
R1=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
asrt "NG7 N=3 healthy tick: ZERO bond-agg restarts (build is order-stable)" "$R1" "$R0"
asrt "NG7 N=3 agg_env unchanged across ticks" "$(aggenv)" "$E0"

echo "===== Layer-2: $pass passed, $fail failed ====="
