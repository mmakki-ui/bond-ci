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

# ---- serialization lock (tmpfs; holder-pid + MONOTONIC age breakstale = D4 fix) ----
LOCK="$RUN_DIR/lock"
# U117. The age gate no longer depends on `stat -c %Y`, and no longer on the wall
# clock. It reads a stamp this program writes at acquire ($LOCK/ts, "<mono> <epoch>")
# against a MONOTONIC source ($P5_MONO_SRC, default /proc/uptime).
#
# Why a stamp and not the directory mtime: `-c` is a GNU spelling some busybox
# builds do not ship, and the old code answered that by setting AGE=0 -- the same
# value the 900s PID-reuse backstop compared against -- so on such a build a dead
# holder whose pid had been re-issued to a live process was judged live FOREVER and
# every reconcile skipped until reboot. The repo's own records CONTRADICT each other
# on whether the routers' build has it (deploy/server/test-p5-fw-deadman.sh:115 says
# busybox does; deploy/p5/p5-client-preflight.sh:49 and
# deploy/server/p5-server-preflight.sh:329 both say builds without it exist and read
# modes from `ls -l` instead), and neither record MEASURES either box. So the probe
# and the call are gone, not made conditional: both answers now produce identical
# behaviour and the question stops being on the shipped path.
#
# Why MONOTONIC and not `date +%s`: these boxes have no RTC and boot at a bogus
# epoch, so the first NTP step would make every held lock look years old and break a
# LIVE holder mid-engage -- two concurrent DAG walks, the MF-3 regression, the
# catastrophic direction. $RUN_DIR is tmpfs, so a stamp is always same-boot and
# uptime cannot be stepped. Field 2 (the epoch) is recorded for operator forensics
# and DECIDES NOTHING.
#
# When the age cannot be established at all -- no ts (a lock from a pre-U117 build
# still in tmpfs, or a kill inside the mkdir->write window), an unparseable ts (a
# short write on a full tmpfs), no monotonic source, or a source that moved
# BACKWARDS -- the age is UNKNOWN. It is never clamped to 0 (that clamp IS the
# defect) and never read as huge (that would break every live holder). The backstop
# still terminates WITHOUT ANY CLOCK: consecutive contended passes are COUNTED in
# $RUN_DIR/lock_unknown, because separate reconcile invocations are ~10s apart
# (bond-watchdog's CYCLE default is 10s) and cannot all be the same microsecond window.
# That is what makes this independent of stat, of date and of procfs, all three.
#
# LIVENESS IS CONSULTED FIRST, AND THE COUNT-OUT IS KEYED TO IT (U117 fix round 1).
# The first cut counted out at UNKNOWN_MAX=3 BEFORE looking at the holder, which
# broke a provably LIVE holder ~30s into a legit 6-8 min engage hold -- exactly the
# MF-3 regression the rule below forbids, and the catastrophic direction (two
# concurrent DAG walks). The pass count is now the CLOCK-FREE ANALOGUE of the two
# second-valued limits, not a third, shorter limit of its own:
#   holder recorded and DEAD    -> reaped on pass 1, as with a usable age
#   holder ABSENT               -> broken at UNKNOWN_MAX passes  (~= HOLD_MAX)
#   holder recorded and LIVE    -> broken at UNKNOWN_LIVE_MAX passes (~= REUSE_MAX),
#                                  and by nothing else -- that IS the PID-reuse
#                                  backstop, the only rule allowed to break a live
#                                  holder, and the reason this still terminates.
# The counter is keyed to the holder pid, so a lock handed from one holder to the
# next restarts the count instead of inheriting it.
#
# CALIBRATION, stated because it is an assumption and not a measurement: a pass is
# worth ~CYCLE seconds only while the watchdog is the caller. A caller that storms
# `bond-xctl reconcile` faster than CYCLE shrinks the effective backstop by the same
# factor. The repo has one periodic caller (bond-watchdog, CYCLE=10) and one manual
# one (bondctl, per operator action), so 90 passes is ~15 min of watchdog time.
#
# $LOCK/pid is untouched -- same path, same one-line format -- so the four fixture
# sites that fabricate a lock by writing only that file, and the ownership-checked
# EXIT trap that reads only that file, keep working unchanged.
P5_MONO_SRC="${P5_MONO_SRC:-/proc/uptime}"
HOLD_MAX=120        # pid absent and older than this -> stale (power-loss crumb)
REUSE_MAX=900       # PID-reuse backstop, above the worst legit hold (~6-8 min)
# Clock-free analogues of the two limits above, counted in CONTENDED PASSES instead
# of seconds (bond-watchdog's CYCLE default is 10s, so a pass is ~10s of watchdog time).
UNKNOWN_MAX=12      # holder ABSENT, age unknowable  -> break here (~= HOLD_MAX)
UNKNOWN_LIVE_MAX=90 # holder LIVE, age unknowable    -> break here (~= REUSE_MAX)

