#!/bin/sh
# p5/test/pathsanity.sh -- the B1 bars: can a CONTRACT row reach an rm?
#
# WHY THIS IS A SEPARATE FILE. The round-2 review demonstrated the defect by
# DOING it: a `../../` row in contract/paths turned into an executed UNLINK and
# deleted the operator's SSH key from a box with no physical access. These bars
# re-run that demonstration, and four more shapes of the same escape, against
# the real shipped p5-uninstall.
#
# THE ROOT IS HAND-BUILT, NOT INSTALLED, and that is a deliberate limitation:
# these bars exercise REMOVAL, and running the installer for each of seven
# roots costs minutes per root on the development machine. The hand-built root
# is checked against the installed one by bar PS-0, which RE-MEASURES the
# reference plan in-run and PRINTS what it measured: every recorded path must be
# reachable by the plan, and the plan's own tally must equal the actions it
# emitted. PS-0 asserts NO plan LENGTH. Length is a property of the FIXTURE, not
# of the product, and the constant it used to assert is what made a red bar mean
# "somebody regrouped the actions" instead of "the subject drifted" -- see PS-0's
# own comment. So a divergence in what the plan COVERS shows up as a red bar
# rather than as silently weaker evidence, and a change in how the actions are
# GROUPED does not.
#
# EVERY BAR HERE HAS A MUTATION BESIDE IT. PS-6 stubs the physical check out and
# the symlink escape must reappear; MU-PS0 mutates the shipped planner and PS-0's
# predicate must go red; MU-PS7 neutralises SELFDROP's point-of-use gate and the
# file outside the namespace must die. A bar that cannot fail is not evidence.
#
# usage: pathsanity.sh [P5DIR]      exit 0 all passed, 1 any failed

set -u

here=$(cd "$(dirname "$0")" && pwd)
P5DIR=${1:-$(cd "$here/.." && pwd)}

# Shared bookkeeping: ok/bad, the ledger, the exclusive scratch directory and
# the self-checked summary. run.sh folds this file's counts in by reading the
# ledger it names in P5T_LEDGER_OUT, not by grepping the output printed below.
. "$here/ledger.sh"

# Exclusive, never `mkdir -p` -- see ledger.sh's header.
B=$(p5t_workdir p5-pathsanity) || {
    echo "FAIL  TMP  could not create an exclusively-owned scratch directory under ${TMPDIR:-/tmp}"
    echo "p5-pathsanity: 0 passed, 1 failed"
    exit 1
}
trap 'rm -rf "$B"' EXIT
p5t_ledger_init "${P5T_LEDGER_OUT:-$B/ledger}" || { echo "FAIL  TMP  cannot write the bar ledger"; exit 1; }

# --- a root that looks like a finished client install ------------------------
# Only the parts removal reads: the stamp, the two records, the shipped
# contract copies, the on-box entry points and the placed payload.
newroot() {
    R="$B/$1"
    mkdir -p "$R/usr/lib/p5" "$R/usr/sbin" "$R/etc/init.d" \
             "$R/etc/hotplug.d/iface" "$R/etc/p5/deadman" "$R/var/run/p5" \
             "$R/etc/dropbear"
    cp "$P5DIR/lib/p5-common.sh"   "$R/usr/lib/p5/p5-common.sh"
    cp "$P5DIR/contract/namespace" "$R/usr/lib/p5/contract-namespace"
    cp "$P5DIR/contract/foreign"   "$R/usr/lib/p5/contract-foreign"
    cp "$P5DIR/contract/paths"     "$R/usr/lib/p5/contract-paths"
    cp "$P5DIR/bin/p5-uninstall"   "$R/usr/sbin/p5-uninstall"
    cp "$P5DIR/bin/p5-version"     "$R/usr/sbin/p5-version"
    cp "$P5DIR/bin/p5-deadman"     "$R/usr/sbin/p5-deadman"
    printf 'x\n'                    > "$R/usr/sbin/p5-datapath"
    printf '#!/bin/sh\nexit 0\n'    > "$R/etc/init.d/p5-datapath"
    printf '#!/bin/sh\nexit 0\n'    > "$R/etc/hotplug.d/iface/94-p5"
    # Two files OUTSIDE the P5 namespace. The first is the one the round-2
    # review actually lost; the second is there so a widened glob has something
    # to take that is not the key, i.e. so a bar cannot pass by coincidence.
    printf 'ssh-rsa OPERATOR-KEY-DO-NOT-DELETE\n' > "$R/etc/dropbear/authorized_keys"
    printf 'root:x:0:0:root:/root:/bin/ash\n'     > "$R/etc/passwd"
    {
        echo "P5_PRODUCT=p5"
        echo "P5_VERSION=0.0.0-pathsanity"
        echo "P5_CONTRACT_VERSION=3"
        echo "P5_ROLE=client"
        echo "P5_GIT_COMMIT=0000000000000000000000000000000000000000"
        echo "P5_GIT_BRANCH=test"
        echo "P5_GIT_DIRTY=no"
        echo "P5_BUILT_UTC=1970-01-01T00:00:00Z"
        echo "P5_INSTALLED_UTC=1970-01-01T00:00:00Z"
    } > "$R/usr/lib/p5/stamp"
    _h=0000000000000000000000000000000000000000000000000000000000000000
    for _p in /usr/lib/p5/stamp /usr/lib/p5/installed.files \
              /usr/lib/p5/installed.dirs /usr/lib/p5/p5-common.sh \
              /usr/lib/p5/contract-namespace /usr/lib/p5/contract-foreign \
              /usr/lib/p5/contract-paths /usr/sbin/p5-uninstall \
              /usr/sbin/p5-version /usr/sbin/p5-deadman /usr/sbin/p5-datapath \
              /etc/init.d/p5-datapath /etc/hotplug.d/iface/94-p5; do
        echo "$_h  $_p"
    done > "$R/usr/lib/p5/installed.files"
    { echo /usr/lib/p5; echo /etc/p5; echo /etc/p5/deadman; } > "$R/usr/lib/p5/installed.dirs"
    CON="$R/usr/lib/p5/contract-paths"
}

