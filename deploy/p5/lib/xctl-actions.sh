#!/bin/sh
# xctl-actions.sh -- sourced by bond-xctl (U124 split); see docs/knowledge/design
# for the WHY of each function.
#
# U18: the bodies are NO LONGER byte-identical to the single-file reconciler, and
# this header used to claim they were. The bonded feeder's lifecycle left this
# library for `bond-aggctl` (M3); what stays is the endpoint/suspend leaf set plus
# a one-line delegation for every feeder leaf. The M3 block below states what moved.
#
# U141: the engarde half of this library is DELETED, not disabled --
# build_engarde_conf, genconf, act_genconf, act_eng_{enable,restart,stop,disable},
# act_genconf_if_enabled, act_eng_restart_if_enabled, act_restore_feeder and
# act_aggdown_if_agg are gone. Every bonded mode is fed by bond-agg on :59402
# (ADR-003 status update, U119), so there is ONE feeder, one config builder
# (build_agg_env) and one set of feeder leaves. INV1 (single feeder) now holds by
# CONSTRUCTION -- there is no second feeder for an edge to have to tear down --
# which is why the `aggdown_if_agg` head that used to lead engage/switch/disengage
# is not replaced by anything.

# ================= leaf ACTIONS (real side effects) =========================
apply_endpoint() {   # $1 target endpoint (RUNTIME only; GL uci untouched)
    _i=1
    while [ "$_i" -le 8 ]; do
        PUB=$(live_peer); [ -n "$PUB" ] && break; sleep 1; _i=$((_i+1))
    done
    [ -n "$PUB" ] || { log "WARN: no live peer after 8s"; return 1; }
    wg set "$WG_DEV" peer "$PUB" endpoint "$1" || { log "WARN: wg set failed"; return 1; }
}
act_ep_direct()  { apply_endpoint "$(live_direct)"; }
act_ep_agg()   { apply_endpoint "$LOCAL_AGG"; }
act_clear_susp() { rm -f "$RUN_DIR/suspended" "$RUN_DIR/suspended-degraded" 2>/dev/null; }

# ============ M3 (U18): the feeder's lifecycle is NOT in this library ========
# Everything from here to act_revert used to BE the aggregate feeder's lifecycle:
# the applied-record machinery, agg_weights + the AGG_W_NEUTRAL prior, the agg_env
# builder, the arity floor, the enable/restart/stop/disable policy and the MTU
# strand. It now lives in `bond-aggctl` (M3), a separate EXECUTABLE this file
# invokes through `aggctl` / `aggctl_srcs` (bond-xctl). U124's split moved those
# lines into a FILE; U18 moves them out of the PROCESS, which is the boundary
# module-architecture.md's M3 row asks for -- inside one process any lib can reach
# any probe, so the feeder's lifecycle could always read the reconciler's world.
#
# THE NAMES BELOW DO NOT CHANGE, and that is load-bearing rather than cosmetic:
# bond.dag names leaves, run_action (xctl-dag.sh) maps those names onto these
# functions, and converged() invokes a BUILDER BY NAME through _conf_matches. So
# each one stays a function under its own name and becomes a one-line delegation.
#
# WHAT THE CONTROLLER IS TOLD, and why each fact is passed rather than probed:
# the listen address, the server endpoint, the stored MODE (for the one error
# message that names it), the resolved SCHEDULER, the spotty set and the lightning
# flag -- plus the ORDERED SOURCE SET as trailing positional arguments. Every one
# of those is an OBSERVATION, and observations are the probe registry's job. A
# controller that re-probed would build against a different world than the one
# converged() compared, and NG7 (order stability, zero feeder bounce on a healthy
# tick) is exactly the property that would become a lie.
#
# FAILURE MAPPING, checked against converge() rather than assumed. In-process, a
# builder/restart `fail` exited 1 inside the per-action SUBSHELL converge() runs
# every leaf in (U116) and arrived at the action loop as an ordinary non-zero
# status; act_critical then decided whether the edge aborts. Across the process
# boundary the controller's `fail` exits 1, the wrapper returns 1, and converge()
# reads the SAME `_arc`. So no wrapper needs `|| exit 1` and none has one: the
# mapping is 1:1 and nothing newly aborts an edge.
#
# _conf_matches runs the builder in a subshell and keys only on success/failure,
# so a controller `fail` there still reads as "cannot build desired" -> NOT
# converged, exactly as the in-process builder did.

