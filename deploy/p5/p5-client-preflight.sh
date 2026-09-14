#!/bin/sh
# shellcheck shell=sh
# p5-client-preflight.sh -- READ-ONLY. The CLIENT counterpart of
# deploy/server/p5-server-preflight.sh, and it exists because there was not one.
#
# WHY IT IS A NEW FILE (U115). Before this, the only thing on the client that
# refused anything at preflight time was `deploy/p5/shape-install preflight`,
# and that is the SHAPER's gate: its subject is tc/cake/ifb, its capability
# list is the shaper's, and the Layer-2 harness drives it hundreds of times.
# Putting a datapath secret check inside it would have made an unrelated gate
# refuse for an unrelated reason. The server's preflight is not usable here
# either -- it probes the firewall subsystem of the box that cannot be
# recovered. So the client's own preflight is this, and today it asks exactly
# one question that can refuse.
#
# WHAT IT DOES NOT DO, said here so a green run is not read as more than it is:
#   - it does not check the shaper. `shape-install preflight` is that gate and
#     is still the one to run before the shaper is installed.
#   - it does not decide whether the old stack is out of the way. That gate is
#     `p5-uninstall --quiescent` (U208) and, on the reconciler's side, the
#     `old_quiescent` guard on the engage row. NOT `--check --scope both`,
#     which this line used to name: under the decided deploy order P5 installs
#     ALONGSIDE the old stack, so the old files are on disk at switch time BY
#     DESIGN and `--check --scope both` returns NOT CLEAN on every box that has
#     reached this point. Presence is the wrong question; quiescence is the
#     right one. The section at the bottom REPORTS the quiescence verdict when
#     the verb is on the box, and never turns it into a refusal.
#   - it cannot tell, FROM THE KEY ALONE, whether this box's secret matches the
#     server's. Nothing on one box can. Two things now close that and neither
#     is "the operator remembers": p5-install takes --peer-key-id and REFUSES a
#     mismatch before it touches the box, and the transport-auth-gate block at
#     the bottom of this file reads the daemon's own PSTAT counters after
#     engage -- gate=1 and authbad=0, or it refuses (U291).
#   - it has never run on a box. Nothing in P5 has.
#
# POSIX sh / busybox. No bashisms, no arrays, no sleep.

sec() { printf '\n### %s\n' "$1"; }

# The exit code: 0 unless a block below refuses. One variable, set in one
# direction only, so a later block cannot quietly clear an earlier refusal.
PF_RC=0

# ---------------------------------------------------------------- identity --
# First, for the same reason the server's preflight prints it first: an answer
# that names the wrong box is worse than no answer.
sec identity
printf 'hostname: %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
printf 'model:    %s\n' "$( (cat /tmp/sysinfo/model 2>/dev/null) || echo '(unknown)')"

# ------------------------------------------------- transport secret (U115) --
# A REFUSAL, not a report. p4-bondagg/daemon/auth.go:117-120 reads the
# per-install secret from this path and, when it cannot, pullrun.go:184-199
# LOGS the failure and the datapath runs on with authentication OFF --
# byte-for-byte the forgeable framing U31 exists to close. "Not there" and
# "readable by anyone on the box" are both stop conditions, so this script
# exits non-zero on either and names the file.
#
# THE MODE IS READ FROM `ls -l`, NOT `stat`: busybox builds without stat exist,
# and a preflight that cannot read the mode must not pass because of it.
# Characters 5-10 of the permission string are the group and other bits;
# anything but six dashes means somebody other than the owner can reach it.
sec transport-key
KEYF="${P5_ROOT:-}/etc/p5/transport.key"
if [ ! -f "$KEYF" ]; then
    printf '%-28s ABSENT\n' "$KEYF"
    printf 'REFUSE: the transport secret is not on this box, so the datapath would start\n'
    printf '        with authentication OFF and the bonded framing forgeable. p5-install\n'
    printf '        places it; a second box adopts the first one with --transport-key.\n'
    printf '        File: %s\n' "$KEYF"
    PF_RC=1