# Run the BOX's own uninstaller, the way an operator would -- not the package
# copy. On a box the contract comes from /usr/lib/p5/contract-*, which is the
# file these bars mutate.
rm_run() {
    P5_ROOT="$R" sh "$R/usr/sbin/p5-uninstall" --remove --role client \
        > "$B/$1.out" 2>&1
    echo $? > "$B/$1.rc"
}

# A directory symlink, however this host can make one. OpenWrt has ln -s; the
# development machine is Windows, where an unprivileged `ln -s` silently
# DEEP-COPIES, so a bar written only against ln -s would pass VACUOUSLY there.
# NTFS junctions are unprivileged, and Git Bash both reports and resolves them
# as symlinks, which is exactly what the bar needs.
#
# IT LIVES IN A FILE, not only in a function, because PS-7 needs the same
# symlink to be made from inside a script THE PRODUCT ITSELF EXECUTES mid-run.
# A second copy of these fallbacks would be a second thing to keep right.
cat > "$B/dirlink.sh" <<'DLEOF'
# dirlink.sh TARGET LINK -- see pathsanity.sh for why the fallbacks exist.
ln -s "$1" "$2" 2>/dev/null
[ -L "$2" ] && exit 0
rm -rf "$2" 2>/dev/null
command -v cmd.exe >/dev/null 2>&1 || exit 1
# cmd.exe cannot read an MSYS path, so the target is converted; without this the
# mklink fallback fails silently and the bar reports "this host cannot make a
# symlink" on a host that can.
_dl_t=$(cygpath -w "$1" 2>/dev/null) || _dl_t="$1"
[ -n "$_dl_t" ] || _dl_t="$1"
( cd "$(dirname "$2")" 2>/dev/null \
  && MSYS_NO_PATHCONV=1 cmd.exe /C "mklink /J $(basename "$2") $_dl_t" ) >/dev/null 2>&1
[ -L "$2" ]
DLEOF
dirlink() { # dirlink TARGET LINK
    sh "$B/dirlink.sh" "$1" "$2"
}

survived() { # survived BAR VICTIM TEXT
    if [ -e "$2" ]; then ok "$1" "$3"; else bad "$1" "$3 -- DELETED: $2"; fi
}

