#!/bin/sh
# xctl-dag.sh -- sourced by bond-xctl (U124 split). Bodies byte-identical to the
# single-file reconciler; see docs/knowledge/design for the WHY of each function.

# ================= leaf GUARDS ==============================================
# guard_installed: P5's OWN precondition -- its fact directory exists. Nothing else.
#
# "P5's OWN" is load-bearing and was NOT true in this unit's first round. The
# predicate is unchanged text, but the directory is now made by mkfacts() (called
# from take_lock, so before any edge is walked) instead of being inherited from
# p2-engarde/bootstrap-bond.sh, which was the repo's only creator of it. Read
# mkfacts() for the measurement; without it, dropping the ENGARDE_BIN term below
# moved the dependency from P2's binary to P2's directory rather than removing it.
#
# U50a removed the `[ -x "$ENGARDE_BIN" ]` term. Mo's decision, recorded in
# docs/ROADMAP.md under "U50 DECIDED by Mo (2026-08-30)": P5 drops the engarde
# DEPENDENCY entirely, rather than bundling engarde, narrowing the guard to the
# one edge where it was plainly wrong, or having E7 stop removing engarde.
#
# What the term was doing, and why it had to go. bond.dag puts `installed` on
# FOUR edges -- engage, disengage, switch AND the aggregate row -- so with the
# term present P5's own DAG could not reach `engaged` or an aggregate mode
# without P2's binary. The aggregate row is the unambiguous case: it already
# carries its own `agg_installed` (the bond.dag `agg` row's `agg_installed` ->
# guard_agg_installed, the bond-agg binary), and no action on that row touches
# engarde, so gating it on engarde-client was a defect.
# The term is now gone from ALL FOUR edges, not narrowed to one -- that is what
# was decided, and narrowing was explicitly rejected.
#
# ROW NAME: U50a was written against the `speed` row and U17 renamed it to `agg`
# (one aggregate intent, AGG_SCHED picks max-vs-speed). Same row, same guards --
# the rename moved no edge. `dag_row` below still falls back to the `speed`
# spelling for a pre-U17 table on disk, so both names reach these guards.
#
# THIS DOES NOT REMOVE ENGARDE FROM THE BOX. The client still has
# /usr/sbin/engarde-client and the production tunnel still runs THROUGH it at
# 127.0.0.1:59401 -- measured, not assumed: docs/knowledge/inventory/
# 2026-08-30-client-flint2.txt -- binary present :145, running :213, listening
# on :59401 at line :31, WG peer endpoint = 127.0.0.1:59401 at line :189,
# rc-enabled S94engarde-client at line :125.
# What is removed is P5's dependency on it: the
# DAG no longer refuses an edge because the binary is absent. On today's client
# the binary is present, so this changes no edge outcome there.
#
# CLOSED BY U141 -- what U50a left open here is done. engage/switch/disengage no
# longer run ANY engarde action (genconf, eng_enable, eng_restart, eng_stop are
# deleted, and so is build_engarde_conf). Every bonded mode is fed by bond-agg on
# :59402, so `engaged` never reaches its verify with no feeder behind it, and the
# engaged/off DISCRIMINATOR is now bond-agg's own rc.d flag rather than engarde's
# (xctl-probe.sh node()/desired()). That was the second half EG-2 recorded as
# owed: `bondctl mode max` on an `off` box used to write the mode fact and
# converge to off, because "off" was defined by a P2 artifact. Layer-2 EG-5 is
# flipped to assert the CLOSED state, and EL-1..EL-4 assert the feeder itself.
guard_installed()     { [ -d "$BOND_DIR" ]; }
guard_manual()        { [ "${XCTL_AUTO_CTX:-0}" != 1 ]; }   # auto policy never picks an agg mode
guard_agg_installed() { [ -x "$AGG_BIN" ]; }
# min_sources_for_mode: the arity FLOOR of the stored mode. MIN_AGG_SOURCES for an
# aggregate mode (you cannot stripe one link); 1 otherwise (eco is DEFINED at N=1,
# and lightning on a box down to its last source is degenerate-but-running, which
# is the daemon's own rule -- U138 accepts lightning at N=1 and logs DEGENERATE).
# Membership in AGG_SCHED_TABLE, never a comparison against a mode name.
min_sources_for_mode() { if is_agg; then echo "$MIN_AGG_SOURCES"; else echo 1; fi; }
# guard_sources_for_mode: does the set THIS MODE enrols meet THAT mode's floor?
# It counts `mode_wans` -- the exact list build_agg_env enrols (one source of
# truth) -- not `ordered_wans`, and that is the whole difference from the guard it
# replaces. `enough_sources` counted LIVE sources against MIN_AGG_SOURCES, which
# is right for max/speed and wrong for eco (which enrols one source however many
# are live) and for lightning at N=1. For max/speed the two are IDENTICAL, because
# mode_wans == ordered_wans there.
# `>=` has no upper bound, so N=3,4,...,k all pass identically: N-generic.
guard_sources_for_mode() { [ "$(mode_wans 2>/dev/null | grep -c .)" -ge "$(min_sources_for_mode)" ]; }
# LEGACY SPELLINGS, kept only so a half-upgraded box (new bond-xctl, old bond.dag
# on disk) resolves its guard instead of refusing every edge. No shipped row uses
# them. `enough_sources`/`two_wans` are the pre-U141 aggregate arity guard.
guard_enough_sources() { [ "$(ordered_wans | grep -c .)" -ge "$MIN_AGG_SOURCES" ]; }

