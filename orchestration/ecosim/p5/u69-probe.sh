#!/bin/sh
# orchestration/ecosim/p5/u69-probe.sh — U69 bisect probe.
#
# WHY: U67 measured that the Layer-2 harness scores 173/0 under bash and 159/14
# under `busybox ash`, with the SAME harness shell in both arms -- only the
# interpreter of deploy/p5/bond-xctl differs. This script narrows that to a
# construct by running the source-discovery chain ONE STAGE AT A TIME under
# whichever interpreter invokes it, printing each intermediate so two arms can
# be diffed instead of reasoned about.
#
# It sources bond-xctl's FUNCTION LIBRARY (everything above the entry-point
# `case`) so the code under test is the shipped code, not a copy.
#
#   sh u69-probe.sh            # whatever `sh` is
#   busybox ash u69-probe.sh
#   dash u69-probe.sh
#
# Prints ONLY facts. It asserts nothing; the CI job diffs the arms.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
P5="$REPO/deploy/p5"
BIN="$HERE/bin"

W="${U69_WORK:-/tmp/u69world}"
NWAN="${U69_NWAN:-3}"

# --- a minimal ecosim world (the subset gl_sources reads) ------------------
rm -rf "$W"; mkdir -p "$W/etc/bond" "$W/run/bond"
echo "$NWAN" > "$W/nwan"
echo lightning > "$W/etc/bond/mode"
echo wgclient1 > "$W/etc/bond/wg-logical"

export ECOSIM_STATE="$W"
export PATH="$BIN:$PATH"
export BOND_DIR="$W/etc/bond"
export RUN_DIR="$W/run/bond"
export DAG="$P5/bond.dag"
export WG_DEV=wgclient1
# The U69 fix: inject the two applet-shadowed commands by path instead of relying
# on PATH, which a standalone busybox shell ignores for its own applet names.
# Set U69_NOINJECT=1 to reproduce the ORIGINAL divergence.
[ "${U69_NOINJECT:-0}" = 1 ] || { export IP="$BIN/ip"; export PING="$BIN/ping"; }

# --- the shipped function library, minus the entry point -------------------
LIB="$W/xctl.lib"
sed '/^# ================= entry point/,$d' "$P5/bond-xctl" > "$LIB"
grep -q '^gl_sources()' "$LIB" || { echo "PROBE-BROKEN: no gl_sources in $LIB"; exit 2; }
# shellcheck disable=SC1090
. "$LIB"

echo "### interpreter: ${U69_ARM:-?}"

echo "--- [1] which implementation each utility resolves to"
for n in awk sed grep sort ip ubus uci cmp tr wc head cut ls sleep ping iptables wg; do
    echo "    $n -> $(command -v "$n" 2>/dev/null || echo NONE)"
done
echo "    awk identity: $(echo | awk 'BEGIN{print (length(ENVIRON)>=0)?"":""} END{}' 2>&1; awk --version 2>&1 | head -1 || true)"

echo "--- [2] ubus list -> gl_ifaces"
echo "    $(gl_ifaces | tr '\n' ' ')"

echo "--- [3] route table as each spelling sees it"
echo "    bare \`ip\` (PATH lookup, bypassed by a standalone busybox shell):"
ip route show default | sed 's/^/        /'
echo "    injected \"\$IP\" (= ${IP:-ip}):"
"${IP:-ip}" route show default | sed 's/^/        /'

echo "--- [4] _route_defaults"
echo "    [$(_route_defaults)]"

echo "--- [5] _json_pick per interface (l3_device|device|available|up|proto|metric|.)"
for _i in $(gl_ifaces); do
    _f=$(ubus call "network.interface.$_i" status 2>/dev/null \
         | _json_pick l3_device device available up proto metric)
    echo "    $_i => [$_f]"
done

echo "--- [6] gl_sources"
gl_sources | sed 's/^/    /'

echo "--- [7] _SRC_SNAP-derived views"
_SRC_SNAP=$(gl_sources 2>/dev/null)
echo "    live_wans   : $(live_wans | tr '\n' ' ')"
echo "    ordered_wans: $(ordered_wans | tr '\n' ' ')"
echo "    primary_wan : $(primary_wan)"

echo "--- [8] the same via the real CLI entry points"
echo "    _sources:"
sh "$P5/bond-xctl" _sources 2>&1 | sed 's/^/        /'
echo "    _primary: $(sh "$P5/bond-xctl" _primary 2>&1)"
