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
# SC2016 ("expressions do not expand in single quotes") is INFORMATIONAL, and in this
# file non-expansion is nearly always the POINT. It is annotated PER SITE, with the
# failure each site would cause if it expanded -- NOT file-wide. The count is MEASURED,
# not carried: `grep -c '^[[:space:]]*# shellcheck disable=SC2016' orchestration/ecosim/p5/run.sh`
# = 23 (U226, 2026-09-05: 21 measured on dev at fa2f818 plus this unit's two ST-3
# sites). The number this line carried before was 20, and it was ALREADY STALE when
# U226 read it -- dev measured 21 -- which is the failure mode the sentence above
# warns about: a count in prose is not a measurement, it is a claim with a vintage.
# Re-measure with the command above; do not carry this number forward untested. The
# ANCHOR is load-bearing: an unanchored grep for that same text also matches the prose
# lines in THIS header that name the directive, so it over-counts and is not the
# measurement. The sites are three shapes:
#   * grep/sed for LITERAL shipped-source text, e.g.
#         grep -c -F 'mkdir -p "$BOND_DIR"' "$P5/bondctl"
#     where expanding $BOND_DIR searches the harness fixture path, matches nothing,
#     and the bar reads 0 and goes GREEN for the wrong reason;
#   * cap_gone's third argument, a command string this file eval-s LATER;
#   * printf building the BODY of a generated shim or fixture file.
# A file-level `# shellcheck disable=SC2016` stood here until U66b. It was removed
# because it also silently suppressed any NEW, UNINTENDED SC2016 anywhere in 3,100
# lines -- the cost of the blanket, not of any one site. Re-measure by deleting a
# directive; never by trusting the count above.
# This does NOT extend to deploy/p5: shape-install carries its own narrow, function-
# scoped directive, because there the reason is different (cap tests are eval-ed).
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
    rm -rf "$WORK"; mkdir -p "$WORK/etc/p5" "$WORK/run/p5" "$WORK/fakebin"
    export ECOSIM_STATE="$WORK"
    # fake target binaries (only -x is checked)
    for b in engarde-client p5-datapath p5-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"
    done
    # facts / world
    echo lightning       > "$WORK/etc/p5/mode"
    echo wgclient1        > "$WORK/etc/p5/wg-logical"
    # DECLARE the logical tunnel to the ip shim. The ecosim world genuinely HAS a wg
    # tunnel -- bond-xctl manages it -- so `ip link show wgclient1` must succeed here.
    # Previously nothing declared it and the shim answered success for EVERY device,
    # which is not the same thing: it was right about this one by being wrong about
    # all of them. SH-16 keeps its own hermetic world and is unaffected.
    : > "$WORK/netdev.wgclient1"
    echo "203.0.113.9:51820" > "$WORK/direct"
    echo "203.0.113.9:51820" > "$WORK/ep"
    echo 1 > "$WORK/capable"
    echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"
    echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in p5-datapath p5-ecod p5-watchdog p5-shape engarde-client; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
    # E4 shaping (U22): the box starts UNSHAPED with the `shape` fact absent,
    # so the default (`on`) is what every pre-existing scenario exercises --
    # shaping has to converge itself on the first lifecycle edge, exactly as it
    # will on a fresh install. MTU starts at the un-bonded 1420.
    echo 1420 > "$WORK/mtu.wgclient1"
    # U125: a COUNTING iptables, created per work-dir and prepended AHEAD of $BIN.
    # The checked-in bin/iptables is record-only and always exits 0, which cannot
    # model the one kernel fact unblock()'s sweep turns on: `iptables -D` FAILS
    # when no matching rule exists. Against a record-only shim the sweep would run
    # to its 16-iteration cap on every reconcile and CR-3 could not be written at
    # all. bin/iptables is not U125's owned file, hence the shadow rather than an
    # edit; fold this body back into bin/iptables when that file's owner lands.
    # LEDGER FORMAT IS UNCHANGED ("iptables $*"), so every existing bar still reads.
    mkdir -p "$WORK/xbin"
    cat > "$WORK/xbin/iptables" <<'IPTEOF'
#!/bin/sh
S="$ECOSIM_STATE"
echo "iptables $*" >> "$S/ledger"
n=$(cat "$S/iptrules" 2>/dev/null || echo 0)
case "$1" in
  -I) echo $((n+1)) > "$S/iptrules" ;;
  -D) [ "$n" -gt 0 ] || exit 1
      echo $((n-1)) > "$S/iptrules" ;;
esac
exit 0
IPTEOF
    chmod +x "$WORK/xbin/iptables"
    echo 0 > "$WORK/iptrules"
    # env for the artifacts
    export PATH="$WORK/xbin:$BIN:$PATH"
    export BOND_DIR="$WORK/etc/p5"
    export RUN_DIR="$WORK/run/p5"
    export DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    # SVC IS DELIBERATELY NOT EXPORTED (U114). It used to be, pointing at svc-agg,
    # because bond-ecod's "the bond is enabled" gate ran `"$SVC" enabled` and the
    # SHIPPED file defaulted that to /etc/init.d/engarde-client -- so the harness
    # was papering over the last engarde dependency in the tree, and every ecod bar
    # here passed for a reason the box would not have had (after U141 nothing
    # enables engarde-client, so on a real purged box the gate was false forever and
    # the eco<->lightning policy never acted). bond-ecod now reads the STORED fact
    # $BOND_DIR/rc, so no service path is needed and leaving SVC unset is what makes
    # every ecod bar below a real purged-box measurement. EF-3 states it as a bar.
    export AGG_SVC="$BIN/svc-agg"
    export ECOD_SVC="$BIN/svc-ecod"
    export WDOG_SVC="$BIN/svc-watchdog"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client"
    export AGG_BIN="$WORK/fakebin/p5-datapath"
    export ECOD_BIN="$WORK/fakebin/p5-ecod"
    export XCTL="$P5/bond-xctl"
    # U124: bond-xctl is a bin + five sourced libs. The installed default is
    # /usr/lib/p5; the harness runs the shipped tree out of a worktree, so it
    # must point XCTL_LIB at that tree's lib/ or the bin fails loud (XS-1).
    # Derived from $P5 so the AGG-L12 mutant tree (P5=$MUTD) picks up its OWN
    # libs when setup runs against it.
    export XCTL_LIB="$P5/lib"
    export LOGGER="$BIN/logger"
    # E4 shaping controller (U22). `tc` is NOT exported: bond-xctl resolves it
    # through PATH, and $BIN is prepended above, so the shim wins.
    export SHAPE_SVC="$BIN/svc-shape"

    # INJECTED, not merely PATH-shadowed (U69). `ip` and `ping` are busybox
    # APPLETS, and busybox ash is a STANDALONE shell: for an applet name it runs
    # its own applet and never consults $PATH. So under the interpreter the
    # routers actually run, `export PATH="$BIN:$PATH"` above does NOT shim these
    # two -- the reconciler saw the test machine's real routing table and real
    # internet instead of the fixture, and 13 bars below went red on that alone.
    # bond-xctl takes them as variables for exactly this reason.
    export IP="$BIN/ip"
    export PING="$BIN/ping"
    # U208: the OLD-STACK QUIESCENCE CHECKER the `old_quiescent` guard runs.
    # INJECTED for the same reason IP/PING are, and for one more: the shipped
    # default is an ABSOLUTE path (/usr/sbin/p5-uninstall), so a PATH shim could
    # never reach it and every scenario in this file would take the guard's
    # fail-closed 127 arm. The shim defaults to QUIESCENT, so every scenario
    # written before this unit keeps its exact meaning.
    export QUIESCE_CHECK="$BIN/p5-quiescent"
}
fact()   { echo "$2" > "$WORK/$1"; }
bctl()   { sh "$P5/bondctl" "$@" >>"$WORK/ledger" 2>&1; }
xctl()   { sh "$P5/bond-xctl" "$@"; }
node()   { sh "$P5/bond-xctl" node 2>/dev/null; }
epv()    { cat "$WORK/ep" 2>/dev/null; }
runw()   { MAXCYCLES=1 CYCLE=0 sh "$P5/bond-watchdog" >>"$WORK/ledger" 2>&1; }
runecod(){ MAXCYCLES=1 CYCLE=0 BONDCTL="$P5/bondctl" SYS_NET="$WORK/sys" PING="$BIN/ping" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1; }
running(){ cat "$WORK/running.$1" 2>/dev/null; }
enabledf(){ cat "$WORK/enabled.$1" 2>/dev/null; }
# THE ENGAGEMENT FACT (U114): $BOND_DIR/rc, presence-only, written by `bondctl
# on|off` and read by desired() and bond-ecod. Reported as 1/0 so a bar reads the
# same shape as enabledf/running.
rcf()    { if [ -f "$WORK/etc/p5/rc" ]; then echo 1; else echo 0; fi; }
rcon()   { : > "$WORK/etc/p5/rc"; }
# agg_env readers. Defined HERE rather than in the NG block because U141 made
# agg_env the config of EVERY bonded mode, so scenarios from S4 onward assert on
# it -- AGG_SCHED is now the fact that distinguishes eco from lightning from max
# from speed at this layer.
aggenv() { cat "$WORK/etc/p5/agg_env" 2>/dev/null; }
aggf()   { aggenv | grep "^$1=" | cut -d= -f2-; }   # $1 = AGG_PATHS | AGG_W | AGG_SCHED
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
# reboot(): model a box reboot. procd stops the feeder, then rc.d STARTS it if it
# is ENABLED, and wg comes up direct (GL co-writer). U141 left ONE feeder, so the
# boot-time DUAL-feeder window (spec §9-risk-4: an aggregating box also left
# engarde rc-enabled, and rc.d started both) is closed by construction -- there is
# no second service for rc.d to start. F14 asserts the post-boot state directly.
reboot() {
    # ONE feeder since U141, so this is a statement, not a loop (shellcheck
    # SC2043: a for over a single word never loops). Adding a second supervised
    # service later means adding a line here, which is the same edit either way.
    if [ "$(cat "$WORK/enabled.p5-datapath" 2>/dev/null)" = 1 ]
    then echo 1 > "$WORK/running.p5-datapath"
    else echo 0 > "$WORK/running.p5-datapath"; fi
    fact ep "203.0.113.9:51820"        # wg up at boot -> GL co-writer sets direct
}

echo "===== P5 Layer-2 artifact harness ====="

# S1 — on: engage THE feeder (bond-agg, :59402), endpoint local to it. TWO things
# move and U114 separated them: `bondctl on` writes the FACT ($BOND_DIR/rc, which
# desired() reads) and the `engage` row enables the feeder's own init script (the
# MECHANISM, which node() reads and which rc.d needs at boot).
setup; bctl on
asrt "S1 on: node"        "$(node)" engaged
asrt "S1 on: endpoint"    "$(epv)"  "127.0.0.1:59402"
asrt "S1 on: feeder up"   "$(running p5-datapath)" 1
asrt "S1 on: the rc FACT is written"            "$(rcf)" 1
asrt "S1 on: the feeder is rc.d ENABLED by the engage row" "$(enabledf p5-datapath)" 1

# S2 — off: direct, no feeder, stays off
setup; bctl on; bctl off
asrt "S2 off: node"       "$(node)" off
asrt "S2 off: endpoint"   "$(epv)"  "203.0.113.9:51820"
asrt "S2 off: feeder down" "$(running p5-datapath)" 0

# S3 — incapable server: engage self-test fails -> suspended, direct
setup; fact capable 0; bctl on
asrt "S3 incapable: node"     "$(node)" suspended
asrt "S3 incapable: endpoint" "$(epv)" "203.0.113.9:51820"
# S3b — capability returns + wg ifup (97-bond) -> auto-resume engaged (I6)
fact capable 1; hook
asrt "S3b resume: node"     "$(node)" engaged
asrt "S3b resume: endpoint" "$(epv)" "127.0.0.1:59402"

# S4 — mode eco live switch. INVERTED BY U141, and this is the unit's headline:
# `eco` used to be an ENGARDE mode, so the bar asserted the aggregate feeder was
# NOT running. It is now the pull core at N=1 over the primary, fed by the SAME
# bond-agg as every other mode, so the feeder MUST be up -- and what makes it
# `eco` rather than `lightning` is the emitted AGG_SCHED plus the enrolled set.
setup; bctl on; bctl mode eco
asrt "S4 eco: mode"        "$(cat "$WORK/etc/p5/mode")" eco
asrt "S4 eco: node"        "$(node)" engaged
asrt "S4 eco: fed by bond-agg (INVERTED by U141: eco was engarde's)" "$(running p5-datapath)" 1
asrt "S4 eco: AGG_SCHED=eco"  "$(aggf AGG_SCHED)" eco
asrt "S4 eco: enrols the primary ONLY" "$(aggf AGG_PATHS)" "eth1"

# S5 — speed engage: agg up, engarde down, endpoint :59402
setup; bctl on; bctl mode speed
asrt "S5 speed: mode"      "$(cat "$WORK/etc/p5/mode")" speed
asrt "S5 speed: agg up"    "$(running p5-datapath)" 1
asrt "S5 speed: AGG_SCHED=speed" "$(aggf AGG_SCHED)" speed
asrt "S5 speed: endpoint"  "$(epv)" "127.0.0.1:59402"

# S6 — speed verify FAIL (server 59402 not capable) -> restore prev mode (INV5).
# THE OUTCOME CHANGED WITH THE FOLD, and it is not a weakened bar: a failed
# aggregate engage used to fall back onto the engarde feeder (`agg_revert` ->
# `restore_feeder`), and with one feeder there is nothing to fall back TO. The
# row's onfail is `suspend`: revert to DIRECT (confirmed), stop the feeder, leave
# the endpoint on a path that works. The CLI still restores the prior mode, so
# the next trigger retries THAT mode (the I6 auto-resume shape).
setup; bctl on; bctl mode eco; fact capable 0; bctl mode speed
asrt "S6 speed-fail: mode restored" "$(cat "$WORK/etc/p5/mode")" eco
asrt "S6 speed-fail: feeder stopped" "$(running p5-datapath)" 0
asrt "S6 speed-fail: node suspended" "$(node)" suspended
asrt "S6 speed-fail: endpoint DIRECT (the suspend onfail, not a fallback feeder)"      "$(epv)" "203.0.113.9:51820"

# S7 — speed guard fail (one WAN) -> refused, mode kept, and the refusal changes
# NOTHING. Post-fold "no agg" is the wrong assertion: the box was already engaged
# on the eco feeder, and a refused edge must leave that exactly as it was.
setup; bctl on; bctl mode eco; fact onewan 1; bctl mode speed
asrt "S7 speed-1wan: refused, mode kept" "$(cat "$WORK/etc/p5/mode")" eco
asrt "S7 speed-1wan: the refusal changed nothing (still fed as eco)" "$(aggf AGG_SCHED)" eco

# S8 — speed then off: full teardown, single-feeder never violated
setup; bctl on; bctl mode speed; bctl off
asrt "S8 speed->off: node" "$(node)" off
asrt "S8 speed->off: agg down"     "$(running p5-datapath)" 0
asrt "S8 speed->off: feeder rc.d flag cleared (the MECHANISM, not the rc fact)" "$(enabledf p5-datapath)" 0
# MF-1: leaving speed must leave the endpoint CORRECT. Off tears down to DIRECT
# (`disengage` stops the feeder, then ep_direct); the missing endpoint
# assert on the speed-exit path is what hid MF-1.
asrt "S8 speed->off: endpoint DIRECT (MF-1)" "$(epv)" "203.0.113.9:51820"

# S8b — speed -> lightning LIVE switch. INVERTED BY U141: this used to be a
# feeder SWAP (bond-agg down, engarde up, endpoint re-pinned :59401 -- the MF-1
# catch on the `switch` edge). It is now a config change on the ONE feeder: it
# keeps running, the endpoint never moves, and only the emitted AGG_SCHED does.
# The MF-1 property survives as "the endpoint is still the feeder's".
# "no swap" is a CLAIM ABOUT THE TRANSITION, so it cannot be read off the
# post-state: `running p5-datapath = 1` is equally true of a box that tore the
# feeder down and stood a new one up. The discriminator is the init ledger --
# svc-agg logs `start` on a cold start and `restart` on an in-place bounce, so a
# stop+start swap ALWAYS leaves a new `start` line while a live switch never
# does. The two bars below are now independent facts, not one fact twice.
setup; bctl on; bctl mode speed
_s8b0=$(grep -c '^SVC p5-datapath start' "$WORK/ledger" 2>/dev/null); _s8b0=${_s8b0:-0}
bctl mode lightning
_s8b1=$(grep -c '^SVC p5-datapath start' "$WORK/ledger" 2>/dev/null); _s8b1=${_s8b1:-0}
asrt "S8b speed->lightning: mode"        "$(cat "$WORK/etc/p5/mode")" lightning
asrt "S8b speed->lightning: feeder is up after the switch" "$(running p5-datapath)" 1
asrt "S8b speed->lightning: a LIVE switch, not a stop+start swap (no new init 'start')" \
     "$_s8b1" "$_s8b0"
asrt "S8b speed->lightning: AGG_SCHED followed the mode" "$(aggf AGG_SCHED)" lightning
asrt "S8b speed->lightning: endpoint still the feeder's (MF-1)" "$(epv)" "127.0.0.1:59402"

# ============ FAULT BATTERY ============
# F1 — feeder crash + procd respawn (simulated) then a converge: still engaged
setup; bctl on; fact running.p5-datapath 1      # respawn brought it back
xctl reconcile >/dev/null 2>&1                   # level-triggered: desired=engaged, no-op
asrt "F1 crash+respawn: still engaged" "$(node)" engaged
asrt "F1 crash+respawn: feeder running" "$(running p5-datapath)" 1

# F2 — respawn EXHAUSTION: enabled but process absent -> watchdog W1 restarts it
setup; bctl on; fact running.p5-datapath 0      # procd gave up
asrt "F2 pre: feeder absent" "$(running p5-datapath)" 0
runw
asrt "F2 W1 pickup: feeder restarted" "$(running p5-datapath)" 1

# F3 — dead state (INV2): endpoint on the feeder but the feeder DISABLED (rc off) + down.
# RECONCILER CHANGE (was: W2 force-engaged, mode/rc-blind): the dead-state remedy is
# now rc-aware -- reconcile derives desired=off (rc off) and heals the dead state to
# OFF/direct. INV2 still holds (no local endpoint left without a listener), and rc is
# respected (a disabled box is not silently re-engaged). rc-ON dead-state heal = F2.
setup; fact ep "127.0.0.1:59402"; fact enabled.p5-datapath 0; fact running.p5-datapath 0
runw
asrt "F3 dead-state remedy: feeder stays down" "$(running p5-datapath)" 0
asrt "F3 dead-state remedy: node off"           "$(node)" off
asrt "F3 dead-state remedy: endpoint direct"    "$(epv)" "203.0.113.9:51820"

# F4 — A STRAY FEEDER ON AN OFF BOX. Pre-U141 this bar was "two feeders (INV1):
# both running -> W3 stops the stray", which is unwritable now: there is ONE
# feeder, so two can never be up. What INV1 protected against is still real in
# the direction that remains -- a feeder running when the box is OFF -- so the
# bar is re-pointed there rather than deleted. The world: rc never set (no
# `bctl on`), yet the feeder is up; the watchdog's periodic reconcile derives
# desired=off and must tear it down.
setup; fact running.p5-datapath 1
runw
asrt "F4 stray feeder on an OFF box: stopped" "$(running p5-datapath)" 0
asrt "F4 stray feeder on an OFF box: node off" "$(node)" off

# F5 — watchdog is a NO-OP in a clean engaged state (I11): nothing changes
setup; bctl on
b_ep=$(epv); b_e=$(enabledf p5-datapath); b_a=$(running p5-datapath)
runw
asrt "F5 I11 clean no-op: endpoint"  "$(epv)" "$b_ep"
asrt "F5 I11 clean no-op: feeder rc.d flag" "$(enabledf p5-datapath)" "$b_e"
asrt "F5 I11 clean no-op: feeder"    "$(running p5-datapath)" "$b_a"

# F6 — policer degradation (D1): watchdog publishes tput; ecod flips eco->lightning
setup; bctl on; touch "$WORK/etc/p5/auto"; fact enabled.p5-ecod 1; bctl mode eco
touch "$WORK/etc/p5/auto"                # bctl mode cleared it; re-arm for ecod path
echo "degraded rate=1000Bps floor=131072" > "$WORK/run/p5/tput"
fact "etc/p5/applied_wans" eth1
runecod
asrt "F6 tput->ecod: mode lightning" "$(cat "$WORK/etc/p5/mode")" lightning

# F7 — tput sensor PUBLISHES a fact (W5, publish-only)
setup; bctl on
echo $(( $(date +%s) - 5 )) > "$WORK/run/p5/wd_rxt"; echo 0 > "$WORK/run/p5/wd_rx"; fact rx 300000
runw
if [ -s "$WORK/run/p5/tput" ]; then ok "F7 W5 sensor published tput ($(cat "$WORK/run/p5/tput"))"; else no "F7 W5 sensor published tput (empty)"; fi

# ---- U117 helpers: the lock's age is a MONOTONIC STAMP, not the directory mtime ---
# The reconciler no longer calls `stat -c %Y` at all (LK-2). It writes $LOCK/ts at
# acquire, "<mono> <epoch>", and ONLY the mono field decides. These build that stamp
# the way take_lock reads it.
#
# THE TIMEBASE IS OFFSET, AND THAT IS NOT COSMETIC. These fixtures build a stamp
# `now - N` with N up to 1000, so with the raw /proc/uptime as the timebase a host
# up for less than N produces a NEGATIVE stamp; the shipped `_uint` helper in
# xctl-lock.sh rejects
# it, the age reads UNKNOWN, and the bar stops measuring the age path. MEASURED on
# WSL at 254s uptime: LK-1's stamp came out -746, the run logged
# `lock age UNKNOWN ... pass 1/90`, LK-1's two asserts went RED -- and LK-1's own
# NEGATIVE CONTROL went GREEN, because "live holder NOT broken" is true for an
# unknown age too. A bar whose result depends on how long the host has been up is
# not a bar, and one that goes green for the wrong reason is worse than one that
# goes red.
#
# So mono_fix derives the timebase FROM the real /proc/uptime and shifts it into a
# range where every age these fixtures build is expressible, publishing it through
# the same $P5_MONO_SRC the shipped code reads. It KEEPS the `<int>.<frac> <idle>`
# shape, so a missing fraction-strip in the shipped code still reds LK-1 and F9 --
# that property is why the raw file was used here and it is not given up.
# mono_unfix restores the shipped default; every fixture that builds a PAST stamp
# pairs them, and LK-6 fails if the offset ever stops being enough. LK-5 builds a
# FUTURE stamp, which is positive on any uptime, and is deliberately left alone.
MONO_SHIFT=100000
mono_fix() {
    _mb=''; read -r _mb < /proc/uptime; _mb=${_mb%%.*}; _mb=${_mb%% *}
    printf '%s.37 3521.56\n' "$(( _mb + MONO_SHIFT ))" > "$WORK/mono"
    export P5_MONO_SRC="$WORK/mono"
}
mono_unfix() { unset P5_MONO_SRC; }
mono_now() { _mn=''; read -r _mn < "${P5_MONO_SRC:-/proc/uptime}"; _mn=${_mn%%.*}; _mn=${_mn%% *}; echo "$_mn"; }
lock_ts()  { echo "$1 $(date +%s)" > "$WORK/run/p5/lock/ts"; }
lockd()    { if [ -d "$WORK/run/p5/lock" ]; then echo yes; else echo no; fi; }

# F8 — power-loss stale lock is self-clearing (tmpfs, D4): a leftover lock with a
# dead holder pid is broken; the op proceeds (not stuck forever).
setup; mkdir -p "$WORK/run/p5/lock"; echo 999999 > "$WORK/run/p5/lock/pid"   # dead pid
bctl on
asrt "F8 stale-lock self-clear: engaged" "$(node)" engaged

# F9 (MF-3) — lock serialization WITH the age gate: a held lock whose holder pid is
# LIVE and whose age is >120s (but < the 900s PID-reuse backstop) must STILL make a
# concurrent op skip. The pre-fix `age>120` alone would break a live holder mid-engage
# (a legit ~6-8min hold) -> two concurrent DAG walks. MF-3: STALE respects holder
# liveness; age never breaks a live holder below the 900s backstop. ($$ = this live
# run.sh pid. U117: the age comes from $LOCK/ts, so the fixture STAMPS it 200
# monotonic seconds in the past instead of backdating the directory mtime with
# `touch -d` -- nothing reads the mtime any more.)
setup; bctl on; mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"  # LIVE holder
mono_fix
lock_ts $(( $(mono_now) - 200 ))                                                   # aged >120s, < 900s
out=$(xctl reconcile 2>&1); mono_unfix; rmdir "$WORK/run/p5/lock" 2>/dev/null
if echo "$out" | grep -q "in progress; skipping"; then
    ok "F9 MF-3 live-holder lock aged>120s: concurrent op skipped"
else
    no "F9 MF-3 lock serialization (out=$out)"
fi


# ============ LK BATTERY (U117): the lock's age gate without `stat -c %Y` ========
# The defect this closes: AGE was set to 0 whenever `stat -c %Y` was unsupported, and
# the SAME value was compared against the 900s PID-reuse backstop, so a dead holder
# whose pid had been re-issued to a live process was judged live forever and every
# reconcile skipped until reboot. The fix stamps $LOCK/ts at acquire from a MONOTONIC
# source and drops `stat` from the shipped path entirely.

asrt "LK pre: /proc/uptime readable (the shipped default monotonic clock)" \
     "$(if [ -r /proc/uptime ]; then echo yes; else echo no; fi)" yes

# LK-0 -- source order. ts must be stamped BEFORE the pid is written: a holder killed
# between the two writes must still leave a lock that carries an age.
_lk0a=$(grep -n -F '    _lock_ts' "$P5/lib/xctl-lock.sh" | head -1 | cut -d: -f1)
# literal shipped source: expanding $$/$LOCK would search for the HARNESS's own pid and
# lock path instead of xctl-lock.sh's text, and the bar would read 0 and go green.
# shellcheck disable=SC2016
_lk0b=$(grep -n -F 'echo "$$" > "$LOCK/pid"' "$P5/lib/xctl-lock.sh" | head -1 | cut -d: -f1)
if [ -n "$_lk0a" ] && [ -n "$_lk0b" ] && [ "$_lk0a" -lt "$_lk0b" ]; then _lk0=yes; else _lk0=no; fi
asrt "LK-0 take_lock stamps \$LOCK/ts BEFORE it writes \$LOCK/pid (${_lk0a:-?}<${_lk0b:-?})" "$_lk0" yes

# LK-2 -- `stat` is GONE from the shipped lock path, not made conditional. The grep is
# the load-bearing half: `stat` is a busybox APPLET, so a standalone busybox ash never
# consults PATH for it and "run it with no stat on PATH" would prove nothing. Comments
# are stripped first -- the WHY block above take_lock names `stat -c %Y` on purpose.
_lk2=$(sed 's/#.*//' "$P5/lib/xctl-lock.sh" | grep -c 'stat')
asrt "LK-2 no \`stat\` call left in xctl-lock.sh code (comments stripped)" "$_lk2" 0

# LK-1 -- THE UNIT'S PURPOSE. A holder whose pid is LIVE (i.e. re-issued to some other
# process) but whose stamp is older than the 900s backstop must be broken. The stamp is
# built from the REAL /proc/uptime, so a missing fraction-strip reds this rather than
# hiding behind an injected integer.
#
# The observable is the FEEDER, not `node`. MEASURED, not assumed: with the pre-U117
# AGE=0 seeded back in, the lock is NOT broken and yet `node` still answers `engaged`,
# because node derives engagement from the rc fact that `bctl on` has already written
# (probe under the seed: ep=203.0.113.9:51820 running=0 enabled=1 node=engaged
# lock=yes). A `node`-based bar here would pass on the defective build.
setup; bctl on; fact running.p5-datapath 0        # engaged, then the feeder dies
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"   # LIVE pid = reused
mono_fix
lock_ts $(( $(mono_now) - 1000 ))                                 # aged > REUSE_MAX 900
# LK-12 -- this fixture's own precondition, ASSERTED rather than assumed: the stamp
# just built must be a positive monotonic second. Without it a timebase too small
# to express the age turns LK-1 red and turns its NEGATIVE CONTROL vacuously green,
# which is exactly how it went unnoticed until a merge on a freshly booted host.
_lk6=$(cut -d' ' -f1 "$WORK/run/p5/lock/ts")
case "$_lk6" in ''|*[!0-9]*) _lk6ok=no ;; *) if [ "$_lk6" -gt 0 ]; then _lk6ok=yes; else _lk6ok=no; fi ;; esac
asrt "LK-12 the age fixtures' timebase expresses a 1000s-old stamp (ts=$_lk6)" "$_lk6ok" yes
xctl reconcile >>"$WORK/ledger" 2>&1
mono_unfix
asrt "LK-1 reused-pid holder aged>900s: lock broken, reconcile ran" "$(running p5-datapath)" 1
asrt "LK-1 and the reconcile released its own lock"                "$(lockd)" no
# ... and its negative control, without which LK-1 passes on a build that breaks every
# lock: the SAME live holder with a stamp INSIDE the backstop is still respected.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"
mono_fix
lock_ts $(( $(mono_now) - 400 ))                                  # aged, but < REUSE_MAX
xctl reconcile >>"$WORK/ledger" 2>&1
mono_unfix
asrt "LK-1 control: live holder aged 400s (< REUSE_MAX): NOT broken" "$(running p5-datapath)" 0
asrt "LK-1 control: and its lock is still there"                    "$(lockd)" yes
rm -rf "$WORK/run/p5/lock" 2>/dev/null

# LK-3 -- NO CLOCK AT ALL (S10): $P5_MONO_SRC denied. Every contended pass is UNKNOWN,
# so the backstop must terminate by COUNTING, not timing -- but MF-3 rules the unknown
# branch exactly as it rules the known one: LIVENESS IS CONSULTED FIRST, and the SHORT
# limit may never break a LIVE holder. This is the fix-round bar. The first cut of this
# unit set STALE=1 on the UNKNOWN_MAX'th pass BEFORE looking at the holder, so a live
# holder ~30s into a legit 6-8 min engage hold was broken -> two concurrent DAG walks,
# the catastrophic direction. Every pass here must SKIP.
unk() { cut -d' ' -f"$1" "$WORK/run/p5/lock_unknown" 2>/dev/null; }
setup; bctl on; fact running.p5-datapath 0        # feeder down: a reconcile must restart it
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"   # LIVE holder, NO ts
export P5_MONO_SRC="$WORK/no-such-clock"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-3 no clock, pass 1: SKIPPED (live holder respected)" "$(running p5-datapath)" 0
asrt "LK-3 no clock, pass 1: lock NOT removed"                "$(lockd)" yes
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-3 no clock, pass 2: still SKIPPED"                   "$(running p5-datapath)" 0
asrt "LK-3 no clock, pass 2: lock NOT removed"                "$(lockd)" yes
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-3 no clock, pass 3 (the old UNKNOWN_MAX): LIVE holder STILL respected (MF-3)" \
     "$(running p5-datapath)" 0
asrt "LK-3 no clock, pass 3: lock NOT removed"                "$(lockd)" yes
asrt "LK-3 the counter is keyed to the holder pid"            "$(unk 1)" "$$"
asrt "LK-3 and it counted all three contended passes"         "$(unk 2)" 3

# LK-6 -- the counter is cleared by a successful acquire. The holder releases (the lock
# dir goes) and the next pass takes the lock for real.
rm -rf "$WORK/run/p5/lock" 2>/dev/null
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-6 holder released: the acquire succeeds and the reconcile ran" "$(running p5-datapath)" 1
asrt "LK-6 lock_unknown cleared by the successful acquire" \
     "$(if [ -e "$WORK/run/p5/lock_unknown" ]; then echo yes; else echo no; fi)" no

