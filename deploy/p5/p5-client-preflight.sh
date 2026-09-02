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
#   - it does not check the old stack. `p5-uninstall --check --scope both` is
#     that gate.
#   - it cannot tell whether this box's secret MATCHES the server's. Nothing on
#     one box can. The two stamps carry P5_TRANSPORT_KEY_ID for exactly that
#     comparison; making it is the operator's step.
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

sec END

# The exit code IS the verdict. Without this line the refusal above is prose,
# and a caller that reads nothing but the status would install over it.
exit "$PF_RC"