_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Monotonic seconds, or EMPTY when unknowable. Read with the shell, so there is no
# applet and no PATH question. /proc/uptime is "12345.67 9876.54": the fraction MUST
# be stripped or the arithmetic errors, and the second field with it.
_mono() {
    _mn=''
    if [ -r "$P5_MONO_SRC" ]; then
        read -r _mn < "$P5_MONO_SRC" 2>/dev/null || _mn=''
        _mn=${_mn%%.*}
        _mn=${_mn%% *}
    fi
    _uint "$_mn" || _mn=''
    printf '%s' "$_mn"
}

# Stamp written ONCE, at acquire. A field we cannot fill is '-', never 0.
_lock_ts() {
    _lm=$(_mono);              [ -n "$_lm" ] || _lm='-'
    _le=$(date +%s 2>/dev/null); _uint "$_le" || _le='-'
    printf '%s %s\n' "$_lm" "$_le" > "$LOCK/ts" 2>/dev/null
}

take_lock() {
    mkrun
    mkfacts          # P5 owns its fact directory; see mkfacts() above
    if ! mkdir "$LOCK" 2>/dev/null; then
        # MF-3: STALE must respect HOLDER LIVENESS. A live holder's legit engage
        # hold can run ~6-8 min (5 retries x verify_local ~20s), so age alone must
        # NOT break it. With a USABLE age, STALE iff (pid present AND holder DEAD)
        # OR (pid absent AND age > HOLD_MAX) OR age > REUSE_MAX (PID-reuse backstop).
        # With an UNKNOWABLE age the same three rules apply with the pass count
        # standing in for the seconds -- liveness FIRST, then the limit that matches
        # the holder's state. A live holder is never broken by the short limit.
        HP=$(cat "$LOCK/pid" 2>/dev/null)
        NOW_MONO=$(_mono)
        TS_MONO=''
        [ -r "$LOCK/ts" ] && read -r TS_MONO < "$LOCK/ts" 2>/dev/null
        TS_MONO=${TS_MONO%% *}
        AGE=''
        if _uint "$NOW_MONO" && _uint "$TS_MONO"; then
            AGE=$((NOW_MONO - TS_MONO))
            [ "$AGE" -ge 0 ] || AGE=''    # source moved BACKWARDS -> UNKNOWN, not 0
        fi
        STALE=0
        if [ -n "$AGE" ]; then
            rm -f "$RUN_DIR/lock_unknown" 2>/dev/null   # usable record: reset
            if [ -n "$HP" ]; then
                kill -0 "$HP" 2>/dev/null || STALE=1    # holder recorded but DEAD
            else
                [ "$AGE" -gt "$HOLD_MAX" ] && STALE=1   # no holder recorded + aged
            fi
            [ "$AGE" -gt "$REUSE_MAX" ] && STALE=1      # PID-reuse backstop
        else
            # The counter is "<holder-pid-or-dash> <count>". Keying it to the pid is
            # load-bearing: without it, passes spent contending holder A would be
            # carried into holder B and count B out early.
            UNK_PID=''; UNK=''
            if [ -r "$RUN_DIR/lock_unknown" ]; then
                read -r UNK_PID UNK < "$RUN_DIR/lock_unknown" 2>/dev/null || { UNK_PID=''; UNK=''; }
            fi
            _uint "$UNK" || UNK=0
            [ "$UNK_PID" = "${HP:--}" ] || UNK=0        # different holder: restart
            UNK=$((UNK + 1))
            printf '%s %s
' "${HP:--}" "$UNK" > "$RUN_DIR/lock_unknown" 2>/dev/null
            # LIVENESS BEFORE THE COUNT-OUT (MF-3). Order here is the whole fix.
            if [ -n "$HP" ] && kill -0 "$HP" 2>/dev/null; then
                UNK_LIM="$UNKNOWN_LIVE_MAX"             # live: only the reuse backstop
                [ "$UNK" -ge "$UNKNOWN_LIVE_MAX" ] && STALE=1
            elif [ -n "$HP" ]; then
                UNK_LIM="$UNKNOWN_MAX"
                STALE=1                                 # holder recorded but DEAD
            else
                UNK_LIM="$UNKNOWN_MAX"                  # no holder: clock-free HOLD_MAX
                [ "$UNK" -ge "$UNKNOWN_MAX" ] && STALE=1
            fi
            log "lock age UNKNOWN (mono='$NOW_MONO' ts='$TS_MONO' holder='$HP' pass $UNK/$UNK_LIM)"
        fi
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
    # ts BEFORE pid, and this order is load-bearing (bar LK-0): a holder killed
    # between the two writes leaves a lock that still carries an age, which is the
    # state the pid-absent limb above decides on.
    _lock_ts
    echo "$$" > "$LOCK/pid" 2>/dev/null
    rm -f "$RUN_DIR/lock_unknown" 2>/dev/null
    # MF-3/MF-4: release is OWNERSHIP-CHECKED (only remove the lock if WE still own
    # it -- never delete a thief's lock after our own breakstale race), and INT/TERM
    # must actually EXIT (busybox ash resumes after a handled signal otherwise, and
    # would keep mutating wg/services unserialized). `exit 143` fires the EXIT trap.
    trap 'unblock 2>/dev/null; [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK" 2>/dev/null' EXIT
    trap 'exit 143' INT TERM
}
