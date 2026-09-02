#!/bin/sh
# xctl-lock.sh -- sourced by bond-xctl (U124 split). Bodies byte-identical to the
# single-file reconciler; see docs/knowledge/design for the WHY of each function.

mkrun() { [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null; }
# mkfacts(): P5 CREATES its own fact directory. Same shape as mkrun, and for the
# same reason -- a directory this program writes into is this program's to make.
#
# U50a, second round. `guard_installed` was `[ -x "$ENGARDE_BIN" ] && [ -d "$BOND_DIR" ]`
# and dropping the first term alone left the SECOND one still owned by the old
# stack: `grep -rn mkdir deploy/p5/` creates RUN_DIR and the lock dir and nothing
# else, and the only creator of $BOND_DIR anywhere in the repo is
# p2-engarde/bootstrap-bond.sh (it mkdir -p's BOND_DIR; the server twin is in
# bootstrap-bond-server.sh). So on a box where E7 has removed the old stack and
# P2's bootstrap never ran, the directory does not exist, `guard_installed` is
# FALSE, and all four edges refuse exactly as they did before -- the dependency
# would have moved from P2's BINARY to P2's DIRECTORY instead of being removed.
# It does not bite today's client, which has /etc/p5, which is why it survived
# the first round: no bar could see it, because every harness `setup` made the
# directory itself.
#
# This claims no new namespace. P5 ALREADY writes engarde.yml, applied_wans and
# agg_env there (genconf, act_env_gen) and bondctl already writes mode and auto,
# so creating the directory it already populates adds nothing that E0's contract
# does not already have to account for (U51 owns the p5-* relocation; this
# function follows $BOND_DIR wherever that lands, and names no literal path).
#
# The guard stays NON-VACUOUS: mkdir -p fails on a read-only or full /etc, and a
# box that cannot hold P5's facts must refuse the edge rather than walk it and
# lose every write silently.
mkfacts() { [ -d "$BOND_DIR" ] || mkdir -p "$BOND_DIR" 2>/dev/null; }

# ---- serialization lock (tmpfs; holder-pid + age breakstale = D4 fix) ------
LOCK="$RUN_DIR/lock"
take_lock() {
    mkrun
    mkfacts          # P5 owns its fact directory; see mkfacts() above
    if ! mkdir "$LOCK" 2>/dev/null; then
        # break a stale lock: holder pid gone, or age > 120s (power-loss crumb)
        # MF-3: STALE must respect HOLDER LIVENESS. A live holder's legit engage
        # hold can run ~6-8 min (5 retries x verify_local ~20s), so age alone must
        # NOT break it. STALE iff (pid present AND holder DEAD) OR (pid absent AND
        # aged) OR age>900 (PID-reuse backstop, above the worst legit hold).
        HP=$(cat "$LOCK/pid" 2>/dev/null)
        # AGE via `stat -c %Y`, but PROBE the capability first: some busybox builds ship
        # a stat without GNU `-c`. Without it we cannot measure age, so DISABLE the
        # age-gate (AGE=0) and fall back to holder-liveness ONLY. Reading a failed stat
        # as mtime 0 would make AGE huge and break EVERY live lock as "aged" (a silent
        # MF-3 regression: serialization gone). kill -0 still reaps a genuinely dead holder.
        NOW=$(date +%s 2>/dev/null || echo 0)
        if stat -c %Y "$LOCK" >/dev/null 2>&1; then
            AGE=$(( NOW - $(stat -c %Y "$LOCK" 2>/dev/null || echo "$NOW") ))
        else
            AGE=0
        fi
        STALE=0
        if [ -n "$HP" ]; then
            kill -0 "$HP" 2>/dev/null || STALE=1              # holder recorded but DEAD
        else
            [ "$AGE" -gt 120 ] 2>/dev/null && STALE=1         # no holder recorded + aged
        fi
        [ "$AGE" -gt 900 ] 2>/dev/null && STALE=1             # PID-reuse backstop
        if [ "$STALE" = 1 ]; then
            log "breaking stale lock (holder=$HP)"; rm -rf "$LOCK" 2>/dev/null
            # DIRTY (MED): our reconcile request would be LOST if we cannot take the
            # lock. Leave a crumb so the holder re-reconciles once more after it finishes
            # (the last request is eventually honored). reconcile() is level-triggered, so
            # one extra pass off the LATEST facts honors whatever request(s) we coalesced.
            mkdir "$LOCK" 2>/dev/null || { touch "$RUN_DIR/reconcile_dirty" 2>/dev/null; log "lock busy; skipping"; exit 0; }
        else
            touch "$RUN_DIR/reconcile_dirty" 2>/dev/null
            log "another bond-xctl operation in progress; skipping"; exit 0
        fi
    fi
    echo "$$" > "$LOCK/pid" 2>/dev/null
    # MF-3/MF-4: release is OWNERSHIP-CHECKED (only remove the lock if WE still own
    # it -- never delete a thief's lock after our own breakstale race), and INT/TERM
    # must actually EXIT (busybox ash resumes after a handled signal otherwise, and
    # would keep mutating wg/services unserialized). `exit 143` fires the EXIT trap.
    trap 'unblock 2>/dev/null; [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null' EXIT
    trap 'exit 143' INT TERM
}