# LK-8 -- and it STILL TERMINATES with no clock at all: the pass count is the clock-free
# analogue of REUSE_MAX (UNKNOWN_LIVE_MAX=90 passes ~ 900s at bond-watchdog CYCLE=10),
# so a holder that merely LOOKS live forever (a re-issued pid) is broken there and only
# there. Seeded one pass below the limit so the SHIPPED constant is what is under test,
# not a harness override; the pass at 89 is the negative control.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"   # LIVE (= reused) pid
export P5_MONO_SRC="$WORK/no-such-clock"
echo "$$ 88" > "$WORK/run/p5/lock_unknown"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-8 control: live holder at pass 89 of UNKNOWN_LIVE_MAX 90: NOT broken" \
     "$(running p5-datapath)" 0
asrt "LK-8 control: the counter advanced to 89"               "$(unk 2)" 89
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-8 pass 90 = UNKNOWN_LIVE_MAX: clock-free reuse backstop broke it, reconcile ran" \
     "$(running p5-datapath)" 1

# LK-9 -- the count is KEYED to the holder pid, so a lock handed from one holder to the
# next restarts it. Without the key, passes spent contending a previous holder would
# count the new one out immediately -- the same live-holder break by another route.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"   # LIVE holder
export P5_MONO_SRC="$WORK/no-such-clock"
echo "999999 89" > "$WORK/run/p5/lock_unknown"                    # a PREVIOUS holder's count
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-9 a previous holder's count is not inherited: live holder NOT broken" \
     "$(running p5-datapath)" 0
asrt "LK-9 and the count restarted at 1"                      "$(unk 2)" 1

# LK-10 -- holder ABSENT (a kill inside the mkdir->write window) with no clock: the
# short limit is the clock-free analogue of HOLD_MAX (12 passes ~ 120s at CYCLE=10),
# and there is no liveness to protect, so this is where the count-out belongs.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"                                      # NO pid, NO ts
export P5_MONO_SRC="$WORK/no-such-clock"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-10 no holder recorded, no clock, pass 1: not broken yet" "$(running p5-datapath)" 0
asrt "LK-10 pass 1: lock NOT removed"                            "$(lockd)" yes
asrt "LK-10 the counter records the ABSENT holder as '-'"        "$(unk 1)" "-"
echo "- 11" > "$WORK/run/p5/lock_unknown"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-10 pass 12 = UNKNOWN_MAX: counted out, reconcile ran"   "$(running p5-datapath)" 1

# LK-11 -- no clock + a DEAD holder: liveness alone reaps on pass 1, no counting.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo 999999 > "$WORK/run/p5/lock/pid"   # DEAD pid, NO ts
export P5_MONO_SRC="$WORK/no-such-clock"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-11 no clock + DEAD holder: reaped on pass 1, reconcile ran" "$(running p5-datapath)" 1
unset P5_MONO_SRC

# LK-4 -- an UNPARSEABLE ts (S7: a short write on a full tmpfs) is neither 0 nor huge.
# With a DEAD holder, liveness alone still reaps on pass 1.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; printf 'x y\n' > "$WORK/run/p5/lock/ts"
echo 999999 > "$WORK/run/p5/lock/pid"                              # DEAD pid
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-4 unparseable ts + DEAD holder: reaped on pass 1" "$(running p5-datapath)" 1
# ... and its negative control: the same unparseable ts with a LIVE holder is respected.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; printf 'x y\n' > "$WORK/run/p5/lock/ts"
echo $$ > "$WORK/run/p5/lock/pid"                                  # LIVE holder
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-4 control: unparseable ts + LIVE holder: skipped on pass 1" "$(running p5-datapath)" 0
rm -rf "$WORK/run/p5/lock" 2>/dev/null

# LK-5 -- a stamp in the FUTURE (S9: the source moved backwards, or is not the source
# assumed). A negative age must be UNKNOWN, never clamped to 0 and never read as huge:
# pass 1 must SKIP a live holder (the safe direction stays safe), and the COUNT -- not
# the clock -- must still terminate at UNKNOWN_MAX.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"
lock_ts $(( $(mono_now) + 5000 ))                                  # NOW_MONO < TS_MONO
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-5 backwards clock, pass 1: live holder NOT broken" "$(running p5-datapath)" 0
asrt "LK-5 backwards clock, pass 1: lock NOT removed"       "$(lockd)" yes
xctl reconcile >>"$WORK/ledger" 2>&1
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-5 backwards clock, pass 3: LIVE holder still respected (MF-3)" "$(running p5-datapath)" 0
asrt "LK-5 backwards clock, pass 3: lock NOT removed"                   "$(lockd)" yes
# ... and a backwards clock still TERMINATES: the same clock-free reuse backstop.
echo "$$ 89" > "$WORK/run/p5/lock_unknown"
xctl reconcile >>"$WORK/ledger" 2>&1
asrt "LK-5 backwards clock, pass 90: counted out by UNKNOWN_LIVE_MAX, reconcile ran" \
     "$(running p5-datapath)" 1
rm -rf "$WORK/run/p5/lock" 2>/dev/null

# LK-7 -- $RUN_DIR unwritable for the counter (a full or read-only tmpfs): the counter
# sticks, so the backstop degrades to pre-U117 behaviour. That is accepted; a crash or a
# loop is not. Made uid-independent by putting a DIRECTORY where the counter file goes --
# root cannot write that either, where a chmod would not stop root.
setup; bctl on; fact running.p5-datapath 0
mkdir -p "$WORK/run/p5/lock"; echo $$ > "$WORK/run/p5/lock/pid"    # LIVE holder, NO ts
mkdir -p "$WORK/run/p5/lock_unknown"                               # counter unwritable
_lk7rc=0; _lk7i=0
while [ "$_lk7i" -lt 4 ]; do
    xctl reconcile >>"$WORK/ledger" 2>&1 || _lk7rc=$?
    _lk7i=$((_lk7i + 1))
done
asrt "LK-7 counter unwritable: reconcile still exits cleanly" "$_lk7rc" 0
asrt "LK-7 counter unwritable: live holder still respected"   "$(running p5-datapath)" 0
rm -rf "$WORK/run/p5/lock" "$WORK/run/p5/lock_unknown" 2>/dev/null

# F10 — coexistence: GL VPN-manager co-writer rewrites endpoint to direct; the
# 97-bond hook re-heals to local (I2), never a dead state. NO-BOUNCE (effect-
# idempotency, the drift-gated BLOCKER-1 class): the heal is a DELTA (ep != LOCAL) so
# converged() does NOT short-circuit -- the engage edge IS walked -- but because the
# CONFIG did not move, the per-leaf idempotency must keep it a no-bounce heal:
# act_agg_restart is an ensure-running no-op (U125: agg_env still matches
# agg_env.applied + the feeder up; it was the agg_env_changed crumb before that)
# and verify_agg takes its ep==LOCAL_AGG fast-path after ep_agg re-pins
# (no iptables silence-window). Teeth: FAILS against the leaf-deleted commit
# (+1 feeder restart, iptables 2->4); PASSES only with the crumb-guard + fast-path.
setup; bctl on; fact ep "203.0.113.9:51820"   # co-writer reset
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
hook
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F10 co-writer re-heal: endpoint" "$(epv)" "127.0.0.1:59402"
asrt "F10 co-writer re-heal: node"     "$(node)" engaged
asrt "F10 co-writer re-heal: ZERO feeder restarts (no datapath bounce)" "$R1" "$R0"
asrt "F10 co-writer re-heal: no iptables silence-window (fast-path verify)" "$IPT1" "$IPT0"

# F11 — OFF stays off across a co-writer rewrite + REAL 97-bond hotplug hook
# (I1: the hook is silent while the feeder is rc-disabled — the guard, not luck).
setup; bctl on; bctl off; fact ep "203.0.113.9:51820"; hook_hotplug
asrt "F11 OFF stable under co-writer+hotplug: node" "$(node)" off
asrt "F11 OFF stable under co-writer+hotplug: endpoint" "$(epv)" "203.0.113.9:51820"

# F12 — REAL 97-bond re-engages when the feeder IS rc-enabled (wrong-iface = silent)
setup; bctl on; fact ep "203.0.113.9:51820"
INTERFACE=wan0 ACTION=ifup sh "$P5/97-bond" 2>/dev/null       # wrong iface -> silent
asrt "F12 hotplug wrong-iface: endpoint unchanged" "$(epv)" "203.0.113.9:51820"

# F13 (MF-2) — SPEED pinned across a co-writer wg_ifup hook + a watchdog tick, with
# NO oscillation. The deployed 97-bond fired `engage` mode-blindly (engarde stayed
# enabled in speed), tearing speed down on every wg ifup -> hook<->watchdog fight ->
# capped black-hole. Under the reconciler BOTH the hook and the watchdog funnel to
# reconcile(), which re-derives the mode from the stored fact, so the box stays
# pinned in speed every cycle (feeder up, AGG_SCHED=speed, ep :59402).
setup; bctl on; bctl mode speed
osc_ok=1; i=1
while [ "$i" -le 3 ]; do
    fact ep "203.0.113.9:51820"          # GL co-writer knocks the endpoint to direct
    hook                                  # 97-bond -> reconcile (mode-blind, must keep speed)
    runw                                  # periodic watchdog reconcile
    [ "$(cat "$WORK/etc/p5/mode")" = speed ] && [ "$(running p5-datapath)" = 1 ] \
        && [ "$(aggf AGG_SCHED)" = speed ] && [ "$(epv)" = "127.0.0.1:59402" ] || osc_ok=0
    i=$((i+1))
done
if [ "$osc_ok" = 1 ]; then
    ok "F13 MF-2 speed pinned across wg_ifup x watchdog (no oscillation, INV1)"
else
    no "F13 MF-2 speed oscillated (mode=$(cat "$WORK/etc/p5/mode") agg=$(running p5-datapath) sched=$(aggf AGG_SCHED) ep=$(epv))"
fi

# F14 (reboot-in-speed) — the boot-time DUAL-FEEDER window is CLOSED BY
# CONSTRUCTION since U141 (spec §9-risk-4): an aggregating box used to leave
# engarde rc-enabled as well, so rc.d started both at boot and the first reconcile
# had to collapse them. There is one service to enable now, so the bar asserts
# what remains checkable and is still worth checking: after a reboot the box comes
# back on the feeder, pinned to the mode it had, with the endpoint re-established
# (wg came up DIRECT and the first reconcile must move it back).
setup; bctl on; bctl mode speed
reboot                                    # rc.d starts the enabled feeder; wg up direct
runw                                      # first watchdog reconcile after boot
asrt "F14 reboot-in-speed: endpoint re-established on the feeder" "$(epv)" "127.0.0.1:59402"
asrt "F14 reboot-in-speed: AGG_SCHED still speed" "$(aggf AGG_SCHED)" speed
asrt "F14 reboot-in-speed: speed feeder up" "$(running p5-datapath)" 1
asrt "F14 reboot-in-speed: mode kept"       "$(cat "$WORK/etc/p5/mode")" speed

# F15 (MF-4) — TERM an IN-FLIGHT bond-xctl: `trap 'exit 143' INT TERM` must fire the
# EXIT trap so the process ACTUALLY exits (busybox ash otherwise resumes after a
# handled signal and keeps mutating unserialized) AND the ownership-checked EXIT trap
# releases the lock. Assert: the lock is GONE and the process is DEAD (no mutation).
# NOTE: this is the ONE scenario that uses REAL (short) wall-clock sleeps -- the engage
# dance must hold the lock long enough to be TERMed. A realbin/sleep shadows the
# logical-clock no-op sleep with short 0.2s real sleeps so bond-xctl loops in verify_agg
# (a LOOP of short children) instead of one long child, letting the trap fire promptly.
setup
mkdir -p "$WORK/realbin"
printf '#!/bin/sh\nexec /usr/bin/sleep 0.2\n' > "$WORK/realbin/sleep"; chmod +x "$WORK/realbin/sleep"
rcon                                     # desired=engaged -> reconcile walks the engage dance
fact capable 0                           # verify_agg fails -> loops all retries (wide TERM window)
PATH="$WORK/realbin:$PATH" sh "$P5/bond-xctl" reconcile >/dev/null 2>&1 & xpid=$!
w=0; while [ ! -d "$WORK/run/p5/lock" ] && [ "$w" -lt 100 ]; do /usr/bin/sleep 0.05; w=$((w+1)); done
if [ -d "$WORK/run/p5/lock" ]; then
    kill -TERM "$xpid" 2>/dev/null
    w=0; while kill -0 "$xpid" 2>/dev/null && [ "$w" -lt 100 ]; do /usr/bin/sleep 0.05; w=$((w+1)); done
    if kill -0 "$xpid" 2>/dev/null; then
        kill -KILL "$xpid" 2>/dev/null; no "F15 MF-4 TERM: process did NOT exit (trap resumed)"
    elif [ -d "$WORK/run/p5/lock" ]; then
        no "F15 MF-4 TERM: process exited but lock NOT released"
    else
        ok "F15 MF-4 TERM in-flight: process exited AND lock released"
    fi
else
    kill -KILL "$xpid" 2>/dev/null; no "F15 MF-4 TERM: engage never took the lock (setup race)"
fi

# F16 (BLOCKER-1, restart-storm) — a healthy-box watchdog tick MUST be a TRUE no-op
# in the DEFAULT mode (lightning): ZERO feeder restarts and NO iptables
# silence-window. The pre-fix engage leaves ran the config build + a restart + the
# full verify dance UNCONDITIONALLY on every 10s tick -> a restart/silence storm.
# The svc shim COUNTS restarts (the regression was previously HIDDEN because
# restart==start in the shim), so this has teeth: it FAILS against the pre-fix
# leaves and PASSES only once they are effect-idempotent (env_gen cmp-guarded,
# agg_restart ensure-running, verify_agg fast-path). F17 is the same bar under an
# AGGREGATE mode -- kept separate because the two walk different guard sets.
setup; bctl on
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F16 BLOCKER-1 healthy tick: ZERO feeder restarts (no datapath bounce)" "$R1" "$R0"
asrt "F16 BLOCKER-1 healthy tick: no iptables silence-window" "$IPT1" "$IPT0"

# F17 (BLOCKER-1, SPEED restart-storm) — the UNGUARDED path the fix was about: a healthy
# SPEED-box watchdog tick MUST be a TRUE no-op -- ZERO bond-agg restarts (no EIF datapath
# bounce) and NO new iptables. Pre-fix, a speed box's every ~10s reconcile re-ran the
# speed edge (act_agg_restart UNCONDITIONAL + act_env_gen rewrite + verify_speed dance),
# bouncing the bond-agg datapath every 10s. This has teeth: the svc-agg shim now COUNTS
# restarts, so it FAILS if the stateless converged() short-circuit is absent and PASSES
# only once a fully-at-target speed box walks NO edge.
setup; bctl on; bctl mode speed
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F17 BLOCKER-1 healthy speed tick: ZERO bond-agg restarts (no EIF bounce)" "$R1" "$R0"
asrt "F17 BLOCKER-1 healthy speed tick: no iptables silence-window" "$IPT1" "$IPT0"

# F18 (BLOCKER-1, SPEED drift-heal — the speed analogue of F10) — a GL co-writer knocks
# the SPEED box's endpoint to direct. The reconcile heal is a DELTA (ep != :59402) so
# converged() does NOT short-circuit and the speed edge IS walked -- but with agg_env
# unchanged it must be a NO-BOUNCE heal: act_agg_restart is an ensure-running no-op
# (U125: agg_env == agg_env.applied + bond-agg up) and verify_agg takes its ep==:59402
# fast-path after ep_agg re-pins. ASSERT ZERO bond-agg restarts across the heal (the
# EIF datapath must NOT bounce). Teeth: FAILS against the leaf-deleted commit (the
# unconditional act_agg_restart bounces bond-agg -> +1 restart); PASSES only with the
# restored crumb-guard on act_agg_restart + the verify_agg fast-path.
setup; bctl on; bctl mode speed; fact ep "203.0.113.9:51820"   # co-writer knocks ep direct
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
hook
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "F18 speed drift-heal: endpoint re-pinned :59402" "$(epv)" "127.0.0.1:59402"
asrt "F18 speed drift-heal: node engaged (speed)"      "$(node)" engaged
asrt "F18 speed drift-heal: still fed as speed" "$(aggf AGG_SCHED)" speed
asrt "F18 speed drift-heal: ZERO bond-agg restarts (no EIF bounce)" "$R1" "$R0"
asrt "F18 speed drift-heal: no iptables silence-window" "$IPT1" "$IPT0"

# ===========================================================================
# CR — U125 RECONCILER KILL-CONSISTENCY: a reconcile killed mid-edge must leave
# nothing that lies.
#
# BAR-NAME COLLISION, handled rather than ignored: p5/test/run.sh:1416-1463
# already owns CR-1..CR-4 (F18's E0 evidence, p5/CONTRACT.md:251-252).
# scripts/feature-status.py scopes anchors per harness, so `ecosim:CR` and
# `e0:CR` are functionally distinct; every bar below therefore begins
# "CR-N reconciler kill-consistency" so that a repo-wide `grep CR-1`
# disambiguates itself instead of returning two unrelated bars.
# ===========================================================================

# CR-1 — K1, THE KILL BETWEEN act_env_gen's `mv` AND act_agg_restart.
# The engage row runs env_gen, then agg_enable, then the restart, so an $AGG_SVC
# shim whose `enable` arm SIGKILLs the reconcile pass dies with agg_env ALREADY
# SWAPPED and the feeder UNTOUCHED: K1 exactly, deterministically, with no timing
# race and no reliance on a sleep. Pre-U125 the next reconcile compared a fresh
# build against the FILE, found them equal, and returned CONVERGED -- the crumb it
# should have read was never reached and the feeder fed traffic over the OLD mode
# FOREVER, not until the next tick. Now the next reconcile must restart EXACTLY
# ONCE, then be quiet. SEED that reddens it: restore `[ -f "$RUN_DIR/agg_env_changed" ]`
# in act_agg_restart and drop the `_same_file` term from converged()'s engaged arm
# -> the first reconcile causes ZERO restarts.
#
# THE SHIM KILLS BY THE LOCK'S PID, NOT BY $PPID, AND THAT IS THE WHOLE FIXTURE.
# U116 runs every action in a subshell, so the shim's parent is that subshell:
# `kill -9 "$PPID"` only made the ACTION fail, agg_enable is best-effort, converge
# continued, and the "killed" pass went on to bounce the feeder -- MEASURED at the
# merge as `want '1' got '2'`, a bar quietly measuring nothing. take_lock records
# the top-level `$$`, which stays the reconcile pass however many subshells deep an
# action runs, so that is the pid to kill and it survives the next change to the
# action machinery.
setup; bctl on                                   # engaged in the default mode
echo speed > "$WORK/etc/p5/mode"                 # a REAL config delta, NOT reconciled
mkdir -p "$WORK/killbin"
cat > "$WORK/killbin/svc-agg" <<'KEOF'
#!/bin/sh
if [ "$1" = enable ]; then
    _rp=$(cat "$RECON_LOCK_PID" 2>/dev/null)
    [ -n "$_rp" ] && kill -9 "$_rp" 2>/dev/null
fi
exec "$ECOSIM_BIN/svc-agg" "$@"
KEOF
chmod +x "$WORK/killbin/svc-agg"
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
ECOSIM_BIN="$BIN" RECON_LOCK_PID="$WORK/run/p5/lock/pid" \
  AGG_SVC="$WORK/killbin/svc-agg" sh "$P5/bond-xctl" reconcile >/dev/null 2>&1
RK=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "CR-1 reconciler kill-consistency: the kill landed AFTER the mv (agg_env moved to speed)" "$(aggf AGG_SCHED)" speed
asrt "CR-1 reconciler kill-consistency: ...and BEFORE the restart (the killed pass bounced nothing)" "$RK" "$R0"
hook
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
hook
R2=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "CR-1 reconciler kill-consistency: the NEXT reconcile restarts the stale feeder" "$R1" "$((R0+1))"
asrt "CR-1 reconciler kill-consistency: ...EXACTLY once, then converged and quiet" "$R2" "$R1"
if cmp -s "$WORK/etc/p5/agg_env" "$WORK/etc/p5/agg_env.applied"; then
    ok "CR-1 reconciler kill-consistency: agg_env.applied records the config the feeder is running"
else
    no "CR-1 reconciler kill-consistency: agg_env.applied != agg_env after recovery"
fi

# CR-2 — K3, the kill between the restart and the crumb's own `rm -f`. That left
# `agg_env_changed` set forever, and the NEXT genuine delta -- one that did not
# move the config at all -- then bounced the datapath on the strength of a stale
# crumb, defeating the no-bounce property F10/F18 assert. The crumb is DELETED, so
# a leftover copy of it must now be completely INERT even while an edge IS walked.
setup; bctl on
touch "$WORK/run/p5/agg_env_changed"             # the leftover a killed K3 pass left
fact ep "203.0.113.9:51820"                      # co-writer knocks ep direct -> a real DELTA
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
hook                                             # the engage edge IS walked (ep drift heal)
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "CR-2 reconciler kill-consistency: a leftover crumb + a walked edge bounces NOTHING" "$R1" "$R0"
asrt "CR-2 reconciler kill-consistency: ...and the heal still happened" "$(epv)" "127.0.0.1:59402"
asrt "CR-2 reconciler kill-consistency: no crumb reader or writer survives in CODE" \
     "$(grep -v '^[[:space:]]*#' "$P5/lib/xctl-actions.sh" | grep -c -F 'agg_env_changed')" 0

# CR-3 — K4, a SIGKILL inside the engage silence window. `BLK` was PROCESS MEMORY
# of a KERNEL rule: N killed passes stacked N DROPs on the tunnel's own source
# port, and every later pass removed NOTHING (a fresh process starts at BLK=0), so
# the port stayed dropped until reboot. unblock() now sweeps to ABSENCE from the
# EXIT trap of every pass that holds the lock -- including a pass that walks no
# edge at all, which is the case a sweep at the top of verify_agg could never
# reach (converged() does not ping, so a box carrying a leftover DROP reads as
# converged and never walks the engage edge). SEED that reddens it: restore
# `[ "$BLK" = 1 ] && iptables -D ...` -> the count stays 2, not 1.
setup; bctl on
echo 2 > "$WORK/iptrules"                        # two killed predecessors left their DROPs
hook                                             # a HEALTHY, converged tick: walks no edge
asrt "CR-3 reconciler kill-consistency: stacked DROPs from killed passes swept to absence" "$(cat "$WORK/iptrules")" 0

# CR-4 — K1', the REBOOT case, and the bar that decides the applied record's
# LOCATION empirically rather than by argument. $RUN_DIR is tmpfs and a boot wipes
# it; $BOND_DIR is persistent. After a boot procd started the feeder FROM agg_env,
# so record == file and the first post-boot reconcile must bounce NOTHING. A
# post-action FLAG, whose natural home is tmpfs, would bounce a correctly-started
# feeder on EVERY boot of EVERY box -- which is what rules that alternative out.
# SEED that reddens it: write the record under $RUN_DIR instead of $BOND_DIR.
setup; bctl on; bctl mode speed
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
rm -rf "$WORK/run/p5"; mkdir -p "$WORK/run/p5"   # tmpfs is EMPTY after the boot
reboot
runw
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "CR-4 reconciler kill-consistency: first post-boot reconcile causes ZERO feeder restarts" "$R1" "$R0"
asrt "CR-4 reconciler kill-consistency: ...and the box is back on the feeder in its mode" "$(aggf AGG_SCHED)" speed

# CR-5a — the `_same_file` FALLBACK LADDER, tier by tier. Without it a busybox
# built without `cmp` would restart the feeder on EVERY ~10s tick: under the old
# crumb the same missing `cmp` only walked an edge (the crumb still gated the
# restart), so this unit makes `cmp`'s absence strictly more expensive and owes a
# fallback. Each tier must call equal files EQUAL and call files that differ only
# in a TRAILING NEWLINE DIFFERENT -- the second half is what the byte-count term
# in tier 3 is for, since `$(cat)` strips trailing newlines from both sides.
_tier() {   # $1 = forced tier name
    sh -c '. "$1"; _SAMEFILE_TIER="$2"
           printf "a\n" > "$3/tx"; printf "a\n" > "$3/ty"; printf "a" > "$3/tz"
           if _same_file "$3/tx" "$3/ty"; then printf same; else printf DIFFER; fi
           printf " "
           if _same_file "$3/tx" "$3/tz"; then printf SAME; else printf differ; fi' \
       _ "$P5/lib/xctl-actions.sh" "$1" "$WORK"
}
setup
asrt "CR-5a reconciler kill-consistency: _same_file tier 1 (cmp) equal==equal, trailing-nl==differs"    "$(_tier cmp)"   "same differ"
asrt "CR-5a reconciler kill-consistency: _same_file tier 2 (cksum) equal==equal, trailing-nl==differs"  "$(_tier cksum)" "same differ"
asrt "CR-5a reconciler kill-consistency: _same_file tier 3 (shell) equal==equal, trailing-nl==differs"  "$(_tier shell)" "same differ"

# CR-5b — the same ladder END TO END: with `cmp` shimmed to fail, a healthy tick
# must still cause ZERO restarts, i.e. the ladder fell through to tier 2/3 rather
# than reading "unknown" as "differs" and storming. STATED rather than implied:
# under busybox's standalone shell `cmp` is an APPLET and a PATH shim cannot
# shadow it, so on the busybox arm this bar re-confirms tier 1 instead of
# exercising the fallback. CR-5a is what exercises tiers 2 and 3 on BOTH arms.
setup; bctl on
mkdir -p "$WORK/nocmp"; printf '#!/bin/sh\nexit 127\n' > "$WORK/nocmp/cmp"; chmod +x "$WORK/nocmp/cmp"
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
PATH="$WORK/nocmp:$PATH" sh "$P5/bond-xctl" reconcile >/dev/null 2>&1
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "CR-5b reconciler kill-consistency: no restart storm when cmp is unavailable" "$R1" "$R0"