else
    # shellcheck disable=SC2012
    # ls, not find -perm: busybox find's permission predicates vary by build
    # and this is one fixed, known path, not a tree walk over hostile names.
    _perm=$(ls -l "$KEYF" 2>/dev/null | head -1 | cut -c1-10)
    _rest=$(printf '%s' "$_perm" | cut -c5-10)
    printf '%-28s %s\n' "$KEYF" "${_perm:-(mode unreadable)}"
    if [ -z "$_perm" ]; then
        printf 'REFUSE: the mode of %s could not be read. A mode that cannot be read is not a\n' "$KEYF"
        printf '        mode that passes.\n'
        PF_RC=1
    elif [ "$_rest" != "------" ]; then
        printf 'REFUSE: %s is reachable beyond its owner (%s). The secret must be mode 600:\n' "$KEYF" "$_perm"
        printf '        chmod 600 %s   then re-run this preflight.\n' "$KEYF"
        PF_RC=1
    else
        printf 'transport-key: ok -- present and owner-only\n'
    fi
fi

# ------------------------------------------------------------ p5 namespace --
# Reported, never a refusal: on the client the old stack is expected to be
# present and running, and P5 installs BESIDE it on purpose (p5/bin/p5-install,
# "WHY IT DOES NOT REQUIRE THE OLD STACK TO BE GONE FIRST").
sec p5-paths
for p in /usr/sbin/p5-datapath /etc/init.d/p5-datapath /usr/lib/p5 /etc/p5; do
    if [ -e "${P5_ROOT:-}$p" ]; then printf '%-28s present\n' "$p"
    else printf '%-28s free\n' "$p"; fi
done

# ------------------------------------------------- old stack quiescence (U211) --
# REPORTED, NEVER A REFUSAL, and the distinction is the point of this block.
# The mechanical gate on the old stack is the reconciler's `old_quiescent`
# guard on the engage row (U208): `p5 on` refuses and logs the terms while the
# old stack is still armed. Duplicating that decision here would give the
# operator two gates that can disagree, and the one with no side effects is the
# one that would be believed. So this prints the verdict and leaves PF_RC alone.
#
# CALLED ONLY WHEN PRESENT, and guarded TWICE. `--quiescent` is U208's verb and
# this file must not depend on the order the two land in, so the installed
# uninstaller must be executable AND must advertise the verb. Without the second
# test a pre-U208 uninstaller would be handed an unknown flag and would answer
# with its usage text and a non-zero status, which reads like a failing check
# and is not one.
sec old-stack-quiescence
_uninst="${P5_ROOT:-}/usr/sbin/p5-uninstall"
if [ ! -x "$_uninst" ]; then
    printf 'skipped: %s is not on this box (nothing to ask)\n' "$_uninst"
elif ! grep -q -- '--quiescent' "$_uninst" 2>/dev/null; then
    printf 'skipped: %s does not carry the --quiescent verb (pre-U208 build)\n' "$_uninst"
elif "$_uninst" --quiescent 2>&1; then
    printf 'old-stack: QUIESCENT -- the engage guard would admit the p5 on verb\n'
else
    _qrc=$?
    printf 'old-stack: NOT QUIESCENT (exit %s). Reported, not refused: the engage guard\n' "$_qrc"
    printf '        is the gate, and it will refuse the p5 on verb until the terms above\n'
    printf '        are cleared with: p5-uninstall --switch-off --role client\n'
fi


# ------------------------------------------- transport auth gate (U291) --
# A REFUSAL, and it is the POST-ENGAGE half of the transport-secret question.
#
# The block above asks "is there a secret, and is it owner-only". It CANNOT
# ask the question that decides whether the wire is authenticated: whether
# these 32 bytes are the SAME 32 bytes as the other box's. Nothing on one box
# can answer that from the key alone -- which is why p5-install now takes
# --peer-key-id and refuses a mismatch. This block is the other end of that:
# it asks the DAEMON, which has been counting the answer all along.
#
# p4-bondagg/daemon/pullrun.go:676 emits `authbad=` (received frames whose MAC did not
# verify) and `gate=` (1 while the gate is CLOSED, i.e. refusing
# unauthenticated frames). A key mismatch makes authbad climb and then, after
# ReopenDefault = 30s with no valid tag, drives gate back to 0 --
# p4-bondagg/server/auth.go:221 and the authGate rule at :307-330. THAT REOPEN
# IS DELIBERATE AND IS NOT CHANGED HERE: on a box with no console, a rule that
# can lock the legitimate client out loses the box for ever. The defect was
# never the reopen. It was that nothing ever LOOKED, so a wrong key produced a
# tunnel that carries traffic normally and authenticates nothing, and the only
# detector was a paragraph p5-install printed at the end of a green run.
#
# THE SOURCE, in order: $P5_STAT_LOG names a file to read -- a captured log,
# and what the e0 bars drive this with -- otherwise `logread`, because
# deploy/p5/init.d/bond-agg:40 sets `procd_set_param stderr 1`, so the
# daemon's lines land in syslog. With NEITHER there is no evidence at all, and
# this block says so rather than passing quietly. Absence of evidence becomes
# a REFUSAL only under --post-engage (or P5_POST_ENGAGE=1), which is how the
# deploy ladder asks the question AFTER the switch: a box that has delivered a
# frame has reported one, so "no PSTAT line" at that rung is itself an answer.
sec transport-auth-gate
ag_field() {    # ag_field LINE KEY -> the integer value of KEY=<int>, or empty
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=\\([0-9][0-9]*\\)$/\\1/p" | head -1
}
AG_PE=0
if [ "${P5_POST_ENGAGE:-0}" = 1 ]; then AG_PE=1; fi
for _ag_a in "$@"; do
    if [ "$_ag_a" = "--post-engage" ]; then AG_PE=1; fi
