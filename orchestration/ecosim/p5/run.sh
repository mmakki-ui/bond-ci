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
# U66/SC2015. Every bar in this file used to be written `A && ok "..." || no "..."`,
# which is NOT if-then-else: `no` also runs whenever `ok` returns non-zero, and then the
# SAME bar increments both counters and prints both a PASS and a FAIL line. That is a
# harness reporting the wrong verdict, not a style point -- it is the family U38 was
# rejected for. It does not fire TODAY only because ok()/no() happen to end in `echo`,
# whose status is 0; the moment either helper grows a trailing test, logger or write to
# a file, all 14 sites start double-counting at once. The bars are now if/then/else, so
# the exclusivity is structural rather than a property of these two function bodies.
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
if echo "$out" | grep -q "in progress; skipping"; then
    ok "F9 MF-3 live-holder lock aged>120s: concurrent op skipped"
else
    no "F9 MF-3 lock serialization (out=$out)"
fi

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
if [ "$osc_ok" = 1 ]; then
    ok "F13 MF-2 speed pinned across wg_ifup x watchdog (no oscillation, INV1)"
else
    no "F13 MF-2 speed oscillated (mode=$(cat "$WORK/etc/bond/mode") agg=$(running bond-agg) eng=$(running engarde-client) ep=$(epv))"
fi

# F14 (reboot-in-speed, INV1) — speed leaves BOTH feeders ENABLED (engarde still
# enabled + agg enabled), so a reboot's rc.d starts both = the boot-time dual-feeder
# window. The FIRST reconcile must collapse to a single feeder (agg), never leaving
# both engarde AND agg running.
setup; bctl on; bctl mode speed
reboot                                    # both enabled -> both running; wg up direct
runw                                      # first watchdog reconcile after boot
sf_ok=1; [ "$(running engarde-client)" = 1 ] && [ "$(running bond-agg)" = 1 ] && sf_ok=0
if [ "$sf_ok" = 1 ]; then
    ok "F14 reboot-in-speed: single feeder after first reconcile (not engarde AND agg)"
else
    no "F14 reboot-in-speed: TWO feeders (eng=$(running engarde-client) agg=$(running bond-agg))"
fi
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
# AGG_W is positional in bond-agg's PUSH modes (`parseW`, p4-bondagg/daemon/main.go
# -- by symbol, because the line number took four values in five days): a vector shorter than
# AGG_PATHS silently privileges the leading paths, so arity must track N. The PULL
# entry point reads no weights at all (ROADMAP U36); these bars gate what bond-xctl
# EMITS, which is what AGG_MODE=client consumes today.
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
if grep -q '^agg|.*,enough_sources|' "$P5/bond.dag"; then
  ok "NG4 bond.dag agg guard is spelled enough_sources (not two_wans)"
else
  no "NG4 bond.dag agg guard still spelled two_wans"
fi

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
if grep -q '^agg_revert|' "$P5/bond.dag"; then
  ok "AGG-L3 the aggregate onfail row is agg_revert (mode-blind)"
else
  no "AGG-L3 no agg_revert row in bond.dag"
fi

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
#
# BOTH of its asserts used to pass on the PRE-U17 tree, where `mode max` does not
# exist: the CLI refuses the verb, no bond-agg ever starts, restarts stay 0 and
# agg_env stays empty -- 0 == 0 and "" == "" both hold, and the bar proves
# nothing about `max`. It was the only new AGG-L family with no failing assert
# against the pre-change artifacts. The asserts below fix that the way AGG-L6 and
# AGG-L8 already did: PIN THE PRECONDITION. A no-op bar must first show there was
# something to no-op ON.
setup; bctl on
L5OUT=$(sh "$P5/bondctl" mode max 2>&1)
case "$L5OUT" in
  *"usage: bondctl mode"*) no "AGG-L5 bondctl accepts the verb mode max (precondition)" ;;
  *)                       ok "AGG-L5 bondctl accepts the verb mode max (precondition)" ;;