# ================= leaf VERIFY (silence-window engage_verify) ================
# ONE verify (U141). `verify_local` -- engage_verify against engarde's :59401 --
# is DELETED, and the surviving `verify_agg` inherits its full silence-window
# dance rather than the thin three-sample check the old `agg` row could afford.
# That inheritance is REQUIRED, not tidiness: the dance is what makes I8 hold (an
# engage converges to the bonded endpoint despite in-flight direct packets
# re-pinning it) and what makes the `suspend` onfail reachable (I9). The old
# `agg` row could skip it only because engarde was still there to fall back to.
BLK=0
unblock() { [ "$BLK" = 1 ] && iptables -D INPUT -p udp --sport "$WGPORT" -j DROP 2>/dev/null; BLK=0; }
verify_agg() {  # engage_verify(59402): endpoint HOLDS on the feeder against live traffic
    # FAST-PATH (BLOCKER-1): an already-pinned, healthy endpoint is a no-op. Skip the
    # iptables silence-window + re-pin dance entirely when ep is already the feeder's
    # and the tunnel pings. converged() no-ops a steady-state tick before any edge is
    # walked; this fast-path is the per-leaf partner for a DELTA that DOES walk the
    # engage edge but is already re-pinned (an ep-drift heal: ep_agg runs immediately
    # before this verify), so the heal installs NO iptables. The full dance runs ONLY
    # when ep != LOCAL_AGG still fails to hold (a genuine re-establishment).
    if [ "$(ep_now)" = "$LOCAL_AGG" ]; then
        "$PING" -c 1 -W 2 76.76.2.0 >/dev/null 2>&1 && return 0
    fi
    DIRECT_EP=$(live_direct); WGPORT=${DIRECT_EP##*:}; TGT="$LOCAL_AGG"
    ATT=1
    while [ "$ATT" -le 3 ]; do
        log "engaging $TGT: attempt $ATT/3 (~20s)..."
        command -v iptables >/dev/null 2>&1 && \
            iptables -I INPUT 1 -p udp --sport "$WGPORT" -j DROP 2>/dev/null && BLK=1
        apply_endpoint "$TGT" || { unblock; ATT=$((ATT+1)); continue; }
        j=1
        while [ "$j" -le 12 ]; do
            wg set "$WG_DEV" peer "$(live_peer)" endpoint "$TGT" 2>/dev/null
            [ $((j % 3)) -eq 0 ] && "$PING" -c 1 -W 1 76.76.2.0 >/dev/null 2>&1 &
            sleep 1; j=$((j+1))
        done
        wait 2>/dev/null; unblock
        GOOD=1; k=1
        while [ "$k" -le 3 ]; do
            [ "$(ep_now)" = "$TGT" ] || { GOOD=0; break; }
            "$PING" -c 2 -W 3 76.76.2.0 >/dev/null 2>&1 || { GOOD=0; break; }
            [ "$k" -lt 3 ] && sleep 3; k=$((k+1))
        done
        [ "$GOOD" = 1 ] && return 0
        ATT=$((ATT+1))
    done
    return 1
}

# ================= dispatchers (name -> function) ===========================
run_guard() { case "$1" in
    installed) guard_installed;; manual) guard_manual;;
    agg_installed) guard_agg_installed;;
    sources_for_mode) guard_sources_for_mode;;
    # `enough_sources` (U6) and `two_wans` (pre-U6) are the LEGACY spellings of the
    # aggregate arity guard U141 replaced with `sources_for_mode`. Kept as aliases
    # onto the predicate they always meant so a half-upgraded box (new bond-xctl,
    # old bond.dag on disk) still resolves the guard instead of refusing every edge.
    enough_sources|two_wans) guard_enough_sources;;
    *) log "unknown guard $1"; return 1;; esac; }
