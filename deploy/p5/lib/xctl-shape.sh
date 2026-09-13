#!/bin/sh
# xctl-shape.sh -- sourced by bond-xctl (U124 split). Bodies byte-identical to the
# single-file reconciler; see docs/knowledge/design for the WHY of each function.

# ================= E4 SHAPING (probe + leaves) ==============================
# Spec: docs/knowledge/design/e4-shaping-in-dag.md. ADR-001 decision 1 SUPERSEDED.
#
# INV8 IS THE CONSTRAINT AND IT IS ENFORCED STRUCTURALLY, not by comment:
# shaping contributes NO guard and NO verify to any bond.dag row, and
# act_shape_apply ALWAYS returns 0. A failed guard refuses the whole edge
# (converge(): `if ! run_guard "$g"; then ... return 1`) and a failed verify
# walks `onfail`, which for `engage` is `suspend`. Either would make tunnel
# availability depend on autorate. So a broken or absent shaper is LOGGED and
# corrected by the next reconcile -- the self-heal path, never the escalation
# path.
#
# NO ARBITRARY CONSTANT ENTERS HERE. `cake` is attached with NO bandwidth
# argument: the rate is owned by the autorate controller, which derives it from
# measurement (OBJ-F). A number picked in this file would be exactly the
# invented constant the guardrail forbids. cake's overhead/framing parameters
# for a WireGuard tunnel are likewise NOT settled here -- see the OPEN QUESTION
# at the end of this block.

