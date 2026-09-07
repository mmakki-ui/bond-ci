#!/bin/sh
# shellcheck shell=sh
# mutant-check-p5-fw-deadman.sh -- prove the deadman's bars are load-bearing.
#
# WHY. An independent verify demonstrated that test-p5-fw-deadman.sh scored a
# byte-identical 34/34 on a tool with TWO OF ITS THREE LIMBS' MACHINERY DELETED:
# `do_status` gutted to `printf; return 0`, and the entire detached-timer spawn
# replaced by `:`. A pass count is not coverage, and no amount of reading the
# suite reveals that -- only running it against a broken tool does.
#
# So this file BUILDS THAT EXACT MUTANT from the shipped tool, runs the shipped
# suite against it, and FAILS IF THE SUITE PASSES. It is the check that the
# suite still notices when the two scheduling limbs are removed. Re-run it after
# any edit to either file, and treat a green mutant as a red bar.
#
# It does NOT test the deadman. test-p5-fw-deadman.sh does that. This tests the
# test, which is a different and, on this box, equally load-bearing thing.
#
# U38a: the subject moved to p5/bin/p5-deadman when the two rollback primitives
# were consolidated into one. The mutant is therefore built into a FAKE PACKAGE
# TREE ($M/bin + $M/lib + $M/contract), because the tool resolves p5-common.sh
# and the contract from its own sibling directories -- a mutant dropped in a
# bare temp dir would exit 5 on its first line and the suite would "catch" a
# mutation that never ran. The suite is pointed at it with P5_DEADMAN_BIN.
#
# COST: it runs the full suite once. On the dev PC the suite is ~75 s, most of
# it the two deliberate poll waits in DM-30..DM-33.
#
# Usage: sh deploy/server/mutant-check-p5-fw-deadman.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
P5DIR=$(cd "$HERE/../../p5" && pwd) || { printf 'no p5/ tree above %s\n' "$HERE" >&2; exit 2; }
SRC="$P5DIR/bin/p5-deadman"
SUITE="$HERE/test-p5-fw-deadman.sh"
[ -f "$SRC" ]   || { printf 'no %s\n' "$SRC" >&2; exit 2; }
[ -f "$SUITE" ] || { printf 'no %s\n' "$SUITE" >&2; exit 2; }

M=$(mktemp -d 2>/dev/null || echo "/tmp/dmmut.$$")
mkdir -p "$M/bin"
cp -R "$P5DIR/lib" "$M/lib"
cp -R "$P5DIR/contract" "$M/contract"

# MUTATION 1 -- gut do_status. It is the pre-F3 gate in docs/deploy-p5-server.md
#               and the only stated mechanism for "boot: ABSENT -- stop".
# MUTATION 2 -- delete the timer limb's spawn entirely, leaving `arm` to report
#               "armed" and exit 0 with no sleeper scheduled.
# Both are applied by awk on markers that exist in the shipped file, so this
# breaks loudly if the tool is restructured rather than silently mutating
# nothing -- a mutant-check that mutates nothing is the failure mode it exists
# to prevent, so the marker count is asserted below.
awk '
/^do_status\(\) \{$/            { instatus=1; print "do_status() {"; print "    printf '"'"'MUTANT status\\n'"'"'"; print "    return 0"; print "}"; m1++; next }
instatus && /^\}$/              { instatus=0; next }
instatus                        { next }
/^    if \[ "\$TIMER" -eq 0 \]; then$/ { intimer=1; print "    :"; m2++; next }
intimer && /^    fi$/           { intimer=0; next }
intimer                         { next }
                                { print }
END { if (m1 != 1 || m2 != 1) { printf("MUTANT-CHECK BROKEN: matched do_status=%d timer=%d, expected 1 and 1\n", m1, m2) > "/dev/stderr"; exit 3 } }
' "$SRC" > "$M/bin/p5-deadman" || { printf 'mutant construction FAILED -- the markers this script edits are gone. Fix this script.\n' >&2; rm -rf "$M"; exit 3; }
chmod +x "$M/bin/p5-deadman"
sh -n "$M/bin/p5-deadman" || { printf 'mutant is not valid shell -- fix this script, not the tool.\n' >&2; rm -rf "$M"; exit 3; }

# The mutant must actually RUN, or the suite would go red on "cannot find
# p5-common.sh" and this file would report a green mutant-check for a mutation
# that never executed a line of the tool. Assert it answers a trivial verb.
if ! P5_ROOT="$M/root" "$M/bin/p5-deadman" check >/dev/null 2>&1; then
    printf 'the mutant does not run at all (check exited %s) -- the fake package tree is wrong,\n' "$?" >&2
    printf 'so a red suite would prove nothing. Fix this script.\n' >&2
    rm -rf "$M"; exit 3
fi

printf 'mutant built in %s: do_status gutted, timer-limb spawn deleted.\n' "$M"
printf 'running the shipped suite against it. It MUST fail.\n\n'

P5_DEADMAN_BIN="$M/bin/p5-deadman" sh "$SUITE" > "$M/out.txt" 2>&1
_rc=$?
_tally=$(grep 'passed / ' "$M/out.txt" | tail -1)
printf '%s\n' "$_tally"

if [ "$_rc" -eq 0 ]; then
    printf '\nMUTANT-CHECK FAILED: the suite PASSED on a tool with two limbs deleted.\n'
    printf 'The bars are not load-bearing. Do not ship this.\n'
    rm -rf "$M"
    exit 1
fi

printf '\nwhich bars caught it:\n'
grep '^FAIL' "$M/out.txt" | sed 's/^/  /'
printf '\nMUTANT DETECTED -- MUTANT-CHECK PASSED: the suite rejects the mutant (exit %s).\n' "$_rc"
rm -rf "$M"
exit 0