# LEGACY SPELLINGS (pre-U17 bond.dag on disk): the aggregate leaf names were
# `ep_speed` / `verify_speed`, back when `speed` was the only aggregate mode.
# Aliased onto the same functions for the same reason run_guard aliases
# `two_wans` (U6): a half-upgraded box resolves the table it has rather than
# refusing every aggregate edge. New tables must not use them.
run_action() { case "$1" in
    ep_direct) act_ep_direct;; ep_agg|ep_speed) act_ep_agg;;
    clear_susp) act_clear_susp;;
    env_gen) act_env_gen;; env_gen_if_enabled) act_env_gen_if_enabled;;
    agg_install) act_agg_install;; agg_enable) act_agg_enable;;
    agg_restart) act_agg_restart;; agg_restart_if_enabled) act_agg_restart_if_enabled;;
    agg_stop) act_agg_stop;; agg_disable) act_agg_disable;;
    mtu_1408) act_mtu_1408;; mtu_1420) act_mtu_1420;; revert) act_revert;;
    shape_apply) act_shape_apply;; shape_clear) act_shape_clear;;
    *) fail "unknown action $1";; esac; }
run_verify() { case "$1" in
    verify_agg|verify_speed) verify_agg;;
    *) log "unknown verify $1"; return 1;; esac; }

# ================= the DAG interpreter (== bond_model.py converge) ===========
# reads the row for $1 from bond.dag; runs guards -> actions -> verify(retries)
# -> onfail. $2 (optional) recursion-depth guard for onfail chaining.
_dag_row_raw() { grep -v '^[[:space:]]*#' "$DAG" 2>/dev/null | awk -F'|' -v i="$1" 'NF==8 && $1==i {print; exit}'; }
# dag_row: look the intent up. The U17 legacy fallback (`agg`->`speed`,
# `agg_revert`->`speed_revert`) is GONE with the rows it aliased: U141 folded the
# aggregate rows into `engage`/`suspend`, so reconcile() never emits either
# intent and a fallback for them could not fire. The intents this executor can
# emit are exactly the four rows the shipped table carries.
dag_row() { _dag_row_raw "$1"; }

converge() {
    intent="$1"; depth="${2:-0}"
    [ "$depth" -gt 4 ] && { log "onfail recursion cap hit at $intent"; return 1; }
    ROW=$(dag_row "$intent")
    [ -n "$ROW" ] || fail "no edge '$intent' in $DAG"
    # HIGH: split the DAG row with GLOBBING DISABLED. `set -- $ROW` word-splits on
    # IFS='|', but with globbing active a field holding a glob char (e.g. from='*',
    # the any-node wildcard) would be expanded against the cwd -- the bond.dag '*'
    # bug. `set -f` around the split keeps every field literal; restore noglob after.
    OLDIFS=$IFS; IFS='|'; set -f
    # shellcheck disable=SC2086
    set -- $ROW
    set +f; IFS=$OLDIFS
    e_from="$2"; e_guards="$4"; e_actions="$5"; e_verify="$6"; e_retries="$7"; e_onfail="$8"
    cur=$(node)
    case ",$e_from," in
        *",$cur,"*) : ;;
        *",*,"*)    : ;;
        *) log "$intent: does not apply from node '$cur' (from=$e_from)"; return 1;;
    esac
    if [ "$e_guards" != "-" ]; then
        # RESTORE IFS AROUND THE CALL, exactly as the action loop below already
        # does. This was asymmetric and it was a live defect, measured in the
        # ecosim harness during U141: a guard body ran with IFS=',' still in
        # force, so any word-splitting inside it split on commas. `is_agg` ->
        # `agg_sched_of` iterates AGG_SCHED_TABLE ("max:max speed:speed") by
        # WHITESPACE; under IFS=',' that is ONE word, no entry matched, and every
        # aggregate mode read as non-aggregate INSIDE A GUARD. The per-mode arity
        # guard therefore took the non-aggregate floor of 1 and `bondctl mode
        # speed` was ACCEPTED at N=1. Nothing caught it before because the only
        # guard that existed did no word-splitting.
        # THIS IS THE ONLY FIX SITE. A second pin lived in `agg_sched_of`/
        # `agg_modes` (xctl-probe.sh) and was removed in the U141 fix round:
        # while both stood, reverting either one alone left the whole suite
        # green at 478/0, so no bar pinned either. With this restore as the only
        # site, reverting the two IFS lines INSIDE this loop reddens 5 bars
        # (measured): EL-1 N=1 speed refused, NG4 x2, S7 x2.
        OLDIFS=$IFS; IFS=,
        for g in $e_guards; do
            IFS=$OLDIFS
            if ! run_guard "$g"; then log "$intent: guard '$g' refused"; return 1; fi
            OLDIFS=$IFS; IFS=,
        done
        IFS=$OLDIFS
    fi
    if [ "$e_actions" != "-" ]; then
        OLDIFS=$IFS; IFS=,
        for a in $e_actions; do IFS=$OLDIFS; run_action "$a"; OLDIFS=$IFS; IFS=,; done
        IFS=$OLDIFS
    fi
    [ "$e_verify" = "-" ] && return 0
    OKV=1; n=1; RET=${e_retries:-1}; [ "$RET" -lt 1 ] && RET=1
    while [ "$n" -le "$RET" ]; do
        if run_verify "$e_verify"; then OKV=0; break; fi
        n=$((n+1))
    done
    if [ "$OKV" = 0 ]; then act_clear_susp; return 0; fi
    if [ "$e_onfail" != "-" ]; then converge "$e_onfail" $((depth+1)); fi
    return 1
}

