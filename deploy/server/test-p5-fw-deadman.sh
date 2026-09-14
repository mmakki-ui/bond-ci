#!/bin/sh
# shellcheck shell=sh
# test-p5-fw-deadman.sh -- executable bars for THE rollback primitive,
# p5/bin/p5-deadman.
#
# THE FILE UNDER TEST MOVED (U38a) AND THIS FILE DID NOT CHANGE ITS NAME.
# There were two rollback primitives -- deploy/server/p5-fw-deadman (this
# suite's original subject, which had the cron boot limb) and p5/bin/p5-deadman
# (E0's, whose boot limb was OPEN). They are now ONE file, p5/bin/p5-deadman,
# and the twin is deleted. This suite is retargeted at the survivor. The name
# `test-p5-fw-deadman.sh` is kept ON PURPOSE: it is the gate command named in
# docs/ROADMAP.md and docs/deploy-p5-server.md, and renaming a gate is how a
# gate stops being run. `P5_DEADMAN_BIN` overrides the subject, which is how the
# mutant-check points it at a mutant.
#
# WHY THESE EXIST. ROADMAP, STANDING CONSTRAINT: "Any claim that a failure mode
# is impossible must name the mechanism AND the test that demonstrates it.
# Assertions without tests are what have failed three consecutive reviews."
# The deadman is the mechanism the whole server procedure leans on, so it is
# the one thing in U38 that must be executed rather than reasoned about.
#
# WHAT THESE BARS DO AND DO NOT PROVE. They run the tool's real code paths
# against a temp root on the DEV PC under Git Bash. They prove the record
# format, the clock comparison, the sha gate, the pre-arm connection snapshot,
# the confirm rule (both its strict and its stated-lenient branch), the disarm,
# the DETACHED TIMER SPAWN and `status`'s limb verdicts are correct as written.
# They do NOT prove anything about busybox ash, about a real crond, about setsid
# on the box, or about the firewall. Those are the box's to answer and the
# preflight asks them.
#
# THEY ARE ALSO NOT THE WHOLE GATE ON THIS TOOL. p5/test/run.sh owns DM-1..DM-10
# over the same file -- the record, the refusals, `--remove` refusing while
# armed. Run both after touching p5/bin/p5-deadman; neither is a superset.
#
# ROUND 2 -- WHAT AN INDEPENDENT VERIFY BROKE, AND WHAT WAS ADDED BECAUSE OF IT.
#
#  1. THE SUITE WENT FULLY GREEN ON A MUTANT with `do_status` gutted to
#     `printf; return 0` and the whole detached-sleeper spawn replaced by `:`.
#     Cause: every arm passed --no-timer, so the spawn ran ZERO times, and no
#     bar ever invoked `status` -- which docs/deploy-p5-server.md makes the
#     MANDATORY pre-F3 gate and the only stated way to learn `boot: ABSENT`.
#     Two of the tool's three limbs had no test. DM-30..DM-33 exercise the
#     timer spawn for real (nobody calls `check`); DM-34..DM-41 exercise every
#     branch of `status`, including the crond-absent verdict, by putting a
#     controlled `ps` on PATH so the shipped grep runs unchanged.
#
#  2. NO BAR ASSERTED arm's SUCCESS EXIT STATUS -- only its five refusals --
#     and every arm discarded stderr. So a transient failure to place a record
#     was invisible until a downstream bar tripped with no diagnostic. That is
#     exactly what one run in nine did on this PC (DM-26/DM-27 failing with
#     `fire` exit 5). `arm_ok` now asserts exit 0 AND the record's presence at
#     every arm site and KEEPS arm's stderr for the failure message.
#
#  3. `confirm`'s refusal did not test what the doc claimed. It compared
#     SSH_CONNECTION 1:2, so it proved "a different 4-tuple" -- and Gate M
#     REQUIRES a second management session to be open before the change, which
#     has a different client port and would have confirmed. DM-46..DM-51 cover
#     the pre-arm connection snapshot that closes it, both fail-closed paths,
#     and the attack itself.
#
# HOW THE BOX IS FAKED, and why that is still a real test: `netstat`, `ss` and
# `ps` are shimmed onto PATH as scripts that print a table this file controls.
# The tool's own parsing, its grep patterns and its exit-status handling all run
# unmodified -- only the kernel's answer is supplied. Nothing in the tool knows
# it is under test; there is no test-only branch in the shipped code.
#
# NON-DETERMINISM, ON THE RECORD: an independent verifier measured 32/2 on one
# run in nine of the PRE-ROUND-2 suite, root cause not established. Any claim
# about this suite's pass count MUST carry the number of runs it was measured
# over. See docs/deploy-p5-server.md s1.
#
# ROUND 3 (U130) -- A FIRED DEADMAN NOW LEAVES NOTHING BEHIND. Before this
# round, only `confirm` called boot_limb_remove_if_last; `fire` and `check`
# left the every-minute crontab line running against a binary the next
# uninstall would delete (O15). DM-52a/b USED TO PIN that as a known defect --
# they are now inverted to assert the fix, and DM-56/DM-56a/DM-57/DM-57a cover
# the same removal reached through `check`, which is the path that actually
# matters (the boot limb calls `check`, never `fire`). The separate pre-arm
# backup file (CRONPRE, `${CRONTAB}.p5-pre`) is also gone -- it lived outside
# p5's own contract namespace (p5/contract/namespace:69-80) and DM-10a/DM-57a
# now assert its ABSENCE instead of its presence. "did the crontab exist
# before this arm" moved onto the armed record as P5_DM_CRON_PREEXISTED
# (DM-51b), and disarm strips the marked line instead of restoring a copy --
# DM-25c/DM-52b/DM-57 prove that is still byte-exact when the crontab already
# ended in a newline; DM-60/DM-60a cover the case where it did not, which
# install now guards against gluing our line onto the operator's last one.
# `arm`'s exit status was unchanged by any of that round -- plain 0 whether or
# not the boot limb installed (DM-45) -- because run.sh's DM-1, not owned by
# this suite, hard-required it. ROUND 4 (U290) REVERSES THAT; see below.
#
# ROUND 2 FIX (U130 fix round) -- TWO ADVERSARIAL-LENS DEFECTS IN THE ROUND-3
# BUILD, both from CRONMARK being matched as an unanchored substring instead
# of the exact appended line: (1) an operator crontab line that happens to
# CONTAIN "# p5-deadman" made boot_limb_install think the limb was already in
# place and skip installing the real one -- `arm` reported success with the
# boot limb silently absent (DM-58/DM-58a cover this); (2) that same
# unanchored match made boot_limb_remove_if_last delete the WHOLE operator
# line on removal, not just p5's -- fixed by matching CRONLINE (the exact
# literal line p5 appends) with grep -qxF/-vxF instead of CRONMARK as a bare
# substring. (3) a crontab with no trailing newline lost its last line
# entirely on removal, because `>>` glued p5's line onto it and the merged
# line then matched and was stripped whole -- fixed by inserting a separating
# newline before appending when the file does not already end in one
# (DM-60/DM-60a).
#
# ROUND 3 FIX (U130 second fix round) -- TWO MORE FROM THE SAME ADJUDICATOR
# PASS: (4) do_status's OWN boot-limb check still used `grep -q "$CRONMARK"`,
# an unanchored substring test, even after (1)/(2) above anchored install and
# removal -- a look-alike-only crontab (real CRONLINE never installed) made
# `status` claim `boot: LIVE`, the exact string O14 calls the pre-F3 gate;
# fixed by matching CRONLINE with grep -qxF like everywhere else (DM-61/
# DM-61a). (5) boot_limb_remove_if_last's `grep > tmp; mv tmp "$CRONTAB"`
# replaces the destination inode, so the temp file's own mode landed on
# $CRONTAB -- root's real, shared crontab -- instead of the mode it had
# before; removal now reads mode/uid/gid with `stat -c` (busybox has %a/%u/%g
# and no GNU `chmod --reference`) and stamps them onto the temp file BEFORE
# the mv, so the destination is never observable at the wrong mode even for
# an instant (DM-62/DM-62a/DM-62b).
#
# ROUND 4 (U290) -- ARM IS FAIL-CLOSED ON THE BOOT LIMB, AND DM-45 IS INVERTED.
# `arm` wrote its record and reported ARMED whether or not the boot limb went in
# (`boot_limb_install || true`); boot_limb_install checked only that the crontab
# DIRECTORY existed, never that crond was RUNNING; and the crontab line names
# $SELF verbatim with nothing checking that $SELF survives a reboot -- an arm run
# from the unpacked package under /tmp wrote a line naming a tmpfs path. arm now
# REFUSES (exit 5, no record, nothing created) unless crond is running, the
# crontab directory is writable and $SELF is under $P5_SBIN; `--no-boot-limb` is
# the only override and says so. DM-45/DM-45a/DM-45b are INVERTED -- they pinned
# the old behaviour on the adjudication in docs/deploy-p5-server.md O14, which
# this round reverses and amends -- and DM-45c..DM-45f, DM-63..DM-63c,
# DM-65..DM-65b, DM-66..DM-66b, DM-67, DM-68..DM-68c, DM-69 and DM-70..DM-70f
# are new.
#
# THE FIX ROUND'S THREE (DM-68, DM-69, DM-70) MEASURE WHAT THE GATE ABOVE STILL
# COULD NOT SEE. boot_limb_ready answers three questions ABOUT THE BOX; none of
# them is "did the write land" (DM-68: both appends discarded their exit status,
# so arm printed ARMED over a crontab with no line in it), none of them notices
# that the file they all passed against is not the one crond reads (DM-69: an
# INHERITED P5_CRONTAB, which this suite and the ecosim portal both export), and
# none of them distinguishes crond RUNNING NOW from cron ENABLED AT BOOT (DM-70:
# the limb exists to survive a reboot, and a hand-started crond does not).
#
# THE FAKE BOX NOW HAS A FAKE /usr/sbin, and it has to. The $SELF condition is
# rooted ("${P5_ROOT}/usr/sbin"), like $P5_CRONTAB and $P5_DEADDIR already were,
# so `use_root` INSTALLS the subject at $P5_ROOT/usr/sbin/p5-deadman with
# p5-common.sh and the contract copies at $P5_ROOT/usr/lib/p5 beside it -- which
# is the resolution order the tool documents at p5/bin/p5-deadman:137-157 and the
# one a real box uses. P5_DEADMAN_BIN still selects the SOURCE, so the
# mutant-check still points this suite at its mutant.
#
# WHAT IS ENFORCED BUT NOT SEEDED: the "writable" half of the crontab-directory
# condition. A suite that may be run as root cannot seed "not writable"
# deterministically -- root writes it anyway -- so the bars seed the ABSENT
# directory (DM-45) and the code carries the writability test unbarred. Said
# here rather than left to be assumed covered.
#
# Usage: sh deploy/server/test-p5-fw-deadman.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# THE SOURCE of the subject, which is not where it is RUN from any more: use_root
# installs a copy into each fake root's /usr/sbin and points $DM at that (U290).
DM_SRC="${P5_DEADMAN_BIN:-$HERE/../../p5/bin/p5-deadman}"
[ -f "$DM_SRC" ] || { printf 'no tool at %s\n' "$DM_SRC" >&2; exit 2; }
P5SRC=$(cd "$HERE/../../p5" && pwd) || { printf 'no p5/ tree above %s\n' "$HERE" >&2; exit 2; }
T=$(mktemp -d 2>/dev/null || echo "/tmp/dmtest.$$")
mkdir -p "$T/crontabs" "$T/bin"

