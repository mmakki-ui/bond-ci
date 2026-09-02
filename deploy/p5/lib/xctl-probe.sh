#!/bin/sh
# xctl-probe.sh -- sourced by bond-xctl (U124 split). Bodies byte-identical to the
# single-file reconciler; see docs/knowledge/design for the WHY of each function.

# ================= reality-faithful probe registry (one owner each) =========
live_peer()    { wg show "$WG_DEV" peers 2>/dev/null | head -1; }
live_section() {
    P=$(live_peer); [ -n "$P" ] || return 1
    uci show wireguard 2>/dev/null | grep -F "$P" | grep "\.public_key=" | head -1 | cut -d. -f1-2
}
live_direct()  { uci -q get "$(live_section).end_point" 2>/dev/null; }
live_server_host() { D=$(live_direct); case "$D" in *:*) echo "${D%:*}";; *) return 1;; esac; }
ep_now()       { wg show "$WG_DEV" endpoints 2>/dev/null | awk '{print $2}' | head -1; }

# ============ GL/ubus SOURCE DISCOVERY (OBJ-A, Mo 2026-08-29) ==============
# "Source status comes FROM GL, not from inference."
#
# CONTRACT -- this whole block is a PROBE, i.e. a FACT PRODUCER. It reads the
# box's own declaration and prints facts. It takes NO action: nothing here
# restarts a service, mutates wg/uci, writes a fact file, or walks a bond.dag
# edge. That is the discovery-side reading of the reconciler rule at the head of
# this file ("the caller writes facts, reconcile() derives the ONE edge"): a
# discovery layer may only change what reconcile SEES, never what it DOES.
# (Deliberate: the facts are re-derived per invocation and never cached to disk.
# A cached source table would be STATE the level-triggered reconciler must not
# trust, and a stale cache is exactly the failure this design forbids.)
#
# WHAT ROUTE-PARSING COULD NOT SEE. The previous implementation derived the
# source list from `ip route show default`, so it could only ever see a source
# that is ROUTED. Measured on the client (docs/INTENT.md OBJ-A/OBJ-H): netifd
# declares FOUR WAN interfaces -- wan(eth1) metric 1, tethering(usb0) metric 2,
# secondwan metric 3, wwan metric 4 -- and only TWO carry a default route. So
# route-parsing saw two of the four, and `secondwan` is precisely the
# configured-but-unrouted source it cannot see, by construction.
# It also GUESSED metered-ness from the interface NAME ('^(usb|wwan|rmnet)').
# Both are replaced below by what the box itself declares over ubus:
# `available` (device present) vs `up` (L3 connected) vs routed (carries a
# default route), the interface->l3_device mapping, and the metric.
#
# N-GENERIC: no interface NAME is ever tested anywhere below. The source set is
# whatever `ubus list` declares, in whatever number and order; there is no
# privileged source, no first/second, no 2-source assumption.
#
# NEVER SHRINK: every step is written so that a missing or unexpected ubus
# field can only fail to ADD a source, never remove one the route table shows.
# The routed set is therefore a SUPERSET of the legacy answer on any box.

