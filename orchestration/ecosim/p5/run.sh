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
grep -q '^agg|.*,enough_sources|' "$P5/bond.dag" \
  && ok "NG4 bond.dag agg guard is spelled enough_sources (not two_wans)" \
  || no "NG4 bond.dag agg guard still spelled two_wans"

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
# AGG — `mode max`, ONE `agg` intent, AGG_SCHED=max|speed (U17)
#
# ADR-003 splits the aggregate mode: `max` stripes every usable source,
# `speed` delivers the offered load over the fewest/fastest sources. The
# DATAPATH difference is real. The ORCHESTRATION difference is exactly ONE
# emitted fact -- AGG_SCHED in agg_env -- so bond.dag carries ONE `agg` intent
# and ONE `engaged_agg` target, and the mode -> scheduler map has ONE owner
# (bond-xctl `agg_sched_of`, queried by bondctl and bond-ecod as `_sched`).
#
# BEFORE THIS UNIT NOTHING HERE COULD TELL `mode max` WORKING FROM `mode max`
# BROKEN: `max` did not exist. The cheapest implementations -- a second dag row,
# a second `[ "$M" = max ]` arm in bondctl, or emitting no AGG_SCHED at all --
# would have kept every other bar in this file green. Each of the bars below
# fails on the pre-U17 artifacts; AGG-L4 is the sharpest, because a missing
# AGG_SCHED makes a max<->speed flip a SILENT no-op (converged() sees an
# unchanged agg_env, walks no edge, and the datapath keeps the old scheduler
# forever with the mode file claiming otherwise).
aggnosched() { aggenv | grep -v '^AGG_SCHED='; }   # agg_env minus the selector

# AGG-L1 — `mode max` engages the aggregate, identically to `speed`, and emits
# its OWN scheduler.
setup; bctl on; bctl mode max
asrt "AGG-L1 max: mode fact"        "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L1 max: agg feeder up"    "$(running bond-agg)" 1
asrt "AGG-L1 max: engarde down (single feeder)" "$(running engarde-client)" 0
asrt "AGG-L1 max: node engaged"     "$(node)" engaged
asrt "AGG-L1 max: endpoint :59402"  "$(epv)" "127.0.0.1:59402"
asrt "AGG-L1 max: AGG_SCHED=max"    "$(aggf AGG_SCHED)" max
MAXENV=$(aggnosched)

# AGG-L2 — `speed` takes the SAME lifecycle and emits the OTHER scheduler. The
# two agg_env files must differ in the AGG_SCHED line and NOWHERE else: any
# other difference means a mode grew its own config path.
setup; bctl on; bctl mode speed
asrt "AGG-L2 speed: agg feeder up"  "$(running bond-agg)" 1
asrt "AGG-L2 speed: endpoint :59402" "$(epv)" "127.0.0.1:59402"
asrt "AGG-L2 speed: AGG_SCHED=speed" "$(aggf AGG_SCHED)" speed
asrt "AGG-L2 max and speed agg_env differ ONLY in AGG_SCHED" "$(aggnosched)" "$MAXENV"

# AGG-L3 — ONE intent in the SHIPPED table. A per-mode implementation shows up
# here as an extra row; this is the structural bar the model's AGG-0 mirrors.
NAGG=$(grep -c '^agg|' "$P5/bond.dag")
NPER=$(grep -c '^\(max\|speed\)|' "$P5/bond.dag")
asrt "AGG-L3 bond.dag has exactly ONE aggregate intent row"        "$NAGG" 1
asrt "AGG-L3 bond.dag has ZERO per-mode rows (no max|, no speed|)" "$NPER" 0
grep -q '^agg_revert|' "$P5/bond.dag" \
  && ok "AGG-L3 the aggregate onfail row is agg_revert (mode-blind)" \
  || no "AGG-L3 no agg_revert row in bond.dag"