esac
asrt "AGG-L5 precondition: mode is max"      "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L5 precondition: agg feeder is UP" "$(running bond-agg)" 1
asrt "AGG-L5 precondition: AGG_SCHED=max"    "$(aggf AGG_SCHED)" max
R0=$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0); E0=$(aggenv)
runw; runw
asrt "AGG-L5 healthy max tick: ZERO bond-agg restarts" \
     "$(cat "$WORK/restarts.bond-agg" 2>/dev/null || echo 0)" "$R0"
asrt "AGG-L5 healthy max tick: agg_env unchanged"  "$(aggenv)" "$E0"
asrt "AGG-L5 healthy max tick: STILL aggregating"  "$(running bond-agg)" 1

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
if grep -q 'AGG_SCHED="[$]AGG_SCHED"' "$P5/init.d/bond-agg"; then
  ok "AGG-L9 canonical init.d/bond-agg passes AGG_SCHED to the daemon"
else
  no "AGG-L9 canonical init.d/bond-agg does NOT pass AGG_SCHED"
fi
if grep -q 'AGG_SCHED="[$]AGG_SCHED"' "$P5/bond-xctl"; then
  ok "AGG-L9 bond-xctl fallback stanza passes AGG_SCHED too (no drift)"
else
  no "AGG-L9 bond-xctl fallback stanza does NOT pass AGG_SCHED"
fi
CANON=$(sed -n '/^START=94/,$p' "$P5/init.d/bond-agg")
FALLB=$(sed -n '/^START=94/,/^SVCEOF$/p' "$P5/bond-xctl" | grep -v '^SVCEOF$')
asrt "AGG-L9 fallback stanza == canonical unit" "$FALLB" "$CANON"

# AGG-L10 — ONE owner of the mode class. `bond-xctl _sched` is the single table;
# bondctl and bond-ecod ask it instead of each carrying their own mode list, so
# a third aggregate scheduler is one row, not three edits.
setup
asrt "AGG-L10 _sched max"    "$(xctl _sched max)"   max
asrt "AGG-L10 _sched speed"  "$(xctl _sched speed)" speed
if xctl _sched lightning >/dev/null 2>&1; then
  no "AGG-L10 _sched lightning must exit non-zero (not an aggregate mode)"
else
  ok "AGG-L10 _sched lightning is NOT an aggregate mode (exit 1)"
fi
if xctl _sched eco >/dev/null 2>&1; then
  no "AGG-L10 _sched eco must exit non-zero (not an aggregate mode)"
else
  ok "AGG-L10 _sched eco is NOT an aggregate mode (exit 1)"
fi
if grep -q '_sched' "$P5/bondctl"; then
  ok "AGG-L10 bondctl asks _sched (no second copy of the mode class)"
else
  no "AGG-L10 bondctl carries its own aggregate-mode test"
fi
if grep -q '_sched' "$P5/bond-ecod"; then
  ok "AGG-L10 bond-ecod asks _sched (no second copy of the mode class)"
else
  no "AGG-L10 bond-ecod carries its own aggregate-mode test"
fi
# LIVE CODE only. bond-ecod keeps a comment quoting the line it replaced (that
# record is worth having), so a whole-file grep matches the DOCUMENTATION and
# fails a correct artifact -- which is exactly what it did on this bar's first
# run. Narrowed to non-comment lines; teeth re-checked against the pre-U17
# bond-ecod, which still matches and still fails.
if grep -v '^[[:space:]]*#' "$P5/bond-ecod" | grep -q '"[$]MODE" = "speed"'; then
  no "AGG-L10 bond-ecod still tests the mode NAME (would run its policy during max)"
else
  ok "AGG-L10 bond-ecod no longer tests a mode NAME (live code, comments excluded)"
fi