# CR-6 — a converged() killed between building its desired-config temp and
# removing it leaves `.desired.cmp.<pid>`, PID-suffixed, so repeated kills
# accumulate DISTINCT files until reboot. _conf_matches sweeps the glob first.
setup; bctl on
: > "$WORK/run/p5/.desired.cmp.11111"; : > "$WORK/run/p5/.desired.cmp.22222"
hook                                             # a healthy tick reaches _conf_matches
asrt "CR-6 reconciler kill-consistency: killed-pass .desired.cmp leftovers are swept" \
     "$(find "$WORK/run/p5" -name '.desired.cmp.*' 2>/dev/null | grep -c .)" 0

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
ncsv()   { printf '%s' "$1" | tr ',' '\n' | grep -c .; }
# nrouted: the number of DISTINCT routed l3_devices in the source table -- the
# live source set, computed independently of build_agg_env. Distinct devices, not
# rows: `wan` and `wan6` are two netifd interfaces sharing eth1, so a row count
# would over-count the sources by one.
nrouted(){ sh "$P5/bond-xctl" _sources 2>/dev/null \
             | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg {print $2}' | sort -u | grep -c .; }

# NG1 — N=3: every live source is enrolled, in metric order, primary first.
setup; fact nwan 3; bctl on; bctl mode speed
asrt "NG1 N=3 speed engaged"          "$(running p5-datapath)" 1
asrt "NG1 N=3 AGG_PATHS carries ALL 3" "$(aggf AGG_PATHS)" "eth1,usb0,eth0"
asrt "NG1 N=3 no source discarded (paths == routed sources)" "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "NG1 N=3 primary is first"       "$(aggf AGG_PATHS | cut -d, -f1)" "$(xctl _primary)"
# AGG_W is positional in bond-agg's PUSH modes (`parseW`, p4-bondagg/daemon/main.go
# -- by symbol, because the line number took four values in five days): a vector shorter than
# AGG_PATHS silently privileges the leading paths, so arity must track N. The PULL
# entry point reads no weights at all (ROADMAP U36); these bars gate what bond-xctl
# EMITS. Neither shipped stanza starts AGG_MODE=client any more (U111) -- both
# start pull-client, which logs AGG_W as IGNORED (pullrun.go, pullNoPrior) -- but
# AGG_W stays load-bearing for the retained AGG_MODE=client PUSH path, reachable
# by hand-editing agg_env's AGG_MODE.
asrt "NG1 N=3 AGG_W arity == N"       "$(ncsv "$(aggf AGG_W)")" 3
asrt "NG1 N=3 AGG_W is the neutral prior (no invented weights)" "$(aggf AGG_W)" "10000,10000,10000"
asrt "NG1 N=3 endpoint :59402"        "$(epv)" "127.0.0.1:59402"

# NG2 — N=4 (the box's real declared arity): still ALL of them, still ordered.
setup; fact nwan 4; bctl on; bctl mode speed
asrt "NG2 N=4 AGG_PATHS carries ALL 4" "$(aggf AGG_PATHS)" "eth1,usb0,eth0,wwan0"
asrt "NG2 N=4 no source discarded"     "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "NG2 N=4 AGG_W arity == N"        "$(ncsv "$(aggf AGG_W)")" 4
asrt "NG2 N=4 speed engaged (no privileged N)" "$(running p5-datapath)" 1
asrt "NG2 N=4 AGG_SCHED=speed"         "$(aggf AGG_SCHED)" speed

# NG3 — N=2 is not a special case, it is just the smallest N that aggregates.
setup; fact nwan 2; bctl on; bctl mode speed
asrt "NG3 N=2 AGG_PATHS"       "$(aggf AGG_PATHS)" "eth1,usb0"
asrt "NG3 N=2 AGG_W arity == N" "$(ncsv "$(aggf AGG_W)")" 2

# NG4 — arity FLOOR, per-mode guard (U141). `sources_for_mode` asks THIS mode's
# floor of the set THIS mode enrols: 2 for an aggregate mode, 1 otherwise. N=1
# refuses `speed`, N=3/N=4 above pass identically, and `eco` at N=1 is not
# refused at all -- which is exactly why `enough_sources` could not stay.
setup; fact nwan 1; bctl on; bctl mode eco; bctl mode speed
asrt "NG4 N=1 speed refused, mode kept" "$(cat "$WORK/etc/p5/mode")" eco
asrt "NG4 N=1 eco is NOT refused: the feeder runs at N=1" "$(running p5-datapath)" 1
asrt "NG4 N=1 and it runs the eco scheduler" "$(aggf AGG_SCHED)" eco
# Read the guard FIELD and match the token EXACTLY, rather than anchoring on
# the field terminator: `^engage|.*,sources_for_mode|` said "the guard list ENDS
# with this token", which was never the claim and went red the moment U208 added
# a guard after it. Field-exact is the stronger test and it is order-independent.
if awk -F'|' '!/^#/ && NF>=8 && $1=="engage"{print $4}' "$P5/bond.dag"      | tr ',' '
' | grep -qx 'sources_for_mode'; then
  ok "NG4 bond.dag engage guard is spelled sources_for_mode (not enough_sources)"
else
  no "NG4 bond.dag engage guard is not sources_for_mode"
fi

# NG5 — applied_wans (act_env_gen's operator-facing twin of AGG_PATHS) is N-generic too,
# and eco selects the primary ONLY at any N (mode selection must not depend on N).
setup; fact nwan 3; bctl on
asrt "NG5 N=3 lightning applied_wans carries ALL 3" \
     "$(cat "$WORK/etc/p5/applied_wans")" "eth1 usb0 eth0"
bctl mode eco
asrt "NG5 N=3 eco applied_wans is the primary ONLY" \
     "$(cat "$WORK/etc/p5/applied_wans")" "eth1"

# NG6 — a STALE operator agg_w must not be bound POSITIONALLY to the wrong paths.
# `20000,15000` (the old hardcoded pair) on a 3-source box would give paths 1-2
# invented weights and path 3 whatever bond-agg defaults to. Arity mismatch ->
# refuse the file, fall back to the neutral prior. A correctly-sized file IS used.
setup; fact nwan 3; echo "20000,15000" > "$WORK/etc/p5/agg_w"; bctl on; bctl mode speed
asrt "NG6 stale 2-entry agg_w on a 3-source box is REFUSED" "$(aggf AGG_W)" "10000,10000,10000"
setup; fact nwan 3; echo "7,8,9" > "$WORK/etc/p5/agg_w"; bctl on; bctl mode speed
asrt "NG6 correctly-sized operator agg_w IS honoured" "$(aggf AGG_W)" "7,8,9"

# NG7 — the N=3 build is STABLE: a healthy speed tick at N=3 must still be a
# no-op. converged() cmp's a FRESH build_agg_env against the live agg_env, so a
# non-deterministically ORDERED builder (e.g. one whose source order depends on
# `ubus list` ordering) would churn agg_env and bounce the EIF datapath every
# tick. Zero bond-agg restarts is the ordering-determinism bar.
setup; fact nwan 3; bctl on; bctl mode speed
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
E0=$(aggenv); runw; runw
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "NG7 N=3 healthy tick: ZERO bond-agg restarts (build is order-stable)" "$R1" "$R0"
asrt "NG7 N=3 agg_env unchanged across ticks" "$(aggenv)" "$E0"

# =======================================================================
# EG — P5's DAG DOES NOT DEPEND ON THE ENGARDE BINARY (U50a)
#
# Mo's decision, docs/ROADMAP.md "U50 DECIDED by Mo (2026-08-30)". Before this
# unit bond-xctl guard_installed() was `[ -x "$ENGARDE_BIN" ] && [ -d "$BOND_DIR" ]`
# and bond.dag put `installed` on the engage, disengage, switch AND speed rows,
# so P5's own DAG could not reach `engaged` or `speed` without P2's binary.
#
# HOW THESE BARS ARE MADE TO BITE: `rm` the harness's fake engarde-client, so
# `[ -x "$ENGARDE_BIN" ]` is FALSE while everything else is unchanged. On the
# pre-U50a artifact every EG bar below that walks an edge goes RED.
#
# SCOPE — read this before quoting a green EG bar. It measures P5's DEPENDENCY
# on the binary, in the harness. It does NOT say engarde is gone from the box:
# the client still carries /usr/sbin/engarde-client and the production tunnel
# still runs through it at 127.0.0.1:59401
# (docs/knowledge/inventory/2026-08-30-client-flint2.txt). On today's client
# the binary is present and no edge outcome changes.
noeng() { rm -f "$WORK/fakebin/engarde-client"; }

# EG-1 — the aggregate engage. It already carried its OWN `agg_installed` guard
# and none of its actions called engarde, so gating it on engarde-client was a
# plain defect. With the binary gone, speed must still fully engage. Since U141
# the row it walks is the ONE `engage` row.
setup; noeng; fact nwan 3; bctl on; bctl mode speed
asrt "EG-1 speed engages with NO engarde binary: bond-agg up"  "$(running p5-datapath)" 1
asrt "EG-1 speed with NO engarde binary: mode fact is speed"   "$(cat "$WORK/etc/p5/mode")" speed
asrt "EG-1 speed with NO engarde binary: endpoint :59402"      "$(epv)" "127.0.0.1:59402"
asrt "EG-1 speed with NO engarde binary: node (speed is a MODE, reported engaged)" "$(node)" engaged
asrt "EG-1 speed with NO engarde binary: AGG_SCHED=speed"      "$(aggf AGG_SCHED)" speed
asrt "EG-1 speed with NO engarde binary: AGG_PATHS still carries ALL 3" \
     "$(aggf AGG_PATHS)" "eth1,usb0,eth0"

# EG-2 — GAP CLOSED BY U141, and the bar is FLIPPED rather than deleted, exactly
# as the U50a text said U50b would have to. It used to record this: the engaged/off
# DISCRIMINATOR was engarde's rc.d enable flag (`svc_enabled "$SVC"` in desired()
# and node(), SVC=/etc/init.d/engarde-client), so a `mode speed` on an `off` box
# wrote the mode fact and converged to off -- a SECOND, deeper engarde dependency
# than the guard U50a removed, and a state-model change nobody had signed off.
# U141 moved that flag onto bond-agg's own init script, which is P5's, and U114
# then took desired() off the flag entirely: desired() now reads the STORED fact
# $BOND_DIR/rc, and the feeder's rc.d flag is left as the MECHANISM that node()
# observes and that rc.d consults at boot. `bondctl mode speed` on an OFF box
# therefore STILL does not engage -- and now for the right reason, which the
# second bar states: `mode` writes the mode fact, `on` writes the rc fact, and
# the two are separate by design (desired() is off while $BOND_DIR/rc is
# absent). What changed is that no engarde artifact is consulted at all: `bctl
# on` alone, with no engarde present anywhere, reaches `engaged` -- the third bar.
setup; noeng; fact nwan 3; bctl mode speed
asrt "EG-2 mode-without-on still does not engage (rc and mode are separate facts)" \
     "$(running p5-datapath)" 0
asrt "EG-2 mode from OFF: the mode fact IS written, the box stays direct" \
     "$(cat "$WORK/etc/p5/mode")|$(epv)" "speed|203.0.113.9:51820"
bctl on
asrt "EG-2 [CLOSED] and 'on' then engages it with NO engarde anywhere -- the rc fact is P5's own" \
     "$(running p5-datapath)|$(node)|$(aggf AGG_SCHED)" "1|engaged|speed"

# EG-3 — the disengage row. Its actions (agg_stop, agg_disable, mtu_1420,
# ep_direct, clear_susp, shape_apply) are init.d verbs, an MTU write and an
# endpoint write; none of them builds a config. So teardown must work with no
# engarde binary.
setup; noeng; fact nwan 3; bctl on; bctl mode speed; bctl off
asrt "EG-3 disengage with NO engarde binary: node"      "$(node)" off
asrt "EG-3 disengage with NO engarde binary: endpoint"  "$(epv)" "203.0.113.9:51820"
asrt "EG-3 disengage with NO engarde binary: no feeder" "$(running p5-datapath)" 0

# EG-4 — the STRUCTURAL bar: the shipped guard must not name the binary. This
# is the one that goes red on a tree that merely behaves right by accident, and
# it is the pre-change tripwire (pre-U50a ffd5857:bond-xctl:736 matched ENGARDE_BIN;
# the rev is pinned because that line no longer exists in this tree).
if grep -n '^guard_installed()' "$P5/lib/xctl-dag.sh" | grep -q 'ENGARDE_BIN'; then
    no "EG-4 guard_installed still requires ENGARDE_BIN (P5 depends on P2's binary)"
else
    ok "EG-4 guard_installed does NOT name ENGARDE_BIN (P5's own precondition only)"
fi
# The lifecycle rows that carry `installed` must still carry it -- U50a changed
# the guard's MEANING, not the table. A row that quietly LOST its guard would drop
# the BOND_DIR precondition too, which is a different defect, not this fix.
# THREE, not four, since U141: the aggregate row was folded into `engage`, so the
# fourth row it counted no longer exists. The count is read off the SHIPPED table,
# so a fold that dropped the guard from a surviving row still goes red here.
_eg_rows=$(awk -F'|' '/^(engage|disengage|switch)\|/ && $4 ~ /(^|,)installed(,|$)/ {c++} END{print c+0}' "$P5/bond.dag")
asrt "EG-4 engage/disengage/switch all still carry the installed guard" "$_eg_rows" 3

# EG-5 — THE GAP, FLIPPED. It used to record the U50b hole exactly: with no
# engarde binary, `bctl on` in the default mode ran genconf -> build_engarde_conf,
# which `fail`s without the binary, so the process exited MID-EDGE (after rc_on,
# before eng_restart and ep_local). No feeder ran, the endpoint never left DIRECT,
# and node() nonetheless reported `engaged` off the rc flag -- an engaged box with
# nothing feeding the tunnel. U141 gave those modes a feeder, so all three
# assertions invert: the feeder RUNS, the endpoint reaches :59402, and `engaged`
# means engaged. The bar is flipped, not deleted, which is what the U50a text said
# U50b would owe.
setup; noeng; bctl on
asrt "EG-5 [CLOSED by U141] engage with NO engarde binary leaves the FEEDER RUNNING" \
     "$(running p5-datapath)" 1
asrt "EG-5 [CLOSED] and the endpoint reaches the feeder (no aborted edge)" \
     "$(epv)" "127.0.0.1:59402"
asrt "EG-5 [CLOSED] node() reports engaged AND something is feeding the tunnel" \
     "$(node)|$(aggf AGG_SCHED)" "engaged|lightning"

# EG-6 — THE GENUINELY STANDALONE BOX: no $BOND_DIR at all.
#
# This is the bar U50a's first round did not have, and its absence is why the
# unit could claim the engarde dependency was gone while it had only moved. The
# guard left behind was `[ -d "$BOND_DIR" ]` = /etc/p5, and the ONLY creator of
# that directory anywhere in the repo is p2-engarde/bootstrap-bond.sh (`grep -rn
# mkdir deploy/p5/` finds RUN_DIR and the lock dir, nothing else). Every scenario
# above is blind to it because `setup` makes the directory itself -- so on a box
# where E7 removed the old stack, all four `installed` edges refused exactly as
# they had before, and no bar could see it.
#
# HOW THIS ONE BITES: delete $BOND_DIR after setup, which is the state of a box
# that never ran P2's bootstrap. On the pre-fix artifacts `bondctl on` exits 1 at
# need() and the box stays `off`; on this tree bond-xctl mkfacts() / bondctl
# need() create the directory and the lifecycle proceeds.
setup; rm -rf "$WORK/etc/p5"; bctl on
asrt "EG-6 standalone box (no BOND_DIR): P5 creates its own fact directory" \
     "$( [ -d "$WORK/etc/p5" ] && echo 1 || echo 0 )" 1
asrt "EG-6 standalone box: engage still reaches engaged" "$(node)" engaged
asrt "EG-6 standalone box: endpoint local"               "$(epv)" "127.0.0.1:59402"
asrt "EG-6 standalone box: the feeder is up"             "$(running p5-datapath)" 1
# and the speed edge, which carries the same `installed` guard, from the same start
setup; rm -rf "$WORK/etc/p5"; fact nwan 3; bctl on; bctl mode speed
asrt "EG-6 standalone box: the aggregate mode engages too (same guard, same row)" "$(aggf AGG_SCHED)" speed
asrt "EG-6 standalone box: speed endpoint :59402" "$(epv)" "127.0.0.1:59402"
asrt "EG-6 standalone box: AGG_PATHS written into the created dir" \
     "$(aggf AGG_PATHS)" "eth1,usb0,eth0"
# EG-6 STRUCTURAL — deploy/p5 must itself contain a creator for $BOND_DIR, AND
# must call it. The behavioural bars above would also go green if some unrelated
# code path happened to make the directory; this one goes red the moment P5 stops
# owning it.
#
# The "AND must call it" half was added after measurement, not by inspection: the
# first version of this bar counted the mkdir literal only, and on the pre-fix
# control tree (mkfacts() defined but its call site removed, bondctl need()
# reverted) it stayed GREEN while all seven behavioural EG-6 bars went red. A
# structural bar that a dead definition satisfies is checking spelling, not
# ownership. `mkfacts` must therefore appear at least TWICE in bond-xctl --
# defined once and called once -- and bondctl must carry its own mkdir, because
# it does not take bond-xctl's lock and so never reaches mkfacts.
#
# Round 3 (review) tightened the count to CODE lines only (lines that BEGIN with
# mkfacts, optionally indented: the definition and the call). A bare
# `grep -c mkfacts` counted the COMMENT mentions too (5 on this tree), so the
# dead-definition control -- call site deleted, comments kept -- still satisfied
# the >=2 threshold and only the behavioural bars went red. Comment lines start
# with '#', so they cannot match this pattern.
_eg6_def=$(grep -cE '^[[:space:]]*mkfacts' "$P5/lib/xctl-lock.sh")
# literal shipped source: expanding $BOND_DIR would grep bondctl for the fixture path,
# match nothing, and the EG-6 guard would read 0 -- green for the wrong reason.
# shellcheck disable=SC2016
_eg6_cli=$(grep -c -F 'mkdir -p "$BOND_DIR"' "$P5/bondctl")
if [ "$_eg6_def" -ge 2 ] && [ "$_eg6_cli" -ge 1 ]; then
    ok "EG-6 deploy/p5 creates \$BOND_DIR itself and calls the creator (bond-xctl mkfacts x$_eg6_def, bondctl mkdir x$_eg6_cli)"
else
    no "EG-6 nothing in deploy/p5 creates \$BOND_DIR on the live path (bond-xctl mkfacts x$_eg6_def, bondctl mkdir x$_eg6_cli) -- the guard depends on p2-engarde/bootstrap-bond.sh again"
fi

# =======================================================================
# EL -- EVERY BONDED MODE IS FED, FROM ONE EDGE, WITH NO ENGARDE (U141)
#
# U119's resolution (ADR-003 status update 2026-09-02): all five ADR-003
# positions ship, and every bonded one is fed by `bond-agg` (pull-client,
# 127.0.0.1:59402, MTU 1408) from ONE `engage` row. Before U141 the
# engage/switch rows ran engarde leaves and bond-agg started only from a
# separate `agg` row under `enough_sources`, so on a purged (U26) client
# `eco` and `lightning` were modes with nothing behind them -- the gap U50b
# measured as G-5/G-6 and Layer-1 could not see, because the model has no
# shell-control-flow boundary to represent an aborted edge.
#
# These four bars are what "the feeder reaches every mode" means EXECUTABLY.
# EG-* above measure P5's DEPENDENCY on the engarde binary; these measure the
# MECHANISM that replaced it.
# =======================================================================

# EL-1 -- every bonded mode reaches a RUNNING feeder from the ONE engage row,
# at the arity that mode is defined at. This is the bar the per-mode guard
# exists for: `eco` is DEFINED at N=1 (the primary only) and `lightning` at
# N=1 is degenerate-but-running (the daemon's own rule, U138), while `max` and
# `speed` need MIN_AGG_SOURCES. A single `enough_sources` guard cannot express
# that -- it refuses eco and lightning on a box down to its last source, which
# is exactly the box that most needs a bonded mode to still work.
for _m in eco lightning; do
    setup; fact nwan 1; bctl on; bctl mode "$_m"
    asrt "EL-1 N=1 $_m: the ONE feeder is running"   "$(running p5-datapath)" 1
    asrt "EL-1 N=1 $_m: endpoint is the feeder's"    "$(epv)" "127.0.0.1:59402"
    asrt "EL-1 N=1 $_m: AGG_SCHED names the mode"    "$(aggf AGG_SCHED)" "$_m"
    asrt "EL-1 N=1 $_m: node engaged"                "$(node)" engaged
done
# ...and at N=3 all four positions engage, each with its OWN scheduler. eco
# still enrols the primary only; the other three enrol every live source.
for _m in eco lightning max speed; do
    setup; fact nwan 3; bctl on; bctl mode "$_m"
    asrt "EL-1 N=3 $_m: the ONE feeder is running"   "$(running p5-datapath)" 1
    asrt "EL-1 N=3 $_m: AGG_SCHED names the mode"    "$(aggf AGG_SCHED)" "$_m"
    if [ "$_m" = eco ]; then _want="eth1"; else _want="eth1,usb0,eth0"; fi
    asrt "EL-1 N=3 $_m: enrolled set follows the mode" "$(aggf AGG_PATHS)" "$_want"
done
# ...and the aggregate modes, and ONLY they, are refused below MIN_AGG_SOURCES.
for _m in max speed; do
    setup; fact nwan 1; bctl on; bctl mode "$_m"
    asrt "EL-1 N=1 $_m: refused (aggregation needs >1 source), prior mode kept" \
         "$(cat "$WORK/etc/p5/mode")" lightning
done

# EL-2 -- THE NO-ENGARDE-PRESENT BAR. A purged client (U26/E7 has removed the
# old stack) has no engarde binary and no engarde init script. Every bonded
# mode must still reach a running feeder there, because nothing on either half
# of the reconciler pair consults engarde any more: desired() reads the stored
# fact $BOND_DIR/rc (U114) and node() reads bond-agg's own rc.d flag (U141).
# This is the bar that goes RED if desired()/node() fall back to engarde's
# service.
noeng_all() {
    rm -f "$WORK/fakebin/engarde-client"        # E7 removed the binary
    rm -f "$WORK/enabled.engarde-client" "$WORK/running.engarde-client"
    unset ENGARDE_BIN                            # nothing left to point at
}
for _m in eco lightning speed; do
    setup; fact nwan 3; noeng_all; bctl on; bctl mode "$_m"
    asrt "EL-2 purged box, $_m: node engaged"        "$(node)" engaged
    asrt "EL-2 purged box, $_m: feeder running"      "$(running p5-datapath)" 1
    asrt "EL-2 purged box, $_m: endpoint :59402"     "$(epv)" "127.0.0.1:59402"
    asrt "EL-2 purged box, $_m: AGG_SCHED=$_m"       "$(aggf AGG_SCHED)" "$_m"
done
# and the whole lifecycle round-trips there too: off tears down to direct.
setup; fact nwan 3; noeng_all; bctl on; bctl off
asrt "EL-2 purged box: off tears down to direct" "$(node)|$(running p5-datapath)|$(epv)" \
     "off|0|203.0.113.9:51820"

# EL-3 -- STRUCTURAL, read off the SHIPPED table. One lifecycle, no engarde
# leaf, no separate aggregate row. The behavioural bars above would also pass
# on a table that kept a dead `agg` row nothing selects; this one would not.
_el3_rows=$(awk -F'|' '!/^[[:space:]]*#/ && NF==8 {print $1}' "$P5/bond.dag" | sort | tr '\n' ' ')
asrt "EL-3 the shipped bond.dag is exactly the four folded rows" \
     "$_el3_rows" "disengage engage suspend switch "
_el3_eng=$(awk -F'|' '!/^[[:space:]]*#/ && NF==8 {print $5}' "$P5/bond.dag" \
           | tr ',' '\n' | grep -cE '^(genconf|genconf_if_enabled|eng_enable|eng_restart|eng_restart_if_enabled|eng_stop|eng_disable|restore_feeder|aggdown_if_agg|ep_local)$')
asrt "EL-3 no shipped row runs an engarde leaf" "$_el3_eng" 0
_el3_ver=$(awk -F'|' '!/^[[:space:]]*#/ && NF==8 && $6!="-" {print $6}' "$P5/bond.dag" | sort -u | tr '\n' ' ')
asrt "EL-3 the ONE verify left is the feeder's" "$_el3_ver" "verify_agg "
# CONTROL: the check is sensitive. Adding an engarde leaf back to a COPY of the
# table must be seen. A bar nobody has watched fail is not a bar.
_el3_tmp="$WORK/bond.dag.el3"
sed 's/^engage|\(.*\)|env_gen,/engage|\1|genconf,env_gen,/' "$P5/bond.dag" > "$_el3_tmp"
_el3_ctl=$(awk -F'|' '!/^[[:space:]]*#/ && NF==8 {print $5}' "$_el3_tmp" \
           | tr ',' '\n' | grep -cE '^(genconf|eng_enable|eng_restart|eng_stop|eng_disable)$')
if [ "$_el3_ctl" -ge 1 ]; then
    ok "EL-3 CONTROL: the leaf scan FIRES on a restored engarde leaf (the instrument is sensitive)"
else
    no "EL-3 CONTROL: the leaf scan did NOT fire on a restored engarde leaf -- it checks nothing"
fi

# EL-4 -- THE NAMED RESIDUAL, NOW CLOSED (U114), and the bar is FLIPPED rather
# than deleted, the same way U141 flipped EG-2. It used to expect EXACTLY ONE
# file: deploy/p5/bond-ecod, whose "the bond is enabled" gate defaulted to
# `/etc/init.d/engarde-client`. After U141 nothing in P5 ever enabled that
# service, so on the standalone box M1 delivers that gate was permanently false
# and the eco<->lightning auto policy never acted. U114 replaced it with the
# stored fact `[ -f "$BOND_DIR/rc" ]`, so the expected list is now EMPTY: NO
# shipped file under deploy/p5 executes engarde's init script. The bar still goes
# red both ways -- a new reader anywhere, or a revert of the bond-ecod gate.
# CODE, not prose. `grep -rlF` is file-level, so a comment that merely NAMES the
# path (deploy/p5/bond-accept:52 contrasts what it checks against
# `/etc/init.d/engarde-client enabled`) counted as a reader and reddened this bar
# on the U141 merge. Match the string only on lines that are not comments; the
# expected list is EMPTY after U114, so a real reader added to bond-accept -- or
# anywhere else -- still reddens it.
_el4=$(grep -rnF '/etc/init.d/engarde-client' "$P5" 2>/dev/null \
       | sed 's/^\([^:]*\):[0-9][0-9]*:/\1\t/' \
       | awk -F'\t' '$2 !~ /^[ \t]*#/ { print $1 }' \
       | sed "s|^$P5/||" | sort -u | tr '\n' ' ')
asrt "EL-4 [CLOSED by U114] NO shipped file under deploy/p5 executes engarde's init script" \
     "$_el4" ""

# =============================== EF-* (U114) =================================
# THE ENGAGEMENT FACT IS A FILE. Until now it was DERIVED by executing an init
# script -- engarde's before U141, the feeder's after -- and `svc_enabled`
# answers the same false for "disabled", "file missing", "not executable" and
# "no /etc/rc.common": four states collapsed into one, one of which is the box
# that needs repairing. `bondctl on|off` now writes/clears $BOND_DIR/rc
# (presence-only, the shape of $BOND_DIR/auto), desired() reads it, bond-ecod
# gates on it, and node() keeps reading the rc.d flag so the two halves of the
# reconciler pair cannot be equal by construction.

# EF-1 -- `off` clears BOTH: the fact the caller wrote and the flag the DAG set.
# A fact left behind would re-engage the box on the next tick.
setup; bctl on; bctl off
asrt "EF-1 off clears the rc FACT and the feeder's rc.d flag" \
     "$(rcf)|$(enabledf p5-datapath)" "0|0"

# EF-2 -- THE SELF-REPAIR, and the reason this unit exists. The intent stands
# but the feeder is NOT rc.d-enabled: a fresh box whose /etc/init.d/p5-datapath
# the installer has not written yet, one where the file was removed, or one
# where `enable` simply failed (`bondctl on` ran it with 2>/dev/null). While
# desired() executed that same service this state read `off`, so `disengage` was
# walked, the `engage` row -- which carries act_agg_install, the fallback that
# writes that very file -- was never selected, and `bondctl on` was a permanent
# SILENT NO-OP on exactly the box that needed it. Now the delta is visible:
# desired=engaged from the file, node=off from the flag, so the next trigger of
# ANY kind (watchdog tick, 97-bond hotplug, reboot) converges it.
setup; bctl on
fact enabled.p5-datapath 0; fact running.p5-datapath 0
asrt "EF-2 pre: the intent stands while the feeder is not enabled (node != desired)" \
     "$(rcf)|$(node)" "1|off"
hook
asrt "EF-2 one reconcile re-engages from the STORED intent (was a silent no-op)" \
     "$(node)|$(running p5-datapath)|$(enabledf p5-datapath)" "engaged|1|1"

# EF-3 -- G-3 CLOSED: the eco<->lightning auto policy runs on a PURGED box. The
# harness no longer exports SVC (see setup), and this bar goes further and points
# it at the path the shipped file used to default to, which does not exist in the
# sandbox: if bond-ecod still executed it, the gate would be false and the loop
# would `continue` forever, which is what it did on every box after U141.
setup; noeng
bctl on; fact enabled.p5-ecod 1; bctl mode eco
: > "$WORK/etc/p5/auto"                  # bctl mode cleared it; re-arm for the ecod path
echo "degraded rate=1000Bps floor=131072" > "$WORK/run/p5/tput"
fact "etc/p5/applied_wans" eth1
SVC="/etc/init.d/engarde-client"; export SVC; runecod; unset SVC
asrt "EF-3 the auto policy ACTS with no engarde binary and no engarde init script" \
     "$(cat "$WORK/etc/p5/mode")" lightning

# EF-4 -- the mechanism is NOT replaced by the fact. rc.d starts what is ENABLED,
# so a design that wrote $BOND_DIR/rc and stopped enabling the feeder would come
# up direct after every reboot and wait for a tick. The fact alone does not boot
# a bonded box; the fact plus one reconcile does.
setup; rcon; reboot
asrt "EF-4 the rc FACT alone does not survive a boot (rc.d starts only ENABLED services)" \
     "$(running p5-datapath)" 0
hook
asrt "EF-4 ...and one reconcile then converges the box the fact asked for" \
     "$(node)|$(running p5-datapath)|$(enabledf p5-datapath)" "engaged|1|1"

# EF-5 -- STRUCTURAL: the two halves of the reconciler pair must read DIFFERENT
# things. If node() and desired() both read the stored fact they are equal by
# construction, EF-2's delta is invisible, and the unit's own defect returns.
_ef_d=$(sed -n '/^desired() {/,/^}/p' "$P5/lib/xctl-probe.sh")
_ef_n=$(sed -n '/^node() {/,/^}/p' "$P5/lib/xctl-probe.sh")
asrt "EF-5 desired() reads the STORED fact"                      "$(printf '%s\n' "$_ef_d" | grep -c 'BOND_DIR/rc')" 1
asrt "EF-5 desired() executes NO service"                        "$(printf '%s\n' "$_ef_d" | grep -c 'svc_enabled')" 0
asrt "EF-5 node() still reads OBSERVED reality (halves not collapsed)" "$(printf '%s\n' "$_ef_n" | grep -c 'svc_enabled')" 1
# literal shipped source: the pattern IS bond-ecod's own `[ -f "$BOND_DIR/rc" ]` text.
# shellcheck disable=SC2016
asrt "EF-5 bond-ecod gates on that same stored fact"             "$(grep -c '\[ -f "\$BOND_DIR/rc" \]' "$P5/bond-ecod")" 1

# EL-5 -- THE NON-DEFAULT-IFS CLAIM, PINNED. xctl-probe.sh states that
# `agg_sched_of`/`agg_modes` word-split AGG_SCHED_TABLE on WHITESPACE and are
# therefore correct only under a default IFS, and that exactly ONE region of the
# shipped tree ever runs with IFS non-default (xctl-dag.sh converge's guard and
# action loops, which restore IFS around every leaf call -- the single fix site
# for the U141 defect). That was a tree-wide guarantee asserted in a COMMENT: it
# is true today by grep, and a future file that sets IFS ships green and silently
# re-opens the defect. This bar makes it mechanical.
# Counted: PERSISTENT non-default IFS assignments only, per file.
#   - `IFS=... read ...` is a COMMAND PREFIX, scoped to that one read, and cannot
#     leak into a later function call -- excluded.
#   - `IFS=$OLDIFS` / `IFS=$_oi` are RESTORES -- excluded.
#   - `OLDIFS=$IFS` / `_oi=$IFS` are saves, not assignments to IFS -- excluded
#     (the `[A-Za-z_]+IFS=` scrub).
#   - comment lines are not code -- excluded.
# Per-file COUNTS, not just file names, so a new site inside xctl-dag.sh reddens
# it too. The expected set is the 5 sites in converge's three loops plus the one
# in xctl-probe.sh's own `|`-split row reader (which does not call agg_sched_of).
# Goes red both ways: a new site anywhere, or a removed one, forces the comment's
# claim to be re-derived rather than inherited.
_el5=$(grep -rn 'IFS=' "$REPO/deploy/p5" 2>/dev/null | sed "s|^$REPO/deploy/p5/||" \
  | awk -F: '{ f=$1; sub(/^[^:]*:[0-9]*:/,"",$0); line=$0;
               sub(/^[ \t]*#.*/,"",line);
               gsub(/[A-Za-z_]+IFS=/," ",line);
               gsub(/IFS=\$OLDIFS/," ",line);
               gsub(/IFS=\$_oi/," ",line);
               gsub(/IFS=[^ ]*[ \t]+read/," ",line);
               n=gsub(/IFS=/,"",line);
               if(n>0) c[f]+=n }
       END{ for(k in c) printf "%s=%d\n", k, c[k] }' | sort | tr '\n' ' ')
asrt "EL-5 every persistent non-default IFS site under deploy/p5 is a converge loop (+probe's row reader)" \
     "$_el5" "lib/xctl-dag.sh=5 lib/xctl-probe.sh=1 "
# ===========================================================================
# NG8 -- AGG_SPOTTY / AGG_LIGHTNING plumbing (U15b fix round, verify blocker
# #1). BEFORE this round: grep -rln AGG_SPOTTY across the whole tree returned
# hits only under p4-bondagg/daemon/ -- build_agg_env emitted AGG_LISTEN /
# AGG_SERVER / AGG_PATHS / AGG_W and NOTHING else, so a deployed daemon always
# saw an EMPTY spotty set and standing lightning was a no-op outside `go test`
# regardless of AGG_LIGHTNING. Fixed by deriving AGG_SPOTTY from the SAME
# operator `metered` fact _metered()/gl_sources() already compute (ordered_spotty(),
# bond-xctl), and by giving AGG_LIGHTNING its own operator fact
# ($BOND_DIR/spotty_dup) so the whole feature -- not just the fact -- is
# switchable on a real box, same pattern as $BOND_DIR/agg_w.
# usb0 (tethering) is the design docs' own canonical spotty example
# (p5-execution-handover.md:77); it is proto=dhcp in this fixture (not a
# GL_CELL_PROTOS match), so it is metered ONLY via the operator fact -- the
# same case a real USB tether is in (INTENT OBJ-H: the router cannot observe
# the radio, only a human can record it).
setup; fact nwan 3; echo usb0 > "$WORK/etc/p5/metered"; bctl on; bctl mode speed
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
setup; fact nwan 3; echo usb0 > "$WORK/etc/p5/metered"; echo 1 > "$WORK/etc/p5/spotty_dup"
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
setup; fact nwan 3; printf 'eth0\nusb0\n' > "$WORK/etc/p5/metered"; bctl on; bctl mode speed
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
# (xctl-probe.sh `agg_sched_of`, queried by bondctl and bond-ecod as `_sched`).
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
asrt "AGG-L1 max: mode fact"        "$(cat "$WORK/etc/p5/mode")" max
asrt "AGG-L1 max: agg feeder up"    "$(running p5-datapath)" 1
asrt "AGG-L1 max: enrols every live source" "$(ncsv "$(aggf AGG_PATHS)")" "$(nrouted)"
asrt "AGG-L1 max: node engaged"     "$(node)" engaged
asrt "AGG-L1 max: endpoint :59402"  "$(epv)" "127.0.0.1:59402"
asrt "AGG-L1 max: AGG_SCHED=max"    "$(aggf AGG_SCHED)" max
MAXENV=$(aggnosched)

# AGG-L2 — `speed` takes the SAME lifecycle and emits the OTHER scheduler. The
# two agg_env files must differ in the AGG_SCHED line and NOWHERE else: any
# other difference means a mode grew its own config path.
setup; bctl on; bctl mode speed
asrt "AGG-L2 speed: agg feeder up"  "$(running p5-datapath)" 1
asrt "AGG-L2 speed: endpoint :59402" "$(epv)" "127.0.0.1:59402"
asrt "AGG-L2 speed: AGG_SCHED=speed" "$(aggf AGG_SCHED)" speed
asrt "AGG-L2 max and speed agg_env differ ONLY in AGG_SCHED" "$(aggnosched)" "$MAXENV"

# AGG-L3 — ONE intent in the SHIPPED table. A per-mode implementation shows up
# here as an extra row; this is the structural bar the model's AGG-0 mirrors.
NAGG=$(grep -c '^agg|' "$P5/bond.dag")
NPER=$(grep -c '^\(max\|speed\)|' "$P5/bond.dag")
# U141 folded the aggregate row into `engage`, so "exactly ONE aggregate intent"
# is now "exactly ZERO aggregate-only rows": the aggregate modes walk the same
# row eco and lightning do. A per-mode implementation still shows up here as an
# extra row, which is what this bar is for.
asrt "AGG-L3 bond.dag has ZERO aggregate-only rows (folded into engage)" "$NAGG" 0
asrt "AGG-L3 bond.dag has ZERO per-mode rows (no max|, no speed|)"       "$NPER" 0
if grep -q '^engage|' "$P5/bond.dag" && ! grep -q '^agg_revert|' "$P5/bond.dag"; then
  ok "AGG-L3 the aggregate onfail row is gone with it -- engage onfails to suspend"
else
  no "AGG-L3 bond.dag still carries an agg_revert row (the fold is incomplete)"
fi

# AGG-L4 (THE DISCRIMINATOR) — a max<->speed flip is an agg_env BYTE CHANGE, so
# agg_env then differs from agg_env.applied (U125; it was the `agg_env_changed`
# crumb before that) and the datapath bounces EXACTLY once.
# Without AGG_SCHED the two builds are byte-identical, converged() short-circuits,
# and the flip is a silent no-op: mode file says speed, datapath still runs max.
setup; bctl on; bctl mode max
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
S0=$(grep -c '^SVC p5-datapath start' "$WORK/ledger" 2>/dev/null); S0=${S0:-0}
bctl mode speed
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
S1=$(grep -c '^SVC p5-datapath start' "$WORK/ledger" 2>/dev/null); S1=${S1:-0}
asrt "AGG-L4 max->speed flip: AGG_SCHED now speed"      "$(aggf AGG_SCHED)" speed
asrt "AGG-L4 max->speed flip: EXACTLY ONE bond-agg restart" "$R1" "$((R0+1))"
asrt "AGG-L4 max->speed flip: still aggregating"        "$(running p5-datapath)" 1
# NOT the line above restated. `running = 1` is a post-state and a torn-down-then-
# rebuilt feeder satisfies it too; the init ledger is the independent fact, since
# svc-agg logs `start` only on a cold start (`restart` is a separate word). Zero
# new `start` lines + exactly one restart = the flip reconfigured the feeder in
# place. Residual, and it is NOT covered by any bar: whether the process is down
# for an instant DURING that restart -- the shim's restart is atomic, so the
# ecosim cannot observe a mid-restart gap at all.
asrt "AGG-L4 max->speed flip: reconfigured in place, no stop+start swap (no new init 'start')" \
     "$S1" "$S0"
asrt "AGG-L4 max->speed flip: endpoint unchanged"       "$(epv)" "127.0.0.1:59402"
# and back, so the bar is symmetric (no privileged mode)
R2=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
bctl mode max
asrt "AGG-L4 speed->max flip: AGG_SCHED now max"        "$(aggf AGG_SCHED)" max
asrt "AGG-L4 speed->max flip: EXACTLY ONE bond-agg restart" \
     "$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)" "$((R2+1))"

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
asrt "AGG-L5 precondition: mode is max"      "$(cat "$WORK/etc/p5/mode")" max
asrt "AGG-L5 precondition: agg feeder is UP" "$(running p5-datapath)" 1
asrt "AGG-L5 precondition: AGG_SCHED=max"    "$(aggf AGG_SCHED)" max
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0); E0=$(aggenv)
runw; runw
asrt "AGG-L5 healthy max tick: ZERO bond-agg restarts" \
     "$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)" "$R0"
asrt "AGG-L5 healthy max tick: agg_env unchanged"  "$(aggenv)" "$E0"
asrt "AGG-L5 healthy max tick: STILL aggregating"  "$(running p5-datapath)" 1

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
asrt "AGG-L6 N=1 max refused, prior mode kept" "$(cat "$WORK/etc/p5/mode")" eco
asrt "AGG-L6 N=1 max: the box stays on the mode it had" "$(aggf AGG_SCHED)" eco

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
# mode and leaves the box on a path that works. U141 changed WHICH path: with one
# feeder there is no engarde to bring back, so the row's onfail is `suspend` --
# revert to DIRECT (confirmed), feeder stopped. Same INV5 property, new landing.
setup; bctl on; bctl mode eco; fact capable 0
L8OUT=$(sh "$P5/bondctl" mode max 2>&1)
# the FATAL must NAME the mode that failed. On a CLI that never accepted `max`
# the same end state (mode eco, feeder down) is reached via a usage
# error, so without this the four asserts below pass vacuously.
case "$L8OUT" in
  *"max engage failed"*) ok "AGG-L8 the aggregate revert path RAN for max (FATAL names the mode)" ;;
  *)                     no "AGG-L8 no max-engage-failed FATAL -- the aggregate revert path never ran" ;;
