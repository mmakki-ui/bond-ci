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
# NG8 -- AGG_SPOTTY / AGG_LIGHTNING plumbing (U15b fix round, verify blocker
# #1). BEFORE this round: grep -rln AGG_SPOTTY across the whole tree returned
# hits only under p4-bondagg/daemon/ -- build_agg_env emitted AGG_LISTEN /
# AGG_SERVER / AGG_PATHS / AGG_W and NOTHING else, so a deployed daemon always
# saw an EMPTY spotty set and standing lightning was a no-op outside `go test`
# regardless of AGG_LIGHTNING. Fixed by deriving AGG_SPOTTY from the SAME
# operator `metered` fact _metered()/gl_sources() already compute (ordered_spotty(),
# bond-xctl), and by giving AGG_LIGHTNING its own operator fact
# ($BOND_DIR/lightning) so the whole feature -- not just the fact -- is
# switchable on a real box, same pattern as $BOND_DIR/agg_w.
# usb0 (tethering) is the design docs' own canonical spotty example
# (p5-execution-handover.md:77); it is proto=dhcp in this fixture (not a
# GL_CELL_PROTOS match), so it is metered ONLY via the operator fact -- the
# same case a real USB tether is in (INTENT OBJ-H: the router cannot observe
# the radio, only a human can record it).
setup; fact nwan 3; echo usb0 > "$WORK/etc/bond/metered"; bctl on; bctl mode speed
asrt "NG8 AGG_SPOTTY carries the metered source" "$(aggf AGG_SPOTTY)" "usb0"
case ",$(aggf AGG_PATHS)," in
    *",usb0,"*) ok  "NG8 AGG_SPOTTY names a device AGG_PATHS actually carries" ;;
    *)          no  "NG8 AGG_SPOTTY names usb0 but AGG_PATHS does not carry it" ;;
esac
asrt "NG8 AGG_LIGHTNING defaults OFF (no operator fact)" "$(aggf AGG_LIGHTNING)" "0"

# NG8b -- AGG_LIGHTNING is honoured from its own operator fact. AGG_SPOTTY
# alone does not make the feature reachable: without this, nothing could ever
# turn AGG_LIGHTNING on outside a manual on-box env-file edit that the next
# reconcile pass would silently overwrite (act_env_gen regenerates agg_env
# from build_agg_env every tick).
setup; fact nwan 3; echo usb0 > "$WORK/etc/bond/metered"; echo 1 > "$WORK/etc/bond/lightning"
bctl on; bctl mode speed
asrt "NG8b AGG_LIGHTNING=1 operator fact IS honoured" "$(aggf AGG_LIGHTNING)" "1"
runw
asrt "NG8b survives a second reconcile tick (not clobbered)" "$(aggf AGG_LIGHTNING)" "1"

# NG8c -- no metered fact anywhere: AGG_SPOTTY is empty, the HONEST fail-safe
# (lightning.go's own EMPTY-set path), never fabricated to look enabled.
setup; fact nwan 3; bctl on; bctl mode speed
asrt "NG8c no metered fact: AGG_SPOTTY is empty" "$(aggf AGG_SPOTTY)" ""

# NG8d -- TWO metered sources (Fable pass on the fix round). The committed
# ordered_spotty matched its newline-separated metered list against a
# space-delimited case pattern, so it emitted a NON-EMPTY AGG_SPOTTY only when
# EXACTLY ONE device was metered -- a hidden 1-metered-source assumption the
# N-GENERIC rule forbids, and NG8's single-device fixture could never see.
# Demonstrated against the pre-fix blob (two metered -> AGG_SPOTTY empty).
# The fact file lists eth0 BEFORE usb0 on purpose: the expected output is
# ordered_wans order (usb0,eth0), pinning that ordered_spotty is a FILTER of
# the live ordered set, never a re-ranking by the fact file.
setup; fact nwan 3; printf 'eth0\nusb0\n' > "$WORK/etc/bond/metered"; bctl on; bctl mode speed
asrt "NG8d BOTH metered sources carried, in ordered_wans order" "$(aggf AGG_SPOTTY)" "usb0,eth0"
asrt "NG8d AGG_PATHS still carries all 3 (spotty is a subset, not a filter of paths)" "$(aggf AGG_PATHS)" "eth1,usb0,eth0"

echo "===== Layer-2: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