# AGG-L11 — the auto policy never selects an aggregate mode, and never runs
# during one. Pre-U17 ecod skipped on `[ "$MODE" = "speed" ]`, so in `max` it
# would have kept running and issued _mode_auto against an aggregating box.
setup; bctl on; bctl mode max; touch "$WORK/etc/bond/auto"
runecod
asrt "AGG-L11 ecod does not disturb mode during max" "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L11 ecod did not start engarde during max" "$(running engarde-client)" 0
if bctl _mode_auto max >/dev/null 2>&1; then
  no "AGG-L11 _mode_auto accepted an aggregate mode"
else
  ok "AGG-L11 _mode_auto REFUSES an aggregate mode (auto never aggregates)"
fi

# AGG-L12 (THE ONE-ROW CLAIM, EXECUTED) - "a third aggregate scheduler is ONE
# table row and ZERO dag rows" was stated unqualified in the ROADMAP and in the
# commit message, and it was FALSE when measured: adding `turbo` to bond-xctl's
# table left `bondctl mode turbo` refused by the parser, because bondctl wrote
# the mode NAMES out again. The claim is now a bar that DOES the experiment:
# copy the shipped tree, add exactly one row, and require (a) the diff is ONE
# line in ONE file - bond.dag included, untouched - and (b) the new mode engages
# end to end carrying its own AGG_SCHED.
MUTD="$WORK.mut"
rm -rf "$MUTD"; mkdir -p "$MUTD"; cp -R "$P5/." "$MUTD/"
sed -i 's/^AGG_SCHED_TABLE="\(.*\)"$/AGG_SCHED_TABLE="\1 turbo:turbo"/' "$MUTD/bond-xctl"
NFILES=$(diff -rq "$P5" "$MUTD" 2>/dev/null | grep -c 'differ')
NLINES=$(diff -r "$P5" "$MUTD" 2>/dev/null | grep -c '^[<>]')
asrt "AGG-L12 a third scheduler touches exactly ONE file"    "$NFILES" 1
asrt "AGG-L12 ...and exactly ONE line in it (one - / one +)" "$NLINES" 2
if diff -q "$P5/bond.dag" "$MUTD/bond.dag" >/dev/null 2>&1; then
  ok "AGG-L12 bond.dag is byte-identical (ZERO dag rows)"
else
  no "AGG-L12 bond.dag changed - the new scheduler needed a dag row"
fi
P5REAL="$P5"; P5="$MUTD"
setup; bctl on
L12OUT=$(sh "$P5/bondctl" mode turbo 2>&1)
case "$L12OUT" in
  *"usage: bondctl mode"*) no  "AGG-L12 bondctl accepts mode turbo after the ONE row" ;;
  *)                       ok "AGG-L12 bondctl accepts mode turbo after the ONE row" ;;
esac
asrt "AGG-L12 turbo: mode stored"      "$(cat "$WORK/etc/bond/mode")" turbo
asrt "AGG-L12 turbo: agg feeder up"    "$(running bond-agg)" 1
asrt "AGG-L12 turbo: single feeder"    "$(running engarde-client)" 0
asrt "AGG-L12 turbo: endpoint :59402"  "$(epv)" "127.0.0.1:59402"
asrt "AGG-L12 turbo: AGG_SCHED=turbo"  "$(aggf AGG_SCHED)" turbo
asrt "AGG-L12 turbo: the usage line lists it too (derived, not typed)" \
     "$(sh "$P5/bondctl" mode bogus 2>&1 | sed -n 's/^usage: bondctl mode //p')" \
     "lightning|eco|max|speed|turbo"
P5="$P5REAL"; rm -rf "$MUTD"