esac
asrt "AGG-L8 max verify-fail: mode restored" "$(cat "$WORK/etc/p5/mode")" eco
asrt "AGG-L8 max verify-fail: feeder stopped" "$(running p5-datapath)" 0
asrt "AGG-L8 max verify-fail: node suspended" "$(node)" suspended
asrt "AGG-L8 max verify-fail: endpoint DIRECT (the suspend onfail, MF-1)" \
     "$(epv)" "203.0.113.9:51820"

# AGG-L9 — the canonical procd unit PASSES AGG_SCHED through. An agg_env carrying
# the selector is useless if the service stanza does not put it in the daemon's
# environment.
#
# U126 — THE SECOND STANZA IS GONE. `act_agg_install` used to write a byte-equal
# copy of this unit into $AGG_SVC at reconcile time, and two `FALLB == CANON`
# asserts here policed that copy for drift. There is now ONE stanza and ONE writer
# of /etc/init.d/p5-datapath: p5-install, via the `deploy/p5/init.d/bond-agg` row
# in p5/payload/filemap. The four bars the fallback needed are replaced 1:1 by the
# four below, which pin what the deletion actually rests on: nothing in the
# reconciler writes the init script any more (L9-a), no half-deletion left the leaf
# name in one artifact and not another (L9-b), the package really does place the
# file (L9-c), and it places it at the path the reconciler drives (L15-a).
if grep -q 'AGG_SCHED="[$]AGG_SCHED"' "$P5/init.d/bond-agg"; then
  ok "AGG-L9 canonical init.d/bond-agg passes AGG_SCHED to the daemon"
else
  no "AGG-L9 canonical init.d/bond-agg does NOT pass AGG_SCHED"
fi

# The SIX files that ARE the reconciler (U124: a bin plus five sourced libs). Every
# structural scan below reads all six, never the bin alone -- the bin is 232 of
# 1570 lines, and a bin-only scan is exactly how AGG-4 once lost 86% of its subject.
xctl_cat() { cat "$P5/bond-xctl" "$P5/lib/xctl-lock.sh" "$P5/lib/xctl-probe.sh" \
                 "$P5/lib/xctl-actions.sh" "$P5/lib/xctl-shape.sh" "$P5/lib/xctl-dag.sh"; }

# AGG-L9-a — no RUNTIME WRITER of the init script survives. Two independent counts:
# lines redirecting into "$AGG_SVC", and SVCEOF heredoc markers. Both must be 0.
# The line count scanned is printed with a floor for the same reason AGG-4 prints
# one: a scan that silently stops covering the program reads as green.
L9_SCAN=$(xctl_cat | wc -l | tr -d ' ')
# literal shipped source: the pattern is the reconciler's own "$AGG_SVC" redirect text,
# not this shell's value of AGG_SVC (which setup() exports to a fixture path).
# shellcheck disable=SC2016
L9_WRITE=$(xctl_cat | grep -c '>[[:space:]]*"\$AGG_SVC"' || true)
L9_HDOC=$(xctl_cat | grep -c 'SVCEOF' || true)
if [ "$L9_SCAN" -ge 1500 ]; then L9_COV=ok; else L9_COV=short; fi
asrt "AGG-L9-a the reconciler has no runtime writer of the init script ($L9_SCAN lines scanned, floor 1500)" \
     "$L9_WRITE|$L9_HDOC|$L9_COV" "0|0|ok"

# AGG-L9-b — the HALF-DELETION bar. `bond.dag` and the reconciler are parsed by
# BOTH layers, and the silent direction (dag drops the leaf while run_action and
# ACTIONS keep it) is caught by nothing else. Match the leaf name EXACTLY: a plain
# `grep agg_install` also matches the `agg_installed` GUARD, which stays.
L9B=$( { xctl_cat; cat "$P5/bond.dag"; } | grep -o 'agg_install[a-z_]*' | grep -cx 'agg_install' || true)
asrt "AGG-L9-b the agg_install leaf is gone from bond.dag AND the reconciler (no half-deletion)" \
     "$L9B" "0"

# AGG-L9-c — the deletion is only safe because the PACKAGE places the stanza.
# Exactly one filemap row may carry deploy/p5/init.d/bond-agg as its source: zero
# means nothing puts a stanza on the box, two means two writers again.
FM="$REPO/p5/payload/filemap"
L9C=$(grep -c '^[0-7][0-7][0-7]|[a-z]*|deploy/p5/init\.d/bond-agg|' "$FM" || true)
asrt "AGG-L9-c the package places the ONE stanza: exactly one filemap row for init.d/bond-agg" \
     "$L9C" "1"

# AGG-L15 (U111; the plan named this AGG-L13, but AGG-L13/AGG-L14 were already
# taken by U17's version-skew bars by the time this unit landed — next free id
# used instead, so no bar is silently overwritten). AGG_MODE=client is the
# ADR-002-superseded EIF PUSH client; 33201da:daemon/main.go:76-84 makes AGG_MODE=client
# with AGG_SCHED=speed a log.Fatalf, so a stanza still emitting AGG_MODE=client
# cannot serve the mode the orchestration believes the box is in. The ONE shipped
# launcher must emit AGG_MODE=pull-client (the U7 PULL core, ADR-002).
if grep -q 'AGG_MODE=pull-client' "$P5/init.d/bond-agg"; then
  ok "AGG-L15 canonical init.d/bond-agg emits AGG_MODE=pull-client"
else
  no "AGG-L15 canonical init.d/bond-agg does NOT emit AGG_MODE=pull-client"
fi

# AGG-L15-a — the COUPLING the fallback used to mask. It wrote to $AGG_SVC whatever
# $AGG_SVC was, so a package that placed the stanza somewhere else still produced a
# working box. With one writer, the package's dest and the reconciler's AGG_SVC
# default must be the SAME STRING; compared as strings, not by two greps that could
# both be wrong, and both sides asserted non-empty so a failed extraction cannot
# read as agreement.
FM_DEST=$(grep '^[0-7][0-7][0-7]|[a-z]*|deploy/p5/init\.d/bond-agg|' "$FM" | cut -d'|' -f4)
# sed SCRIPT matching bond-xctl's literal ${AGG_SVC:-...} default line; expanding it here
# would rewrite the pattern into the fixture path and extract nothing.
# shellcheck disable=SC2016
XCTL_DEST=$(sed -n 's/^AGG_SVC="${AGG_SVC:-\(.*\)}".*$/\1/p' "$P5/bond-xctl")
asrt "AGG-L15-a the package's dest IS the path the reconciler drives (filemap dest == AGG_SVC default)" \
     "$FM_DEST|${FM_DEST:+set}" "$XCTL_DEST|set"

# AGG-L16 (U126, +1 bar — declared; FIXTURE AND EXPECTATION CORRECTED at the U114
# merge) — the DEGENERATE CASE the deleted fallback was claimed to cover: an
# `engage` on a box with no init script at $AGG_SVC.
#
# WHY THE OLD EXPECTATION WAS AN ARTEFACT, not a property. U126 measured this on a
# tree whose desired() read `svc_enabled "$AGG_SVC"`, so a missing script made the
# INTENT read `off` before any guard or action ran and reconcile walked
# `disengage`. U114 moved the intent to the stored fact $BOND_DIR/rc for exactly
# the reason that coupling is wrong: a box whose init script was absent read
# desired=off forever and `bondctl on` could not repair it (bar EF-2). With the
# intent stored, the edge RUNS -- so what keeps the box safe here is U116's
# critical-action abort, not a short-circuit, and the safe end state is the same.
#
# AND THE OLD FIXTURE DID NOT BUILD THE CASE ITS TITLE NAMED: it repointed
# $AGG_SVC at a missing path but left the feeder PROCESS running. On a box the
# init script and the running feeder go together. Both shapes are pinned now,
# because they have DIFFERENT correct answers and only one of them was ever tested.
#
# THE NAMED CASE: script gone AND the feeder down. act_agg_restart is CRITICAL
# (xctl-dag.sh act_critical), so the edge aborts, `suspend` is walked, and
# act_revert puts the endpoint back on DIRECT and CONFIRMS the readback. A FATAL
# line IS printed -- that is U116's report of an aborted edge, and the reason this
# bar pins the END STATE rather than the absence of a log line: "not stranded" is
# what U126 cared about, and a silent abort would be worse, not better.
setup; fact nwan 3; bctl on; bctl mode max
"$BIN/svc-agg" stop >/dev/null 2>&1 || true
export AGG_SVC="$WORK/nosuchsvc"
if sh "$P5/bond-xctl" reconcile > "$WORK/l16.out" 2>&1; then L16RC=0; else L16RC=$?; fi
asrt "AGG-L16 a MISSING feeder init script + a down feeder ends on DIRECT and suspended, never stranded" \
     "$L16RC|$(node)|$(epv)|$(running p5-datapath)" "1|suspended|203.0.113.9:51820|0"
case "$(cat "$WORK/l16.out")" in
  *"reverted to DIRECT (confirmed)"*) ok "AGG-L16 ...and the revert was CONFIRMED by readback, not merely attempted" ;;
  *)                                  no "AGG-L16 ...and the revert was CONFIRMED by readback, not merely attempted" ;;
esac
export AGG_SVC="$BIN/svc-agg"

# AGG-L16-b — THE OTHER SHAPE, and the one the pre-U114 fixture actually built:
# the init script is unreachable but the feeder is UP. Reverting to direct here
# would DEGRADE a working datapath, so the correct answer is the opposite of the
# bar above: the edge completes best-effort (agg_enable's 127 is not critical) and
# the endpoint stays on the live feeder. node() still reads `off`, because the
# rc.d flag it reads is gone with the script, so the box never converges and
# re-walks `engage` every tick -- churn with no effect, since the leaves are
# effect-idempotent. This bar exists so that a future change cannot "fix"
# AGG-L16 by making any unreachable init script revert the endpoint.
setup; fact nwan 3; bctl on; bctl mode max
export AGG_SVC="$WORK/nosuchsvc"
if sh "$P5/bond-xctl" reconcile > "$WORK/l16b.out" 2>&1; then L16BRC=0; else L16BRC=$?; fi
L16BFAT=$(grep -c 'FATAL' "$WORK/l16b.out" || true)
asrt "AGG-L16-b an unreachable init script with the feeder UP does NOT degrade a working datapath" \
     "$L16BRC|$(node)|$(epv)|$(running p5-datapath)|$L16BFAT" "0|off|127.0.0.1:59402|1|0"
export AGG_SVC="$BIN/svc-agg"

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
setup; bctl on; bctl mode max; touch "$WORK/etc/p5/auto"
runecod
asrt "AGG-L11 ecod does not disturb mode during max" "$(cat "$WORK/etc/p5/mode")" max
asrt "AGG-L11 ecod did not disturb the feeder during max" "$(aggf AGG_SCHED)" max
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
# U124: the table lives in the PROBE lib now, and the mutant tree carries its own
# copy of lib/ (cp -R above), so the one-row edit and the XCTL_LIB the mutant runs
# under both point INSIDE $MUTD. Without the export the mutant bin would source the
# REAL tree's libs and the experiment would measure the unmutated table.
sed -i 's/^AGG_SCHED_TABLE="\(.*\)"$/AGG_SCHED_TABLE="\1 turbo:turbo"/' "$MUTD/lib/xctl-probe.sh"
export XCTL_LIB="$MUTD/lib"
# PORTABLE LINE COUNT (U69). `diff` has no portable DEFAULT output format: GNU
# diff defaults to NORMAL format ("< old" / "> new"), busybox diff defaults to
# UNIFIED ("-old" / "+new"). This bar counted `^[<>]`, so on a busybox toolchain
# -- which is every router and every arm of the busybox workflow -- it counted 0
# and read a CORRECT one-line change as a failure. Ask for `-u` explicitly, which
# both implementations honour, and count body lines only: the `---`/`+++` headers
# start with a doubled sign, so `^[-+][^-+]` excludes them.
#
# U72 (2026-09-03) -- THE FIX WAS RIGHT AND NOTHING WAS MEASURING IT. This comment
# used to end "Measured both ways in .github/workflows/busybox.yml", and that claim
# is false for every arm this suite actually runs. Measured on WSL busybox 1.36.1:
# a script run BY `busybox ash` still resolves `diff` through $PATH to GNU
# diffutils 3.10, so the busybox ARM of this harness has always counted with GNU
# diff, exactly like the bash arm. Only CI's arm C (bash shell, busybox applets
# first on PATH) ever put the two implementations together. Reproduced by putting
# the pre-fix `grep -c '^[<>]'` back: bash+GNU 2, ash+GNU 2, ash+busybox-diff 0 --
# the exact defect this bar exists to prevent, reported GREEN by every arm of the
# local suite. So ask BOTH implementations here, on the mutant tree that already
# exists, and make disagreement a failure instead of a comment.
# ONE LITERAL, AND IT LIVES ON THE NLINES LINE (U72 fix round, 2026-09-03).
# .github/workflows/busybox.yml seed 2 rewrites the `^NLINES=` line below and then
# proves the rewrite landed by grepping this whole file for the two-word literal
# `diff` followed by the unified+recursive flags. That guard is a TRUE detector
# only while that literal appears on the NLINES line and NOWHERE ELSE here: a
# second occurrence makes the step abort with the FALSE message "seed 2 did not
# apply", taking seeds 3 and 4 down with it -- the entire seeded-failure
# validation, off, fail-closed but silent about the real reason. The first draft
# of the bars below added five more occurrences and did exactly that. So the
# NLINES line keeps the spelled-out flags and every OTHER unified-diff call in
# this block asks for the same flags through $DIFFU. Do not inline $DIFFU back,
# and do not spell those flags out in a comment either. The durable fix is to
# anchor that guard (`grep -q '^NLINES=.*<flags>'`), which is CI's file, not this
# one; until that lands, this file owns the invariant.
DIFFU="-ru"
NFILES=$(diff -rq "$P5" "$MUTD" 2>/dev/null | grep -c 'differ')
NLINES=$(diff -ru "$P5" "$MUTD" 2>/dev/null | grep -c '^[-+][^-+]')
asrt "AGG-L12 a third scheduler touches exactly ONE file"    "$NFILES" 1
asrt "AGG-L12 ...and exactly ONE line in it (one - / one +)" "$NLINES" 2
if command -v busybox >/dev/null 2>&1; then
    asrt "AGG-L12p the FILE count is diff-implementation-independent (busybox diff agrees)" \
         "$(busybox diff -rq "$P5" "$MUTD" 2>/dev/null | grep -c 'differ')" "$NFILES"
    asrt "AGG-L12p the LINE count is diff-implementation-independent (busybox diff agrees)" \
         "$(busybox diff "$DIFFU" "$P5" "$MUTD" 2>/dev/null | grep -c '^[-+][^-+]')" "$NLINES"
    # NON-VACUITY. Agreeing is not the same as being RIGHT: two counters that are
    # both blind to a format agree on 0, which is precisely how the original defect
    # would have read had the sibling file-count bar not been there to contradict
    # it. So run the SAME counting rule over a fixture whose answer is known by
    # construction -- 3 changed lines in 1 of 2 files, so 3 `-` plus 3 `+` = 6 --
    # under both implementations, plus a negative control of two identical trees.
    # That is what makes a 0 above mean "nothing changed" rather than "the counter
    # cannot read this output format".
    D12="$WORK.diff12"; rm -rf "$D12"; mkdir -p "$D12/a/sub" "$D12/b/sub"
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$D12/a/f"
    printf 'k1\nk2\nk3\n'                     > "$D12/a/sub/g"
    cp "$D12/a/sub/g" "$D12/b/sub/g"
    printf 'l1\nX2\nl3\nl4\nl5\nX6\nl7\nX8\n' > "$D12/b/f"
    asrt "AGG-L12p known answer, toolchain diff: 3 changed lines in 1 of 2 files reads 6" \
         "$(diff "$DIFFU" "$D12/a" "$D12/b" 2>/dev/null | grep -c '^[-+][^-+]')" 6
    asrt "AGG-L12p known answer, busybox diff: the same 3 changed lines read 6" \
         "$(busybox diff "$DIFFU" "$D12/a" "$D12/b" 2>/dev/null | grep -c '^[-+][^-+]')" 6
    asrt "AGG-L12p known answer, toolchain diff: and exactly ONE of the two files differs" \
         "$(diff -rq "$D12/a" "$D12/b" 2>/dev/null | grep -c 'differ')" 1
    asrt "AGG-L12p known answer, busybox diff: and exactly ONE of the two files differs" \
         "$(busybox diff -rq "$D12/a" "$D12/b" 2>/dev/null | grep -c 'differ')" 1
    cp "$D12/a/f" "$D12/b/f"
    asrt "AGG-L12p negative control, toolchain diff: identical trees read 0" \
         "$(diff "$DIFFU" "$D12/a" "$D12/b" 2>/dev/null | grep -c '^[-+][^-+]')" 0
    asrt "AGG-L12p negative control, busybox diff: identical trees read 0" \
         "$(busybox diff "$DIFFU" "$D12/a" "$D12/b" 2>/dev/null | grep -c '^[-+][^-+]')" 0
    rm -rf "$D12"
else
    # NOT a pass and NOT a fail: an undeclared dependency. `recon-ecosim` does not
    # install busybox and this harness has never required it, so failing here would
    # redden a job for a dependency nobody declared. The busybox workflow -- the one
    # place the claim is about -- DOES install it, so the bars above run where they
    # mean something. Say so loudly rather than counting a green.
    echo "SKIP  AGG-L12p busybox is ABSENT: the diff-portability half of AGG-L12 did NOT run."
    echo "SKIP  AGG-L12p the counts above are single-implementation and say nothing about the boxes."
fi
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
asrt "AGG-L12 turbo: mode stored"      "$(cat "$WORK/etc/p5/mode")" turbo
asrt "AGG-L12 turbo: agg feeder up"    "$(running p5-datapath)" 1
asrt "AGG-L12 turbo: node engaged"     "$(node)" engaged
asrt "AGG-L12 turbo: endpoint :59402"  "$(epv)" "127.0.0.1:59402"
asrt "AGG-L12 turbo: AGG_SCHED=turbo"  "$(aggf AGG_SCHED)" turbo
asrt "AGG-L12 turbo: the usage line lists it too (derived, not typed)" \
     "$(sh "$P5/bondctl" mode bogus 2>&1 | sed -n 's/^usage: bondctl mode //p')" \
     "lightning|eco|max|speed|turbo"
P5="$P5REAL"; export XCTL_LIB="$P5/lib"; rm -rf "$MUTD"

# AGG-L13 - VERSION SKEW MUST FAIL CLOSED. U17 replaced bond-ecod's
# self-contained `[ "$MODE" = "speed" ]` with a question to another executable
# (`bondctl _sched`). That introduces a third answer the string test never had:
# "the question could not be ASKED". The first form treated it as "not an
# aggregate mode" and FAILED OPEN - on a half-upgraded box (old bondctl or old
# bond-xctl on disk, `_sched` an unknown verb -> exit 1) ecod would run its
# eco/lightning policy against an aggregating box and issue `_mode_auto`,
# rewriting /etc/p5/mode. `_sched` now exits 3 for "not an aggregate mode" and
# ecod proceeds ONLY on 3. The stub below is a real old CLI: it answers every
# other verb through the shipped bond-xctl and rejects `_sched` the way a
# pre-U17 bondctl does.
setup; bctl on; bctl mode max; touch "$WORK/etc/p5/auto"
cat > "$WORK/fakebin/oldbondctl" <<'OLDEOF'
#!/bin/sh
case "$1" in
  _sched|_sched_modes) echo "usage: bondctl on|off|status|mode|auto on|off" >&2; exit 1 ;;
  _mode_auto) echo "$2" > "$BOND_DIR/mode" ;;
  *) exec sh "$XCTL_REAL" "$@" ;;
esac
OLDEOF
chmod +x "$WORK/fakebin/oldbondctl"
echo degraded > "$WORK/run/p5/tput"     # the one-cycle trigger to _mode_auto lightning
XCTL_REAL="$P5/bond-xctl" MAXCYCLES=1 CYCLE=0 BONDCTL="$WORK/fakebin/oldbondctl" \
  SYS_NET="$WORK/sys" PING="$BIN/ping" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1
asrt "AGG-L13 skewed CLI (_sched unknown): ecod STANDS DOWN, mode still max" \
     "$(cat "$WORK/etc/p5/mode")" max
asrt "AGG-L13 skewed CLI: aggregate feeder untouched" "$(running p5-datapath)" 1
# ...and the same cycle with a CURRENT CLI still ACTUATES, so the bar is not
# "ecod never does anything": in eco, tput degraded escapes to lightning.
setup; bctl on; bctl mode eco; touch "$WORK/etc/p5/auto"
echo degraded > "$WORK/run/p5/tput"
runecod
asrt "AGG-L13 current CLI, NON-aggregate mode: ecod still actuates (eco -> lightning)" \
     "$(cat "$WORK/etc/p5/mode")" lightning

# AGG-L14 - the EMPTY mode verb is refused REGARDLESS of stored state (found in
# the U17 adversarial review). Deriving acceptance from `_sched` introduced a
# hole the listed parser never had: `_sched ""` answers for the STORED mode (a
# query default kept for bond-ecod), so `bondctl mode` with the argument
# forgotten was ACCEPTED exactly when the box was aggregating -- it wrote an
# EMPTY mode fact and the follow-up reconcile tore the aggregate down -- while
# the same typo on a lightning box printed usage and exited 1. State-dependent
# parsing is the bug. TEETH: on the pre-fix bondctl the FIRST block fails 5/5
# (verb accepted, exit 0, mode file emptied, feeder reconfigured); the
# second block passes either way -- it pins that the refusal is the SAME on a
# non-aggregate box, i.e. acceptance no longer depends on state.
setup; bctl on; bctl mode max
L14OUT=$(sh "$P5/bondctl" mode 2>&1); L14RC=$?
case "$L14OUT" in
  *"usage: bondctl mode"*) ok "AGG-L14 empty mode verb on an aggregating box: usage printed" ;;
  *)                       no "AGG-L14 empty mode verb on an aggregating box was ACCEPTED" ;;
esac
asrt "AGG-L14 empty mode verb: exit 1"            "$L14RC" 1
asrt "AGG-L14 empty mode verb: mode fact intact"  "$(cat "$WORK/etc/p5/mode")" max
asrt "AGG-L14 empty mode verb: still aggregating" "$(running p5-datapath)" 1
asrt "AGG-L14 empty mode verb: AGG_SCHED intact"  "$(aggf AGG_SCHED)" max
# ...and the refusal is state-INDEPENDENT: same verb, non-aggregate box.
setup; bctl on
L14RC2=0; sh "$P5/bondctl" mode >/dev/null 2>&1 || L14RC2=$?
asrt "AGG-L14 empty mode verb on a lightning box: exit 1 too" "$L14RC2" 1
asrt "AGG-L14 empty mode verb on a lightning box: mode intact" "$(cat "$WORK/etc/p5/mode")" lightning

# ===========================================================================
# AGG-L16 / AGG-L17 — converge() OBSERVES ACTION STATUS (U116)
#
# THE DEFECT, stated as the box state it produces: the engage row is
# `env_gen,agg_install,agg_enable,agg_restart,mtu_1408,ep_agg,shape_apply` with
# `onfail=suspend`, and converge discarded every action's exit status. The feeder
# start (`agg_restart`) sits BEFORE the endpoint pin (`ep_agg`), and it escapes
# through `fail()` -- which exits the process. So a feeder that cannot start left
# the box with the endpoint still pointing wherever the previous edge left it,
# `suspend` NEVER walked, and no crumb: `node()` reads the rc.d flag and answers
# `engaged` for a box with nothing feeding the tunnel, until an unrelated trigger.
#
# THE SEED IS HARNESS-LOCAL. bin/svc-agg is NOT edited -- every other bar depends
# on its single behaviour. `aggfail` writes a WRAPPER into $WORK whose `restart`
# does what a real init script does when the daemon will not come up (clears the
# running flag, exits non-zero) and delegates every other verb to the real shim.
# It must run AFTER `setup`, which re-exports AGG_SVC; the next `setup` clears it.
# act_agg_install early-returns on an executable $AGG_SVC, so the fallback heredoc
# never overwrites the wrapper.
aggfail() {
    # printf builds the BODY of a shim script: $1 and $ECOSIM_* belong to the GENERATED shim
    # and must reach it unexpanded, or the shim reads this harness's values instead.
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/sh' \
      '[ "$1" = restart ] && { echo 0 > "$ECOSIM_STATE/running.p5-datapath"; exit 1; }' \
      'exec "$ECOSIM_AGG_REAL" "$@"' > "$WORK/svc-agg-failrestart"
    chmod +x "$WORK/svc-agg-failrestart"
    export ECOSIM_AGG_REAL="$BIN/svc-agg"
    export AGG_SVC="$WORK/svc-agg-failrestart"
}
setup; fact nwan 3; bctl on; aggfail
L16OUT=$(sh "$P5/bondctl" mode speed 2>&1)
# PRECONDITION, not the instrument: the CLI reports the failure on BOTH trees
# (before this unit the process died at `fail`, which is also a non-zero exit).
case "$L16OUT" in
  *"engage failed"*) ok "AGG-L16 precondition: the CLI reports the engage failed" ;;
  *)                 no "AGG-L16 precondition: the CLI did not report a failed engage" ;;
esac
# INV1 sanity, non-discriminating: the seeded feeder is down either way.
asrt "AGG-L16 the seeded feeder is down"             "$(running p5-datapath)" 0
# THE THREE DISCRIMINATING BARS. On the pre-U116 tree they read
# `engaged` / `127.0.0.1:59402` / `no` -- an engaged-looking box pinned to a dead
# local feeder port, which is the defect.
asrt "AGG-L16 the failed action ABORTED the edge and onfail was walked (node)" \
     "$(node)" suspended
asrt "AGG-L16 ...so the endpoint was reverted to DIRECT, not left on a dead feeder" \
     "$(epv)" "203.0.113.9:51820"
if [ -f "$WORK/run/p5/suspended" ]; then
  ok "AGG-L16 ...and act_revert really ran (suspend crumb present)"
else
  no "AGG-L16 ...and act_revert really ran (suspend crumb present)"
fi
# The aborted edge must not leak the reconciler's lock: the action subshells clear
# the inherited EXIT trap, whose `rm -rf "$LOCK"` tests `$$` -- still the PARENT's
# pid inside a subshell. F9/F15 are the standing bars for the trap itself.
if [ -d "$WORK/run/p5/lock" ]; then
  no "AGG-L16 the aborted edge released the reconciler lock"
else
  ok "AGG-L16 the aborted edge released the reconciler lock"
fi

# AGG-L17 — A LEAF THE BINARY HAS NO ARM FOR STAYS FATAL. Raising the action's
# status to converge creates a way to get this wrong: if the `*)` arm's reserved
# 90 were treated as an ordinary failure, a bond.dag naming a leaf this binary
# does not carry would walk `onfail=suspend` and SUSPEND A BOX over a packaging
# mistake. The mutant tree lives OUTSIDE $WORK, as a sibling, for the reason XS-2
# records: `setup` begins `rm -rf "$WORK"`.
L17MUT="$WORK.l17mut"
rm -rf "$L17MUT"; mkdir -p "$L17MUT"; cp -R "$P5/." "$L17MUT/"
# Prepend the bogus leaf to the engage row's ACTION field (field 5), by field, so
# the mutation does not depend on the current action list's spelling. First in the
# list on purpose: nothing real runs before the FATAL.
awk -F'|' 'BEGIN{OFS="|"} /^engage\|/ {$5="bogus_leaf," $5} {print}' \
    "$P5/bond.dag" > "$L17MUT/bond.dag"
setup; fact nwan 3; bctl on
echo 0 > "$WORK/running.p5-datapath"          # feeder down => converged() is FALSE => the edge is walked
L17RC=0
L17OUT=$(XCTL_LIB="$L17MUT/lib" DAG="$L17MUT/bond.dag" sh "$L17MUT/bond-xctl" reconcile 2>&1) || L17RC=$?
case "$L17OUT" in
  *"FATAL"*"bogus_leaf"*) ok "AGG-L17 an unknown leaf is FATAL and NAMES the leaf" ;;
  *)                      no "AGG-L17 an unknown leaf is FATAL and NAMES the leaf" ;;
esac
asrt "AGG-L17 ...and exits non-zero"                          "$L17RC" 1
asrt "AGG-L17 ...and did NOT bring the feeder up"             "$(running p5-datapath)" 0
if [ -f "$WORK/run/p5/suspended" ]; then
  no "AGG-L17 ...and did NOT suspend the box over a packaging mistake"