# ===========================================================================
# PS-0: the hand-built root is the same subject the installed one is.
# ===========================================================================
# THIS BAR USED TO ASSERT A CONSTANT -- `# end of plan: 18 action(s)`. It could
# not own that number. Plan length is a property of the FIXTURE, not of the
# product: the same tree measured on this hand-built root, on a minimal install
# under a test root, on run.sh's own client fixture and on a live-shaped client
# root has given 18, 13, 12, 14 and 16 actions across U25's rounds and lenses,
# and B2's SELFDROP legitimately folded six tail actions into one. So a red here
# never told you the subject had drifted; it told you somebody had changed the
# plan, and the only way to clear it was to edit the constant -- which is
# weakening a bar to go green.
#
# What the bar actually needs to establish is that this root is the SAME KIND OF
# SUBJECT run.sh installs: a plan that reaches every recorded path, and that
# counts itself honestly. Both are re-measured here. The measured length is
# PRINTED, never asserted -- the same shape MU-RCV uses for the action index.
# ps0_measure PLANOUT RC RECFILE -> 0 if the plan covers the record and counts
# itself honestly. Sets PS0_SAID / PS0_EMIT / PS0_MISS / PS0_MISSING / PS0_RECN.
# A FUNCTION, not inline text, so MU-PS0 below can put a mutated planner's plan
# through the identical predicate -- a mutation that re-implements the check it
# is supposed to falsify proves nothing.
ps0_measure() {
    # The plan's own tally against the action lines it actually emitted. A
    # planner that mis-counts its own plan is the defect this half catches; a
    # form where both halves come from the same grep could not see it.
    PS0_SAID=$(sed -n 's/^# end of plan: \([0-9][0-9]*\) action(s)$/\1/p' "$1")
    PS0_EMIT=$(grep -cE '^(SVCDOWN|UNLINK|RMTREE|RMDIR|SELFDROP|DROPINTENT|UCIMANUAL)\|' "$1")
    # Every path the install record names must be reachable by the plan, either
    # as its own action or inside the SELFDROP argument. This is what makes the
    # root the same subject; it does not depend on how the actions are grouped,
    # and it asserts no LENGTH.
    PS0_MISS=0; PS0_MISSING=; PS0_RECN=0
    while read -r _sha _p; do
        [ -n "$_p" ] || continue
        PS0_RECN=$((PS0_RECN + 1))
        # -F, not a regex. A recorded path is a LITERAL: with plain `grep` every `.` in
        # /usr/lib/p5/cake-autorate.sh matches any character, so a path could be "reachable"
        # via a DIFFERENT line that merely resembles it. Unanchored is still deliberate --
        # a path may legitimately appear in any action -- but it must match ITSELF.
        grep -qF -- "$_p" "$1" || { PS0_MISS=$((PS0_MISS + 1)); PS0_MISSING="$PS0_MISSING $_p"; }
    done < "$3"
    [ "$2" = 0 ] || return 1
    [ -n "$PS0_SAID" ] || return 1
    [ "$PS0_SAID" = "$PS0_EMIT" ] || return 1
    [ "$PS0_EMIT" -gt 0 ] || return 1
    [ "$PS0_MISS" = 0 ] || return 1
    return 0
}

newroot p0
P5_ROOT="$R" sh "$R/usr/sbin/p5-uninstall" --remove --role client --dry-run \
    > "$B/p0.out" 2>&1
p0_rc=$?
if ps0_measure "$B/p0.out" "$p0_rc" "$R/usr/lib/p5/installed.files"; then
    ok "PS-0" "the hand-built root plans over the SAME SUBJECT run.sh installs: all $PS0_RECN recorded paths are reachable by the plan, and the plan's own tally ($PS0_SAID) equals the actions it emitted ($PS0_EMIT). The length is MEASURED and printed here, never asserted -- it is fixture-dependent and has been 12/13/14/16/18 across this unit's fixtures"
else
    bad "PS-0" "hand-built root is not the same subject (rc=$p0_rc, plan says '$PS0_SAID' actions vs $PS0_EMIT emitted, $PS0_MISS of $PS0_RECN recorded path(s) unreachable:$PS0_MISSING)"
fi

# ===========================================================================
# MU-PS0: THE MUTATION. PS-0 replaced a constant it could not own; a bar that
# re-measures is only better than a bar that asserts if it can still go RED. So
# the shipped planner is mutated two ways -- once so it LIES about its own tally,
# once so it DROPS a recorded path from the plan -- and PS-0's own predicate must
# refuse each. Both limbs run the real p5-uninstall against the same hand-built
# root; only one line of the planner differs.
# ===========================================================================
newroot m0
MB="$B/m0bin"; mkdir -p "$MB"
# Limb A -- the tally lies. `# end of plan: N` becomes a constant, which is
# exactly the shape PS-0 used to assert and could therefore never catch.
sed 's|^    echo "# end of plan: \$(grep -c . "\$P5_PLANO") action(s)"$|    echo "# end of plan: 99 action(s)"|' \
    "$P5DIR/bin/p5-uninstall" > "$MB/liar"