# AGG-L4 (THE DISCRIMINATOR) — a max<->speed flip is an agg_env BYTE CHANGE, so
# it drops the `agg_env_changed` crumb and bounces the datapath EXACTLY once.
# Without AGG_SCHED the two builds are byte-identical, converged() short-circuits,
# and the flip is a silent no-op: mode file says speed, datapath still runs max.
setup; bctl on; bctl mode max
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
bctl mode speed
R1=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
asrt "AGG-L4 max->speed flip: AGG_SCHED now speed"      "$(aggf AGG_SCHED)" speed
asrt "AGG-L4 max->speed flip: EXACTLY ONE bond-agg restart" "$R1" "$((R0+1))"
asrt "AGG-L4 max->speed flip: still aggregating"        "$(running bond-agg)" 1
asrt "AGG-L4 max->speed flip: still single feeder"      "$(running engarde-client)" 0
asrt "AGG-L4 max->speed flip: endpoint unchanged"       "$(epv)" "127.0.0.1:59402"
# and back, so the bar is symmetric (no privileged mode)
R2=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)
bctl mode max
asrt "AGG-L4 speed->max flip: AGG_SCHED now max"        "$(aggf AGG_SCHED)" max
asrt "AGG-L4 speed->max flip: EXACTLY ONE bond-agg restart" \
     "$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)" "$((R2+1))"

# AGG-L5 — a healthy `max` tick is a NO-OP (the F17 property, for the new mode).
# converged() rebuilds agg_env and cmp's it, so a non-deterministic AGG_SCHED (or
# a builder that re-derives it differently) would churn the datapath every tick.
setup; bctl on; bctl mode max
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0); E0=$(aggenv)
runw; runw
asrt "AGG-L5 healthy max tick: ZERO bond-agg restarts" \
     "$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)" "$R0"
asrt "AGG-L5 healthy max tick: agg_env unchanged" "$(aggenv)" "$E0"

# AGG-L6 — the arity floor is a property of AGGREGATION, not of one mode name.
# The verb-acceptance assert is what stops this bar passing VACUOUSLY: a CLI
# that does not know `max` at all also leaves the mode at eco with no feeder,
# which is indistinguishable from a correct arity refusal unless the PARSER is
# checked separately.
setup; fact onewan 1; bctl on; bctl mode eco
L6OUT=$(sh "$P5/bondctl" mode max 2>&1)
case "$L6OUT" in
  *"usage: bondctl mode"*) no "AGG-L6 bondctl REJECTS the verb mode max (parser refusal, not arity)" ;;
  *)                       ok "AGG-L6 bondctl accepts the verb mode max (any refusal must come from the arity guard)" ;;
esac
asrt "AGG-L6 N=1 max refused, prior mode kept" "$(cat "$WORK/etc/bond/mode")" eco
asrt "AGG-L6 N=1 max: no agg feeder"           "$(running bond-agg)" 0

# AGG-L7 — no pruning by mode. `speed` picks the fewest/fastest sources PER FRAME
# in the datapath; the reconciler must still ENROL every live source, or the
# daemon can never promote one it was never given.
setup; fact nwan 3; bctl on; bctl mode max
asrt "AGG-L7 N=3 max enrols ALL 3"   "$(aggf AGG_PATHS)" "eth1,usb0,eth0"
asrt "AGG-L7 N=3 max AGG_W arity==N" "$(ncsv "$(aggf AGG_W)")" 3
setup; fact nwan 4; bctl on; bctl mode max
asrt "AGG-L7 N=4 max enrols ALL 4"   "$(aggf AGG_PATHS)" "eth1,usb0,eth0,wwan0"
asrt "AGG-L7 N=4 max: paths == routed sources" "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
setup; fact nwan 4; bctl on; bctl mode speed
asrt "AGG-L7 N=4 speed enrols ALL 4 too (selection is the datapath's)" \
     "$(aggf AGG_PATHS)" "eth1,usb0,eth0,wwan0"

# AGG-L8 — INV5 atomicity for the new mode: a failed verify restores the PRIOR
# mode, brings engarde back and re-pins :59401 (the MF-1 property, for `max`).
setup; bctl on; bctl mode eco; fact capable 0
L8OUT=$(sh "$P5/bondctl" mode max 2>&1)
# the FATAL must NAME the mode that failed. On a CLI that never accepted `max`
# the same end state (mode eco, agg down, engarde back) is reached via a usage
# error, so without this the four asserts below pass vacuously.
case "$L8OUT" in
  *"max engage failed"*) ok "AGG-L8 the aggregate revert path RAN for max (FATAL names the mode)" ;;
  *)                     no "AGG-L8 no max-engage-failed FATAL -- the aggregate revert path never ran" ;;