# _json_pick: stdin = ONE JSON object; stdout = ONE line carrying the DEPTH-1
# SCALAR values of the requested keys, in the order asked, '|'-separated with
# a trailing '.' sentinel so a trailing EMPTY field survives word-splitting.
# Nested objects/arrays are skipped WHOLE, so a nested key -- e.g. the
# per-route "metric"/"up" inside netifd's "route" array -- can never be
# mistaken for the interface's own. Handles ubus pretty output AND compact.
# Pure text: no jsonfilter/jshn presence assumed on the box.
# ONE awk per interface, not one per field: this runs on every probe of a
# ~10s-tick reconciler on a busybox router, so the process count is part of
# the design, not an afterthought. Prints NOTHING when the input is not a
# JSON object (a failed ubus call), so a caller can tell "no answer" from
# "an empty answer".
_json_pick() {   # $@ = the keys to emit, in order
    awk -v keys="$*" '
      function rdstr(s, i,   j, ch, t) {
        j = i + 1; t = ""
        while (j <= length(s)) {
          ch = substr(s, j, 1)
          if (ch == "\\") { t = t substr(s, j+1, 1); j += 2; continue }
          if (ch == "\"") break
          t = t ch; j++
        }
        VAL = t; return j + 1
      }
      function skipc(s, i,   dd, ch, n) {
        n = length(s); dd = 0
        while (i <= n) {
          ch = substr(s, i, 1)
          if (ch == "\"") { i = rdstr(s, i); continue }
          if (ch == "{" || ch == "[") dd++
          else if (ch == "}" || ch == "]") { dd--; if (dd == 0) return i + 1 }
          i++
        }
        return i
      }
      { buf = buf $0 "\n" }
      END {
        n = length(buf); i = 1; d = 0; seen = 0; expect = "key"; key = ""
        while (i <= n) {
          c = substr(buf, i, 1)
          if (c == " " || c == "\t" || c == "\n" || c == "\r") { i++; continue }
          if (d == 0) { if (c == "{") { d = 1; seen = 1 } ; i++; continue }
          if (c == "}") { d = 0; i++; continue }
          if (c == ",") { expect = "key"; i++; continue }
          if (c == ":") { expect = "value"; i++; continue }
          if (c == "\"") {
            i = rdstr(buf, i)
            if (expect == "key") key = VAL
            else { V[key] = VAL; key = ""; expect = "key" }
            continue
          }
          if (c == "{" || c == "[") { i = skipc(buf, i); key = ""; expect = "key"; continue }
          t = ""
          while (i <= n) { c = substr(buf, i, 1)
            if (c == "," || c == "}" || c == " " || c == "\t" || c == "\n" || c == "\r") break
            t = t c; i++ }
          if (expect == "value") { V[key] = t; key = ""; expect = "key" }
        }
        if (!seen) exit 0
        m = split(keys, K, " "); out = ""
        for (q = 1; q <= m; q++) out = out (K[q] in V ? V[K[q]] : "") "|"
        print out "."
      }'
}

gl_ok()     { command -v ubus >/dev/null 2>&1; }
# the netifd interface namespace, as the box declares it (no name is assumed)
gl_ifaces() { ubus list 2>/dev/null | sed -n 's/^network\.interface\.//p' | sort -u; }

# _route_defaults: dev<TAB>metric for every default route that NAMES a device.
# BLACKHOLE GUARD (required, docs/INTENT.md OBJ-H): GL's VPN kill-switch
# configures `network.wgclient1_blackhole.metric=254`, a blackhole default
# route. It can never be read as a source here, for TWO independent reasons,
# either sufficient on its own:
#   (1) iproute2 prints a blackhole route with `blackhole` as the FIRST field
#       ("blackhole default ... metric 254"), so `$1=="default"` is FALSE; and
#   (2) a blackhole route names no output device, so `d` stays empty and the
#       pair is dropped by `if (d!="")`.
# The ubus side is guarded independently: a source is accepted only with a
# NON-EMPTY l3_device (a blackhole has none), and the kill-switch section is a
# route, not an interface, so it is not expected in `ubus list` at all. The
# harness asserts the ADVERSARIAL case where it IS listed as an interface.
# Emitted as space-separated `dev=metric` pairs so every later lookup is a
# shell `case` match instead of another awk process.
_route_defaults() {
    "$IP" route show default 2>/dev/null | awk '
        $1=="default" { d=""; m=""
            for (i=1;i<NF;i++) { if($i=="dev") d=$(i+1); if($i=="metric") m=$(i+1) }
            if (d!="") printf "%s=%s ", d, m }'
}