# The tool roots every path it touches under $P5_ROOT, so the whole test lives
# in a fake box. The record directory is $P5_ROOT/etc/p5/deadman -- named by
# p5-common.sh, not by this file, so a change to the layout is a red here rather
# than a silent miss.
# THE FAKE BOX IS NOW INSTALLED, not just rooted (U290). arm refuses unless the
# resolved $SELF is under $P5_SBIN -- "${P5_ROOT}/usr/sbin" -- so a fake root
# that has no /usr/sbin cannot arm at all, and every boot-limb bar in this file
# would be measuring the refusal instead of the limb. The library and the
# contract copies go to $P5_ROOT/usr/lib/p5 because that is where the tool looks
# when there is no sibling ../lib, which is exactly the on-box case
# (p5/bin/p5-deadman:137-157). Nothing about the subject is modified: it is the
# same bytes as $DM_SRC, so P5_DEADMAN_BIN still selects a mutant when the
# mutant-check sets it.
use_root() {
    P5_ROOT="$1"; export P5_ROOT
    mkdir -p "$P5_ROOT/etc/p5/deadman" "$P5_ROOT/usr/sbin" "$P5_ROOT/usr/lib/p5"
    DMDIR="$P5_ROOT/etc/p5/deadman"
    cp "$DM_SRC" "$P5_ROOT/usr/sbin/p5-deadman"
    chmod +x "$P5_ROOT/usr/sbin/p5-deadman"
    cp "$P5SRC/lib/p5-common.sh" "$P5_ROOT/usr/lib/p5/p5-common.sh"
    for _ur_c in namespace foreign paths; do
        cp "$P5SRC/contract/$_ur_c" "$P5_ROOT/usr/lib/p5/contract-$_ur_c" 2>/dev/null || true
    done
    DM="$P5_ROOT/usr/sbin/p5-deadman"
}
use_root "$T/root"
P5_CRONTAB="$T/crontabs/root"; export P5_CRONTAB
# Seed a PRE-EXISTING crontab. The deadman appends to somebody else's file, so
# "restored byte-exact" has to be tested against a file that had content, not
# against an empty one -- an empty-file test would pass for a tool that simply
# truncates.
printf '0 4 * * * /usr/bin/somebody-elses-job\n#keep me\n' > "$P5_CRONTAB"
cp "$P5_CRONTAB" "$T/crontab.golden"
# Where the tool parks its byte-exact copy of that file: NEXT TO IT, never in
# the record directory, because p5_deadman_armed counts every file there as an
# armed record and a backup parked there would wedge `p5-uninstall --remove`.
CRONPRE="$P5_CRONTAB.p5-pre"