esac
asrt "AGG-L8 max verify-fail: mode restored" "$(cat "$WORK/etc/bond/mode")" eco
asrt "AGG-L8 max verify-fail: agg down"      "$(running bond-agg)" 0
asrt "AGG-L8 max verify-fail: engarde back"  "$(running engarde-client)" 1
asrt "AGG-L8 max verify-fail: endpoint LOCAL (MF-1)" "$(epv)" "127.0.0.1:59401"

# AGG-L9 — the procd units PASS AGG_SCHED through. An agg_env carrying the
# selector is useless if the service stanza does not put it in the daemon's
# environment, and the on-demand fallback stanza in bond-xctl must stay
# byte-equivalent to the shipped canonical unit (the drift this repo already
# fixed once for STOP/respawn).
grep -q 'AGG_SCHED=\$AGG_SCHED' "$P5/init.d/bond-agg" \
  && ok "AGG-L9 canonical init.d/bond-agg passes AGG_SCHED to the daemon" \
  || no "AGG-L9 canonical init.d/bond-agg does NOT pass AGG_SCHED"
grep -q 'AGG_SCHED=\$AGG_SCHED' "$P5/bond-xctl" \
  && ok "AGG-L9 bond-xctl fallback stanza passes AGG_SCHED too (no drift)" \
  || no "AGG-L9 bond-xctl fallback stanza does NOT pass AGG_SCHED"
CANON=$(sed -n '/^START=94/,$p' "$P5/init.d/bond-agg")
FALLB=$(sed -n '/^START=94/,/^SVCEOF$/p' "$P5/bond-xctl" | grep -v '^SVCEOF$')
asrt "AGG-L9 fallback stanza == canonical unit" "$FALLB" "$CANON"

# AGG-L10 — ONE owner of the mode class. `bond-xctl _sched` is the single table;
# bondctl and bond-ecod ask it instead of each carrying their own mode list, so
# a third aggregate scheduler is one row, not three edits.
setup
asrt "AGG-L10 _sched max"    "$(xctl _sched max)"   max
asrt "AGG-L10 _sched speed"  "$(xctl _sched speed)" speed
xctl _sched lightning >/dev/null 2>&1 \
  && no "AGG-L10 _sched lightning must exit non-zero (not an aggregate mode)" \
  || ok "AGG-L10 _sched lightning is NOT an aggregate mode (exit 1)"
xctl _sched eco >/dev/null 2>&1 \
  && no "AGG-L10 _sched eco must exit non-zero (not an aggregate mode)" \
  || ok "AGG-L10 _sched eco is NOT an aggregate mode (exit 1)"
grep -q '_sched' "$P5/bondctl" \
  && ok "AGG-L10 bondctl asks _sched (no second copy of the mode class)" \
  || no "AGG-L10 bondctl carries its own aggregate-mode test"
grep -q '_sched' "$P5/bond-ecod" \
  && ok "AGG-L10 bond-ecod asks _sched (no second copy of the mode class)" \
  || no "AGG-L10 bond-ecod carries its own aggregate-mode test"
# LIVE CODE only. bond-ecod keeps a comment quoting the line it replaced (that
# record is worth having), so a whole-file grep matches the DOCUMENTATION and
# fails a correct artifact -- which is exactly what it did on this bar's first
# run. Narrowed to non-comment lines; teeth re-checked against the pre-U17
# bond-ecod, which still matches and still fails.
grep -v '^[[:space:]]*#' "$P5/bond-ecod" | grep -q '"\$MODE" = "speed"' \
  && no "AGG-L10 bond-ecod still tests the mode NAME (would run its policy during max)" \
  || ok "AGG-L10 bond-ecod no longer tests a mode NAME (live code, comments excluded)"

# AGG-L11 — the auto policy never selects an aggregate mode, and never runs
# during one. Pre-U17 ecod skipped on `[ "$MODE" = "speed" ]`, so in `max` it
# would have kept running and issued _mode_auto against an aggregating box.
setup; bctl on; bctl mode max; touch "$WORK/etc/bond/auto"
runecod
asrt "AGG-L11 ecod does not disturb mode during max" "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L11 ecod did not start engarde during max" "$(running engarde-client)" 0
bctl _mode_auto max >/dev/null 2>&1 \
  && no "AGG-L11 _mode_auto accepted an aggregate mode" \
  || ok "AGG-L11 _mode_auto REFUSES an aggregate mode (auto never aggregates)"

echo "===== Layer-2: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