# ================= converged(): the stateless steady-state short-circuit =====
# `converged "$d"` returns 0 (TRUE = already at desired -> do NOTHING) ONLY when the
# box is FULLY at the desired target. This is the idiomatic level-triggered no-op that
# fixes the watchdog restart-storm UNIFORMLY for engage AND speed: a healthy box walks
# NO edge (no restart, no verify/iptables dance, no genconf/env rewrite), so the ~10s
# reconcile tick stops bouncing the datapath. converge then runs ONLY on a real delta.
#
# It is a FULL-signature check, not node()-only: node() alone misses (a) an endpoint
# drift that node() still reports as `engaged` -- checking node only would break I2
# self-heal; and (b) a mode switch, which moves the CONFIG but not node/ep/feeders --
# so the live config MUST be compared against a fresh desired build. Any suspend crumb
# present => NOT converged (re-walk the edge so verify re-confirms and clears it).
_conf_matches() {   # $1 = builder fn name, $2 = live file. TRUE iff fresh build == live.
    _t="$RUN_DIR/.desired.cmp.$$"
    # Build in a SUBSHELL so a builder `fail` (missing probe/underlay) is contained and
    # simply reads as "cannot build desired" -> NOT converged (fall through to converge).
    if ( "$1" "$_t" ) >/dev/null 2>&1; then
        cmp -s "$_t" "$2" 2>/dev/null; _cr=$?
    else
        _cr=1
    fi
    rm -f "$_t" 2>/dev/null
    return "$_cr"
}
converged() {
    mkrun
    [ "$(susp_state)" = none ] || return 1        # any suspend crumb -> re-verify/clear
    case "$1" in
        off)
            svc_running p5-datapath    && return 1
            [ "$(ep_now)" = "$(live_direct)" ] || return 1
            shape_matches              || return 1
            return 0 ;;
        engaged)
            # TWO arms, not three (U141): one feeder means one engaged signature,
            # whatever the mode. The MODE difference lives entirely inside
            # build_agg_env (AGG_PATHS from mode_wans, AGG_SCHED), so the config
            # cmp below is what makes ANY mode flip a real delta -- including
            # eco<->lightning, which used to move nothing this function could see.
            svc_enabled "$AGG_SVC"     || return 1
            svc_running p5-datapath    || return 1
            [ "$(ep_now)" = "$LOCAL_AGG" ] || return 1
            _conf_matches build_agg_env "$BOND_DIR/agg_env" || return 1
            shape_matches              || return 1
            return 0 ;;
        *) return 1 ;;
    esac
}