_excluded_dev() {   # TRUE (0) if $1 must never be treated as a WAN source
    [ -z "$1" ] && return 0
    [ "$1" = "$WG_DEV" ] && return 0
    for _x in $STATIC_EXCLUDES; do [ "$1" = "$_x" ] && return 0; done
    return 1
}

# METERED -- replaces the '^(usb|wwan|rmnet)' NAME GUESS.
# Metered-ness is a BILLING property, not a network property, so it is not
# universally observable. Two truthful sources, in precedence order:
#   1. OPERATOR FACT `$BOND_DIR/metered` (one interface OR device name per
#      line). This is the ONLY truthful source for a USB TETHER: INTENT OBJ-H
#      records that a tethered phone presents as a plain DHCP netdev, so the
#      router cannot observe its radio -- or its billing -- by construction.
#      The old regex "happened" to classify usb0 correctly; that was luck, and
#      luck is not a classification.
#   2. netifd PROTO in the cellular set -> metered by construction (an internal
#      modem). Config-derived, not name-derived. On the client this fires only
#      for a future box: this one has NO internal modem (wwan available:false).
# NOT invented: nothing here reads the `cellular.*` tree, because INTENT
# records that `cellular.status` exposes no status method and the rest is
# unchecked -- that is an open question, not a guessed field name.
GL_CELL_PROTOS="qmi ncm mbim modemmanager 3g"
_metered() {   # $1=iface $2=device $3=proto
    if [ -r "$BOND_DIR/metered" ]; then
        grep -qx -e "$1" -e "$2" "$BOND_DIR/metered" 2>/dev/null && return 0
    fi
    for _cp in $GL_CELL_PROTOS; do [ "$3" = "$_cp" ] && return 0; done
    return 1
}

# gl_sources: THE source table, one line per declared source:
#     <iface> <l3_device> <state> <metric|-> <metered|->
# state (a property of the l3_device, not of the name):
#   routed  the device carries a default route -> usable NOW
#   up      available AND connected AND has an l3_device, but NOT routed
#           -- the DARK source route-parsing cannot see
#   idle    declared uplink, present, not connected
#   absent  declared uplink, device not present (ubus available:false -- e.g.
#           `wwan` on a box with no internal modem)
# UPLINK CRITERION for a NON-routed interface: it must carry a netifd `metric`.
# netifd metrics exist to ORDER DEFAULT ROUTES, so a configured metric is the
# box declaring "this interface is an uplink". Measured support (INTENT OBJ-H,
# `uci show network | grep -i metric`): exactly wan=1, tethering=2,
# secondwan=3, wwan=4 -- the four WANs and nothing else (`lan` has none).
# This is why `lan`/`guest`/any other up-with-an-address interface can never
# leak into the source set, WITHOUT testing a single interface name.
gl_sources() {
    gl_ok || return 1
    _RTS=" $(_route_defaults)"      # " eth1=1 usb0=2 " -- one ip+awk, once
    _CLAIMED=" "
    for _if in $(gl_ifaces); do
        # ONE ubus + ONE awk per interface. The '.' sentinel proves the reply
        # was a JSON object at all (a failed call prints nothing).
        _F=$(ubus call "network.interface.$_if" status 2>/dev/null \
             | _json_pick l3_device device available up proto metric)
        [ -n "$_F" ] || continue
        _oi=$IFS; IFS='|'; set -f
        # shellcheck disable=SC2086
        set -- $_F
        set +f; IFS=$_oi
        _dev="$1"; [ -n "$_dev" ] || _dev="$2"      # l3_device, else device
        _av="$3"; _up="$4"; _pr="$5"; _mt="$6"
        _excluded_dev "$_dev" && continue
        # ROUTED? a pure shell lookup against the route pairs -- no process.
        _rt=0; _rm=""
        case "$_RTS" in
            *" $_dev="*) _rt=1; _rm=${_RTS#*" $_dev="}; _rm=${_rm%% *} ;;
        esac
        # metric precedence: ubus -> uci (netifd OWNS the metrics, OBJ-H) ->
        # the live route metric. Each is a measured source; none is invented.
        [ -n "$_mt" ] || _mt=$(uci -q get "network.$_if.metric" 2>/dev/null)
        [ -n "$_mt" ] || _mt="$_rm"
        if   [ "$_rt" = 1 ];     then _state=routed
        elif [ -z "$_mt" ];      then continue        # not declared an uplink
        elif [ "$_av" = false ]; then _state=absent
        elif [ "$_up" = true ];  then _state=up       # the DARK source
        else                          _state=idle
        fi
        _md=-; _metered "$_if" "$_dev" "$_pr" && _md=metered
        echo "$_if $_dev $_state ${_mt:--} $_md"
        [ "$_rt" = 1 ] && _CLAIMED="$_CLAIMED$_dev "
    done
    # NEVER SHRINK: a device that carries a default route but that no ubus
    # interface claimed (a route added out of band, or an unexpected status
    # shape) is still a live source. Emitting it here makes the routed set a
    # SUPERSET of the legacy route-parse answer on every box, so this change
    # can only add sources, never take one away.
    for _p in $_RTS; do
        _d=${_p%%=*}; _m=${_p#*=}
        [ -n "$_d" ] || continue
        _excluded_dev "$_d" && continue
        case "$_CLAIMED" in *" $_d "*) continue ;; esac
        _md=-; _metered "-" "$_d" "" && _md=metered
        echo "- $_d routed ${_m:--} $_md"
    done
}