# _agg_spotty: the spotty set as the CSV agg_env carries. Joined here because the
# probe emits one per line and the interface is one field.
_agg_spotty() {
    _as_o=""; for _s in $(ordered_spotty); do _as_o="${_as_o}${_s},"; done
    printf '%s' "${_as_o%,}"
}
# _agg_env_call: the ONE place the agg_env fact set is spelled. Every builder verb
# goes through it, so the three call sites below cannot drift apart -- which is the
# same one-source-of-truth argument the arity floor gets, applied to the facts.
# EVERY FACT IS QUOTED, deliberately: an empty spotty set must arrive as an EMPTY
# ARGUMENT, not vanish and shift the lightning flag into its slot. Only the SOURCE
# list is word-split, and that split is pinned to newline in aggctl_srcs.
#   $LOCAL_AGG / live_server_host():$AGG_PORT reproduce the pre-extraction bytes,
#   including the degenerate ":$AGG_PORT" when the peer endpoint cannot be resolved.
#   `agg_sched_of "$(mode_of)" || mode_of`: AGGREGATE modes resolve through
#   AGG_SCHED_TABLE, and the fallback is the mode's own name because `eco` and
#   `lightning` ARE scheduler names in the daemon. That table stays HERE -- it is a
#   MODE question with one fix site (xctl-probe.sh), and the controller is handed
#   the answer rather than a second copy of the table.
#   `agg_sched_of "$(mode_of)"`, never a bare `agg_sched_of`: the explicit argument
#   names the input at the call site (see is_agg in xctl-probe.sh for the
#   measurement that settled what a bare call actually does).
_agg_env_call() {   # $1 = verb, $2.. = the verb's own leading args
    _ac_v=$1; shift
    aggctl_srcs mode_wans "$_ac_v" "$@" \
        "$LOCAL_AGG" "$(live_server_host):$AGG_PORT" "$(mode_of)" \
        "$(agg_sched_of "$(mode_of)" || mode_of)" "$(_agg_spotty)" "$(_lightning_enabled)"
}
# build_agg_env: DELEGATES to M3 (`bond-aggctl env-build`). Kept as a FUNCTION,
# under this name, because converged()/_conf_matches invokes builders BY NAME.
build_agg_env() { _agg_env_call env-build "$1"; }   # $1 = output path
# act_env_gen: DELEGATES to M3 (`env-apply`) -- the effect-idempotent swap of
# agg_env AND the applied_wans record, both built from the ONE mode_wans
# observation this call passes down, so the two can never disagree.
act_env_gen() { _agg_env_call env-apply; }
# act_env_gen_if_enabled: the `switch` leaf. The switch row applies from `off` too
# (a mode write on a disabled box), and a disabled box must not have its feeder
# config rewritten or its feeder started. The rc.d gate is the CONTROLLER's, because
# the flag it reads is the FEEDER's -- an M3 fact.
act_env_gen_if_enabled() { _agg_env_call env-apply-if-enabled; }
# The feeder's service lifecycle: every one of these is a one-line delegation.
# act_agg_enable / act_agg_disable are the MECHANISM, not the fact (U114): node()
# reads $AGG_SVC's rc.d flag and desired() reads $BOND_DIR/rc, so these two only
# make the box MATCH that intent. They are still required and are not replaceable
# by the file: rc.d is what starts the feeder at boot, so an engage that wrote the
# fact and skipped the enable would come up direct after every reboot.
act_agg_enable() { aggctl enable; }
act_agg_disable(){ aggctl disable; }
act_agg_restart(){ aggctl restart; }
act_agg_restart_if_enabled() { aggctl restart-if-enabled; }
act_agg_stop()   { aggctl stop; }
# The MTU strand moved WITH the feeder (P2's review names the MTU juggling as part
# of what must be extracted). The LEAF names are bond.dag's and do not change; the
# VALUES are the controller's, which is why these two no longer spell a number.
act_mtu_1408()   { aggctl mtu agg; }
act_mtu_1420()   { aggctl mtu normal; }
act_revert() {
    # I9 revert-then-suspend: try DIRECT, confirm readback != the bonded local
    # endpoint, THEN stop the feeder.
    REVOK=0; _i=1
    while [ "$_i" -le 8 ]; do
        if apply_endpoint "$(live_direct)"; then
            [ "$(ep_now)" != "$LOCAL_AGG" ] && { REVOK=1; break; }
        fi
        sleep 1; _i=$((_i+1))
    done
    mkrun
    if [ "$REVOK" = 1 ]; then
        touch "$RUN_DIR/suspended"; rm -f "$RUN_DIR/suspended-degraded"
        aggctl stop
        log "SUSPENDED: engagement unverified; reverted to DIRECT (confirmed). Retry on next wg up."
    else
        touch "$RUN_DIR/suspended-degraded"; rm -f "$RUN_DIR/suspended"
        log "SUSPENDED-DEGRADED: revert unconfirmed — keeping bond-agg RUNNING so the local endpoint stays valid."
    fi
    # U66/SC2015: this was `ping ... && log OK || log WARN`, which is NOT if-then-else.
    # `log()` ends in `logger`, so log()'s exit status is logger's -- non-zero if the
    # applet is missing or /dev/log cannot be opened. A SUCCESSFUL ping would then print
    # BOTH "direct path verified OK" and "WARN: direct path also failing", in the
    # suspend/revert path, which is exactly where the operator is reading the log to
    # decide whether the tunnel or the underlay is at fault. if/else makes the two
    # branches exclusive by construction.
    # ...and "$PING" not bare (U69): ping is a busybox applet, so under the
    # standalone shell a PATH shim never sees it.
    if "$PING" -c 2 -W 3 76.76.2.0 >/dev/null 2>&1; then
        log "direct path verified OK"
    else
        log "WARN: direct path also failing — check the tunnel itself"
    fi
}