# shape_if: the tunnel iface shaping is applied to. It is NOT a fact of this
# unit -- it comes from M8/E6 discovery (`$BOND_DIR/wg_if`). No `wgclient1`
# literal appears anywhere in the shaping path; the fallback is $WG_DEV, the
# same already-overridable variable the rest of this file resolves the tunnel
# through, so this adds no new hardcode and E6 deletes the fallback with the
# rest of them.
shape_if() {
    _I=$(cat "$BOND_DIR/wg_if" 2>/dev/null)
    [ -n "$_I" ] || _I="$WG_DEV"
    echo "$_I"
}
# shape_want: the DESIRED shaping fact, written by bondctl/the portal and never
# by the executor (the fact-writer contract). Default `on`: `direct` is DEFINED
# as bond-off PLUS cake/autorate, so shaping-on is the product's normal state
# and an absent fact must not silently mean "unshaped".
shape_want() {
    case "$(cat "$BOND_DIR/shape" 2>/dev/null)" in
        off) echo off ;;
        *)   echo on ;;
    esac
}
# shape_now: the OBSERVED shaping state -> "off" | "<ifname>". Reality-faithful,
# one owner, no memory: a cake qdisc present on the DISCOVERED iface AND the
# autorate controller running. Either half missing reads `off`, because half a
# shaper is not shaping.
# UNVERIFIED ON THE BOX (repo-is-not-the-world): that `$SHAPE_SVC running` is a
# supported verb for the shipped p5-shape init script is read off P1's
# usage of enable/restart only; `running` is procd's standard verb but has not
# been executed on either box. U40 reads the boxes.
shape_now() {
    _I=$(shape_if)
    "$TC" qdisc show dev "$_I" 2>/dev/null | grep -q "qdisc cake" || { echo off; return 0; }
    "$SHAPE_SVC" running >/dev/null 2>&1 || { echo off; return 0; }
    echo "$_I"
}
# shape_native_sqm: true when GL's OWN SQM has an ENABLED queue on the
# DISCOVERED tunnel iface (U22a, E4 non-interference). Two owners attaching a
# root qdisc to one device is a tug-of-war neither wins, and P5 must not take
# the device off the operator silently. Reads /etc/config/sqm directly rather
# than via uci: a check that reports "no conflict" because its own tool is
# absent is worse than no check. The trailing sentinel flushes the last section
# (uci config files have no section terminator).
shape_native_sqm() {
    [ -r "$SQM_CONF" ] || return 1
    _T=$(shape_if)
    { tr -d "\"'" < "$SQM_CONF" 2>/dev/null; echo "config __sentinel"; } | {
        _en=0; _sif=""
        while read -r _k _a _b; do
            case "$_k" in
                config)
                    [ "$_en" = 1 ] && [ "$_sif" = "$_T" ] && exit 0
                    _en=0; _sif="" ;;
                option)
                    case "$_a" in
                        enabled)   _en="${_b:-0}" ;;
                        interface) _sif="${_b:-}" ;;
                    esac ;;
            esac
        done
        exit 1
    }
}
# shape_matches: desired == observed. The R3 clause -- converged() calls it, so
# a box whose shaping has drifted is NOT converged and the next reconcile heals
# it. Without this the fold is inert: the reconciler would no-op while shaping
# was gone (a fact-space no-op is not an effect-space no-op).
shape_matches() {
    _W=$(shape_want); _N=$(shape_now)
    case "$_W" in
        off) [ "$_N" = off ] ;;
        *)   [ "$_N" = "$(shape_if)" ] ;;
    esac
}
# shape_svc_owned: is the controller at $SHAPE_SVC one P5 WROTE? (U210)
#
# THE GAP THIS CLOSES, and it is not hypothetical. `shape_apply` rides the
# DISENGAGE edge as well as engage/switch (bond.dag), and `direct` is DEFINED as
# bond-off PLUS shaping -- so ANY reconcile on a box whose shaping has not
# converged runs this leaf, including at S2, before P5 is ever engaged. Until
# U210 the leaf ran `$SHAPE_SVC enable; restart` with SHAPE_SVC defaulting to
# /etc/init.d/cake-autorate, which on the client is P1's LIVE controller: P5
# would have re-enabled a service the operator had just switched off, from
# inside the reconciler, invisibly to the engage guard. The rename moved the
# default out of P1's name; this predicate makes the leaves refuse to drive a
# controller that is absent or unmarked whatever the path is set to, which is
# the half a rename alone cannot give.
#
# `-s` before the grep, and the marker is a fixed string, because an EMPTY
# marker would make `grep -q ""` true for every file -- an ownership check that
# fails open is worse than none.
shape_svc_owned() {
    [ -n "${P5_MARK:-}" ] || return 1
    [ -f "$SHAPE_SVC" ] && grep -q "$P5_MARK" "$SHAPE_SVC" 2>/dev/null
}
# act_shape_apply: a PURE CONVERGENCE action -- "make shaping match", not "turn
# shaping on". That is what makes it safe to place on EVERY edge. Idempotent:
# already-matching is a no-op, so a healthy edge does not bounce the shaper.
# ALWAYS returns 0 (R2).
act_shape_apply() {
    _W=$(shape_want); _I=$(shape_if); _N=$(shape_now)
    if [ "$_W" = off ]; then
        [ "$_N" = off ] && return 0
        act_shape_clear
        return 0
    fi
    [ "$_N" = "$_I" ] && return 0
    # CONVERGE-GUARD (U22a): GL's own SQM owns this device. Do NOT attach --
    # that is a qdisc tug-of-war, and taking the device off the operator
    # silently is exactly what E4 forbids. Report the state, change nothing,
    # return 0 (INV8: shaping never escalates). The box stays un-converged and
    # retries, which is the measured, contained R3 cost (SH-5 / SH-6).
    if shape_native_sqm; then
        log "WARN: shaping: GL native SQM has an ENABLED queue on $_I -- NOT attaching (two owners on one device). Turn FLOW CONTROL -> SQM off for $_I, or set 'bondctl shape off'."
        return 0
    fi
    # OWNERSHIP (U210), tested BEFORE any service verb and AFTER the desired-off
    # branch above, so `off` still tears down a controller P5 owns. Not owned ->
    # log and change NOTHING: no qdisc, no enable, no restart. The box stays
    # un-converged and retries, which is the same contained R3 cost as the
    # native-SQM guard (INV8: shaping never escalates).
    if ! shape_svc_owned; then
        log "WARN: shaping: $SHAPE_SVC is absent or carries no P5 marker -- foreign or missing controller, NOT touching it (INV8)"
        return 0
    fi
    # (re)apply cake, then (re)start the controller. `replace` is idempotent at
    # the qdisc level; we are here only because the observed state did not match.
    # NO rate argument -- see the constants note above.
    if "$TC" qdisc replace dev "$_I" root cake >/dev/null 2>&1; then :; else
        log "WARN: shaping: cake attach failed on $_I (continuing; INV8: never escalated)"
    fi
    "$SHAPE_SVC" enable  >/dev/null 2>&1
    if "$SHAPE_SVC" restart >/dev/null 2>&1; then :; else
        log "WARN: shaping: $SHAPE_SVC restart failed (continuing; INV8: never escalated)"
    fi
    if [ "$(shape_now)" = "$_I" ]; then
        log "shaping converged ON ($_I)"
    else
        log "WARN: shaping NOT converged on $_I (desired=on) -- retried next reconcile"
    fi
    return 0
}
# act_shape_clear: idempotent teardown. NO bond.dag row references it today --
# act_shape_apply calls it for the desired-off case. It is registered as a leaf
# because that is what the spec names it and because E7 removal wants exactly
# this teardown; it is unreferenced BY THE TABLE and that is stated, not hidden.
act_shape_clear() {
    _I=$(shape_if)
    # OWNERSHIP (U210), the SECOND leaf and the one it is easy to forget: a
    # teardown that disables and stops a controller P5 did not write is the same
    # defect as an apply that enables one, pointed the other way -- on the client
    # it would stop P1's live shaper from inside P5. The `tc qdisc del` is
    # skipped too, because the qdisc on that device may be the foreign
    # controller's; P5 removes only what P5 attached.
    if ! shape_svc_owned; then
        log "WARN: shaping: $SHAPE_SVC is absent or carries no P5 marker -- foreign or missing controller, NOT touching it (INV8)"
        return 0
    fi
    "$SHAPE_SVC" disable >/dev/null 2>&1
    "$SHAPE_SVC" stop    >/dev/null 2>&1
    "$TC" qdisc del dev "$_I" root >/dev/null 2>&1
    log "shaping converged OFF ($_I)"
    return 0
}
# OPEN QUESTION, recorded rather than guessed (no-arbitrary-constants):
# cake's overhead/framing accounting for a WireGuard tunnel iface is not
# specified anywhere in the record, and this unit does not invent it. What IS
# settled and enforced here is the ORDERING: shape_apply runs after mtu_1408/
# mtu_1420 on every edge that moves the MTU, so whatever accounting E4's
# install half chooses is computed against the settled frame size (SH-4).