# BAR-COUNT RATCHET. A pass count with no floor cannot tell "everything passed"
# from "half the bars stopped being reached". U46 exists in this project because
# `recon-model` checked exit status and nothing else, so a silently dropped bar
# stayed green; the round-1 form of THIS file went fully green on a tool with
# two limbs deleted. Raise this when bars are added; a drop is a RED, not a tidy.
BARS_MIN=141

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# EVERY ASSERTED INVOCATION KEEPS ITS STDERR AND THE STATE THAT PRODUCED IT.
# The pre-round-2 suite threw both away with `>/dev/null 2>&1`, so a transient
# failure arrived as a bare exit code with nothing to diagnose it -- which is
# exactly how the 1-in-9 flake an independent verifier measured stayed
# un-root-caused. runv/chkv exist so the NEXT occurrence carries its evidence.
runv() { _verr=$("$DM" "$@" 2>&1 >/dev/null); _vrc=$?; }
dump_state() {
    printf '        record-dir: %s\n' "$(ls -a "$DMDIR" 2>/dev/null | tr '\n' ' ')"
    for _dr in "$DMDIR"/*; do
        [ -f "$_dr" ] || continue
        printf '        %s = %s\n' "$_dr" "$(tr '\n' '|' < "$_dr")"
    done
}
chkv() {
    if [ "$_vrc" = "$2" ]; then ok "$1"
    else bad "$1 (got '$_vrc', want '$2') stderr<<$_verr>>"; dump_state; fi
}
has()  { if printf '%s' "$2" | grep -q "$3"; then ok "$1"; else bad "$1 (output had no /$3/: <<$2>>)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -q "$3"; then bad "$1 (output DID contain /$3/: <<$2>>)"; else ok "$1"; fi; }

# ------------------------------------------------------------- box shims --
# A busybox-format `netstat -tn` table that this file controls. `ss` is shimmed
# to fail so the netstat branch is the one exercised -- which is what the server
# actually has (its inventory's listener blocks are netstat-formatted:
# server inventory:12-13,29-30, `Active Internet connections` + `Proto Recv-Q`).
cat > "$T/bin/netstat" <<EOF
#!/bin/sh
cat "$T/netstat.out"
EOF
cat > "$T/bin/ss" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$T/bin/ps" <<EOF
#!/bin/sh
cat "$T/ps.out"
EOF
chmod +x "$T/bin/netstat" "$T/bin/ss" "$T/bin/ps"
PATH="$T/bin:$PATH"; export PATH

netstat_reset() {
    printf 'Active Internet connections (w/o servers)\n' >  "$T/netstat.out"
    printf 'Proto Recv-Q Send-Q Local Address Foreign Address State\n' >> "$T/netstat.out"
}
# open_session PORT -- the box now has this connection established.
open_session() { printf 'tcp 0 0 10.0.0.1:22 10.0.0.9:%s ESTABLISHED\n' "$1" >> "$T/netstat.out"; }
# use_session PORT -- and we are now talking over it.
use_session()  { SSH_CONNECTION="10.0.0.9 $1 10.0.0.1 22"; export SSH_CONNECTION; }
# crond_running yes|no
crond_running() {
    if [ "$1" = yes ]; then printf '  711 root      1234 S    /usr/sbin/crond -f -c /etc/crontabs -l 5\n' > "$T/ps.out"
    else                    printf '  711 root      1234 S    /sbin/procd\n' > "$T/ps.out"; fi
}
netstat_reset; crond_running yes

# mkstubs DIR name... -- absolute-exec wrappers, so a command stays reachable
# with PATH stripped down to DIR alone. Used to prove the ABSENT branches.
# The list is deliberately generous: these bars are about netstat/ss and
# setsid/nohup being absent, so anything else the tool or p5-common.sh reaches
# for must stay present or the bar would pass for the wrong reason.
mkstubs() {
    _d="$1"; shift; mkdir -p "$_d"
    for _c in "$@"; do
        _p=$(command -v "$_c" 2>/dev/null) || continue
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$_p" > "$_d/$_c"
        chmod +x "$_d/$_c"
    done
}
# `cut` and `head` are in the list because p5-common.sh's p5_hash and
# p5_deadman_field use them; leaving them out made DM-49 "pass" by failing arm
# for a reason that had nothing to do with netstat. A stub list is part of the
# bar: if it is short, the bar measures the stub list instead of the tool.
BASETOOLS="sh date sha256sum awk cut mkdir mv rm cp grep head sync readlink sort tr basename dirname cat sed printf ls ps"

# a restore script that leaves a trace so "did it actually run" is observable
cat > "$T/restore.sh" <<EOF
#!/bin/sh
echo ran >> "$T/restore.ran"
EOF
chmod +x "$T/restore.sh"

# arm_ok BAR LABEL AFTER [extra args...]
# THE BAR THAT WAS MISSING. Asserts arm's SUCCESS exit status and that the
# record actually landed, and keeps arm's stderr so the next transient failure
# is diagnosed at the arm instead of surfacing as an unexplained exit 5 three
# bars later.
arm_ok() {
    _bar="$1"; _lbl="$2"; _aft="$3"; shift 3
    _err=$("$DM" arm --after "$_aft" --restore-script "$T/restore.sh" --label "$_lbl" "$@" 2>&1 >/dev/null)
    _rc=$?
    if [ -f "$DMDIR/$_lbl" ]; then _st=present; else _st=MISSING; fi
    if [ "$_rc" -eq 0 ] && [ "$_st" = present ]; then
        ok "$_bar arm --label $_lbl exits 0 AND places its record"
    else
        bad "$_bar arm --label $_lbl (exit=$_rc record=$_st) stderr<<$_err>>"
    fi
}

# ---------------------------------------------------------------- DM-1..2 --
# arm has no defaults. --after in particular: how long an operator needs to
# prove reachability is not derivable, so it is never invented.
use_session 41000; open_session 41000
runv arm --restore-script "$T/restore.sh"
chkv "DM-1 arm without --after refuses (usage)" "2"

runv arm --after 60
chkv "DM-2 arm without any --restore refuses (usage)" "2"

# --after 0 IS ACCEPTED, and this bar changed direction in U38a. It used to
# assert a refusal. p5/test/run.sh:DM-4 -- which this suite does not own and
# must not break -- arms `--after 0` on purpose, because a deadline of `now` is
# what makes the firing path deterministic instead of a race against a sleep.
# The refusal bought nothing: a zero window is ALREADY past its deadline, so the
# next check ROLLS THE BOX BACK, which is the safe direction. What is asserted
# instead is that it is never silent.
_err=$("$DM" arm --after 0 --restore-script "$T/restore.sh" --label zero --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-3 arm accepts --after 0 (already past its deadline: the SAFE direction)" "$_rc" "0"
has "DM-3a ...and says so loudly rather than arming a zero window silently" "$_err" 'ALREADY past its deadline'
rm -f "$DMDIR/zero"

runv arm --after abc --restore-script "$T/restore.sh"
chkv "DM-4 arm rejects non-numeric --after" "2"

echo x > "$T/notexec.sh"
runv arm --after 60 --restore-script "$T/notexec.sh"
chkv "DM-5 arm rejects a non-executable restore (precondition)" "5"

# The two restore forms are ALTERNATIVES. Accepting both would leave a record
# with two rollbacks in it and no stated rule for which one runs -- which is the
# U38a defect (two implementations of a rollback) reproduced inside one record.
runv arm --after 60 --restore "true" --restore-script "$T/restore.sh"
chkv "DM-5a --restore and --restore-script together is a usage error, not a merge" "2"

# ------------------------------------------------------------------ DM-6 --
# The record is an ABSOLUTE deadline on persistent storage, so firing is a pure
# function of (record, clock) and the timer/boot/human limbs share it.
arm_ok "DM-A1" fwtest 3600 --no-timer
R="$DMDIR/fwtest"
if [ -f "$R" ]; then ok "DM-6 arm writes the record"; else bad "DM-6 arm writes the record"; fi
if grep -q '^P5_DM_DEADLINE=[0-9][0-9]*$' "$R"; then ok "DM-7 record carries an absolute epoch deadline"; else bad "DM-7 record carries an absolute epoch deadline"; fi
if grep -q "^P5_DM_SESSION=10.0.0.9:41000$" "$R"; then ok "DM-8 record pins the ARMING session id"; else bad "DM-8 record pins the arming session id"; fi
if grep -q '^P5_DM_SHA=[0-9a-f][0-9a-f]*$' "$R"; then ok "DM-9 record pins the restore script sha"; else bad "DM-9 record pins the restore sha"; fi
if grep -q "^P5_DM_PRESNAP=ok$" "$R"; then ok "DM-51 record pins a VALIDATED pre-arm connection snapshot"; else bad "DM-51 P5_DM_PRESNAP is not ok: $(grep P5_DM_PRESNAP "$R")"; fi
if grep -q "^P5_DM_PRE_SESSIONS=.*10.0.0.9:41000" "$R"; then ok "DM-51a the snapshot contains the arming connection"; else bad "DM-51a snapshot missing the arming connection: $(grep P5_DM_PRE_SESSIONS "$R")"; fi
if grep -q "^P5_DM_CRON_PREEXISTED=yes$" "$R"; then ok "DM-51b record states the crontab existed before this arm (P5_DM_CRON_PREEXISTED)"; else bad "DM-51b P5_DM_CRON_PREEXISTED not yes: $(grep P5_DM_CRON_PREEXISTED "$R")"; fi

# ------------------------------------------------------------------ DM-10 --
# The boot limb is installed. U130: there is no separate pre-arm backup file
# any more (CRONPRE, eliminated) -- "did the crontab exist before" is a record
# field (DM-51b above) and disarm STRIPS the marked line instead (DM-25c,
# DM-52b below prove that is still byte-exact).
if grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-10 boot limb: crontab line installed"; else bad "DM-10 boot limb: crontab line installed"; fi
if [ ! -f "$CRONPRE" ]; then ok "DM-10a no sibling backup file at ${P5_CRONTAB}.p5-pre -- CRONPRE is eliminated (U130), outside the contract namespace"; else bad "DM-10a $CRONPRE exists -- CRONPRE was supposed to be gone"; fi

# ------------------------------------------------------------------ DM-11 --
# Before the deadline, check must NOT fire. A deadman that fires early is a
# deadman that takes the box down on a healthy deploy.
runv check
chkv "DM-11 check before the deadline does not fire" "0"
if [ ! -f "$T/restore.ran" ]; then ok "DM-12 restore did NOT run before the deadline"; else bad "DM-12 restore ran early"; fi

# ------------------------------------------------------------------ DM-13 --
# confirm from the ARMING session is refused. An established TCP session
# survives the removal of the rule that admitted it (conntrack ESTABLISHED), so
# confirming from it proves the box was reachable, not that it is.
runv confirm --label fwtest
chkv "DM-13 confirm from the ARMING session is REFUSED" "5"
if [ -f "$R" ]; then ok "DM-14 a refused confirm leaves the record armed"; else bad "DM-14 refused confirm disarmed anyway"; fi

# no ssh session at all is also refused FOR A RECORD ARMED OVER SSH -- it cannot
# be distinguished from the arming one, and 'cannot distinguish' must fail
# closed on this box.
( unset SSH_CONNECTION; "$DM" confirm --label fwtest >/dev/null 2>&1 )
chk "DM-15 confirm outside ssh is REFUSED for an ssh-armed record" "$?" "5"
if [ -f "$R" ]; then ok "DM-16 still armed after the non-ssh refusal"; else bad "DM-16 disarmed by a non-ssh confirm"; fi

# --------------------------------------------------------- DM-46..DM-48 --
# THE ATTACK THE OLD REFUSAL DID NOT STOP, and it is not hypothetical: Gate M
# (docs/deploy-p5-server.md) REQUIRES a second independent management path to be
# established and proven BEFORE step 1. That session has a different client
# port, so the 4-tuple comparison lets it through -- and it survives the reload
# through conntrack ESTABLISHED exactly like the arming one, so it proves
# nothing. The pre-arm snapshot is what makes it exit 5.
open_session 41900          # the Gate M session, opened BEFORE the arm below
use_session  41901; open_session 41901
arm_ok "DM-A2" gatem 3600 --no-timer
use_session 41900           # ...now confirm over that pre-existing session
runv confirm --label gatem
chkv "DM-46 confirm over a session that PREDATES the arm is REFUSED" "5"
if [ -f "$DMDIR/gatem" ]; then ok "DM-47 that refusal left the record armed"; else bad "DM-47 a pre-existing session disarmed the deadman"; fi
use_session 41902; open_session 41902   # a connection that did not exist at arm
runv confirm --label gatem
chkv "DM-48 confirm over a connection opened AFTER the arm succeeds" "0"

# --------------------------------------------------------- DM-49..DM-50 --
# Both ways the snapshot can be worthless must FAIL CLOSED. This box has no
# console; "cannot tell a new connection from an old one" is not a green.
#   DM-49: no working netstat and no working ss at all.
#   DM-50: a tool that answers, in a format this parser does not recognise --
#          caught at ARM time by the snapshot not containing our own connection.
# shellcheck disable=SC2086
mkstubs "$T/nonet" $BASETOOLS
use_session 41910; open_session 41910
( PATH="$T/nonet"; export PATH; "$DM" arm --after 3600 --restore-script "$T/restore.sh" --label nosnap --no-timer >/dev/null 2>&1 )
if grep -q '^P5_DM_PRESNAP=none$' "$DMDIR/nosnap" 2>/dev/null; then ok "DM-49 no netstat and no ss -> P5_DM_PRESNAP=none, recorded not guessed"; else bad "DM-49 P5_DM_PRESNAP not none: $(grep P5_DM_PRESNAP "$DMDIR/nosnap" 2>/dev/null)"; fi
use_session 41911
runv confirm --label nosnap
chkv "DM-49a confirm REFUSES when there was no snapshot (fails closed)" "5"

printf 'some other tool entirely\nno addresses here\n' > "$T/netstat.out"
use_session 41920
"$DM" arm --after 3600 --restore-script "$T/restore.sh" --label badsnap --no-timer >/dev/null 2>&1
if grep -q '^P5_DM_PRESNAP=untrusted$' "$DMDIR/badsnap" 2>/dev/null; then ok "DM-50 a snapshot that lacks our OWN connection is marked untrusted"; else bad "DM-50 P5_DM_PRESNAP not untrusted: $(grep P5_DM_PRESNAP "$DMDIR/badsnap" 2>/dev/null)"; fi
use_session 41921
runv confirm --label badsnap
chkv "DM-50a confirm REFUSES on an untrusted snapshot (fails closed)" "5"
rm -f "$DMDIR/nosnap" "$DMDIR/badsnap"
netstat_reset; use_session 41000; open_session 41000

# ------------------------------------------------------------------ DM-17 --
# A tampered or truncated restore script must not run. A rollback that runs
# something other than what was reviewed is worse than no rollback.
cp "$T/restore.sh" "$T/restore.orig"
printf '\n# tampered\n' >> "$T/restore.sh"
_t=$(date +%s); _past=$((_t - 10))
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$_past/" "$R" > "$R.tmp" && mv "$R.tmp" "$R"
runv check
chkv "DM-17 check refuses a restore whose sha changed (still exits fired)" "1"
if [ ! -f "$T/restore.ran" ]; then ok "DM-18 the TAMPERED restore did not execute"; else bad "DM-18 tampered restore executed"; fi
# FAIL CLOSED, and this bar was added because the suite caught the tool doing
# the right thing for a reason nobody had written down. A record whose restore
# fails its integrity check has NOT rolled back, so it must stay ARMED and keep
# failing loudly on every check -- not be quietly retired as though the rollback
# had happened. That is the difference between a deadman that has given up and
# one that is still asking for help.
if [ -f "$R" ]; then ok "DM-18a a record whose restore failed integrity STAYS ARMED"; else bad "DM-18a record retired despite no rollback"; fi
# ...and nothing else is left in the record directory. This is not tidiness:
# p5-common.sh's p5_deadman_armed counts EVERY file under $P5_DEADDIR as an
# armed record, so a tombstone or a stray backup parked there would make
# `p5-uninstall --remove` refuse for ever (p5/test/run.sh DM-8/DM-9).
_left=$(ls "$DMDIR" 2>/dev/null | tr '\n' ' ')
chk "DM-18b the record dir holds ONLY armed records -- no tombstone, no backup" "$_left" "fwtest "
cp "$T/restore.orig" "$T/restore.sh"; chmod +x "$T/restore.sh"

# ------------------------------------------------------------------ DM-19 --
# Past deadline, intact restore: it fires. This bar covers the FIRING half that
# all three limbs share. It does NOT cover their SCHEDULING -- DM-30..DM-33 and
# DM-34..DM-41 do, and this file went fully green on a mutant without them.
use_session 41001; open_session 41001
arm_ok "DM-A3" fwtest2 3600 --no-timer
R2="$DMDIR/fwtest2"
_t=$(date +%s); _past=$((_t - 10))
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$_past/" "$R2" > "$R2.tmp" && mv "$R2.tmp" "$R2"
runv check
chkv "DM-19 check AFTER the deadline fires (exit 1)" "1"
if [ -f "$T/restore.ran" ]; then ok "DM-20 the restore actually executed"; else bad "DM-20 restore did not execute"; fi
if [ ! -f "$R2" ]; then ok "DM-21 a record that fired successfully is REMOVED, not left behind"; else bad "DM-21 record still present after a successful rollback"; fi

# ------------------------------------------------------------------ DM-22 --
# Idempotent / safe to interrupt and retry: a second check must not re-run a
# rollback that already ran.
_n1=$(wc -l < "$T/restore.ran")
"$DM" check >/dev/null 2>&1
_n2=$(wc -l < "$T/restore.ran")
chk "DM-22 a second check does NOT re-fire a spent record" "$_n1" "$_n2"

# ------------------------------------------------------------------ DM-23 --
# confirm from a NEWER connection succeeds and disarms, and the crontab is
# restored byte-exact once the last record is gone.
# Arm TWO records so the "last one out" rule is actually exercised: confirming
# one must NOT drop the boot limb while the other is still live.
use_session 41002; open_session 41002
arm_ok "DM-A4" fwtest3 3600 --no-timer
arm_ok "DM-A5" fwtest5 3600 --no-timer
use_session 41003; open_session 41003
runv confirm --label fwtest3
chkv "DM-23 confirm from a NEW session succeeds" "0"
if [ ! -f "$DMDIR/fwtest3" ]; then ok "DM-24 confirm removed the record"; else bad "DM-24 record survived confirm"; fi
if grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-25 boot limb KEPT while another record is still armed"; else bad "DM-25 boot limb dropped while fwtest5 was still armed"; fi

# ------------------------------------------------------------------ DM-25a --
# ...and removed, restoring the crontab byte-exact, only once the LAST record
# is gone. Byte-exact matters: that file is somebody else's.
runv confirm --label fwtest5
chkv "DM-25a the last record can be confirmed away" "0"
if ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-25b boot limb removed once NOTHING is armed"; else bad "DM-25b crontab line left behind"; fi
if cmp -s "$P5_CRONTAB" "$T/crontab.golden"; then ok "DM-25c crontab restored BYTE-EXACT to its pre-arm content"; else bad "DM-25c crontab not byte-exact: $(cat "$P5_CRONTAB")"; fi

# ------------------------------------------------------------------ DM-26 --
# fire is the human limb of the same code path.
use_session 41004; open_session 41004
rm -f "$T/restore.ran"
arm_ok "DM-A6" fwtest4 3600 --no-timer
runv fire --label fwtest4
chkv "DM-26 fire runs the rollback now (exit 1: a rollback RAN)" "1"
if [ -f "$T/restore.ran" ]; then ok "DM-27 fire executed the restore"; else bad "DM-27 fire did not execute the restore"; fi

# ------------------------------------------------------------ DM-52a/b --
# O15 FIXED (U130). `fire` and `check` now call boot_limb_remove_if_last
# through the shared fire_one(), exactly like `confirm` always did, so the
# every-minute crontab line is gone once nothing remains armed instead of
# self-healing on the NEXT arm+confirm cycle. INVERTED from the pre-U130 form
# of these two bars, which pinned the defect on purpose; a regression back to
# the old behaviour must go red here, not silently pass.
if ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-52a after fire the boot limb IS removed (O15 fixed: fire -> fire_one -> boot_limb_remove_if_last)"; else bad "DM-52a boot limb still installed after fire -- O15 regressed"; fi
if cmp -s "$P5_CRONTAB" "$T/crontab.golden"; then ok "DM-52b ...and the crontab is restored byte-exact (stripped, not backed up -- CRONPRE is gone)"; else bad "DM-52b crontab not byte-exact after fire: $(cat "$P5_CRONTAB")"; fi

# ------------------------------------------------------------------ DM-28 --
runv fire --label nosuchlabel
chkv "DM-28 fire on an unarmed label fails closed (precondition)" "5"
runv bogusverb
chkv "DM-29 an unknown verb fails closed (usage)" "2"

# ------------------------------------------------------------ DM-42..DM-44 --
# Two failures that were SILENT, on a box nobody can reach.
#  DM-42: run_restore reported `exit $?` AFTER `_r=1`, so a failed rollback
#         always printed "exit 0" -- the one line an operator gets.
#  DM-43/44: a corrupt or truncated record was skipped by `check` with no log,
#         on every run, forever. The tool's own header names "a deadman that
#         cannot fire" as the thing it exists to prevent.
cat > "$T/restore_fails.sh" <<'EOF'
#!/bin/sh
exit 37
EOF
chmod +x "$T/restore_fails.sh"
use_session 41005; open_session 41005
"$DM" arm --after 3600 --restore-script "$T/restore_fails.sh" --label failing --no-timer >/dev/null 2>&1
_out=$("$DM" fire --label failing 2>&1)
has "DM-42 a failed rollback reports its REAL exit status" "$_out" 'exit 37'
if [ -f "$DMDIR/failing" ]; then ok "DM-42a ...and a failed rollback KEEPS the record armed, so the next check retries"; else bad "DM-42a a failed rollback dropped the record"; fi
rm -f "$DMDIR/failing"

printf 'P5_DM_LABEL=corrupt\nP5_DM_DEAD' > "$DMDIR/corrupt"
_out=$("$DM" check 2>&1); _rc=$?
has "DM-43 check SAYS a record with no rollback in it can never fire" "$_out" 'CAN NEVER FIRE'
chk "DM-43a check does not report success when a record is unfireable" "$_rc" "5"
_out=$("$DM" status 2>&1)
has "DM-44 status flags the unreadable record instead of dying on it" "$_out" 'UNREADABLE'
rm -f "$DMDIR"/* 2>/dev/null

# ------------------------------------------------------------ DM-34..DM-41 --
# `status` IS THE PRE-F3 GATE. docs/deploy-p5-server.md makes it the mandatory
# check before the one firewall step that can lock the operator out, and its
# `boot: ABSENT` line is the ONLY stated mechanism for "crond is not running,
# stop". Before round 2 no bar invoked this verb at all, so gutting it to
# `printf; return 0` left the suite fully green.
use_root "$T/root2"
P5_CRONTAB="$T/crontabs2/root"; export P5_CRONTAB; mkdir -p "$T/crontabs2"
CRONPRE="$P5_CRONTAB.p5-pre"

_out=$("$DM" status 2>&1)
has "DM-34 status on an empty record dir says nothing is armed" "$_out" 'nothing armed'

crond_running yes
use_session 41100; netstat_reset; open_session 41100
_out=$("$DM" status 2>&1)
has "DM-38 status: crond up but no crontab line -> says arm installs it" "$_out" 'boot:  crond running but NO crontab line'
has "DM-38a ...and names the gap in the words the E0 contract uses" "$_out" 'boot limb is not wired yet'

arm_ok "DM-A7" stat1 3600 --no-timer
_out=$("$DM" status 2>&1)
has "DM-35 status lists the armed record with its label and deadline" "$_out" 'label=stat1 deadline=[0-9]'
has "DM-35a status reports the snapshot state of each record" "$_out" 'presnap=ok'
hasnt "DM-36 status does NOT claim a live deadline has passed" "$_out" 'DEADLINE PASSED'
has "DM-37 status: crond running + line installed -> boot LIVE" "$_out" 'boot:  LIVE'
has "DM-40 status: setsid/nohup present -> timer available" "$_out" 'timer: available'

_t=$(date +%s); _past=$((_t - 10))
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$_past/" "$DMDIR/stat1" > "$DMDIR/x" && mv "$DMDIR/x" "$DMDIR/stat1"
_out=$("$DM" status 2>&1)
has "DM-36a status FLAGS a record whose deadline has passed" "$_out" 'DEADLINE PASSED'

# THE GATE ITSELF: no crond -> the power-cut limb is dead and status must say so.
crond_running no
_out=$("$DM" status 2>&1)
has "DM-39 status: crond NOT running -> boot ABSENT, the pre-F3 stop condition" "$_out" 'boot:  ABSENT'
has "DM-39a ...and says the boot limb is not wired yet on this box" "$_out" 'boot limb is not wired yet'
crond_running yes

# ...and the timer limb's own ABSENT branch, with PATH stripped to a set that
# has neither setsid nor nohup. `ps` is still reachable so the boot verdict is
# unaffected -- the two limbs are reported independently.
# shellcheck disable=SC2086
mkstubs "$T/nodetach" $BASETOOLS
cp "$T/bin/ps" "$T/nodetach/ps"
_out=$( PATH="$T/nodetach"; export PATH; "$DM" status 2>&1 )
has "DM-41 status: no setsid and no nohup -> timer ABSENT" "$_out" 'timer: ABSENT'
has "DM-41a and the boot verdict is still reported independently" "$_out" 'boot: '

# ------------------------------------------------------------ DM-53..DM-55 --
# THE CONSOLIDATION ITSELF (U38a). The surviving tool carries BOTH restore
# forms, because p5/test/run.sh's DM-1..DM-10 drive `--restore CMD` and the
# server procedure drives `--restore-script`. One firing path, two ways to say
# what to run: exercise the one this suite otherwise never touches.
use_root "$T/root3"
rm -f "$T/cmd.ran"
use_session 41500; netstat_reset; open_session 41500
_err=$("$DM" arm --after 0 --restore "echo ran >> \"$T/cmd.ran\"" --label cmdform --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-53 arm accepts the --restore CMD form (E0's, p5/test/run.sh drives it)" "$_rc" "0"
runv check
chkv "DM-53a check fires a --restore CMD record (exit 1)" "1"
if [ -f "$T/cmd.ran" ]; then ok "DM-54 the recorded COMMAND actually ran"; else bad "DM-54 the command form did not execute"; fi
if [ ! -f "$DMDIR/cmdform" ]; then ok "DM-54a ...and its record was removed like any other"; else bad "DM-54a command-form record left behind"; fi

# The CONFIRM RULE'S OTHER BRANCH, stated in the tool's header and until now
# untested: a record armed with NO ssh session has no connection that could
# false-green through conntrack, so confirm disarms it -- and SAYS which rule it
# applied. p5/test/run.sh:DM-5 depends on this branch (its harness is not an ssh
# session), so an unstated version of it would be a silent coupling between two
# suites. It is stated here instead.
unset SSH_CONNECTION
# Captured as 2>&1, not stderr alone: this message is an operator NOTE and goes
# through p5_log, which writes to stdout. Reading only stderr here made the bar
# red against a tool that was saying exactly the right thing.
_out=$("$DM" arm --after 3600 --restore "true" --label nossh --no-timer 2>&1)
has "DM-55 arm outside ssh SAYS the strict confirm rule will not apply" "$_out" 'armed OUTSIDE an ssh session'
_out=$("$DM" status 2>&1)
has "DM-55a status prints that rule per record, so it is never a surprise" "$_out" 'armed outside ssh'
_out=$("$DM" confirm --label nossh 2>&1); _rc=$?
chk "DM-55b confirm disarms a record armed outside ssh" "$_rc" "0"
has "DM-55c ...and names the rule it applied rather than silently allowing it" "$_out" 'armed OUTSIDE an ssh session'

# ------------------------------------------------------------ DM-30..DM-33 --
# THE TIMER LIMB'S SCHEDULING, which no bar reached before round 2. Nothing
# below calls `check`. If the detached spawn does not happen, or does not
# outlive its parent, or does not run the tool, these go red -- which is exactly
# what the mutant (`spawn` replaced by `:`) needed and did not get.
#
# --after is supplied here, as everywhere, by the caller. These are test
# parameters chosen to be short, not constants about the world: TIMER_AFTER is
# how long the sleeper waits, POLL_MAX bounds how long this file waits for it.
# Both are printed on failure so a slow PC reads as slow, not as broken.
TIMER_AFTER=3
POLL_MAX=40
use_root "$T/root4"
rm -f "$T/restore.ran"
use_session 41200; netstat_reset; open_session 41200

_t0=$(date +%s)
arm_ok "DM-A8" tmr "$TIMER_AFTER"
_t1=$(date +%s)
# arm must RETURN, not block for --after. The tool's own comment says a detached
# child holding stdin/stdout keeps the ssh channel open and hung the harness.
if [ $((_t1 - _t0)) -lt 120 ]; then ok "DM-32 arm with the timer RETURNS instead of holding the session"; else bad "DM-32 arm blocked for $((_t1 - _t0))s"; fi

_i=0
while [ "$_i" -lt "$POLL_MAX" ]; do
    [ -f "$DMDIR/tmr" ] || break
    _i=$((_i + 1)); sleep 1
done
if [ ! -f "$DMDIR/tmr" ]; then ok "DM-30 the DETACHED timer fired the record with nobody calling check"; else bad "DM-30 timer never fired (waited ${POLL_MAX}s past --after ${TIMER_AFTER}s)"; fi
if [ -f "$T/restore.ran" ]; then ok "DM-31 the timer limb actually ran the restore"; else bad "DM-31 timer fired nothing"; fi

# ...and --no-timer really means no sleeper. Same wait, nothing must happen.
use_root "$T/root5"
rm -f "$T/restore.ran"
use_session 41300; netstat_reset; open_session 41300
arm_ok "DM-A9" notmr "$TIMER_AFTER" --no-timer
_i=0
while [ "$_i" -lt "$POLL_MAX" ]; do
    [ -f "$DMDIR/notmr" ] || break
    _i=$((_i + 1)); sleep 1
done
if [ -f "$DMDIR/notmr" ]; then ok "DM-33 --no-timer spawns NOTHING: the record is still armed past its deadline"; else bad "DM-33 --no-timer fired anyway -- the flag does not gate the spawn"; fi

# ------------------------------------------ DM-45, DM-63, DM-65, DM-66, DM-67 --
# U290: ARM IS FAIL-CLOSED ON THE BOOT LIMB. Each of the three preconditions is
# seeded FALSE in turn and `arm` must REFUSE -- exit non-zero AND write no record
# -- and then all-true must arm and install the line. The record check is not
# decoration: the defect this replaces was an arm that refused nothing and left a
# record behind for a limb that was never installed, so "exit != 0" alone would
# not have caught it.
#
# DM-45/DM-45a/DM-45b ARE INVERTED. They pinned the opposite behaviour on the
# adjudication recorded in docs/deploy-p5-server.md O14 ("refusing would leave NO
# deadman at all, which stays the worse outcome"). That is reversed: a record with
# no boot limb is TRUSTED and does not fire after the power cut it was armed for,
# which is worse than an arm that refused and said why while the operator was
# still standing there. O14 is amended in the same commit. Same inversion shape as
# DM-52a/b when O15 was closed.

# ---- seed 2 FALSE: no crontab directory -----------------------------------
use_root "$T/root6"
P5_CRONTAB="$T/nosuchdir/root"; export P5_CRONTAB
crond_running yes
use_session 41400; netstat_reset; open_session 41400
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label opengap --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-45 arm with NO crontab directory REFUSES (exit 5), inverted from the O14 adjudication" "$_rc" "5"
has "DM-45a ...and names the directory that is missing" "$_err" 'does not exist'
if [ ! -f "$DMDIR/opengap" ]; then ok "DM-45b ...and writes NO record: a refused arm leaves the box as it found it"; else bad "DM-45b a REFUSED arm wrote a record anyway: $(cat "$DMDIR/opengap")"; fi

# ...and --no-boot-limb is the one override, on that same box.
# Captured as 2>&1, not stderr alone, and for the reason already written out at
# DM-55 above: the refusal is an ERROR and goes through p5_err (stderr), but the
# deliberate-absence note is an operator NOTE and goes through p5_log, which
# writes to STDOUT (p5/lib/p5-common.sh:235-239 vs :241-245). The stderr-only
# idiom is correct for DM-45/DM-45a immediately above and was copied one bar too
# far: it made DM-45e red against a tool that was printing exactly the required
# sentence. Combined, not stdout-only, so the bar stays green if the note is ever
# promoted to stderr -- it asserts that arm SAYS it, not which fd it says it on.
_out=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label optout --no-timer --no-boot-limb 2>&1); _rc=$?
chk "DM-45c --no-boot-limb arms on the same box the refusal just rejected" "$_rc" "0"
if [ -f "$DMDIR/optout" ]; then ok "DM-45d ...and the record IS written under the explicit override"; else bad "DM-45d no record under --no-boot-limb (output<<$_out>>)"; fi
has "DM-45e ...and says out loud that the boot limb is deliberately absent" "$_out" 'DELIBERATELY ABSENT'
# AND IT REACHES STDERR, which DM-45e above deliberately does not measure.
# The two bars are a pair, not a duplicate: DM-45e pins the CLAIM (arm says the
# limb is absent) and is fd-agnostic so it cannot go red over a routing change,
# while this one pins the ROUTING. "This box has no power-cut limb" is a safety
# degradation, and the fd an operator pipes away or a scripted caller discards
# is stdout -- so p5_log (stdout, p5/lib/p5-common.sh:235-239) is the wrong
# channel for it and p5_err (:241-245) is the one the rest of this file's
# degradation notices already use. Separate capture, stderr ALONE.
_eout=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label optout2 --no-timer --no-boot-limb 2>&1 >/dev/null)
has "DM-45f ...and that notice goes to STDERR, not the stdout a caller discards" "$_eout" 'DELIBERATELY ABSENT'

# ---- seed 1 FALSE: crond is not running -----------------------------------
# The ONLY thing that changes between this block and DM-66 below is the `ps`
# shim's answer. The crontab directory is present and writable and the subject is
# installed, so a red here cannot be either of the other two conditions.
use_root "$T/root12"
P5_CRONTAB="$T/crontabs12/root"; export P5_CRONTAB; mkdir -p "$T/crontabs12"
printf '0 4 * * * /usr/bin/somebody-elses-job\n' > "$P5_CRONTAB"
use_session 41410; netstat_reset; open_session 41410
crond_running no
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label nocrond --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-63 crond NOT running: arm REFUSES (exit 5) instead of writing an inert crontab line" "$_rc" "5"
if [ ! -f "$DMDIR/nocrond" ]; then ok "DM-63a ...and writes NO record"; else bad "DM-63a a record was written with crond down"; fi
has "DM-63b ...and names crond as the reason" "$_err" 'crond is NOT RUNNING'
if ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-63c ...and did not touch the operator's crontab on the way out"; else bad "DM-63c the refused arm appended to the crontab anyway: $(cat "$P5_CRONTAB")"; fi

# ---- seed 3 FALSE: $SELF is not on a path a reboot will find --------------
# The tool is COPIED out of the fake box's /usr/sbin into $T -- a real temp
# directory, which is what an arm run from the unpacked package looks like -- and
# THAT copy is run. It still finds its library at $P5_ROOT/usr/lib/p5, so this
# bar measures the $SELF rule and not a tool that failed to start.
crond_running yes
mkdir -p "$T/unpacked"
cp "$DM" "$T/unpacked/p5-deadman"; chmod +x "$T/unpacked/p5-deadman"
_err=$("$T/unpacked/p5-deadman" arm --after 3600 --restore-script "$T/restore.sh" --label tmpself --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-65 arm from an UNINSTALLED path REFUSES (exit 5): the crontab line would name a path the reboot cannot find" "$_rc" "5"
if [ ! -f "$DMDIR/tmpself" ]; then ok "DM-65a ...and writes NO record"; else bad "DM-65a a record was written from an uninstalled path"; fi
has "DM-65b ...and names the path it refused and the installed path it wanted" "$_err" 'is not under'

# ---- all three TRUE -------------------------------------------------------
# The positive control for the three bars above. Same fake box, same crontab,
# same operator line; crond up, directory writable, subject installed.
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label allgood --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-66 all three preconditions true: arm SUCCEEDS (exit 0)" "$_rc" "0"
if [ -f "$DMDIR/allgood" ]; then ok "DM-66a ...and the record is written"; else bad "DM-66a no record (stderr<<$_err>>)"; fi
if grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-66b ...and the boot limb line IS installed"; else bad "DM-66b arm reported success with no crontab line: $(cat "$P5_CRONTAB")"; fi

# ...and the override really does suppress the limb, rather than just logging.
use_root "$T/root13"
P5_CRONTAB="$T/crontabs13/root"; export P5_CRONTAB; mkdir -p "$T/crontabs13"
printf '0 4 * * * /usr/bin/somebody-elses-job\n' > "$P5_CRONTAB"
use_session 41420; netstat_reset; open_session 41420
# THE EXIT CODE IS PART OF THIS BAR, and it was not, which made the bar VACUOUS.
# Measured in the U290 seeded A/B: against dev's tool -- which has no
# --no-boot-limb at all and exits 2 on usage -- this bar went GREEN, because a
# tool that refuses to run installs no line either. "No line" is only evidence
# that the override SUPPRESSED the limb if arm actually armed. rc and the record
# are therefore asserted in the same bar rather than as new ones: they are not a
# separate claim, they are the precondition that makes this claim mean anything.
_out=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label nolimb --no-timer --no-boot-limb 2>&1); _rc=$?
if [ "$_rc" -ne 0 ] || [ ! -f "$DMDIR/nolimb" ]; then
    bad "DM-67 --no-boot-limb did not arm at all (rc=$_rc, record $([ -f "$DMDIR/nolimb" ] && echo present || echo absent)) -- 'no crontab line' would be vacuous <<$_out>>"
elif ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then
    ok "DM-67 --no-boot-limb installs NO crontab line, on a box where it could have"
else
    bad "DM-67 --no-boot-limb installed the line anyway: $(cat "$P5_CRONTAB")"
fi

# ------------------------------------------------- DM-68, DM-69, DM-70 --
# U290 FIX ROUND: THE APPEND ITSELF CAN FAIL, AND NOTHING READ ITS STATUS.
# boot_limb_ready answers three questions about the box; it does not and cannot
# answer "did the write land". Both `printf >> $CRONTAB` appends in
# boot_limb_install discarded their exit status and the function returned 0
# regardless, so a failed append -- ENOSPC, a read-only remount, the path being
# a DIRECTORY -- reached the caller as success and arm printed ARMED over a
# crontab with no line in it. That is the same silent NO-OP the whole unit is
# about, one layer below the gate it added.
#
# SEEDED AS A DIRECTORY, deliberately, because it is the one seed that gets
# through every condition boot_limb_ready tests and fails only at the write:
# dirname() is the parent, which exists and is writable; the path itself EXISTS
# and passes `-w` (a directory is writable); crond is up and the subject is
# installed. ENOSPC would need a loop mount and root; a read-only remount the
# same. Measured across the three shells this product runs under, a `>>` onto a
# directory returns non-zero (dash 2, busybox sh 1, bash 1) without exiting the
# shell, which is what makes `|| return 1` portable here.
use_root "$T/root14"
mkdir -p "$T/crontabs14/root"          # THE CRONTAB PATH IS A DIRECTORY
P5_CRONTAB="$T/crontabs14/root"; export P5_CRONTAB
use_session 41430; netstat_reset; open_session 41430
crond_running yes
_out=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label appendfail --no-timer 2>&1); _rc=$?
chk "DM-68 an append that FAILS (crontab path is a directory) makes arm REFUSE (exit 5)" "$_rc" "5"
if [ ! -f "$DMDIR/appendfail" ]; then ok "DM-68a ...and the record written before the limb is REMOVED again: nothing is left armed"; else bad "DM-68a a record survived a failed boot-limb install: $(cat "$DMDIR/appendfail")"; fi
hasnt "DM-68b ...and arm never says ARMED" "$_out" "ARMED '"
has "DM-68c ...and says the boot limb FAILED to install" "$_out" 'boot limb FAILED to install'

# ---- P5_CRONTAB IS AN OVERRIDE AND MUST BE ANNOUNCED ----------------------
# It is consumed at p5/bin/p5-deadman:173 and was NOT in p5-common.sh's override
# list, so an INHERITED P5_CRONTAB -- exported by this very suite, and by the
# ecosim portal's deadman wrapper -- reached a real arm in silence. Every
# boot-limb condition then passes against a file crond does not read: the limb
# is installed, correct, and inert. The banner is the only thing that can make
# that visible, because nothing else about the arm looks wrong.
has "DM-69 P5_CRONTAB is announced as an environment override" "$_out" 'P5_CRONTAB='

# ---- RUNNING NOW IS NOT ENABLED AT BOOT ------------------------------------
# crond_is_running reads the PROCESS TABLE. The boot limb exists to survive a
# REBOOT, and what survives a reboot is /etc/rc.d/S<nn>cron, not a process
# somebody started by hand. These bars measure that the tool REPORTS the second
# fact -- it is deliberately not a fourth refusal condition (p5-deadman's
# cron_boot_state says why), so the bars assert the TEXT, in both directions.
use_root "$T/root15"
P5_CRONTAB="$T/crontabs15/root"; export P5_CRONTAB; mkdir -p "$T/crontabs15"
printf '0 4 * * * /usr/bin/somebody-elses-job\n' > "$P5_CRONTAB"
use_session 41440; netstat_reset; open_session 41440

# a) on a REFUSAL, the operator is told the separate boot-enablement fact --
#    otherwise they restart crond by hand, the refusal clears, and the reboot
#    case is exactly as broken as it was.
crond_running no
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label bootrep --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-70 crond down still refuses (exit 5)" "$_rc" "5"
has "DM-70a ...and the refusal reports boot enablement as a SEPARATE fact" "$_err" 'NOT enabled at boot'

# b) on a SUCCESSFUL arm with the limb installed: no S*cron -> WARN. This is the
#    silent case the whole check exists for -- every condition passes, the line
#    goes in, and the reboot eats the crond that would have read it.
crond_running yes
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label bootwarn --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-70b arm SUCCEEDS (exit 0) with crond up but cron not enabled at boot -- reported, not refused" "$_rc" "0"
has "DM-70c ...and WARNS that the installed limb is inert after a reboot" "$_err" 'NOT enabled at boot'

# c) THE OTHER DIRECTION, which is what stops this from being a bar that just
#    asserts a constant string: enable cron at boot on the same fake box and the
#    warning must be GONE. Without this, a tool that printed the sentence
#    unconditionally would pass (a) and (b).
mkdir -p "$P5_ROOT/etc/rc.d"; : > "$P5_ROOT/etc/rc.d/S50cron"
_err=$("$DM" arm --after 3600 --restore-script "$T/restore.sh" --label bootok --no-timer 2>&1 >/dev/null); _rc=$?
chk "DM-70d ...and with /etc/rc.d/S50cron present the same arm still succeeds" "$_rc" "0"
hasnt "DM-70e ...and the not-enabled-at-boot warning is GONE (the A/B control)" "$_err" 'NOT enabled at boot'
if grep -qF 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-70f ...and the boot limb line is installed on that box"; else bad "DM-70f no crontab line after a successful arm: $(cat "$P5_CRONTAB")"; fi

# ------------------------------------------------------------ DM-56..DM-57 --
# THE SAME REMOVAL THROUGH `check`, not just `fire` (U130). The call lives in
# fire_one(), which both verbs share, so a record fired by `check` -- the
# timer or the boot limb itself invoking it, nobody typing `fire` -- must clean
# up identically. This is the more important path in practice: the boot limb
# calls `check`, not `fire`, so a fix that only worked from `fire` would leave
# the real-world case (a power-cut rollback firing from cron) unfixed.
use_root "$T/root7"
P5_CRONTAB="$T/crontabs7/root"; export P5_CRONTAB; mkdir -p "$T/crontabs7"
printf '0 4 * * * /usr/bin/somebody-elses-job\n#keep me\n' > "$P5_CRONTAB"
cp "$P5_CRONTAB" "$T/crontab7.golden"
CRONPRE="$P5_CRONTAB.p5-pre"
use_session 41600; netstat_reset; open_session 41600
arm_ok "DM-A10" viacheck 3600 --no-timer
_t=$(date +%s); _past=$((_t - 10))
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$_past/" "$DMDIR/viacheck" > "$DMDIR/x" && mv "$DMDIR/x" "$DMDIR/viacheck"
runv check
chkv "DM-56 check fires the past-deadline (and only) record (exit 1)" "1"
if ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-56a check also removes the boot limb once nothing remains armed"; else bad "DM-56a boot limb still present after check fired the last record"; fi
if cmp -s "$P5_CRONTAB" "$T/crontab7.golden"; then ok "DM-57 ...and the crontab is byte-exact again"; else bad "DM-57 crontab not byte-exact after check: $(cat "$P5_CRONTAB")"; fi
if [ ! -f "$CRONPRE" ]; then ok "DM-57a still no CRONPRE sibling file anywhere on this path either"; else bad "DM-57a $CRONPRE exists"; fi

# ------------------------------------------------------------ DM-58..DM-58d --
# CASE A: an operator crontab line that happens to CONTAIN "# p5-deadman" as a
# substring, but is not our line. Before this fix round, `grep -q "$CRONMARK"`
# (an unanchored substring test) treated this as "the boot limb is already
# installed" and skipped the real append -- `arm` exited 0 and the boot limb
# was silently absent. `grep -v "$CRONMARK"` had the mirror bug on removal: it
# stripped the WHOLE look-alike line, not just p5's. Both are fixed by
# matching CRONLINE -- the exact literal line p5 appends -- with -xF instead
# of CRONMARK as a bare substring.
LOOKALIKE='0 5 * * * /usr/bin/true # p5-deadman-lookalike, not ours'
use_root "$T/root8"
P5_CRONTAB="$T/crontabs8/root"; export P5_CRONTAB; mkdir -p "$T/crontabs8"
printf '%s\n' "$LOOKALIKE" > "$P5_CRONTAB"
use_session 41700; netstat_reset; open_session 41700
arm_ok "DM-A11" lookalike 3600 --no-timer
_n=$(grep -c 'p5-deadman' "$P5_CRONTAB" 2>/dev/null)
if [ "$_n" = 2 ]; then ok "DM-58 case A install: a look-alike operator line does NOT suppress the real boot-limb append (2 lines now)"; else bad "DM-58 expected 2 lines containing p5-deadman after arm, got $_n: $(cat "$P5_CRONTAB")"; fi
if grep -qxF "$LOOKALIKE" "$P5_CRONTAB"; then ok "DM-58a ...and the look-alike line itself is byte-for-byte untouched"; else bad "DM-58a look-alike line was altered: $(cat "$P5_CRONTAB")"; fi
use_session 41701; open_session 41701   # a NEW connection: confirm refuses the arming one
runv confirm --label lookalike
chkv "DM-58b confirm disarms the look-alike-line record" "0"
if grep -qxF "$LOOKALIKE" "$P5_CRONTAB"; then ok "DM-58c ...and the look-alike line SURVIVES removal (anchored match, not a substring match)"; else bad "DM-58c look-alike line was deleted on removal: $(cat "$P5_CRONTAB")"; fi
_n2=$(wc -l < "$P5_CRONTAB")
if [ "$_n2" = 1 ]; then ok "DM-58d ...and only p5's own line was stripped -- 1 line left, not 0"; else bad "DM-58d wrong line count after removal ($_n2): $(cat "$P5_CRONTAB")"; fi

# ------------------------------------------------------------ DM-60..DM-60d --
# CASE B: a pre-existing crontab with NO trailing newline. `>>` used to glue
# p5's appended line onto the operator's last line into one merged line, which
# then matched CRONMARK on removal and was stripped WHOLE -- the operator's
# job vanished with it (reproduced pre-fix: crontab left at 0 bytes).
# boot_limb_install now inserts a separating newline first when the file does
# not already end in one, so the two lines stay distinct through install and
# removal both.
JOBLINE='0 4 * * * /usr/bin/somebody-elses-job'
use_root "$T/root9"
P5_CRONTAB="$T/crontabs9/root"; export P5_CRONTAB; mkdir -p "$T/crontabs9"
printf '%s' "$JOBLINE" > "$P5_CRONTAB"   # deliberately NO trailing newline
use_session 41800; netstat_reset; open_session 41800
arm_ok "DM-A12" notrail 3600 --no-timer
if grep -qxF "$JOBLINE" "$P5_CRONTAB"; then ok "DM-60 case B install: a no-trailing-newline crontab is not glued to p5's appended line"; else bad "DM-60 operator line glued or lost on install: $(cat "$P5_CRONTAB")"; fi
_t=$(date +%s); _past=$((_t - 10))
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$_past/" "$DMDIR/notrail" > "$DMDIR/x" && mv "$DMDIR/x" "$DMDIR/notrail"
runv check
chkv "DM-60a check fires the no-trailing-newline record (exit 1)" "1"
_sz=$(wc -c < "$P5_CRONTAB")
if [ "$_sz" -gt 0 ]; then ok "DM-60b ...and the crontab is NOT reduced to 0 bytes (the pre-fix defect)"; else bad "DM-60b crontab is 0 bytes -- the operator's job was deleted"; fi
if grep -qxF "$JOBLINE" "$P5_CRONTAB"; then ok "DM-60c ...and the operator's job line survives intact"; else bad "DM-60c operator job line missing or altered: $(cat "$P5_CRONTAB")"; fi
if ! grep -q 'p5-deadman' "$P5_CRONTAB" 2>/dev/null; then ok "DM-60d ...and p5's own line is gone (removed through check -> fire_one)"; else bad "DM-60d p5's line still present: $(cat "$P5_CRONTAB")"; fi

# ------------------------------------------------------------------ DM-61 --
# ROUND 3 FIX (U130 second fix round): do_status's OWN boot-limb check used
# `grep -q "$CRONMARK"` -- a bare, unanchored substring test -- independently
# of the -xF anchoring DM-58 already forced onto install and removal above. A
# crontab holding ONLY a look-alike line, with the real CRONLINE never
# installed, made status claim "boot: LIVE" -- exactly the string
# docs/deploy-p5-server.md O14 names as the operator's signal that the
# power-cut limb is wired. Fixed by matching CRONLINE with grep -qxF, the same
# anchor already used everywhere else in this file. No arm happens in this
# bar on purpose: the defect is in status's OWN read of the crontab, not in
# anything arm did to it.
use_root "$T/root10"
P5_CRONTAB="$T/crontabs10/root"; export P5_CRONTAB; mkdir -p "$T/crontabs10"
printf '%s\n' "$LOOKALIKE" > "$P5_CRONTAB"
crond_running yes
_out=$("$DM" status 2>&1)
hasnt "DM-61 status does not claim boot: LIVE from a look-alike line when the real CRONLINE was never installed" "$_out" 'boot:  LIVE'
has "DM-61a ...and reports the honest crond-up-no-line verdict instead" "$_out" 'boot:  crond running but NO crontab line'

# ------------------------------------------------------------------ DM-62 --
# ROUND 3 FIX (U130 second fix round): boot_limb_remove_if_last rewrote
# $CRONTAB via `grep -vxF ... > tmp; mv tmp "$CRONTAB"`. `mv` onto an existing
# path unlinks the destination and puts the SOURCE file in its place --
# tmp's own (umask-derived) mode lands on $CRONTAB, not the mode it had
# before. $CRONTAB is root's real, shared crontab; a removal is not p5's
# license to loosen or tighten it. Seed a non-default 640 and expect 640
# back -- MEASURED with the mode stamp removed from the tool: 640 -> 644,
# this bar red, the other 113 still green.
# DM-62b guards the bar itself: on a filesystem that does not honor
# chmod bits (NTFS under Git Bash) the seed would silently read back as
# something other than 640 and DM-62a would pass for the wrong reason -- this
# bar must be run where p5-deadman actually runs, ext4 under WSL (`bash
# scripts/ci-wsl.sh`), not directly under Git Bash on the Windows host.
use_root "$T/root11"
P5_CRONTAB="$T/crontabs11/root"; export P5_CRONTAB; mkdir -p "$T/crontabs11"
printf '0 4 * * * /usr/bin/somebody-elses-job\n' > "$P5_CRONTAB"
chmod 640 "$P5_CRONTAB"
_mode_before=$(stat -c %a "$P5_CRONTAB" 2>/dev/null || echo '?')
use_session 41900; netstat_reset; open_session 41900
arm_ok "DM-A13" modekeep 3600 --no-timer
use_session 41901; open_session 41901
runv confirm --label modekeep
chkv "DM-62 confirm disarms the mode-preservation record" "0"
_mode_after=$(stat -c %a "$P5_CRONTAB" 2>/dev/null || echo '?')
chk "DM-62a crontab mode is unchanged by removal ($_mode_before -> $_mode_after)" "$_mode_after" "$_mode_before"
if [ "$_mode_before" = 640 ]; then ok "DM-62b ...and the seeded mode really was the non-default 640 this bar depends on"; else bad "DM-62b chmod 640 did not stick on this filesystem (got $_mode_before) -- run this suite under ext4 (WSL), not directly on NTFS"; fi

_TOTAL=$((PASS + FAIL))
printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"
if [ "$_TOTAL" -lt "$BARS_MIN" ]; then
    printf 'RATCHET FAILED: only %s bars were REACHED, floor is %s.\n' "$_TOTAL" "$BARS_MIN"
    printf 'Bars stopped executing somewhere above. A green run that reaches fewer\n'
    printf 'bars than the last one is a regression in the gate, not a tidier suite.\n'
    rm -rf "$T"
    exit 1
fi
rm -rf "$T"
[ "$FAIL" -eq 0 ] || exit 1