else
  ok "AGG-L17 ...and did NOT suspend the box over a packaging mistake"
fi
# CONTROL: same world, same invocation form, shipped table -- the edge DOES run,
# so the three bars above are about the mutant leaf and not about the world.
echo 0 > "$WORK/running.p5-datapath"
XCTL_LIB="$P5/lib" DAG="$P5/bond.dag" sh "$P5/bond-xctl" reconcile >>"$WORK/ledger" 2>&1 || true
asrt "AGG-L17 CONTROL: the shipped table walks the same edge (the world is not the reason)" \
     "$(running p5-datapath)" 1
rm -rf "$L17MUT"

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
asrt "SH-0 cake is attached on the tunnel iface"             "$(qdiscv)" "cake mtu 1408"
asrt "SH-0 the shaping controller is running"                "$(running p5-shape)" 1
setup; bctl on; bctl off
asrt "SH-0 direct is HONEST: bond-off still carries shaping" "$(shapev)" wgclient1
asrt "SH-0 direct: node off"                                 "$(node)" off

# SH-1 — IDEMPOTENCY. reconcile twice with shaping already correct => ZERO
# effects: no shaper restart, no qdisc re-attach, and no feeder bounce. Measured
# on the shim's restart counter and the tc ledger, not on a return code.
setup; bctl on
R0=$(cat "$WORK/restarts.p5-shape" 2>/dev/null || echo 0)
T0=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T0=${T0:-0}
E0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
hook; hook
R1=$(cat "$WORK/restarts.p5-shape" 2>/dev/null || echo 0)
T1=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T1=${T1:-0}
E1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
asrt "SH-1 idempotency: two reconciles cause ZERO shaper restarts" "$R1" "$R0"
asrt "SH-1 idempotency: two reconciles cause ZERO qdisc operations" "$T1" "$T0"
asrt "SH-1 idempotency: and still ZERO feeder restarts"             "$E1" "$E0"

# SH-2 — SELF-HEAL, from every node including `off`. Tear the qdisc out from
# under a converged box (a firmware event, a GL UI toggle, a manual `tc`); the
# NEXT reconcile restores it, with no new timer, daemon or watchdog.
setup; bctl on; rm -f "$WORK/qdisc.wgclient1"
asrt "SH-2 engaged: torn down, observed off"  "$(shapev)" off
hook
asrt "SH-2 engaged: healed by the next reconcile" "$(shapev)" wgclient1
setup; bctl on; bctl off; rm -f "$WORK/qdisc.wgclient1"; hook
# NOT a style nit: backticks inside DOUBLE quotes are command substitution, so this
# label executed `off` and the bar's own name came out mangled. Single quotes, like
# every sibling bar already uses.
asrt "SH-2 'off': healed from the 'off' node too" "$(shapev)" wgclient1
setup; bctl on; bctl mode speed; rm -f "$WORK/qdisc.wgclient1"; hook
asrt "SH-2 speed: healed from the speed node too" "$(shapev)" wgclient1
# and the healer is the WATCHDOG tick as well, which is the unattended path
setup; bctl on; echo 0 > "$WORK/running.p5-shape"; runw
asrt "SH-2 watchdog tick heals a dead shaping controller" "$(running p5-shape)" 1

# SH-3 — INV8 NON-ESCALATION. THE bar that matters: make shaping fail hard and
# assert the EFFECT -- the edge still completes, engage still reaches `engaged`,
# and NO suspend is walked. Effect, not return code: a shape_apply that was
# simply skipped would pass a return-code check, so the qdisc/controller state
# is asserted DOWN at the same time, proving the action really did run.
setup; fact shape_broken 1; fact tc_broken 1; bctl on
asrt "SH-3 INV8: engage still reaches engaged with the shaper failing" "$(node)" engaged
asrt "SH-3 INV8: endpoint still pinned local"        "$(epv)" "127.0.0.1:59402"
asrt "SH-3 INV8: the feeder is still up"             "$(running p5-datapath)" 1
asrt "SH-3 INV8: NO suspend crumb was walked"        "$( [ -f "$WORK/run/p5/suspended" ] || [ -f "$WORK/run/p5/suspended-degraded" ] && echo yes || echo no )" no
asrt "SH-3 INV8: shaping is observably DOWN (the action ran and did not escalate)" "$(shapev)" off
# the same under an aggregate mode -- same row, same onfail (`suspend`)
setup; fact shape_broken 1; fact tc_broken 1; bctl on; bctl mode speed
asrt "SH-3 INV8 speed: aggregate still engaged"      "$(running p5-datapath)" 1
asrt "SH-3 INV8 speed: endpoint :59402"              "$(epv)" "127.0.0.1:59402"
asrt "SH-3 INV8 speed: no suspend was walked (still fed as speed)" "$(aggf AGG_SCHED)" speed
asrt "SH-3 INV8 speed: shaping observably DOWN"      "$(shapev)" off
# and it recovers with no operator action once the shaper is fixed
fact shape_broken 0; fact tc_broken 0; hook
asrt "SH-3 INV8: shaping recovers on the next reconcile once the shaper is fixed" "$(shapev)" wgclient1

# SH-4 — MTU ORDERING, asserted as an EFFECT. The bar reads the MTU the qdisc
# was ATTACHED AGAINST (the tc shim stamps it), so it reads the applied shaping,
# not the order of names in a list -- and it is asserted on an attach that
# ACTUALLY happens: shaping is torn out first, so the edge must re-attach. Move
# `shape_apply` ahead of mtu_1408/mtu_1420 in bond.dag and this fails.
# WHICH EDGE MOVES THE MTU CHANGED WITH U141: 1408 is now the frame size of EVERY
# bonded mode (one feeder, one MTU -- ADR-003 G-10: eco pays the 1408 it did not
# pay under engarde), so the crossing is engage(1408) <-> disengage(1420), not a
# mode flip. Both directions are asserted.
setup; bctl on
asrt "SH-4 engage: the attach happened AFTER the MTU settled (1408, not 1420)" "$(qdiscv)" "cake mtu 1408"
rm -f "$WORK/qdisc.wgclient1"
bctl mode speed
asrt "SH-4 aggregate mode: the attach is still against 1408" "$(qdiscv)" "cake mtu 1408"
asrt "SH-4 aggregate mode: node engaged (speed)" "$(node)" engaged
rm -f "$WORK/qdisc.wgclient1"
bctl off
asrt "SH-4 disengage: the attach reflects MTU 1420 again" "$(qdiscv)" "cake mtu 1420"

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
bctl off
T1=$(grep -c '^TC ' "$WORK/ledger" 2>/dev/null); T1=${T1:-0}
asrt "SH-4b NAMED LIMIT: an already-converged box crossing an MTU change performs ZERO qdisc operations" "$T1" "$T0"
asrt "SH-4b NAMED LIMIT: the qdisc stamp stays 1408"    "$(qdiscv)" "cake mtu 1408"
asrt "SH-4b NAMED LIMIT: while the device MTU really did move to 1420"      "$(cat "$WORK/mtu.wgclient1" 2>/dev/null)" 1420

# SH-5 — the `shape` FACT is honoured, and the writer is the CLI, not the
# executor. `bondctl shape off` writes the fact and reconciles; the qdisc and
# the controller come down, and STAY down across further reconciles (a converged
# `off` is converged -- it must not be re-applied every tick).
setup; bctl on; bctl shape off
asrt "SH-5 shape off: observed off"                  "$(shapev)" off
asrt "SH-5 shape off: qdisc removed"                 "$(qdiscv)" none
asrt "SH-5 shape off: controller stopped"            "$(running p5-shape)" 0
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
R0=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT0=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT0=${IPT0:-0}
runw; runw; runw
R1=$(cat "$WORK/restarts.p5-datapath" 2>/dev/null || echo 0)
IPT1=$(grep -c '^iptables -I' "$WORK/ledger" 2>/dev/null); IPT1=${IPT1:-0}
asrt "SH-6 shaping unavailable: 3 watchdog ticks cause ZERO feeder restarts" "$R1" "$R0"
asrt "SH-6 shaping unavailable: no iptables silence-window"                   "$IPT1" "$IPT0"
asrt "SH-6 shaping unavailable: box stays engaged"                            "$(node)" engaged

# SH-7 — the tunnel iface is DISCOVERED, not hardcoded. `$BOND_DIR/wg_if` is the
# M8/E6 discovery fact; shaping follows it. No `wgclient1` literal exists in the
# shaping path, so a box whose tunnel is named anything else shapes the right
# device. (E6 is not built; this asserts the consumer half is already generic.)
setup; echo wgc7 > "$WORK/etc/p5/wg_if"; bctl on
asrt "SH-7 shaping follows the DISCOVERED iface, not a literal" "$(shapev)" wgc7
asrt "SH-7 no qdisc was attached to the fallback name" "$(qdiscv)" none
asrt "SH-7 the discovered device carries the qdisc" \
     "$(cat "$WORK/qdisc.wgc7" 2>/dev/null || echo none)" "cake mtu 1420"

# SH-20 / SH-21 — THE RECONCILER MAY NOT DRIVE A CONTROLLER IT DID NOT WRITE.
#
# THE IDS. U210's brief named this pair SH-17/SH-18. Both ids were ALREADY
# taken further down this same file -- the mangled-pin refusal and the
# citation lint -- so the pair is numbered SH-20/SH-21 here and in
# bond_model.py, which is the only change: every assertion is the brief's.
#
# THE DEFECT, and it was live on dev until U210. `shape_apply` rides the
# DISENGAGE edge as well as engage/switch (bond.dag), and `direct` is DEFINED as
# bond-off PLUS shaping -- so ANY reconcile on a box whose shaping has not
# converged runs act_shape_apply, INCLUDING at deploy state S2, before P5 is
# ever engaged. The leaf ran `$SHAPE_SVC enable; restart`, and SHAPE_SVC
# defaulted to /etc/init.d/cake-autorate, which on the client is P1's LIVE
# controller: P5 would have re-enabled, from inside the reconciler, the service
# the operator had just switched off -- invisible to the engage guard, because
# the engage guard is not on the disengage edge.
#
# THE RENAME IS ONLY HALF THE FIX and these two bars are the other half:
# $SHAPE_SVC is an override, so the name alone cannot decide ownership. The
# leaves grep the FILE for the P5 marker, in BOTH directions -- apply and clear.
#
# WHY THE KNOB IS A FILE COPY AND NOT A FLAG. Ownership is a property of the
# file the reconciler greps; nothing the shim does at RUNTIME can change what
# that grep sees. sh_foreign therefore points SHAPE_SVC at a copy of the shim
# with the marker line stripped -- a copy that still LEDGERS every verb, so
# "zero verbs" is measured against a recorder, not against silence.
sh_foreign() {
    _fs="$WORK/foreign-shape"
    grep -v '^# P5-OWNED-INIT: deploy/p5/init.d/p5-shape$' "$BIN/svc-shape" > "$_fs"
    chmod 0755 "$_fs"
    # the copy must still be a recorder, or "zero verbs" would be vacuous
    [ "$(grep -c 'ledger' "$_fs")" -ge 5 ] || no "SH-20 fixture: the foreign copy lost its ledger writes"
    [ "$(grep -c 'P5-OWNED-INIT' "$_fs")" = 0 ] || no "SH-20 fixture: the marker survived the strip"
    SHAPE_SVC="$_fs"; export SHAPE_SVC
}
svcverbs() { grep -Ec "^SVC p5-shape ($1)\$" "$WORK/ledger" 2>/dev/null | tr -d ' '; }
shwarn()   { grep -c '^LOG WARN: shaping: .*carries no P5 marker' "$WORK/ledger" 2>/dev/null | tr -d ' '; }

# SH-20 — want=on against a FOREIGN controller: zero enable/restart, one WARN,
# no qdisc, and the tunnel still comes up (INV8 -- shaping never escalates).
setup; sh_foreign
bctl on
asrt "SH-20 foreign controller: ZERO enable/restart verbs reached it" "$(svcverbs 'enable|restart')" 0
asrt "SH-20 foreign controller: the leaf WARNed exactly once"         "$(shwarn)" 1
asrt "SH-20 foreign controller: NO qdisc was attached either"         "$(qdiscv)" none
asrt "SH-20 INV8: the tunnel still engaged"                           "$(node)" engaged
asrt "SH-20 INV8: endpoint still pinned local"                        "$(epv)" "127.0.0.1:59402"
asrt "SH-20 INV8: NO suspend crumb was walked" \
     "$( [ -f "$WORK/run/p5/suspended" ] || [ -f "$WORK/run/p5/suspended-degraded" ] && echo yes || echo no )" no
# CONTROL: the same world with the marker present DOES drive it -- so the three
# zeros above are about ownership and not about a world in which nothing happens.
setup; bctl on
asrt "SH-20 CONTROL: an OWNED controller receives enable+restart in the same world" \
     "$( [ "$(svcverbs 'enable|restart')" -ge 2 ] && echo drove || echo NOTHING )" drove
asrt "SH-20 CONTROL: and shaping converges"                           "$(shapev)" wgclient1

# SH-21 — the SECOND leaf, and the one it is easy to forget. want=off against a
# foreign controller must not disable or stop it, and must not tear down a qdisc
# that may be the foreign controller's. Measured as a DELTA across the switch,
# because the owned half of the scenario legitimately drove the shim first.
setup; bctl on
_D0=$(svcverbs 'disable|stop'); _Q0=$(qdiscv); _W0=$(shwarn)
sh_foreign
bctl shape off
asrt "SH-21 foreign controller: ZERO disable/stop verbs reached it" "$(svcverbs 'disable|stop')" "$_D0"
asrt "SH-21 foreign controller: the clear leaf WARNed once"         "$(shwarn)" "$((_W0 + 1))"
asrt "SH-21 foreign controller: the qdisc was NOT torn down"        "$(qdiscv)" "$_Q0"
asrt "SH-21 INV8: the tunnel is untouched by any of it"             "$(node)" engaged
# CONTROL: `shape off` against an OWNED controller still tears it down, so SH-21
# is measuring the ownership test and not a broken `off` path (must-not 15: an
# ownership check placed BEFORE the desired-off branch would break exactly this).
setup; bctl on; bctl shape off
# NOT a style nit: backticks inside DOUBLE quotes are command substitution, and
# this label would execute `shape off` (SH-2 was bitten by exactly that).
# shellcheck disable=SC2016
# ^ the single quotes are the POINT (see the note above): in double quotes the
#   backticks would run `shape off` while building the bar's own label.
asrt 'SH-21 CONTROL: `shape off` on an OWNED controller stops it'   "$(running p5-shape)" 0
asrt "SH-21 CONTROL: and removes the qdisc"                         "$(qdiscv)" none
setup

# ================= E4 INSTALL HALF — U22a — SH-8 .. SH-15 ==================
# U22 folded shaping into the DAG. Nothing PRODUCED the shaper it controls:
# `bond-xctl SHAPE_SVC=` had no producer in the tree and E7 removes P1's.
# U210 renamed that default to /etc/init.d/p5-shape and made the controller a
# FILEMAP ROW: p5-install places it (disabled), and this installer only checks
# that it is there and marked. THESE BARS GO RED ON A TREE WITHOUT THE INSTALL HALF —
# SH-8/SH-9/SH-10/SH-11/SH-14 cannot even find `deploy/p5/shape-install`, SH-15
# reads bond-xctl's own SHAPE_SVC and asserts a producer + a manifest entry
# exist for exactly that path. Demonstrated failing against the parent tree in
# U22a's result; do not weaken them to go green.

si_world() {   # a hermetic "box" for shape-install. EVERY path is an override,
               # so the harness runs the SHIPPED file, not a copy of it.
    SI="$WORK/si"; rm -rf "$SI" 2>/dev/null
    mkdir -p "$SI/share/vendor" "$SI/net/wgclient1" \
             "$SI/mod/sch_cake" "$SI/mod/ifb" "$SI/mod/act_mirred" \
             "$SI/usr/lib/p5" "$SI/etc/init.d" "$SI/etc/config" "$SI/payload"
    cp "$P5/shape/cake-autorate.pin" "$SI/share/cake-autorate.pin"
    # THE CONTROLLER IS NOT THIS INSTALLER'S TO PLACE ANY MORE (U210). It is a
    # filemap row -- 755|client|deploy/p5/init.d/p5-shape|/etc/init.d/p5-shape --
    # so p5-install writes it, DISABLED, and shape-install only CHECKS that it is
    # present and P5-marked. The world therefore starts in the state a box is in
    # when `sh <pkg>/bin/p5-shape-install install` is run from the package: P5
    # installed first, the controller already there. si_place_ctl IS that step,
    # spelled out here rather than hidden inside si_world, because three bars
    # below need the world WITHOUT it (absent) or with a FOREIGN file at that
    # name, and a fixture you cannot vary cannot measure a refusal.
    si_place_ctl
    printf 'GL-MT6000\n' > "$SI/model"
    : > "$SI/rc.common"
    : > "$SI/proc_modules"
}
si_place_ctl() {   # exactly what p5-install does from the filemap row, and no more
    cp "$P5/init.d/p5-shape" "$SI/etc/init.d/p5-shape"
    chmod 0755 "$SI/etc/init.d/p5-shape"
}
si_ctlsum() { sha256sum "$SI/etc/init.d/p5-shape" 2>/dev/null | awk '{print $1}'; }
shapeinst() {
    BOND_DIR="$WORK/etc/p5" WG_DEV=wgclient1 \
    P5_SHARE="$SI/share" \
    SHAPE_BASE="$SI/usr/lib/p5/p5-shape" SHAPE_SVC="$SI/etc/init.d/p5-shape" \
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
    printf '5000 20000 100000 5000 20000 50000\n' > "$WORK/etc/p5/shape_bounds"
    printf '198.51.100.7\n198.51.100.8\n'         > "$WORK/etc/p5/shape_reflectors"
}

# ---- ABSENT MUST NOT LOOK LIKE CLEAN -------------------------------------
# Every bar below that WANTS a low count reads a SHIPPED file. On a tree with no
# install half those files do not exist, `grep -c` over nothing is 0, and the
# bar scores its wanted value while measuring nothing at all. MEASURED on the
# A/B arm with the install half deleted (mmakki-ui/bond-ci run 33342017927,
# branch u22a-ab-noinstall): 31 of these 96 bars PASSED there, ten of them
# asserting this unit's headline safety properties about files that were not in
# the tree. `lint_hits` was fixed for two of five lint sites and none of the
# five pin bars; these helpers close the whole class. NOFILE is not 0 and is not
# any wanted value, so an absent input goes RED.
PINF="$P5/shape/cake-autorate.pin"
code()      { [ -f "$1" ] || { echo NOFILE; return; }; sed 's/#.*//' "$1"; }
lint_hits() { [ -f "$1" ] || { echo NOFILE; return; }; code "$1" | grep -Eic "$2" | tr -d ' '; }
f_hits()    { [ -f "$1" ] || { echo NOFILE; return; }; grep -Ec -- "$2" "$1" | tr -d ' '; }
blk()       { [ -f "$1" ] || { echo NOFILE; return; }; sed -n "/^BEGIN_$2\$/,/^END_$2\$/p" "$1"; }
blk_hits()  { [ -f "$1" ] || { echo NOFILE; return; }; blk "$1" "$2" | grep -Ec -- "$3" | tr -d ' '; }
dir_files() { [ -d "$1" ] || { echo NODIR; return; }; find "$1" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' '; }

# SH-8 — G2 IS THE GATE, AND IT REFUSES RATHER THAN PROCEEDING UNVERIFIED.
# G2 answered on 2026-08-30 with CAR_ORIGIN=NO-GIT and a per-file sha256 set, so
# the shipped pin now HAS hashes. It does NOT have the BYTES: shape/vendor/ is
# empty and hashes are not code. The refusal must therefore be PRECISE about
# which half is missing, and must still change nothing at all.
setup; si_world
_ctl0=$(si_ctlsum)
SH8=$(shapeinst preflight)
asrt "SH-8 shipped pin records NO-GIT (no commit exists on the box to pin to)" \
     "$(f_hits "$PINF" '^CAR_ORIGIN=NO-GIT$')" 1
asrt "SH-8 shipped pin carries a FILES block with per-file sha256" \
     "$( [ "$(blk_hits "$PINF" FILES '^[0-9a-f]{64}  ')" -ge 1 ] 2>/dev/null && echo yes || echo no )" yes
asrt "SH-8 config.wg.sh (Mo's operational config) is deliberately NOT pinned" \
     "$(blk_hits "$PINF" FILES 'config\.wg\.sh$')" 0
# PINNED IS NOT SHIPPED, asserted on the SHIPPED pin, not only on the harness one.
# _stg is NOFILE-guarded: on a tree with no pin every want-0 bar below would
# otherwise read an empty list and score 0 (see the note above the helpers).
if [ -f "$PINF" ]; then
    _stg=$(blk "$PINF" STAGE | grep -Ev '^(BEGIN|END)_STAGE$|^#|^$')
    _stgbad=$(for _n in $_stg; do blk "$PINF" FILES | grep -q "  $_n\$" || echo BAD; done | wc -l | tr -d ' ')
    _stgsetup=$(printf '%s\n' "$_stg" | grep -cx 'setup\.sh' | tr -d ' ')
    _stguninst=$(printf '%s\n' "$_stg" | grep -cx 'uninstall\.sh' | tr -d ' ')
else
    _stg=""; _stgbad=NOFILE; _stgsetup=NOFILE; _stguninst=NOFILE
fi
asrt "SH-8 the shipped pin declares a STAGE block (which files land on the box)" \
     "$( [ -n "$_stg" ] && echo yes || echo no )" yes
asrt "SH-8 setup.sh (upstream's wget-from-master installer) is pinned but NEVER staged" \
     "$_stgsetup" 0
asrt "SH-8 uninstall.sh (it deletes P1's LIVE /root/cake-autorate) is pinned but NEVER staged" \
     "$_stguninst" 0
asrt "SH-8 every STAGED name is also PINNED (no unverified file can be staged)" \
     "$_stgbad" 0
asrt "SH-8 shape/vendor/ ships EMPTY (the bytes are the remaining G2 half)" \
     "$(dir_files "$P5/shape/vendor")" 0
asrt "SH-8 preflight REFUSES with the bytes absent"  "$(sirc preflight)" 3
asrt "SH-8 the refusal NAMES G2"                     "$( [ "$(echo "$SH8" | grep -c 'G2')" -ge 1 ] && echo named || echo silent )" named
asrt "SH-8 the refusal says the VENDORED BYTES are what is missing" \
     "$(echo "$SH8" | grep -c 'vendored bytes')" 1
asrt "SH-8 install refuses too, exit 3"              "$(sirc install)" 3
# The controller is p5-install's file now, so "installed nothing" cannot be read
# off its ABSENCE any more -- it is read off its BYTES. A refused install must
# leave the file p5-install placed exactly as it found it.
asrt "SH-8 and it did not touch the controller p5-install placed (byte-identical)" \
     "$(si_ctlsum)" "$_ctl0"
asrt "SH-8 and it staged NOTHING"                    "$( [ -e "$SI/usr/lib/p5/p5-shape" ] && echo yes || echo no )" no

# SH-9 — the mechanism WORKS once the declared inputs exist (positive control:
# a bar that can only ever refuse proves nothing). Synthetic payload, sha
# computed from the artifact.
setup; si_world; si_supply
_ctl0=$(si_ctlsum)
asrt "SH-9 preflight READY once the pin + facts are supplied" "$(sirc preflight)" 0
asrt "SH-9 install succeeds"                                  "$(sirc install)" 0
asrt "SH-9 the CONTROLLER bond-xctl drives is present and P5-MARKED" \
     "$( [ -x "$SI/etc/init.d/p5-shape" ] && grep -q "P5-OWNED-INIT: deploy/p5/init.d/p5-shape" "$SI/etc/init.d/p5-shape" && echo yes || echo no )" yes
asrt "SH-9 and the installer did NOT write it -- p5-install's bytes are untouched" \
     "$(si_ctlsum)" "$_ctl0"
_V1=$(cat "$SI/usr/lib/p5/p5-shape/current")
asrt "SH-9 install-new-then-switch: current -> a CONTENT-ADDRESSED version id" \
     "$(echo "$_V1" | grep -Ec '^v-[0-9a-f]{12}$')" 1
asrt "SH-9 the payload is under the version dir, not over the live one" \
     "$( [ -f "$SI/usr/lib/p5/p5-shape/$_V1/cake-autorate.sh" ] && echo yes || echo no )" yes
# PINNED IS NOT SHIPPED. All five are verified; only the STAGE subset lands.
asrt "SH-9 exactly the STAGED subset landed, not every pinned file"  \
     "$(find "$SI/usr/lib/p5/p5-shape/$_V1" -type f | wc -l | tr -d ' ')" 3
asrt "SH-9 upstream's wget-from-master setup.sh is VERIFIED but NOT placed" \
     "$( [ -e "$SI/usr/lib/p5/p5-shape/$_V1/setup.sh" ] && echo placed || echo absent )" absent
asrt "SH-9 upstream's uninstall.sh (it removes P1's LIVE /root/cake-autorate) is NOT placed" \
     "$( [ -e "$SI/usr/lib/p5/p5-shape/$_V1/uninstall.sh" ] && echo placed || echo absent )" absent
asrt "SH-9 config generated with the DISCOVERED iface, not a literal" \
     "$(grep -c '^ul_if=wgclient1$' "$SI/usr/lib/p5/p5-shape/config.p5.sh")" 1
asrt "SH-9 dl_if is the ifb mirror of the discovered iface" \
     "$(grep -c '^dl_if=ifb4wgclient1$' "$SI/usr/lib/p5/p5-shape/config.p5.sh")" 1
asrt "SH-9 rates come from the FACT, none are written by the installer" \
     "$(grep -c '^base_ul_shaper_rate_kbps=20000$' "$SI/usr/lib/p5/p5-shape/config.p5.sh")" 1
asrt "SH-9 no tuning constant is written (upstream defaults, named not guessed)" \
     "$(f_hits "$SI/usr/lib/p5/p5-shape/config.p5.sh" '^(no_pingers|high_load_thr|bufferbloat_refractory_period_ms|shaper_rate_max_adjust_up_load_high)=')" 0
# PLACEMENT IS NOT ACTIVATION: the installer must not enable or start anything.
# The DAG owns activation, and that single ownership point is the whole design.
asrt "SH-9 the installer ENABLED nothing"  "$( [ -e "$SI/etc/rc.d" ] && echo yes || echo no )" no
# literal shipped source: the lint pattern is shape-install's own $SHAPE_SVC text.
# shellcheck disable=SC2016
asrt "SH-9 the installer contains no start/enable of the controller" \
     "$(lint_hits "$P5/shape-install" 'SHAPE_SVC" *(enable|start|restart)|\$SHAPE_SVC (enable|start|restart)')" 0
# IDEMPOTENCY + interruption-retry: running it again converges, never duplicates.
_p1=$(cat "$SI/usr/lib/p5/p5-shape/current")
asrt "SH-9 second install is a no-op-or-forward (idempotent)" "$(sirc install)" 0
asrt "SH-9 and current still names the same version"          "$(cat "$SI/usr/lib/p5/p5-shape/current")" "$_p1"
asrt "SH-9 no stage dir survived"  "$(find "$SI/usr/lib/p5/p5-shape" -name '.stage.*' 2>/dev/null | wc -l | tr -d ' ')" 0

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
_CAR="$SI/usr/lib/p5/p5-shape"
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
mkdir -p "$SI/usr/lib/p5/p5-shape/current"
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
asrt "SH-10 nothing was STAGED on a mismatch"  "$( [ -e "$SI/usr/lib/p5/p5-shape" ] && echo yes || echo no )" no
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
_VA=$(cat "$SI/usr/lib/p5/p5-shape/current")
setup; si_world; si_supply b; shapeinst install >/dev/null 2>&1
_VB=$(cat "$SI/usr/lib/p5/p5-shape/current")
asrt "SH-10 the version id is DERIVED from the pinned set (different set => different id)" \
     "$( [ "$_VA" != "$_VB" ] && echo differs || echo same )" differs

# SH-10b — A PATH IS NOT A TITLE DEED. U210 moved P5's controller OUT of P1's
# name (`/etc/init.d/cake-autorate`, P1's live service, `S97cake-autorate` in
# rc.d -- inventory 2026-08-30-client-flint2.txt:125,214-218) and into
# `/etc/init.d/p5-shape`, so the collision that motivated the marker cannot
# happen by DEFAULT any more. The marker is still what decides ownership,
# because $SHAPE_SVC is an override and a foreign file can be at that path:
# install refuses (exit 6), remove leaves it, and the bytes are untouched either
# way. Removing a foreign controller is E7's, ordered.
setup; si_world; si_supply
printf '#!/bin/sh /etc/rc.common\n# a FOREIGN service, not P5-marked\nSTART=97\n' > "$SI/etc/init.d/p5-shape"
chmod +x "$SI/etc/init.d/p5-shape"
_sum0=$(sha256sum "$SI/etc/init.d/p5-shape" | awk '{print $1}')
SH10f=$(shapeinst install)
asrt "SH-10b a FOREIGN controller at SHAPE_SVC refuses the install (exit 6)" "$(sirc install)" 6
asrt "SH-10b the refusal names the reason"     "$(echo "$SH10f" | grep -c 'SVC  FOREIGN')" 1
asrt "SH-10b and says whose it is and who removes it"      "$( [ "$(echo "$SH10f" | grep -c "P5 did not write")" -ge 1 ] && [ "$(echo "$SH10f" | grep -c "E7")" -ge 1 ] && echo named || echo vague )" named
asrt "SH-10b and the foreign file is BYTE-IDENTICAL afterwards" \
     "$(sha256sum "$SI/etc/init.d/p5-shape" | awk '{print $1}')" "$_sum0"
asrt "SH-10b remove LEAVES a foreign controller alone" \
     "$(sirc remove)$( [ -f "$SI/etc/init.d/p5-shape" ] && echo kept || echo DELETED )" "0kept"
asrt "SH-10b and it says why"  "$(shapeinst remove | grep -c 'no P5 ownership marker')" 1
# THE MARKER IS ONE STRING IN THREE SHIPPED FILES, and it is an ownership check
# only while all three agree: the init script CARRIES it, shape-install greps for
# it, and bond-xctl -- which is where the reconciler's shape leaves read it from
# (xctl-shape.sh shape_svc_owned is a sourced lib, so $P5_MARK is bond-xctl's
# variable) -- defines it. Two spellings and one of the three silently stops
# recognising P5's own controller. Asserted on the SHIPPED files, not the harness.
asrt "SH-10b the shipped init script carries the ownership marker on line 3" \
     "$(sed -n '3p' "$P5/init.d/p5-shape")" "# P5-OWNED-INIT: deploy/p5/init.d/p5-shape"
asrt "SH-10b and shape-install checks for exactly that string" \
     "$(grep -c 'P5_MARK="P5-OWNED-INIT: deploy/p5/init.d/p5-shape"' "$P5/shape-install")" 1
asrt "SH-10b and bond-xctl defines exactly that string (what the shape leaves grep for)" \
     "$(grep -c 'P5_MARK="P5-OWNED-INIT: deploy/p5/init.d/p5-shape"' "$P5/bond-xctl")" 1
# ABSENT: the controller p5-install should have placed is not there at all.
# Distinct from FOREIGN and it must not read as clean -- a box with no
# controller cannot shape, and a payload made live under one is a lie.
setup; si_world; si_supply
rm -f "$SI/etc/init.d/p5-shape"
SH10g=$(shapeinst install)
asrt "SH-10b an ABSENT controller refuses the install (exit 6, not a silent placement)" "$(sirc install)" 6
asrt "SH-10b and the refusal says WHO places it -- p5-install, from the filemap row" \
     "$( [ "$(echo "$SH10g" | grep -c 'p5-install')" -ge 1 ] && [ "$(echo "$SH10g" | grep -c 'filemap')" -ge 1 ] && echo named || echo vague )" named
asrt "SH-10b and this installer still wrote nothing into /etc/init.d" \
     "$( [ -e "$SI/etc/init.d/p5-shape" ] && echo wrote || echo no )" no