# ONE OBSERVATION PER INVOCATION. gl_sources is a pure probe, but a reconcile
# pass reads the source list from several places (converged(), genconf, the
# guards, the builders). Re-probing at each call is not MORE level-triggered,
# it is LESS CONSISTENT: two calls in one pass can disagree if a WAN comes up
# mid-pass, and then converged() compares the live config against one built
# from a different world -- a torn read that shows up as a needless datapath
# bounce or a missed one. So: probe ONCE per process, in the MAIN shell (every
# probe below runs inside a command substitution, i.e. a subshell, and
# subshells INHERIT this but can never write back), and let the next trigger
# re-observe. This is not stored state: it lives only in this process, dies
# with it, and no invocation ever starts from a remembered world.
_SRC_SNAP=""

# live_wans: the sources usable NOW = the ROUTED subset, as device names.
# DELIBERATELY NOT WIDENED to the dark (`up`) sources: whether engarde can bind
# and egress on an interface that is up but carries no default route is NOT
# derivable from the record and cannot be tested without the box -- it is an
# open question. Widening it here would put a guess in the datapath, so the
# dark sources are PUBLISHED (`bond-xctl _sources`) and not yet CONSUMED.
live_wans() {
    _S="$_SRC_SNAP"
    if [ -n "$_S" ]; then
        printf '%s\n' "$_S" | awk '$3=="routed" {print $2}' | sort -u | grep -v "^$WG_DEV$"
        return 0
    fi
    # FALLBACK (ubus absent or unusable): the legacy route parse, so a box
    # without ubus is never left with NO underlays.
    "$IP" route show 2>/dev/null | awk '/^default/ {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' \
        | sort -u | grep -v "^$WG_DEV$"
}
# primary_wan: lowest netifd metric among the ROUTED sources. Metric ownership
# is netifd's (OBJ-H), which is exactly what `eco` is defined to follow. Ties
# break lexically by device -- a DETERMINISM rule, not a preference: no source
# is privileged, and the answer must not depend on `ubus list` ordering.
primary_wan() {
    _S="$_SRC_SNAP"
    if [ -n "$_S" ]; then
        _P=$(printf '%s\n' "$_S" \
            | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg && $4 ~ /^[0-9]+$/ {print $4" "$2}' \
            | sort -k1,1n -k2,2 | awk 'NR==1 {print $2}')
        # a routed source with NO metric anywhere must still be electable
        [ -n "$_P" ] || _P=$(printf '%s\n' "$_S" \
            | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg {print $2}' | sort | head -1)
        [ -n "$_P" ] && { echo "$_P"; return 0; }
    fi
    "$IP" route show 2>/dev/null | awk '$1=="default"{m=0;d="";for(i=1;i<NF;i++){if($i=="dev")d=$(i+1);if($i=="metric")m=$(i+1)} if(d!="")print m" "d}' \
        | sort -n | awk '{print $2}' | grep -v "^$WG_DEV$" | head -1
}
# ordered_wans: live_wans as an ORDERED list -- lowest netifd metric first, ties
# broken lexically by device (primary_wan's DETERMINISM rule, not a preference),
# and any routed source whose metric is unknown last (still electable, same
# lexical tie-break). Two properties hold BY CONSTRUCTION, not by luck:
#   (a) `ordered_wans | head -1` == `primary_wan` (same ranking, same fallbacks);
#   (b) `ordered_wans` is `live_wans` as a SET -- this is an ORDERING, never a
#       filter. No head/tail cut, no branch on the count: N-generic.
# It is the box-side twin of Layer-1's `sources` tuple (bond_model.py: ordered by
# route metric so sources[0] IS the primary), so the artifact and the model
# enroll the same sources in the same order against the same bond.dag.
ordered_wans() {
    _S="$_SRC_SNAP"
    if [ -n "$_S" ]; then
        _L=$(printf '%s\n' "$_S" | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg {print $4" "$2}')
    else
        # FALLBACK (ubus absent or unusable): the legacy route parse. A default
        # route printed with NO `metric` keyword is metric 0 in the kernel, which
        # is what primary_wan's own fallback already assumes -- keep them identical.
        _L=$("$IP" route show 2>/dev/null | awk -v wg="$WG_DEV" '$1=="default"{m=0;d="";for(i=1;i<NF;i++){if($i=="dev")d=$(i+1);if($i=="metric")m=$(i+1)} if(d!="" && d!=wg) print m" "d}')
    fi
    [ -n "$_L" ] || return 0
    # numeric metrics first (ascending, lexical tie-break), then the metric-less;
    # the final awk de-dupes a device that carries two default routes, KEEPING its
    # best (first) rank -- so the set never shrinks and never gains a duplicate.
    { printf '%s\n' "$_L" | awk '$1 ~ /^[0-9]+$/' | sort -k1,1n -k2,2
      printf '%s\n' "$_L" | awk '$1 !~ /^[0-9]+$/' | sort -k2,2
    } | awk '$2!="" && !seen[$2]++ {print $2}'
}
# ordered_spotty: the SPOTTY-CLASS subset of ordered_wans -- exactly the
# devices gl_sources marked `metered` (the METERED fact, :252-274), filtered to
# the CURRENTLY LIVE ordered set. A SUBSET of ordered_wans, never a re-ranking,
# so it can never name a device outside AGG_PATHS (the daemon's own contract --
# lightning.go:750 WARNs and drops any AGG_SPOTTY entry not in AGG_PATHS).
# THIS is the plumbing U15b's own header named as missing (lightning.go:73-82,
# "THE FACT IS NOT PLUMBED YET"): build_agg_env emitted AGG_LISTEN/AGG_SERVER/
# AGG_PATHS/AGG_W and stopped, so a deployed daemon always saw an EMPTY spotty
# set and standing lightning was inert outside `go test` regardless of
# AGG_LIGHTNING. No name is parsed and no regexp exists here either -- same
# rule as _metered() itself.
ordered_spotty() {
    _S="$_SRC_SNAP"
    [ -n "$_S" ] || return 0
    _M=$(printf '%s\n' "$_S" | awk -v wg="$WG_DEV" '$3=="routed" && $2!=wg && $5=="metered" {print $2}')
    [ -n "$_M" ] || return 0
    # $_M is NEWLINE-separated (one awk print per device). Normalise it to a
    # space-delimited word list BEFORE the case membership test: `case " $_M "
    # in *" $_d "*` matches a literal space on each side of $_d, and a newline
    # is not a space, so the un-normalised form matched ONLY when exactly one
    # device was metered -- a hidden 1-metered-source assumption (Fable pass;
    # demonstrated, then covered by NG8d). Field splitting on $_M splits on
    # newlines too, so this loop is the normalisation and adds no dependency.
    _MS=" "; for _m in $_M; do _MS="${_MS}${_m} "; done
    for _d in $(ordered_wans); do
        case "$_MS" in *" $_d "*) printf '%s\n' "$_d" ;; esac
    done
}
# _lightning_enabled: AGG_LIGHTNING is OFF by default (bond-agg's own default,
# lightning.go:711-715) unless an operator fact says otherwise. Design
# (p5-execution-handover.md:107): standing lightning's "enablement [is] set by
# E1" -- E1 is a ONE-TIME hardware measurement (edge vs mid), not a per-
# reconcile probe, so an operator fact is the correct input here -- same
# pattern as $BOND_DIR/metered and $BOND_DIR/agg_w: a human records a MEASURED
# verdict, this generator never guesses one. Absent file, or any content other
# than exactly "1", is OFF -- the same fail-safe default the daemon applies.
_lightning_enabled() {
    _lv=$(head -1 "$BOND_DIR/lightning" 2>/dev/null)
    [ "$_lv" = "1" ] && { echo 1; return 0; }
    echo 0
}
mode_of()      { cat "$BOND_DIR/mode" 2>/dev/null || echo lightning; }
# mode_wans: the sources this MODE enrolls -- eco = the primary only, every other
# mode = ALL live sources, however many. N-generic by construction: no branch on
# the count, no truncation. Ordered via ordered_wans so applied_wans and AGG_PATHS
# share ONE ordering rule (eco is exactly its head, == primary_wan).
# BOTH aggregate modes fall in the `*` arm on purpose. `speed` means "use the
# fewest/fastest sources the offered load needs" (ADR-003), and that selection is
# the DATAPATH's, made per frame at ms timescale from live capacity -- not the
# reconciler's, which reconverges at ~10s and cannot see offered load. So `speed`
# ENROLLS every live source and NOMINATES fewer; the reconciler must not prune the
# set, or the daemon could never promote a source it was never given.
# == bond_model.py mode_sources().
mode_wans() {
    W=$(ordered_wans); [ -n "$W" ] || return 1
    case "$(mode_of)" in
        eco)  R=$(printf '%s\n' "$W" | head -1) ;;
        *)    R="$W" ;;
    esac
    [ -n "$R" ] || return 1; echo "$R"
}