# ================= THE reconciler (== bond_model.py reconcile) ===============
# observe node() -> desired() -> walk ONE bond.dag edge. The lifecycle target is
# chosen by desired(), never by the caller. One edge per invocation; the next
# trigger/tick reconverges (no loop-to-fixpoint). $1="refresh" for a live config
# switch (a mode change): the tunnel is intact, re-apply config via `switch` (no
# re-verify, ep untouched); otherwise (on/wg-ifup/reboot/watchdog) re-establish via
# `engage`. Serialized by the single take_lock (the caller takes it before calling).
reconcile() {
    d=$(desired)
    # STATELESS SHORT-CIRCUIT: a box already fully at its desired target does NOTHING.
    # This supersedes the per-leaf idempotency crumbs/fast-paths: converge is reached
    # ONLY on a genuine delta (engage AND speed), so a healthy tick never restarts a
    # feeder or runs the verify dance.
    if converged "$d"; then return 0; fi
    case "$d" in
        off)           converge disengage ;;
        engaged)
            if [ "$1" = refresh ] && svc_enabled "$AGG_SVC"; then
                converge switch; return $?
            fi
            if converge engage; then return 0; fi
            # ---- CHURN SUSTAINMENT (U19, re-based on the one feeder by U141).
            # The per-mode arity requirement is an ENTRY guard on `engage`
            # (`sources_for_mode`), and a refused guard changes nothing -- so a box
            # already running an aggregate mode whose live source count has FALLEN
            # below the floor would keep bond-agg running over a source that is
            # GONE, re-refusing the same edge every tick, with the watchdog calling
            # it a no-op. The DAG already carries the recovery: `switch`, whose
            # env_gen re-enrols the sources that ARE live and whose agg_restart
            # bounces the datapath onto them. `mode` is deliberately NOT rewritten,
            # so the pin survives and the aggregate re-forms by itself when a
            # source returns -- the same shape as I6 capability auto-resume.
            # THE DISCRIMINATOR. It fires only on sustainment loss, never on an
            # entry refusal (`bondctl mode max` at N<2 must still fail and restore
            # the prior mode -- SP5/NG-1), so it needs all three terms:
            #   * the feeder is RUNNING;
            #   * the LIVE agg_env already carries THIS mode's scheduler, i.e. the
            #     box is already IN this mode and the world fell away underneath
            #     it -- false for an attempt to enter a different mode;
            #   * this mode is an AGGREGATE mode. For eco/lightning the floor is 1,
            #     so the guard can only refuse at N=0, and at N=0 `switch` could not
            #     help: build_agg_env `fail`s on the empty set and exits mid-edge.
            # == bond_model.py reconcile()'s sustainment arm, term for term.
            if is_agg && svc_running p5-datapath \
               && [ "$(agg_sched_live)" = "$(agg_sched_of "$(mode_of)" || mode_of)" ] \
               && ! guard_sources_for_mode; then
                converge switch
            fi
            return 1 ;;
        *) log "reconcile: unknown desired '$d'"; return 1 ;;
    esac
}

# ================= selfcheck (validate the shipped table) ===================
selfcheck() {
    [ -r "$DAG" ] || fail "cannot read $DAG"
    bad=0
    # LOW: two coupled defects fixed here --
    #  (1) SUBSHELL: the old `grep ... | while` ran the loop in a subshell, so `bad=1`
    #      was lost on exit and selfcheck could never report a bad row. Feed the loop via
    #      a here-doc REDIRECT instead, keeping it in THIS shell.
    #  (2) DETECTOR: the old field count rebuilt "$nm|..|$on", which ALWAYS has 7
    #      delimiters == 8 fields, so the NF!=8 test could never fire (a 7-field row
    #      passed). Count fields on the RAW line via awk, which also prints the row.
    while IFS= read -r _row; do
        [ -n "$_row" ] || continue
        printf '%s\n' "$_row" | awk -F'|' '
            NF!=8 { printf "BAD ROW (fields=%d): %s\n", NF, $0; exit 3 }
                  { printf "edge %s: %s -> %s  guards=[%s] verify=%s retries=%s onfail=%s\n", $1,$2,$3,$4,$6,$7,$8 }'
        [ $? = 3 ] && bad=1
    done <<EOF
$(grep -v '^[[:space:]]*#' "$DAG" | grep -v '^[[:space:]]*$')
EOF
    if [ "$bad" != 0 ]; then echo "selfcheck: $DAG has malformed rows" >&2; return 1; fi
    echo "selfcheck: $DAG parsed"
}
