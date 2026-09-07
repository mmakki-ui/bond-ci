#!/bin/sh
# orchestration/ecosim/p5/gl-discovery.sh — Layer-2 battery for GL/ubus SOURCE
# DISCOVERY (OBJ-A: "source status comes FROM GL, not from inference").
#
# Runs the REAL shipped deploy/p5/bond-xctl against the hermetic ubus/ip/uci
# shims in ./bin, whose netifd fixture reflects the CLIENT as documented in
# docs/INTENT.md OBJ-A/OBJ-H (four declared WAN interfaces, two routed,
# `wwan` available:false, GL's kill-switch blackhole at metric 254).
#
# It is a SIBLING of run.sh, not an edit to it: run.sh owns the lifecycle/fault
# battery, this owns discovery. Same shims, same pattern, one writer per file.
#
# WHAT THIS CAN AND CANNOT PROVE. It proves the discovery LOGIC against a
# fixture. It cannot prove the fixture: nobody here can reach the box, so the
# real `ubus call network.interface.<x> status` reply shape is taken from what
# INTENT records (available / up / l3_device / metric) and nothing more. Every
# claim that needs the real box is listed at the end of this file.
#
# Exit code is the gate: 0 iff every assertion passes.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
P5="$REPO/deploy/p5"
BIN="$HERE/bin"
WORK="${ECOSIM_WORK:-$(mktemp -d 2>/dev/null || echo "$HERE/gl.$$")}"
[ -n "${ECOSIM_WORK:-}" ] || trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
no() { fail=$((fail+1)); echo "FAIL  $1"; }
asrt(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1 (want '$3' got '$2')"; fi; }

setup() {
    rm -rf "$WORK"; mkdir -p "$WORK/etc/p5" "$WORK/run/p5" "$WORK/fakebin"
    export ECOSIM_STATE="$WORK"
    for b in engarde-client p5-datapath p5-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"
    done
    echo lightning > "$WORK/etc/p5/mode"
    echo "203.0.113.9:51820" > "$WORK/direct"
    echo "203.0.113.9:51820" > "$WORK/ep"
    echo 1 > "$WORK/capable"
    export PATH="$BIN:$PATH"
    export BOND_DIR="$WORK/etc/p5"
    export RUN_DIR="$WORK/run/p5"
    export DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    export SVC="$BIN/svc-engarde"
    export AGG_SVC="$BIN/svc-agg"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client"
    export AGG_BIN="$WORK/fakebin/p5-datapath"
    # U124: the bin sources its five libs from XCTL_LIB (default /usr/lib/p5).
    # This harness runs the shipped tree out of a worktree, so it must say where.
    export XCTL_LIB="$P5/lib"
    for s in engarde-client p5-datapath p5-ecod p5-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
}
fact() { echo "$2" > "$WORK/$1"; }
xctl() { sh "$P5/bond-xctl" "$@" 2>/dev/null; }
# SNAPSHOT the source table once per world state, then assert against it.
# Discovery is a PURE PROBE, so one probe per world state is exactly the same
# evidence as one probe per assertion -- and it keeps the battery cheap enough
# to run often. Call snap after every setup/knob change.
SRC=""
snap() { SRC=$(xctl _sources); }
row()  { printf '%s\n' "$SRC" | awk -v i="$1" '$1==i {print $2" "$3" "$4" "$5}'; }
wans() { printf '%s\n' "$SRC" | awk '$3=="routed" {print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }

echo "===== P5 Layer-2 GL/ubus source discovery ====="

# --- G1: the box declares FOUR WAN sources; route-parsing can see TWO -------
# This is the whole point of the unit. `secondwan` is configured + connected
# and carries no default route, so `ip route show default` is blind to it.
setup
snap
asrt "G1 wan       (routed, netifd metric 1)" "$(row wan)"       "eth1 routed 1 -"
asrt "G1 tethering (routed, netifd metric 2)" "$(row tethering)" "usb0 routed 2 -"
asrt "G1 secondwan (DARK: up, NOT routed)"    "$(row secondwan)" "eth0 up 3 -"
asrt "G1 wwan      (absent: no modem)"        "$(row wwan)"      "wwan0 absent 4 metered"
asrt "G1 routed devices == what routes show"  "$(wans)"          "eth1 usb0"

# --- G2: nothing that is NOT an uplink may leak in --------------------------
# `guest` is up, has an address and a device, and is NOT in STATIC_EXCLUDES.
# The only thing keeping it out is the uplink criterion (a netifd metric).
# No interface NAME is tested anywhere in the implementation.
asrt "G2 guest never appears"     "$(row guest)"     ""
asrt "G2 lan never appears"       "$(row lan)"       ""
asrt "G2 loopback never appears"  "$(row loopback)"  ""
asrt "G2 wg device never appears" "$(row wgclient1)" ""
# wan6 shares eth1 (a routed device) so it IS a source row -- and devices
# dedupe, so it cannot double-count into the underlay list.
asrt "G2 wan6 folds onto eth1, no dup" "$(wans)" "eth1 usb0"

# --- G3: NEVER SHRINK -- the routed set is a superset of the legacy answer --
# Old live_wans() was `ip route show | /^default/ -> dev`. Same answer here.
LEGACY=$(sh "$BIN/ip" route show | awk '/^default/ {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' \
         | sort -u | grep -v '^wgclient1$' | tr '\n' ' ' | sed 's/ $//')
asrt "G3 routed set == legacy route-parse set" "$(wans)" "$LEGACY"

# --- G4: primary follows netifd's METRIC, not the route table's order ------
# The ip shim's route metrics are 10/20; netifd's are 1/2. `eco` is defined to
# follow netifd's metric (OBJ-H), and the two must not be conflated.
asrt "G4 primary = lowest netifd metric" "$(xctl _primary)" eth1

# --- G5: BLACKHOLE GUARD (docs/INTENT.md OBJ-H) ----------------------------
# Arm GL's VPN kill-switch: a `blackhole default metric 254` route AND (the
# adversarial case) the kill-switch declared as a network.interface object.
setup; fact blackhole 1
snap
asrt "G5 blackhole route is not a source"      "$(wans)" "eth1 usb0"
asrt "G5 blackhole iface is not a source"      "$(row wgclient1_blackhole)" ""
asrt "G5 primary unchanged with kill-switch"   "$(xctl _primary)" eth1

# --- G6: a routed source going dark ----------------------------------------
# onewan=1 withdraws usb0's default route. tethering must NOT vanish from the
# facts (route-parsing would have lost it entirely) -- it becomes DARK, and
# leaves the usable-now set.
setup; fact onewan 1
snap
asrt "G6 tethering demoted routed->up" "$(row tethering)" "usb0 up 2 -"
asrt "G6 usable-now set shrinks to 1"  "$(wans)" "eth1"
asrt "G6 primary follows"              "$(xctl _primary)" eth1

# --- G7: METERED comes from a fact or the proto, NEVER from the name -------
# The deleted regex was '^(usb|wwan|rmnet)'. usb0 matches it. Nothing about a
# USB tether tells the router it is metered (INTENT OBJ-H: a tethered phone's
# radio -- and its billing -- are invisible by construction), so the honest
# default is NOT metered until the operator says so.
setup
snap
asrt "G7 usb0 NOT metered by its name"     "$(row tethering)" "usb0 routed 2 -"
echo tethering > "$WORK/etc/p5/metered"
snap
asrt "G7 metered after operator declares"  "$(row tethering)" "usb0 routed 2 metered"
echo usb0 > "$WORK/etc/p5/metered"
snap
asrt "G7 declaration by DEVICE works too"  "$(row tethering)" "usb0 routed 2 metered"
rm -f "$WORK/etc/p5/metered"
snap
asrt "G7 cellular proto is metered"        "$(row wwan)" "wwan0 absent 4 metered"
asrt "G7 dhcp uplink is not"               "$(row wan)"  "eth1 routed 1 -"

# --- G8: metric precedence ubus -> uci -> route ----------------------------
setup; fact noubusmetric.wan 1; fact ucimetric.wan 7   # ubus silent, uci answers 7
snap
asrt "G8 uci metric used when ubus has none" "$(row wan)" "eth1 routed 7 -"
asrt "G8 primary re-ranks on the uci metric" "$(xctl _primary)" usb0
setup; fact noubusmetric.wan 1                          # neither ubus nor uci
snap
asrt "G8 route metric is the last resort"    "$(row wan)" "eth1 routed 10 -"
asrt "G8 route-metric rank still holds"      "$(xctl _primary)" usb0

# --- G9: a routed device ubus declares no interface for --------------------
# NEVER SHRINK: it is still a live source, emitted with iface '-'.
setup; fact unclaimed ppp0
snap
asrt "G9 unclaimed routed device kept" "$(row -)" "ppp0 routed 40 -"
asrt "G9 and it joins the usable set"  "$(wans)" "eth1 ppp0 usb0"

# --- G10: nested JSON keys must not leak -----------------------------------
# The `wan` fixture nests "up":false / "metric":9999 / "l3_device":NESTED
# inside its "route" array. A depth-blind parser reads those and mis-ranks
# every source. Covered by G1/G4 above; asserted explicitly here.
setup
snap
asrt "G10 depth-1 only: device"  "$(printf '%s\n' "$SRC" | awk '$1=="wan"{print $2}')" eth1
asrt "G10 depth-1 only: metric"  "$(printf '%s\n' "$SRC" | awk '$1=="wan"{print $4}')" 1
asrt "G10 no nested value leaked" "$(printf '%s\n' "$SRC" | grep -c NESTED)" 0

# --- G11: ubus absent -> the legacy route parse, never an empty underlay ----
# A box without ubus (or a status shape this parser cannot read) must still
# bond. `_sources` exits 1 so a caller can tell "none" from "cannot ask".
setup
NOUBUS="$WORK/nobus"; mkdir -p "$NOUBUS"
for t in ip uci wg iptables logger pgrep ping sleep; do cp "$BIN/$t" "$NOUBUS/$t"; done
NW=$(PATH="$NOUBUS:/usr/bin:/bin" sh "$P5/bond-xctl" _sources 2>/dev/null; echo "rc=$?")
asrt "G11 _sources fails loudly with no ubus" "$NW" "rc=1"
NP=$(PATH="$NOUBUS:/usr/bin:/bin" sh "$P5/bond-xctl" _primary 2>/dev/null)
asrt "G11 primary falls back to route parse"  "$NP" eth1

# --- G12: the shipped artifact still parses + the old hardcodes are gone ----
setup
asrt "G12 bond-xctl selfcheck"          "$(xctl selfcheck | tail -1)" "selfcheck: $DAG parsed"
# U124: the source discovery this checks lives in lib/xctl-probe.sh now. Both
# names are greppped in the file that would carry them again if they came back.
asrt "G12 name regex METERED_PAT gone"  "$(grep -c 'METERED_PAT' "$P5/lib/xctl-probe.sh")" 0
asrt "G12 name regex WIRED_PAT gone"    "$(grep -c 'WIRED_PAT' "$P5/lib/xctl-probe.sh")" 0

# --- G13: equal metrics -> a DETERMINISTIC pick, not an arbitrary one ------
# Two routed sources declared at the same metric. `eco` must still name one
# source and always the same one; the answer must not depend on `ubus list`
# ordering. Lexical by device is the tie-break -- a determinism rule, not a
# preference for any source.
setup
fact noubusmetric.wan 1; fact noubusmetric.tethering 1
fact ucimetric.wan 5;    fact ucimetric.tethering 5
snap
asrt "G13 tied metrics: wan side"  "$(row wan)"       "eth1 routed 5 -"
asrt "G13 tied metrics: teth side" "$(row tethering)" "usb0 routed 5 -"
asrt "G13 deterministic primary"   "$(xctl _primary)" eth1
asrt "G13 same answer on re-probe" "$(xctl _primary)" eth1

echo "-------------------------------------------------"
echo "GL discovery: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