# feeder liveness via ubus service list (NOT pgrep — D5). Falls back to pgrep
# only if ubus is unavailable, so the probe still works off-box in the harness.
svc_running() {   # $1 = service name (p5-datapath -- THE feeder, U141)
    if command -v ubus >/dev/null 2>&1; then
        ubus call service list 2>/dev/null | grep -q "\"$1\"" && return 0
        # ubus present but service not listed: treat pgrep as the tiebreak
    fi
    pgrep -f "/usr/sbin/$1" >/dev/null 2>&1
}
svc_enabled() { "$1" enabled 2>/dev/null; }   # $1 = init.d path

# AGG_SCHED_TABLE -- the ONE place a MODE is mapped to an AGGREGATE SCHEDULER.
# ADR-003 splits the aggregate mode in two: `max` (stripe every usable source)
# and `speed` (deliver the offered load over the fewest/fastest sources). At
# THIS layer the two are the SAME lifecycle: same feeder (bond-agg), same
# listener (:$AGG_PORT), same arity guard, same enrolled source set. They differ
# by exactly one emitted fact -- AGG_SCHED -- which the datapath reads. So the
# reconciler carries ONE `agg` intent and ONE `engaged_agg` target, and a mode is
# a COMPOSITION (mode -> sched) rather than a branch.
#
# The table is DATA, one `<mode>:<scheduler>` word per aggregate mode, because
# the "a third scheduler is ONE row" claim has to be EXECUTABLE, not asserted.
# It was measured false once: with the table written as a `case` and the mode
# list ALSO written out in bondctl, adding `turbo` here left `bondctl mode
# turbo` refused by the parser. Everything downstream now DERIVES from this
# word list -- bondctl's accepted modes AND its usage string (`_sched_modes`),
# bond-ecod's stand-down test (`_sched`), and bond_model.py's AGG_SCHED, which
# PARSES this line rather than restating it. Layer-2 AGG-L12 adds a row to a
# copy of this tree and asserts the diff is one line in one file and that
# `bondctl mode <new>` then engages.
AGG_SCHED_TABLE="max:max speed:speed"