# Limb B -- a recorded path never reaches the plan. Step b of emit_plan drops
# one entry, so the record still names it and no action covers it.
sed 's|^    grep -v .\^/usr/lib/p5/. "\$P5_PLANF" 2>/dev/null |    grep -v "^/usr/sbin/p5-datapath$" "$P5_PLANF" 2>/dev/null \| grep -v "^/usr/lib/p5/" |' \
    "$P5DIR/bin/p5-uninstall" > "$MB/dropper"
a=0
cmp -s "$MB/liar"    "$P5DIR/bin/p5-uninstall" && { a=1; echo "  MUTATION A DID NOT APPLY: the plan tally line was not found"; }
cmp -s "$MB/dropper" "$P5DIR/bin/p5-uninstall" && { a=1; echo "  MUTATION B DID NOT APPLY: the payload pass was not found"; }
for _mu in liar dropper; do
    P5_ROOT="$R" P5_LIB_SRC="$P5DIR/lib" sh "$MB/$_mu" \
        --remove --role client --dry-run > "$B/m0.$_mu.out" 2>&1
    _mrc=$?
    if ps0_measure "$B/m0.$_mu.out" "$_mrc" "$R/usr/lib/p5/installed.files"; then
        a=1
        echo "  the $_mu mutant PASSED PS-0's predicate (rc=$_mrc, said '$PS0_SAID' vs $PS0_EMIT emitted, $PS0_MISS unreachable) -- PS-0 cannot see that defect"
    else
        echo "  $_mu -> refused: said '$PS0_SAID' vs $PS0_EMIT emitted, $PS0_MISS of $PS0_RECN recorded path(s) unreachable:$PS0_MISSING"
    fi
done
if [ "$a" = 0 ]; then
    ok "MU-PS0" "MUTATION: a planner that lies about its own tally, and one that leaves a recorded path out of the plan, are each refused by the SAME predicate PS-0 passes -- PS-0 re-measures rather than asserting a length, and it is still a bar that can fail"
else
    bad "MU-PS0" "PS-0's predicate did not go red against a mutated planner -- it is not a bar that can fail"
fi

# ===========================================================================
# PS-1: `../..` traversal. THE EXACT ROUND-2 DEMONSTRATION.
# ===========================================================================
newroot p1
echo 'glob|both  |/etc/p5/../../etc/dropbear/authorized_keys |E6 |runtime |traversal' >> "$CON"
rm_run p1
survived "PS-1" "$R/etc/dropbear/authorized_keys" \
  "a contract glob row containing ../.. cannot unlink outside the namespace (rc=$(cat "$B/p1.rc"))"

# ===========================================================================
# PS-2: an absolute path wholly outside the namespace.
# ===========================================================================
newroot p2
echo 'glob|both  |/etc/dropbear/authorized_keys |E6 |runtime |absolute escape' >> "$CON"
rm_run p2
survived "PS-2" "$R/etc/dropbear/authorized_keys" \
  "a contract row naming an absolute out-of-namespace path cannot unlink it (rc=$(cat "$B/p2.rc"))"

# ===========================================================================
# PS-3: a symlink pointing out. NO CONTRACT EDIT AT ALL.
# The shipped, correct, namespace-admitted row  glob|both|/etc/p5/*|E6|runtime
# is enough once /etc/p5 is a symlink: every hit is SPELLED inside the
# namespace and LANDS outside it. This is the one no lexical check can see.
# ===========================================================================
newroot p3
rm -rf "$R/etc/p5"
if dirlink "$R/etc/dropbear" "$R/etc/p5"; then
    rm_run p3
    survived "PS-3" "$R/etc/dropbear/authorized_keys" \
      "a symlinked /etc/p5 cannot turn the SHIPPED /etc/p5/* row into an unlink outside the namespace (rc=$(cat "$B/p3.rc"))"
else
    bad "PS-3" "this host cannot create a directory symlink (ln -s deep-copies and mklink /J failed) -- the bar FAILS rather than skipping"
fi

# ===========================================================================
# PS-4: a glob that widens. Not hostile -- one character wrong in a row.
# ===========================================================================
newroot p4
echo 'glob|both  |/etc/* |E6 |runtime |widened glob' >> "$CON"
rm_run p4
survived "PS-4" "$R/etc/passwd" \
  "a widened contract glob cannot unlink the files it newly matches (rc=$(cat "$B/p4.rc"))"

