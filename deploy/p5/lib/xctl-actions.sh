#!/bin/sh
# xctl-actions.sh -- sourced by bond-xctl (U124 split). Bodies byte-identical to the
# single-file reconciler; see docs/knowledge/design for the WHY of each function.
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
# build_agg_env: emit the DESIRED agg_env for the live facts to $1. A PURE
# generator shared by act_env_gen (write-idempotency) and converged() (cmp a fresh
# build against the live agg_env) -- the short-circuit compares apples to apples.
# agg_weights: the AGG_W vector for $1 paths, POSITIONALLY aligned with AGG_PATHS.
# Prints the vector on stdout; any complaint goes to stderr (build_agg_env captures
# this, so a warning must never land inside agg_env).
#
# NOT DERIVED, and deliberately NOT INVENTED. The shipped value was `20000,15000`:
# two numbers with no measurement behind them, AND 2-shaped -- so on the box's own
# 4-WAN hardware paths 1 and 2 were PRIVILEGED by constants nobody measured while
# paths 3..N silently fell through to bond-agg's parseW default.
#   - $BOND_DIR/agg_w (operator/measured) is USED, but only when it carries exactly
#     N positive integers. A stale 2-entry file on a 4-source box would bind weights
#     to the WRONG paths -- silently, positionally. Refusing that is this unit.
#   - Otherwise: N copies of AGG_W_NEUTRAL, bond-agg's own per-path prior. Equal
#     weights == NO prior, the honest statement when nothing has been measured.
#     Emitting an EMPTY AGG_W would NOT achieve this IN THE MODE THIS FILE STARTS.
#     bond-agg has two weight-reading entry points and one that reads none:
#       AGG_MODE=client|server -- the retained EIF PUSH reference. runClient and
#         runServer both resolve parseW(env("AGG_W", "20000,15000"), N), so an
#         unset or empty AGG_W re-applies the 2-shaped 20000,15000 and paths 0/1
#         are privileged. Neither shipped stanza starts this mode any more (U111);
#         it is reachable only by hand-editing agg_env's AGG_MODE, and the
#         explicit N-copy vector stays load-bearing for that path.
#       AGG_MODE=pull-client -- the E2a PULL datapath (U7). This file STARTS this
#         mode (U111); it reads no per-path weights at all: AGG_W unset, empty and
#         set are the same state, and an AGG_W that is set is logged as IGNORED
#         (pullrun.go, pullNoPrior; bars in pullaggw_test.go). ROADMAP U36.
#     Cited by symbol, not line number: see the parseW line-number history at the
#     head of this file. Four values in five days.
# OPEN QUESTION (reported, not guessed): what a MEASURED per-source weight should
# be. bond-agg's CapEst converges per path on-path; whether an a-priori weight
# speeds that convergence or biases it is untested, and the box exposes no
# measurement this generator could read at config-build time.
agg_weights() {   # $1 = N
    _wn=$1
    # FIRST LINE ONLY: agg_env is sourced by the procd unit, so a multi-line
    # agg_w must never be able to inject extra lines into it.
    _wf=$(head -1 "$BOND_DIR/agg_w" 2>/dev/null)
    if [ -n "$_wf" ]; then
        _wt=$(printf '%s' "$_wf" | tr ',' '\n' | grep -c .)
        _wg=$(printf '%s' "$_wf" | tr ',' '\n' | grep -c '^[1-9][0-9]*$')
        if [ "$_wt" = "$_wn" ] && [ "$_wg" = "$_wn" ]; then
            printf '%s\n' "$_wf"; return 0
        fi
        echo "$TAG: WARN: $BOND_DIR/agg_w has $_wt entr(ies) for $_wn paths (need $_wn positive integers) - using the neutral prior" >&2
        logger -t "$TAG" "WARN: agg_w arity $_wt != paths $_wn - neutral prior" 2>/dev/null
    fi
    _wo=""; _wi=1
    while [ "$_wi" -le "$_wn" ]; do _wo="${_wo}${AGG_W_NEUTRAL},"; _wi=$((_wi+1)); done
    printf '%s\n' "${_wo%,}"
}
build_agg_env() {   # $1 = output path
    # N-GENERIC (Layer-1 NG-2). Enroll the sources THIS MODE selects, in
    # mode_wans order (primary first, then by metric) -- the SAME order Layer-1's
    # `sources` tuple carries, since the artifact and the model are checked
    # against one bond.dag.
    #
    # WAS `ordered_wans` (U6), i.e. ALWAYS every live source. That was correct
    # while bond-agg fed only the aggregate modes; U141 makes it the feeder for
    # ALL of them, and `eco` is DEFINED as N=1 over the primary (ADR-003). So the
    # enrolled set is `mode_wans` -- eco -> the head of ordered_wans, every other
    # mode -> all live sources. This is the SAME function `applied_wans` was built
    # from before, so the two files never disagreed about eco and still do not.
    #
    # BEFORE THAT it was `P=$(primary_wan); O=$(live_wans | grep -v "^$P$" |
    # head -1)` and `AGG_PATHS=$P,$O` -- exactly two paths. A third live source
    # was discarded SILENTLY: no error, no log, no reduction in the guard's count.
    # The client box already declares FOUR WAN interfaces (docs/INTENT.md:193), so
    # that was lost capacity on current hardware, not a future case.
    #
    # ARITY: this builder refuses only the EMPTY set (N=0 -- nothing to feed).
    # The per-mode arity floor is the ENTRY guard `sources_for_mode`, not a term
    # here, and that split is deliberate: a box already running an aggregate mode
    # whose live source count has FALLEN below the floor must still be able to
    # rebuild its env over the sources that remain (the U19 churn-sustainment
    # `switch`), and a builder that failed on arity would take that recovery away.
    _WL=$(mode_wans) || fail "no live WAN underlays for mode $(mode_of)"
    _WN=$(printf '%s\n' "$_WL" | grep -c .)
    [ "$_WN" -ge 1 ] || fail "no live WAN underlays for mode $(mode_of)"
    _WP=""; for _w in $_WL; do _WP="${_WP}${_w},"; done; _WP="${_WP%,}"
    _WV=$(agg_weights "$_WN")
    # AGG_SPOTTY / AGG_LIGHTNING -- U15b's standing spotty-class duplicator
    # (p4-bondagg/daemon/lightning.go). Emitted UNCONDITIONALLY, same as
    # AGG_PATHS/AGG_W: an empty AGG_SPOTTY (nothing metered) or AGG_LIGHTNING=0
    # (no operator fact) is the correct fail-safe and the daemon logs it either
    # way (lightning.go:757) -- this is not a guess, it is the honest DEFAULT.
    # NAME COLLISION, stated: this env var is the SPOTTY-CLASS duplicator, NOT
    # the `lightning` MODE below it in AGG_SCHED. ADR-003 §2 renames it
    # AGG_SPOTTY_DUP; that rename spans the daemon (lightning.go -> spottydup.go)
    # and U133's operator fact, and is U133's to land -- see the U141 row.
    _SP=""; for _s in $(ordered_spotty); do _SP="${_SP}${_s},"; done; _SP="${_SP%,}"
    {
        echo "AGG_LISTEN=$LOCAL_AGG"
        echo "AGG_SERVER=$(live_server_host):$AGG_PORT"
        echo "AGG_PATHS=$_WP"
        echo "AGG_W=$_WV"
        # AGG_SCHED is the WHOLE of the between-modes difference at this layer,
        # together with AGG_PATHS. It rides agg_env, so ANY mode flip is a byte
        # change in agg_env -> act_env_gen drops the `agg_env_changed` crumb ->
        # act_agg_restart bounces the datapath EXACTLY once. No new edge, no new
        # node, no new crumb.
        # AGGREGATE modes resolve through AGG_SCHED_TABLE (max->max, speed->speed);
        # `agg_sched_of` exits 3 for a NON-aggregate mode, and the fallback is the
        # mode's own name, because `eco` and `lightning` ARE scheduler names in the
        # daemon (schedPolicies gained both in U138). One table for the aggregate
        # set -- unchanged by this unit -- and identity for the rest.
        # `agg_sched_of "$(mode_of)"`, never a bare `agg_sched_of`: this
        # function is called with $1 = the output path, and POSIX sh would let
        # the callee see it (see is_agg in xctl-probe.sh for the measurement).
        echo "AGG_SCHED=$(agg_sched_of "$(mode_of)" || mode_of)"
        echo "AGG_SPOTTY=$_SP"
        echo "AGG_LIGHTNING=$(_lightning_enabled)"
    } > "$1"
}
act_env_gen() {
    # EFFECT-IDEMPOTENT: build agg_env into a temp and swap ONLY on a byte change
    # (WRITE-idempotency, no file churn). On a REAL change drop the
    # `agg_env_changed` crumb so act_agg_restart bounces the datapath EXACTLY when
    # the env moved. A DELTA that walks the engage edge without a real env move
    # (e.g. an ep-drift heal) leaves no crumb -> act_agg_restart is a no-op and
    # only ep_agg re-pins; converged() no-ops the steady-state tick before any
    # edge is walked.
    mkrun
    _TMP="$BOND_DIR/.agg_env.new"
    build_agg_env "$_TMP"
    if cmp -s "$_TMP" "$BOND_DIR/agg_env" 2>/dev/null; then
        rm -f "$_TMP" 2>/dev/null
    else
        mv "$_TMP" "$BOND_DIR/agg_env"; touch "$RUN_DIR/agg_env_changed"
    fi
    # applied_wans: the operator-facing record of WHICH sources are enrolled.
    # It used to be genconf's (engarde's) file; with one feeder it is written
    # here, from the SAME mode_wans() build_agg_env just enrolled, so the two can
    # never disagree.
    # U66/SC2046+SC2005: both are DELIBERATE. mode_wans emits ONE SOURCE PER LINE;
    # applied_wans stores the single-space form (run.sh NG5 asserts "eth1 usb0 eth0").
    # The unquoted $( ) does the field split and `echo` does the re-join, so this is a
    # newline->space normaliser, not a useless echo: quoting it, or taking SC2005's
    # advice and dropping the echo, both keep the newlines and change the on-disk file.
    # shellcheck disable=SC2046,SC2005
    _AW="$(echo $(mode_wans))"
    if [ "$_AW" != "$(cat "$BOND_DIR/applied_wans" 2>/dev/null)" ]; then
        printf '%s' "$_AW" > "$BOND_DIR/applied_wans"
    fi
}
act_env_gen_if_enabled() {
    # `switch` leaf. The switch row applies from `off` too (a mode write on a
    # disabled box), and a disabled box must not have its feeder config rewritten
    # or its feeder started. Same shape the deleted `genconf_if_enabled` had, now
    # gated on the ONE feeder's rc.d flag.
    svc_enabled "$AGG_SVC" && act_env_gen
}
act_agg_install() {
    # On-demand FALLBACK only: the shipped canonical copy is deploy/p5/init.d/bond-agg
    # (installed at package time). This stanza MUST stay byte-for-byte equivalent to it
    # so a fallback-generated unit never drifts from the canonical (LOW: was missing
    # STOP=11 and used a bare `respawn` instead of the canonical `respawn 3600 5 5`).
    [ -x "$AGG_SVC" ] && return 0
    cat > "$AGG_SVC" <<'SVCEOF'
#!/bin/sh /etc/rc.common
# procd service: bond-agg (THE feeder). START order 94.
# shellcheck disable=SC2034
START=94
# shellcheck disable=SC2034
STOP=11
# shellcheck disable=SC2034
USE_PROCD=1
start_service() {
    [ -r /etc/p5/agg_env ] || return 1
    # U66/SC1091: agg_env is GENERATED at runtime by `bond-xctl act_env_gen`; it is
    # not in the repo, so there is no file for `shellcheck -x` to follow. Left
    # unfollowed on purpose -- pointing it at /dev/null would instead make every
    # AGG_* below read as unassigned.
    # shellcheck disable=SC1091
    . /etc/p5/agg_env
    procd_open_instance
    procd_set_param command /usr/sbin/p5-datapath
    procd_set_param env AGG_MODE=pull-client AGG_LISTEN="$AGG_LISTEN" AGG_SERVER="$AGG_SERVER" AGG_PATHS="$AGG_PATHS" AGG_W="$AGG_W" AGG_SCHED="$AGG_SCHED" AGG_SPOTTY="$AGG_SPOTTY" AGG_LIGHTNING="$AGG_LIGHTNING"
    procd_set_param respawn 3600 5 5
    procd_set_param stderr 1
    procd_close_instance
}
SVCEOF
    chmod 755 "$AGG_SVC"
}
# act_agg_enable / act_agg_disable are ALSO the rc (engagement) fact now: node()
# and desired() read $AGG_SVC's rc.d enable flag, so enabling the feeder IS
# "the box is engaged". Before U141 that flag was engarde's -- a P2 artifact
# deciding a P5 lifecycle (EG-2).
act_agg_enable() { "$AGG_SVC" enable 2>/dev/null; }
act_agg_disable(){ "$AGG_SVC" disable 2>/dev/null; }
act_agg_restart(){
    # EFFECT-IDEMPOTENT: ensure-running, not restart-always. Bounce the datapath
    # ONLY when act_env_gen actually changed agg_env (agg_env_changed crumb) OR
    # bond-agg is absent. An ep-drift heal (env unchanged, feeder up) is a NO-OP
    # here -- no restart, no datapath silence -- while converged() no-ops the
    # steady-state tick before any edge is walked.
    if [ -f "$RUN_DIR/agg_env_changed" ] || ! svc_running p5-datapath; then
        "$AGG_SVC" restart || fail "bond-agg start failed"
    fi
    rm -f "$RUN_DIR/agg_env_changed" 2>/dev/null
}
act_agg_restart_if_enabled() {
    # `switch` leaf (live mode change): same EFFECT-IDEMPOTENT guard as
    # act_agg_restart, and the same disabled-box gate as act_env_gen_if_enabled.
    # A no-op `switch` (mode unchanged) does not bounce a healthy datapath.
    svc_enabled "$AGG_SVC" || { rm -f "$RUN_DIR/agg_env_changed" 2>/dev/null; return 0; }
    if [ -f "$RUN_DIR/agg_env_changed" ] || ! svc_running p5-datapath; then
        "$AGG_SVC" restart || log "WARN: restart failed"
    fi
    rm -f "$RUN_DIR/agg_env_changed" 2>/dev/null
}
act_agg_stop()   { "$AGG_SVC" stop 2>/dev/null; }
act_mtu_1408()   { "$IP" link set "$WG_DEV" mtu 1408 2>/dev/null; }
act_mtu_1420()   { "$IP" link set "$WG_DEV" mtu 1420 2>/dev/null; }
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
        "$AGG_SVC" stop 2>/dev/null
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