# The one caller that passes $1 is the bin's `_sched` dispatch, which shellcheck
# cannot see from inside this library (U124).
# shellcheck disable=SC2120
# THIS FUNCTION DOES NOT PIN IFS, and that is deliberate. It word-splits
# AGG_SCHED_TABLE on WHITESPACE, so it is correct only under the caller's
# default IFS. Exactly ONE place in the shipped tree ever calls it with a
# non-default IFS: the DAG interpreter's guard and action loops (xctl-dag.sh
# converge), which split a row's leaf list on ','; both loops restore IFS around
# the call. THAT SENTENCE IS A BAR, NOT A PROMISE: ecosim EL-5 enumerates every
# persistent non-default IFS assignment under deploy/p5 and pins the per-file
# counts (xctl-dag.sh=5, xctl-probe.sh=1), so a future file that sets IFS cannot
# ship green and silently re-open this defect. Before EL-5 this was an unpinned
# tree-wide guarantee -- true by grep on the day it was written and by nothing
# after. That interpreter restore is the SINGLE fix site for this defect, and
# keeping it single is what makes it falsifiable -- revert xctl-dag.sh's
# guard-loop restore and FIVE ecosim bars go red (measured, U141 fix round:
# `EL-1 N=1 speed: refused (aggregation needs >1 source), prior mode kept`,
# `NG4 N=1 speed refused, mode kept`, `NG4 N=1 and it runs the eco scheduler`,
# `S7 speed-1wan: refused, mode kept`, `S7 speed-1wan: the refusal changed
# nothing`), because `is_agg` then reads every aggregate mode as non-aggregate
# INSIDE A GUARD and the arity floor drops to 1. A second, belt-and-braces pin
# lived HERE and was REMOVED for that reason: with two independent mitigations
# of one defect, reverting either alone left the suite green at 478/0, so NO bar
# pinned either one and neither was verifiable.
agg_sched_of() {   # $1 = mode (default: the stored mode). Prints the scheduler
    _asm="${1:-$(mode_of)}"          # and exits 0; exits 3 when the mode is not
    for _ase in $AGG_SCHED_TABLE; do # an aggregate mode. 3, not 1, so a caller
        case "$_ase" in              # can tell "the table ANSWERED no" from "I
            "$_asm":*) echo "${_ase#*:}"; return 0 ;;   # could not ASK" (an
        esac                         # older bond-xctl exits 1 on the unknown
    done                             # verb) -- see bond-ecod.
    return 3
}
# agg_modes: the aggregate mode NAMES from the same table, `|`-separated, for
# callers that must render or validate the mode set without copying it.
agg_modes() {
    _amo=""                          # same whitespace/IFS contract as
    for _ase in $AGG_SCHED_TABLE; do # agg_sched_of above, same single fix site
        _amo="${_amo}${_amo:+|}${_ase%%:*}"
    done
    echo "$_amo"
}
# is_agg: "the stored mode is an aggregate mode" -- membership in the table
# above, never a comparison against a privileged mode name.
#
# THE ARGUMENT IS PASSED EXPLICITLY FOR READABILITY ONLY -- it changes nothing,
# and the earlier claim in this comment that it was a FIX was WRONG. That claim
# rested on "POSIX sh does not reset the positional parameters on a no-arg call,
# so the callee sees the CALLER's $1". THAT PREMISE IS FALSE, and it is false in
# all three shells this code runs under. Measured (U141 fix round), script
# `i(){ echo "[$1] $#"; }; m(){ i; }; m alpha beta` -> `[] 0` under dash, bash
# and busybox ash alike: a no-arg call gets an EMPTY parameter list. Since
# `agg_sched_of` already defaults to `${1:-$(mode_of)}`, the bare call and this
# explicit one are equivalent; the explicit form is kept only because it names
# the input at the call site. Nothing derived from the false premise stands
# either: `is_agg` did NOT answer FALSE on an aggregating box for that reason,
# and converged()'s aggregate arm did not fail for it. The one measured symptom
# -- `bondctl mode speed` ACCEPTED at N=1 in the ecosim harness -- had ONE
# cause, the guard-loop IFS defect fixed in xctl-dag.sh converge.
is_agg()   { agg_sched_of "$(mode_of)" >/dev/null 2>&1; }
# agg_sched_live: the AGG_SCHED the RUNNING feeder was started with, read from
# the live agg_env. Prints nothing when there is no agg_env. Compared against
# `agg_sched_of || mode_of` it answers "is the feeder already enrolled under the
# STORED mode?" -- the discriminator the churn-sustainment arm in xctl-dag.sh
# reconcile() needs to tell sustainment loss from an entry refusal.
# FIRST LINE ONLY, for the same reason agg_weights reads one line: agg_env is
# sourced by the procd unit and a multi-line value must never widen this answer.
agg_sched_live() { sed -n 's/^AGG_SCHED=//p' "$BOND_DIR/agg_env" 2>/dev/null | head -1; }
susp_state() {
    if [ -f "$RUN_DIR/suspended-degraded" ]; then echo suspended_degraded
    elif [ -f "$RUN_DIR/suspended" ];        then echo suspended
    else echo none; fi
}
# NODE = {off, engaged, suspended, suspended_degraded}. rc = THE feeder's rc.d
# enable flag (persistent engagement); susp overrides. Every mode is `engaged`:
# mode is a SIDE VALUE on the node, never a node.
#
# U141 MOVED THE DISCRIMINATOR, and this is the state-model change EG-2 recorded
# as owed. It used to be `svc_enabled "$SVC"` (engarde's rc.d flag) OR an
# aggregate mode with bond-agg enabled -- so a box whose old stack E7 had
# removed could not be `engaged` at all, and `bondctl mode max` on an `off` box
# reached an unreachable `from=off` member. There is now ONE feeder, so there is
# one flag, and it is P5's own ($AGG_SVC = /etc/init.d/p5-datapath).
node() {
    S=$(susp_state)
    [ "$S" = suspended ]          && { echo suspended;          return; }
    [ "$S" = suspended_degraded ] && { echo suspended_degraded; return; }
    if svc_enabled "$AGG_SVC"; then
        echo engaged
    else
        echo off
    fi
}
# DESIRED lifecycle target = pure fn of the stored facts (rc = the feeder's rc.d
# enable flag). NOT susp (an outcome). This is the reconciler's core: the caller
# writes facts, reconcile() derives the ONE edge from (observed node -> desired)
# -- no caller ever picks an edge (MF-1/MF-2 gone).
# TWO targets, not three: U141 folded the `agg` row into `engage`, so an
# aggregate mode is no longer a separate lifecycle target -- it is `engaged`
# carrying a mode whose AGG_SCHED and enrolled source set differ. == bond_model.py
# desired().
desired() {
    svc_enabled "$AGG_SVC" || { echo off; return; }
    echo engaged
}