# ===========================================================================
# PS-5: a path that collapsed to "/" -- the shape a package template produces
# when a substituted variable was empty. Both limbs: the runtime DIR row that
# becomes RMTREE and the runtime GLOB row that becomes UNLINK.
# ===========================================================================
newroot p5
printf 'CRITICAL\n' > "$R/CRITICAL"
echo 'dir |both  |/ |E0 |runtime |a substituted variable was empty' >> "$CON"
echo 'glob|both  |/* |E6 |runtime |a substituted variable was empty' >> "$CON"
rm_run p5
esc=$(grep -cE '^(RMTREE|RMDIR|UNLINK)\|(/|/CRITICAL)$' "$B/p5.out")
if [ -e "$R/CRITICAL" ] && [ "$esc" = 0 ]; then
    ok "PS-5" "a row collapsed to / reaches no destructive action and takes nothing (rc=$(cat "$B/p5.rc"))"
else
    bad "PS-5" "a row collapsed to / produced $esc destructive action(s) naming / (CRITICAL still present: $([ -e "$R/CRITICAL" ] && echo yes || echo NO))"
fi

# ===========================================================================
# PS-6: THE MUTATION. Stub the physical check to return 0 and the symlink
# escape must reappear. Without this, "PS-3 passes" is indistinguishable from
# "PS-3 cannot fail".
# ===========================================================================
newroot p6
sed 's/^p5_phys_ok() {$/p5_phys_ok() { return 0; # MUTANT/' \
    "$P5DIR/lib/p5-common.sh" > "$R/usr/lib/p5/p5-common.sh"
mut=$(grep -c 'MUTANT' "$R/usr/lib/p5/p5-common.sh")
rm -rf "$R/etc/p5"
if [ "$mut" != 1 ]; then
    bad "PS-6" "the mutation did not apply (p5_phys_ok signature not found) -- PS-3 is unvalidated"
elif dirlink "$R/etc/dropbear" "$R/etc/p5"; then
    rm_run p6
    if [ -e "$R/etc/dropbear/authorized_keys" ]; then
        bad "PS-6" "with p5_phys_ok stubbed the key SURVIVED -- PS-3 is not the bar that catches the symlink escape"
    else
        ok "PS-6" "with p5_phys_ok stubbed the symlink escape reappears and takes the key: PS-3 is a bar that can fail"
    fi
else
    bad "PS-6" "this host cannot create a directory symlink -- the mutation bar FAILS rather than skipping"
fi

# ===========================================================================
# PS-7 / MU-PS7: SELFDROP AT THE POINT OF USE.
# ===========================================================================
# Every escape above is refused while the PLAN IS BEING BUILT. That is a gate on
# a snapshot. The plan is then written to a file under a shared /tmp and read
# back to be executed, so a path it names can mean something else by the time
# the rm runs. B1 answered that for the UNLINK and RMTREE arms by re-checking at
# the point of use. SELFDROP predates B1 and did not -- and SELFDROP is the arm
# that runs rm -f on the recovery toolchain of a box with no console.
#
# A STATIC tree cannot show this: plan time and use time ask the same predicate,
# so a swap made before the run is refused at plan time and never reaches
# SELFDROP. The tree therefore has to change WHILE THE RUN IS IN FLIGHT, and it
# is changed by the product's own executor rather than by a race: emit_plan's
# step (a) EXECUTES /etc/init.d/<svc> for every enable-glob hit, before any
# other action, so a `stop` handler on the box swaps /usr/lib/p5 for a symlink
# out of the namespace at a deterministic instant between plan and SELFDROP.
#
# THAT EXECUTION IS ITSELF AN OPEN DEFECT OF THIS TREE (README.md: a contract
# glob row can make --remove execute an undeclared /etc/init.d/p5-* as root). It
# is used here ONLY as a deterministic clock. The property under test is
# SELFDROP's gate, and nothing here claims the executor defect is fixed.
#
# The victim directory holds exactly the four basenames SELFDROP is about to
# unlink and nothing else, because SELFDROP's own emptiness pre-check refuses to
# proceed when a stranger is present -- a stranger would make the bar pass for
# the wrong reason.
ps7_setup() {   # ps7_setup NAME -> a root primed to swap mid-run
    newroot "$1"
    mkdir -p "$R/etc/operator" "$R/etc/rc.d"
    for _b in contract-foreign contract-namespace contract-paths p5-common.sh; do
        printf 'OPERATOR FILE -- OUTSIDE THE P5 NAMESPACE -- DO NOT DELETE\n' \
            > "$R/etc/operator/$_b"
    done
    # The enable flag. Not in installed.files -- procd writes it at enable time
    # -- so it reaches the plan through the contract's enable glob, which is
    # what makes step (a) run the init script below.
    printf 'S94p5-datapath\n' > "$R/etc/rc.d/S94p5-datapath"
    {
        echo '#!/bin/sh'
        echo '# On `stop`, move /usr/lib/p5 aside and put a symlink out of the'
        echo '# namespace in its place. This is the mid-run change SELFDROP has'
        echo '# to survive.'
        echo 'case "$1" in'
        echo 'stop)'
        printf '    mv "%s/usr/lib/p5" "%s/usr/lib/p5.moved" 2>/dev/null\n' "$R" "$R"
        printf '    sh "%s" "%s/etc/operator" "%s/usr/lib/p5" >/dev/null 2>&1\n' \
            "$B/dirlink.sh" "$R" "$R"
        echo '    ;;'
        echo 'esac'
        echo 'exit 0'
    } > "$R/etc/init.d/p5-datapath"
    chmod 755 "$R/etc/init.d/p5-datapath" 2>/dev/null
}

