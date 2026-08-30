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
    for s in engarde-client bond-agg bond-ecod bond-watchdog cake-autorate; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
    # E4 shaping (U22): the box starts UNSHAPED with the `shape` fact absent,
    # so the default (`on`) is what every pre-existing scenario exercises --
    # shaping has to converge itself on the first lifecycle edge, exactly as it
    # will on a fresh install. MTU starts at the engarde-side 1420.
    echo 1420 > "$WORK/mtu.wgclient1"
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
    # E4 shaping controller (U22). `tc` is NOT exported: bond-xctl resolves it
    # through PATH, and $BIN is prepended above, so the shim wins.
    export SHAPE_SVC="$BIN/svc-shape"
}
fact()   { echo "$2" > "$WORK/$1"; }
bctl()   { sh "$P5/bondctl" "$@" >>"$WORK/ledger" 2>&1; }
xctl()   { sh "$P5/bond-xctl" "$@"; }
node()   { sh "$P5/bond-xctl" node 2>/dev/null; }
epv()    { cat "$WORK/ep" 2>/dev/null; }
runw()   { MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
runecod(){ MAXCYCLES=1 CYCLE=0 BONDCTL="$P5/bondctl" SYS_NET="$WORK/sys" PING="$BIN/ping" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1; }
running(){ cat "$WORK/running.$1" 2>/dev/null; }
# E4 shaping observations (U22)
shapev() { sh "$P5/bond-xctl" _shape 2>/dev/null; }          # "off" | "<ifname>"
qdiscv() { cat "$WORK/qdisc.wgclient1" 2>/dev/null || echo none; }   # "<kind> mtu <n>"
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

# S1 — on: engage engarde, endpoint local, single feeder
setup; bctl on
asrt "S1 on: node"        "$(node)" engaged
asrt "S1 on: endpoint"    "$(epv)"  "127.0.0.1:59401"
asrt "S1 on: engarde up"  "$(running engarde-client)" 1
asrt "S1 on: agg down"    "$(running bond-agg)" 0

# S2 — off: direct, no feeder, stays off
setup; bctl on; bctl off
asrt "S2 off: node"       "$(node)" off
asrt "S2 off: endpoint"   "$(epv)"  "203.0.113.9:51820"
asrt "S2 off: engarde down" "$(running engarde-client)" 0

# S3 — incapable server: engage self-test fails -> suspended, direct
setup; fact capable 0; bctl on
asrt "S3 incapable: node"     "$(node)" suspended
asrt "S3 incapable: endpoint" "$(epv)" "203.0.113.9:51820"
# S3b — capability returns + wg ifup (97-bond) -> auto-resume engaged (I6)
fact capable 1; hook
asrt "S3b resume: node"     "$(node)" engaged
asrt "S3b resume: endpoint" "$(epv)" "127.0.0.1:59401"

# S4 — mode eco live switch (engarde restarted, single feeder)
setup; bctl on; bctl mode eco
asrt "S4 eco: mode"        "$(cat "$WORK/etc/bond/mode")" eco
asrt "S4 eco: node"        "$(node)" engaged
asrt "S4 eco: single feeder" "$(running bond-agg)" 0

# S5 — speed engage: agg up, engarde down, endpoint :59402
setup; bctl on; bctl mode speed
asrt "S5 speed: mode"      "$(cat "$WORK/etc/bond/mode")" speed
asrt "S5 speed: agg up"    "$(running bond-agg)" 1
asrt "S5 speed: engarde down" "$(running engarde-client)" 0
asrt "S5 speed: endpoint"  "$(epv)" "127.0.0.1:59402"

# S6 — speed verify FAIL (server 59402 not capable) -> restore prev mode (INV5)
setup; bctl on; bctl mode eco; fact capable 0; bctl mode speed
asrt "S6 speed-fail: mode restored" "$(cat "$WORK/etc/bond/mode")" eco
asrt "S6 speed-fail: agg down"      "$(running bond-agg)" 0
asrt "S6 speed-fail: engarde back"  "$(running engarde-client)" 1
# MF-1: speed_revert's restore_feeder must RE-PIN the engarde endpoint LOCAL (the
# undefined engage_verify used to leave it DIRECT, silently unbonding on speed exit).
asrt "S6 speed-fail: endpoint LOCAL (MF-1)" "$(epv)" "127.0.0.1:59401"

# S7 — speed guard fail (one WAN) -> refused, mode kept, no agg
setup; bctl on; bctl mode eco; fact onewan 1; bctl mode speed
asrt "S7 speed-1wan: refused, mode kept" "$(cat "$WORK/etc/bond/mode")" eco
asrt "S7 speed-1wan: no agg"             "$(running bond-agg)" 0

# S8 — speed then off: full teardown, single-feeder never violated
setup; bctl on; bctl mode speed; bctl off
asrt "S8 speed->off: node" "$(node)" off
asrt "S8 speed->off: agg down"     "$(running bond-agg)" 0
asrt "S8 speed->off: engarde down" "$(running engarde-client)" 0
# MF-1: leaving speed must leave the endpoint CORRECT. Off tears down to DIRECT
# (engarde disabled first -> restore_feeder pins direct); the missing endpoint
# assert on the speed-exit path is what hid MF-1.
asrt "S8 speed->off: endpoint DIRECT (MF-1)" "$(epv)" "203.0.113.9:51820"

# S8b — speed -> lightning LIVE switch: single feeder, and the engarde feeder
# endpoint re-pinned LOCAL. This is the MF-1 catch on the `switch` edge: its
# speeddown_if_speed -> restore_feeder must pin 127.0.0.1:59401, not DIRECT.
setup; bctl on; bctl mode speed; bctl mode lightning
asrt "S8b speed->lightning: mode"        "$(cat "$WORK/etc/bond/mode")" lightning
asrt "S8b speed->lightning: agg down"    "$(running bond-agg)" 0
asrt "S8b speed->lightning: engarde up"  "$(running engarde-client)" 1
asrt "S8b speed->lightning: endpoint LOCAL (MF-1)" "$(epv)" "127.0.0.1:59401"

# ============ FAULT BATTERY ============
# F1 — feeder crash + procd respawn (simulated) then a converge: still engaged
setup; bctl on; fact running.engarde-client 1   # respawn brought it back
xctl reconcile >/dev/null 2>&1                   # level-triggered: desired=engaged, no-op
asrt "F1 crash+respawn: still engaged" "$(node)" engaged
asrt "F1 crash+respawn: single feeder" "$(running bond-agg)" 0

# F2 — respawn EXHAUSTION: enabled but process absent -> watchdog W1 restarts it
setup; bctl on; fact running.engarde-client 0    # procd gave up
asrt "F2 pre: engarde absent" "$(running engarde-client)" 0
runw
asrt "F2 W1 pickup: engarde restarted" "$(running engarde-client)" 1

# F3 — dead state (INV2): endpoint local but engarde DISABLED (rc off) + down.
# RECONCILER CHANGE (was: W2 force-engaged, mode/rc-blind): the dead-state remedy is
# now rc-aware -- reconcile derives desired=off (rc off) and heals the dead state to
# OFF/direct. INV2 still holds (no local endpoint left without a listener), and rc is
# respected (a disabled box is not silently re-engaged). rc-ON dead-state heal = F2.
setup; fact ep "127.0.0.1:59401"; fact enabled.engarde-client 0; fact running.engarde-client 0
runw
asrt "F3 dead-state remedy: engarde stays down" "$(running engarde-client)" 0
asrt "F3 dead-state remedy: node off"           "$(node)" off
asrt "F3 dead-state remedy: endpoint direct"    "$(epv)" "203.0.113.9:51820"

# F4 — two feeders (INV1): both running -> W3 stops the stray (non-speed: kills agg)
setup; bctl on; fact running.bond-agg 1
runw
asrt "F4 W3 single-feeder: agg stopped" "$(running bond-agg)" 0
asrt "F4 W3 single-feeder: engarde kept" "$(running engarde-client)" 1

# F5 — watchdog is a NO-OP in a clean engaged state (I11): nothing changes
setup; bctl on
b_ep=$(epv); b_e=$(running engarde-client); b_a=$(running bond-agg)
runw
asrt "F5 I11 clean no-op: endpoint"  "$(epv)" "$b_ep"
asrt "F5 I11 clean no-op: engarde"   "$(running engarde-client)" "$b_e"
asrt "F5 I11 clean no-op: agg"       "$(running bond-agg)" "$b_a"

# F6 — policer degradation (D1): watchdog publishes tput; ecod flips eco->lightning
setup; bctl on; touch "$WORK/etc/bond/auto"; fact enabled.bond-ecod 1; bctl mode eco
touch "$WORK/etc/bond/auto"                # bctl mode cleared it; re-arm for ecod path
echo "degraded rate=1000Bps floor=131072" > "$WORK/run/bond/tput"
fact "etc/bond/applied_wans" eth1
runecod
asrt "F6 tput->ecod: mode lightning" "$(cat "$WORK/etc/bond/mode")" lightning

# F7 — tput sensor PUBLISHES a fact (W5, publish-only)
setup; bctl on
echo $(( $(date +%s) - 5 )) > "$WORK/run/bond/wd_rxt"; echo 0 > "$WORK/run/bond/wd_rx"; fact rx 300000
runw
if [ -s "$WORK/run/bond/tput" ]; then ok "F7 W5 sensor published tput ($(cat "$WORK/run/bond/tput"))"; else no "F7 W5 sensor published tput (empty)"; fi

# F8 — power-loss stale lock is self-clearing (tmpfs, D4): a leftover lock with a
# dead holder pid is broken; the op proceeds (not stuck forever).
setup; mkdir -p "$WORK/run/bond/lock"; echo 999999 > "$WORK/run/bond/lock/pid"   # dead pid
bctl on
asrt "F8 stale-lock self-clear: engaged" "$(node)" engaged

# F9 (MF-3) — lock serialization WITH the age gate: a held lock whose holder pid is
# LIVE and whose age is >120s (but < the 900s PID-reuse backstop) must STILL make a
# concurrent op skip. The pre-fix `age>120` alone would break a live holder mid-engage
# (a legit ~6-8min hold) -> two concurrent DAG walks. MF-3: STALE respects holder
# liveness; age never breaks a live holder below the 900s backstop. ($$ = this live
# run.sh pid; backdate the lock mtime so stat -c %Y reports it aged >120s.)
setup; bctl on; mkdir -p "$WORK/run/bond/lock"; echo $$ > "$WORK/run/bond/lock/pid"  # LIVE holder
touch -d '200 seconds ago' "$WORK/run/bond/lock"                                     # aged >120s, < 900s
out=$(xctl reconcile 2>&1); rmdir "$WORK/run/bond/lock" 2>/dev/null
echo "$out" | grep -q "in progress; skipping" && ok "F9 MF-3 live-holder lock aged>120s: concurrent op skipped" || no "F9 MF-3 lock serialization (out=$out)"

# F10 — coexistence: GL VPN-manager co-writer rewrites endpoint to direct; the
# 97-bond hook re-heals to local (I2), never a dead state. NO-BOUNCE (effect-
# idempotency, the drift-gated BLOCKER-1 class): the heal is a DELTA (ep != LOCAL) so
# converged() does NOT short-circuit -- the engage edge IS walked -- but because the
# CONFIG did not move, the per-leaf idempotency must keep it a no-bounce heal:
# act_eng_restart is an ensure-running no-op (genconf_changed crumb absent + engarde up)
# and verify_local takes its ep==LOCAL fast-path after ep_local re-pins (no iptables
# silence-window). Teeth: FAILS against the leaf-deleted commit (+1 engarde restart,
# iptables 2->4); PASSES only with the restored crumb-guard + fast-path.
setup; bctl on; fact ep "203.0.113.9:51820"   # co-writer reset
R0=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
hook
R1=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F10 co-writer re-heal: endpoint" "$(epv)" "127.0.0.1:59401"
asrt "F10 co-writer re-heal: node"     "$(node)" engaged
asrt "F10 co-writer re-heal: ZERO engarde restarts (no datapath bounce)" "$R1" "$R0"
asrt "F10 co-writer re-heal: no iptables silence-window (fast-path verify)" "$IPT1" "$IPT0"

# F11 — OFF stays off across a co-writer rewrite + REAL 97-bond hotplug hook
# (I1: the hook is silent while engarde is disabled — the guard, not luck).
setup; bctl on; bctl off; fact ep "203.0.113.9:51820"; hook_hotplug
asrt "F11 OFF stable under co-writer+hotplug: node" "$(node)" off
asrt "F11 OFF stable under co-writer+hotplug: endpoint" "$(epv)" "203.0.113.9:51820"

# F12 — REAL 97-bond re-engages when engarde IS enabled (wrong-iface = silent)
setup; bctl on; fact ep "203.0.113.9:51820"
INTERFACE=wan0 ACTION=ifup sh "$P5/97-bond" 2>/dev/null       # wrong iface -> silent
asrt "F12 hotplug wrong-iface: endpoint unchanged" "$(epv)" "203.0.113.9:51820"

# F13 (MF-2) — SPEED pinned across a co-writer wg_ifup hook + a watchdog tick, with
# NO oscillation. The deployed 97-bond fired `engage` mode-blindly (engarde stays
# enabled in speed), tearing speed down on every wg ifup -> hook<->watchdog fight ->
# capped black-hole. Under the reconciler BOTH the hook and the watchdog funnel to
# reconcile() (mode-aware: desired=engaged_speed), so the box stays pinned in speed
# every cycle (INV1 single-feeder holds: agg up, engarde down, ep :59402).
setup; bctl on; bctl mode speed
osc_ok=1; i=1
while [ "$i" -le 3 ]; do
    fact ep "203.0.113.9:51820"          # GL co-writer knocks the endpoint to direct
    hook                                  # 97-bond -> reconcile (mode-blind, must keep speed)
    runw                                  # periodic watchdog reconcile
    [ "$(cat "$WORK/etc/bond/mode")" = speed ] && [ "$(running bond-agg)" = 1 ] \
        && [ "$(running engarde-client)" = 0 ] && [ "$(epv)" = "127.0.0.1:59402" ] || osc_ok=0
    i=$((i+1))
done
[ "$osc_ok" = 1 ] && ok "F13 MF-2 speed pinned across wg_ifup x watchdog (no oscillation, INV1)" \
    || no "F13 MF-2 speed oscillated (mode=$(cat "$WORK/etc/bond/mode") agg=$(running bond-agg) eng=$(running engarde-client) ep=$(epv))"

# F14 (reboot-in-speed, INV1) — speed leaves BOTH feeders ENABLED (engarde still
# enabled + agg enabled), so a reboot's rc.d starts both = the boot-time dual-feeder
# window. The FIRST reconcile must collapse to a single feeder (agg), never leaving
# both engarde AND agg running.
setup; bctl on; bctl mode speed
reboot                                    # both enabled -> both running; wg up direct
runw                                      # first watchdog reconcile after boot
sf_ok=1; [ "$(running engarde-client)" = 1 ] && [ "$(running bond-agg)" = 1 ] && sf_ok=0
[ "$sf_ok" = 1 ] && ok "F14 reboot-in-speed: single feeder after first reconcile (not engarde AND agg)" \
    || no "F14 reboot-in-speed: TWO feeders (eng=$(running engarde-client) agg=$(running bond-agg))"
asrt "F14 reboot-in-speed: speed feeder up" "$(running bond-agg)" 1
asrt "F14 reboot-in-speed: mode kept"       "$(cat "$WORK/etc/bond/mode")" speed

# F15 (MF-4) — TERM an IN-FLIGHT bond-xctl: `trap 'exit 143' INT TERM` must fire the
# EXIT trap so the process ACTUALLY exits (busybox ash otherwise resumes after a
# handled signal and keeps mutating unserialized) AND the ownership-checked EXIT trap
# releases the lock. Assert: the lock is GONE and the process is DEAD (no mutation).
# NOTE: this is the ONE scenario that uses REAL (short) wall-clock sleeps -- the engage
# dance must hold the lock long enough to be TERMed. A realbin/sleep shadows the
# logical-clock no-op sleep with short 0.2s real sleeps so bond-xctl loops in verify_local
# (a LOOP of short children) instead of one long child, letting the trap fire promptly.
setup
mkdir -p "$WORK/realbin"
printf '#!/bin/sh\nexec /usr/bin/sleep 0.2\n' > "$WORK/realbin/sleep"; chmod +x "$WORK/realbin/sleep"
fact enabled.engarde-client 1            # desired=engaged -> reconcile walks the engage dance
fact capable 0                           # verify_local fails -> loops all retries (wide TERM window)
PATH="$WORK/realbin:$PATH" sh "$P5/bond-xctl" reconcile >/dev/null 2>&1 & xpid=$!
w=0; while [ ! -d "$WORK/run/bond/lock" ] && [ "$w" -lt 100 ]; do /usr/bin/sleep 0.05; w=$((w+1)); done
if [ -d "$WORK/run/bond/lock" ]; then
    kill -TERM "$xpid" 2>/dev/null
    w=0; while kill -0 "$xpid" 2>/dev/null && [ "$w" -lt 100 ]; do /usr/bin/sleep 0.05; w=$((w+1)); done
    if kill -0 "$xpid" 2>/dev/null; then
        kill -KILL "$xpid" 2>/dev/null; no "F15 MF-4 TERM: process did NOT exit (trap resumed)"
    elif [ -d "$WORK/run/bond/lock" ]; then
        no "F15 MF-4 TERM: process exited but lock NOT released"
    else
        ok "F15 MF-4 TERM in-flight: process exited AND lock released"
    fi
else
    kill -KILL "$xpid" 2>/dev/null; no "F15 MF-4 TERM: engage never took the lock (setup race)"
fi

# F16 (BLOCKER-1, restart-storm) — a healthy-box watchdog tick MUST be a TRUE no-op:
# ZERO engarde restarts (no datapath bounce) and NO iptables silence-window. The pre-fix
# engage leaves ran genconf + eng_restart + the full verify_local dance UNCONDITIONALLY
# on every 10s tick -> a restart/silence storm. The svc shim now COUNTS restarts (the
# regression was previously HIDDEN because restart==start in the shim), so this test has
# teeth: it FAILS against the pre-fix leaves and PASSES only once they are effect-
# idempotent (genconf cmp-guarded, eng_restart ensure-running, verify_local fast-path).
setup; bctl on
R0=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw
R1=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F16 BLOCKER-1 healthy tick: ZERO engarde restarts (no datapath bounce)" "$R1" "$R0"
asrt "F16 BLOCKER-1 healthy tick: no iptables silence-window" "$IPT1" "$IPT0"

# F17 (BLOCKER-1, SPEED restart-storm) — the UNGUARDED path the fix was about: a healthy
# SPEED-box watchdog tick MUST be a TRUE no-op -- ZERO bond-agg restarts (no EIF datapath
# bounce) and NO new iptables. Pre-fix, a speed box's every ~10s reconcile re-ran the
# speed edge (act_agg_restart UNCONDITIONAL + act_env_gen rewrite + verify_speed dance),
# bouncing the bond-agg datapath every 10s. This has teeth: the svc-agg shim now COUNTS
# restarts, so it FAILS if the stateless converged() short-circuit is absent and PASSES
# only once a fully-at-target speed box walks NO edge.
setup; bctl on; bctl mode speed
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw
R1=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F17 BLOCKER-1 healthy speed tick: ZERO bond-agg restarts (no EIF bounce)" "$R1" "$R0"
asrt "F17 BLOCKER-1 healthy speed tick: no iptables silence-window" "$IPT1" "$IPT0"

# F18 (BLOCKER-1, SPEED drift-heal — the speed analogue of F10) — a GL co-writer knocks
# the SPEED box's endpoint to direct. The reconcile heal is a DELTA (ep != :59402) so
# converged() does NOT short-circuit and the speed edge IS walked -- but with agg_env
# unchanged it must be a NO-BOUNCE heal: act_agg_restart is an ensure-running no-op
# (agg_env_changed crumb absent + bond-agg up) and verify_speed takes its ep==:59402
# fast-path after ep_speed re-pins. ASSERT ZERO bond-agg restarts across the heal (the
# EIF datapath must NOT bounce). Teeth: FAILS against the leaf-deleted commit (the
# unconditional act_agg_restart bounces bond-agg -> +1 restart); PASSES only with the
# restored crumb-guard on act_agg_restart + the verify_speed fast-path.
setup; bctl on; bctl mode speed; fact ep "203.0.113.9:51820"   # co-writer knocks ep direct
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
hook
R1=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F18 speed drift-heal: endpoint re-pinned :59402" "$(epv)" "127.0.0.1:59402"
asrt "F18 speed drift-heal: node engaged (speed)"      "$(node)" engaged
asrt "F18 speed drift-heal: single feeder (engarde down)" "$(running engarde-client)" 0
asrt "F18 speed drift-heal: ZERO bond-agg restarts (no EIF bounce)" "$R1" "$R0"
asrt "F18 speed drift-heal: no iptables silence-window" "$IPT1" "$IPT0"

# ===========================================================================
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

# NG2 — N=4 (the box's real declared arity): still ALL of them, still ordered.
setup; fact nwan 4; bctl on; bctl mode speed
asrt "NG2 N=4 AGG_PATHS carries ALL 4" "$(aggf AGG_PATHS)" "eth1,usb0,eth0,wwan0"
asrt "NG2 N=4 no source discarded"     "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "NG2 N=4 AGG_W arity == N"        "$(ncsv "$(aggf AGG_W)")" 4
asrt "NG2 N=4 speed engaged (no privileged N)" "$(running bond-agg)" 1
asrt "NG2 N=4 single feeder"           "$(running engarde-client)" 0

# NG3 — N=2 is not a special case, it is just the smallest N that aggregates.
setup; fact nwan 2; bctl on; bctl mode speed
asrt "NG3 N=2 AGG_PATHS"       "$(aggf AGG_PATHS)" "eth1,usb0"
asrt "NG3 N=2 AGG_W arity == N" "$(ncsv "$(aggf AGG_W)")" 2

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
setup; fact nwan 3; echo "7,8,9" > "$WORK/etc/bond/agg_w"; bctl on; bctl mode speed
asrt "NG6 correctly-sized operator agg_w IS honoured" "$(aggf AGG_W)" "7,8,9"

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

# ===========================================================================
# E4 SHAPING FOLDED INTO THE DAG — U22
# spec: docs/knowledge/design/e4-shaping-in-dag.md · ADR-001 decision 1 SUPERSEDED
#
# These are the spec's own owed Layer-2 asserts (§8.2), run against the REAL
# artifacts: bond-xctl reads the REAL bond.dag, and the shaper is a real init.d
# shim with a real qdisc shim behind it. They are what distinguishes "E4
# shaping present" from "E4 shaping absent" at the artifact layer: on the
# pre-change tree bond-xctl's run_action has no `shape_apply` case and hits its
# `*) fail "unknown action"` arm, so every one of these fails loudly.
# ===========================================================================

# SH-0 — shaping converges on the FIRST lifecycle edge, and `direct` is honest.
# Mo's gap: `direct` is DEFINED as bond-off PLUS cake/autorate, and until this
# fold the `off` node expressed no shaping expectation at all.
setup; bctl on
asrt "SH-0 engage converges shaping ON the discovered iface" "$(shapev)" wgclient1
asrt "SH-0 cake is attached on the tunnel iface"             "$(qdiscv)" "cake mtu 1420"
asrt "SH-0 the shaping controller is running"                "$(running cake-autorate)" 1
setup; bctl on; bctl off
asrt "SH-0 direct is HONEST: bond-off still carries shaping" "$(shapev)" wgclient1
asrt "SH-0 direct: node off"                                 "$(node)" off

# SH-1 — IDEMPOTENCY. reconcile twice with shaping already correct => ZERO
# effects: no shaper restart, no qdisc re-attach, and no feeder bounce. Measured
# on the shim's restart counter and the tc ledger, not on a return code.
setup; bctl on
R0=$(cat "$WORK/restarts.cake-autorate" 2>/dev/null || echo 0)
T0=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T0=${T0:-0}
E0=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
hook; hook
R1=$(cat "$WORK/restarts.cake-autorate" 2>/dev/null || echo 0)
T1=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T1=${T1:-0}
E1=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
asrt "SH-1 idempotency: two reconciles cause ZERO shaper restarts" "$R1" "$R0"
asrt "SH-1 idempotency: two reconciles cause ZERO qdisc operations" "$T1" "$T0"
asrt "SH-1 idempotency: and still ZERO engarde restarts"            "$E1" "$E0"

# SH-2 — SELF-HEAL, from every node including `off`. Tear the qdisc out from
# under a converged box (a firmware event, a GL UI toggle, a manual `tc`); the
# NEXT reconcile restores it, with no new timer, daemon or watchdog.
setup; bctl on; rm -f "$WORK/qdisc.wgclient1"
asrt "SH-2 engaged: torn down, observed off"  "$(shapev)" off
hook
asrt "SH-2 engaged: healed by the next reconcile" "$(shapev)" wgclient1
setup; bctl on; bctl off; rm -f "$WORK/qdisc.wgclient1"; hook
asrt "SH-2 off: healed from the `off` node too" "$(shapev)" wgclient1
setup; bctl on; bctl mode speed; rm -f "$WORK/qdisc.wgclient1"; hook
asrt "SH-2 speed: healed from the speed node too" "$(shapev)" wgclient1
# and the healer is the WATCHDOG tick as well, which is the unattended path
setup; bctl on; echo 0 > "$WORK/running.cake-autorate"; runw
asrt "SH-2 watchdog tick heals a dead shaping controller" "$(running cake-autorate)" 1

# SH-3 — INV8 NON-ESCALATION. THE bar that matters: make shaping fail hard and
# assert the EFFECT -- the edge still completes, engage still reaches `engaged`,
# and NO suspend is walked. Effect, not return code: a shape_apply that was
# simply skipped would pass a return-code check, so the qdisc/controller state
# is asserted DOWN at the same time, proving the action really did run.
setup; fact shape_broken 1; fact tc_broken 1; bctl on
asrt "SH-3 INV8: engage still reaches engaged with the shaper failing" "$(node)" engaged
asrt "SH-3 INV8: endpoint still pinned local"        "$(epv)" "127.0.0.1:59401"
asrt "SH-3 INV8: engarde still up"                   "$(running engarde-client)" 1
asrt "SH-3 INV8: NO suspend crumb was walked"        "$( [ -f "$WORK/run/bond/suspended" ] || [ -f "$WORK/run/bond/suspended-degraded" ] && echo yes || echo no )" no
asrt "SH-3 INV8: shaping is observably DOWN (the action ran and did not escalate)" "$(shapev)" off
# the same on the speed edge, whose onfail is speed_revert
setup; fact shape_broken 1; fact tc_broken 1; bctl on; bctl mode speed
asrt "SH-3 INV8 speed: aggregate still engaged"      "$(running bond-agg)" 1
asrt "SH-3 INV8 speed: endpoint :59402"              "$(epv)" "127.0.0.1:59402"
asrt "SH-3 INV8 speed: no speed_revert (engarde still down)" "$(running engarde-client)" 0
asrt "SH-3 INV8 speed: shaping observably DOWN"      "$(shapev)" off
# and it recovers with no operator action once the shaper is fixed
fact shape_broken 0; fact tc_broken 0; hook
asrt "SH-3 INV8: shaping recovers on the next reconcile once the shaper is fixed" "$(shapev)" wgclient1

# SH-4 — MTU ORDERING, asserted as an EFFECT. The speed edge moves the tunnel
# MTU 1420 -> 1408. The bar reads the MTU the qdisc was ATTACHED AGAINST (the tc
# shim stamps it), so it reads the applied shaping, not the order of names in a
# list -- and it is asserted on an attach that ACTUALLY happens: shaping is torn
# out first, so the edge must re-attach. Move `shape_apply` ahead of mtu_1408 in
# bond.dag and this fails.
setup; bctl on
asrt "SH-4 baseline: shaping attached against MTU 1420" "$(qdiscv)" "cake mtu 1420"
rm -f "$WORK/qdisc.wgclient1"
bctl mode speed
asrt "SH-4 speed edge: the attach happened AFTER the MTU settled (1408, not 1420)"      "$(qdiscv)" "cake mtu 1408"
asrt "SH-4 speed edge: node engaged (speed)" "$(node)" engaged
rm -f "$WORK/qdisc.wgclient1"
bctl mode lightning
asrt "SH-4 off speed: the attach reflects MTU 1420 again" "$(qdiscv)" "cake mtu 1420"

# SH-4b — the ordering guarantee's KNOWN LIMIT, measured and named rather than
# hidden. shape_now() observes qdisc presence + controller liveness; the MTU a
# qdisc was attached against is NOT recoverable from `tc qdisc show`, so an
# already-converged box crossing an MTU change does not re-apply shaping. That
# is sound ONLY WHILE no MTU-derived cake parameter is configured -- and this
# unit configures none (no arbitrary constants; overhead/framing belongs to E4's
# install half). If that installer sets an overhead/mpu, closing this needs an
# applied-record (the `applied_wans`/_conf_matches pattern) or an unconditional
# re-attach on the MTU-moving edges.
setup; bctl on
T0=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T0=${T0:-0}
bctl mode speed
T1=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T1=${T1:-0}
asrt "SH-4b NAMED LIMIT: an already-converged box crossing an MTU change performs ZERO qdisc operations" "$T1" "$T0"
asrt "SH-4b NAMED LIMIT: the qdisc stamp stays 1420"    "$(qdiscv)" "cake mtu 1420"
asrt "SH-4b NAMED LIMIT: while the device MTU really did move to 1408"      "$(cat "$WORK/mtu.wgclient1" 2>/dev/null)" 1408

# SH-5 — the `shape` FACT is honoured, and the writer is the CLI, not the
# executor. `bondctl shape off` writes the fact and reconciles; the qdisc and
# the controller come down, and STAY down across further reconciles (a converged
# `off` is converged -- it must not be re-applied every tick).
setup; bctl on; bctl shape off
asrt "SH-5 shape off: observed off"                  "$(shapev)" off
asrt "SH-5 shape off: qdisc removed"                 "$(qdiscv)" none
asrt "SH-5 shape off: controller stopped"            "$(running cake-autorate)" 0
asrt "SH-5 shape off: tunnel untouched (still engaged)" "$(node)" engaged
T0=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T0=${T0:-0}
hook; hook
T1=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T1=${T1:-0}
asrt "SH-5 shape off is CONVERGED: zero further qdisc operations" "$T1" "$T0"
bctl shape on
asrt "SH-5 shape on again: observed on"              "$(shapev)" wgclient1

# SH-6 — the R3 COST, measured rather than hidden. converged() now carries a
# shaping term, so a box that wants shaping and cannot get it is NEVER converged
# and walks an edge on every watchdog tick. That is real. What must hold is
# CONTAINMENT: the lifecycle leaves are effect-idempotent, so those ticks must
# not bounce a feeder or install an iptables silence-window.
setup; fact shape_broken 1; fact tc_broken 1; bctl on
R0=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw; runw; runw
R1=$(cat "$WORK/restarts.engarde-client" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables ' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "SH-6 shaping unavailable: 3 watchdog ticks cause ZERO engarde restarts" "$R1" "$R0"
asrt "SH-6 shaping unavailable: no iptables silence-window"                   "$IPT1" "$IPT0"
asrt "SH-6 shaping unavailable: box stays engaged"                            "$(node)" engaged

# SH-7 — the tunnel iface is DISCOVERED, not hardcoded. `$BOND_DIR/wg_if` is the
# M8/E6 discovery fact; shaping follows it. No `wgclient1` literal exists in the
# shaping path, so a box whose tunnel is named anything else shapes the right
# device. (E6 is not built; this asserts the consumer half is already generic.)
setup; echo wgc7 > "$WORK/etc/bond/wg_if"; bctl on
asrt "SH-7 shaping follows the DISCOVERED iface, not a literal" "$(shapev)" wgc7
asrt "SH-7 no qdisc was attached to the fallback name" "$(qdiscv)" none
asrt "SH-7 the discovered device carries the qdisc" \
     "$(cat "$WORK/qdisc.wgc7" 2>/dev/null || echo none)" "cake mtu 1420"

# ================= E4 INSTALL HALF — U22a — SH-8 .. SH-15 ==================
# U22 folded shaping into the DAG. Nothing PRODUCED the shaper it controls:
# `bond-xctl SHAPE_SVC=/etc/init.d/cake-autorate` had no producer in the tree
# and E7 removes P1's. THESE BARS GO RED ON A TREE WITHOUT THE INSTALL HALF —
# SH-8/SH-9/SH-10/SH-11/SH-14 cannot even find `deploy/p5/shape-install`, SH-15
# reads bond-xctl's own SHAPE_SVC and asserts a producer + a manifest entry
# exist for exactly that path. Demonstrated failing against the parent tree in
# U22a's result; do not weaken them to go green.

si_world() {   # a hermetic "box" for shape-install. EVERY path is an override,
               # so the harness runs the SHIPPED file, not a copy of it.
    SI="$WORK/si"; rm -rf "$SI" 2>/dev/null
    mkdir -p "$SI/share/vendor" "$SI/initd" "$SI/net/wgclient1" \
             "$SI/mod/sch_cake" "$SI/mod/ifb" "$SI/mod/act_mirred" \
             "$SI/usr/lib/p5" "$SI/etc/init.d" "$SI/etc/config" "$SI/payload"
    cp "$P5/shape/cake-autorate.pin" "$SI/share/cake-autorate.pin"
    cp "$P5/init.d/cake-autorate"    "$SI/initd/cake-autorate"
    printf 'GL-MT6000\n' > "$SI/model"
    : > "$SI/rc.common"
    : > "$SI/proc_modules"
}
shapeinst() {
    BOND_DIR="$WORK/etc/bond" WG_DEV=wgclient1 \
    P5_SHARE="$SI/share" P5_INITD="$SI/initd" \
    SHAPE_BASE="$SI/usr/lib/p5/cake-autorate" SHAPE_SVC="$SI/etc/init.d/cake-autorate" \
    SQM_CONF="$SI/etc/config/sqm" SYSINFO_MODEL="$SI/model" GLVERSION="$SI/glversion" \
    SYS_MODULE="$SI/mod" PROC_MODULES="$SI/proc_modules" MODDIR="$SI/moddir" \
    SYS_CLASS_NET="$SI/net" RC_COMMON="$SI/rc.common" PROCD_BIN="$SI/procd" \
    sh "$P5/shape-install" "$@" 2>&1
}
sirc() { shapeinst "$@" >/dev/null 2>&1; echo $?; }
# si_supply [marker] — hand the installer the inputs G2 and U24 still owe it, so
# the mechanism is demonstrated WORKING and not only refusing. The vendored
# files are SYNTHETIC: G2 answered the hashes, not the bytes, and inventing
# bytes to match Mo's real hashes is impossible and would be a lie if it were
# not. EVERY HASH HERE IS COMPUTED FROM THE ARTIFACT, never typed. The numbers
# in shape_bounds/shape_reflectors are harness fixtures for the CONSUMER path;
# they are not defaults and the shipped tree contains neither file.
# The harness pin mirrors the SHIPPED pin's SHAPE: five pinned files of which
# THREE are staged, so the pinned-but-not-shipped distinction is exercised and
# not merely written down. `setup.sh` here stands in for the real one (upstream's
# wget-from-master installer) and `uninstall.sh` for the remover that would
# delete P1's live /root/cake-autorate.
SI_PIN='cake-autorate.sh lib.sh defaults.sh setup.sh uninstall.sh'
SI_STG='cake-autorate.sh lib.sh defaults.sh'
si_supply() {
    _mk="${1:-a}"
    for _f in $SI_PIN; do
        printf '#!/usr/bin/env bash\n# %s %s\nexit 0\n' "$_f" "$_mk" > "$SI/share/vendor/$_f"
    done
    {
        echo "CAR_UPSTREAM=https://example.invalid/harness"
        echo "CAR_ORIGIN=NO-GIT"
        echo "BEGIN_FILES"
        for _f in $SI_PIN; do
            printf '%s  %s\n' "$(sha256sum "$SI/share/vendor/$_f" | awk '{print $1}')" "$_f"
        done
        echo "END_FILES"
        echo "BEGIN_STAGE"
        for _f in $SI_STG; do printf '%s\n' "$_f"; done
        echo "END_STAGE"
    } > "$SI/share/cake-autorate.pin"
    printf '5000 20000 100000 5000 20000 50000\n' > "$WORK/etc/bond/shape_bounds"
    printf '198.51.100.7\n198.51.100.8\n'         > "$WORK/etc/bond/shape_reflectors"
}

# SH-8 — G2 IS THE GATE, AND IT REFUSES RATHER THAN PROCEEDING UNVERIFIED.
# G2 answered on 2026-08-30 with CAR_ORIGIN=NO-GIT and a per-file sha256 set, so
# the shipped pin now HAS hashes. It does NOT have the BYTES: shape/vendor/ is
# empty and hashes are not code. The refusal must therefore be PRECISE about
# which half is missing, and must still change nothing at all.
setup; si_world
SH8=$(shapeinst preflight)
asrt "SH-8 shipped pin records NO-GIT (no commit exists on the box to pin to)" \
     "$(grep -c '^CAR_ORIGIN=NO-GIT$' "$P5/shape/cake-autorate.pin")" 1
asrt "SH-8 shipped pin carries a FILES block with per-file sha256" \
     "$( [ "$(sed -n '/^BEGIN_FILES$/,/^END_FILES$/p' "$P5/shape/cake-autorate.pin" | grep -Ec '^[0-9a-f]{64}  ')" -ge 1 ] && echo yes || echo no )" yes
asrt "SH-8 config.wg.sh (Mo's operational config) is deliberately NOT pinned" \
     "$(sed -n '/^BEGIN_FILES$/,/^END_FILES$/p' "$P5/shape/cake-autorate.pin" | grep -c 'config\.wg\.sh$')" 0
# PINNED IS NOT SHIPPED, asserted on the SHIPPED pin, not only on the harness one.
_stg=$(sed -n '/^BEGIN_STAGE$/,/^END_STAGE$/p' "$P5/shape/cake-autorate.pin" | grep -Ev '^(BEGIN|END)_STAGE$|^#|^$')
asrt "SH-8 the shipped pin declares a STAGE block (which files land on the box)" \
     "$( [ -n "$_stg" ] && echo yes || echo no )" yes
asrt "SH-8 setup.sh (upstream's wget-from-master installer) is pinned but NEVER staged" \
     "$(echo "$_stg" | grep -cx 'setup\.sh')" 0
asrt "SH-8 uninstall.sh (it deletes P1's LIVE /root/cake-autorate) is pinned but NEVER staged" \
     "$(echo "$_stg" | grep -cx 'uninstall\.sh')" 0
asrt "SH-8 every STAGED name is also PINNED (no unverified file can be staged)" \
     "$(for _n in $_stg; do sed -n '/^BEGIN_FILES$/,/^END_FILES$/p' "$P5/shape/cake-autorate.pin" | grep -q "  $_n\$" || echo BAD; done | wc -l | tr -d ' ')" 0
asrt "SH-8 shape/vendor/ ships EMPTY (the bytes are the remaining G2 half)" \
     "$(find "$P5/shape/vendor" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')" 0
asrt "SH-8 preflight REFUSES with the bytes absent"  "$(sirc preflight)" 3
asrt "SH-8 the refusal NAMES G2"                     "$( [ "$(echo "$SH8" | grep -c 'G2')" -ge 1 ] && echo named || echo silent )" named
asrt "SH-8 the refusal says the VENDORED BYTES are what is missing" \
     "$(echo "$SH8" | grep -c 'vendored bytes')" 1
asrt "SH-8 install refuses too, exit 3"              "$(sirc install)" 3
asrt "SH-8 and it installed NOTHING (no controller placed)" \
     "$( [ -e "$SI/etc/init.d/cake-autorate" ] && echo yes || echo no )" no
asrt "SH-8 and it staged NOTHING"                    "$( [ -e "$SI/usr/lib/p5/cake-autorate" ] && echo yes || echo no )" no

# SH-9 — the mechanism WORKS once the declared inputs exist (positive control:
# a bar that can only ever refuse proves nothing). Synthetic payload, sha
# computed from the artifact.
setup; si_world; si_supply
asrt "SH-9 preflight READY once the pin + facts are supplied" "$(sirc preflight)" 0
asrt "SH-9 install succeeds"                                  "$(sirc install)" 0
asrt "SH-9 the CONTROLLER bond-xctl drives now exists"        "$( [ -x "$SI/etc/init.d/cake-autorate" ] && echo yes || echo no )" yes
_V1=$(cat "$SI/usr/lib/p5/cake-autorate/current")
asrt "SH-9 install-new-then-switch: current -> a CONTENT-ADDRESSED version id" \
     "$(echo "$_V1" | grep -Ec '^v-[0-9a-f]{12}$')" 1
asrt "SH-9 the payload is under the version dir, not over the live one" \
     "$( [ -f "$SI/usr/lib/p5/cake-autorate/$_V1/cake-autorate.sh" ] && echo yes || echo no )" yes
# PINNED IS NOT SHIPPED. All five are verified; only the STAGE subset lands.
asrt "SH-9 exactly the STAGED subset landed, not every pinned file"  \
     "$(find "$SI/usr/lib/p5/cake-autorate/$_V1" -type f | wc -l | tr -d ' ')" 3
asrt "SH-9 upstream's wget-from-master setup.sh is VERIFIED but NOT placed" \
     "$( [ -e "$SI/usr/lib/p5/cake-autorate/$_V1/setup.sh" ] && echo placed || echo absent )" absent
asrt "SH-9 upstream's uninstall.sh (it removes P1's LIVE /root/cake-autorate) is NOT placed" \
     "$( [ -e "$SI/usr/lib/p5/cake-autorate/$_V1/uninstall.sh" ] && echo placed || echo absent )" absent
asrt "SH-9 config generated with the DISCOVERED iface, not a literal" \
     "$(grep -c '^ul_if=wgclient1$' "$SI/usr/lib/p5/cake-autorate/config.p5.sh")" 1
asrt "SH-9 dl_if is the ifb mirror of the discovered iface" \
     "$(grep -c '^dl_if=ifb4wgclient1$' "$SI/usr/lib/p5/cake-autorate/config.p5.sh")" 1
asrt "SH-9 rates come from the FACT, none are written by the installer" \
     "$(grep -c '^base_ul_shaper_rate_kbps=20000$' "$SI/usr/lib/p5/cake-autorate/config.p5.sh")" 1
asrt "SH-9 no tuning constant is written (upstream defaults, named not guessed)" \
     "$(grep -Ec '^(no_pingers|high_load_thr|bufferbloat_refractory_period_ms|shaper_rate_max_adjust_up_load_high)=' "$SI/usr/lib/p5/cake-autorate/config.p5.sh")" 0
# PLACEMENT IS NOT ACTIVATION: the installer must not enable or start anything.
# The DAG owns activation, and that single ownership point is the whole design.
asrt "SH-9 the installer ENABLED nothing"  "$( [ -e "$SI/etc/rc.d" ] && echo yes || echo no )" no
asrt "SH-9 the installer contains no start/enable of the controller" \
     "$(sed 's/#.*//' "$P5/shape-install" | grep -Ec 'SHAPE_SVC\" *(enable|start|restart)|\$SHAPE_SVC (enable|start|restart)')" 0
# IDEMPOTENCY + interruption-retry: running it again converges, never duplicates.
_p1=$(cat "$SI/usr/lib/p5/cake-autorate/current")
asrt "SH-9 second install is a no-op-or-forward (idempotent)" "$(sirc install)" 0
asrt "SH-9 and current still names the same version"          "$(cat "$SI/usr/lib/p5/cake-autorate/current")" "$_p1"
asrt "SH-9 no stage dir survived"  "$(find "$SI/usr/lib/p5/cake-autorate" -name '.stage.*' 2>/dev/null | wc -l | tr -d ' ')" 0

# SH-9b — THE UPGRADE PATH, which is the one an idempotency bar cannot see.
# Found by review, not by a passing test. The switch was `ln -s new tmp; mv tmp
# current`, and `mv` FOLLOWS a destination symlink that points at a directory:
# on a SECOND, DIFFERENT version it deposited the new link INSIDE the old
# version dir and left `current` on the OLD payload while reporting success.
# Everything above still passes under that bug, because SH-9 re-installs the
# SAME version and SH-10's content-addressing check starts from a fresh world
# each time. `current` is now a POINTER FILE, so the switch is a rename(2) over
# a regular file -- atomic, and with no symlink to dereference. This bar
# installs set `a` and then set `b` over the top, which is the only shape that
# can see the difference.
_CAR="$SI/usr/lib/p5/cake-autorate"
setup; si_world; si_supply a
shapeinst install >/dev/null 2>&1
_UA=$(cat "$_CAR/current")
si_supply b                       # same world, DIFFERENT pinned bytes
asrt "SH-9b upgrade over a live install succeeds"  "$(sirc install)" 0
_UB=$(cat "$_CAR/current")
asrt "SH-9b current actually MOVED to the new version (not left on the old one)" \
     "$( [ -n "$_UB" ] && [ "$_UA" != "$_UB" ] && echo moved || echo "stuck:$_UA" )" moved
asrt "SH-9b the live payload is the NEW bytes" \
     "$(grep -c '# cake-autorate.sh b$' "$_CAR/$_UB/cake-autorate.sh")" 1
asrt "SH-9b nothing was deposited INSIDE the old version dir (the mv-follows-symlink trap)" \
     "$(find "$_CAR/$_UA" -maxdepth 1 \( -name 'current*' -o -name '.current.*' \) 2>/dev/null | wc -l | tr -d ' ')" 0
asrt "SH-9b the old version is still on disk (rollback stays possible)" \
     "$( [ -d "$_CAR/$_UA" ] && echo kept || echo gone )" kept
asrt "SH-9b 'current' is a PLAIN FILE, so its swap is rename(2) and not a link dance" \
     "$( [ -f "$_CAR/current" ] && [ ! -L "$_CAR/current" ] && echo file || echo other )" file
# and it refuses rather than clobbering something it did not create
setup; si_world; si_supply
mkdir -p "$SI/usr/lib/p5/cake-autorate/current"
_out9=$(shapeinst install)
asrt "SH-9b a 'current' that is not a plain pointer file is REFUSED, never replaced" \
     "$(echo "$_out9" | grep -c 'not a plain pointer file')" 1

# SH-10 — the PIN IS ENFORCED. A payload that is not the pinned one is refused,
# and nothing is placed. This is the bar that makes "vendor + pin" real rather
# than decorative.
setup; si_world; si_supply
printf 'tampered\n' >> "$SI/share/vendor/lib.sh"
SH10=$(shapeinst install)
asrt "SH-10 a vendored file that does not match the pin is REFUSED" "$(sirc install)" 3
asrt "SH-10 the refusal names the mismatching FILE"  "$(echo "$SH10" | grep -c 'HASH MISMATCH: lib.sh')" 1
asrt "SH-10 nothing was placed on a mismatch"  "$( [ -e "$SI/etc/init.d/cake-autorate" ] && echo yes || echo no )" no
# a pinned-but-absent file is a refusal too, not a silent skip
setup; si_world; si_supply; rm -f "$SI/share/vendor/lib.sh"
SH10b=$(shapeinst install)
asrt "SH-10 a pinned file that is not vendored REFUSES (never installs partial)" "$(sirc install)" 3
asrt "SH-10 and it names the missing file"  "$(echo "$SH10b" | grep -c 'pinned but NOT VENDORED: lib.sh')" 1
# UNPINNED code must not reach the box either -- the direction a pure "every
# pinned file matches" check misses entirely.
setup; si_world; si_supply; printf 'x\n' > "$SI/share/vendor/smuggled.sh"
SH10c=$(shapeinst install)
asrt "SH-10 an UNPINNED file in vendor/ REFUSES the install" "$(sirc install)" 3
asrt "SH-10 and it names it"  "$(echo "$SH10c" | grep -c 'VENDORED BUT NOT PINNED: smuggled.sh')" 1
# a STAGE block that names a file the pin does not cover would put UNVERIFIED
# code on the box -- the one direction "every pinned file matches" cannot see.
setup; si_world; si_supply
sed -i 's/^BEGIN_STAGE$/BEGIN_STAGE\nsmuggled.sh/' "$SI/share/cake-autorate.pin"
SH10d=$(shapeinst install)
asrt "SH-10 a STAGED name that is not PINNED REFUSES the install" "$(sirc install)" 3
asrt "SH-10 and it names it"  "$(echo "$SH10d" | grep -c 'STAGED BUT NOT PINNED: smuggled.sh')" 1
# and an ABSENT stage block fails CLOSED -- it must never mean "ship everything"
setup; si_world; si_supply
sed -i '/^BEGIN_STAGE$/,/^END_STAGE$/d' "$SI/share/cake-autorate.pin"
SH10e=$(shapeinst install)
asrt "SH-10 a pin with NO STAGE block REFUSES (never defaults to shipping all of it)" "$(sirc install)" 3
asrt "SH-10 and it says so"  "$(echo "$SH10e" | grep -c 'NO STAGE block')" 1
# CONTENT-ADDRESSING: a different pinned set must produce a different version id
setup; si_world; si_supply a; shapeinst install >/dev/null 2>&1
_VA=$(cat "$SI/usr/lib/p5/cake-autorate/current")
setup; si_world; si_supply b; shapeinst install >/dev/null 2>&1
_VB=$(cat "$SI/usr/lib/p5/cake-autorate/current")
asrt "SH-10 the version id is DERIVED from the pinned set (different set => different id)" \
     "$( [ "$_VA" != "$_VB" ] && echo differs || echo same )" differs

# SH-10b — P5 MUST NOT CLOBBER P1's CONTROLLER. `/etc/init.d/cake-autorate` is a
# name P1 ALREADY USES on the client: its own cake-autorate service, running
# production traffic, `S97cake-autorate` in rc.d (inventory
# 2026-08-30-client-flint2.txt:125,214-218). Without an ownership check, install
# overwrites that file and remove deletes it -- and P1-P3 are not this unit's to
# touch. Removing the old stack is E7's, ordered.
setup; si_world; si_supply
printf '#!/bin/sh /etc/rc.common\n# P1 cake-autorate service\nSTART=97\n' > "$SI/etc/init.d/cake-autorate"
chmod +x "$SI/etc/init.d/cake-autorate"
_sum0=$(sha256sum "$SI/etc/init.d/cake-autorate" | awk '{print $1}')
SH10f=$(shapeinst install)
asrt "SH-10b a FOREIGN controller at SHAPE_SVC refuses the install (exit 6)" "$(sirc install)" 6
asrt "SH-10b the refusal names the reason"     "$(echo "$SH10f" | grep -c 'SVC  FOREIGN')" 1
asrt "SH-10b and says whose it is and who removes it"      "$( [ "$(echo "$SH10f" | grep -c "P5 did not write")" -ge 1 ] && [ "$(echo "$SH10f" | grep -c "E7")" -ge 1 ] && echo named || echo vague )" named
asrt "SH-10b and P1's file is BYTE-IDENTICAL afterwards" \
     "$(sha256sum "$SI/etc/init.d/cake-autorate" | awk '{print $1}')" "$_sum0"
asrt "SH-10b remove LEAVES a foreign controller alone" \
     "$(sirc remove)$( [ -f "$SI/etc/init.d/cake-autorate" ] && echo kept || echo DELETED )" "0kept"
asrt "SH-10b and it says why"  "$(shapeinst remove | grep -c 'no P5 ownership marker')" 1
# the marker is a property of the SHIPPED init script, not of the harness
asrt "SH-10b the shipped init script carries the ownership marker" \
     "$(grep -c 'P5-OWNED-INIT: deploy/p5/init.d/cake-autorate' "$P5/init.d/cake-autorate")" 1
asrt "SH-10b and shape-install checks for exactly that string" \
     "$(grep -c 'P5_MARK="P5-OWNED-INIT: deploy/p5/init.d/cake-autorate"' "$P5/shape-install")" 1
# P5's OWN controller is replaceable and removable -- the guard is about
# foreign files, never about refusing to manage our own.
setup; si_world; si_supply; shapeinst install >/dev/null 2>&1
asrt "SH-10b re-install over P5's OWN marked controller is fine"  "$(sirc install)" 0
asrt "SH-10b and remove takes P5's own controller away" \
     "$(sirc remove)$( [ -e "$SI/etc/init.d/cake-autorate" ] && echo kept || echo gone )" "0gone"

# SH-11 — NON-INTERFERENCE WITH GL NATIVE SQM, both halves.
# (a) install-time: an enabled sqm queue on the TUNNEL iface is a conflict.
# FIXTURE IS THE REAL ONE, not an invented shape: the client inventory
# (docs/knowledge/inventory/2026-08-30-client-flint2.txt:205-211, on dev) shows
# `sqm.eth1` with `interface='wgclient1'` and `enabled='1'` -- the SECTION IS
# NAMED eth1 WHILE ITS INTERFACE IS THE TUNNEL. A name-based check would miss it
# entirely, which is exactly why the predicate reads `option interface`.
setup; si_world; si_supply
printf "config queue 'eth1'
	option enabled '1'
	option interface 'wgclient1'
	option qdisc 'cake'
" > "$SI/etc/config/sqm"
SH11=$(shapeinst preflight)
asrt "SH-11a native SQM on the tunnel iface => preflight REFUSES" "$(sirc preflight)" 5
asrt "SH-11a the refusal names the conflict"  "$(echo "$SH11" | grep -c 'CONFLICT')" 1
asrt "SH-11a install refuses and places nothing" "$(sirc install)$( [ -e "$SI/etc/init.d/cake-autorate" ] && echo yes || echo no )" "5no"
# (b) an enabled queue on ANOTHER iface is REPORTED, not a refusal
setup; si_world; si_supply
printf "config queue 'lan'\n\toption enabled '1'\n\toption interface 'br-lan'\n" > "$SI/etc/config/sqm"
asrt "SH-11b native SQM elsewhere is not a conflict" "$(sirc preflight)" 0
asrt "SH-11b but it is REPORTED"  "$(shapeinst preflight | grep -c "SQM  note")" 1
# (c) a DISABLED queue on the tunnel iface is not a conflict
setup; si_world; si_supply
printf "config queue 'eth1'
	option enabled '0'
	option interface 'wgclient1'
" > "$SI/etc/config/sqm"
asrt "SH-11c a DISABLED native queue is not a conflict" "$(sirc preflight)" 0
# (d) RUNTIME converge-guard: the operator turns GL SQM on AFTER install. The
# DAG must NOT attach (two owners on one device) and must NOT escalate (INV8).
setup
mkdir -p "$WORK/etc/config"
printf "config queue 'eth1'
	option enabled '1'
	option interface 'wgclient1'
" > "$WORK/etc/config/sqm"
SQM_CONF="$WORK/etc/config/sqm"; export SQM_CONF
bctl on
asrt "SH-11d converge-guard: NO qdisc attached while native SQM owns the iface" "$(qdiscv)" none
asrt "SH-11d and shaping reads observably OFF"        "$(shapev)" off
asrt "SH-11d but the TUNNEL still engaged (INV8)"     "$(node)" engaged
asrt "SH-11d endpoint still pinned local"             "$(epv)" "127.0.0.1:59401"
asrt "SH-11d NO suspend crumb was walked" \
     "$( [ -f "$WORK/run/bond/suspended" ] || [ -f "$WORK/run/bond/suspended-degraded" ] && echo yes || echo no )" no
# and it self-heals the moment the operator turns native SQM back off
printf "config queue 'eth1'
	option enabled '0'
	option interface 'wgclient1'
" > "$WORK/etc/config/sqm"
hook
asrt "SH-11d self-heals once native SQM is disabled" "$(shapev)" wgclient1
unset SQM_CONF

# SH-12 / SH-13 — STATIC LINTS ON THE SHIPPED INSTALL PATH. A lint nothing has
# ever failed is not evidence, so each one carries controls that MUST fail it:
#   * a SYNTHETIC control, written here, exercising the exact constructs the
#     pattern claims to catch. It runs in EVERY tree, so instrument sensitivity
#     is never unproven.
#   * the REAL control, p1-autorate/bootstrap-autorate.sh — which genuinely does
#     curl-from-master and genuinely does rewrite other people's uci. It is read,
#     never edited: it is shaping production traffic right now.
# The real control is not runnable everywhere: `p1-autorate/` is deliberately
# absent from the PUBLIC CI MIRROR's allowlist (scripts/sync-public-ci.sh ALLOW
# carries only what CI builds; the deployed stack is not published). Its absence
# is printed as a NOTE, never counted as a PASS -- a skip that scores is exactly
# the vacuous-green this file exists to prevent.
# lint_hits FAILS CLOSED on a missing file. `sed` on an absent path yields no
# lines, `grep -c` then says 0, and "0 hits" is indistinguishable from "clean" --
# so a lint on a file that does not exist would PASS. That is how the SH-12/13
# negative controls silently inverted on the mirror, and it is how these bars
# would go green on a tree with no install half. NOFILE is not 0.
code() { sed 's/#.*//' "$1"; }
lint_hits() { [ -f "$1" ] || { echo NOFILE; return; }; code "$1" | grep -Eic "$2" | tr -d ' '; }
FETCH='(^|[^a-z_])(wget|curl|opkg)([^a-z_]|$)|git +clone'
MGMT='uci +(set|commit|delete|add)|/etc/config/(network|firewall)|/etc/init\.d/(firewall|network|dropbear)|dropbear|(^|[^a-z_])reboot([^a-z_]|$)'
# the synthetic control: the constructs, verbatim in shape, that P1 really uses
_CTL="$WORK/lint-control.sh"
cat > "$_CTL" <<'CTLEOF'
#!/bin/sh
opkg update && opkg install sqm-scripts
wget -O /tmp/setup.sh https://example.invalid/master/setup.sh
uci set sqm.wgclient1=queue
uci commit sqm
/etc/init.d/firewall reload
reboot
CTLEOF
asrt "SH-13 shape-install FETCHES NOTHING (no wget/curl/opkg/git clone)" "$(lint_hits "$P5/shape-install" "$FETCH")" 0
asrt "SH-13 the shipped init script fetches nothing"                     "$(lint_hits "$P5/init.d/cake-autorate" "$FETCH")" 0
asrt "SH-13 CONTROL: the lint FIRES on a fetching script (the instrument is sensitive)" \
     "$( [ "$(lint_hits "$_CTL" "$FETCH")" -gt 0 ] && echo fires || echo BLIND )" fires
asrt "SH-12 shape-install touches NO management path"  "$(lint_hits "$P5/shape-install" "$MGMT")" 0
asrt "SH-12 the shipped init script touches no management path" "$(lint_hits "$P5/init.d/cake-autorate" "$MGMT")" 0
asrt "SH-12 CONTROL: the lint FIRES on a uci/firewall/reboot script" \
     "$( [ "$(lint_hits "$_CTL" "$MGMT")" -gt 0 ] && echo fires || echo BLIND )" fires
# the REAL control, where the tree carries it
_P1B="$REPO/p1-autorate/bootstrap-autorate.sh"
if [ -f "$_P1B" ]; then
    asrt "SH-13 REAL NEGATIVE CONTROL: P1's curl-from-master bootstrap FAILS this lint" \
         "$( [ "$(lint_hits "$_P1B" "$FETCH")" -gt 0 ] && echo fails || echo passes )" fails
    asrt "SH-12 REAL NEGATIVE CONTROL: P1's bootstrap FAILS this lint (uci set/commit)" \
         "$( [ "$(lint_hits "$_P1B" "$MGMT")" -gt 0 ] && echo fails || echo passes )" fails
else
    echo "NOTE  SH-12/SH-13 real negative control NOT RUN: p1-autorate/ is not in this tree"
    echo "NOTE  (the public CI mirror publishes only what CI builds). Run the full repo for it."
    echo "NOTE  Instrument sensitivity is still asserted above, by the synthetic controls."
fi
asrt "SH-12 no wgclient1 literal in the install path (discovery, not a hardcode)" \
     "$(code "$P5/shape-install" | grep -c 'wgclient1')" 0
asrt "SH-12 no wgclient1 literal in the shipped init script" \
     "$(code "$P5/init.d/cake-autorate" | grep -c 'wgclient1')" 0
asrt "SH-12 no single-SKU model match in the install path (GL-MT6000/GL-MT2500)" \
     "$(code "$P5/shape-install" | grep -Ec 'GL-MT(6000|2500)')" 0

# SH-14 — REMOVAL IS NAMESPACE-GUARDED. E0's B1 lost an SSH key by turning a
# contract row straight into an unlink. `remove` refuses any base outside
# /usr/lib/p5/, which is the only directory P5 exclusively owns.
setup; si_world; si_supply; shapeinst install >/dev/null 2>&1
asrt "SH-14 remove is idempotent and succeeds"  "$(sirc remove)" 0
asrt "SH-14 the payload is gone"  "$( [ -e "$SI/usr/lib/p5/cake-autorate" ] && echo yes || echo no )" no
asrt "SH-14 remove again is still 0 (idempotent)" "$(sirc remove)" 0
_evil="$WORK/etc"
_out=$(BOND_DIR="$WORK/etc/bond" P5_SHARE="$SI/share" P5_INITD="$SI/initd" \
       SHAPE_BASE="$_evil" SHAPE_SVC="$SI/etc/init.d/cake-autorate" \
       sh "$P5/shape-install" remove 2>&1; echo "rc=$?")
asrt "SH-14 remove REFUSES a base outside P5's namespace" "$(echo "$_out" | grep -c 'refusing to remove')" 1
asrt "SH-14 and that directory still exists"  "$( [ -d "$_evil" ] && echo yes || echo no )" yes
# The namespace guard matches the `/usr/lib/p5/` SEGMENT so that the harness can
# drive the REAL remove path under a test root. That is only safe while the
# SHIPPED default base is the absolute one -- assert it, or the relaxation
# becomes a way to ship a base outside the namespace.
asrt "SH-14 the SHIPPED default SHAPE_BASE is inside P5's absolute namespace" \
     "$(grep -c '^SHAPE_BASE="\${SHAPE_BASE:-/usr/lib/p5/' "$P5/shape-install")" 1
asrt "SH-14 a traversal base is refused even inside the namespace" \
     "$(BOND_DIR="$WORK/etc/bond" P5_SHARE="$SI/share" P5_INITD="$SI/initd" \
        SHAPE_BASE="/usr/lib/p5/../../../etc" SHAPE_SVC="$SI/etc/init.d/cake-autorate" \
        sh "$P5/shape-install" remove 2>&1 | grep -c 'refusing to remove')" 1

# SH-15 — THE BAR THAT GOES RED ON A TREE WITH NO INSTALL HALF, and the one
# that would have caught U18's un-manifested-shipped-file defect. It reads
# bond-xctl's OWN SHAPE_SVC and asserts (a) a producer for exactly that path is
# in the shipped set, and (b) every new shipped artifact is in the manifest job.
SVC_PATH=$(grep -m1 '^SHAPE_SVC=' "$P5/bond-xctl" | sed -e 's/^SHAPE_SVC="\${SHAPE_SVC:-//' -e 's/}"$//')
SVC_BASE=$(basename "$SVC_PATH")
asrt "SH-15 bond-xctl's SHAPE_SVC resolves to a name"      "$( [ -n "$SVC_BASE" ] && echo yes || echo no )" yes
asrt "SH-15 an INSTALL HALF exists and is executable"      "$( [ -x "$P5/shape-install" ] && echo yes || echo no )" yes
asrt "SH-15 it ships an init script named exactly SHAPE_SVC's basename" \
     "$( [ -f "$P5/init.d/$SVC_BASE" ] && echo yes || echo no )" yes
asrt "SH-15 it ships the vendor PIN record"                "$( [ -f "$P5/shape/cake-autorate.pin" ] && echo yes || echo no )" yes
asrt "SH-15 the installer places exactly that path"        "$(grep -c 'mv "\$_it" "\$SHAPE_SVC"' "$P5/shape-install")" 1
WF="$REPO/.github/workflows/emulator-gate.yml"
# Both manifest steps must carry each new artifact: the completeness ABORT list
# and the sha256sum line. Counting >=2 rather than ==2 so prose in the job
# cannot make the bar flap; the two lists are what it is measuring.
for _a in shape-install "init.d/$SVC_BASE" "shape/cake-autorate.pin"; do
    asrt "SH-15 manifest job pins the shipped artifact '$_a' (U18: an un-manifested shipped file is a deploy defect)" \
         "$( [ "$(grep -c -- "$_a" "$WF")" -ge 2 ] && echo pinned || echo UNPINNED )" pinned
done

echo "===== Layer-2: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