# P5's OWN controller is replaceable and removable -- the guard is about
# foreign files, never about refusing to manage our own.
setup; si_world; si_supply; shapeinst install >/dev/null 2>&1
asrt "SH-10b re-install over P5's OWN marked controller is fine"  "$(sirc install)" 0
asrt "SH-10b and remove takes P5's own controller away" \
     "$(sirc remove)$( [ -e "$SI/etc/init.d/p5-shape" ] && echo kept || echo gone )" "0gone"

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
asrt "SH-11a install refuses and stages nothing" "$(sirc install)$( [ -e "$SI/usr/lib/p5/p5-shape" ] && echo yes || echo no )" "5no"
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
asrt "SH-11d endpoint still pinned local"             "$(epv)" "127.0.0.1:59402"
asrt "SH-11d NO suspend crumb was walked" \
     "$( [ -f "$WORK/run/p5/suspended" ] || [ -f "$WORK/run/p5/suspended-degraded" ] && echo yes || echo no )" no
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
# code()/lint_hits() are defined ONCE, above SH-8, so every bar in this block
# gets the same fail-closed treatment. Defining them here left the SH-8 pin bars
# and the SH-9/SH-12 code bars reading missing files as clean.
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
asrt "SH-13 the shipped init script fetches nothing"                     "$(lint_hits "$P5/init.d/p5-shape" "$FETCH")" 0
asrt "SH-13 CONTROL: the lint FIRES on a fetching script (the instrument is sensitive)" \
     "$( [ "$(lint_hits "$_CTL" "$FETCH")" -gt 0 ] && echo fires || echo BLIND )" fires
asrt "SH-12 shape-install touches NO management path"  "$(lint_hits "$P5/shape-install" "$MGMT")" 0
asrt "SH-12 the shipped init script touches no management path" "$(lint_hits "$P5/init.d/p5-shape" "$MGMT")" 0
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
     "$(lint_hits "$P5/shape-install" 'wgclient1')" 0
asrt "SH-12 no wgclient1 literal in the shipped init script" \
     "$(lint_hits "$P5/init.d/p5-shape" 'wgclient1')" 0
# The SKU bar is a LITERAL lint and it can only ever see a literal. A refusal
# written as `case "$_model" in GL-MT6*)` walks straight past it -- MEASURED,
# 2026-08-30 verify. SH-16 below is the behavioural bar for that direction:
# non-GL-MT6000 models with full capabilities must reach READY.
asrt "SH-12 no single-SKU model match in the install path (GL-MT6000/GL-MT2500)" \
     "$(lint_hits "$P5/shape-install" 'GL-MT(6000|2500)')" 0

# SH-14 — REMOVAL IS NAMESPACE-GUARDED. E0's B1 lost an SSH key by turning a
# contract row straight into an unlink. `remove` refuses any base outside
# /usr/lib/p5/, which is the only directory P5 exclusively owns.
setup; si_world; si_supply; shapeinst install >/dev/null 2>&1
asrt "SH-14 remove is idempotent and succeeds"  "$(sirc remove)" 0
asrt "SH-14 the payload is gone"  "$( [ -e "$SI/usr/lib/p5/p5-shape" ] && echo yes || echo no )" no
asrt "SH-14 remove again is still 0 (idempotent)" "$(sirc remove)" 0
_evil="$WORK/etc"
_out=$(BOND_DIR="$WORK/etc/p5" P5_SHARE="$SI/share" \
       SHAPE_BASE="$_evil" SHAPE_SVC="$SI/etc/init.d/p5-shape" \
       sh "$P5/shape-install" remove 2>&1; echo "rc=$?")
asrt "SH-14 remove REFUSES a base outside P5's namespace" "$(echo "$_out" | grep -c 'refusing to remove')" 1
asrt "SH-14 and that directory still exists"  "$( [ -d "$_evil" ] && echo yes || echo no )" yes
# The namespace guard matches the `/usr/lib/p5/` SEGMENT so that the harness can
# drive the REAL remove path under a test root. That is only safe while the
# SHIPPED default base is the absolute one -- assert it, or the relaxation
# becomes a way to ship a base outside the namespace.
# literal shipped source: shape-install's own ${SHAPE_BASE:-/usr/lib/p5/...} default line.
# shellcheck disable=SC2016
asrt "SH-14 the SHIPPED default SHAPE_BASE is inside P5's absolute namespace" \
     "$(grep -c '^SHAPE_BASE="\${SHAPE_BASE:-/usr/lib/p5/' "$P5/shape-install")" 1
asrt "SH-14 a traversal base is refused even inside the namespace" \
     "$(BOND_DIR="$WORK/etc/p5" P5_SHARE="$SI/share" \
        SHAPE_BASE="/usr/lib/p5/../../../etc" SHAPE_SVC="$SI/etc/init.d/p5-shape" \
        sh "$P5/shape-install" remove 2>&1 | grep -c 'refusing to remove')" 1

# SH-15 — THE BAR THAT GOES RED ON A TREE WITH NO INSTALL HALF, and the one
# that would have caught U18's un-manifested-shipped-file defect. It reads
# bond-xctl's OWN SHAPE_SVC and asserts (a) a producer for exactly that path is
# in the shipped set, and (b) every new shipped artifact is in the manifest job.
# sed SCRIPT matching bond-xctl's literal ${SHAPE_SVC:-...} default; expanding it would
# rewrite the pattern and SVC_PATH would come back empty.
# shellcheck disable=SC2016
SVC_PATH=$(grep -m1 '^SHAPE_SVC=' "$P5/bond-xctl" | sed -e 's/^SHAPE_SVC="\${SHAPE_SVC:-//' -e 's/}"$//')
SVC_BASE=$(basename "$SVC_PATH")
asrt "SH-15 bond-xctl's SHAPE_SVC resolves to a name"      "$( [ -n "$SVC_BASE" ] && echo yes || echo no )" yes
asrt "SH-15 an INSTALL HALF exists and is executable"      "$( [ -x "$P5/shape-install" ] && echo yes || echo no )" yes
asrt "SH-15 it ships an init script named exactly SHAPE_SVC's basename" \
     "$( [ -f "$P5/init.d/$SVC_BASE" ] && echo yes || echo no )" yes
asrt "SH-15 it ships the vendor PIN record"                "$( [ -f "$P5/shape/cake-autorate.pin" ] && echo yes || echo no )" yes
# WHO PLACES IT CHANGED WITH U210, so what this bar reads changed with it. The
# producer is now the FILEMAP: p5-install writes exactly SHAPE_SVC's path from a
# row, and shape-install writes NOTHING into /etc/init.d at all. Both halves are
# asserted, because either one alone can be true while the product is broken.
asrt "SH-15 a filemap row places exactly that path"        "$(grep -c "|$SVC_PATH\$" "$REPO/p5/payload/filemap")" 1
# literal shipped source: the pattern hunts shape-install's own `$SHAPE_SVC`
# TEXT. Expanding it here would search for the harness fixture path, match
# nothing, and the bar would read 0 and go GREEN for the wrong reason.
# shellcheck disable=SC2016
asrt "SH-15 and the shipped installer writes NOTHING into /etc/init.d" \
     "$(lint_hits "$P5/shape-install" '(mv|cp) [^;&]*\$SHAPE_SVC')" 0
WF="$REPO/.github/workflows/emulator-gate.yml"
# Both manifest steps must carry each new artifact: the completeness ABORT list
# and the sha256sum line. The previous form counted occurrences ANYWHERE in the
# workflow and wanted >=2. MEASURED, 2026-08-30 verify: deleting `shape-install`
# from BOTH lists still left count=2 (the step comment at :357 and the echo at
# :385), so the bar read `pinned` and PASSED; `shape/cake-autorate.pin` still
# counted 3. A shipped artifact could drop out of MANIFEST.sha256 with `manifest`
# and `recon-ecosim` both green. Prose was making the bar pass, not flap.
# So: read the TWO LISTS THEMSELVES. wf_list joins a backslash-continued logical
# line starting at an anchor, and each artifact must appear as a WHOLE WORD in
# each list. Anchored on the first artifact name, which is itself a shipped
# file; if the job is restructured the anchor stops matching, the list comes
# back empty and the bar goes RED rather than quietly passing.
wf_list() {
    [ -f "$1" ] || { echo NOFILE; return; }
    awk -v re="$2" '
        inl==0 && $0 ~ re {inl=1}
        inl==1 {
            t=$0; sub(/[ \t]+$/,"",t)
            cont = (substr(t,length(t),1) == "\\")
            # strip the continuation backslash with substr, NOT sub(/\\$/..).
            # MEASURED here: awk processes escapes in a regex CONSTANT before
            # compiling it, so /\\$/ becomes the ERE \$ -- a literal dollar --
            # and matches nothing. It left a bare `\` in every joined list.
            # substr has no escape layer to get wrong.
            if (cont) t = substr(t, 1, length(t) - 1)
            l = l " " t
            if (!cont) { print l; exit }
        }' "$1"
}
# the artifact names in one of those logical lines, shell noise removed.
# The lone-backslash filter is `^[\]$` and not `^\\$` for the same reason:
# MEASURED, GNU grep 3.0 -- `grep -Ec '^\\$'` on a file whose only line is a
# backslash returns 0, `grep -Ec '^[\]$'` returns 1. A filter that silently
# matches nothing is how noise gets into a set comparison.
wf_words() {
    # shellcheck disable=SC2020  # the repeated \n is deliberate: tr maps set to set
    # POSITIONALLY, so space->newline and tab->newline. Not a word replacement.
    printf '%s\n' "$1" | tr ' \t' '\n\n' | sed 's/;$//' \
        | grep -Ev '^$|^[\]$|^\|$|^(for|f|in|do|sha256sum|tee|MANIFEST\.sha256)$'
}
_MFA=$(wf_list "$WF" '^ *for f in bond-xctl')
_MFS=$(wf_list "$WF" '^ *sha256sum bond-xctl')
asrt "SH-15 the manifest COMPLETENESS list is where it is expected to be" \
     "$( [ -n "$_MFA" ] && [ "$_MFA" != NOFILE ] && echo found || echo MISSING )" found
asrt "SH-15 the MANIFEST.sha256 list is where it is expected to be" \
     "$( [ -n "$_MFS" ] && [ "$_MFS" != NOFILE ] && echo found || echo MISSING )" found
for _a in shape-install "init.d/$SVC_BASE" "shape/cake-autorate.pin"; do
    asrt "SH-15 the completeness ABORT list names '$_a' (U18: an un-manifested shipped file is a deploy defect)" \
         "$(wf_words "$_MFA" | grep -cx -- "$_a" | tr -d ' ')" 1
    asrt "SH-15 the MANIFEST.sha256 list names '$_a'" \
         "$(wf_words "$_MFS" | grep -cx -- "$_a" | tr -d ' ')" 1
done
# and the two lists must be the SAME SET, so neither can drift from the other in
# either direction -- an entry in the ABORT list that never gets sha256'd is the
# U18 defect wearing a different hat.
wf_words "$_MFA" | sort > "$WORK/mf.abort"
wf_words "$_MFS" | sort > "$WORK/mf.sha"
asrt "SH-15 the two manifest lists are the SAME artifact set (neither can drift)" \
     "$(diff "$WORK/mf.abort" "$WORK/mf.sha" >/dev/null 2>&1 && echo same || echo DRIFTED)" same
asrt "SH-15 and that set is non-empty" \
     "$( [ -s "$WORK/mf.abort" ] && echo yes || echo no )" yes

# SH-16 — THE CAPABILITY GATE, MEASURED IN BOTH DIRECTIONS.
# Item (4) of this unit's six is "CAPABILITY gate, not SKU". Until now it was
# proven only by the ABSENCE of a string literal (SH-12's GL-MT lint). MEASURED,
# 2026-08-30 adversarial verify: deleting ALL NINE `cap` invocations from the
# shipped shape-install changed NOTHING -- the whole SH-8..SH-15 battery scored
# 98/0 on both trees and the outputs were byte-identical -- while the mutated
# installer returned preflight rc=0 and INSTALLED on a world with no tc, no
# sch_cake, no ifb, no act_mirred and no rc.common. And the other direction:
# re-introducing the single-SKU refusal as `case "$_model" in GL-MT6*) : ;; *)
# return 4` refused a fully-capable GL-MT2500 while SH-12's literal lint still
# read 0. Neither direction of the actual behaviour was measured. These bars
# measure it.
#
# Making a capability genuinely ABSENT needs control of PATH: `have` is
# `command -v`, so tc/bash/a pinger/sha256sum cannot be hidden by any of the
# root overrides. si_bin builds a HERMETIC PATH -- one wrapper per utility
# shape-install actually uses -- and omits whatever it is told to. That is also
# what makes the tunnel_if bar real: with $BIN on PATH the `ip link show`
# fallback would succeed against the ecosim shim.
si_bin() {   # si_bin [tool...] — hermetic PATH for shape-install, omitting [tool...]
    # ${SI:?} not $SI: `set -u` catches UNSET, not EMPTY, and an empty $SI turns this
    # into `rm -rf /bin`. shellcheck SC2115. The harness runs as whoever runs CI.
    rm -rf "${SI:?}/bin" 2>/dev/null; mkdir -p "$SI/bin"
    # `ip` is deliberately NOT in this list. si_bin resolves each tool with
    # `command -v` under the AMBIENT PATH, and run.sh has already put $BIN on it --
    # so a wrapper for `ip` would point at the ECOSIM SHIM, whose whole job is to
    # report that wgclient1 exists. The tunnel_if bar then finds the capability
    # PRESENT and never refuses. Measured 2026-08-31: adding `ip` here turned all
    # four SH-16 tunnel_if bars red. IP stays pointed at $SI/bin/ip, which is never
    # created, so the fallback fails deterministically under bash AND ash.
    # RESOLVE BY EXPLICIT PATH SEARCH, NOT BY `command -v`.
    #
    # `command -v` is not portable in the way this harness needs. MEASURED 2026-08-31 by the
    # census step above, on the same runner and the same PATH:
    #
    #   name   applet   busybox-ash            dash
    #   ping   YES      ping                   /.../ecosim/p5/bin/ping
    #   tc     YES      tc                     /.../ecosim/p5/bin/tc
    #
    # For an APPLET NAME busybox ash answers with the BARE NAME; dash and bash answer with a
    # path. Two failures came out of that one difference:
    #   1. `exec "$_r" "$@"` with a bare name, under PATH="$SI/bin", made every wrapper exec
    #      ITSELF -- a fork bomb that SIGTERM could not kill (ash arm, exit 137 at 420s).
    #   2. Routing bare names through `busybox <name>` instead fixed the bomb but changed WHAT
    #      RAN: busybox's own applet rather than the ecosim shim that dash resolves to, so
    #      SH-16's positive controls refused with exit 4 -- green-looking machinery measuring
    #      the wrong binary.
    #
    # So do not ask the shell. Walk $PATH and take the first executable file, which is what
    # bash and dash do and what the harness means. Shell-independent by construction, and the
    # SAME binary is selected under every interpreter -- which is the entire point of a parity
    # gate. $SI/bin is skipped defensively so a wrapper can never select a wrapper.
    _si_which() {   # _si_which NAME -> absolute path, or nothing
        case "$1" in
            /*) [ -x "$1" ] && printf '%s\n' "$1"; return ;;
        esac
        _w_old=$IFS
        IFS=:
        for _w_d in $PATH; do
            [ -n "$_w_d" ] || _w_d=.
            case "$_w_d" in "$SI/bin") continue ;; esac
            if [ -f "$_w_d/$1" ] && [ -x "$_w_d/$1" ]; then
                IFS=$_w_old
                printf '%s\n' "$_w_d/$1"
                return
            fi
        done
        IFS=$_w_old
    }
    for _u in sh awk cat chmod cp cut dirname find grep mkdir mv rm sed sha256sum \
              touch tr uname wc tc bash ping fping; do
        for _o in "$@"; do [ "$_u" = "$_o" ] && continue 2; done
        _r=$(_si_which "$_u")
        [ -n "$_r" ] || continue
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$_r" > "$SI/bin/$_u"
        chmod 0755 "$SI/bin/$_u"
    done
}
SHBIN=$(command -v sh 2>/dev/null); [ -n "$SHBIN" ] || SHBIN=/bin/sh
# INJECTED, not merely PATH-shadowed -- the same lesson as IP/PING above (U69),
# re-earned here by U67a. The hermetic PATH cannot hide `tc`, `sha256sum`, `ping`
# or `fping` from busybox ash, which runs its own applet for those names and never
# consults $PATH; under it every cap_gone bar for an applet PASSED when it was
# supposed to refuse. Pointing each at $SI/bin/<tool> makes absence real, because
# `command -v` on an ABSOLUTE PATH asks the filesystem in every shell. si_bin omits
# the wrapper, so the path stops resolving -- in bash and ash alike.
shapeinst_h() {   # the SHIPPED file again, this time on the hermetic PATH
    PATH="$SI/bin" BOND_DIR="$WORK/etc/p5" WG_DEV=wgclient1 \
    TC="$SI/bin/tc" BASH_BIN="$SI/bin/bash" FPING="$SI/bin/fping" \
    PING="$SI/bin/ping" SHA256SUM="$SI/bin/sha256sum" IP="$SI/bin/ip" \
    P5_SHARE="$SI/share" \
    SHAPE_BASE="$SI/usr/lib/p5/p5-shape" SHAPE_SVC="$SI/etc/init.d/p5-shape" \
    SQM_CONF="$SI/etc/config/sqm" SYSINFO_MODEL="$SI/model" GLVERSION="$SI/glversion" \
    SYS_MODULE="$SI/mod" PROC_MODULES="$SI/proc_modules" MODDIR="$SI/moddir" \
    SYS_CLASS_NET="$SI/net" RC_COMMON="$SI/rc.common" PROCD_BIN="$SI/procd" \
    "$SHBIN" "$P5/shape-install" "$@" 2>&1
}
sirc_h() { shapeinst_h "$@" >/dev/null 2>&1; echo $?; }
# si_placed -- "this installer changed something on the box". THE CONTROLLER IS
# NO LONGER ITS OUTPUT (U210): p5-install places /etc/init.d/p5-shape from a
# filemap row before this installer ever runs, so its PRESENCE proves nothing.
# What must hold instead is that nothing was STAGED and the controller BYTES are
# exactly the ones p5-install wrote -- the stronger statement, and the one that
# catches a regression back to writing /etc/init.d directly.
SI_CTL_PRISTINE=$(sha256sum "$P5/init.d/p5-shape" | awk '{print $1}')
si_placed() { [ -e "$SI/usr/lib/p5/p5-shape" ] || [ "$(si_ctlsum)" != "$SI_CTL_PRISTINE" ]; }

# POSITIVE CONTROL FIRST: a gate that only ever refuses proves nothing, and a
# hermetic PATH that broke the installer would make every bar below vacuous.
setup; si_world; si_supply; si_bin
asrt "SH-16 positive control: full capabilities on the hermetic PATH => READY" "$(sirc_h preflight)" 0
asrt "SH-16 positive control: and it installs"                                 "$(sirc_h install)" 0
asrt "SH-16 positive control: it staged the payload and left the controller alone" \
     "$( [ -e "$SI/usr/lib/p5/p5-shape/current" ] && [ "$(si_ctlsum)" = "$SI_CTL_PRISTINE" ] && echo yes || echo no )" yes

# cap_gone NAME "<PATH tools to omit>" "<world-breaking command>"
# One capability removed at a time, so deleting ONE `cap` line from the shipped
# installer makes exactly its own bars go red and deleting all nine makes all of
# them go red.
cap_gone() {
    _cn="$1"; _com="$2"; _cbk="$3"
    setup; si_world; si_supply
    # shellcheck disable=SC2086  # unquoted ON PURPOSE: $_com is a LIST of tool
    # names ("ping fping") and si_bin takes one argument per tool. Quoting it would
    # pass a single tool literally named "ping fping", which exists nowhere, so every
    # cap_gone bar would refuse for the wrong reason and still look green.
    si_bin $_com
    [ -z "$_cbk" ] || eval "$_cbk"
    _co=$(shapeinst_h preflight)
    asrt "SH-16 capability '$_cn' absent => preflight REFUSES (exit 4)" "$(sirc_h preflight)" 4
    asrt "SH-16 '$_cn': the refusal names THAT capability" \
         "$(printf '%s\n' "$_co" | grep -c "CAP  MISSING $_cn")" 1
    asrt "SH-16 '$_cn': install refuses too (exit 4)" "$(sirc_h install)" 4
    asrt "SH-16 '$_cn': and NOTHING was placed -- nothing staged, controller bytes untouched" \
         "$(si_placed && echo placed || echo nothing)" nothing
}
cap_gone tc         "tc"         ""
# deferred command string: cap_gone eval-s it LATER, against the $SI live at that point.
# shellcheck disable=SC2016
cap_gone sch_cake   ""           'rm -rf "${SI:?}/mod/sch_cake"'
# deferred command string: cap_gone eval-s it LATER, against the $SI live at that point.
# shellcheck disable=SC2016
cap_gone ifb        ""           'rm -rf "${SI:?}/mod/ifb"'
# deferred command string: cap_gone eval-s it LATER, against the $SI live at that point.
# shellcheck disable=SC2016
cap_gone act_mirred ""           'rm -rf "${SI:?}/mod/act_mirred"'
cap_gone bash       "bash"       ""
cap_gone pinger     "ping fping" ""
# deferred command string: cap_gone eval-s it LATER, against the $SI live at that point.
# shellcheck disable=SC2016
cap_gone rc_common  ""           'rm -f "${SI:?}/rc.common"'
cap_gone sha256sum  "sha256sum"  ""
# deferred command string: cap_gone eval-s it LATER, against the $SI live at that point.
# shellcheck disable=SC2016
cap_gone tunnel_if  ""           'rm -rf "${SI:?}/net/wgclient1"'

# AND THE MUTANT'S OWN WORLD, verbatim: no tc, no sch_cake, no ifb, no
# act_mirred, no rc.common. That is the exact world in which the gate-deleted
# installer returned rc=0 and INSTALLED. One bar, so a mutation that removes the
# whole gate cannot be argued down to "one probe regressed".
setup; si_world; si_supply
si_bin tc
rm -rf "${SI:?}/mod/sch_cake" "$SI/mod/ifb" "$SI/mod/act_mirred"; rm -f "${SI:?}/rc.common" "$SI/procd"
_CO0=$(shapeinst_h preflight)
asrt "SH-16 a world with NO shaping capabilities at all REFUSES (exit 4)" "$(sirc_h preflight)" 4
asrt "SH-16 and it names every missing one (tc sch_cake ifb act_mirred rc_common)" \
     "$(printf '%s\n' "$_CO0" | grep -c 'CAP  MISSING ')" 5
asrt "SH-16 install in that world refuses (exit 4)"  "$(sirc_h install)" 4
asrt "SH-16 and it placed NOTHING -- nothing staged, controller bytes untouched" \
     "$(si_placed && echo placed || echo nothing)" nothing

# and the verdict line itself, once
setup; si_world; si_supply; si_bin; rm -rf "${SI:?}/mod/sch_cake"
asrt "SH-16 the refusal prints VERDICT: REFUSE (4), not a capability-shaped 3" \
     "$(shapeinst_h preflight | grep -c 'VERDICT: REFUSE (4)')" 1

# THE OTHER DIRECTION — IDENTITY IS NEVER THE REFUSAL. A GL-MT2500 (the SERVER
# SKU the reused P1 predicate refused outright), another GL SKU, a non-GL
# OpenWrt box, and a box with no /tmp/sysinfo/model at all must ALL reach READY
# and install when the capabilities are there. This is the bar the SKU-literal
# lint cannot be: it goes red on `case "$_model" in GL-MT6*) : ;; *) return 4`,
# which contains no matched literal.
for _m in GL-MT2500 GL-AXT1800 Some-Other-Router NOMODEL; do
    setup; si_world; si_supply; si_bin
    if [ "$_m" = NOMODEL ]; then rm -f "$SI/model"; else printf '%s\n' "$_m" > "$SI/model"; fi
    asrt "SH-16 model '$_m' with full capabilities reaches READY (identity is read, never a refusal)" \
         "$(sirc_h preflight)" 0
    asrt "SH-16 model '$_m' installs"  "$(sirc_h install)" 0
    asrt "SH-16 model '$_m' got the controller placed" \
         "$( [ -x "$SI/etc/init.d/p5-shape" ] && echo yes || echo no )" yes
done

# SH-17 — A MANGLED PIN LINE IS A REFUSAL, NOT A SMALLER PIN.
# The comment over shape-install's `pin_files()` claimed "a malformed pin yields
# fewer entries and the count checks below fail closed" (cited by function name,
# not by line: shape-install is being edited in this same unit and a line number
# rots on the next inserted comment). The only count check was `-gt 0`.
# MEASURED, 2026-08-30 verify: mangling the FILES line of a pinned-but-unstaged
# file and deleting it from vendor/ gave rc=0, "2 file(s) pinned, 2 staged" and
# a DIFFERENT version id while reporting success -- which defeats the pin's own
# stated reason for keeping those files pinned (the version id must change if
# any of the vendored set changes). pin_files_declared now makes the parsed
# count equal the declared count.
setup; si_world; si_supply
_V0=$(shapeinst install >/dev/null 2>&1; cat "$SI/usr/lib/p5/p5-shape/current")
setup; si_world; si_supply
sed -i 's/^\([0-9a-f]\{64\}\)  uninstall\.sh$/MANGLED uninstall.sh/' "$SI/share/cake-autorate.pin"
rm -f "$SI/share/vendor/uninstall.sh"
SH17=$(shapeinst install)
asrt "SH-17 a mangled FILES line REFUSES the install (never a quietly smaller pin)" "$(sirc install)" 3
asrt "SH-17 and it says the FILES block is malformed" \
     "$(printf '%s\n' "$SH17" | grep -c 'MALFORMED FILES block')" 1
asrt "SH-17 and nothing was installed under the wrong version id" \
     "$( [ -e "$SI/usr/lib/p5/p5-shape/current" ] && echo installed || echo nothing )" nothing
asrt "SH-17 control: the same pin unmangled installs, at the id the clean pin derives" \
     "$( setup; si_world; si_supply; shapeinst install >/dev/null 2>&1; cat "$SI/usr/lib/p5/p5-shape/current" )" "$_V0"

# SH-18 — A CITATION IN A SHIPPED FILE MUST RESOLVE.
# MEASURED, 2026-08-30 verify: shape-install attributed "a lingering pin must not
# blackhole clients' DNS" to bootstrap-autorate.sh:87-88; the text is at line 40.
# Wrong by 47 lines, in a file that ships. Two bars, because they fail in
# different worlds:
#   (a) NO line-number citation into an EDITED file may exist in the shipped
#       installer. A number rots on the next inserted comment -- which is the
#       defect, not the arithmetic -- so the ban covers the executable trees
#       (p1-autorate/ and deploy/p5/, both of which this project edits) and not
#       a frozen capture like the box inventory, whose lines never move.
#       This one runs everywhere, mirror included.
#   (b) every ANCHOR the installer names must actually be findable in the file
#       it names. Needs p1-autorate/, which the public mirror does not publish,
#       so it is a NOTE there and never a PASS.
CITE='(bootstrap-autorate\.sh|bond-xctl|bondctl|bond-ecod|bond-watchdog|shape-install|cake-autorate|bond\.dag):[0-9]|^#[[:space:]]*:[0-9]+-[0-9]+'
asrt "SH-18 no line-number citation into an edited file survives in the installer" \
     "$(f_hits "$P5/shape-install" "$CITE")" 0
asrt "SH-18 nor in the shipped init script" \
     "$(f_hits "$P5/init.d/$SVC_BASE" "$CITE")" 0
# U70: the control's artifact name below is CONSTRAINED FROM TWO SIDES. It must
# be in CITE above (or this control is blind) and must NOT be in
# citation_check.py's ARTIFACTS (or CIT-1 flags the control itself as a rotting
# citation -- the U70 merge clash, settled by respelling away from a name in
# both vocabularies). If a later unit adds shape-install to ARTIFACTS, CIT-1
# goes red HERE: respell the control to a CITE name still outside ARTIFACTS.
# Never exempt it in the gate -- that blinds CIT-1 to a genuine rot nearby.
asrt "SH-18 CONTROL: the lint FIRES on a line-number citation (the instrument is sensitive)" \
     "$( printf '%s\n' '# see shape-install:60 for the default' > "$WORK/cite-control.sh"
        [ "$(f_hits "$WORK/cite-control.sh" "$CITE")" -gt 0 ] && echo fires || echo BLIND )" fires
if [ -f "$_P1B" ]; then
    for _anc in 'grep -q "GL-MT6000" /tmp/sysinfo/model' \
                '^# ---- retire v1 machinery' \
                '^# ---- cake-autorate' \
                '^WG_REFLECTORS=' \
                '^WG_DL_MIN_KBIT='; do
        asrt "SH-18 the anchor shape-install cites resolves in P1's bootstrap: '$_anc'" \
             "$( [ "$(f_hits "$_P1B" "$_anc")" -ge 1 ] && echo resolves || echo DANGLING )" resolves
    done
else
    echo "NOTE  SH-18(b) anchor resolution NOT RUN: p1-autorate/ is not in this tree"
    echo "NOTE  (the public CI mirror publishes only what CI builds). Run the full repo for it."
    echo "NOTE  SH-18(a), the no-line-numbers lint, DID run and is asserted above."
fi

# SH-19 — NO SHIPPED FILE MAY DEFAULT A KNOWN EXTERNAL TOOL TO ITS BARE NAME.
# U67i. This is a STATIC bar on purpose, and it is the teeth of this unit.
#
# THE DEFECT CLASS. busybox ash is a STANDALONE shell: for any name in its applet
# table it runs its OWN applet and never consults $PATH. `tc`, `ip`, `ping`,
# `fping`, `sha256sum` and `bash` are applet names, and busybox `tc` has no cake
# qdisc. So `TC="${TC:-tc}"` in a shipped file does not mean "the tool on PATH",
# it means "busybox's cut-down applet", and no caller can override that from
# outside the process. Shaping is INV8 -- it never escalates, only logs -- so the
# consequence on a box with no console is SILENT AND PERMANENT.
#
# WHY STATIC AND NOT ONLY BEHAVIOURAL. Measured on this branch, 2026-09-01: the
# behavioural seed for it (busybox.yml job `bisect`, seed 4) does NOT redden --
# restoring the bare name in the installer leaves the battery at 412 pass / 0
# fail. That is not a reason to skip the seed, it is the reason this bar exists.
# The two shaping files are reached by the harness only through paths that
# INJECT absolute tool paths (the hermetic SH-16 world) or through worlds where
# the ecosim shim and busybox's applet behave the same, and the init script is
# never executed here at all (Layer-2 substitutes svc-shape). No behavioural bar
# in this tree can see the defect, which is exactly how it survived U67h's fix
# in the file next to it. A static bar can see it, so a static bar is what
# guards it.
#
# SCOPE. Every file under deploy/p5, not a named list -- the unit was scoped to
# two files and this lint found a THIRD (`bond-ecod`, PING). A named list would
# have missed it, and would miss the next one the same way.
#
# THE FLOOR IS PART OF THE BAR (U65/U22a): `grep -c` over an empty file set is 0,
# which is the wanted value, so a broken selector would score a clean PASS while
# measuring nothing. bare_defaults refuses to answer below MINFILES and the
# sentinel it returns is not any wanted value.
_BT='(tc|ip|ping|fping|sha256sum|bash)'
# Two forms, both anchored to a whole assignment so a USE like `"$TC" qdisc ...`
# or a path like `/bin/ping` can never match: `V="${V:-tool}"` and `V=tool`.
BARE='="?\$\{[A-Za-z_][A-Za-z0-9_]*:-'"$_BT"'\}"?[[:space:]]*$|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?'"$_BT"'"?[[:space:]]*$'
bare_defaults() {   # bare_defaults DIR MINFILES -> hit count over DIR, comments stripped
    # `while read < FILE`, not `for f in $(find ...)` (SC2044) and not a PIPE into
    # the loop: a piped loop is a SUBSHELL in every POSIX shell here, and the two
    # counters it increments would be discarded -- the bar would then report 0
    # hits over 0 files no matter what the tree held.
    [ -d "$1" ] || { echo NODIR; return; }
    find "$1" -type f ! -name '.gitkeep' 2>/dev/null > "$WORK/bare.list"
    _bd_n=0; _bd_h=0
    while IFS= read -r _bd_f; do
        _bd_n=$((_bd_n+1))
        _bd_h=$(( _bd_h + $(sed 's/#.*//' "$_bd_f" | grep -Ec -- "$BARE" | tr -d ' ') ))
    done < "$WORK/bare.list"
    [ "$_bd_n" -ge "$2" ] || { echo "TOOFEW($_bd_n<$2)"; return; }
    echo "$_bd_h"
}
asrt "SH-19 no shipped file under deploy/p5 defaults a known tool to its bare name" \
     "$(bare_defaults "$P5" 12)" 0
# POSITIVE CONTROL. The one line U67h deleted from the reconciler, in its own
# directory with its own floor of 1: the lint must FIRE on it, or the assert
# above is a green square over an instrument that cannot see anything.
# printf builds the BODY of the shipped-file FIXTURE the lint then reads: $TC belongs to
# that generated file, and expanding it here would write the harness's value instead.
# shellcheck disable=SC2016
asrt "SH-19 CONTROL: the lint FIRES on a restored bare-name default (the instrument is sensitive)" \
     "$( rm -rf "$WORK/barectl"; mkdir -p "$WORK/barectl"
        printf '%s\n' '#!/bin/sh' 'TC="${TC:-tc}"' '"$TC" qdisc show dev wgclient1' \
            > "$WORK/barectl/shipped-file"
        [ "$(bare_defaults "$WORK/barectl" 1)" -gt 0 ] && echo fires || echo BLIND )" fires
# NEGATIVE CONTROL, the other direction: the FIXED shape must NOT trip it, or the
# bar would be unsatisfiable and the only way green is to weaken it.
# printf builds the BODY of the shipped-file FIXTURE the lint then reads: ${TC:-} and
# $_tool_path belong to that generated file, not to this shell.
# shellcheck disable=SC2016
asrt "SH-19 CONTROL: the \$PATH-walk shape does NOT trip the lint (the bar is satisfiable)" \
     "$( rm -rf "$WORK/barectl"; mkdir -p "$WORK/barectl"
        printf '%s\n' '#!/bin/sh' '[ -n "${TC:-}" ] || { _tool tc; TC=$_tool_path; }' \
            '"$TC" qdisc show dev wgclient1' > "$WORK/barectl/shipped-file"
        bare_defaults "$WORK/barectl" 1 )" 0