# AGG-L13 - VERSION SKEW MUST FAIL CLOSED. U17 replaced bond-ecod's
# self-contained `[ "$MODE" = "speed" ]` with a question to another executable
# (`bondctl _sched`). That introduces a third answer the string test never had:
# "the question could not be ASKED". The first form treated it as "not an
# aggregate mode" and FAILED OPEN - on a half-upgraded box (old bondctl or old
# bond-xctl on disk, `_sched` an unknown verb -> exit 1) ecod would run its
# eco/lightning policy against an aggregating box and issue `_mode_auto`,
# rewriting /etc/bond/mode. `_sched` now exits 3 for "not an aggregate mode" and
# ecod proceeds ONLY on 3. The stub below is a real old CLI: it answers every
# other verb through the shipped bond-xctl and rejects `_sched` the way a
# pre-U17 bondctl does.
setup; bctl on; bctl mode max; touch "$WORK/etc/bond/auto"
cat > "$WORK/fakebin/oldbondctl" <<'OLDEOF'
#!/bin/sh
case "$1" in
  _sched|_sched_modes) echo "usage: bondctl on|off|status|mode|auto on|off" >&2; exit 1 ;;
  _mode_auto) echo "$2" > "$BOND_DIR/mode" ;;
  *) exec sh "$XCTL_REAL" "$@" ;;
esac
OLDEOF
chmod +x "$WORK/fakebin/oldbondctl"
echo degraded > "$WORK/run/bond/tput"     # the one-cycle trigger to _mode_auto lightning
XCTL_REAL="$P5/bond-xctl" MAXCYCLES=1 CYCLE=0 BONDCTL="$WORK/fakebin/oldbondctl" \
  SYS_NET="$WORK/sys" PING="$BIN/ping" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1
asrt "AGG-L13 skewed CLI (_sched unknown): ecod STANDS DOWN, mode still max" \
     "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L13 skewed CLI: aggregate feeder untouched" "$(running bond-agg)" 1
# ...and the same cycle with a CURRENT CLI still ACTUATES, so the bar is not
# "ecod never does anything": in eco, tput degraded escapes to lightning.
setup; bctl on; bctl mode eco; touch "$WORK/etc/bond/auto"
echo degraded > "$WORK/run/bond/tput"
runecod
asrt "AGG-L13 current CLI, NON-aggregate mode: ecod still actuates (eco -> lightning)" \
     "$(cat "$WORK/etc/bond/mode")" lightning

# AGG-L14 - the EMPTY mode verb is refused REGARDLESS of stored state (found in
# the U17 adversarial review). Deriving acceptance from `_sched` introduced a
# hole the listed parser never had: `_sched ""` answers for the STORED mode (a
# query default kept for bond-ecod), so `bondctl mode` with the argument
# forgotten was ACCEPTED exactly when the box was aggregating -- it wrote an
# EMPTY mode fact and the follow-up reconcile tore the aggregate down -- while
# the same typo on a lightning box printed usage and exited 1. State-dependent
# parsing is the bug. TEETH: on the pre-fix bondctl the FIRST block fails 5/5
# (verb accepted, exit 0, mode file emptied, feeder down, engarde back); the
# second block passes either way -- it pins that the refusal is the SAME on a
# non-aggregate box, i.e. acceptance no longer depends on state.
setup; bctl on; bctl mode max
L14OUT=$(sh "$P5/bondctl" mode 2>&1); L14RC=$?
case "$L14OUT" in
  *"usage: bondctl mode"*) ok "AGG-L14 empty mode verb on an aggregating box: usage printed" ;;
  *)                       no "AGG-L14 empty mode verb on an aggregating box was ACCEPTED" ;;
esac
asrt "AGG-L14 empty mode verb: exit 1"            "$L14RC" 1
asrt "AGG-L14 empty mode verb: mode fact intact"  "$(cat "$WORK/etc/bond/mode")" max
asrt "AGG-L14 empty mode verb: still aggregating" "$(running bond-agg)" 1
asrt "AGG-L14 empty mode verb: single feeder"     "$(running engarde-client)" 0
# ...and the refusal is state-INDEPENDENT: same verb, non-aggregate box.
setup; bctl on
L14RC2=0; sh "$P5/bondctl" mode >/dev/null 2>&1 || L14RC2=$?
asrt "AGG-L14 empty mode verb on a lightning box: exit 1 too" "$L14RC2" 1
asrt "AGG-L14 empty mode verb on a lightning box: mode intact" "$(cat "$WORK/etc/bond/mode")" lightning

echo "===== Layer-2: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