done
AG_SRC=""
AG_LINE=""
if [ -n "${P5_STAT_LOG:-}" ] && [ -r "${P5_STAT_LOG:-}" ]; then
    AG_SRC="$P5_STAT_LOG"
    AG_LINE=$(grep 'PSTAT ' "$P5_STAT_LOG" 2>/dev/null | tail -1)
elif command -v logread >/dev/null 2>&1; then
    AG_SRC="logread"
    AG_LINE=$(logread 2>/dev/null | grep 'PSTAT ' | tail -1)
fi
if [ "$AG_PE" = 1 ]; then
    printf '%-28s %s\n' "mode" "POST-ENGAGE (no evidence REFUSES)"
else
    printf '%-28s %s\n' "mode" "pre-engage (no evidence REPORTS)"
fi
printf '%-28s %s\n' "PSTAT source" "${AG_SRC:-(none: P5_STAT_LOG unset, logread absent)}"
if [ -z "$AG_LINE" ]; then
    if [ "$AG_PE" = 1 ]; then
        printf 'REFUSE: --post-engage was asked for and there is no PSTAT line to read. After\n'
        printf '        engage this daemon reports one; none at all means it is not running,\n'
        printf '        not logging, or was never engaged -- and the auth gate cannot be\n'
        printf '        called CLOSED on no evidence.\n'
        PF_RC=1
    else
        printf 'transport-auth-gate: NOT EVALUATED -- no PSTAT line to read. This check has a\n'
        printf '        verdict only AFTER engage. Re-run it with --post-engage at that rung;\n'
        printf '        there it REFUSES on silence instead of reporting it.\n'
    fi
else
    printf 'last PSTAT: %s\n' "$AG_LINE"
    _ag_gate=$(ag_field "$AG_LINE" gate)
    _ag_bad=$(ag_field "$AG_LINE" authbad)
    if [ -z "$_ag_gate" ] || [ -z "$_ag_bad" ]; then
        printf 'REFUSE: that PSTAT line carries no gate= and authbad= pair, so this box runs a\n'
        printf '        build older than the counters this check reads. An unreadable verdict\n'
        printf '        is not a passing one.\n'
        PF_RC=1
    elif [ "$_ag_gate" != 1 ]; then
        printf 'REFUSE: the auth gate is OPEN (gate=%s). Every frame is being served unsigned\n' "$_ag_gate"
        printf '        and unverified -- the forgeable framing. The usual cause is that the\n'
        printf '        two boxes carry DIFFERENT transport secrets, which degrades to no-auth\n'
        printf '        after the 30s reopen horizon instead of to an outage you would notice.\n'
        printf '        Compare P5_TRANSPORT_KEY_ID in the two stamps (p5-version prints it)\n'
        printf '        and re-install this box with --transport-key plus --peer-key-id.\n'
        PF_RC=1
    elif [ "$_ag_bad" != 0 ]; then
        printf 'REFUSE: authbad=%s -- that many received frames failed their MAC. The gate is\n' "$_ag_bad"
        printf '        shut at this instant, but frames are arriving that this key cannot\n'
        printf '        verify, so the two boxes are not carrying the same secret and the\n'
        printf '        gate will reopen 30s after the last good one.\n'
        PF_RC=1
    else
        printf 'transport-auth-gate: ok -- gate=1 (CLOSED) and authbad=0\n'
    fi
fi

sec END

# The exit code IS the verdict. Without this line the refusals above are prose,
# and a caller that reads nothing but the status would install over them.
exit "$PF_RC"