# And the floor itself is measured, not merely written: an empty tree must NOT
# score the wanted 0.
asrt "SH-19 CONTROL: an empty shipped tree refuses to answer (absent is not clean)" \
     "$( rm -rf "$WORK/barectl"; mkdir -p "$WORK/barectl"; bare_defaults "$WORK/barectl" 12 )" \
     "TOOFEW(0<12)"

# NS-5 — NO SHIPPED FILE MAY NAME AN OLD-STACK DESTINATION. U51a, ADR-005 SS4.
#
# WHAT IT ASSERTS. `p5/contract/foreign` declares the bond namespace FOREIGN --
# paths P5 must never write. Until this unit, `deploy/p5` shipped to exactly
# those paths, so the installer would have refused every one of its own
# artifacts at its destination check. ADR-005 resolved that by MOVING the
# destinations into the p5-* namespace rather than widening the contract, and
# this bar is the thing that keeps them moved.
#
# DERIVED, NOT RE-TYPED. The forbidden set is read out of contract/foreign at
# run time. A hand-copied list here would be a second copy of a fact that lives
# somewhere else, which is the drift class this repo keeps paying for, and it
# would go quietly stale the moment a row is added. Reading the contract also
# means that adding a bond row to it immediately widens this bar.
#
# STATIC, AND THAT IS THE POINT. No behavioural bar in this tree can see a wrong
# default: the harness EXPORTS BOND_DIR / RUN_DIR / DAG / AGG_SVC and the shims
# stand in for every service, so the shipped defaults are never the values under
# test. The same blind spot is why SH-19 exists one bar up. A default that is
# only ever overridden is only ever checked by a static lint.
#
# THE FLOOR IS PART OF THE BAR (U65/U22a, same shape as SH-19). Two ways to
# score a false clean: an empty file set, and an empty PATTERN set (grep -F with
# no patterns matches nothing). Both are refused with a sentinel that is not any
# wanted value, and both are asserted rather than asserted about.
#
# SCOPE AND ITS WAIVERS, named with their owners rather than hidden in a glob:
#   deploy/p5/portal/**   the M9 portal (U23; U56/U120 carry it). It names
#                         BOND_DIR / BONDCTL / XCTL destinations of its own and
#                         is not this unit's to edit.
#   deploy/p5/bond-accept P5's acceptance runner (U56), unmerged today.
#   deploy/p5/facts       the U133 fact LEDGER, and
#   deploy/p5/test-facts.sh its checker. Both are REPO-ONLY DATA: they name every
#                         fact destination on purpose, because naming them IS
#                         the artifact. Neither is installed -- deploy/p5/test-facts.sh
#                         bar FD-11 names BOTH files and asserts both are absent
#                         from p5/payload/filemap and from p5-install's map (and
#                         reds if either of those two files has MOVED, rather than
#                         reading a zero-hit grep as clean), so NS-5's subject (a
#                         SHIPPED file carrying an old destination) cannot apply.
# Both are LISTED, not skipped silently: the NOTE below prints their current hit
# count every run, so the waiver cannot quietly become the whole tree.
FOREIGN_FILE="$REPO/p5/contract/foreign"
old_dests() {   # -> one forbidden destination literal per line, from the contract
    [ -r "$1" ] || { echo NOFILE; return; }
    sed 's/#.*//' "$1" \
      | grep -E '^p[34]\|(/etc/bond|/var/run/bond|/usr/sbin/bond|/etc/init\.d/bond|/etc/hotplug\.d/iface/97-bond)' \
      | cut -d'|' -f2 | sed 's|/\*$||' | sort -u
}
old_dests "$FOREIGN_FILE" > "$WORK/ns5.pat"
NPAT=$(grep -c . "$WORK/ns5.pat" 2>/dev/null | tr -d ' ')
# The pattern set is itself asserted. contract/foreign carries FIFTEEN bond rows;
# the filter above keeps the thirteen `p3|`/`p4|` rows that sit under its five
# hard-coded path prefixes (foreign:98-110), and two of those thirteen are the
# `/*` globs of roots already listed, so eleven literals survive the dedupe.
# The two bond rows the filter DROPS are foreign:90 `p2|/root/bondctl` and
# foreign:122 `p3|/etc/rc.d/[SK][0-9][0-9]bond-*`; neither path is referenced
# anywhere under deploy/p5 (`grep -rE '/etc/rc\.d|/root/bondctl' deploy/p5
# --exclude-dir=portal` = 0 hits), so dropping them hides no shipped default --
# but note the limit: a NEW bond row under a sixth prefix would NOT widen this
# bar; the prefix list is hand-maintained and would have to be extended with it.
# Removing one of the thirteen from that file to make this bar green is the
# move ADR-005 SS2 refuses by name, and it reddens here first.
asrt "NS-5 the forbidden destination set is DERIVED from contract/foreign, not re-typed" "$NPAT" 11
ns5_bad() {   # ns5_bad DIR MINFILES -> "none" | the offending paths | a sentinel
    [ -d "$1" ] || { echo NODIR; return; }
    [ -s "$WORK/ns5.pat" ] || { echo NOPATTERNS; return; }
    # The two U133 files are exempted by their EXACT PATH, not by basename: a
    # future deploy/p5/<anything>/facts would inherit a waiver written for one
    # specific repo-only data file, which is how a named waiver quietly becomes
    # a glob. (portal/bond-accept keep the older spellings; they are U23/U56's.)
    find "$1" -type f ! -name '.gitkeep' ! -path '*/portal/*' ! -name 'bond-accept' \
        ! -path "$1/facts" ! -path "$1/test-facts.sh" \
        2>/dev/null | sort > "$WORK/ns5.list"
    # `while read < FILE`, not a pipe into the loop: a piped loop is a subshell in
    # every POSIX shell here and the counter would be discarded (SH-19's note).
    _n5_n=0; _n5_b=""
    while IFS= read -r _n5_f; do
        _n5_n=$((_n5_n+1))
        if grep -Fq -f "$WORK/ns5.pat" "$_n5_f" 2>/dev/null; then
            _n5_b="$_n5_b${_n5_b:+ }${_n5_f#"$1"/}"
        fi
    done < "$WORK/ns5.list"
    [ "$_n5_n" -ge "$2" ] || { echo "TOOFEW($_n5_n<$2)"; return; }
    echo "${_n5_b:-none}"
}
# The bar reports the OFFENDING PATHS, not a count: a failure has to say which
# file re-acquired a bond destination, or the next reader has to go find it.
asrt "NS-5 no shipped file under deploy/p5 names a contract/foreign destination" \
     "$(ns5_bad "$P5" 12)" none
# POSITIVE CONTROL: the exact assignment this unit rewrote, in its own directory
# with its own floor of 1. The lint must FIRE on it, or the assert above is a
# green square over an instrument that cannot see anything.
# printf builds the BODY of the shipped-file FIXTURE the lint then reads: ${BOND_DIR:-...}
# belongs to that generated file; expanded here it would write the fixture's own path.
# shellcheck disable=SC2016
asrt "NS-5 CONTROL: the lint FIRES on a restored /etc/bond default (the instrument is sensitive)" \
     "$( rm -rf "$WORK/ns5ctl"; mkdir -p "$WORK/ns5ctl"
        printf '%s\n' '#!/bin/sh' 'BOND_DIR="${BOND_DIR:-/etc/bond}"' \
            > "$WORK/ns5ctl/shipped-file"
        ns5_bad "$WORK/ns5ctl" 1 )" shipped-file
# NEGATIVE CONTROL, the other direction: the p5-* shape must NOT trip it, or the
# bar would be unsatisfiable and the only way green is to weaken it.
# printf builds the BODY of the shipped-file FIXTURE the lint then reads: the four
# ${VAR:-/etc/p5...} defaults belong to that generated file, not to this shell.
# shellcheck disable=SC2016
asrt "NS-5 CONTROL: the p5-* destinations do NOT trip the lint (the bar is satisfiable)" \
     "$( rm -rf "$WORK/ns5ctl"; mkdir -p "$WORK/ns5ctl"
        printf '%s\n' '#!/bin/sh' 'BOND_DIR="${BOND_DIR:-/etc/p5}"' \
            'RUN_DIR="${RUN_DIR:-/var/run/p5}"' 'DAG="${DAG:-/usr/lib/p5/dag}"' \
            'AGG_SVC="${AGG_SVC:-/etc/init.d/p5-datapath}"' > "$WORK/ns5ctl/shipped-file"
        ns5_bad "$WORK/ns5ctl" 1 )" none
# The floor is measured, not merely written: an empty tree must NOT read clean.
asrt "NS-5 CONTROL: an empty shipped tree refuses to answer (absent is not clean)" \
     "$( rm -rf "$WORK/ns5ctl"; mkdir -p "$WORK/ns5ctl"; ns5_bad "$WORK/ns5ctl" 12 )" \
     "TOOFEW(0<12)"
# The waived subtrees, counted out loud. Not an assertion -- they belong to other
# units -- but a waiver nobody can see is a waiver nobody will ever remove.
_ns5_w=0
find "$P5" -type f \( -path '*/portal/*' -o -name 'bond-accept' -o -path "$P5/facts" -o -path "$P5/test-facts.sh" \) 2>/dev/null > "$WORK/ns5.waived"
while IFS= read -r _n5_f; do
    _ns5_w=$(( _ns5_w + $(grep -Fc -f "$WORK/ns5.pat" "$_n5_f" 2>/dev/null | tr -d ' ') ))
done < "$WORK/ns5.waived"
echo "NOTE  NS-5 waived: $(grep -c . "$WORK/ns5.waived" | tr -d ' ') file(s) under deploy/p5 carry"
echo "NOTE  $_ns5_w remaining bond destination(s) -- the M9 portal (U23/U56/U120), bond-accept (U56)"
echo "NOTE  and the U133 fact ledger + its checker (repo-only; FD-11 asserts they never ship)."
echo "NOTE  They are OUT OF SCOPE for U51a, not clean. Deleting this waiver is those units' work."

# ===========================================================================
# XS-1 / XS-2 -- THE SPLIT ITSELF (U124). bond-xctl was one 1542-line file; it is
# now a bin plus five sourced libraries under deploy/p5/lib. Two failure modes
# that did not exist before the split, both silent without a bar:
#   XS-1 a lib is not on the box (partial scp, a missing paths row, an install
#        that placed four of five). Sourcing a file that is not there is a NO-OP
#        in POSIX sh followed by "not found" on the first call, i.e. a HALF
#        LOADED reconciler that walks an edge with some leaves missing. The bin
#        must refuse to start instead.
#   XS-2 a leaf named in bond.dag has no definition, or two. The dispatchers are
#        `case` statements: an unknown arm is caught, but a KNOWN arm calling a
#        function that no longer exists is not -- it is "command not found" at
#        the moment the edge runs.
setup
rm -rf "$WORK/xs1"; mkdir -p "$WORK/xs1"; cp "$P5"/lib/xctl-*.sh "$WORK/xs1/"
_XS1C=$(XCTL_LIB="$WORK/xs1" sh "$P5/bond-xctl" node 2>&1; echo "rc=$?")
asrt "XS-1 CONTROL: the bin runs against a complete lib set (the bar is satisfiable)" \
     "$(printf '%s\n' "$_XS1C" | tail -1)" "rc=0"
rm -f "$WORK/xs1/xctl-probe.sh"
_XS1=$(XCTL_LIB="$WORK/xs1" sh "$P5/bond-xctl" node 2>&1; echo "rc=$?")
asrt "XS-1 a missing lib FAILS LOUD (FATAL: missing)" \
     "$(printf '%s\n' "$_XS1" | grep -c 'FATAL: missing' | tr -d ' ')" 1
asrt "XS-1 ...and NAMES the file it could not read" \
     "$(printf '%s\n' "$_XS1" | grep -c 'xctl-probe.sh' | tr -d ' ')" 1
asrt "XS-1 ...and exits non-zero (never a half-loaded reconciler)" \
     "$(printf '%s\n' "$_XS1" | tail -1)" "rc=1"

# XS-2: every guard/action/verify leaf named in bond.dag resolves, through the
# run_guard/run_action/run_verify case arms, to EXACTLY ONE function definition
# across the bin and the five libs. Derived from the shipped table and the
# shipped dispatchers -- no hand-typed leaf list, so a new dag row is covered the
# moment it is added. The floor is part of the bar: a broken selector scores 0
# leaves and would otherwise read clean.
xs2_bad() {   # xs2_bad BIN LIBDIR MINLEAVES -> "none" | offending leaves | sentinel
    [ -f "$1" ] || { echo NOBIN; return; }
    cat "$1" "$2"/xctl-*.sh > "$WORK/xs2.all" 2>/dev/null || { echo NOLIBS; return; }
    # the three dispatchers only -- a `case` arm elsewhere in the tree must not be
    # mistaken for a leaf mapping
    awk '/^run_(guard|action|verify)\(\)/{inr=1} inr{print} /esac/{inr=0}' "$WORK/xs2.all" \
      | sed 's/#.*//' | tr ';' '\n' \
      | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_|]*\))[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$/\1 \2/p' \
      | awk '{n=split($1,a,"|"); for(i=1;i<=n;i++) print a[i], $2}' > "$WORK/xs2.map"
    grep -v '^[[:space:]]*#' "$P5/bond.dag" 2>/dev/null \
      | awk -F'|' 'NF==8 {print $4","$5","$6}' | tr ',' '\n' \
      | grep -Ev '^-$|^[[:space:]]*$' | sort -u > "$WORK/xs2.leaves"
    _x2n=$(grep -c . "$WORK/xs2.leaves" | tr -d ' ')
    [ "$_x2n" -ge "$3" ] || { echo "TOOFEW($_x2n<$3)"; return; }
    _x2b=""
    while IFS= read -r _x2l; do
        _x2f=$(awk -v l="$_x2l" '$1==l {print $2; exit}' "$WORK/xs2.map")
        if [ -z "$_x2f" ]; then
            _x2b="$_x2b${_x2b:+ }$_x2l(no-arm)"; continue
        fi
        _x2c=$(grep -cE "^$_x2f\(\)" "$WORK/xs2.all" | tr -d ' ')
        [ "$_x2c" = 1 ] || _x2b="$_x2b${_x2b:+ }$_x2l->$_x2f(x$_x2c)"
    done < "$WORK/xs2.leaves"
    echo "${_x2b:-none}"
}
# The FLOOR is the leaf count of the SHIPPED table, re-derived when the table
# changes -- it is a "the selector still sees something" tripwire, not a ratchet.
# U141 folded away the engarde leaves (genconf, eng_*, restore_feeder,
# aggdown_if_agg, ep_local, verify_local) and the separate aggregate row, taking
# the distinct-leaf count from 25 to 19, and U126 deleted the `agg_install` leaf
# from the `engage` row, taking it 19 -> 18: measured on the shipped table by the
# bar's own selector, never counted by eye
# (the count is the sorted-unique union of the guards, actions and verify
# fields of every 8-field row -- xs2_bad computes it, this line only records it).
asrt "XS-2 every bond.dag leaf resolves to exactly ONE definition across bin+libs" \
     "$(xs2_bad "$P5/bond-xctl" "$P5/lib" 18)" none
# POSITIVE CONTROL: delete the arity guard the `engage` row depends on. The bar must name
# the leaf that no longer resolves -- otherwise the assert above is a green
# square over an instrument that cannot see anything.
# The mutant tree lives OUTSIDE $WORK, as a SIBLING of it -- the same trick
# AGG-L12 uses for $MUTD (:989). It must: `setup` (:50) begins with
# `rm -rf "$WORK"`, so a mutant built under $WORK is DELETED before the
# behavioural half below can exec it, and `running p5-datapath` would then read
# 0 because no reconciler ran at all -- "nothing happened" wearing the costume
# of "the guard is missing". That is the defect this arrangement removes.
XS2MUT="$WORK.xs2mut"
rm -rf "$XS2MUT"; mkdir -p "$XS2MUT/lib"
cp "$P5/bond-xctl" "$XS2MUT/bond-xctl"; cp "$P5"/lib/xctl-*.sh "$XS2MUT/lib/"
sed -i '/^guard_sources_for_mode()/d' "$XS2MUT/lib/xctl-dag.sh"
asrt "XS-2 CONTROL: the check FIRES on a deleted leaf definition (the instrument is sensitive)" \
     "$(xs2_bad "$XS2MUT/bond-xctl" "$XS2MUT/lib" 18)" \
     "sources_for_mode->guard_sources_for_mode(x0)"
# ...and the same mutant REFUSES the aggregate edge rather than walking it with a
# leaf that is not there: the structural bar and the behaviour agree.
setup; bctl on
echo max > "$WORK/etc/p5/mode"
# PRESENCE, checked at exec time and asserted: without this the two bars below
# are satisfiable by an absent binary.
if [ -f "$XS2MUT/bond-xctl" ] && [ -f "$XS2MUT/lib/xctl-dag.sh" ]; then _XS2E=yes; else _XS2E=no; fi
XCTL_LIB="$XS2MUT/lib" sh "$XS2MUT/bond-xctl" reconcile >"$XS2MUT/out" 2>&1 || true
cat "$XS2MUT/out" >>"$WORK/ledger"
# READ THE EMITTED FACT, not "is the feeder running": since U141 `bctl on` above
# already started the ONE feeder, so a running feeder proves nothing about this
# edge. AGG_SCHED is what the refused edge would have rewritten.
_XS2MUTF=$(aggf AGG_SCHED)
# ...and it must have LOADED, not died. The feeder is also down when the mutant
# never got past its own sourcing block -- a lib missing from the copy, a syntax
# error, an unreadable file -- and the bar below would then read that corpse as
# "the guard refused the edge". The presence check above pins only two of the six
# files; this pins every other early death, by the reconciler's own loud failure
# word, on the mutant's OWN output rather than on the shared ledger.
_XS2FAT=$(grep -c 'FATAL' "$XS2MUT/out" 2>/dev/null | tr -d ' ')
# CONTROL for that half: the SHIPPED tree, same fresh world, same invocation
# form (not `hook`, so the only difference between the arms is the tree), DOES
# engage the feeder -- so "0" above is the missing guard and not the fixture.
setup; bctl on; echo max > "$WORK/etc/p5/mode"
XCTL_LIB="$P5/lib" sh "$P5/bond-xctl" reconcile >>"$WORK/ledger" 2>&1 || true
_XS2SHIPF=$(aggf AGG_SCHED)
asrt "XS-2 the mutant bin EXISTS when the edge is walked (setup did not delete it)" \
     "$_XS2E" yes
asrt "XS-2 the mutant RAN (no FATAL: it refused the edge, it did not die loading)" \
     "$_XS2FAT" 0
asrt "XS-2 the mutant REFUSES the aggregate edge (AGG_SCHED never became max)" \
     "$_XS2MUTF" lightning
asrt "XS-2 CONTROL: the shipped tree engages the same edge (the world is not the reason)" \
     "$_XS2SHIPF" max
rm -rf "$XS2MUT"
setup

# ===========================================================================
# EP — converged(off) ON A DDNS BOX (U216). F12/KK8.
#
# WHY THIS WORLD DID NOT EXIST BEFORE. Every scenario above seeds `direct` and
# `ep` to THE SAME STRING (setup: both "203.0.113.9:51820"), so the pre-U216
# converged(off) term `[ "$(ep_now)" = "$(live_direct)" ]` was true here and the
# 570 bars above could not see the defect. THE CLIENT IS NOT THAT BOX: its uci
# `end_point` is a DDNS HOSTNAME (inventory :198) and `wg show endpoints` prints
# what the kernel RESOLVED it to, an IP (:192 form). Two different strings for
# one endpoint -> converged(off) false forever -> every reconcile at S2 walks
# disengage (agg_stop, agg_disable, mtu_1420, ep_direct, clear_susp, shape_apply)
# and the box never rests. The walk SUCCEEDS each time, so nothing goes red and
# nothing is logged: the only symptom is that the box never stops working.
#
# setup_ddns() IS THE FIXTURE, and its whole content is that the two strings
# DIFFER. They are printed by the first bar so a reader can see the split rather
# than trust this comment.
#
# HOW THE RE-WALK IS OBSERVED, stated because the obvious reading is wrong here.
# On an already-off box NONE of disengage's leaves writes a ledger line: svc-agg
# `stop`/`disable` are silent, the `ip`/`wg` shims do not log, and act_shape_apply
# is idempotent so it emits no TC/SVC line. The action whose EFFECT differs
# between "already there" and "re-walked" is `ep_direct` -- it re-points the
# endpoint at live_direct, i.e. back at the HOSTNAME, clobbering the resolved IP.
# So the endpoint itself is the witness, and `mtu_1420` is a second, independent
# one: the fixture drifts the device MTU to 1408 before the second reconcile, and
# only a walked edge puts it back to 1420 (converged(off) has no MTU term, so the
# drift cannot be what makes the arms differ). The ledger count is asserted too,
# as the brief asks -- it is the weak witness here, and saying so is the point.
#
# THE NAME IS NEUTRAL ON PURPOSE. The brief spelled this fixture with the client's
# real DDNS label. That label is the leading component of DDNS_HOST in
# .local/secrets.env, this file is pushed to a PUBLIC CI mirror, and the fixture
# needs exactly one property of the string: that it is a NAME and not an address.
# Spelling the box's own identifier buys nothing and is the U170/U25a class.
setup_ddns() {
    setup
    echo "client.ddns.example:51820" > "$WORK/direct"  # uci end_point: a DDNS NAME
    echo "203.0.113.9:51820"         > "$WORK/ep"      # wg show endpoints: the IP
}

# EP-1 — a DDNS box RESTS. `bctl off` twice: the second reconcile is a no-op.
setup_ddns
asrt "EP-1 the fixture really splits the two strings (uci name vs wg IP)" \
     "$(cat "$WORK/direct")|$(cat "$WORK/ep")" "client.ddns.example:51820|203.0.113.9:51820"
bctl on
bctl off
# The first disengage ran act_ep_direct, so wg was handed the NAME; the kernel
# resolves it and reports the address back. That resolution is the co-writer
# idiom already used at F10/F11/F14 above -- the harness never resolves anything.
fact ep "203.0.113.9:51820"
fact mtu.wgclient1 1408                 # drift, so a walked mtu_1420 is visible
: > "$WORK/ledger"                      # zero it: only the SECOND reconcile counts
bctl off
_EP1LED=$(grep -cE '^(SVC|TC) ' "$WORK/ledger" 2>/dev/null | tr -d ' ')
asrt "EP-1 second reconcile is a NO-OP: the endpoint is NOT re-pointed at the name" \
     "$(epv)" "203.0.113.9:51820"
asrt "EP-1 second reconcile is a NO-OP: mtu_1420 did not run (the drift survives)" \
     "$(cat "$WORK/mtu.wgclient1" 2>/dev/null)" 1408
asrt "EP-1 second reconcile is a NO-OP: zero SVC/TC ledger lines" "$_EP1LED" 0
asrt "EP-1 and the box is still off, unsuspended"  "$(node)|$(rcf)" "off|0"

# EP-1 CONTROL — the same fixture, the same two commands, with the endpoint the
# box would have if it were NOT direct. Without this, EP-1 is satisfiable by a
# predicate that answers TRUE for everything.
setup_ddns; bctl on; bctl off; fact ep "203.0.113.9:51820"
fact mtu.wgclient1 1408
fact ep "198.51.100.7:51820"            # a DIFFERENT public host, same port
bctl off
asrt "EP-1 CONTROL a foreign host on the configured port is still 'direct' (no name lookup ever runs)" \
     "$(epv)" "198.51.100.7:51820"

# EP-2 — the predicate is NOT a blanket accept. A LOCAL feeder socket is never
# direct, whichever feeder it belongs to: :59401 is P2 engarde's (the socket the
# quiescence gate names) and :59402 is P5's own (bond-xctl LOCAL_AGG). In both
# cases converged(off) must be FALSE, so the reconcile WALKS disengage and
# ep_direct re-points the endpoint at live_direct -- the hostname. That rewrite
# is the proof the guard refused to call the socket direct.
setup_ddns; bctl on; bctl off; fact ep "203.0.113.9:51820"
fact ep "127.0.0.1:59401"
bctl off
asrt "EP-2 engarde's local socket is NOT converged(off): the edge IS walked" \
     "$(epv)" "client.ddns.example:51820"
setup_ddns; bctl on; bctl off; fact ep "203.0.113.9:51820"
fact ep "127.0.0.1:59402"
bctl off
asrt "EP-2 P5's OWN feeder socket is NOT converged(off) either" \
     "$(epv)" "client.ddns.example:51820"
setup_ddns; bctl on; bctl off; fact ep "203.0.113.9:51820"
fact ep "203.0.113.9:59402"             # public host, WRONG port
bctl off
asrt "EP-2 a public host on the wrong port is NOT direct (the port term is load-bearing)" \
     "$(epv)" "client.ddns.example:51820"
setup_ddns; bctl on; bctl off
fact ep ""                              # no handshake yet: wg prints nothing
bctl off
asrt "EP-2 an EMPTY endpoint is not direct -- the box re-walks exactly as today" \
     "$(epv)" "client.ddns.example:51820"

# EP-2 SCOPE — the fix must not weaken ENGAGED detection. The engaged arm and the
# verify path compare against LOCAL_AGG, an exact local literal, and ep_is_direct
# is CALLED from converged(off) only. Grepped from the shipped source so a later
# edit that widens the engaged compare reddens this. The pattern anchors on the
# CALL (leading whitespace, then the name, then `||`) so the prose that names the
# function in the comments beside it cannot satisfy the count.
asrt "EP-2 SCOPE ep_is_direct is CALLED exactly once, in converged(off)" \
     "$(grep -cE '^[[:space:]]*ep_is_direct[[:space:]]+\|\|' "$P5/lib/xctl-dag.sh")" 1
asrt "EP-2 SCOPE and nothing outside the reconciler's converged() calls it" \
     "$(grep -lE '^[[:space:]]*ep_is_direct[[:space:]]+\|\|' "$P5"/lib/*.sh | wc -l | tr -d ' ')" 1
# literal shipped source: the pattern IS xctl-dag.sh's own `[ "$(ep_now)" = "$LOCAL_AGG" ]`
# text. Expanding it here would run ep_now in THIS shell and substitute the harness's
# LOCAL_AGG, so the grep would search for a resolved address, match nothing, read 0 --
# and this bar exists precisely to red when that count falls from 2.
# shellcheck disable=SC2016
asrt "EP-2 SCOPE the engaged/verify arms still compare against LOCAL_AGG literally" \
     "$(grep -c '"\$(ep_now)" = "\$LOCAL_AGG"' "$P5/lib/xctl-dag.sh")" 2

# QG — U208 / G5: THE PRE-SWITCH QUIESCENCE GATE, LAYER 2 (THE WIRING)
# ===========================================================================
# What this block proves is that the guard is CONNECTED, end to end, through
# the real shipped artifacts: bond.dag names `old_quiescent` on its engage row,
# xctl-dag.sh `run_guard` resolves the token, xctl-dag.sh `guard_old_quiescent`
# actually EXECUTES $QUIESCE_CHECK,
# a non-zero from that program refuses the edge BEFORE any action runs, the
# refusal is logged by name, and bondctl's own exit status follows it out.
#
# It deliberately does NOT re-measure the predicate. WHAT makes a box
# non-quiescent -- an rc.d flag with a single-digit priority, a worker still up
# under a supervisor procd never heard of, the WireGuard peer still on the old
# local socket -- is measured in E0 (QG-E1..E7, QS-LIT) against a real $P5_ROOT
# tree with injected wg/ubus/pgrep. Splitting it that way is the point: this
# layer can fail because the wiring broke, and E0 can fail because the question
# changed, and neither failure can hide inside the other.
setup
fact old_quiescent 0
QG1RC=0; bctl on || QG1RC=$?
asrt "QG-1 a NON-QUIESCENT old stack refuses \`p5 on\`: bondctl exits non-zero" \
     "$(if [ "$QG1RC" = 0 ]; then echo zero; else echo nonzero; fi)" nonzero
asrt "QG-1 ...and the node did NOT move: the box is still off" "$(node)" off
asrt "QG-1 ...and the endpoint was never re-pointed (still the direct peer, never the feeder's socket)" "$(epv)" 203.0.113.9:51820
QG1G=$(grep -c "guard 'old_quiescent' refused" "$WORK/ledger" 2>/dev/null | tr -d ' ')
asrt "QG-1 ...and the refusal NAMES the guard in the log (not a silent no-op)" \
     "$(if [ "$QG1G" -ge 1 ]; then echo named; else echo silent; fi)" named
QG1S=$(grep -c "SVC p5-datapath start" "$WORK/ledger" 2>/dev/null | tr -d ' ')
asrt "QG-1 ...and ZERO feeder starts: the guard ran BEFORE the actions, not after" \
     "$QG1S" 0
asrt "QG-1 ...and the feeder rc.d flag was not even set" "$(enabledf p5-datapath)" 0

# QG-2 CONTROL: the SAME command in the SAME world with the fact flipped. Without
# this, QG-1 is indistinguishable from a fixture that cannot engage at all.
setup
fact old_quiescent 1
QG2RC=0; bctl on || QG2RC=$?
asrt "QG-2 CONTROL: with the old stack QUIESCENT the same \`p5 on\` succeeds (rc)" "$QG2RC" 0
asrt "QG-2 CONTROL: ...the node is engaged" "$(node)" engaged
asrt "QG-2 CONTROL: ...and the endpoint is P5's own aggregate socket" "$(epv)" 127.0.0.1:59402

# QG-3 FAIL CLOSED. The obvious shape for this guard is
# `command -v "$QUIESCE_CHECK" || return 0` -- pass when you cannot check -- and
# that is the defect, not the fallback: a box missing its uninstaller would
# engage over a live old stack with nothing in the log. Point it at a path that
# does not exist and require a REFUSAL that NAMES the path.
setup
fact old_quiescent 1
QG3RC=0; QUIESCE_CHECK=/nonexistent bctl on || QG3RC=$?
asrt "QG-3 an ABSENT checker refuses the edge (fail closed, not fail open)" \
     "$(if [ "$QG3RC" = 0 ]; then echo engaged; else echo refused; fi)" refused