# ps7_run BAR EXECUTABLE -> runs the removal and reports whether the swap landed
ps7_run() {
    P5_ROOT="$R" P5_LIB_SRC="$P5DIR/lib" sh "$2" --remove --role client \
        > "$B/$1.out" 2>&1
    echo $? > "$B/$1.rc"
    [ -L "$R/usr/lib/p5" ]
}

ps7_setup p7
if ps7_run p7 "$R/usr/sbin/p5-uninstall"; then
    if [ -e "$R/etc/operator/p5-common.sh" ]; then
        if grep -q 'REFUSED UNLINK on /usr/lib/p5/p5-common.sh' "$B/p7.out"; then
            ok "PS-7" "the toolchain path was swapped for a symlink out of the namespace BETWEEN the plan and SELFDROP, and SELFDROP refused it at the point of use: the operator's file survived and the run said why (rc=$(cat "$B/p7.rc"))"
        else
            bad "PS-7" "the file survived but SELFDROP never said it refused anything -- it may have been skipped for an unrelated reason, which is not the property under test"
        fi
    else
        bad "PS-7" "SELFDROP unlinked $R/etc/operator/p5-common.sh -- a path OUTSIDE the P5 namespace (rc=$(cat "$B/p7.rc"))"
    fi
else
    bad "PS-7" "the mid-run swap did not land (this host could not make a directory symlink, or step (a) did not execute the init script) -- the bar FAILS rather than skipping"
fi

# MU-PS7: THE MUTATION. Neutralise that one guard, change nothing else, and the
# same run must delete the file outside the namespace. Without this, "PS-7
# passes" is indistinguishable from "PS-7 cannot fail".
MU7="$B/mu7bin"; mkdir -p "$MU7"
sed 's|^ *if ! p5_removable "$RROLE" "$sd_p" file; then$|                            if false; then # MUTANT|' \
    "$P5DIR/bin/p5-uninstall" > "$MU7/p5-uninstall"
a=0
cmp -s "$MU7/p5-uninstall" "$P5DIR/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: SELFDROP's point-of-use gate was not found"; }
ps7_setup m7
if [ "$a" = 0 ] && ps7_run m7 "$MU7/p5-uninstall"; then
    if [ -e "$R/etc/operator/p5-common.sh" ]; then
        bad "MU-PS7" "with SELFDROP's point-of-use gate neutralised the operator file SURVIVED -- PS-7 is not the bar that catches this (rc=$(cat "$B/m7.rc"))"
    else
        ok "MU-PS7" "MUTATION: with SELFDROP's point-of-use gate neutralised the SAME run unlinks $R/etc/operator/p5-common.sh, a path outside the P5 namespace -- PS-7 is a bar that can fail (rc=$(cat "$B/m7.rc"))"
    fi
else
    bad "MU-PS7" "the mutation did not run (applied=$([ "$a" = 0 ] && echo yes || echo NO), swap landed=$([ -L "$R/usr/lib/p5" ] && echo yes || echo no)) -- MU-PS7 FAILS rather than skipping"
fi

p5t_report "p5-pathsanity" "$P5T_LEDGER" "$pass" "$fail"