asrt "QG-3 ...and the node did not move" "$(node)" off
if grep -q '/nonexistent' "$WORK/ledger" 2>/dev/null; then
  ok "QG-3 ...and the log NAMES the checker path it could not run"
else
  no "QG-3 ...and the log NAMES the checker path it could not run"
fi

# MU-QG — THE SEED. A guard nobody has watched go missing is not a guard: with
# the token deleted from a COPY of bond.dag, QG-1's own predicate must go FALSE
# (the box engages over a live old stack). The mutant tree lives OUTSIDE $WORK,
# as a sibling, for the reason XS-2 records: `setup` begins `rm -rf "$WORK"`.
QGMUT="$WORK.qgmut"
rm -rf "$QGMUT"; mkdir -p "$QGMUT"; cp -R "$P5/." "$QGMUT/"
# Strip the token by FIELD, so the mutation does not depend on the guard list's
# current spelling or order.
awk -F'|' 'BEGIN{OFS="|"} !/^#/ && NF>=8 {
             n=split($4,g,","); out=""
             for (i=1;i<=n;i++) if (g[i]!="old_quiescent") out=(out==""?g[i]:out","g[i])
             if (out=="") out="-"
             $4=out }
           {print}' "$P5/bond.dag" > "$QGMUT/bond.dag"
# Counted in the GUARD FIELDS of the intent rows, never over the whole file:
# the table's header explains this guard in prose, so a whole-file grep counts
# comments and reports the mutation unapplied when it applied perfectly.
QGMUTAPPLIED=$(awk -F'|' '!/^#/ && NF>=8 {print $4}' "$QGMUT/bond.dag" | grep -c 'old_quiescent')
asrt "MU-QG the mutation APPLIED: no old_quiescent token survives in the mutant table" \
     "$QGMUTAPPLIED" 0
setup
fact old_quiescent 0
QGMRC=0
XCTL_LIB="$QGMUT/lib" DAG="$QGMUT/bond.dag" sh "$QGMUT/bondctl" on >>"$WORK/ledger" 2>&1 || QGMRC=$?
QGMNODE=$(XCTL_LIB="$QGMUT/lib" DAG="$QGMUT/bond.dag" sh "$QGMUT/bond-xctl" node 2>/dev/null)
asrt "MU-QG MUTATION: with the token removed from the table the SAME non-quiescent world ENGAGES -- QG-1 is a bar that can fail" \
     "$QGMNODE|$QGMRC" "engaged|0"
rm -rf "$QGMUT"
setup

# ===========================================================================
# FD — THE FACT LEDGER (U133). deploy/p5/facts gives every file under $BOND_DIR
# a writer, a reader and a stated DEFAULT; deploy/p5/test-facts.sh is the
# MECHANICAL bar over it: it sweeps BOTH the $BOND_DIR spelling and the literal
# one (agg_env is only ever spelled the second way) and refuses a fact
# read with no ledger row, a row nobody reads, and a cite that no longer
# resolves. It is run FROM HERE so it rides the emulator gate rather than
# depending on a human remembering it. A hand-written list is exactly what U124
# invalidated when it split bond-xctl and every bond-xctl:NNN cite died silently.
setup
_FDOUT=$(sh "$REPO/deploy/p5/test-facts.sh" "$REPO" 2>&1); _FDRC=$?
asrt "FD-L2 the fact-ledger checker exits 0" "$_FDRC" 0
_FDFAIL=$(printf "%s" "$_FDOUT" | grep -c "^FAIL ")
asrt "FD-L2 the fact-ledger checker reports zero FAIL lines" "$_FDFAIL" 0
# The checker going green is not enough: a checker whose selector broke also
# goes green. Pin that the COMPLETENESS bar itself ran.
case "$_FDOUT" in
    *"FD-3 every swept fact name has a ledger row"*)
        ok "FD-L2 the UNDECLARED bar RAN (a fact read with no ledger row is refused)" ;;
    *)  no "FD-L2 the UNDECLARED bar did not run -- checker output: $_FDOUT" ;;
esac

# ===========================================================================
# LG -- U221: THE WALKED EDGE IS LOGGED, AND THE CONVERGED NO-OP STAYS SILENT
# ===========================================================================
# R1 section 3b claimed the reconciler "logs the edge it walked and why a guard
# refused". Only the second half was true. converge() (xctl-dag.sh) logged
# does-not-apply, guard refused, action FAILED, no-onfail and best-effort rc, and
# said NOTHING on the success path -- so `logread | grep bond-xctl:` on a box that
# had just re-established the tunnel showed an empty ring, and the operator could
# not tell "nothing happened" from "everything happened, twice".
#
# EVERY BAR BELOW READS THE LEDGER THROUGH THE `logger` SHIM (bin/logger:4 writes
# `LOG <msg>`), never off stdout: bctl() folds bond-xctl's stdout into the SAME
# file, and log() both echoes and calls logger, so an unanchored grep would match
# the echo and stay green with the syslog half of log() deleted. Hence `^LOG `.
setup
: > "$WORK/ledger"
bctl on
asrt "LG-1 the walked edge is logged: intent, and the node pair it moved between" \
     "$(grep -c '^LOG engage: walked off -> engaged$' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 1
asrt "LG-1 ...and the box really did walk it (the line is a fact, not a hope)" "$(node)" engaged

# LG-2 THE SILENCE, which is half the deliverable. The watchdog reconciles every
# ~10 s and the syslog ring is 16 KiB: one line per tick would evict the refusals
# this unit exists to preserve, so the converged no-op path must log NOTHING.
# reconcile() returns on `converged "$d"` BEFORE converge is entered, so the
# property is structural -- these bars pin it against a later edit that moves the
# short-circuit or the log line.
setup; bctl on
: > "$WORK/ledger"
_lgi=0
while [ "$_lgi" -lt 10 ]; do hook; _lgi=$((_lgi+1)); done
asrt "LG-2 ten idle reconciles on a converged box append ZERO LOG lines" \
     "$(grep -c '^LOG ' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 0
asrt "LG-2 ...and the box is still engaged (the silence is convergence, not a dead fixture)" \
     "$(node)" engaged
# CONTROL: the same world, one REAL delta. Without this the bar above is satisfied
# by a harness whose logger shim stopped writing.
fact ep "203.0.113.9:51820"
hook
asrt "LG-2 CONTROL a real delta in that same world DOES log a walk" \
     "$(grep -c '^LOG engage: walked ' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 1

# LG-2 (refusal arm): a guard that refuses changes nothing, so it must not claim a
# walk. This is what pins the line BELOW the guard loop rather than at the top of
# converge() -- LG-3 MUT-B is the seed that proves this arm can fail.
setup
fact old_quiescent 0
: > "$WORK/ledger"
LG2RC=0; bctl on || LG2RC=$?
asrt "LG-2 a REFUSED edge never claims a walk" \
     "$(grep -c '^LOG .*: walked ' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 0
asrt "LG-2 CONTROL ...and that refusal WAS logged, so the zero above is silence about the walk, not an empty ledger" \
     "$(if [ "$(grep -c "^LOG engage: guard 'old_quiescent' refused" "$WORK/ledger" 2>/dev/null | tr -d ' ')" -ge 1 ]; then echo logged; else echo empty; fi)" logged
asrt "LG-2 ...and the edge really was refused" \
     "$(if [ "$LG2RC" = 0 ]; then echo walked; else echo refused; fi)|$(node)" "refused|off"

# LG-3 THE SEEDS. Two mutant trees, each OUTSIDE $WORK (setup begins `rm -rf
# "$WORK"` -- the reason XS-2/MU-QG record), each proving one bar above can fail.
LGMUT="$WORK.lgmut"
rm -rf "$LGMUT"; mkdir -p "$LGMUT"; cp -R "$P5/." "$LGMUT/"
# The statement is matched by SHAPE (indent + `log "` + the literal text), so the
# count is of the CODE line and never of the comments beside it that quote it.
asrt "LG-3 the shipped lib carries exactly ONE walked-edge log statement" \
     "$(grep -c "^[[:space:]]*log \"\$intent: walked" "$P5/lib/xctl-dag.sh" | tr -d ' ')" 1
# MUT-A: delete it. LG-1's predicate must go FALSE while the edge still walks.
sed "/^[[:space:]]*log \"\$intent: walked/d" "$P5/lib/xctl-dag.sh" > "$LGMUT/lib/xctl-dag.sh"
asrt "LG-3 MUT-A applied: no walked-edge log statement survives in the mutant lib" \
     "$(grep -c "^[[:space:]]*log \"\$intent: walked" "$LGMUT/lib/xctl-dag.sh" | tr -d ' ')" 0
setup
: > "$WORK/ledger"
LGARC=0
XCTL_LIB="$LGMUT/lib" DAG="$LGMUT/bond.dag" sh "$LGMUT/bondctl" on >>"$WORK/ledger" 2>&1 || LGARC=$?
LGANODE=$(XCTL_LIB="$LGMUT/lib" DAG="$LGMUT/bond.dag" sh "$LGMUT/bond-xctl" node 2>/dev/null)
asrt "LG-3 MUT-A: the mutant still ENGAGES (the mutation removed the LOG, not the edge)" \
     "$LGANODE|$LGARC" "engaged|0"
asrt "LG-3 MUT-A: ...and LG-1's predicate is FALSE -- LG-1 is a bar that can fail" \
     "$(grep -c '^LOG engage: walked ' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 0
# MUT-B: HOIST the same statement above the guard loop -- the plausible wrong
# placement, and the one a reviewer would not notice, because every bar that only
# looks at a SUCCESSFUL edge stays green under it. Written as an awk PROGRAM FILE
# so the shipped text (`$intent`, `$cur`, `$e_to`) needs no shell quoting at all.
cat > "$LGMUT/lg-hoist.awk" <<'LGAWK'
/^[[:space:]]*log "\$intent: walked/                 { next }
/^[[:space:]]*if \[ "\$e_guards" != "-" \]; then/    { print "    log \"$intent: walked $cur -> $e_to\"" }
                                                     { print }
LGAWK
awk -f "$LGMUT/lg-hoist.awk" "$P5/lib/xctl-dag.sh" > "$LGMUT/lib/xctl-dag.sh"
lgpos() {   # "above" | "below" -- where the log statement sits relative to the guard loop
    _w=$(grep -n "^[[:space:]]*log \"\$intent: walked" "$1" | head -1 | cut -d: -f1)
    _g=$(grep -n "^[[:space:]]*if \[ \"\$e_guards\" != \"-\" \]; then" "$1" | head -1 | cut -d: -f1)
    if [ -z "$_w" ] || [ -z "$_g" ]; then echo absent
    elif [ "$_w" -lt "$_g" ]; then echo above
    else echo below; fi
}
asrt "LG-3 the SHIPPED statement sits BELOW the guard loop (structural, not incidental)" \
     "$(lgpos "$P5/lib/xctl-dag.sh")" below
asrt "LG-3 MUT-B applied: the mutant's statement sits ABOVE it" \
     "$(lgpos "$LGMUT/lib/xctl-dag.sh")" above
setup
fact old_quiescent 0
: > "$WORK/ledger"
LGBRC=0
XCTL_LIB="$LGMUT/lib" DAG="$LGMUT/bond.dag" sh "$LGMUT/bondctl" on >>"$WORK/ledger" 2>&1 || LGBRC=$?
asrt "LG-3 MUT-B: hoisted, a REFUSED edge claims a walk -- LG-2's refusal arm is a bar that can fail" \
     "$(grep -c '^LOG engage: walked ' "$WORK/ledger" 2>/dev/null | tr -d ' ')" 1
asrt "LG-3 MUT-B: ...and the edge was still refused (the mutation moved the LOG, not the guard)" \
     "$(if [ "$LGBRC" = 0 ]; then echo walked; else echo refused; fi)|$(node)" "refused|off"
rm -rf "$LGMUT"

# EFP — THE ESCALATION PROFILE FACT, $BOND_DIR/profile (U227).
#
# The portal writes a NAME (a risk appetite, never a millisecond); bond-ecod's
# `apply_profile` owns the mapping to constants and re-reads the fact at the top
# of EVERY cycle, so a portal write lands without restarting the daemon. Three
# claims: EFP-1 `balanced` IS the set this daemon resolved; EFP-2 a value with no
# derivation on record runs balanced and says so ONCE PER CHANGE; EFP-3 with no
# fact at all nothing is printed.
#
# EFP-1's CONTROL IS A DAEMON WITH THE apply_profile CALL REMOVED -- NOT the same
# daemon with the fact absent, which is what the first build of this unit
# compared and why that bar could not fail. Both of those arms run the identical
# apply_profile body (its `case` decides only whether a LINE IS LOGGED; the five
# assignments under it are unconditional), so no mapping error can ever separate
# them: an adversarial seed giving all five constants a literal 1 left the bar
# GREEN. The fixture was blind for a second, independent reason -- it escalated
# on `tput degraded`, an arm that `continue`s (84ca901:bond-ecod:246-249) before
# BLOAT_DELTA / BLOAT_N / NEED_CLEAN / PROBATION / NEED_MAX_MULT are read at all.
# Both are fixed here:
#
#   * THE CONTROL (`$WORK/ecod-noprofile`) is the pre-change daemon in the one
#     respect that matters, built by deleting the call rather than by reaching
#     into git history, which would rot. `balanced` means "what this daemon
#     RESOLVED", so removing the call must change NOTHING; a mapping that assigns
#     anything else -- a retyped 100/3/24/600/8 included -- diverges. EFP-1b
#     keeps that control honest: a `sed` that silently matched nothing would make
#     EFP-1 compare a run with itself.
#   * THE FIXTURE DRIVES RTT. The five knobs are EXPORTED to values that are NOT
#     the shipped defaults (137/2/5/0/3), because the property under test is
#     "balanced restores what was resolved" -- a mapping hard-coding the defaults
#     must be a different run, and the harness/bond-accept sandbox depends on the
#     same env-override property. The scheduled ping shim then walks the daemon
#     through every one of them: learn -> eco return (NEED_CLEAN) -> raw bloat
#     (BLOAT_DELTA, BLOAT_N; the 84ca901:bond-ecod:277 line) -> the bounded-counter
#     plateau accept (NEED_MAX = NEED_CLEAN * NEED_MAX_MULT) -> a second eco
#     return -> tunnel bloat under the probation test (PROBATION; the
#     84ca901:bond-ecod:306 line). EFP-1c pins the CYCLE of each escalation (where
#     BLOAT_N and NEED_MAX_MULT are visible) and EFP-1d/1e the two log lines
#     (where BLOAT_DELTA and PROBATION are).
#
# The knobs are named ONCE, here, so a bar and the world it measures cannot drift.
EFP_DELTA=137; EFP_N=2; EFP_CLEAN=5; EFP_PROB=0; EFP_MULT=3

efpbloat() {   # a world whose ONLY escalations come from RTT, on a scheduled ping
    setup; bctl on; touch "$WORK/etc/p5/auto"; fact enabled.p5-ecod 1
    bctl mode lightning
    touch "$WORK/etc/p5/auto"          # bctl mode cleared it; re-arm for ecod
    # ASKED, not assumed: a hard-coded interface here would silently put ecod on
    # the "primary now X (applied: Y) -> re-deriving eco" path and the fixture
    # would measure that instead of the escalation ladder (EFP-1f refuses it).
    fact "etc/p5/applied_wans" "$(sh "$P5/bondctl" _primary 2>/dev/null | head -1)"
    echo 0 > "$WORK/efpn"
    # THE SCHEDULE IS KEYED TO THE ECOD CYCLE, not to the ping CALL: the raw probe
    # (-I) is issued exactly once per cycle, so incrementing there and only READING
    # it in the tunnel arm makes $_n the cycle number. It stamps the ledger too,
    # which is what lets EFP-1c assert WHICH cycle each escalation happened on --
    # the only place BLOAT_N and NEED_MAX_MULT are observable at all.
    #   cycles 1-5    raw 20 / tunnel 30   learn, then the NEED_CLEAN eco return
    #   cycles 6+     raw 900              raw bloat at BLOAT_N, then a sustained
    #                                      plateau accepted at NEED_MAX
    #   cycles 25-26  tunnel 800           tunnel bloat while in eco (probation)
    cat > "$WORK/fakebin/ping-sched" <<EOF
#!/bin/sh
_raw=0
for a in "\$@"; do case "\$a" in -I) _raw=1 ;; esac; done
_n=\$(cat "$WORK/efpn" 2>/dev/null || echo 0)
if [ "\$_raw" = 1 ]; then
    _n=\$((_n + 1)); echo "\$_n" > "$WORK/efpn"
    echo "CYC \$_n" >> "$WORK/ledger"
    if [ "\$_n" -ge 6 ]; then _t=900; else _t=20; fi
else
    if [ "\$_n" -ge 25 ] && [ "\$_n" -le 26 ]; then _t=800; else _t=30; fi
fi
echo "64 bytes from x: seq=0 ttl=54 time=\${_t}.0 ms"
exit 0
EOF
    chmod +x "$WORK/fakebin/ping-sched"
    : > "$WORK/ledger"                 # from here the ledger is ecod's own
}
efpbrun() {    # efpbrun <daemon> -- 28 cycles under the EXPORTED knobs
    MAXCYCLES=28 CYCLE=0 BONDCTL="$P5/bondctl" SYS_NET="$WORK/sys" \
        PING="$WORK/fakebin/ping-sched" \
        BLOAT_DELTA="$EFP_DELTA" BLOAT_N="$EFP_N" NEED_CLEAN="$EFP_CLEAN" \
        PROBATION="$EFP_PROB" NEED_MAX_MULT="$EFP_MULT" \
        sh "$1" >>"$WORK/ledger" 2>&1
}
# THE ESCALATION TRACE: one "<cycle>:<what>" per ecod escalation, in order.
efptrace() {
    awk '/^CYC /{c=$2; next}
         /healthy .* cycles -> mode eco/  {printf "%s:eco ", c; next}
         /primary .* bloated .* -> mode/  {printf "%s:raw ", c; next}
         /tunnel path bloated .* -> mode/ {printf "%s:tun ", c; next}' "$WORK/ledger"
}

efpbloat; printf 'balanced\n' > "$WORK/etc/p5/profile"; efpbrun "$P5/bond-ecod"
EFP_B=$(cat "$WORK/ledger"); EFP_BT=$(efptrace)
# The control is built AFTER the fixture ran: setup() wipes $WORK.
sed 's/^    apply_profile$/    : # CONTROL MUTANT: apply_profile not called/' \
    "$P5/bond-ecod" > "$WORK/ecod-noprofile"
EFP_SHIP=$(grep -c '^    apply_profile$' "$P5/bond-ecod" | tr -d ' ')
EFP_MUT=$(grep -c '^    apply_profile$' "$WORK/ecod-noprofile" | tr -d ' ')
printf 'balanced\n' > "$WORK/etc/p5/profile"
echo 0 > "$WORK/efpn"; : > "$WORK/ledger"
efpbrun "$WORK/ecod-noprofile"
EFP_C=$(cat "$WORK/ledger"); EFP_CT=$(efptrace)

asrt "EFP-1b the control is REAL: the shipped daemon calls apply_profile in the loop and the control mutant does not (shipped/mutant call sites)" \
     "$EFP_SHIP/$EFP_MUT" "1/0"
if [ "$EFP_B" = "$EFP_C" ]; then
  ok "EFP-1 profile=balanced restores exactly what the daemon RESOLVED: removing the apply_profile call changes not one byte of the ledger"
else
  no "EFP-1 balanced is NOT the resolved set -- apply_profile moved a constant. with:[$EFP_BT] without:[$EFP_CT]"
fi
asrt "EFP-1c ... on a fixture that walks all five constants: NEED_CLEAN eco return, BLOAT_N raw bloat, NEED_MAX plateau accept + second eco return, tunnel bloat" \
     "$EFP_BT" "5:eco 7:raw 24:eco 26:tun "
EFP_RAWL=$(printf '%s\n' "$EFP_B" | grep 'primary .* bloated' | head -1)
case "$EFP_RAWL" in
  *"+$EFP_DELTA)"*)
     ok "EFP-1d the raw-bloat line (84ca901:bond-ecod:277) carries the EXPORTED BLOAT_DELTA, so a mapped-in delta would show: $EFP_RAWL" ;;
  *) no "EFP-1d the raw-bloat line does not carry base+$EFP_DELTA: [$EFP_RAWL]" ;;
esac
EFP_TUNL=$(printf '%s\n' "$EFP_B" | grep 'tunnel path bloated' | head -1)
case "$EFP_TUNL" in
  *"next eco needs $EFP_CLEAN clean"*)
     ok "EFP-1e the tunnel-bloat line (84ca901:bond-ecod:306) carries the EXPORTED NEED_CLEAN with NO probation doubling (PROBATION=$EFP_PROB), so a mapped-in NEED_CLEAN or PROBATION would show: $EFP_TUNL" ;;
  *) no "EFP-1e the tunnel line does not say 'next eco needs $EFP_CLEAN clean': [$EFP_TUNL]" ;;
esac
asrt "EFP-1f ... and no cycle re-derived eco, so the trace above is the WHOLE escalation story" \
     "$(printf '%s\n' "$EFP_B" | grep -c 're-deriving eco')" 0

# The fact's stated DEFAULT (deploy/p5/facts: absent = balanced) as its own bar.
efpbloat; efpbrun "$P5/bond-ecod"
EFP_A=$(cat "$WORK/ledger")
if [ "$EFP_B" = "$EFP_A" ]; then
  ok "EFP-1g absent == balanced: the fact's stated default costs nothing"
else
  no "EFP-1g the absent fact is not the balanced run -- balanced:[$EFP_BT] absent:[$(efptrace)]"
fi

efpquiet() {   # a world that ESCALATES NOTHING (so a profile line is unmistakable)
    setup; bctl on; touch "$WORK/etc/p5/auto"; bctl mode lightning
    touch "$WORK/etc/p5/auto"          # bctl mode cleared it; re-arm for ecod
    # ... but is NOT silent: the tunnel reflector is unreachable, which makes ecod
    # log its once-per-outage "tunnel sensor lost" line. Without that, EFP-2c
    # ("behaviour unchanged") would be comparing two EMPTY ledgers and asserting
    # nothing at all -- the failure mode this file's floors exist to refuse.
    echo 0 > "$WORK/capable"
    : > "$WORK/ledger"
}
efprun() {     # efprun <maxcycles> [ping shim]
    MAXCYCLES="$1" CYCLE=0 BONDCTL="$P5/bondctl" SYS_NET="$WORK/sys" \
        PING="${2:-$BIN/ping}" sh "$P5/bond-ecod" >>"$WORK/ledger" 2>&1
}
efpsaid() { grep -c 'no derivation on record' "$WORK/ledger" | tr -d ' '; }

# EFP-3 first: the CONTROL run, whose ledger EFP-2 is measured against.
efpquiet; efprun 12
EFP_Q=$(grep -v 'no derivation on record' "$WORK/ledger")
asrt "EFP-3 no profile fact: ecod says nothing about a profile in 12 cycles" "$(efpsaid)" 0
if [ -n "$EFP_Q" ]; then
  ok "EFP-3b ... and the control run is NOT silent ($(printf '%s\n' "$EFP_Q" | grep -c .) line(s)), so EFP-2c below compares something"
else
  no "EFP-3b the control ledger is empty: EFP-2c would compare two empty strings"
fi

# EFP-2. The wrapper writes the fact DURING the run (second ping = cycle 2), and
# DELEGATES to the shared shim rather than replacing it: it changes when the fact
# appears, never what a ping answers.
efpquiet
cat > "$WORK/fakebin/ping-mid" <<EOF
#!/bin/sh
_n=0
[ -f "$WORK/pingn" ] && _n=\$(cat "$WORK/pingn")
_n=\$((_n + 1)); echo "\$_n" > "$WORK/pingn"
[ "\$_n" -ge 2 ] && echo aggressive > "$WORK/etc/p5/profile"
"$BIN/ping" "\$@"
exit \$?
EOF
chmod +x "$WORK/fakebin/ping-mid"
efprun 12 "$WORK/fakebin/ping-mid"
asrt "EFP-2 profile written MID-RUN: the daemon re-read it and said so exactly once in the ten cycles after" \
     "$(efpsaid)" 1
EFP_LINE=$(grep 'no derivation on record' "$WORK/ledger" | head -1)
case "$EFP_LINE" in
  *"profile 'aggressive'"*"running balanced"*)
     ok "EFP-2b ... naming the value it refused to invent a mapping for, and what it ran instead: $EFP_LINE" ;;
  *) no "EFP-2b the line does not name the value and the fallback: [$EFP_LINE]" ;;
esac
asrt "EFP-2c ... and BEHAVIOUR is unchanged: the rest of the ledger equals the control run" \
     "$(grep -v 'no derivation on record' "$WORK/ledger")" "$EFP_Q"
asrt "EFP-2d ... and it never wrote a mode of its own" "$(cat "$WORK/etc/p5/mode")" lightning
setup


# ================= U226 -- THE DATAPATH STATS READER (ST) ====================
# `_stats` is the READER half of U225's stats file (p4-bondagg/daemon/stats.go
# renames a whole snapshot into place each PSTAT tick). The two states the design
# names are the two bars: the file is not there -- a RESULT, printed as one
# `absent:` line with rc 0, because every probe verb here exits 0 for "no data"
# and rc!=0 means the tool itself failed -- and the file is there with a KNOWN
# age.
#
# ST-2 ASSERTS ON A NUMBER, NOT ON THE WORD "stale". The reader prints an
# interval; the PAGE decides fresh vs stale from the cadence the file itself
# states in `ival_ms=`. A reader that printed a label would move that decision
# into the artifact that cannot see the cadence, and this bar would not notice.
setup
STF="$WORK/run/p5/datapath.stats"
rm -f "$STF"
ST1RC=0; ST1=$(xctl _stats 2>&1) || ST1RC=$?
asrt "ST-1 no stats file -> ONE 'absent:' line, rc 0 (absent is a result, not a failure)" \
     "$(printf '%s\n' "$ST1" | head -1 | cut -d' ' -f1)|$ST1RC|$(printf '%s\n' "$ST1" | grep -c .)" \
     "absent:|0|1"
asrt "ST-1b ... and the line names the path and all three worlds that produce it" \
     "$(printf '%s\n' "$ST1" | grep -c 'datapath\.stats not written (daemon down, AGG_STATS unset, or pre-U225 binary)')" 1

# The fixture is the grammar the portal plan fixes at section 9 so U225 and U226
# could be built apart. Link names are placeholders on purpose: nothing in the
# reader or the page tests an interface NAME (N-generic).
ST2SEED=100
ST2T0=$(date +%s)
{ printf 'ts=%s up=1200 ival_ms=1000 PSTAT n=2 sched=speed depth=0 hold=7ms gate=0' "$(( ST2T0 - ST2SEED ))"
  printf ' | linkA sent=5 kb=2048 blk=0ms bp=0 err=0 up=true'
  printf ' | linkB sent=3 kb=1024 blk=0ms bp=0 err=0 up=true\n'
  printf 'link linkA loss_pct=0.4\n'
  printf 'link linkB loss_pct=1.2\n'
  printf 'latency p50=absent p95=absent\n'; } > "$STF"
ST2RC=0; ST2=$(xctl _stats 2>&1) || ST2RC=$?
ST2T1=$(date +%s)
# The sed matches DIGITS only, so `age_s=stale` / `age_s=unknown` yield the empty
# string and the bar reports what it actually saw.
ST2AGE=$(printf '%s\n' "$ST2" | sed -n 's/^age_s=\(-\{0,1\}[0-9][0-9]*\)$/\1/p' | head -1)
asrt "ST-2 the age line is a NUMBER, not a label" \
     "$(if [ -n "$ST2AGE" ]; then echo number; else echo "not-a-number($(printf '%s\n' "$ST2" | head -1))"; fi)" \
     number
# The window's BOTH ends are measured in this block, so the bar is exact rather
# than tolerant: a reader printing 0 fails it, and the one-second clock tick that
# can fall between the seed and the read does not.
asrt "ST-2b ... and it equals the seeded age (window ${ST2SEED}..$(( ST2T1 - ST2T0 + ST2SEED ))s)" \
     "$(if [ -n "$ST2AGE" ] && [ "$ST2AGE" -ge "$ST2SEED" ] && [ "$ST2AGE" -le "$(( ST2T1 - ST2T0 + ST2SEED ))" ]
        then echo in; else echo "out($ST2AGE)"; fi)" in
# BYTE-for-byte, which is also what proves an unknown future key survives the
# reader untouched: this function copies the body through and parses one token.
asrt "ST-2c rc 0 and the file follows the age line byte-for-byte" \
     "$ST2RC|$(printf '%s\n' "$ST2" | sed '1d' | cksum)" "0|$(cksum < "$STF")"

# ST-2z THE CONTROL. A bar that has never been shown to fail would pass on an
# empty file. The mutant is the exact defect ST-2b exists to catch: a reader that
# reports a constant age, i.e. every file as fresh forever.
STMUT="$WORK.stmut"
rm -rf "$STMUT"; mkdir -p "$STMUT"; cp -R "$P5/lib/." "$STMUT/"
awk '/_sn_now - _sn_ts/ { print "        echo \"age_s=0\""; next } { print }' \
    "$P5/lib/xctl-probe.sh" > "$STMUT/xctl-probe.sh"
asrt "ST-2z MUT applied: the mutant computes no interval and prints a constant" \
     "$(grep -c '_sn_now - _sn_ts' "$STMUT/xctl-probe.sh")|$(grep -c 'echo "age_s=0"' "$STMUT/xctl-probe.sh")" \
     "0|1"
STZAGE=$(XCTL_LIB="$STMUT" sh "$P5/bond-xctl" _stats 2>&1 \
         | sed -n 's/^age_s=\(-\{0,1\}[0-9][0-9]*\)$/\1/p' | head -1)
asrt "ST-2z ... and ST-2b's window REJECTS it -- ST-2b is a bar that can fail" \
     "$(if [ -n "$STZAGE" ] && [ "$STZAGE" -ge "$ST2SEED" ]; then echo accepted; else echo "rejected($STZAGE)"; fi)" \
     "rejected(0)"
rm -rf "$STMUT"

# ST-3 THE PATH IS NOT A LOCAL CONSTANT. The reader's default and the literal the
# daemon's init script publishes are the SAME string, compared here rather than
# written twice in two files that can drift apart silently.
# The three programs below are grep/sed patterns whose SUBJECT is the shipped
# source's own text (`$RUN_DIR`, `${AGG_STATS:-...}`). Expanding them would search
# this harness's environment, match nothing, and go green blind.
# shellcheck disable=SC2016
ST3_RD=$(grep -o 'RUN_DIR="${RUN_DIR:-[^}]*}"' "$P5/bond-xctl" | sed 's/.*:-//; s/}"$//' | head -1)
# shellcheck disable=SC2016
ST3_BASE=$(grep -o 'AGG_STATS:-\$RUN_DIR/[A-Za-z0-9._-]*' "$P5/lib/xctl-probe.sh" | sed 's#.*/##' | head -1)
ST3_INIT=$(grep -o 'AGG_STATS=[^ "]*' "$P5/init.d/bond-agg" | sed 's/^AGG_STATS=//' | head -1)
asrt "ST-3 the reader's default stats path IS the literal init.d/bond-agg publishes" \
     "$ST3_RD/$ST3_BASE" "$ST3_INIT"

# ST-4 the verb's own shape. A sleep here would make a portal click bounded by
# the reader, which is what the plan's PROBES rule ("no sleep in the CGI")
# forbids; the deltas are computed page-side between two clicks instead.
ST4_BODY=$(sed -n '/^stats_now() {/,/^}/p' "$P5/lib/xctl-probe.sh")
asrt "ST-4 the stats reader contains no sleep" "$(printf '%s\n' "$ST4_BODY" | grep -c 'sleep')" 0
asrt "ST-4b ... and it is defined exactly once in the shipped lib" \
     "$(grep -c '^stats_now() {' "$P5/lib/xctl-probe.sh")" 1
setup

echo "===== Layer-2: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
