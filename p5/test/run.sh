#!/bin/sh
# p5/test/run.sh -- the E0 skeleton battery.
#
# Runs the REAL shipped scripts against a temp root ($P5_ROOT), the same way
# orchestration/ecosim/p5/run.sh exercises the reconciler artifacts rather than
# a copy of them. Stdlib only: sh, sha256sum, find, grep, sed, install.
#
# Output shape mirrors the Layer-2 harness: "p5-skeleton: N passed, M failed",
# exit 1 on any failure. No bar is skipped silently -- a bar that cannot run
# because a tool is missing FAILS and says which tool.
#
# EVERY BAR THAT ASSERTS A SAFETY PROPERTY HAS A MUTATION BESIDE IT. The rule
# this battery is written to is the one that failed three reviews on the sibling
# unit: a claim that a failure mode is impossible must name the mechanism AND
# the test. So the MU-* bars deliberately break the thing the safety bar
# protects and assert the bar goes red. A bar that cannot fail is not evidence.
#
# WHAT THIS BATTERY DOES NOT PROVE, stated here so a green run is not read as
# more than it is:
#   - it does not run under busybox ash. There is no busybox on the development
#     machine (Windows; Python 3.12 only, no WSL/Docker). The bashism bar is a
#     STATIC lint, not an execution proof on the target interpreter.
#   - it does not install anything on a real box, and no P5 install has ever
#     existed on hardware.
#   - it cannot simulate a FULL DISK. Atomicity is by construction (stage
#     beside, sync, rename) and the rename half is exercised; ENOSPC is not.
#   - the HP-* bars fire a REPRODUCTION of OpenWrt's /sbin/hotplug-call, not
#     netifd. What they establish is that the shipped staging name is invisible
#     to a scanner of that SHAPE -- a shell glob plus [ -f ] -- and that the
#     round-1 name was not. A scanner that enumerated with `find` or `ls -a`
#     would still see the stage; hotplug-call does not, and it is the only
#     activator E0 ships a destination into. Nothing here has seen a real
#     iface event.
#   - it cannot probe a UCI object: a uci object is not relocatable by a test
#     root. The clean predicate reports those rows as UNPROBED rather than
#     guessing, and bar UN-7 asserts it says so.
#   - the deadman's TIMER limb spawns a real detached sleeper, which is not
#     waited on here. What is tested is the deadline logic that the timer, the
#     boot hook and a manual fire all share -- there is only one implementation.

set -u

here=$(cd "$(dirname "$0")" && pwd)
P5DIR=$(cd "$here/.." && pwd)
BIN="$P5DIR/bin"
LIB="$P5DIR/lib"
CON="$P5DIR/contract"

# The bar bookkeeping -- ok/bad/chk/yn, the ledger, the exclusive scratch
# directory and the self-checked summary -- lives in one file shared with
# pathsanity.sh. Read its header: it is where the "91 passed, 2 failed over 93
# PASS ids and no FAIL line" run is accounted for, and where the fold below
# stopped being a grep over printed output.
. "$here/ledger.sh"

# EXCLUSIVE, not `mkdir -p`. A scratch directory that already exists is another
# run's, or a killed run's leftover with a reused pid; adopting one shares a
# path with a second writer and lets its cleanup trap delete this run's
# fixtures. p5_fault_point's `kill -9 $$` means killed runs leave directories
# behind by design, so the leftovers are guaranteed, not incidental.
TMPBASE=$(p5t_workdir p5-e0-test) || {
    echo "FAIL  TMP  could not create an exclusively-owned scratch directory under ${TMPDIR:-/tmp} -- refusing to share one"
    echo
    echo "p5-skeleton: 0 passed, 1 failed"
    exit 1
}
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT
p5t_ledger_init "$TMPBASE/ledger" || { echo "FAIL  TMP  cannot write the bar ledger"; exit 1; }

need_tool() {
    command -v "$1" >/dev/null 2>&1 || { bad "TOOL" "required tool missing: $1"; return 1; }
}
need_tool sha256sum || true
need_tool install || true

# ===========================================================================
# CONTRACT bars
# ===========================================================================

# NS-1: contract/namespace is parseable and every row is well formed.
ns_bad=0
while IFS='|' read -r r pat; do
    case "$r" in ''|\#*) continue ;; esac
    case "$r" in both|client|server) : ;; *) echo "  bad role: $r"; ns_bad=$((ns_bad + 1)); continue ;; esac
    case "$pat" in /*) : ;; *) echo "  pattern not absolute: $pat"; ns_bad=$((ns_bad + 1)) ;; esac
done < "$CON/namespace"
chk "$(yn "$([ "$ns_bad" = 0 ]; echo $?)")" "NS-1" "contract/namespace parses, every row role+absolute pattern"

# NS-2: contract/paths is parseable and every row is well formed, and the two
# fields that decide behaviour -- kind and state -- agree with each other.
pa_bad=0; pa_rows=0
while IFS='|' read -r kind role path owner state note; do
    case "$kind" in ''|\#*) continue ;; esac
    kind=$(echo "$kind" | tr -d ' '); role=$(echo "$role" | tr -d ' ')
    path=$(echo "$path" | tr -d ' '); owner=$(echo "$owner" | tr -d ' ')
    state=$(echo "$state" | tr -d ' ')
    pa_rows=$((pa_rows + 1))
    case "$kind"  in dir|file|glob|staging|uci) : ;; *) echo "  bad kind: $kind"; pa_bad=$((pa_bad + 1)) ;; esac
    case "$role"  in both|client|server) : ;; *) echo "  bad role: $role"; pa_bad=$((pa_bad + 1)) ;; esac
    case "$state" in install|payload|runtime|reserved|transient|enable|uci) : ;; *) echo "  bad state: $state"; pa_bad=$((pa_bad + 1)) ;; esac
    # kind=uci and state=uci are the same claim written twice; either alone is
    # a row the code would mis-route (a uci object is not a filesystem path).
    if [ "$kind" = uci ] || [ "$state" = uci ]; then
        [ "$kind" = uci ] && [ "$state" = uci ] || { echo "  kind/state uci mismatch: $kind/$state $path"; pa_bad=$((pa_bad + 1)); }
        case "$path" in *.*) : ;; *) echo "  uci row is not config.object: $path"; pa_bad=$((pa_bad + 1)) ;; esac
    else
        case "$path" in /*) : ;; *) echo "  path not absolute: $path"; pa_bad=$((pa_bad + 1)) ;; esac
    fi
    [ -n "$owner" ] || { echo "  empty owner for $path"; pa_bad=$((pa_bad + 1)); }
    [ -n "$note" ]  || { echo "  empty note for $path"; pa_bad=$((pa_bad + 1)); }
done < "$CON/paths"
chk "$(yn "$([ "$pa_bad" = 0 ] && [ "$pa_rows" -gt 0 ]; echo $?)")" "NS-2" "contract/paths parses ($pa_rows rows), kinds/states/roles in range, uci rows coherent, every row carries an owner and a reason"

# NS-3: DISJOINTNESS. No path can be claimed by both P5 and a foreign stack.
# This is the machine-checked form of the claim the whole standalone-product
# shape rests on -- and, since E0 decided to install BESIDE the old stack
# rather than after removing it, it is now also what makes that ordering safe.
#
# TESTED IN BOTH DIRECTIONS, and that is not symmetry for its own sake. The
# first version of this bar only tested foreign-probe against namespace-pattern
# and MISSED a real collision: adding `both|/etc/bond/*` to the namespace was
# not caught, because the foreign probe `/etc/bond` does not match the pattern
# `/etc/bond/*` -- the containment runs the other way. Found by mutating the
# contract and watching the bar stay green.
reps() {   # reps PATTERN -> one concrete probe per line
    echo "$1"
    echo "$1" | sed 's:/\*$:/probe:'
    echo "$1" | sed 's:\*:probe:g'
}
disjoint() {   # disjoint NSFILE FOREIGNFILE -> prints collisions
    _d_ns="$1"; _d_fo="$2"
    while IFS='|' read -r fo fpat; do
        case "$fo" in ''|\#*) continue ;; esac
        case "$fpat" in uci:*) continue ;; esac
        for probe in $(reps "$fpat"); do
            while IFS='|' read -r nr npat; do
                case "$nr" in ''|\#*) continue ;; esac
                case "$probe" in $npat) echo "  COLLISION: foreign $fo|$fpat (as $probe) matches namespace $nr|$npat" ;; esac
            done < "$_d_ns"
        done
    done < "$_d_fo"
    while IFS='|' read -r nr npat; do
        case "$nr" in ''|\#*) continue ;; esac
        for probe in $(reps "$npat"); do
            while IFS='|' read -r fo fpat; do
                case "$fo" in ''|\#*) continue ;; esac
                case "$fpat" in uci:*) continue ;; esac
                case "$probe" in $fpat) echo "  COLLISION: namespace $nr|$npat (as $probe) matches foreign $fo|$fpat" ;; esac
            done < "$_d_fo"
        done
    done < "$_d_ns"
}
coll=$(disjoint "$CON/namespace" "$CON/foreign" | tee "$TMPBASE/coll" | grep -c .)
[ "$coll" = 0 ] || cat "$TMPBASE/coll"
chk "$(yn "$([ "$coll" = 0 ]; echo $?)")" "NS-3" "namespace and foreign path sets are DISJOINT in BOTH directions (no P5 path collides with P1/P2/P3/P4/GL)"

# MU-NS3: the disjointness bar can fail. Widen the namespace to reclaim an
# old-stack path and assert the collision is found and named.
MUTNS="$TMPBASE/mut-ns"
cp "$CON/namespace" "$MUTNS"; echo "both|/etc/bond/*" >> "$MUTNS"
mcoll=$(disjoint "$MUTNS" "$CON/foreign" | grep -c .)
chk "$(yn "$([ "$mcoll" -gt 0 ]; echo $?)")" "MU-NS3" "MUTATION: namespace widened to /etc/bond/* -> NS-3 finds $mcoll collision(s), so the bar is not vacuous"

# NS-4: every concrete path in contract/paths is admitted by the namespace for
# its role. A path in the inventory that the installer would refuse is a
# contract that contradicts itself.
adm_bad=0
while IFS='|' read -r kind role path owner state note; do
    case "$kind" in ''|\#*) continue ;; esac
    kind=$(echo "$kind" | tr -d ' '); role=$(echo "$role" | tr -d ' '); path=$(echo "$path" | tr -d ' ')
    [ "$kind" = staging ] && continue
    # A uci object is not a filesystem path, so the namespace rule -- which is
    # about the filesystem -- has nothing to say about it. NS-5 covers it.
    [ "$kind" = uci ] && continue
    hit=1
    while IFS='|' read -r nr npat; do
        case "$nr" in ''|\#*) continue ;; esac
        if [ "$nr" = both ] || [ "$role" = both ] || [ "$nr" = "$role" ]; then
            # A kind=glob row's PATH is itself a pattern, so glob-matching it
            # as a subject is wrong: the literal '[' in `[0-9][0-9]-p5` can
            # never be matched by the pattern `[0-9]`. Such a row is admitted
            # only by being verbatim one of the namespace patterns -- which is
            # the stricter test anyway, and is what keeps the two files from
            # drifting into two different spellings of the same claim.
            if [ "$kind" = glob ]; then
                [ "$path" = "$npat" ] && { hit=0; break; }
                # ...or by being covered by a broader pattern, which is how
                # /etc/p5/deadman/* is admitted by both|/etc/p5/*.
                case "$path" in $npat) hit=0; break ;; esac
            else
                case "$path" in $npat) hit=0; break ;; esac
            fi
        fi
    done < "$CON/namespace"
    [ "$hit" = 0 ] || { echo "  not admitted by namespace: $role $path"; adm_bad=$((adm_bad + 1)); }
done < "$CON/paths"
chk "$(yn "$([ "$adm_bad" = 0 ]; echo $?)")" "NS-4" "every inventoried filesystem path is admitted by the namespace rule for its role"

# NS-5: the uci objects P5 owns are disjoint from the ones the old stack owns,
# and every one names a config P5 does not own as a FILE. That second half is
# the whole reason the unit of ownership is the object: if P5 could claim the
# file, "remove precisely P5" would stop being decidable for /etc/config/firewall.
uci_bad=0; uci_rows=0
while IFS='|' read -r kind role path owner state note; do
    case "$kind" in ''|\#*) continue ;; esac
    kind=$(echo "$kind" | tr -d ' '); path=$(echo "$path" | tr -d ' ')
    [ "$kind" = uci ] || continue
    uci_rows=$((uci_rows + 1))
    grep -q "^[a-z0-9]*|uci:$path\$" "$CON/foreign" && { echo "  P5 claims a uci object the old stack owns: $path"; uci_bad=$((uci_bad + 1)); }
    cfg="/etc/config/${path%%.*}"
    grep -q "|$cfg\$" "$CON/foreign" || { echo "  uci object $path names $cfg, which is NOT on the foreign list -- so P5 could also claim the file"; uci_bad=$((uci_bad + 1)); }
done < "$CON/paths"
chk "$(yn "$([ "$uci_bad" = 0 ] && [ "$uci_rows" -gt 0 ]; echo $?)")" "NS-5" "P5's $uci_rows uci object(s) are disjoint from the old stack's, and each lives in a config file that is foreign to P5"

# PATH-ADR5: every ADR-005 §4 destination resolves to a contract/paths row.
# ADR-005 is the destination map deploy/p5 renames onto; a contract that does
# not carry all twelve destinations it names contradicts the ADR it cites.
# Literal destinations, not derived: this bar is a translation check, not a
# re-derivation of ADR-005's own reasoning.
path_adr5_check() {   # path_adr5_check PATHSFILE -> prints each destination
                       # ADR-005 §4 names that PATHSFILE has no row for
    _p5="$1"
    for d in \
        /usr/sbin/p5-datapath \
        /usr/sbin/p5 \
        /usr/sbin/p5-reconciler \
        /usr/sbin/p5-ecod \
        /usr/sbin/p5-watchdog \
        /etc/init.d/p5-datapath \
        /etc/init.d/p5-ecod \
        /etc/init.d/p5-watchdog \
        '/etc/hotplug.d/iface/[0-9][0-9]-p5' \
        /usr/lib/p5/dag \
        '/etc/p5/*' \
        '/var/run/p5/*' \
    ; do
        _found=0
        while IFS='|' read -r _k _r _path _o _s _n; do
            case "$_k" in ''|\#*) continue ;; esac
            _path=$(echo "$_path" | tr -d ' ')
            [ "$_path" = "$d" ] && { _found=1; break; }
        done < "$_p5"
        [ "$_found" = 1 ] || echo "  ADR-005 §4 destination has no contract/paths row: $d"
    done
}
adr5_bad=$(path_adr5_check "$CON/paths" | tee "$TMPBASE/adr5" | grep -c .)
[ "$adr5_bad" = 0 ] || cat "$TMPBASE/adr5"
chk "$(yn "$([ "$adr5_bad" = 0 ]; echo $?)")" "PATH-ADR5" "every ADR-005 §4 destination (12) resolves to a contract/paths row"

# MU-PATH-ADR5: the bar can fail. Drop one of the seven rows U51 added and
# assert PATH-ADR5 is the one that goes red, while NS-3 (disjointness) is
# untouched by a paths-file-only mutation and still passes both directions.
MUTPA="$TMPBASE/mut-paths"
grep -v '^file|client|/usr/sbin/p5-reconciler' "$CON/paths" > "$MUTPA"
mu_adr5_bad=$(path_adr5_check "$MUTPA" | grep -c .)
mu_ns3_coll=$(disjoint "$CON/namespace" "$CON/foreign" | grep -c .)
chk "$(yn "$([ "$mu_adr5_bad" -gt 0 ] && [ "$mu_ns3_coll" = 0 ]; echo $?)")" "MU-PATH-ADR5" "MUTATION: p5-reconciler row dropped -> PATH-ADR5 finds $mu_adr5_bad missing destination(s), NS-3 unaffected ($mu_ns3_coll collisions)"

# ===========================================================================
# LINT bars
# ===========================================================================
# THE SHIPPED SET = what goes to a box, and therefore what must be
# busybox-safe and constant-free. This harness is NOT in that set: it runs on
# the developer machine and on the CI runner, never on a router, and its lint
# patterns contain the very strings the lints look for -- linting the linter
# would be a guaranteed self-match, not a finding.
#
# The set is carried in the positional parameters, NOT in a space-joined
# string. That is not a style preference: the repo path on this machine
# contains a space ("Claude Code"), so an unquoted `for f in $SHIPPED` splits
# every path in half, `grep` gets filenames that do not exist, finds nothing,
# and EVERY LINT BAR PASSES VACUOUSLY. That is what the first version of this
# file did. The `linted` counter below is the guard against it recurring: a bar
# that did not actually open the files it claims to have checked FAILS.
set -- "$BIN/p5-install" "$BIN/p5-uninstall" "$BIN/p5-version" "$BIN/p5-deadman" "$LIB/p5-common.sh"
N_SHIPPED=5

BASHISM='\[\[|(^|[^a-zA-Z_])local[[:space:]]|^[[:space:]]*function[[:space:]]|echo[[:space:]]+-e|(^|[^a-zA-Z_.])source[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*\['
CONSTANT='^[^#]*(sleep[[:space:]]+[0-9]|START=[0-9]|STOP=[0-9]|respawn[[:space:]]+[0-9]|:[0-9]{4,5}([^0-9]|$)|timeout[[:space:]]*=?[[:space:]]*[0-9]|retries[[:space:]]*=[[:space:]]*[0-9])'
# Privileged-path LANGUAGE. Words, not idioms: these are checked in prose too,
# because the N-generic rule binds comments as much as code. `head -1` is
# deliberately NOT in this list -- it is a truncation idiom, dangerous when
# applied to a SOURCE LIST and unremarkable when applied to a lookup, and a
# word-grep cannot tell the two apart. What replaces it is L-5, which asserts
# the stronger and checkable property: E0 code never enumerates sources at all.
PRIVPATH='primary|secondary|backup path|first wan|two_wans|both wans|dual-wan assum'
# Source enumeration in CODE. If E0 never names a source, it cannot privilege one.
SRCENUM='(^|[^a-z])wan[0-9]?([^a-z]|$)|ifname|AGG_PATHS|eth[0-9]|usb[0-9]|wwan|rmnet'

# strip_comments FILE -> the file with `#` comments removed, for lints that are
# about executable text. Known blind spot, named rather than hidden: it also
# truncates at a `#` inside a parameter expansion such as ${x#*|}, so it can
# MISS code after one. A lint that misses is acceptable; a lint that invents is
# not, and this direction of error is the safe one.
strip_comments() { sed 's/#.*//' "$1"; }

# L-1: no bashisms. The targets are busybox ash. Checked statically because no
# busybox interpreter exists on this machine (see the header).
bash_bad=0; linted=0
for f in "$@"; do
    [ -f "$f" ] || { echo "  not a file: $f"; bash_bad=$((bash_bad + 1)); continue; }
    linted=$((linted + 1))
    if strip_comments "$f" | grep -nE "$BASHISM" >/dev/null 2>&1; then
        echo "  bashism in $f:"; strip_comments "$f" | grep -nE "$BASHISM" | sed 's/^/    /'
        bash_bad=$((bash_bad + 1))
    fi
done
chk "$(yn "$([ "$bash_bad" = 0 ] && [ "$linted" = "$N_SHIPPED" ]; echo $?)")" \
    "L-1" "no bashisms in any shipped script ($linted/$N_SHIPPED files actually opened; static lint, NOT an ash execution proof)"

# L-2: every shipped script parses. The harness IS included here -- a syntax
# check cannot self-match.
syn_bad=0; linted=0
for f in "$@" "$here/run.sh" "$here/pathsanity.sh" "$here/ledger.sh"; do
    [ -f "$f" ] || { echo "  not a file: $f"; syn_bad=$((syn_bad + 1)); continue; }
    linted=$((linted + 1))
    sh -n "$f" 2>/dev/null || { echo "  syntax error: $f"; syn_bad=$((syn_bad + 1)); }
done
chk "$(yn "$([ "$syn_bad" = 0 ] && [ "$linted" = "$((N_SHIPPED + 3))" ]; echo $?)")" \
    "L-2" "sh -n clean on every shipped script ($linted/$((N_SHIPPED + 3)) files actually opened)"

# L-3: NO ARBITRARY CONSTANTS. E0 ships no tuned number: no sleeps with a
# literal duration, no retry counts, no ports, no procd priorities, no sizes.
# The numbers in the tree are exit codes, the contract schema version and one
# sha256 test vector -- none behavioural. p5-deadman's --after is the case that
# proves the rule: it is a REQUIRED argument with no default, so the number
# lives in the operator's command line and in the armed record, not here.
const_bad=0; linted=0
for f in "$@"; do
    [ -f "$f" ] || { const_bad=$((const_bad + 1)); continue; }
    linted=$((linted + 1))
    if grep -nE "$CONSTANT" "$f" >/dev/null 2>&1; then
        echo "  candidate constant in $f:"; grep -nE "$CONSTANT" "$f" | sed 's/^/    /'
        const_bad=$((const_bad + 1))
    fi
done
chk "$(yn "$([ "$const_bad" = 0 ] && [ "$linted" = "$N_SHIPPED" ]; echo $?)")" \
    "L-3" "no timeouts/retries/ports/priorities anywhere in E0 code ($linted/$N_SHIPPED files opened)"

# L-4: N-GENERIC. No privileged path, no 2-source assumption, in code OR prose.
ng_bad=0; linted=0
for f in "$@" "$CON/namespace" "$CON/paths" "$CON/foreign"; do
    [ -f "$f" ] || { ng_bad=$((ng_bad + 1)); continue; }
    linted=$((linted + 1))
    if grep -niE "$PRIVPATH" "$f" >/dev/null 2>&1; then
        echo "  privileged-path language in $f:"; grep -niE "$PRIVPATH" "$f" | sed 's/^/    /'
        ng_bad=$((ng_bad + 1))
    fi
done
chk "$(yn "$([ "$ng_bad" = 0 ] && [ "$linted" = "$((N_SHIPPED + 3))" ]; echo $?)")" \
    "L-4" "no privileged-path or 2-source language in E0 code or contract prose ($linted/$((N_SHIPPED + 3)) files opened)"

# L-5: N-GENERIC, the checkable form. E0 is the packaging layer: it never needs
# to know how many sources exist, or what they are called.
src_bad=0; linted=0
for f in "$@"; do
    [ -f "$f" ] || { src_bad=$((src_bad + 1)); continue; }
    linted=$((linted + 1))
    if strip_comments "$f" | grep -nE "$SRCENUM" >/dev/null 2>&1; then
        echo "  source enumeration in $f:"; strip_comments "$f" | grep -nE "$SRCENUM" | sed 's/^/    /'
        src_bad=$((src_bad + 1))
    fi
done
chk "$(yn "$([ "$src_bad" = 0 ] && [ "$linted" = "$N_SHIPPED" ]; echo $?)")" \
    "L-5" "E0 code never enumerates a network source, so it cannot privilege one ($linted/$N_SHIPPED files opened)"

# P-1: the E0 file set is complete.
pset_bad=0
for f in bin/p5-install bin/p5-uninstall bin/p5-version bin/p5-deadman lib/p5-common.sh \
         contract/namespace contract/paths contract/foreign \
         README.md CONTRACT.md test/run.sh test/pathsanity.sh test/ledger.sh; do
    [ -f "$P5DIR/$f" ] || { echo "  MISSING p5/$f"; pset_bad=$((pset_bad + 1)); }
done
chk "$(yn "$([ "$pset_bad" = 0 ]; echo $?)")" "P-1" "the E0 shipped file set is complete"

# P-2: the entry points are executable IN THE GIT INDEX, not merely on this
# filesystem. This machine has core.filemode=false, so `[ -x ]` is true for
# every file here and cannot see the problem; the first commit of this tree
# recorded all four as 100644, which on the Linux runner would have made the
# executability checks fail for a reason nothing local could reproduce. The
# index mode is the only representation both platforms agree on.
if command -v git >/dev/null 2>&1 && git -C "$P5DIR" rev-parse --git-dir >/dev/null 2>&1; then
    mode_bad=0; checked=0
    for f in bin/p5-install bin/p5-uninstall bin/p5-version bin/p5-deadman test/run.sh; do
        m=$(git -C "$P5DIR" ls-files -s "$f" 2>/dev/null | cut -d' ' -f1)
        if [ -z "$m" ]; then
            echo "  not tracked (cannot check mode): p5/$f"; mode_bad=$((mode_bad + 1)); continue
        fi
        checked=$((checked + 1))
        [ "$m" = 100755 ] || { echo "  p5/$f is $m in the index, must be 100755"; mode_bad=$((mode_bad + 1)); }
    done
    chk "$(yn "$([ "$mode_bad" = 0 ] && [ "$checked" = 5 ]; echo $?)")" "P-2" "all five entry points are 100755 in the git index ($checked/5 checked)"
else
    bad "P-2" "cannot reach the git index to check file modes -- this bar FAILS rather than skipping (see the header)"
fi

# ===========================================================================
# INSTALLER bars -- the real scripts, hermetic root, NO STUBS
# ===========================================================================
# There is no stub uninstaller any more, and that is a strengthening rather
# than a tidy-up. The clean-box precondition used to be computed by shelling
# out to $P5_UNINSTALL, so every install bar below ran with the precondition
# replaced by `exit 0` -- the gate was never exercised by the bars that
# depended on it. It is now computed in-process from p5_box_state, so these
# bars drive the real gate.

PROV="$TMPBASE/PROVENANCE.good"
cat > "$PROV" <<'EOF'
P5_PRODUCT=p5
P5_VERSION=0.0.0-test
P5_GIT_COMMIT=0000000000000000000000000000000000000000
P5_GIT_BRANCH=u25-e0-skeleton
P5_GIT_DIRTY=no
P5_BUILT_UTC=1970-01-01T00:00:00Z
EOF

# mkpkg DIR [ROLE] -- build a valid package. The DEFAULT client filemap ships
# THREE destinations, in three different parent directories, on purpose:
#
#   /usr/sbin/p5-datapath              a plain payload binary
#   /etc/init.d/p5-datapath            a procd service -- so IN-9c ("nothing
#                                      was enabled") can actually fail, and so
#                                      /etc/init.d gets CREATED by the install
#   /etc/hotplug.d/iface/94-p5         a glob-declared destination in a
#                                      directory the install must create
#
# Round 1's package shipped exactly one destination, which made IN-9c vacuous
# (the directories it tested for could not exist whatever the installer did)
# and made the directory-recording defect invisible: with only /usr/sbin
# created, /etc/init.d and /etc/hotplug.d/iface never entered installed.dirs
# in the battery even though a real filemap put them there. Extra filemap rows
# come from stdin so each bar can inject exactly the row it is testing.
mkpkg() {
    _pd="$1"; _prole="${2:-client}"
    mkdir -p "$_pd/payload"
    printf 'hello\n' > "$_pd/payload/p5-datapath.bin"
    printf '#!/bin/sh\nexit 0\n' > "$_pd/payload/initd.sh"
    printf '#!/bin/sh\nexit 0\n' > "$_pd/payload/hotplug.sh"
    {
        echo "# mode|role|src|dest"
        if [ "$_prole" = client ]; then
            echo "755|client|p5-datapath.bin|/usr/sbin/p5-datapath"
            echo "755|client|initd.sh|/etc/init.d/p5-datapath"
            echo "755|client|hotplug.sh|/etc/hotplug.d/iface/94-p5"
        else
            echo "755|server|p5-datapath.bin|/usr/sbin/p5-server"
            echo "755|server|initd.sh|/etc/init.d/p5-server"
        fi
        cat
    } > "$_pd/payload/filemap"
    cp "$PROV" "$_pd/PROVENANCE"
    ( cd "$_pd" && find payload -type f | sort | xargs sha256sum > MANIFEST.sha256 )
}
remanifest() { ( cd "$1" && find payload -type f | sort | xargs sha256sum > MANIFEST.sha256 ); }

inst() {  # inst ROOT PKG ROLE [extra args...]
    _r="$1"; _p="$2"; _ro="$3"; shift 3
    P5_ROOT="$_r" sh "$BIN/p5-install" --package "$_p" --role "$_ro" "$@" >"$TMPBASE/out" 2>"$TMPBASE/err"
}
unin() {  # unin ROOT [args...]
    _r="$1"; shift
    P5_ROOT="$_r" sh "$BIN/p5-uninstall" "$@" >"$TMPBASE/uout" 2>"$TMPBASE/uerr"
}

# IN-1: no arguments -> usage
P5_ROOT="$TMPBASE/r1" sh "$BIN/p5-install" >/dev/null 2>&1; rc=$?
chk "$(yn "$([ "$rc" = 2 ]; echo $?)")" "IN-1" "no arguments -> exit 2 (usage), rc=$rc"

# IN-2: package dir absent -> precondition
inst "$TMPBASE/r2" "$TMPBASE/nope" client; rc=$?
chk "$(yn "$([ "$rc" = 5 ]; echo $?)")" "IN-2" "missing package -> exit 5 (precondition), rc=$rc"

# IN-3: a payload file changed after the manifest was made -> integrity.
P=$TMPBASE/pkg3; mkpkg "$P" </dev/null
printf 'tampered\n' > "$P/payload/p5-datapath.bin"
inst "$TMPBASE/r3" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 3 ]; echo $?)")" "IN-3" "payload tampered after manifest -> exit 3 (integrity), rc=$rc"

# IN-4: a payload file that the manifest does not pin -> integrity.
P=$TMPBASE/pkg4; mkpkg "$P" </dev/null
printf 'stowaway\n' > "$P/payload/unpinned.bin"
inst "$TMPBASE/r4" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 3 ]; echo $?)")" "IN-4" "unpinned payload file -> exit 3 (integrity), rc=$rc"

# IN-5: a destination outside the P5 namespace -> contract violation.
P=$TMPBASE/pkg5; mkpkg "$P" <<'EOF'
755|client|p5-datapath.bin|/usr/sbin/whatever
EOF
remanifest "$P"
inst "$TMPBASE/r5" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 4 ]; echo $?)")" "IN-5" "destination outside the namespace -> exit 4 (contract), rc=$rc"

# IN-6: THE historical defect, as a bar. The deploy runbook seeded
# /etc/bond/agg_w with an invented 20000,15000 and silently defeated U6
# (removed in 52a76d3). A package that tries it now is refused by name.
P6=$TMPBASE/pkg6; mkpkg "$P6" <<'EOF'
644|client|p5-datapath.bin|/etc/bond/agg_w
EOF
remanifest "$P6"
inst "$TMPBASE/r6" "$P6" client; rc=$?
grep -q 'FOREIGN' "$TMPBASE/err" && named=0 || named=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ]; echo $?)")" "IN-6" "packaging /etc/bond/agg_w -> exit 4, refusal names the FOREIGN stack, rc=$rc"

# IN-6b: DEFENCE IN DEPTH, tested rather than claimed. Widen the namespace so
# it explicitly admits the old stack's config dir, and the same package is
# STILL refused -- because p5_check_dest consults contract/foreign BEFORE
# contract/namespace. This is what makes contract/foreign worth shipping even
# though the namespace rule alone would normally cover it.
P5_ROOT="$TMPBASE/r6b" P5_CONTRACT_NS="$MUTNS" \
    sh "$BIN/p5-install" --package "$P6" --role client >/dev/null 2>"$TMPBASE/err"; rc=$?
grep -q 'FOREIGN' "$TMPBASE/err" && named=0 || named=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ]; echo $?)")" "IN-6b" "even with the namespace widened to admit /etc/bond/*, the foreign check still refuses it first (rc=$rc)"

# MG-1: THE MANAGEMENT PATH IS UNREACHABLE FROM A FILEMAP. The mechanism is
# that contract/foreign carries an explicit management-path class and
# p5_check_dest consults it BEFORE the namespace; the test is this bar, which
# packages a file at every one of those destinations and asserts each is
# refused with exit 4 and a refusal that names the origin. This is the whole
# of E0's claim that it cannot cut the branch the operator is sitting on --
# E0 writes files and nothing else, so a destination gate is a complete gate
# for E0. It is NOT complete for E5/E7, which take ACTIONS; that is what
# p5-deadman is for.
mg_bad=0; mg_n=0
for dest in /etc/config/dropbear /etc/init.d/dropbear /etc/dropbear/authorized_keys \
            /etc/config/network /etc/config/firewall /etc/init.d/network \
            /etc/init.d/firewall /etc/rc.d/S19dropbear /etc/rc.d/S20network ; do
    mg_n=$((mg_n + 1))
    PM=$TMPBASE/pkgmg; rm -rf "$PM"; mkpkg "$PM" <<EOF
644|client|p5-datapath.bin|$dest
EOF
    remanifest "$PM"
    inst "$TMPBASE/rmg" "$PM" client; rc=$?
    rm -rf "$TMPBASE/rmg"
    [ "$rc" = 4 ] || { echo "  NOT refused with exit 4 (rc=$rc): $dest"; mg_bad=$((mg_bad + 1)); continue; }
    grep -q 'FOREIGN' "$TMPBASE/err" || { echo "  refused but did not name the foreign origin: $dest"; mg_bad=$((mg_bad + 1)); }
done
chk "$(yn "$([ "$mg_bad" = 0 ] && [ "$mg_n" -gt 0 ]; echo $?)")" "MG-1" "every management-path destination ($mg_n of them: sshd, network, firewall and their boot flags) is refused with exit 4 naming the foreign origin"

# IN-16: the installer cannot seed configuration. /etc/p5/* is declared
# state=runtime, so a filemap row targeting a fact file is refused even though
# /etc/p5 is squarely inside P5's own namespace. This is the /etc/bond/agg_w
# defect closed at the level above the path list.
PS=$TMPBASE/pkgseed; mkpkg "$PS" <<'EOF'
644|client|p5-datapath.bin|/etc/p5/sources
EOF
remanifest "$PS"
inst "$TMPBASE/rseed" "$PS" client; rc=$?
grep -q 'NOT DECLARED' "$TMPBASE/err" && named=0 || named=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ]; echo $?)")" "IN-16" "a filemap that seeds a fact into /etc/p5 -> exit 4: the installer cannot write configuration it did not measure (rc=$rc)"

# IN-7: nothing declared for this role -> an empty install is not a success.
P=$TMPBASE/pkg7; mkpkg "$P" </dev/null
inst "$TMPBASE/r7" "$P" server; rc=$?
chk "$(yn "$([ "$rc" = 5 ]; echo $?)")" "IN-7" "a client-only filemap installed with --role server -> exit 5, not a silent success, rc=$rc"

# IN-8: PROVENANCE is VALIDATED, not merely grepped. Round 1 carried it through
# with a bare grep and no check that anything matched, so a garbage PROVENANCE
# produced exit 0 and a stamp carrying none of the fields it exists for. An
# unvalidated stamp is worse than none: it looks authoritative.
prov_bad=0; prov_n=0
for mutate in 'P5_GIT_COMMIT=deadbeef' 'P5_GIT_DIRTY=maybe' 'P5_PRODUCT=notp5' \
              'P5_BUILT_UTC=yesterday' 'P5_VERSION=' 'DELETE:P5_GIT_COMMIT' ; do
    prov_n=$((prov_n + 1))
    PP=$TMPBASE/pkgprov; rm -rf "$PP"; mkpkg "$PP" </dev/null
    case "$mutate" in
        DELETE:*) grep -v "^${mutate#DELETE:}=" "$PROV" > "$PP/PROVENANCE" ;;
        *) k=${mutate%%=*}; grep -v "^$k=" "$PROV" > "$PP/PROVENANCE"; echo "$mutate" >> "$PP/PROVENANCE" ;;
    esac
    inst "$TMPBASE/rprov" "$PP" client; rc=$?
    n=$(find "$TMPBASE/rprov" -type f 2>/dev/null | wc -l)
    rm -rf "$TMPBASE/rprov"
    [ "$rc" = 3 ] && [ "$n" = 0 ] || { echo "  PROVENANCE mutation '$mutate' gave rc=$rc, files=$n (want rc=3, files=0)"; prov_bad=$((prov_bad + 1)); }
done
chk "$(yn "$([ "$prov_bad" = 0 ] && [ "$prov_n" -gt 0 ]; echo $?)")" "IN-8" "all $prov_n PROVENANCE mutations -> exit 3 and zero files written; a stamp is never written from provenance nobody checked"

# IN-8b: a fake hasher is caught by the test vector. P5_SHA256 is an override,
# and announcing it is not enough: a program that prints plausible hashes would
# defeat the manifest check AND the install record while every message stayed
# reassuring.
cat > "$TMPBASE/fakehash" <<'EOF'
#!/bin/sh
echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
EOF
chmod +x "$TMPBASE/fakehash"
P=$TMPBASE/pkg8b; mkpkg "$P" </dev/null
P5_ROOT="$TMPBASE/r8b" P5_SHA256="$TMPBASE/fakehash" \
    sh "$BIN/p5-install" --package "$P" --role client >/dev/null 2>"$TMPBASE/err"; rc=$?
grep -q 'test vector' "$TMPBASE/err" && named=0 || named=1
n=$(find "$TMPBASE/r8b" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 3 ] && [ "$named" = 0 ] && [ "$n" = 0 ]; echo $?)")" "IN-8b" "a P5_SHA256 that does not compute sha256 -> exit 3 naming the test vector, 0 files written (rc=$rc)"

# IN-17: THE CLEAN-BOX PRECONDITION CANNOT BE DEFEATED FROM THE ENVIRONMENT.
# Mechanism: it is computed in-process from p5_box_state, so there is no
# external program to substitute. Tested two ways -- the variable appears
# nowhere in the installer, and setting it changes nothing.
# Comments are stripped first: the variable is NAMED in the explanation of why
# it is gone, and a bar that could not tell an explanation from a use would
# force the explanation to be deleted to stay green.
u_refs=$(sed 's/#.*//' "$BIN/p5-install" | grep -c 'P5_UNINSTALL')
[ -n "$u_refs" ] || u_refs=0
R9=$TMPBASE/r9; P9=$TMPBASE/pkg9; mkpkg "$P9" </dev/null
inst "$R9" "$P9" client; rc=$?
chk "$(yn "$([ "$rc" = 0 ]; echo $?)")" "IN-9a" "valid package + clean box -> exit 0 with NO stubbed check anywhere, rc=$rc"

P5_ROOT="$R9" P5_UNINSTALL=/bin/true sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1; rc2=$?
chk "$(yn "$([ "$u_refs" = 0 ] && [ "$rc2" = 5 ]; echo $?)")" \
    "IN-17" "P5_UNINSTALL appears $u_refs times in p5-install and setting it to /bin/true still refuses the second install (rc=$rc2): the bypass does not exist rather than being defended against"

# IN-9b: everything the contract says an install places is present.
in9b=0
for f in /usr/sbin/p5-datapath /etc/init.d/p5-datapath /etc/hotplug.d/iface/94-p5 \
         /usr/lib/p5/stamp /usr/lib/p5/installed.files /usr/lib/p5/installed.dirs \
         /usr/lib/p5/p5-common.sh /usr/lib/p5/contract-namespace \
         /usr/lib/p5/contract-foreign /usr/lib/p5/contract-paths \
         /usr/sbin/p5-uninstall /usr/sbin/p5-version /usr/sbin/p5-deadman ; do
    [ -f "$R9$f" ] || { echo "  MISSING after install: $f"; in9b=$((in9b + 1)); }
done
chk "$(yn "$([ "$in9b" = 0 ]; echo $?)")" "IN-9b" "payload, stamp, both records, the library, all three contract copies and all three on-box entry points are present"

# IN-9c: NOTHING WAS ENABLED OR STARTED -- and this bar can now FAIL. Round 1's
# version tested for the absence of /etc/init.d, /etc/rc.d and /etc/hotplug.d
# on a root where the package shipped ONE file into /usr/sbin, so none of those
# directories could have existed whatever the installer did. The package now
# ships an init script and a hotplug hook, so /etc/init.d and
# /etc/hotplug.d/iface DO exist; the live assertion is the one that matters --
# no /etc/rc.d, i.e. nothing was enabled -- and the bar also asserts the two
# directories that prove it is looking at a tree where they could have been.
ic_pre=0
[ -d "$R9/etc/init.d" ] || { echo "  the package's init script did not land -- this bar would be vacuous"; ic_pre=1; }
[ -d "$R9/etc/hotplug.d/iface" ] || { echo "  the package's hotplug hook did not land -- this bar would be vacuous"; ic_pre=1; }
ic_bad=0
[ -e "$R9/etc/rc.d" ] && { echo "  install created /etc/rc.d: something was ENABLED"; ic_bad=1; }
n_links=$(find "$R9" -type l 2>/dev/null | wc -l)
[ "$n_links" = 0 ] || { echo "  install created $n_links symlink(s); E0 creates none"; ic_bad=1; }
chk "$(yn "$([ "$ic_bad" = 0 ] && [ "$ic_pre" = 0 ]; echo $?)")" "IN-9c" "install enabled and started nothing: no /etc/rc.d and 0 symlinks, on a tree where /etc/init.d and /etc/hotplug.d/iface DO exist so the bar is live"

# MU-9c: prove IN-9c's live assertion can fail.
mkdir -p "$R9/etc/rc.d"; ln -s "/etc/init.d/p5-datapath" "$R9/etc/rc.d/S94p5-datapath" 2>/dev/null || touch "$R9/etc/rc.d/S94p5-datapath"
mu_bad=0
[ -e "$R9/etc/rc.d" ] || mu_bad=1
chk "$(yn "$([ "$mu_bad" = 0 ]; echo $?)")" "MU-9c" "MUTATION: an rc.d flag planted under the install root is visible to IN-9c's predicate, so IN-9c is able to fail"

# UN-7 / B4: the clean predicate SEES the enable-time flag. This is the state
# the install-time record is structurally incapable of covering, and round 1's
# predicate had no idea it existed.
unin "$R9" --check --scope p5 --role client; rc=$?
grep -q 'S94p5-datapath' "$TMPBASE/uout" && a=0 || a=1
grep -q 'state=enable' "$TMPBASE/uout" && b=0 || b=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a$b" = 00 ]; echo $?)")" "UN-7" "the clean predicate reports the enable-time rc.d flag by name and by declared state (rc=$rc) -- a path created AFTER the installer exits"
rm -rf "$R9/etc/rc.d"

# UN-8: the predicate reports its own blind spot. A CLEAN verdict that silently
# skipped a row it could not probe is the shape of the defect this replaces.
unin "$TMPBASE/empty-u8" --check --scope p5 --role server; rc=$?
grep -q 'UNPROBED' "$TMPBASE/uout" && a=0 || a=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$a" = 0 ]; echo $?)")" "UN-8" "--check names every declared row it could NOT probe (the uci object under a test root), so a green verdict carries the size of its blind spot"

# ===========================================================================
# B3 -- the clean predicate covers EVERY declared path, derived not written
# ===========================================================================
# Round 1's predicate tested four locations out of twelve declared rows, so a
# root carrying seven declared P5 paths printed "P5 half: CLEAN". The predicate
# is now p5_present_paths over contract/paths, so this bar is generated FROM
# the contract: every non-staging, non-uci row is planted, one at a time, on an
# otherwise-empty root, and --check must find it. Adding a row to the inventory
# adds a case here with no edit.
cov_bad=0; cov_n=0
while IFS='|' read -r kind role path owner state note; do
    case "$kind" in ''|\#*) continue ;; esac
    kind=$(echo "$kind" | tr -d ' '); role=$(echo "$role" | tr -d ' '); path=$(echo "$path" | tr -d ' ')
    case "$kind" in staging|uci) continue ;; esac
    [ "$role" = both ] && role=client
    # A glob row's path is a pattern; plant a concrete instance of it.
    concrete=$(echo "$path" | sed 's:\[SK\]:S:; s:\[0-9\]\[0-9\]:94:; s:\[0-9\]\[0-9\]:94:; s:\*:probe:g')
    RC=$TMPBASE/cov; rm -rf "$RC"
    mkdir -p "$RC$(dirname "$concrete")"
    if [ "$kind" = dir ]; then mkdir -p "$RC$concrete"; else printf 'x\n' > "$RC$concrete"; fi
    cov_n=$((cov_n + 1))
    P5_ROOT="$RC" sh "$BIN/p5-uninstall" --check --scope p5 --role "$role" >"$TMPBASE/cov.out" 2>&1; crc=$?
    if [ "$crc" = 0 ] || ! grep -q "NOT CLEAN" "$TMPBASE/cov.out"; then
        echo "  CLEAN reported on a root carrying declared path: $concrete (kind=$kind state=$state rc=$crc)"
        cov_bad=$((cov_bad + 1))
    fi
done < "$CON/paths"
rm -rf "$TMPBASE/cov"
chk "$(yn "$([ "$cov_bad" = 0 ] && [ "$cov_n" -gt 4 ]; echo $?)")" "CL-1" "the clean predicate detects EVERY ONE of the $cov_n declared non-uci paths planted alone on an empty root (round 1 checked 4)"

# CL-2: the predicate is DERIVED, so a row added to the contract extends it
# with no code change. Add a row to a contract copy, plant that path, assert it
# is found -- with the shipped code untouched.
MUTP="$TMPBASE/mut-paths"
cp "$CON/paths" "$MUTP"
echo 'file|both  |/usr/lib/p5/invented           |E0 |install |a row that exists only in this test copy' >> "$MUTP"
RC=$TMPBASE/cl2; rm -rf "$RC"; mkdir -p "$RC/usr/lib/p5"; printf 'x\n' > "$RC/usr/lib/p5/invented"
P5_ROOT="$RC" P5_CONTRACT_PATHS="$MUTP" sh "$BIN/p5-uninstall" --check --scope p5 --role client >"$TMPBASE/cl2.out" 2>&1; rc=$?
grep -q '/usr/lib/p5/invented' "$TMPBASE/cl2.out" && a=0 || a=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ]; echo $?)")" "CL-2" "a path declared ONLY in a contract copy is detected by the unmodified predicate: the predicate is derived, not written (rc=$rc)"

# ===========================================================================
# B1 -- the record records ITSELF. Counted, not asserted.
# ===========================================================================
# Round 1 placed 9 files and recorded 6; the delta was the stamp and the two
# record files, and an E7 that obeyed the contract verbatim would have left
# them, kept /usr/lib/p5 non-empty, and wedged the box against its own
# reinstall. This bar counts both sides on the real tree.
n_disk=$(find "$R9" -type f 2>/dev/null | wc -l)
n_rec=$(grep -c . "$R9/usr/lib/p5/installed.files" 2>/dev/null); [ -n "$n_rec" ] || n_rec=0
n_self=$(grep -c "^self-referential  " "$R9/usr/lib/p5/installed.files" 2>/dev/null); [ -n "$n_self" ] || n_self=0
missing=$(find "$R9" -type f 2>/dev/null | sed "s:^$R9::" | sort > "$TMPBASE/ondisk"
          awk '{ if (NF >= 2) print $2 }' "$R9/usr/lib/p5/installed.files" | sort > "$TMPBASE/inrec"
          comm -23 "$TMPBASE/ondisk" "$TMPBASE/inrec")
[ -n "$missing" ] && { echo "  ON DISK BUT NOT RECORDED:"; echo "$missing" | sed 's/^/    /'; }
chk "$(yn "$([ "$n_disk" = "$n_rec" ] && [ -z "$missing" ] && [ "$n_self" = 1 ]; echo $?)")" \
    "RC-1" "every file on the installed tree is in installed.files: $n_disk on disk, $n_rec recorded, exactly $n_self self-referential row (round 1: 9 placed, 6 recorded)"

# RC-2: the record is complete in the other direction too -- nothing recorded
# that is not on disk.
extra=$(comm -13 "$TMPBASE/ondisk" "$TMPBASE/inrec")
[ -n "$extra" ] && { echo "  RECORDED BUT NOT ON DISK:"; echo "$extra" | sed 's/^/    /'; }
chk "$(yn "$([ -z "$extra" ]; echo $?)")" "RC-2" "nothing is recorded that is not on disk"

# ===========================================================================
# B2 -- installed.dirs is structurally incapable of naming a shared directory
# ===========================================================================
# The measured round-1 set on this very filemap was /etc/hotplug.d/iface,
# /etc/init.d, /etc/p5, /usr/lib/p5, /usr/sbin -- three of them shared system
# directories that p5_check_dest itself refuses. The install above created
# /usr/sbin, /etc/init.d and /etc/hotplug.d/iface, so if the defect were still
# present this bar would see it.
dirs_recorded=$(cat "$R9/usr/lib/p5/installed.dirs" 2>/dev/null | tr '\n' ' ')
dr_bad=0; dr_n=0
while read -r d; do
    [ -n "$d" ] || continue
    dr_n=$((dr_n + 1))
    P5_ROOT="" P5_CONTRACT_NS="$CON/namespace" P5_CONTRACT_FOREIGN="$CON/foreign" P5_CONTRACT_PATHS="$CON/paths" \
        sh -c '. "$1/p5-common.sh"; p5_declared client "$2" dir install' _ "$LIB" "$d" >/dev/null 2>&1 \
        || { echo "  installed.dirs names a directory that is NOT a contract dir row: $d"; dr_bad=$((dr_bad + 1)); }
done < "$R9/usr/lib/p5/installed.dirs"
# and the three shared directories the install DID create must NOT be there
for d in /usr/sbin /etc/init.d /etc/hotplug.d/iface /etc /usr /usr/lib; do
    [ -d "$R9$d" ] || continue
    grep -qxF "$d" "$R9/usr/lib/p5/installed.dirs" && { echo "  SHARED DIRECTORY IN THE REMOVAL RECORD: $d"; dr_bad=$((dr_bad + 1)); }
done
chk "$(yn "$([ "$dr_bad" = 0 ] && [ "$dr_n" -gt 0 ]; echo $?)")" \
    "DR-1" "installed.dirs holds $dr_n entry/ies, every one a contract dir row, and none of the shared directories this install created ($dirs_recorded)"

# IN-10: EVERY path the install created is admitted by the contract. Round 1
# walked `find -type f` only while its comment claimed it checked "EVERY path
# the install created", so the directory defect it was meant to catch was
# invisible to it. It now walks files, directories AND symlinks.
audit() {   # audit ROOT ROLE -> prints one line per stray
    _a_r="$1"; _a_ro="$2"
    find "$_a_r" -type f 2>/dev/null | sed "s:^$_a_r::" | while read -r f; do
        P5_ROOT="" P5_CONTRACT_NS="$CON/namespace" P5_CONTRACT_FOREIGN="$CON/foreign" P5_CONTRACT_PATHS="$CON/paths" \
            sh -c '. "$1/p5-common.sh"; p5_check_dest "$3" "$2"' _ "$LIB" "$f" "$_a_ro" >/dev/null 2>&1 \
            || echo "STRAY FILE (not admitted by the contract): $f"
    done
    find "$_a_r" -type d 2>/dev/null | sed "s:^$_a_r::" | while read -r d; do
        [ -n "$d" ] || continue
        # A directory is legitimate if P5 declares it, or if it is an ancestor
        # of a file that is on the tree (i.e. the install had to create it to
        # place something). A directory that is neither is a stray -- which is
        # exactly what an empty rogue directory is, and what a -type f walk
        # could never see.
        P5_ROOT="" P5_CONTRACT_NS="$CON/namespace" P5_CONTRACT_FOREIGN="$CON/foreign" P5_CONTRACT_PATHS="$CON/paths" \
            sh -c '. "$1/p5-common.sh"; p5_declared "$3" "$2" dir "install runtime"' _ "$LIB" "$d" "$_a_ro" >/dev/null 2>&1 && continue
        [ -n "$(find "$_a_r$d" -type f 2>/dev/null | head -1)" ] && continue
        echo "STRAY DIRECTORY (undeclared and holds no installed file): $d"
    done
    find "$_a_r" -type l 2>/dev/null | sed "s:^$_a_r::" | while read -r l; do
        echo "STRAY SYMLINK (E0 creates none): $l"
    done
}
strays=$(audit "$R9" client)
[ -n "$strays" ] && echo "$strays" | sed 's/^/  /'
chk "$(yn "$([ -z "$strays" ]; echo $?)")" "IN-10" "every FILE, DIRECTORY and SYMLINK on the installed tree is accounted for by the contract"

# MU-10: prove IN-10 can fail, in all three of the ways it now looks.
mkdir -p "$R9/etc/rogue"
printf 'x\n' > "$R9/usr/sbin/notp5"
ln -s /dev/null "$R9/usr/lib/p5/alink" 2>/dev/null || true
mstr=$(audit "$R9" client)
mf=$(echo "$mstr" | grep -c 'STRAY FILE')
md=$(echo "$mstr" | grep -c 'STRAY DIRECTORY')
chk "$(yn "$([ "$mf" -ge 1 ] && [ "$md" -ge 1 ]; echo $?)")" \
    "MU-10" "MUTATION: a rogue file and an EMPTY rogue directory are both found ($mf file, $md directory) -- the -type f walk round 1 shipped could see neither"
rm -rf "$R9/etc/rogue" "$R9/usr/sbin/notp5" "$R9/usr/lib/p5/alink"

# IN-11: installing over an existing install is refused, and names the remedy.
inst "$R9" "$P9" client; rc=$?
grep -q 'p5-uninstall --remove' "$TMPBASE/err" && named=0 || named=1
chk "$(yn "$([ "$rc" = 5 ] && [ "$named" = 0 ]; echo $?)")" "IN-11" "second install over an existing one -> exit 5 naming the remedy, no in-place upgrade, rc=$rc"

# IN-12: --dry-run runs every check, writes nothing, and PRINTS THE WHOLE PLAN
# including the removal set. On a box nobody can walk up to, the plan has to be
# readable before it is executed.
R12=$TMPBASE/r12
inst "$R12" "$P9" client --dry-run; rc=$?
n=$(find "$R12" 2>/dev/null | wc -l)
a=0
grep -q '/usr/sbin/p5-datapath' "$TMPBASE/out" || a=1
grep -q 'would CREATE and OWN' "$TMPBASE/out" || a=1
grep -q 'resulting removal set' "$TMPBASE/out" || a=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$n" = 0 ] && [ "$a" = 0 ]; echo $?)")" "IN-12" "--dry-run passes every check, writes 0 paths, and prints the placement AND removal sets (rc=$rc, paths=$n)"

# IN-13: the installer leaves no scratch behind on the abort paths.
#
# COUNTED IN A PRIVATE TMPDIR, not the shared one. This bar used to count
# `p5-install.*` under ${TMPDIR:-/tmp} -- a directory every other process on the
# machine writes to. Measured during U25's adjudication run: 21 concurrent p5
# scratch entries in /tmp, and the bar failed with `before=2 after=1` -- the
# count went DOWN, which this bar's own install cannot cause, because one of
# somebody else's runs finished mid-bar. It was non-deterministic in both
# directions and could report a defect that is not there and miss one that is.
# A private TMPDIR makes before/after a statement about THIS installer, which is
# what the bar claims. (Same shared-state class as the unexplained 91/2 summary
# recorded in README.md's known limits.)
IN13T=$TMPBASE/tmp13; rm -rf "$IN13T"; mkdir -p "$IN13T"
before=$(find "$IN13T" -maxdepth 1 -name 'p5-install.*' 2>/dev/null | wc -l)
P5_ROOT="$TMPBASE/r13" TMPDIR="$IN13T" sh "$BIN/p5-install" --package "$P6" --role client \
    >"$TMPBASE/out" 2>"$TMPBASE/err"; rc=$?
after=$(find "$IN13T" -maxdepth 1 -name 'p5-install.*' 2>/dev/null | wc -l)
chk "$(yn "$([ "$before" = "$after" ] && [ "$rc" != 0 ]; echo $?)")" "IN-13" "a REFUSED install (rc=$rc) leaves no scratch dir behind in a PRIVATE TMPDIR (before=$before after=$after)"

# IN-14 / IN-15: the ONE hand-maintained list in the product is barred from
# drifting from the contract, in both directions.
MUTP2="$TMPBASE/mut-paths-extra"
cp "$CON/paths" "$MUTP2"
echo 'file|both  |/usr/lib/p5/neverplaced        |E0 |install |declared but nothing places it' >> "$MUTP2"
P5_ROOT="$TMPBASE/r14" P5_CONTRACT_PATHS="$MUTP2" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>"$TMPBASE/err"; rc=$?
grep -q 'neverplaced' "$TMPBASE/err" && named=0 || named=1
n=$(find "$TMPBASE/r14" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ] && [ "$n" = 0 ]; echo $?)")" \
    "IN-14" "a file DECLARED in the contract that the installer never places -> exit 4 naming it, 0 files written (rc=$rc)"

MUTP3="$TMPBASE/mut-paths-missing"
grep -v '/usr/sbin/p5-deadman' "$CON/paths" > "$MUTP3"
P5_ROOT="$TMPBASE/r15" P5_CONTRACT_PATHS="$MUTP3" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>"$TMPBASE/err"; rc=$?
grep -q 'p5-deadman' "$TMPBASE/err" && named=0 || named=1
n=$(find "$TMPBASE/r15" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ] && [ "$n" = 0 ]; echo $?)")" \
    "IN-15" "a file the installer PLACES that the contract does not declare -> exit 4 naming it, 0 files written (rc=$rc)"

# ===========================================================================
# STAMP / PROVENANCE bars (against the install from IN-9)
# ===========================================================================
vrun() { P5_ROOT="$R9" sh "$BIN/p5-version" "$@"; }

vrun >"$TMPBASE/stamp.out" 2>&1; rc=$?
miss=""
for k in P5_CONTRACT_VERSION P5_ROLE P5_PRODUCT P5_VERSION P5_GIT_COMMIT P5_GIT_BRANCH \
         P5_GIT_DIRTY P5_BUILT_UTC P5_PKG_MANIFEST_SHA256 P5_INSTALLED_UTC \
         P5_INSTALL_ARCH P5_INSTALL_FILES P5_INSTALL_DIRS P5_E1_VERDICT \
         P5_INSTALL_OVERRIDES P5_CONTRACT_NS_SHA256 P5_CONTRACT_FOREIGN_SHA256 \
         P5_CONTRACT_PATHS_SHA256; do
    grep -q "^$k=" "$TMPBASE/stamp.out" || miss="$miss $k"
done
chk "$(yn "$([ "$rc" = 0 ] && [ -z "$miss" ]; echo $?)")" "VS-1" "the stamp identifies the install completely (missing:${miss:- none})"

# VS-2: the git identity in the stamp is the package's, carried through verbatim.
want=$(grep '^P5_GIT_COMMIT=' "$P9/PROVENANCE" | head -1)
got=$(grep '^P5_GIT_COMMIT=' "$TMPBASE/stamp.out" | head -1)
chk "$(yn "$([ "$want" = "$got" ]; echo $?)")" "VS-2" "P5_GIT_COMMIT is carried verbatim from the package PROVENANCE"

# VS-3: E1 has not run, and the box says so rather than implying a default.
grep -q '^P5_E1_VERDICT=unmeasured' "$TMPBASE/stamp.out" && r=0 || r=1
chk "$r" "VS-3" "P5_E1_VERDICT=unmeasured -- the open hardware gate (G1) is visible ON THE BOX"

# VS-4: --verify passes on an untouched install, and the self-referential row
# is reported as such rather than skipped.
vrun --verify >"$TMPBASE/ver.out" 2>&1; rc=$?
grep -q 'SELFREF  /usr/lib/p5/installed.files' "$TMPBASE/ver.out" && a=0 || a=1
grep -q '1 self-referential' "$TMPBASE/ver.out" && b=0 || b=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$a$b" = 00 ]; echo $?)")" "VS-4" "--verify passes right after install and names the one self-referential row rather than skipping it, rc=$rc"

# VS-8: an install judged against a mutated contract is DETECTABLE ON THE BOX.
# Overrides are not refused (the harness and out-of-tree layouts need them);
# they are made indelible.
RID=$TMPBASE/rid
IDNS="$TMPBASE/id-ns"; cp "$CON/namespace" "$IDNS"
P5_ROOT="$RID" P5_CONTRACT_NS="$IDNS" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>"$TMPBASE/err"; rc=$?
grep -q 'ENVIRONMENT OVERRIDE IN EFFECT' "$TMPBASE/err" && a=0 || a=1
grep -q '^P5_INSTALL_OVERRIDES=.*P5_CONTRACT_NS' "$RID/usr/lib/p5/stamp" 2>/dev/null && b=0 || b=1
sha_ns=$(sha256sum "$IDNS" | cut -d' ' -f1)
grep -q "^P5_CONTRACT_NS_SHA256=$sha_ns\$" "$RID/usr/lib/p5/stamp" 2>/dev/null && c=0 || c=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$a$b$c" = 000 ]; echo $?)")" \
    "VS-8" "an override is announced on stderr AND recorded in the stamp by name AND by the sha256 of the contract actually used (rc=$rc)"

# VS-5 / VS-6: --verify detects drift and deletion and names the file.
printf 'drifted\n' >> "$R9/usr/sbin/p5-datapath"
vrun --verify >"$TMPBASE/ver.out" 2>&1; rc=$?
grep -q 'CHANGED  /usr/sbin/p5-datapath' "$TMPBASE/ver.out" && named=0 || named=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$named" = 0 ]; echo $?)")" "VS-5" "--verify detects a changed file and names it (rc=$rc)"

rm -f "$R9/usr/sbin/p5-datapath"
vrun --verify >"$TMPBASE/ver.out" 2>&1; rc=$?
grep -q 'MISSING  /usr/sbin/p5-datapath' "$TMPBASE/ver.out" && named=0 || named=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$named" = 0 ]; echo $?)")" "VS-6" "--verify detects a missing file and names it (rc=$rc)"

# VS-7: a box with no P5 says so, and says it with a non-zero status.
P5_ROOT="$TMPBASE/empty" sh "$BIN/p5-version" >/dev/null 2>&1; rc=$?
chk "$(yn "$([ "$rc" = 1 ]; echo $?)")" "VS-7" "p5-version on a box with no P5 -> exit 1, rc=$rc"

# VS-9: --state answers in EVERY state, including the ones with no stamp. It is
# the first thing an operator on a box that will not install should run.
P5_ROOT="$TMPBASE/empty" sh "$BIN/p5-version" --state >"$TMPBASE/st.out" 2>&1; rc=$?
grep -q '^P5_BOX_STATE=clean' "$TMPBASE/st.out" && a=0 || a=1
P5_ROOT="$RID" sh "$BIN/p5-version" --state >"$TMPBASE/st2.out" 2>&1
grep -q '^P5_BOX_STATE=installed' "$TMPBASE/st2.out" && b=0 || b=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$a$b" = 00 ]; echo $?)")" "VS-9" "--state names the box state on an empty root and on an installed one"

# ===========================================================================
# UNINSTALL / REMOVAL bars
# ===========================================================================
# UN-1: --list reproduces the install-time record.
unin "$RID" --list; rc=$?
n_rec=$(grep -cE '^([0-9a-f]{64}|self-referential)  /' "$RID/usr/lib/p5/installed.files")
n_list=$(grep -cE '^([0-9a-f]{64}|self-referential)  /' "$TMPBASE/uout")
chk "$(yn "$([ "$rc" = 0 ] && [ "$n_rec" = "$n_list" ] && [ "$n_rec" -gt 0 ]; echo $?)")" "UN-1" "--list prints the full install record ($n_list of $n_rec rows, rc=$rc)"

# UN-2: on a box that already carries P5, --check --scope p5 says NOT CLEAN.
unin "$RID" --check --scope p5 --role client; rc=$?
grep -q 'NOT CLEAN' "$TMPBASE/uout" && named=0 || named=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$named" = 0 ]; echo $?)")" "UN-2" "--check --scope p5 on an installed box -> exit 1, NOT CLEAN (rc=$rc)"

# UN-9: THE INSTALLED ENTRY POINT, run from the box rather than from the
# package. Every other uninstall bar invokes $BIN/p5-uninstall, whose sibling
# ../lib and ../contract exist, so it never exercises the on-box resolution
# path -- the one a real deploy uses, where the tool must find the library and
# all three contract copies under /usr/lib/p5 with the `contract-` prefix. A
# box with no package must still be able to describe and remove itself, and
# that claim is only worth anything if something runs it that way.
P5_ROOT="$RID" sh "$RID/usr/sbin/p5-uninstall" --check --scope p5 --role client >"$TMPBASE/box.out" 2>"$TMPBASE/box.err"; rc=$?
grep -q 'NOT CLEAN' "$TMPBASE/box.out" && a=0 || a=1
grep -q 'contract copies are missing' "$TMPBASE/box.err" && b=1 || b=0
P5_ROOT="$RID" sh "$RID/usr/sbin/p5-version" --state >"$TMPBASE/box2.out" 2>/dev/null
grep -q '^P5_BOX_STATE=installed' "$TMPBASE/box2.out" && c=0 || c=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a$b$c" = 000 ]; echo $?)")" \
    "UN-9" "the INSTALLED p5-uninstall and p5-version resolve their library and all three contract copies from /usr/lib/p5 with no package present, and answer correctly (rc=$rc)"

# UN-3: BOTH halves answer on an empty box, and neither invents work. The bar
# used to assert the old half returned exit 6 naming U26; U26 landed, so what
# it asserts now is the behaviour that replaced it. The "it gates the SWITCH,
# not the install" claim moved to OLD-1, which can actually see the sentence --
# it is printed on a DIRTY box, and this one is empty.
unin "$TMPBASE/empty2" --check --role client; rc=$?
grep -q 'P5 half: CLEAN' "$TMPBASE/uout" && a=0 || a=1
grep -q 'old half: CLEAN' "$TMPBASE/uout" && b=0 || b=1
grep -q 'NOT CLEAN' "$TMPBASE/uout" && c=1 || c=0
chk "$(yn "$([ "$rc" = 0 ] && [ "$a$b$c" = 000 ]; echo $?)")" "UN-3" "--check on an empty box -> exit 0, BOTH halves report CLEAN and neither invents an artifact (rc=$rc)"

# UN-4: --purge WITH NO --role, which is the form every remedy string in this
# product spells. The role has to come off the stamp, and the run has to stop at
# the management-path precondition having touched nothing -- on a box that is
# fully installed, so "removed nothing" is a measurement and not a tautology.
unin "$RID" --purge; rc=$?
# p5_log writes to STDOUT and p5_err to stderr, so the stamp-resolution line is
# read off uout and the refusal off uerr. Getting that wrong is a bar that fails
# for the wrong reason, which is worth no more than one that cannot fail.
grep -q 'role=client from the install stamp' "$TMPBASE/uout" && a=0 || a=1
grep -q 'management-path report' "$TMPBASE/uerr" && b=0 || b=1
grep -q 'CONTRACT.md:340-352' "$TMPBASE/uerr" && c=0 || c=1
left=$(find "$RID" -type f 2>/dev/null | wc -l | tr -d " ")
chk "$(yn "$([ "$rc" = 5 ] && [ "$a$b$c" = 000 ] && [ "$left" -gt 0 ]; echo $?)")" \
    "UN-4" "--purge with no --role resolves the role from the stamp, then REFUSES on the missing management-path report and removes nothing (rc=$rc, files still $left)"

# UN-6: an unknown verb is a usage error, not a silent no-op.
P5_ROOT="$RID" sh "$BIN/p5-uninstall" --wipe >/dev/null 2>&1; rc=$?
chk "$(yn "$([ "$rc" = 2 ]; echo $?)")" "UN-6" "unknown verb -> exit 2 (usage), rc=$rc"

# RM-1: --remove --dry-run prints the plan and changes NOTHING.
before=$(find "$RID" | sort | sha256sum)
unin "$RID" --remove --dry-run --role client; rc=$?
after=$(find "$RID" | sort | sha256sum)
a=0
grep -q '^UNLINK|/usr/lib/p5/stamp' "$TMPBASE/uout" || a=1
# The rmdir of the owned library directory must be NAMED in the plan. It used
# to be its own `RMDIR|/usr/lib/p5` action; the B2 fix moves it inside the
# final SELFDROP, because /usr/lib/p5 still holds the library and the contract
# copies the recovery verb reads. The assertion is unchanged -- the plan names
# that rmdir -- only the grammar it is written in moved, so the pattern accepts
# either spelling. It is NOT relaxed to a substring: both alternatives are
# anchored, so an rmdir of some other path cannot satisfy it.
grep -qE '^RMDIR\|/usr/lib/p5$|^SELFDROP\|(.* )?RMDIR:/usr/lib/p5( |$)' "$TMPBASE/uout" || a=1
grep -q 'rmdir, NEVER rm -rf' "$TMPBASE/uout" || a=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$before" = "$after" ] && [ "$a" = 0 ]; echo $?)")" \
    "RM-1" "--remove --dry-run prints the exact ordered plan and leaves the tree byte-identical (rc=$rc)"

# RM-2: the plan orders product metadata LAST, so the record outlives what it
# describes and an interrupted removal can resume.
ln_stamp=$(grep -n '^UNLINK|/usr/lib/p5/stamp' "$TMPBASE/uout" | head -1 | cut -d: -f1)
ln_payload=$(grep -n '^UNLINK|/usr/sbin/p5-datapath' "$TMPBASE/uout" | head -1 | cut -d: -f1)
ln_rmdir=$(grep -n '^RMDIR|' "$TMPBASE/uout" | head -1 | cut -d: -f1)
chk "$(yn "$([ -n "$ln_stamp" ] && [ -n "$ln_payload" ] && [ -n "$ln_rmdir" ] && [ "$ln_payload" -lt "$ln_stamp" ] && [ "$ln_stamp" -lt "$ln_rmdir" ]; echo $?)")" \
    "RM-2" "plan order is payload -> product metadata -> rmdir (lines $ln_payload < $ln_stamp < $ln_rmdir)"

# RM-3: --remove actually removes, and the box comes back CLEAN.
unin "$RID" --remove --role client; rc=$?
nf=$(find "$RID" -type f 2>/dev/null | wc -l)
unin "$RID" --check --scope p5 --role client; crc=$?
chk "$(yn "$([ "$rc" = 0 ] && [ "$nf" = 0 ] && [ "$crc" = 0 ]; echo $?)")" \
    "RM-3" "--remove leaves 0 files and a CLEAN P5 half (rc=$rc, files=$nf, check=$crc)"

# RM-4: the shared directories the install created are STILL THERE. They were
# never recorded, so they can never be removed -- which is the point.
sd_bad=0
for d in /usr/sbin /etc/init.d /etc/hotplug.d/iface; do
    [ -d "$RID$d" ] || { echo "  a shared system directory was REMOVED: $d"; sd_bad=$((sd_bad + 1)); }
done
gone=0
for d in /usr/lib/p5 /etc/p5 /etc/p5/deadman; do
    [ -d "$RID$d" ] && { echo "  an owned directory was NOT removed: $d"; gone=$((gone + 1)); }
done
chk "$(yn "$([ "$sd_bad" = 0 ] && [ "$gone" = 0 ]; echo $?)")" \
    "RM-4" "removal rmdir-ed exactly the 3 directories P5 owns and left /usr/sbin, /etc/init.d and /etc/hotplug.d/iface standing"

# RM-5: --remove is idempotent -- a second run is a clean no-op.
unin "$RID" --remove --role client; rc=$?
chk "$(yn "$([ "$rc" = 0 ]; echo $?)")" "RM-5" "a second --remove on an already-clean box -> exit 0, no-op (rc=$rc)"

# RM-6: THE ONE THAT WOULD HAVE ENDED THE BOX. Hand-write shared system
# directories into installed.dirs -- exactly the round-1 measured set -- and
# assert the removal refuses ENTIRELY and unlinks nothing. This is the
# version-skew case: a record written by an older, buggier installer.
RX=$TMPBASE/rx; inst "$RX" "$P9" client
printf '/usr/sbin\n/etc/init.d\n/etc/hotplug.d/iface\n' >> "$RX/usr/lib/p5/installed.dirs"
before=$(find "$RX" | sort | sha256sum)
unin "$RX" --remove --role client; rc=$?
after=$(find "$RX" | sort | sha256sum)
a=0
grep -q 'REFUSING THE ENTIRE REMOVAL' "$TMPBASE/uerr" || a=1
grep -q 'dir|/usr/sbin' "$TMPBASE/uerr" || a=1
grep -q 'dir|/etc/init.d' "$TMPBASE/uerr" || a=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$before" = "$after" ] && [ "$a" = 0 ]; echo $?)")" \
    "RM-6" "installed.dirs hand-loaded with /usr/sbin, /etc/init.d and /etc/hotplug.d/iface -> the WHOLE removal is refused (exit 4), the offenders are named, and the tree is byte-identical (rc=$rc)"

# RM-7: the same for a FILE the contract does not declare. A record naming
# /etc/dropbear/authorized_keys must not be obeyed.
sed 's:  /usr/sbin/p5-datapath$:  /etc/dropbear/authorized_keys:' "$RX/usr/lib/p5/installed.files" > "$TMPBASE/fr.new"
cp "$TMPBASE/fr.new" "$RX/usr/lib/p5/installed.files"
grep -v '^/usr/sbin$' "$RX/usr/lib/p5/installed.dirs" | grep -v '^/etc/init.d$' | grep -v '^/etc/hotplug.d/iface$' > "$RX/usr/lib/p5/installed.dirs.new"
mv "$RX/usr/lib/p5/installed.dirs.new" "$RX/usr/lib/p5/installed.dirs"
before=$(find "$RX" | sort | sha256sum)
unin "$RX" --remove --role client; rc=$?
after=$(find "$RX" | sort | sha256sum)
grep -q 'file|/etc/dropbear/authorized_keys' "$TMPBASE/uerr" && a=0 || a=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$before" = "$after" ] && [ "$a" = 0 ]; echo $?)")" \
    "RM-7" "a record naming a management-path FILE is refused by name and nothing is unlinked (rc=$rc)"

# RM-8: a non-empty owned directory is REPORTED, not forced. rmdir cannot take
# a subtree with it; rm -rf could.
RY=$TMPBASE/ry; inst "$RY" "$P9" client
# /usr/lib/p5, not /etc/p5. /etc/p5/* IS a declared runtime glob (E6's facts),
# so a file there is P5's own and the plan correctly sweeps it -- which the
# first version of this bar mistook for a defect. /usr/lib/p5 has no glob row,
# so a file there is genuinely not P5's and rmdir must refuse to take it.
printf 'someone else put this here\n' > "$RY/usr/lib/p5/stranger"
unin "$RY" --remove --role client; rc=$?
grep -q 'NOT EMPTY, left in place: /usr/lib/p5' "$TMPBASE/uerr" && a=0 || a=1
[ -f "$RY/usr/lib/p5/stranger" ] && b=0 || b=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a$b" = 00 ]; echo $?)")" \
    "RM-8" "an owned directory holding a file P5 did not place is reported and LEFT (rc=$rc); the stranger's file survives because rmdir cannot force"

# RM-9: the runtime tmpfs directory is the only recursive removal, and it is
# reached only through the contract.
RZ=$TMPBASE/rz; inst "$RZ" "$P9" client
mkdir -p "$RZ/var/run/p5/sub"; printf 'x\n' > "$RZ/var/run/p5/sub/state"
unin "$RZ" --remove --dry-run --role client
grep -q '^RMTREE|/var/run/p5$' "$TMPBASE/uout" && a=0 || a=1
n_rmtree=$(grep -c '^RMTREE|' "$TMPBASE/uout")
unin "$RZ" --remove --role client; rc=$?
[ -e "$RZ/var/run/p5" ] && b=1 || b=0
chk "$(yn "$([ "$rc" = 0 ] && [ "$a$b" = 00 ] && [ "$n_rmtree" = 1 ]; echo $?)")" \
    "RM-9" "exactly $n_rmtree RMTREE in the plan, on the one declared runtime directory, and it cleared a populated /var/run/p5 (rc=$rc)"

# RM-10: THE `damaged` STATE AND ITS REMEDY. p5-install and p5-version both
# name `--remove --recover` as the way out of a box carrying P5 paths with no
# record. An untested remedy is exactly the defect class this unit is fixing,
# so it is exercised end to end: refuse by default, print a plan, clear the
# box, and install again.
RW=$TMPBASE/rw; inst "$RW" "$P9" client
rm -f "$RW/usr/lib/p5/stamp" "$RW/usr/lib/p5/installed.files" "$RW/usr/lib/p5/installed.dirs"
P5_ROOT="$RW" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=damaged' && a=0 || a=1
before=$(find "$RW" | sort | sha256sum)
unin "$RW" --remove --role client; rc=$?
after=$(find "$RW" | sort | sha256sum)
grep -q 'remove --recover' "$TMPBASE/uerr" && b=0 || b=1
[ "$before" = "$after" ] && c=0 || c=1
unin "$RW" --remove --recover --dry-run --role client; drc=$?
after2=$(find "$RW" | sort | sha256sum)
grep -q '^UNLINK|/usr/sbin/p5-datapath' "$TMPBASE/uout" && d=0 || d=1
[ "$before" = "$after2" ] && e=0 || e=1
unin "$RW" --remove --recover --role client; rrc=$?
nf=$(find "$RW" -type f 2>/dev/null | wc -l)
inst "$RW" "$P9" client; irc=$?
chk "$(yn "$([ "$a$b$c$d$e" = 00000 ] && [ "$rc" = 5 ] && [ "$drc" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ] && [ "$irc" = 0 ]; echo $?)")" \
    "RM-10" "a record-less box reports state=damaged, --remove REFUSES it (exit $rc) naming --recover, --recover --dry-run prints the plan and changes nothing, --recover clears it to $nf files, and the next install exits $irc"

# RM-11: VERSION SKEW. A stamp declaring a layout this build does not
# understand must stop every destructive verb, because the paths it does not
# know about are exactly the ones it would leave behind.
RV=$TMPBASE/rv; inst "$RV" "$P9" client
sed 's/^P5_CONTRACT_VERSION=.*/P5_CONTRACT_VERSION=999/' "$RV/usr/lib/p5/stamp" > "$TMPBASE/fv"; cp "$TMPBASE/fv" "$RV/usr/lib/p5/stamp"
P5_ROOT="$RV" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=future' && a=0 || a=1
before=$(find "$RV" | sort | sha256sum)
unin "$RV" --remove --role client; rc=$?
after=$(find "$RV" | sort | sha256sum)
inst "$RV" "$P9" client; irc=$?
chk "$(yn "$([ "$a" = 0 ] && [ "$rc" = 5 ] && [ "$irc" = 5 ] && [ "$before" = "$after" ]; echo $?)")" \
    "RM-11" "a stamp declaring contract version 999 puts the box in state=future: --remove refuses (exit $rc), --install refuses (exit $irc), and the tree is byte-identical"

# ---------------------------------------------------------------------------
# EXG-*: THE FILE SVCDOWN EXECUTES IS GATED, NOT JUST ITS NAME (U146).
#
# The defect these bars close: step a of emit_plan gated the /etc/rc.d FLAG
# (plan_gate -> p5_removable) and then emitted SVCDOWN for the service the flag
# names, and NOTHING asked who put /etc/init.d/<svc> on the box -- planner and
# executor both only anchored the NAME to p5|p5-*. SVCDOWN runs that file as
# root, twice. It was reproduced on the RECOVERY path with no rogue name and no
# contract edit, because the asymmetry is in the contract itself: the flag glob
# is role=both while the init scripts it points at are role=client/server, so
# the flag survives every role filter its own target does not.
#
# WHY A RECORD-LESS ROOT IS THE FIXTURE AND NOT AN EDGE CASE: `damaged` is the
# state --recover exists for, it is the state a box reaches by a crashed or
# pre-v3 install, and it is the one where the record cannot vouch for anything.
# U28's package puts /etc/init.d/p5-server on ${SERVER_PC_IP} -- no physical access,
# no console -- at install time, which is what made this reachable now.
#
# The rogue script WRITES A SENTINEL when it runs, so "did not execute" is a
# measured absence rather than an inference from an exit code.
mkexecroot() {
    _er="$1"; rm -rf "$_er"
    inst "$_er" "$P9" client
    # records stripped -> state=damaged: nothing on the box can vouch for what
    # is present, which is exactly when a p5-* NAME is worth nothing.
    rm -f "$_er/usr/lib/p5/stamp" "$_er/usr/lib/p5/installed.files" "$_er/usr/lib/p5/installed.dirs"
    mkdir -p "$_er/etc/init.d" "$_er/etc/rc.d"
    cat > "$_er/etc/init.d/p5-rogue" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$_er/rogue-ran"
exit 0
EOF
    chmod 755 "$_er/etc/init.d/p5-rogue"
    printf 'flag\n' > "$_er/etc/rc.d/S94p5-rogue"
}

# EXG-1: the planner refuses. An undeclared /etc/init.d/p5-rogue with its own
# rc.d flag, on a record-less root, must REFUSE THE WHOLE REMOVAL by name and
# execute nothing -- the same doctrine every other bad row here follows.
EX=$TMPBASE/rexec; mkexecroot "$EX"
a=0
P5_ROOT="$EX" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=damaged' \
    || { a=1; echo "  the fixture is not in state=damaged, so this bar is not on the recovery path"; }
before=$(find "$EX" | sort | sha256sum)
unin "$EX" --remove --recover --role client; rc=$?
after=$(find "$EX" | sort | sha256sum)
# The sentinel FIRST and by name: this is the whole finding. Its content is
# printed on failure, because "the rogue script ran as root" is the claim.
[ -e "$EX/rogue-ran" ] && { a=1; echo "  THE ROGUE SCRIPT RAN: $(tr '\n' ' ' < "$EX/rogue-ran")"; }
[ "$rc" = 4 ] || { a=1; echo "  exit was $rc, not 4 (contract) -- the refusal did not reach the exit status"; }
grep -q '/etc/init.d/p5-rogue' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name /etc/init.d/p5-rogue"; }
grep -q 'EXECUTE' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not say the file would have been EXECUTED"; }
[ "$before" = "$after" ] || { a=1; echo "  the tree changed: a refused plan unlinked something"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-1" "a record-less box carrying an UNDECLARED /etc/init.d/p5-rogue and its rc.d flag: --remove --recover refuses the whole removal (exit $rc), names the file and says it would have EXECUTED it, the sentinel is absent so the script never ran, and the tree is byte-identical"

# EXG-2: AND IT IS NOT A BLANKET REFUSAL. The same mechanism on a DECLARED init
# script -- /etc/init.d/p5-datapath, `file|client|...|reserved` in
# contract/paths -- still stops it, disables it and removes the flag.
EXD=$TMPBASE/rexecd; inst "$EXD" "$P9" client
cat > "$EXD/etc/init.d/p5-datapath" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$EXD/declared-ran"
exit 0
EOF
chmod 755 "$EXD/etc/init.d/p5-datapath"
mkdir -p "$EXD/etc/rc.d"; printf 'flag\n' > "$EXD/etc/rc.d/S94p5-datapath"
unin "$EXD" --remove --role client; rc=$?
a=0
grep -q '^RAN stop$' "$EXD/declared-ran" 2>/dev/null || { a=1; echo "  the declared service was never STOPPED -- the gate is a blanket refusal"; }
grep -q '^RAN disable$' "$EXD/declared-ran" 2>/dev/null || { a=1; echo "  the declared service was never DISABLED"; }
[ -e "$EXD/etc/rc.d/S94p5-datapath" ] && { a=1; echo "  the rc.d flag survived"; }
[ -e "$EXD/etc/init.d/p5-datapath" ] && { a=1; echo "  the init script survived"; }
[ "$rc" = 0 ] || { a=1; echo "  the removal exited $rc"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-2" "the DECLARED /etc/init.d/p5-datapath is still stopped and disabled normally (both invocations recorded), its rc.d flag and the script itself are gone, and the removal exits $rc -- the gate refuses undeclared files, not services"

# EXG-3: DEFENCE IN DEPTH, MEASURED. The plan is written to disk between build
# and execute, so the executor re-asks rather than trusting it -- the same rule
# UNLINK and RMTREE follow. Neutralise the PLANNER's gate only and the executor
# must still refuse: the sentinel stays absent and the run is non-zero.
EXM="$TMPBASE/execmut"
mkdir -p "$EXM/bin" "$EXM/lib" "$EXM/contract"
cp "$LIB/p5-common.sh" "$EXM/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$EXM/contract/"
sed 's|if ! p5_removable "$RROLE" "$svcf" file; then|if false; then|' "$BIN/p5-uninstall" > "$EXM/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$EXM/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the planner's executed-file gate was not found"; }
EXP=$TMPBASE/rexecp; mkexecroot "$EXP"
P5_ROOT="$EXP" sh "$EXM/bin/p5-uninstall" --remove --recover --role client >"$TMPBASE/xp.out" 2>"$TMPBASE/xp.err"; prc=$?
[ -e "$EXP/rogue-ran" ] && { a=1; echo "  the rogue script RAN with only the planner gate removed"; }
grep -q 'REFUSED SVCDOWN on p5-rogue' "$TMPBASE/xp.err" || { a=1; echo "  the executor did not refuse by name"; }
[ "$prc" = 4 ] || { a=1; echo "  the run exited $prc, not 4 (contract), after refusing to execute"; }
grep -q '^SVCDOWN|p5-rogue$' "$TMPBASE/xp.out" || { a=1; echo "  the mutant planner did not even emit the action, so this bar is vacuous"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-3" "with the PLANNER's executed-file gate removed the plan does emit SVCDOWN|p5-rogue, and the EXECUTOR still refuses it by name at the point of use and exits $prc: the sentinel is absent, so neither gate is decoration and the refusal reaches the exit status even though the P5 half ends up clean"

# MU-EXG: THE MUTATION. Both new gate calls removed -- the pre-U146 shape --
# and the same fixture EXECUTES the undeclared script as root. Without this,
# "EXG-1 passes" is indistinguishable from "EXG-1 cannot fail". The declared
# fixture is re-run against the SAME mutant and must still work, so the bar
# also pins that the gate is what changed and not the service handling.
EXM2="$TMPBASE/execmut2"
mkdir -p "$EXM2/bin" "$EXM2/lib" "$EXM2/contract"
cp "$LIB/p5-common.sh" "$EXM2/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$EXM2/contract/"
sed -e 's|if ! p5_removable "$RROLE" "$svcf" file; then|if false; then|' \
    -e 's|if ! p5_removable "$RROLE" "/etc/init.d/$arg" file; then|if false; then|' \
    "$BIN/p5-uninstall" > "$EXM2/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$EXM2/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: neither gate call site was found"; }
grep -q 'p5_removable "$RROLE" "/etc/init.d/$arg" file' "$EXM2/bin/p5-uninstall" && { a=1; echo "  the executor gate survived the mutation"; }
EXR=$TMPBASE/rexecm; mkexecroot "$EXR"
P5_ROOT="$EXR" sh "$EXM2/bin/p5-uninstall" --remove --recover --role client >"$TMPBASE/xm.out" 2>"$TMPBASE/xm.err"; mrc=$?
grep -q '^RAN stop$' "$EXR/rogue-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the rogue script's stop -- the seed did not bite"; }
grep -q '^RAN disable$' "$EXR/rogue-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the rogue script's disable"; }
EXD2=$TMPBASE/rexecd2; inst "$EXD2" "$P9" client
cat > "$EXD2/etc/init.d/p5-datapath" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$EXD2/declared-ran"
exit 0
EOF
chmod 755 "$EXD2/etc/init.d/p5-datapath"
mkdir -p "$EXD2/etc/rc.d"; printf 'flag\n' > "$EXD2/etc/rc.d/S94p5-datapath"
P5_ROOT="$EXD2" sh "$EXM2/bin/p5-uninstall" --remove --role client >/dev/null 2>&1; drc=$?
grep -q '^RAN stop$' "$EXD2/declared-ran" 2>/dev/null || { a=1; echo "  the DECLARED script was not stopped by the mutant, so EXG-2 is not measuring the gate"; }
[ "$drc" = 0 ] || { a=1; echo "  the mutant failed the declared removal (rc=$drc)"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-EXG" "MUTATION: with BOTH executed-file gates removed from the shipped uninstaller, the same record-less fixture EXECUTES /etc/init.d/p5-rogue as root -- stop and disable both recorded (exit $mrc) -- while the DECLARED script's removal is unchanged (exit $drc). EXG-1/EXG-3 are bars that can fail, and EXG-2 is not measuring the gate"

# A record-less (state=damaged) root with NO rogue file: `inst` then the records
# stripped. mkexecroot above always adds BOTH a flag and the script behind it,
# so the two ordinary shapes below -- a flag with nothing behind it, and a
# DECLARED service on the same record-less box -- had no fixture at all.
mkdamaged() {
    _dr="$1"; rm -rf "$_dr"
    inst "$_dr" "$P9" client
    rm -f "$_dr/usr/lib/p5/stamp" "$_dr/usr/lib/p5/installed.files" "$_dr/usr/lib/p5/installed.dirs"
    mkdir -p "$_dr/etc/init.d" "$_dr/etc/rc.d"
}

# EXG-4: THE STALE FLAG WHOSE TARGET IS ABSENT -- and the reason the gate is
# asked only when there is a file to execute.
#
# contract/paths:182 makes the rc.d glob role=both ON PURPOSE and says why: the
# flag can outlive its target. So /etc/rc.d/S94p5-rogue with NOTHING at
# /etc/init.d/p5-rogue is an ORDINARY state on a record-less box, not an attack
# -- and there is nothing there to execute. The first cut of the executed-file
# gate asked p5_removable about the NAME regardless, so that flag alone refused
# the WHOLE removal (exit 4, P5 left installed) where the pre-gate code cleared
# it and exited 0. On ${SERVER_PC_IP} -- no console -- that is a wedge, so this bar
# pins the PRE-GATE semantics: exit 0, flag gone, P5 gone, nothing executed.
EXS=$TMPBASE/rexecs; mkdamaged "$EXS"
printf 'flag\n' > "$EXS/etc/rc.d/S94p5-rogue"
a=0
[ -e "$EXS/etc/init.d/p5-rogue" ] && { a=1; echo "  the fixture HAS a target, so it is not the stale-flag case"; }
P5_ROOT="$EXS" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=damaged' \
    || { a=1; echo "  the fixture is not in state=damaged, so this bar is not on the recovery path"; }
unin "$EXS" --remove --recover --role client; rc=$?
[ "$rc" = 0 ] || { a=1; echo "  exit was $rc, not 0: a flag with no target refused the removal"; }
[ -e "$EXS/etc/rc.d/S94p5-rogue" ] && { a=1; echo "  the stale flag survived -- it is a declared p5 path and must go"; }
grep -q '^exec|' "$TMPBASE/uerr" && { a=1; echo "  an exec| refusal was raised for a name with no file behind it"; }
[ -e "$EXS/usr/sbin/p5-datapath" ] && { a=1; echo "  P5 is still installed after a removal that reported success"; }
nf=$(find "$EXS" -type f 2>/dev/null | wc -l | tr -d ' ')
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-4" "a record-less box whose /etc/rc.d/S94p5-rogue flag has NO /etc/init.d/p5-rogue behind it -- the state contract/paths:182 anticipates -- still removes cleanly: exit $rc, the stale flag is gone, P5 is gone ($nf files left), and no execution refusal was raised for a name with nothing to execute"

# EXG-5: A DECLARED SERVICE ON THE RECORD-LESS BOX. EXG-2 uses a fresh root
# whose install record is intact, so it cannot tell "the gate allows declared
# files" from "the gate is never reached when a record exists". This is the same
# assertion on the fixture the gate actually lives on.
EXDD=$TMPBASE/rexecdd; mkdamaged "$EXDD"
cat > "$EXDD/etc/init.d/p5-datapath" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$EXDD/declared-ran"
exit 0
EOF
chmod 755 "$EXDD/etc/init.d/p5-datapath"
printf 'flag\n' > "$EXDD/etc/rc.d/S94p5-datapath"
a=0
P5_ROOT="$EXDD" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=damaged' \
    || { a=1; echo "  the fixture is not in state=damaged"; }
unin "$EXDD" --remove --recover --role client; rc=$?
grep -q '^RAN stop$' "$EXDD/declared-ran" 2>/dev/null || { a=1; echo "  the declared service was never STOPPED on a damaged root"; }
grep -q '^RAN disable$' "$EXDD/declared-ran" 2>/dev/null || { a=1; echo "  the declared service was never DISABLED on a damaged root"; }
[ -e "$EXDD/etc/rc.d/S94p5-datapath" ] && { a=1; echo "  the rc.d flag survived"; }
[ -e "$EXDD/etc/init.d/p5-datapath" ] && { a=1; echo "  the declared init script survived"; }
[ "$rc" = 0 ] || { a=1; echo "  the recovery removal exited $rc"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-5" "on the SAME record-less fixture the gate lives on, the DECLARED /etc/init.d/p5-datapath is still stopped and disabled (both invocations recorded), its flag and the script are gone, and --remove --recover exits $rc: the gate reads the contract, not the record"

# EXG-6: THE PRINTED REMEDY CONVERGES -- both halves of it, measured by
# FOLLOWING WHAT WAS PRINTED rather than by reading the wording.
#
# A refusal that does not converge is a wedge with a help text. The first cut
# printed only `mv /etc/init.d/<file> /root/`, and following it re-ran into the
# identical refusal, because the gate was asked about the NAME and the flag was
# still there. Now the flag is named too, and either step ends the refusal. Run
# 1 refuses; run 2 follows the printed `mv` and must FINISH; a second fixture
# follows the printed `rm` and must finish while LEAVING the operator's file.
EXR1=$TMPBASE/rexecr1; mkexecroot "$EXR1"
unin "$EXR1" --remove --recover --role client; r1=$?
a=0
[ "$r1" = 4 ] || { a=1; echo "  run 1 exited $r1, not 4: the fixture did not reach the refusal"; }
mvf=$(sed -n 's/.*ERROR:  *mv \([^ ]*\) .*/\1/p' "$TMPBASE/uerr" | head -1)
rmf=$(sed -n 's/.*ERROR:  *rm \([^ ]*\).*/\1/p' "$TMPBASE/uerr" | head -1)
[ "$mvf" = "/etc/init.d/p5-rogue" ] || { a=1; echo "  the remedy did not name the FILE to move (got '$mvf')"; }
[ "$rmf" = "/etc/rc.d/S94p5-rogue" ] || { a=1; echo "  the remedy did not name the FLAG to drop (got '$rmf')"; }
# Follow the mv. /root is the printed destination; the assertion is that the
# file leaves /etc/init.d, so it is parked outside the fixture root.
mkdir -p "$TMPBASE/held1"; mv "$EXR1$mvf" "$TMPBASE/held1/" 2>/dev/null
unin "$EXR1" --remove --recover --role client; r2=$?
[ "$r2" = 0 ] || { a=1; echo "  after following the printed mv the run exited $r2, not 0 -- the remedy does not converge"; }
[ -e "$EXR1/rogue-ran" ] && { a=1; echo "  THE ROGUE SCRIPT RAN: $(tr '\n' ' ' < "$EXR1/rogue-ran")"; }
[ -e "$EXR1/etc/rc.d/S94p5-rogue" ] && { a=1; echo "  the flag survived the converged run"; }
[ -e "$EXR1/usr/sbin/p5-datapath" ] && { a=1; echo "  P5 is still installed after the converged run"; }
# The other half: drop the flag, keep the file. The operator's own script must
# still be there afterwards -- the product does not delete what it refused.
EXR2=$TMPBASE/rexecr2; mkexecroot "$EXR2"
unin "$EXR2" --remove --recover --role client; r3=$?
[ "$r3" = 4 ] || { a=1; echo "  the second fixture exited $r3, not 4, on the first run"; }
rm -f "$EXR2$rmf"
unin "$EXR2" --remove --recover --role client; r4=$?
[ "$r4" = 0 ] || { a=1; echo "  after following the printed rm the run exited $r4, not 0"; }
[ -e "$EXR2/rogue-ran" ] && { a=1; echo "  THE ROGUE SCRIPT RAN on the rm path: $(tr '\n' ' ' < "$EXR2/rogue-ran")"; }
[ -e "$EXR2/etc/init.d/p5-rogue" ] || { a=1; echo "  the file this product REFUSED to touch was deleted anyway"; }
[ -e "$EXR2/usr/sbin/p5-datapath" ] && { a=1; echo "  P5 is still installed after the rm-path run"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXG-6" "the refusal PRINTS both ends of the pair ($mvf and $rmf) and following either printed command converges: run 1 exits $r1, moving the named file makes run 2 exit $r2, and on a second fixture removing the named flag makes the run exit $r4 while the operator's script is left where it is -- the sentinel is absent on both paths, so nothing was executed to get there"

# UC-1: E0 NEVER COMMITS A UCI CONFIG, and the removal plan says so out loud.
# This is the one action anywhere in the product that could cut the operator's
# own SSH session -- `uci delete firewall.p5; uci commit firewall` reloads the
# firewall, and on the server the session rides it. The first version of
# --remove executed it. Mechanism: the plan carries UCIMANUAL, which the
# executor only ever PRINTS; the test is this bar, which asserts the plan names
# the object for the server role and that no executable line in the file
# performs the commit.
RU=$TMPBASE/ru; PSU=$TMPBASE/pkgsrv2; mkpkg "$PSU" server </dev/null
inst "$RU" "$PSU" server
unin "$RU" --remove --dry-run --role server
grep -q '^UCIMANUAL|firewall.p5$' "$TMPBASE/uout" && a=0 || a=1
grep -q 'UCIDEL' "$TMPBASE/uout" && b=1 || b=0
# Comments are stripped: the file EXPLAINS the command it refuses to run, and a
# bar that could not tell an explanation from an execution would force the
# explanation out.
n_commit=$(sed 's/#.*//' "$BIN/p5-uninstall" | grep -cE '^[^"]*uci -q (delete|commit)|^[[:space:]]*uci (delete|commit)')
[ -n "$n_commit" ] || n_commit=0
unin "$RU" --remove --role server; rc=$?
chk "$(yn "$([ "$a$b" = 00 ] && [ "$n_commit" = 0 ] && [ "$rc" = 0 ]; echo $?)")" \
    "UC-1" "the removal plan REPORTS the uci object as UCIMANUAL and $n_commit executable lines in p5-uninstall run a uci delete/commit: E0 never reloads the firewall unattended (rc=$rc)"

# ===========================================================================
# CRASH / INTERRUPT bars -- FM-3, the wedge
# ===========================================================================
# Round 1 could be killed between the last file placement and the stamp, after
# which p5_installed was false, p5_half_clean was false, --check returned 1, a
# retried install refused with exit 5, and --remove was NOT IMPLEMENTED. The
# box was wedged against both its own reinstall and its own removal.
#
# P5_FAULT_AFTER kills the installer HARD (kill -9, no trap, no cleanup) before
# write number N. This bar walks EVERY N until the install completes, and for
# each one asserts: the box names its state, a removal verb clears it, and the
# next install succeeds. That is the whole claim "an interrupted run can always
# be finished or undone", tested rather than asserted.
CRTMP="$TMPBASE/crtmp"; mkdir -p "$CRTMP"
cr_bad=0; cr_n=0; cr_recover=0; cr_states=""
N=1
while [ "$N" -le 40 ]; do
    RCR="$TMPBASE/cr$N"; rm -rf "$RCR"
    P5_ROOT="$RCR" TMPDIR="$CRTMP" P5_FAULT_AFTER="$N" \
        sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1
    crc=$?
    if [ "$crc" = 0 ]; then break ; fi   # past the last write: N exhausted
    cr_n=$((cr_n + 1))
    # 1. the box must NAME its state rather than being unrecognisable.
    P5_ROOT="$RCR" sh "$BIN/p5-version" --state >"$TMPBASE/cr.state" 2>/dev/null
    st=$(grep '^P5_BOX_STATE=' "$TMPBASE/cr.state" | head -1 | sed 's/.*=//')
    case "$st" in
        clean|incomplete|damaged) : ;;
        *) echo "  N=$N: box state is '$st', which no remedy is written for"; cr_bad=$((cr_bad + 1)) ;;
    esac
    cr_states="$cr_states $st"
    # 2. a removal verb must clear it. --remove first; --recover if the state
    #    is one where there is no record to remove FROM.
    P5_ROOT="$RCR" sh "$BIN/p5-uninstall" --remove --role client >/dev/null 2>&1; rrc=$?
    if [ "$rrc" != 0 ]; then
        P5_ROOT="$RCR" sh "$BIN/p5-uninstall" --remove --recover --role client >/dev/null 2>&1; rrc=$?
        cr_recover=$((cr_recover + 1))
    fi
    if [ "$rrc" != 0 ]; then
        echo "  N=$N: NO removal verb could clear the box (state=$st)"; cr_bad=$((cr_bad + 1)); N=$((N + 1)); continue
    fi
    # 3. the tree must be back to nothing but the shared directories.
    nf=$(find "$RCR" -type f 2>/dev/null | wc -l)
    [ "$nf" = 0 ] || { echo "  N=$N: $nf file(s) survived the removal"; cr_bad=$((cr_bad + 1)); }
    # 4. and the next install must succeed. This is the property round 1 lost.
    P5_ROOT="$RCR" TMPDIR="$CRTMP" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1; irc=$?
    [ "$irc" = 0 ] || { echo "  N=$N: the box is WEDGED -- reinstall after recovery gave rc=$irc"; cr_bad=$((cr_bad + 1)); }
    rm -rf "$RCR"
    N=$((N + 1))
done
chk "$(yn "$([ "$cr_bad" = 0 ] && [ "$cr_n" -ge 10 ]; echo $?)")" \
    "CR-1" "killed with SIGKILL before EVERY ONE of $cr_n writes: each box named its state, a removal verb cleared it ($cr_recover needed --recover), 0 files survived, and the next install exited 0"

# CR-2: the intent record is what makes that work. Without it there is no way
# to tell a crashed install from a foreign tree. Assert it exists at the moment
# it matters -- after the FIRST write and before the stamp.
RCI="$TMPBASE/cri"; rm -rf "$RCI"
P5_ROOT="$RCI" TMPDIR="$CRTMP" P5_FAULT_AFTER=4 sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1
a=0
[ -f "$RCI/usr/lib/p5/install.inprogress" ] || a=1
[ -f "$RCI/usr/lib/p5/stamp" ] && a=1
grep -q '^file|/usr/sbin/p5-datapath$' "$RCI/usr/lib/p5/install.inprogress" 2>/dev/null || a=1
grep -q '^dir|/usr/lib/p5$' "$RCI/usr/lib/p5/install.inprogress" 2>/dev/null || a=1
P5_ROOT="$RCI" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=incomplete' || a=1
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "CR-2" "a mid-install kill leaves an intent record carrying the WHOLE plan (files and owned dirs) and no stamp, and the box reports state=incomplete"

# CR-3: an interrupted REMOVAL resumes. The removal intent record is written
# before the first unlink and the metadata is unlinked last.
RCR2="$TMPBASE/crr"; inst "$RCR2" "$P9" client
unin "$RCR2" --remove --dry-run --role client   # populate nothing, just prove the plan builds
# simulate a removal that died after unlinking the payload but before finishing
rm -f "$RCR2/usr/sbin/p5-datapath"
printf '# P5 removal intent record\nP5_CONTRACT_VERSION=3\nP5_ROLE=client\nfile|/usr/sbin/p5-datapath\nfile|/usr/lib/p5/stamp\ndir|/usr/lib/p5\ndir|/etc/p5\ndir|/etc/p5/deadman\n' > "$RCR2/usr/lib/p5/remove.inprogress"
P5_ROOT="$RCR2" sh "$BIN/p5-version" --state 2>/dev/null | grep -q '^P5_BOX_STATE=incomplete' && a=0 || a=1
unin "$RCR2" --remove --role client; rc=$?
nf=$(find "$RCR2" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$a" = 0 ] && [ "$rc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "CR-3" "a box carrying a removal intent record reports state=incomplete and a re-run of --remove finishes the job (rc=$rc, files left=$nf)"

# CR-4: ATOMIC WRITES. A killed atomic write leaves a staged file beside the
# destination and NEVER a truncated destination. Demonstrated on the strongest
# case: overwrite an existing record with a write that dies. The staged path is
# DERIVED from the shipped helper, never spelled here -- when the staging rule
# changed for B3 this bar had the old name hard-coded and would have gone green
# while testing a file the product no longer writes.
RCA="$TMPBASE/cra"; inst "$RCA" "$P9" client
CR4_STAGE=$(sh -c '. "$1/p5-common.sh"; p5_incoming_of "$2"' _ "$LIB" "$RCA/usr/lib/p5/installed.files")
orig=$(sha256sum "$RCA/usr/lib/p5/installed.files" | cut -d' ' -f1)
P5_ROOT="$RCA" sh -c '. "$1/p5-common.sh"; printf "half a record" > "$2"; kill -9 $$' _ "$LIB" "$CR4_STAGE" 2>/dev/null
now=$(sha256sum "$RCA/usr/lib/p5/installed.files" | cut -d' ' -f1)
a=0
[ "$orig" = "$now" ] || a=1
[ -f "$CR4_STAGE" ] || a=1
# and the leftover is swept by the removal plan rather than left forever
unin "$RCA" --remove --role client; rc=$?
[ -e "$CR4_STAGE" ] && a=1
chk "$(yn "$([ "$a" = 0 ] && [ "$rc" = 0 ]; echo $?)")" \
    "CR-4" "a write that dies mid-stage leaves the live record byte-identical and $(basename "$CR4_STAGE") beside it, and the removal plan sweeps the leftover (rc=$rc)"

# ===========================================================================
# HOTPLUG bars -- B3: in /etc/hotplug.d/iface, PLACEMENT IS ACTIVATION
# ===========================================================================
# netifd has no enable step for iface hooks. OpenWrt's /sbin/hotplug-call is,
# in full:
#     for script in /etc/hotplug.d/$1/*; do ( [ -f $script ] && . $script ); done
# so a file is LIVE the instant its name lands in that directory, whatever is
# in it and whoever put it there. That makes the installer's staging name a
# safety-critical decision: round 1 staged at `DEST.p5-incoming`, which matches
# `*`, so the hook was published to netifd while `install` was still writing it
# and stayed published for as long as an interrupted run left it behind.
#
# hotplug_call below is that loop and it is the ONLY judge these bars use. No
# bar asserts "the name looks safe"; each one fires the real scanner and counts
# what ran. The subshell is the real one's too -- it is what lets a hook that
# fails to parse take its neighbours down with it or not.
hotplug_call() {   # hotplug_call DIR -- reproduction of /sbin/hotplug-call
    for script in "$1"/*; do (
        [ -f "$script" ] && . "$script"
    ); done
}
# The staging suffix round 1 used, read from the shipped library rather than
# retyped, so these bars cannot drift away from the code they judge.
P5_INCOMING=$(sh -c '. "$1/p5-common.sh"; echo "$P5_INCOMING"' _ "$LIB")
HPD="$TMPBASE/hp"; mkdir -p "$HPD/iface"
hp_reset() { rm -f "$HPD"/ran-*; }

# HP-1: the mechanism, and the defect it produced. A hook staged under round
# 1's name is executed by the real scanner -- and a HALF-WRITTEN one is
# executed as far as the truncation point, which is what `install` leaves on
# disk for the whole duration of the copy.
printf '#!/bin/sh\ntouch "%s/ran-live"\n' "$HPD" > "$HPD/iface/94-p5"
printf '#!/bin/sh\ntouch "%s/ran-suffix"\nif [ ' "$HPD" > "$HPD/iface/94-p5$P5_INCOMING"
hp_reset; ( hotplug_call "$HPD/iface" ) >/dev/null 2>&1
a=0; [ -f "$HPD/ran-live" ]   || a=1
b=0; [ -f "$HPD/ran-suffix" ] || b=1
chk "$(yn "$([ "$a" = 0 ] && [ "$b" = 0 ]; echo $?)")" \
    "HP-1" "the real hotplug-call loop sources a hook staged as DEST$P5_INCOMING -- truncated body and all -- so round 1's staging name published an unfinished hook to netifd"

# HP-2: the fix, judged by the same scanner. The name comes from the SHIPPED
# helper, not from this file: if the rule changes, this bar follows it.
rm -f "$HPD/iface/94-p5$P5_INCOMING"
hp_stage=$(sh -c '. "$1/p5-common.sh"; p5_incoming_of "$2"' _ "$LIB" "$HPD/iface/94-p5")
printf '#!/bin/sh\ntouch "%s/ran-staged"\nif [ ' "$HPD" > "$hp_stage"
hp_reset; ( hotplug_call "$HPD/iface" ) >/dev/null 2>&1
a=0; [ -f "$HPD/ran-live" ]     || a=1   # the scanner still works: not a vacuous silence
b=0; [ -f "$HPD/ran-staged" ]   && b=1
chk "$(yn "$([ "$a" = 0 ] && [ "$b" = 0 ]; echo $?)")" \
    "HP-2" "a stage named by the shipped p5_incoming_of ($(basename "$hp_stage")) is NOT sourced, while the live hook in the same directory still is"

# MU-HP2: revert only the naming rule and HP-2's predicate goes red. Without
# this the bar could be passing because nothing ran at all.
MUL="$TMPBASE/mulib"; rm -rf "$MUL"; mkdir -p "$MUL"
cp "$LIB/p5-common.sh" "$MUL/p5-common.sh"
cat >> "$MUL/p5-common.sh" <<'MUEOF'
# MUTATION, test only: round 1's staging rule restored. A later definition wins,
# so this replaces p5_incoming_of without editing the copy's body.
p5_incoming_of() { echo "$1$P5_INCOMING"; }
MUEOF
mu_stage=$(sh -c '. "$1/p5-common.sh"; p5_incoming_of "$2"' _ "$MUL" "$HPD/iface/94-p5")
mu_ok=0; [ "$mu_stage" = "$HPD/iface/94-p5$P5_INCOMING" ] || mu_ok=1
rm -f "$hp_stage"
printf '#!/bin/sh\ntouch "%s/ran-staged"\n' "$HPD" > "$mu_stage"
hp_reset; ( hotplug_call "$HPD/iface" ) >/dev/null 2>&1
[ -f "$HPD/ran-staged" ] || mu_ok=1
rm -f "$mu_stage"
chk "$(yn "$([ "$mu_ok" = 0 ]; echo $?)")" \
    "MU-HP2" "MUTATION: p5_incoming_of reverted to the suffix form -> the stage is sourced again, so HP-2 is able to fail"

# HP-3: the stage must sit in the DESTINATION'S OWN DIRECTORY. If it did not,
# the rename could cross a filesystem, stop being atomic, and degrade to a
# copy -- which would reintroduce the partial-file window at the destination
# itself. Checked over every destination the package ships plus every record
# and stamp path the installer writes.
hp3_bad=0; hp3_n=0
{ grep -v '^#' "$P9/payload/filemap" | cut -d'|' -f4
  echo /usr/lib/p5/installed.files; echo /usr/lib/p5/installed.dirs
  echo /usr/lib/p5/stamp; echo /usr/lib/p5/install.inprogress
  echo /usr/lib/p5/remove.inprogress; echo /etc/p5/deadman/rollback; } | while read -r d; do
    [ -n "$d" ] || continue
    st=$(sh -c '. "$1/p5-common.sh"; p5_incoming_of "$2"' _ "$LIB" "$d")
    [ "$(dirname "$st")" = "$(dirname "$d")" ] || echo "  $d -> $st leaves its own directory"
done > "$TMPBASE/hp3.out"
hp3_bad=$(grep -c . "$TMPBASE/hp3.out")
hp3_n=$(grep -vc '^#' "$P9/payload/filemap")
cat "$TMPBASE/hp3.out"
chk "$(yn "$([ "$hp3_bad" = 0 ] && [ "$hp3_n" -gt 0 ]; echo $?)")" \
    "HP-3" "every staging path stays in its destination's own directory ($((hp3_n + 6)) checked), so the publishing rename is intra-filesystem and stays atomic"

# HP-4: THE INTERRUPTION. Kill the installer between staging the hotplug hook
# and renaming it -- the one window P5_FAULT_AFTER's counter cannot express --
# and then run netifd's scanner over the directory that was left behind.
PHP="$TMPBASE/pkg-hp"; rm -rf "$PHP"; mkpkg "$PHP" client </dev/null
printf '#!/bin/sh\ntouch "%s/ran-hook"\n' "$HPD" > "$PHP/payload/hotplug.sh"
remanifest "$PHP"
hp4() {   # hp4 LIBDIR -> sets hp4_ran, hp4_left, hp4_rc, hp4_nf, hp4_irc
    _r="$TMPBASE/hp4root"; rm -rf "$_r"
    P5_ROOT="$_r" TMPDIR="$CRTMP" P5_LIB_SRC="$1" P5_FAULT_STAGE=/etc/hotplug.d/iface/94-p5 \
        sh "$BIN/p5-install" --package "$PHP" --role client >/dev/null 2>&1
    hp4_left=$(find "$_r/etc/hotplug.d/iface" -type f 2>/dev/null | wc -l)
    # a control hook, so "nothing ran" cannot be a scanner that was never fired
    printf '#!/bin/sh\ntouch "%s/ran-live"\n' "$HPD" > "$_r/etc/hotplug.d/iface/99-control"
    hp_reset; ( hotplug_call "$_r/etc/hotplug.d/iface" ) >/dev/null 2>&1
    hp4_ran=0; [ -f "$HPD/ran-hook" ] && hp4_ran=1
    hp4_ctl=0; [ -f "$HPD/ran-live" ] || hp4_ctl=1
    rm -f "$_r/etc/hotplug.d/iface/99-control"
    P5_ROOT="$_r" P5_LIB_SRC="$1" sh "$BIN/p5-uninstall" --remove --role client >/dev/null 2>&1; hp4_rc=$?
    [ "$hp4_rc" = 0 ] || { P5_ROOT="$_r" P5_LIB_SRC="$1" sh "$BIN/p5-uninstall" --remove --recover --role client >/dev/null 2>&1; hp4_rc=$?; }
    hp4_nf=$(find "$_r" -type f 2>/dev/null | wc -l)
    P5_ROOT="$_r" TMPDIR="$CRTMP" P5_LIB_SRC="$1" sh "$BIN/p5-install" --package "$PHP" --role client >/dev/null 2>&1; hp4_irc=$?
}
hp4 "$LIB"
chk "$(yn "$([ "$hp4_left" = 1 ] && [ "$hp4_ran" = 0 ] && [ "$hp4_ctl" = 0 ] && [ "$hp4_rc" = 0 ] && [ "$hp4_nf" = 0 ] && [ "$hp4_irc" = 0 ]; echo $?)")" \
    "HP-4" "SIGKILL between staging and renaming the netifd hook: the stage is on disk ($hp4_left file) but netifd's own scanner runs ZERO P5 code while still running the control hook, --remove sweeps it (rc=$hp4_rc, $hp4_nf files left) and the next install exits $hp4_irc"

# MU-HP4: the same interruption with the naming rule reverted. This is the
# defect as it stood, reproduced end to end rather than argued: the killed run
# leaves a hook that netifd EXECUTES, on a box where nothing else of P5 is
# installed yet.
hp4 "$MUL"
chk "$(yn "$([ "$hp4_ran" = 1 ]; echo $?)")" \
    "MU-HP4" "MUTATION: with the suffix naming restored, the SAME interrupted install leaves a hook that netifd executes on the next iface event -- HP-4 is the bar that refuses it"

# ===========================================================================
# RCV bars -- THE RECOVERY VERB MUST OUTLIVE WHAT IT RECOVERS FROM
# ===========================================================================
# Round 2's removal plan sorted /usr/sbin/p5-uninstall into the middle of the
# payload pass, so from action 6 of 18 onward the box had no uninstaller -- and
# p5-install then refused with exit 5 printing "Remedy: p5-uninstall --remove",
# naming the binary the run had just deleted. Recovery meant re-uploading the
# package over SSH to a box with no console.
#
# The claim being tested here is deliberately narrower and harder than "an
# interrupted removal resumes" (CR-3): at EVERY action index, the box must be
# recoverable BY A VERB THAT IS ON THE BOX, with no package present. So RCV-1
# invokes $ROOT/usr/sbin/p5-uninstall, never $BIN/p5-uninstall -- the package
# copy would pass this bar on a box that had nothing left.

# The reference plan, on a root that also carries the runtime state a live box
# has (facts under /etc/p5, a populated /var/run/p5), so the matrix walks the
# longest plan this product produces rather than the shortest.
RVP=$TMPBASE/rvp; inst "$RVP" "$P9" client
mkdir -p "$RVP/var/run/p5"; printf 'x\n' > "$RVP/var/run/p5/state"
printf 'fact\n' > "$RVP/etc/p5/wg-identity"
unin "$RVP" --remove --dry-run --role client
cp "$TMPBASE/uout" "$TMPBASE/rcv.plan"
rcv_actions=$(grep -c '^[A-Z]' "$TMPBASE/rcv.plan")

# RCV-2: the ORDER, read straight off the plan. SELFDROP is the last action,
# and the entry point appears in no earlier one.
ln_last=$(grep -n '^[A-Z]' "$TMPBASE/rcv.plan" | tail -1)
a=0
case "$ln_last" in *SELFDROP*) : ;; *) a=1; echo "  last action is not SELFDROP: $ln_last" ;; esac
grep -q '^UNLINK|/usr/sbin/p5-uninstall$' "$TMPBASE/rcv.plan" && { a=1; echo "  the entry point is unlinked by an ordinary action"; }
sd=$(grep '^SELFDROP|' "$TMPBASE/rcv.plan" | head -1)
for want in UNLINK:/usr/lib/p5/p5-common.sh UNLINK:/usr/lib/p5/contract-paths \
            UNLINK:/usr/lib/p5/contract-namespace UNLINK:/usr/lib/p5/contract-foreign \
            RMDIR:/usr/lib/p5; do
    case "$sd" in *"$want"*) : ;; *) a=1; echo "  SELFDROP is missing $want" ;; esac
done
case "$sd" in *"UNLINK:/usr/sbin/p5-uninstall") : ;; *) a=1; echo "  SELFDROP does not end with the entry point" ;; esac
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "RCV-2" "of $rcv_actions actions the LAST is SELFDROP, it carries the library, all three contract copies and the rmdir of /usr/lib/p5, it ends with /usr/sbin/p5-uninstall, and no earlier action touches the entry point"

# RCV-1: SIGKILL before EVERY action index, then recover using ONLY the verb
# that is on the box. This is the bar B2 did not have.
CRTMP="${CRTMP:-$TMPBASE/crtmp}"; mkdir -p "$CRTMP"
rcv_bad=0; rcv_n=0; rcv_recover=0
K=1
while [ "$K" -le "$rcv_actions" ]; do
    RR="$TMPBASE/rv$K"; rm -rf "$RR"
    P5_ROOT="$RR" TMPDIR="$CRTMP" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1
    if [ $? != 0 ]; then echo "  k=$K: fixture install failed"; rcv_bad=$((rcv_bad + 1)); K=$((K + 1)); continue; fi
    mkdir -p "$RR/var/run/p5"; printf 'x\n' > "$RR/var/run/p5/state"
    printf 'fact\n' > "$RR/etc/p5/wg-identity"
    P5_ROOT="$RR" TMPDIR="$CRTMP" P5_FAULT_AFTER="$K" \
        sh "$BIN/p5-uninstall" --remove --role client >/dev/null 2>&1
    rcv_n=$((rcv_n + 1))
    if [ ! -x "$RR/usr/sbin/p5-uninstall" ]; then
        echo "  k=$K: LOST -- /usr/sbin/p5-uninstall is gone and the box is not clean"
        rcv_bad=$((rcv_bad + 1)); rm -rf "$RR"; K=$((K + 1)); continue
    fi
    # ON-BOX ONLY. No package on this box; the sibling ../lib does not exist.
    P5_ROOT="$RR" sh "$RR/usr/sbin/p5-uninstall" --remove --role client >/dev/null 2>&1; rrc=$?
    if [ "$rrc" != 0 ]; then
        P5_ROOT="$RR" sh "$RR/usr/sbin/p5-uninstall" --remove --recover --role client >/dev/null 2>&1; rrc=$?
        rcv_recover=$((rcv_recover + 1))
    fi
    if [ "$rrc" != 0 ]; then
        echo "  k=$K: the ON-BOX verb could not clear the box (rc=$rrc)"
        rcv_bad=$((rcv_bad + 1)); rm -rf "$RR"; K=$((K + 1)); continue
    fi
    nf=$(find "$RR" -type f 2>/dev/null | wc -l)
    [ "$nf" = 0 ] || { echo "  k=$K: $nf file(s) survived"; rcv_bad=$((rcv_bad + 1)); }
    P5_ROOT="$RR" TMPDIR="$CRTMP" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1; irc=$?
    [ "$irc" = 0 ] || { echo "  k=$K: WEDGED -- reinstall after recovery gave rc=$irc"; rcv_bad=$((rcv_bad + 1)); }
    rm -rf "$RR"
    K=$((K + 1))
done
chk "$(yn "$([ "$rcv_bad" = 0 ] && [ "$rcv_n" = "$rcv_actions" ] && [ "$rcv_n" -ge 10 ]; echo $?)")" \
    "RCV-1" "SIGKILL before EVERY ONE of $rcv_n removal actions: at each index the ON-BOX /usr/sbin/p5-uninstall was present, cleared the box ($rcv_recover needed --recover), 0 files survived, and the next install exited 0"

# MU-RCV: the mutation. Drop ONE line from p5_self_toolchain -- the entry point
# -- and nothing else, which reproduces round 2's order exactly: the entry
# point falls back into the ordinary payload pass. RCV-2's order check must go
# red, and the box must actually be lost at that index. A bar that cannot fail
# is not evidence.
MUL=$TMPBASE/mutlib; mkdir -p "$MUL"
sed 's|^    echo /usr/sbin/p5-uninstall$|    :|' "$LIB/p5-common.sh" > "$MUL/p5-common.sh"
RVM=$TMPBASE/rvm; inst "$RVM" "$P9" client
mkdir -p "$RVM/var/run/p5"; printf 'x\n' > "$RVM/var/run/p5/state"
printf 'fact\n' > "$RVM/etc/p5/wg-identity"
P5_ROOT="$RVM" P5_LIB_SRC="$MUL" sh "$BIN/p5-uninstall" --remove --dry-run --role client >"$TMPBASE/mu.plan" 2>/dev/null
mu_idx=$(grep -n '^[A-Z]' "$TMPBASE/mu.plan" | grep 'UNLINK|/usr/sbin/p5-uninstall$' | head -1 | cut -d: -f1)
mu_pos=$(grep -n '^[A-Z]' "$TMPBASE/mu.plan" | cut -d: -f1 | grep -n "^${mu_idx}$" | cut -d: -f1)
a=0
[ -n "$mu_pos" ] || { a=1; echo "  MUTATION DID NOT BITE: the mutant plan still defers the entry point"; }
if [ -n "$mu_pos" ]; then
    mu_kill=$((mu_pos + 1))
    RVM2=$TMPBASE/rvm2; rm -rf "$RVM2"
    P5_ROOT="$RVM2" TMPDIR="$CRTMP" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1
    mkdir -p "$RVM2/var/run/p5"; printf 'x\n' > "$RVM2/var/run/p5/state"
    printf 'fact\n' > "$RVM2/etc/p5/wg-identity"
    P5_ROOT="$RVM2" TMPDIR="$CRTMP" P5_LIB_SRC="$MUL" P5_FAULT_AFTER="$mu_kill" \
        sh "$BIN/p5-uninstall" --remove --role client >/dev/null 2>&1
    [ -x "$RVM2/usr/sbin/p5-uninstall" ] && { a=1; echo "  MUTATION DID NOT BITE: the entry point survived the kill"; }
    nleft=$(find "$RVM2" -type f 2>/dev/null | wc -l)
    [ "$nleft" -gt 0 ] || { a=1; echo "  MUTATION DID NOT BITE: the box was already clean at that index"; }
fi
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-RCV" "MUTATION: removing the entry point from p5_self_toolchain puts it back at plan action $mu_pos of $rcv_actions, and a kill at action $((${mu_pos:-0} + 1)) leaves a box with $nleft file(s) and NO /usr/sbin/p5-uninstall -- exactly B2"

# RCV-3: the message. A SIGKILL landing INSIDE SELFDROP is the one window the
# ordering cannot close, so what p5-install PRINTS there has to be a verb that
# exists. Strip the toolchain the way a mid-SELFDROP kill would, then read the
# remedy out of the installer's own stderr and check the file it names is real.
RVR=$TMPBASE/rvr; inst "$RVR" "$P9" client
rm -f "$RVR/usr/lib/p5/p5-common.sh" "$RVR/usr/lib/p5/contract-paths" \
      "$RVR/usr/lib/p5/contract-namespace" "$RVR/usr/lib/p5/contract-foreign" \
      "$RVR/usr/lib/p5/stamp" "$RVR/usr/lib/p5/installed.files" "$RVR/usr/lib/p5/installed.dirs"
inst "$RVR" "$P9" client; rc=$?
named=$(sed -n "s|.*Remedy: sh '\([^']*\)'.*|\1|p" "$TMPBASE/err" | head -1)
a=0
[ -n "$named" ] || { a=1; echo "  the remedy did not name a package copy: $(grep -o 'Remedy:.*' "$TMPBASE/err" | head -1)"; }
[ -n "$named" ] && { [ -f "$named" ] || { a=1; echo "  the remedy names a file that does not exist: $named"; }; }
grep -q "Remedy: p5-uninstall" "$TMPBASE/err" && { a=1; echo "  it named the box's own copy, which is not runnable here"; }
chk "$(yn "$([ "$rc" = 5 ] && [ "$a" = 0 ]; echo $?)")" \
    "RCV-3" "with the toolchain stripped, p5-install refuses (rc=$rc) and names a verb that EXISTS -- the package copy beside it -- instead of /usr/sbin/p5-uninstall"

# RCV-4: and that verb has to work. Run exactly what RCV-3 read out of the
# message, from the package, and require a clean box and a successful install.
if [ -n "$named" ]; then
    P5_ROOT="$RVR" sh "$named" --remove --recover --role client >/dev/null 2>&1; rc=$?
else
    rc=99
fi
nf=$(find "$RVR" -type f 2>/dev/null | wc -l)
inst "$RVR" "$P9" client; irc=$?
chk "$(yn "$([ "$rc" = 0 ] && [ "$nf" = 0 ] && [ "$irc" = 0 ]; echo $?)")" \
    "RCV-4" "the verb the message named cleared the toolchain-only residue (rc=$rc, $nf files left) and the next install exited $irc"

# RCV-5: a REFUSED removal must leave a verb that RUNS, not one that merely
# EXISTS. The refusal path is RM-8's: a file P5 did not place is sitting in an
# owned directory, so the rmdir cannot proceed and the operator has work left.
# The first version of SELFDROP unlinked the library and the three contract
# copies, THEN hit the failing rmdir, THEN "kept" /usr/sbin/p5-uninstall -- an
# entry point that exits 5 on the first line it runs. That is B2 again by a
# second route: a present file the operator is told to use and cannot.
# SELFDROP now settles the directory's emptiness BEFORE it unlinks anything.
RVS=$TMPBASE/rvs; inst "$RVS" "$P9" client
printf 'someone else put this here\n' > "$RVS/usr/lib/p5/stranger"
unin "$RVS" --remove --role client; rc=$?
a=0
grep -q 'NOT EMPTY, left in place: /usr/lib/p5' "$TMPBASE/uerr" || { a=1; echo "  the refusal was not reported"; }
grep -q 'KEEPING THE WHOLE RECOVERY TOOLCHAIN' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not say the toolchain was kept whole"; }
for f in /usr/sbin/p5-uninstall /usr/lib/p5/p5-common.sh /usr/lib/p5/contract-paths \
         /usr/lib/p5/contract-namespace /usr/lib/p5/contract-foreign; do
    [ -e "$RVS$f" ] || { a=1; echo "  the refusal took $f with it"; }
done
# RUNNABLE, on the box, with no package: the sibling ../lib does not exist.
P5_ROOT="$RVS" sh "$RVS/usr/sbin/p5-uninstall" --check --scope p5 --role client \
    >"$TMPBASE/rvs.out" 2>"$TMPBASE/rvs.err"; crc=$?
grep -q 'cannot find p5-common.sh' "$TMPBASE/rvs.err" && { a=1; echo "  the kept verb cannot source its library"; }
grep -q 'NOT CLEAN' "$TMPBASE/rvs.out" || { a=1; echo "  the kept verb did not report the box (rc=$crc)"; }
# and once the stranger is gone it finishes the job itself.
rm -f "$RVS/usr/lib/p5/stranger"
P5_ROOT="$RVS" sh "$RVS/usr/sbin/p5-uninstall" --remove --role client >/dev/null 2>&1; rrc=$?
[ "$rrc" = 0 ] || { P5_ROOT="$RVS" sh "$RVS/usr/sbin/p5-uninstall" --remove --recover --role client >/dev/null 2>&1; rrc=$?; }
nf=$(find "$RVS" -type f 2>/dev/null | wc -l)
inst "$RVS" "$P9" client; irc=$?
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ] && [ "$irc" = 0 ]; echo $?)")" \
    "RCV-5" "a removal REFUSED by a non-empty owned directory (rc=$rc) leaves the whole toolchain, and the ON-BOX verb still RUNS: it reported the box, then cleared it to $nf files once the stranger was gone, and the next install exited $irc"

# MU-RCV5: the mutation. Disable the emptiness pre-check and nothing else, so
# SELFDROP goes back to unlink-then-discover-the-rmdir-failed. The entry point
# must survive (that part always worked) and its library must NOT -- and the
# survivor must fail to run. A bar that cannot fail is not evidence.
MUB=$TMPBASE/mutbin; mkdir -p "$MUB"
sed 's|if \[ "$sd_extra" != 0 \]; then|if [ 0 = 1 ]; then|' "$BIN/p5-uninstall" > "$MUB/p5-uninstall"
a=0
cmp -s "$MUB/p5-uninstall" "$BIN/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the pre-check guard was not found"; }
RVM3=$TMPBASE/rvm3; inst "$RVM3" "$P9" client
printf 'someone else put this here\n' > "$RVM3/usr/lib/p5/stranger"
P5_ROOT="$RVM3" P5_LIB_SRC="$LIB" sh "$MUB/p5-uninstall" --remove --role client >/dev/null 2>&1; mrc=$?
[ -e "$RVM3/usr/sbin/p5-uninstall" ] || { a=1; echo "  MUTATION DID NOT BITE: the entry point is gone entirely, not kept"; }
[ -e "$RVM3/usr/lib/p5/p5-common.sh" ] && { a=1; echo "  MUTATION DID NOT BITE: the library survived the mutant"; }
P5_ROOT="$RVM3" sh "$RVM3/usr/sbin/p5-uninstall" --check --scope p5 --role client \
    >/dev/null 2>"$TMPBASE/mu5.err"; mcrc=$?
grep -q 'cannot find p5-common.sh' "$TMPBASE/mu5.err" || { a=1; echo "  MUTATION DID NOT BITE: the kept verb still ran (rc=$mcrc)"; }
chk "$(yn "$([ "$a" = 0 ] && [ "$mcrc" = 5 ]; echo $?)")" \
    "MU-RCV5" "MUTATION: with the emptiness pre-check disabled, the same refusal (rc=$mrc) unlinks the library and then KEEPS an entry point that exits $mcrc on its first line -- present, unrunnable, which is what RCV-5 forbids"

# ===========================================================================
# DEADMAN bars
# ===========================================================================
RD=$TMPBASE/rd; inst "$RD" "$P9" client
dm() { P5_ROOT="$RD" sh "$BIN/p5-deadman" "$@" >"$TMPBASE/dm.out" 2>"$TMPBASE/dm.err"; }
MARK="$TMPBASE/rollback.ran"

# DM-1: arm writes a persistent record. Persistent is the requirement: a
# deadman that only exists in a running process does not survive the power loss
# it is there to protect against.
rm -f "$MARK"
dm arm --after 60 --restore "touch $MARK" --label t1 --no-timer; rc=$?
a=0
[ -f "$RD/etc/p5/deadman/t1" ] || a=1
grep -q '^P5_DM_DEADLINE=[0-9]' "$RD/etc/p5/deadman/t1" 2>/dev/null || a=1
grep -q '^P5_DM_AFTER=60$' "$RD/etc/p5/deadman/t1" 2>/dev/null || a=1
[ -f "$MARK" ] && a=1
chk "$(yn "$([ "$rc" = 0 ] && [ "$a" = 0 ]; echo $?)")" "DM-1" "arm writes a persistent record carrying an ABSOLUTE deadline and does not fire (rc=$rc)"

# DM-2: --after has NO DEFAULT. How long an operator needs to prove
# reachability is not derivable from anything this product can measure.
dm arm --restore "touch $MARK" --label t2 --no-timer; rc=$?
grep -q 'REQUIRED and has no default' "$TMPBASE/dm.err" && a=0 || a=1
dm arm --after 10 --label t2 --no-timer; rc2=$?
grep -q 'restore is REQUIRED' "$TMPBASE/dm.err" && b=0 || b=1
dm arm --after later --restore "true" --label t2 --no-timer; rc3=$?
chk "$(yn "$([ "$rc" = 2 ] && [ "$rc2" = 2 ] && [ "$rc3" = 2 ] && [ "$a$b" = 00 ]; echo $?)")" \
    "DM-2" "arm refuses without --after ($rc), without --restore ($rc2) and with a non-numeric --after ($rc3): no invented timeout"

# DM-3: check does not fire before the deadline.
dm check; rc=$?
chk "$(yn "$([ "$rc" = 0 ] && [ ! -f "$MARK" ]; echo $?)")" "DM-3" "check with the deadline in the future does not fire (rc=$rc)"

# DM-4: check FIRES at the deadline, and the rollback actually runs. --after 0
# puts the deadline at now, which is what makes this deterministic instead of
# a sleep race. This is the SAME code path the detached timer and a boot hook
# call, so testing it tests all three.
dm arm --after 0 --restore "touch $MARK" --label t1 --no-timer
dm check; rc=$?
a=0
[ -f "$MARK" ] || a=1
[ -f "$RD/etc/p5/deadman/t1" ] && a=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ]; echo $?)")" \
    "DM-4" "check fires a past-deadline record, the rollback RAN, the record is cleared, and the exit status is non-zero so a caller cannot read 'the box was rolled back' as success (rc=$rc)"

# DM-5: confirm disarms without firing, and is idempotent.
rm -f "$MARK"
dm arm --after 0 --restore "touch $MARK" --label t3 --no-timer
dm confirm --label t3; rc=$?
dm confirm --label t3; rc2=$?
dm check; rc3=$?
chk "$(yn "$([ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ] && [ ! -f "$MARK" ]; echo $?)")" \
    "DM-5" "confirm disarms without firing and is idempotent; a later check finds nothing armed (rc=$rc/$rc2/$rc3)"

# DM-6: a rollback that FAILS keeps the record armed. Dropping it would
# silently retire a rollback that never happened.
dm arm --after 0 --restore "exit 7" --label t4 --no-timer
dm check; rc=$?
a=0
[ -f "$RD/etc/p5/deadman/t4" ] || a=1
grep -q 'THE ROLLBACK FAILED' "$TMPBASE/dm.err" || a=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ]; echo $?)")" \
    "DM-6" "a rollback that exits non-zero leaves the record ARMED and says so, so the next check retries (rc=$rc)"
dm confirm --label t4

# DM-7: an unreadable deadline FIRES rather than being treated as 'never'.
mkdir -p "$RD/etc/p5/deadman"
printf 'P5_DM_LABEL=t5\nP5_DM_DEADLINE=corrupt\nP5_DM_RESTORE=touch %s\n' "$MARK" > "$RD/etc/p5/deadman/t5"
rm -f "$MARK"
dm check; rc=$?
chk "$(yn "$([ "$rc" = 1 ] && [ -f "$MARK" ]; echo $?)")" \
    "DM-7" "a record with a corrupt deadline is fired immediately, not skipped: 'unreadable' must never read as 'never' (rc=$rc)"

# DM-8: removal REFUSES while a deadman is armed. Tearing down the product
# while a rollback is owed removes the thing that would execute it.
rm -f "$MARK"
dm arm --after 60 --restore "touch $MARK" --label t6 --no-timer
before=$(find "$RD" | sort | sha256sum)
unin "$RD" --remove --role client; rc=$?
after=$(find "$RD" | sort | sha256sum)
grep -q 'deadman is ARMED' "$TMPBASE/uerr" && a=0 || a=1
chk "$(yn "$([ "$rc" = 5 ] && [ "$before" = "$after" ] && [ "$a" = 0 ]; echo $?)")" \
    "DM-8" "--remove refuses while a deadman is armed (exit 5) and the tree is byte-identical (rc=$rc)"
dm confirm --label t6
unin "$RD" --remove --role client; rc=$?
chk "$(yn "$([ "$rc" = 0 ]; echo $?)")" "DM-9" "once confirmed, the same --remove succeeds (rc=$rc): the refusal is a gate, not a wedge"

# DM-10: status names the gap in the boot limb rather than implying coverage.
dm status
grep -q 'boot limb is not wired yet' "$TMPBASE/dm.out" && a=0 || a=1
chk "$a" "DM-10" "status states the unwired boot limb out loud on every run, so the gap is visible on the box"

# ===========================================================================
# ROLE bars -- the server is not a special case of the client
# ===========================================================================
RS=$TMPBASE/rs; PS9=$TMPBASE/pkgsrv; mkpkg "$PS9" server </dev/null
inst "$RS" "$PS9" server; rc=$?
a=0
[ -f "$RS/usr/sbin/p5-server" ] || a=1
[ -f "$RS/usr/sbin/p5-datapath" ] && a=1
strays=$(audit "$RS" server)
[ -n "$strays" ] && { echo "$strays" | sed 's/^/  /'; a=1; }
unin "$RS" --remove --role server; rrc=$?
nf=$(find "$RS" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 0 ] && [ "$a" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "RO-1" "a server install places the server payload and no client payload, audits clean, and removes to 0 files (install=$rc remove=$rrc)"

# ===========================================================================
# NO-ROLE REMOVAL bars (RR-*) -- the invocation the PRODUCT PRINTS.
# ===========================================================================
# Every other removal bar in this file passes --role explicitly: 53 --remove
# call sites, 0 without the flag. That is exactly why an 86/0 battery could not
# see that `p5-uninstall --remove` -- the form in p5-install's three Remedy
# strings, in its closing line, in p5-version's two remedies and in
# CONTRACT.md's own signature -- exited 4 and removed nothing on every box of
# either role, blaming the install record for a defect in the row filter
# (RROLE="${ROLE:-both}" against p5_declared/p5_rows, where `both` is a literal
# row VALUE and not a wildcard). A bar exercises the DOCUMENTED invocation now.

# Dedicated packages: these bars must not depend on which $P a distant bar left
# behind. PRRC is a plain client package, PRRS a plain server one, PRR2 carries
# BOTH roles in one filemap -- which is what contract/paths already declares
# (client and server payload rows in one inventory) and therefore what E8 will
# ship.
PRRC=$TMPBASE/pkgrrc; mkpkg "$PRRC" client </dev/null
PRRS=$TMPBASE/pkgrrs; mkpkg "$PRRS" server </dev/null
PRR2=$TMPBASE/pkgrr2; mkpkg "$PRR2" client <<'EOF'
755|server|p5-datapath.bin|/usr/sbin/p5-server
755|server|initd.sh|/etc/init.d/p5-server
EOF

# RR-1: the bare documented verb removes a client box.
RR1=$TMPBASE/rr1; mkdir -p "$RR1"
inst "$RR1" "$PRRC" client >/dev/null 2>&1; rc=$?
unin "$RR1" --remove; rrc=$?
nf=$(find "$RR1" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "RR-1" "\`p5-uninstall --remove\` with NO --role -- the form every remedy string and CONTRACT.md print -- removes a client install to 0 files (install=$rc remove=$rrc left=$nf)"

# RR-2: same on a server box, and it says where it got the role.
RR2=$TMPBASE/rr2; mkdir -p "$RR2"
inst "$RR2" "$PRRS" server >/dev/null 2>&1; rc=$?
unin "$RR2" --remove --dry-run; drc=$?
said=1; grep -q "using role=server from the install stamp" "$TMPBASE/uout" && said=0
nplan=$(grep -c '^# end of plan:' "$TMPBASE/uout")
unin "$RR2" --remove; rrc=$?
nf=$(find "$RR2" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 0 ] && [ "$drc" = 0 ] && [ "$said" = 0 ] && [ "$nplan" = 1 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "RR-2" "no --role on a SERVER box: --dry-run prints a plan (rc=$drc) and NAMES the stamp as the source of role=server, and --remove clears it (rc=$rrc left=$nf)"

# RR-3: a box with no stamp cannot supply a role, so the run REFUSES BY NAME
# rather than filtering everything out and reporting a fault in the record.
RR3=$TMPBASE/rr3; mkdir -p "$RR3/usr/lib/p5"; : > "$RR3/usr/lib/p5/contract-paths"
unin "$RR3" --remove; rc=$?
named=1; grep -q -- "--role client|server" "$TMPBASE/uerr" && named=0
skew=0; grep -q "version-skew guard" "$TMPBASE/uerr" && skew=1
chk "$(yn "$([ "$rc" = 2 ] && [ "$named" = 0 ] && [ "$skew" = 0 ]; echo $?)")" \
    "RR-3" "a stamp-less box refuses the no-role removal with exit 2 naming --role (rc=$rc), and does NOT misreport it as the version-skew guard"

# RR-4: a WRONG-ROLE install is still removable by the bare documented verb.
# There is no box-identity check anywhere in p5-install (its only uname writes
# P5_INSTALL_ARCH into the stamp), so a two-role package plus a mistyped --role
# installs the other role's payload and exits 0. The stamp records what was
# actually done, so the bare verb undoes exactly that.
RR4=$TMPBASE/rr4; mkdir -p "$RR4"
inst "$RR4" "$PRR2" client >/dev/null 2>&1; rc=$?
hook=1; [ -f "$RR4/etc/hotplug.d/iface/94-p5" ] && hook=0
unin "$RR4" --remove; rrc=$?
nf=$(find "$RR4" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 0 ] && [ "$hook" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "RR-4" "a two-role package installed with the WRONG --role exits 0 and places the netifd hook (install=$rc hook=$hook) -- and the bare --remove undoes exactly what the stamp records (rc=$rrc left=$nf)"

# RR-5: the DAMAGED-state remedy, executed verbatim as printed. This is the one
# state where the bare verb legitimately cannot work -- `damaged` means there is
# no stamp, so there is no P5_ROLE to read -- which is why p5-install spells
# --role out on that branch and only that branch. RCV-4 runs a hand-written
# `--remove --recover --role client` rather than the string the product printed,
# so it cannot see a remedy that omits the flag. This bar runs the string.
RR5=$TMPBASE/rr5; mkdir -p "$RR5"
inst "$RR5" "$PRRC" client >/dev/null 2>&1
rm -f "$RR5/usr/lib/p5/stamp" "$RR5/usr/lib/p5/installed.files" \
      "$RR5/usr/lib/p5/installed.dirs"
inst "$RR5" "$PRRC" client; rc=$?
rr5_cmd=$(sed -n 's/.*, then \(.*\) derives the set from the contract.*/\1/p' "$TMPBASE/err" | head -1)
a=0
[ -n "$rr5_cmd" ] || { a=1; echo "  could not read a recovery command out of the damaged-state remedy"; }
case "$rr5_cmd" in *--role*) : ;; *) a=1; echo "  the damaged-state remedy omits --role, and a damaged box has no stamp to supply one: $rr5_cmd" ;; esac
if [ "$a" = 0 ]; then
    # p5_recovery_verb resolves to the BARE name when the box's own copy is
    # runnable, which is correct on a box (/usr/sbin is on PATH) and needs the
    # test root's sbin put on PATH here. The FLAGS are what this bar is about;
    # RCV-3/RCV-4 already own the "does the named file exist" half.
    ( P5_ROOT="$RR5"; PATH="$RR5/usr/sbin:$PATH"; export P5_ROOT PATH; eval "$rr5_cmd" ) \
        >/dev/null 2>&1; rr5_rc=$?
else
    rr5_rc=99
fi
nf=$(find "$RR5" -type f 2>/dev/null | wc -l)
irc=99; [ "$rr5_rc" = 0 ] && { inst "$RR5" "$PRRC" client >/dev/null 2>&1; irc=$?; }
chk "$(yn "$([ "$rc" = 5 ] && [ "$a" = 0 ] && [ "$rr5_rc" = 0 ] && [ "$nf" = 0 ] && [ "$irc" = 0 ]; echo $?)")" \
    "RR-5" "the damaged-state remedy p5-install PRINTS, run verbatim, clears the box (rc=$rr5_rc, $nf files left) and the next install succeeds (rc=$irc) -- the string carries --role because a damaged box has no stamp to read one from"

# MU-RR: restore the defect and prove RR-1 can fail. Without this the RR bars
# are four green lines that never demonstrated they can go red.
MURR=$TMPBASE/murr; mkdir -p "$MURR/bin"
sed 's|RROLE_SRC=stamp ;;|RROLE="both"; RROLE_SRC=stamp ;;|' "$BIN/p5-uninstall" > "$MURR/bin/p5-uninstall"
mutated=1; cmp -s "$MURR/bin/p5-uninstall" "$BIN/p5-uninstall" || mutated=0
RRM=$TMPBASE/rrm; mkdir -p "$RRM"
inst "$RRM" "$PRRC" client >/dev/null 2>&1
P5_ROOT="$RRM" P5_LIB_SRC="$LIB" sh "$MURR/bin/p5-uninstall" --remove >/dev/null 2>&1; mrc=$?
mnf=$(find "$RRM" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$mutated" = 0 ] && [ "$mrc" != 0 ] && [ "$mnf" != 0 ]; echo $?)")" \
    "MU-RR" "MUTATION: put the stamp-derived role back to the literal \`both\` and the same bare --remove fails (rc=$mrc) leaving $mnf file(s) -- RR-1 is able to go red (mutation applied=$mutated)"

# ===========================================================================
# PATH-SANITY bars (PS-*) -- can a CONTRACT row reach an rm?
# ===========================================================================
# Kept in their own file because every one of them needs an installed root AND
# a mutated on-box contract; folded in here so a green run of this battery
# means the server-loss path is closed too, not merely that nobody ran the
# other file.
#
# THE FOLD READS A LEDGER, NOT THE PRINTED OUTPUT. It used to count
# `grep -c '^PASS '` over the child's stdout and then print that same stdout
# INDENTED by two spaces -- so a PS bar that failed was counted into `fail` and
# was simultaneously invisible to any reader grepping `^FAIL` in the battery's
# own output. A summary that disagrees with what a reader can count is the exact
# defect this unit exists to remove, so the counts now come from the child's
# ledger file (which run.sh creates and owns, and which nothing else writes) and
# its output is printed VERBATIM, bar lines at column 0.
PSLED="$TMPBASE/ps.ledger"
if P5T_LEDGER_OUT="$PSLED" sh "$here/pathsanity.sh" "$P5DIR" > "$TMPBASE/ps.out" 2>&1
then ps_rc=0; else ps_rc=1; fi
cat "$TMPBASE/ps.out"
ps_pass=$(grep -c '^PASS ' "$PSLED" 2>/dev/null); [ -n "$ps_pass" ] || ps_pass=0
ps_fail=$(grep -c '^FAIL ' "$PSLED" 2>/dev/null); [ -n "$ps_fail" ] || ps_fail=0
# Appended, so the ONE ledger this battery reconciles against carries every bar
# either harness emitted. Sequential: pathsanity has exited by this line.
cat "$PSLED" >> "$P5T_LEDGER" 2>/dev/null
pass=$((pass + ps_pass)); fail=$((fail + ps_fail))
if [ "$ps_rc" = 0 ] && [ "$ps_fail" = 0 ] && [ "$ps_pass" -gt 0 ]; then
    ok  "PS-ALL" "pathsanity.sh ran and every path-sanity bar passed ($ps_pass bars)"
else
    bad "PS-ALL" "pathsanity.sh: $ps_pass passed, $ps_fail failed, exit $ps_rc"
fi

# ===========================================================================
# SELF-REPORT bars (SC-*) -- can this battery's summary lie about its own bars?
# ===========================================================================
# One run of this battery printed 93 unique bar ids, no line beginning FAIL, and
# the summary `91 passed, 2 failed`. ok/bad cannot produce that: each of them
# prints a line and moves a counter in the same call. The output file also
# carried a spliced partial line. That artifact is gone and was never
# reproduced, so its cause is NOT established here and is not guessed at; what
# these bars close is the class -- see ledger.sh's header.

# SC-2: the scratch directory is EXCLUSIVELY OWNED. `mkdir -p` adopts whatever
# is already at the name; `$$` is not exclusive on a machine where killed runs
# leave scratch directories behind and pids are reused. This asserts the
# allocator refuses to adopt, and hands back a different name instead of
# wedging.
SCW1=$(p5t_workdir p5-e0-scw) || SCW1=""
SCW2=$(p5t_workdir p5-e0-scw) || SCW2=""
a=0
if [ -z "$SCW1" ] || [ -z "$SCW2" ]; then
    a=1; echo "  the allocator could not produce two directories"
fi
[ "$SCW1" = "$SCW2" ] && { a=1; echo "  it handed the same directory out twice: $SCW1"; }
# And it must step over one that is already there rather than adopting it.
SCW3=$(p5t_workdir p5-e0-scw) || SCW3=""
if [ "$SCW3" = "$SCW1" ] || [ "$SCW3" = "$SCW2" ]; then
    a=1; echo "  it adopted an existing directory: $SCW3"
fi
printf 'planted\n' > "$SCW1/planted" 2>/dev/null
[ -f "$SCW2/planted" ] && { a=1; echo "  the two directories are the same storage"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "SC-2" "the harness scratch directory is created exclusively: three requests gave three distinct directories, none adopted, so a leftover from a killed run with a reused pid cannot be shared or wedge the run"
rm -rf "$SCW1" "$SCW2" "$SCW3"

# SC-3 / L-5: the SHIPPED tools must allocate scratch the same way, and this is
# where it MATTERS. $P5_WORK/ordered IS the removal plan -- the file on disk
# between the gate that approved a path and the rm that acts on it, which is the
# window PS-7 exists to survive. `mkdir -p` ADOPTS, and $$ is not exclusive on a
# box where p5_fault_point kills with -9 and skips the cleanup trap BY DESIGN, so
# leftovers are the EXPECTED state, not bad luck. The server has no console. (U82)
#
# L-6 is the regression guard: the adopting form must not come BACK. Same `linted`
# counter every other lint here uses, because a lint that opened no files passes
# vacuously -- that is what this file was rewritten once already to prevent.
# The pattern targets the NON-EXCLUSIVE NAME, not the mkdir. First cut matched
# `mkdir -p "${TMPDIR...}"` on one line and found NOTHING, because the real defect
# is TWO lines -- the path is built from TMPDIR, then mkdir -p''d on the next. The
# seeded A/B is the only reason that was caught: the lint read right and matched
# the shape the code never had. So: flag any shipped file that builds a
# "${TMPDIR...}/....$$" path AT ALL, since exclusive allocation goes through
# p5_workdir. It self-exempts p5_workdir, whose candidate is ".$$.<i>" and so does
# not end at .$$ -- by construction, not by a name exception.
ADOPT='^[^#]*\$\{TMPDIR[^}]*\}[^"]*\.\$\$"'
adopt_bad=0; linted=0
for f in "$@"; do
    [ -f "$f" ] || { echo "  not a file: $f"; adopt_bad=$((adopt_bad + 1)); continue; }
    linted=$((linted + 1))
    if grep -nE "$ADOPT" "$f" >/dev/null 2>&1; then
        echo "  adopting scratch allocation in $f:"; grep -nE "$ADOPT" "$f" | sed 's/^/    /'
        adopt_bad=$((adopt_bad + 1))
    fi
done
chk "$(yn "$([ "$adopt_bad" = 0 ] && [ "$linted" = "$N_SHIPPED" ]; echo $?)")" \
    "L-6" "no shipped tool builds a non-exclusive pid-named scratch path under TMPDIR ($linted/$N_SHIPPED files actually opened); the adopting form cannot come back unnoticed"

# SC-3: and the shipped allocator BEHAVES, not merely reads right.
# The harness does NOT source p5-common.sh -- it exercises the shipped tools as
# PROCESSES, not as a library. The first cut of this bar called p5_workdir directly
# and died with "command not found", i.e. it went RED for a reason that had nothing to
# do with the allocator. A bar that fails for the wrong reason is worth no more than
# one that cannot fail.
#
# All THREE allocations happen in ONE subshell, so they share a pid. That is the whole
# point: candidates are "$prefix.$$.<i>", so three requests from three DIFFERENT
# processes would get distinct names for free and prove nothing about stepping.
SWOUT=$(sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_workdir p5-e0-sw; p5_workdir p5-e0-sw; p5_workdir p5-e0-sw' _ "$LIB/p5-common.sh" 2>/dev/null)
SW1=$(echo "$SWOUT" | sed -n 1p)
SW2=$(echo "$SWOUT" | sed -n 2p)
SW3=$(echo "$SWOUT" | sed -n 3p)
b=0
if [ -z "$SW1" ] || [ -z "$SW2" ] || [ -z "$SW3" ]; then
    b=1; echo "  the shipped allocator could not produce three directories"
fi
[ "$SW1" = "$SW2" ] && { b=1; echo "  it handed the same directory out twice: $SW1"; }
[ "$SW3" = "$SW1" ] && { b=1; echo "  it re-handed an existing directory: $SW3"; }
[ "$SW3" = "$SW2" ] && { b=1; echo "  it re-handed an existing directory: $SW3"; }
printf 'planted\n' > "$SW1/planted" 2>/dev/null
[ -f "$SW2/planted" ] && { b=1; echo "  the two directories are the same storage"; }
chk "$(yn "$([ "$b" = 0 ]; echo $?)")" \
    "SC-3" "the SHIPPED scratch allocator (p5_workdir in p5-common.sh) creates exclusively: three requests gave three distinct directories, none adopted, so a leftover from a -9 killed run with a reused pid cannot be inherited while \$P5_WORK/ordered is the removal plan"
rm -rf "$SW1" "$SW2" "$SW3"

# ===========================================================================
# THE OLD STACK -- U26 / E7
# ===========================================================================
#
# THE FIXTURE IS BUILT FROM THE SHIPPED LIST, NOT FROM A COPY OF IT. Every root
# below is planted by asking p5_old_rows what the old stack is, so a row added
# to the product extends this fixture with no edit here, and a fixture that
# plants something the product does not know about cannot exist. That matters
# more than usual for this half: the whole claim is that the list was DERIVED
# from the old package's own teardown, and a hand-written fixture would let the
# bars agree with a list that had drifted away from it.
#
# WHAT THESE BARS DO NOT PROVE, said here rather than left to be assumed:
#   - no old stack has ever been removed from a router. These roots are $P5_ROOT
#     trees; procd, uci and netifd are absent, so `stop`/`disable` are shell
#     stubs and the uci row can only be reported UNPROBED.
#   - the DERIVATION is checked for form and for its bound (OLD-0), never for
#     truth: that /etc/init.d/bond-ecod really is what p2-engarde/bondctl:334-335
#     stops is a claim about a file in this repo that a bar cannot settle.

AGGW_CANARY='AGGW-CANARY-DO-NOT-DELETE'
OLDROWS="$TMPBASE/oldrows"

# The shipped list, asked of the library as a PROCESS -- the harness never
# sources p5-common.sh, for the reason SC-3's comment gives.
sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_contract_dir "$2" ""
    p5_old_rows' _ "$LIB/p5-common.sh" "$CON" > "$OLDROWS" 2>/dev/null

mkoldroot() {   # mkoldroot NAME -> sets OR to a root carrying the P1-P4 set
    OR="$TMPBASE/$1"
    rm -rf "$OR"
    mkdir -p "$OR/etc/init.d" "$OR/etc/rc.d" "$OR/etc/hotplug.d/iface" \
             "$OR/usr/sbin" "$OR/root" "$OR/etc/config" "$OR/tmp"
    while IFS='|' read -r _o _k _p _d; do
        case "$_o" in ''|\#*) continue ;; esac
        case "$_k" in
            uci) continue ;;
            dir) mkdir -p "$OR$_p"; printf 'old-stack state\n' > "$OR$_p/planted" ;;
            svc) mkdir -p "$OR${_p%/*}"; printf '#!/bin/sh\nexit 0\n' > "$OR$_p"
                 printf 'flag\n' > "$OR/etc/rc.d/S50${_p##*/}"
                 printf 'flag\n' > "$OR/etc/rc.d/K50${_p##*/}" ;;
            quarantine) mkdir -p "$OR${_p%/*}"; printf '%s\n' "$AGGW_CANARY" > "$OR$_p" ;;
            *) mkdir -p "$OR${_p%/*}"; printf 'old-stack artifact\n' > "$OR$_p" ;;
        esac
    done < "$OLDROWS"
    # p5_old_keeps: two paths contract/foreign carries under origin p1 that NO
    # teardown deletes -- the opkg package sqm-scripts and GL's own queue
    # config. They are planted so that a removal derived from the refusal list
    # instead of from the teardown takes GL's native queues with it and a bar
    # sees it happen.
    printf '#!/bin/sh\nexit 0\n' > "$OR/etc/init.d/sqm"
    printf 'config queue\n'      > "$OR/etc/config/sqm"
    # A `revert` row names a TOOL TO INVOKE, not a file to delete, so each one
    # is planted as an EXECUTABLE stub that records how it was called. Planted
    # after the loop above on purpose: /usr/sbin/bondctl is also a `file` row,
    # and the loop would otherwise overwrite the stub with inert text.
    while IFS='|' read -r _o _k _p _d; do
        case "$_o" in ''|\#*) continue ;; esac
        [ "$_k" = revert ] || continue
        mkdir -p "$OR${_p%/*}"
        printf '#!/bin/sh\necho "$*" >> "%s/revert-calls"\nexit 0\n' "$OR" > "$OR$_p"
        chmod +x "$OR$_p"
    done < "$OLDROWS"
}

mkmgmt() {   # mkmgmt ROOT ROLE CARRIER -- the management-path report
    mkdir -p "$1/tmp"
    {
        echo "P5_MGMT_GENERATED_UTC=19700101T000000Z"
        echo "P5_MGMT_ROLE=$2"
        echo "P5_MGMT_SSH_PEER=203.0.113.9"
        echo "P5_MGMT_IFACE=br-lan"
        echo "P5_MGMT_WG_PEER=none"
        echo "P5_MGMT_WG_ENDPOINT=none"
        echo "P5_MGMT_CARRIER_SVC=$3"
    } > "$1/tmp/p5-mgmt-path.report"
}

oldleft() {   # oldleft ROOT -> one line per declared old-stack artifact still present
    while IFS='|' read -r _o _k _p _d; do
        case "$_o" in ''|\#*) continue ;; esac
        # `revert` is skipped here because it is not an artifact: its path is
        # carried a second time as a `file` row, and counting it twice would
        # inflate every before/after number in this section. What the revert
        # DOES is asserted by OLD-R, not by a presence count.
        case "$_k" in uci|quarantine|revert) continue ;; esac
        if [ -e "$1$_p" ] || [ -L "$1$_p" ]; then echo "$_p"; fi
    done < "$OLDROWS"
    for _f in "$1"/etc/rc.d/*; do
        [ -e "$_f" ] || continue
        case "${_f##*/}" in [SK][0-9][0-9]sqm) continue ;; esac
        echo "rc.d flag ${_f##*/}"
    done
    return 0
}

# OLD-0: THE DERIVATION IS WELL FORMED AND IT IS BOUNDED. Every row carries an
# origin, a kind, an absolute path (or a config.object for a uci row) and the
# file:line that put it there -- a row with no citation is the thing this list
# exists to prevent. And every filesystem row is classified FOREIGN by
# contract/foreign under a p1/p2/p3/p4 origin, which is the bound that stops an
# old-stack action ever reaching a `gl` row: the `gl` rows are dropbear, the
# network stack, the firewall and the boot flags -- the management path itself.
sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_contract_dir "$2" ""
    while IFS="|" read -r o k p d; do
        case "$o" in ""|\#*) continue ;; esac
        case "$k" in uci) continue ;; esac
        if p5_old_origin "$p" >/dev/null 2>&1; then echo "BOUND|$p"; else echo "UNBOUNDED|$p"; fi
    done' _ "$LIB/p5-common.sh" "$CON" < "$OLDROWS" > "$TMPBASE/oldbound" 2>/dev/null
od_bad=0; od_rows=0
while IFS='|' read -r _o _k _p _d; do
    case "$_o" in ''|\#*) continue ;; esac
    od_rows=$((od_rows + 1))
    case "$_o" in p1|p2|p3|p4) : ;; *) echo "  bad origin: $_o"; od_bad=$((od_bad + 1)) ;; esac
    case "$_k" in revert|svc|file|dir|quarantine|uci) : ;; *) echo "  bad kind: $_k"; od_bad=$((od_bad + 1)) ;; esac
    [ -n "$_d" ] || { echo "  row carries no derivation: $_p"; od_bad=$((od_bad + 1)); }
    if [ "$_k" = uci ]; then
        case "$_p" in *.*) : ;; *) echo "  uci row is not config.object: $_p"; od_bad=$((od_bad + 1)) ;; esac
    else
        case "$_p" in /*) : ;; *) echo "  path not absolute: $_p"; od_bad=$((od_bad + 1)) ;; esac
    fi
done < "$OLDROWS"
ub=$(grep -c '^UNBOUNDED|' "$TMPBASE/oldbound" 2>/dev/null); [ -n "$ub" ] || ub=0
bn=$(grep -c '^BOUND|'     "$TMPBASE/oldbound" 2>/dev/null); [ -n "$bn" ] || bn=0
[ "$ub" = 0 ] || { echo "  not classified foreign under p1..p4:"; grep '^UNBOUNDED|' "$TMPBASE/oldbound" | sed 's/^/    /'; }
chk "$(yn "$([ "$od_bad" = 0 ] && [ "$od_rows" -gt 0 ] && [ "$ub" = 0 ] && [ "$bn" -gt 0 ]; echo $?)")" \
    "OLD-0" "the derived old-stack list parses ($od_rows rows), every row carries the teardown file:line that put it there, and all $bn filesystem rows are bounded by contract/foreign under a p1/p2/p3/p4 origin -- so no old-stack action can reach a \`gl\` management path"

# OLD-Q: WHERE THE QUARANTINE LANDS IS A PATH NO REMOVAL LIST HERE CAN NAME.
# It is the one destination in this product that must survive both halves of a
# purge: /etc/bond is a declared `dir` row that the old half rm -rf's, and
# /etc/p5/* is a declared runtime glob that the P5 half unlinks. So the
# destination is asserted against the shipped lists rather than argued for in a
# comment -- undeclared in every kind, outside the namespace in BOTH roles, not
# removable, and its holding directory likewise.
sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_contract_dir "$2" ""
    q=$(p5_old_quarantine_of /etc/bond/agg_w); echo "DEST|$q"
    for k in quarantine file dir svc; do p5_old_declared "$q" "$k" && echo "DECLARED|$k"; done
    for r in client server; do p5_ns_ok "$r" "$q" && echo "NAMESPACE|$r"; done
    for k in file dir; do p5_old_removable "$q" "$k" && echo "REMOVABLE|$k"; done
    qd=${q%/*}
    p5_old_declared "$qd" dir && echo "DECLAREDDIR|$qd"
    for r in client server; do p5_ns_ok "$r" "$qd" && echo "NSDIR|$r"; done
    exit 0' _ "$LIB/p5-common.sh" "$CON" > "$TMPBASE/oldq" 2>/dev/null
qdest=$(sed -n 's/^DEST|//p' "$TMPBASE/oldq")
qbad=$(grep -cE '^(DECLARED|NAMESPACE|REMOVABLE|DECLAREDDIR|NSDIR)\|' "$TMPBASE/oldq" 2>/dev/null)
[ -n "$qbad" ] || qbad=0
[ "$qbad" = 0 ] || { echo "  the quarantine destination is reachable by a removal list:"; grep -E '^(DECLARED|NAMESPACE|REMOVABLE|DECLAREDDIR|NSDIR)\|' "$TMPBASE/oldq" | sed 's/^/    /'; }
case "$qdest" in /etc/bond.p5-quarantine/agg_w.*) qform=0 ;; *) qform=1; echo "  unexpected quarantine destination: $qdest" ;; esac
chk "$(yn "$([ "$qbad" = 0 ] && [ "$qform" = 0 ]; echo $?)")" \
    "OLD-Q" "the quarantine destination ($qdest) is declared by no old-stack row in any kind, is outside the P5 namespace in both roles, is not removable by either half, and neither is the directory holding it"

# OLD-1: THE SCAN NAMES EVERY ARTIFACT. Not "reports dirty" -- names them, one
# by one, because the operator's next move is to look at each. Checked against
# the shipped list rather than a count, so a scan that found 30 of 31 is red.
mkoldroot oldr1
unin "$OR" --check --scope old; rc=$?
os_miss=0; os_n=0
while IFS='|' read -r _o _k _p _d; do
    case "$_o" in ''|\#*) continue ;; esac
    case "$_k" in uci|revert) continue ;; esac
    os_n=$((os_n + 1))
    grep -qF -- "$_p" "$TMPBASE/uout" || { echo "  the scan did not name $_p"; os_miss=$((os_miss + 1)); }
done < "$OLDROWS"
grep -q 'BEFORE the switch' "$TMPBASE/uout" && a=0 || a=1
grep -q 'UNPROBED' "$TMPBASE/uout" && b=0 || b=1
chk "$(yn "$([ "$rc" = 1 ] && [ "$os_miss" = 0 ] && [ "$os_n" -gt 0 ] && [ "$a$b" = 00 ]; echo $?)")" \
    "OLD-1" "--check --scope old on a root carrying the P1-P4 set -> exit 1 naming all $os_n declared artifacts individually, reporting the uci object as UNPROBED rather than guessing, and saying the gate is on the SWITCH not the install (rc=$rc)"

# OLD-2 / OLD-3 / OLD-8: ONE purge, three separate claims about it.
mkoldroot oldr2
mkmgmt "$OR" client none
before=$(oldleft "$OR" | wc -l | tr -d " ")
unin "$OR" --purge --role client; prc=$?
oldleft "$OR" > "$TMPBASE/oldsurv"
after=$(grep -c . "$TMPBASE/oldsurv" 2>/dev/null); [ -n "$after" ] || after=0
[ "$after" = 0 ] || { echo "  survived the purge:"; sed 's/^/    /' "$TMPBASE/oldsurv"; }
chk "$(yn "$([ "$prc" = 0 ] && [ "$after" = 0 ] && [ "$before" -gt 0 ]; echo $?)")" \
    "OLD-2" "--purge leaves NONE of the $before declared old-stack artifacts and their rc.d flags (rc=$prc, $after left)"

# OLD-3: THE U26 CONDITION. /etc/bond/agg_w is MOVED ASIDE under a timestamped
# name and REPORTED -- never deleted, and never left where a later `rm -rf
# /etc/bond` in the same run can take it. Byte-identical is the assertion: a
# quarantine that truncates is a deletion with a receipt.
qf=$(find "$OR/etc/bond.p5-quarantine" -type f 2>/dev/null | head -1)
a=1; [ -n "$qf" ] && a=0
b=1; [ -n "$qf" ] && grep -qxF "$AGGW_CANARY" "$qf" && b=0
c=0; [ -e "$OR/etc/bond/agg_w" ] && { c=1; echo "  the original is still in place"; }
d=0; [ -d "$OR/etc/bond" ] && { d=1; echo "  /etc/bond survived the purge"; }
grep -q 'QUARANTINED, NOT DELETED' "$TMPBASE/uerr" "$TMPBASE/uout" 2>/dev/null && e=0 || e=1
case "${qf##*/}" in agg_w.*) f=0 ;; *) f=1; echo "  quarantine name carries no timestamp: ${qf##*/}" ;; esac
chk "$(yn "$([ "$a$b$c$d$e$f" = 000000 ]; echo $?)")" \
    "OLD-3" "a pre-existing /etc/bond/agg_w is QUARANTINED, not deleted: moved to ${qf##*/} outside the tree the purge rm -rf's, byte-identical to what was there, and reported by name"

# OLD-8: and the two paths the DERIVATION says to keep are still there. This is
# the half a refusal list cannot express: both are on contract/foreign under
# origin p1, and a removal taken from THAT list would have deleted the opkg
# package sqm-scripts and GL's own queue config.
a=0; [ -f "$OR/etc/init.d/sqm" ] || { a=1; echo "  /etc/init.d/sqm was removed"; }
b=0; [ -f "$OR/etc/config/sqm" ] || { b=1; echo "  /etc/config/sqm was removed"; }
chk "$(yn "$([ "$a$b" = 00 ]; echo $?)")" \
    "OLD-8" "p5_old_keeps holds: /etc/init.d/sqm and /etc/config/sqm survive a purge, because no teardown deletes them -- deriving the removal from contract/foreign instead would have taken GL's native queues"

# OLD-9: IDEMPOTENT, IN BOTH DIRECTIONS. Re-running the purge on the box it just
# purged is a no-op, and so is running it on a box that never carried the old
# package -- which is the case a rollback lands in.
unin "$OR" --purge --role client; rc1=$?
q2=$(find "$OR/etc/bond.p5-quarantine" -type f 2>/dev/null | wc -l | tr -d " ")
mkdir -p "$TMPBASE/oldnever/tmp"
mkmgmt "$TMPBASE/oldnever" client none
unin "$TMPBASE/oldnever" --purge --role client; rc2=$?
q3=$(find "$TMPBASE/oldnever" -name 'agg_w.*' 2>/dev/null | wc -l | tr -d " ")
chk "$(yn "$([ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$q2" = 1 ] && [ "$q3" = 0 ]; echo $?)")" \
    "OLD-9" "--purge is idempotent: a second run on the purged root exits $rc1 and does not re-quarantine (still $q2 file), and a root that never had the old package exits $rc2 quarantining nothing"

# OLD-4: NO REPORT, NO PURGE. CONTRACT.md:340-352 makes the management-path
# report a precondition for E7's first destructive command, so it is one: the
# refusal has to happen with the tree untouched, not half way through.
mkoldroot oldr4
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
grep -q 'CONTRACT.md:340-352' "$TMPBASE/uerr" && a=0 || a=1
grep -q 'P5_MGMT_CARRIER_SVC' "$TMPBASE/uerr" && b=0 || b=1
c=0; [ -f "$OR/etc/bond/agg_w" ] || { c=1; echo "  agg_w was touched by a refused purge"; }
chk "$(yn "$([ "$rc" = 5 ] && [ "$left" = "$before" ] && [ "$a$b$c" = 000 ]; echo $?)")" \
    "OLD-4" "--purge with no management-path report -> exit 5 citing the contract and printing the field recipe, and NOTHING was touched ($left of $before artifacts still present)"

# OLD-5: AN INCOMPLETE REPORT IS REFUSED TOO, and that is not pedantry: the
# cross-reference below is what the report is FOR, and it cannot run against a
# field nobody filled in. A file that merely exists would satisfy a presence
# check and defeat the whole precondition.
mkoldroot oldr5
mkmgmt "$OR" client none
grep -v '^P5_MGMT_CARRIER_SVC=' "$OR/tmp/p5-mgmt-path.report" > "$OR/tmp/r.tmp"
mv "$OR/tmp/r.tmp" "$OR/tmp/p5-mgmt-path.report"
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
grep -q 'INCOMPLETE' "$TMPBASE/uerr" && a=0 || a=1
grep -q 'P5_MGMT_CARRIER_SVC' "$TMPBASE/uerr" && b=0 || b=1
chk "$(yn "$([ "$rc" = 5 ] && [ "$left" = "$before" ] && [ "$a$b" = 00 ]; echo $?)")" \
    "OLD-5" "--purge with a report missing one field -> exit 5 naming the missing field, tree untouched ($left of $before)"

# OLD-6: THE SELF-SEVERING STEP, CAUGHT BY MACHINE. The report says which
# service carries the operator's session; this purge has a stop list. If they
# intersect, E7's first destructive step cuts the session running it -- the
# failure CONTRACT.md:340-352 describes -- and the run refuses instead.
mkoldroot oldr6
mkmgmt "$OR" client /etc/init.d/engarde-client
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
grep -q 'SELF-SEVERING' "$TMPBASE/uerr" && a=0 || a=1
grep -q '/etc/init.d/engarde-client' "$TMPBASE/uerr" && b=0 || b=1
chk "$(yn "$([ "$rc" = 5 ] && [ "$left" = "$before" ] && [ "$a$b" = 00 ]; echo $?)")" \
    "OLD-6" "--purge refuses when the report names a carrier service that is on its own stop list -> exit 5 naming it, tree untouched ($left of $before)"

# OLD-7: E7 IS CLIENT-ONLY, mechanised. On the server P5 installs ALONGSIDE and
# removes nothing (p5-execution-handover.md:88-100): nothing collides, the box
# has no physical access, the stated rollback assumes you can still reach it,
# and the old stack there carries the management path.
mkoldroot oldr7
mkmgmt "$OR" server none
unin "$OR" --purge --role server; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
grep -q 'CLIENT ONLY' "$TMPBASE/uerr" && a=0 || a=1
grep -q 'ALONGSIDE' "$TMPBASE/uerr" && b=0 || b=1
chk "$(yn "$([ "$rc" = 5 ] && [ "$left" = "$before" ] && [ "$a$b" = 00 ]; echo $?)")" \
    "OLD-7" "--purge --role server -> exit 5, refuses as CLIENT ONLY and removes nothing ($left of $before still present)"

# OLD-10: THE DERIVATION IS THE GATE. Nothing absent from p5_old_rows can become
# a destructive action, whatever else is true of it -- and the three shapes that
# matter are checked: a path that is foreign but undeclared, a `gl` management
# path (the operator's own SSH key), and a path inside P5's own namespace, so
# the two halves of a purge cannot act on each other's files.
sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_contract_dir "$2" ""
    for p in /etc/config/network /etc/dropbear/authorized_keys /usr/lib/p5/stamp /etc/passwd; do
        for k in file dir svc quarantine revert; do
            p5_old_removable "$p" "$k" && echo "ADMITTED|$k|$p"
        done
    done
    p5_old_removable /usr/sbin/bondctl file || echo "REFUSED-A-DECLARED-ROW|/usr/sbin/bondctl"
    p5_old_flag_removable /etc/rc.d/S99dropbear && echo "ADMITTED-FLAG|dropbear"
    p5_old_flag_removable /etc/rc.d/S50bond-ecod || echo "REFUSED-A-DECLARED-FLAG|bond-ecod"
    exit 0' _ "$LIB/p5-common.sh" "$CON" > "$TMPBASE/oldgate" 2>/dev/null
gb=$(grep -c . "$TMPBASE/oldgate" 2>/dev/null); [ -n "$gb" ] || gb=0
[ "$gb" = 0 ] || { echo "  the old-stack gate did not behave:"; sed 's/^/    /' "$TMPBASE/oldgate"; }
chk "$(yn "$([ "$gb" = 0 ]; echo $?)")" \
    "OLD-10" "the derived list IS the gate: an undeclared foreign path, a \`gl\` management path, an SSH key and a path inside P5's own namespace are all refused in every kind, while a declared row and a declared service's rc.d flag are admitted"

# OLD-R: THE TEARDOWN'S OWN FIRST STEP, AND IT IS NOT A REMOVAL.
# p3-ecod/bond-rollback.sh:6 -- ahead of every stop, disable and rm in the file
# -- is `/usr/sbin/bondctl off`, and p2-engarde/bondctl:263-269 says what that
# buys: `off` ends in apply_endpoint "$(live_direct)", which points the
# WireGuard peer back at the real server. While bonding is engaged that endpoint
# is the LOCAL engarde socket, so a purge that stops and unlinks engarde without
# running it first leaves the tunnel dead until a reboot. A list of ARTIFACTS
# cannot express a step, which is exactly how it went missing; this bar asserts
# it is carried, reported by --check, and planned FIRST.
mkoldroot oldrr
mkmgmt "$OR" client none
unin "$OR" --check --scope old; rrc=$?
a=0; grep -q "restore step has not been taken" "$TMPBASE/uout" || { a=1; echo "  --check --scope old never named the owed restore step"; }
unin "$OR" --purge --role client --dry-run
first=$(grep -E '^OLD[A-Z]+\|' "$TMPBASE/uout" | head -1)
case "$first" in
    OLDREVERT\|/usr/sbin/bondctl) b=0 ;;
    *) b=1; echo "  the first planned old-stack action is not the revert: '$first'" ;;
esac
c=0; [ -f "$OR/revert-calls" ] && { c=1; echo "  --dry-run actually RAN the revert"; }
# and now for real, on a fresh root: it runs, it runs as `off`, and it is
# reported. The stub records its own argv, so "it ran" is measured and not
# inferred from the absence of a complaint.
mkoldroot oldrr2
mkmgmt "$OR" client none
unin "$OR" --purge --role client; prc2=$?
calls=$(cat "$OR/revert-calls" 2>/dev/null)
d=0; [ "$calls" = "off" ] || { d=1; echo "  the revert tool was not invoked as 'off' (got '$calls')"; }
e=0; grep -q 'RESTORED FIRST' "$TMPBASE/uout" "$TMPBASE/uerr" 2>/dev/null || { e=1; echo "  the purge did not report the restore"; }
f=0; [ "$prc2" = 0 ] || { f=1; echo "  the purge did not exit 0 (rc=$prc2)"; }
chk "$(yn "$([ "$a$b$c$d$e$f" = 000000 ] && [ "$rrc" = 1 ]; echo $?)")" \
    "OLD-R" "the teardown's own first step is carried as an action, not assumed: --check --scope old names the owed '/usr/sbin/bondctl off' (rc=$rrc), --dry-run plans it as the FIRST action ('$first') without running it, and a real --purge invokes it as '$calls' and reports it before anything is stopped, moved or removed"

# OLD-R2: A FAILED RESTORE STOPS THE PURGE, WITH NOTHING REMOVED. This is the
# whole point of putting it first. Every action after it takes away something
# the box would need to put its own endpoint back, so a revert that did not
# work must not be followed by them. Seeded by giving the fixture a revert tool
# that exits non-zero -- the shape a real `bondctl off` takes when
# need_installed fails or `wg set` is refused.
mkoldroot oldrfail
mkmgmt "$OR" client none
printf '#!/bin/sh\necho "$*" >> "%s/revert-calls"\nexit 1\n' "$OR" > "$OR/usr/sbin/bondctl"
chmod +x "$OR/usr/sbin/bondctl"
beforef=$(oldleft "$OR" | wc -l | tr -d " ")
unin "$OR" --purge --role client; frc=$?
leftf=$(oldleft "$OR" | wc -l | tr -d " ")
a=0; [ "$leftf" = "$beforef" ] || { a=1; echo "  the purge removed $((beforef - leftf)) artifact(s) after its restore step failed"; }
b=0; [ -f "$OR/etc/bond/agg_w" ] || { b=1; echo "  agg_w was moved by a purge that should have stopped before the quarantine"; }
c=0; grep -q 'STOPPING THE PURGE HERE' "$TMPBASE/uerr" || { c=1; echo "  no stop was reported"; }
d=0; [ "$frc" = 0 ] && { d=1; echo "  the purge exited 0 after its restore step failed"; }
e=0; [ "$(cat "$OR/revert-calls" 2>/dev/null)" = "off" ] || { e=1; echo "  the failing tool was not the one invoked"; }
chk "$(yn "$([ "$a$b$c$d$e" = 00000 ] && [ "$beforef" -gt 0 ]; echo $?)")" \
    "OLD-R2" "a FAILED restore step stops the purge dead (rc=$frc): all $beforef declared artifacts are still present, agg_w has not even been quarantined yet, and the refusal says so -- the ordering is load-bearing, not cosmetic"

# p5count ROOT -> how many of the P5 files this box's own install record names
# are still present. Read off installed.files rather than counted with `find`,
# so "the P5 half did not run" is measured against what the install claims to
# have placed and not against whatever happens to be under the root.
p5count() {
    [ -r "$1/usr/lib/p5/installed.files" ] || { echo 0; return 0; }
    _pc=0
    for _pp in $(awk '{ if (NF >= 2) print $2 }' "$1/usr/lib/p5/installed.files"); do
        [ -e "$1$_pp" ] && _pc=$((_pc + 1))
    done
    echo "$_pc"
}

# OLD-R3: A STOPPED OLD HALF DOES NOT TAKE THE P5 HALF WITH IT.
# Every stop message in the old half says "nothing has been stopped, moved or
# removed", and until this bar existed that sentence was false about the half of
# the box the operator actually needs: do_purge caught old_execute's failure in
# a FLAG and then ran do_remove anyway, so a failed `bondctl off` left the old
# stack fully intact and P5 GONE -- the one state from which neither half of the
# tool can act, on a client whose tunnel is already down. The fixture is the
# only one in this file carrying BOTH stacks, because that is the only shape in
# which the defect is visible at all.
mkoldroot oldr3
mkmgmt "$OR" client none
P5_ROOT="$OR" sh "$BIN/p5-install" --package "$P9" --role client >"$TMPBASE/r3i.out" 2>"$TMPBASE/r3i.err"; r3i=$?
p3before=$(p5count "$OR")
o3before=$(oldleft "$OR" | wc -l | tr -d " ")
printf '#!/bin/sh\necho "$*" >> "%s/revert-calls"\nexit 1\n' "$OR" > "$OR/usr/sbin/bondctl"
chmod +x "$OR/usr/sbin/bondctl"
unin "$OR" --purge --role client; r3rc=$?
p3after=$(p5count "$OR")
o3after=$(oldleft "$OR" | wc -l | tr -d " ")
a=0
[ "$r3i" = 0 ] || { a=1; echo "  the fixture's P5 install did not succeed (rc=$r3i)"; sed 's/^/    /' "$TMPBASE/r3i.err"; }
[ "$p3before" -gt 0 ] || { a=1; echo "  the fixture carries no P5 files, so this bar could not see the defect"; }
[ "$p3after" = "$p3before" ] || { a=1; echo "  the P5 half RAN after the old half stopped: $p3before -> $p3after files"; }
[ -f "$OR/usr/lib/p5/stamp" ] || { a=1; echo "  the P5 stamp is gone after a purge that stopped in its old half"; }
[ "$o3after" = "$o3before" ] || { a=1; echo "  $((o3before - o3after)) old artifact(s) were removed after the stop"; }
[ "$r3rc" = 5 ] || { a=1; echo "  the stopped purge did not exit 5 (rc=$r3rc)"; }
grep -q 'THE P5 HALF HAS NOT RUN' "$TMPBASE/uerr" || { a=1; echo "  the run never said the P5 half had not run"; }
[ -f "$OR/var/run/p5/purge.inprogress" ] || { a=1; echo "  no purge progress record was left for the re-run"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "OLD-R3" "a failed restore step ENDS the purge: on a root carrying BOTH stacks the run exits 5 saying the P5 half has not run, and it has not -- all $p3before recorded P5 files and the stamp are still there, all $o3before old artifacts are still there, and a progress record is left behind to resume from"

# OLD-R4: A HALF-FINISHED PURGE CAN BE FINISHED. P5_FAULT_AFTER kills the run
# HARD (kill -9, no trap) one action after /usr/sbin/bondctl is unlinked and
# before /etc/bond is removed -- the window in which the box is "bonding still
# resident, restore tool gone", which old_bonding_resident refuses. That refusal
# is right for a box nobody purged and unanswerable for this one: it asks the
# operator to put an endpoint back with a tool the purge itself deleted, and
# nothing they can do changes the state that produced it. The record is what
# separates the two cases, so the re-run has to FINISH.
mkoldroot oldr4
mkmgmt "$OR" client none
unin "$OR" --purge --role client --dry-run
r4idx=$(grep -E '^OLD[A-Z]+\|' "$TMPBASE/uout" | grep -n -F -x 'OLDFILE|/usr/sbin/bondctl' | cut -d: -f1)
[ -n "$r4idx" ] || r4idx=0
r4kill=$((r4idx + 1))
P5_ROOT="$OR" P5_FAULT_AFTER="$r4kill" sh "$BIN/p5-uninstall" --purge --role client \
    >"$TMPBASE/r4k.out" 2>"$TMPBASE/r4k.err"; r4krc=$?
r4mid=$(oldleft "$OR" | wc -l | tr -d " ")
a=0
[ "$r4idx" -gt 0 ] || { a=1; echo "  the plan never named OLDFILE|/usr/sbin/bondctl, so the kill point is not the one this bar describes"; }
[ -e "$OR/usr/sbin/bondctl" ] && { a=1; echo "  the kill landed before bondctl was unlinked -- not the window this bar names"; }
[ -d "$OR/etc/bond" ] || { a=1; echo "  the kill landed after /etc/bond was removed -- not the window this bar names"; }
[ -f "$OR/var/run/p5/purge.inprogress" ] || { a=1; echo "  the interrupted purge left no progress record"; }
grep -q '^done|OLDREVERT|/usr/sbin/bondctl$' "$OR/var/run/p5/purge.inprogress" 2>/dev/null \
    || { a=1; echo "  the record does not say the restore step was taken, which is the one fact the box cannot show"; }
unin "$OR" --purge --role client; r4rc=$?
r4left=$(oldleft "$OR" | wc -l | tr -d " ")
[ "$r4rc" = 0 ] || { a=1; echo "  the re-run did not finish the purge (rc=$r4rc)"; sed 's/^/    /' "$TMPBASE/uerr"; }
[ "$r4left" = 0 ] || { a=1; echo "  $r4left old artifact(s) survived the re-run"; }
grep -q 'RESUME' "$TMPBASE/uout" || { a=1; echo "  the re-run never announced that it was resuming"; }
grep -q 'already done by an earlier run' "$TMPBASE/uout" || { a=1; echo "  the re-run never reported skipping a recorded action"; }
[ -f "$OR/var/run/p5/purge.inprogress" ] && { a=1; echo "  the finished purge left its progress record behind"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "OLD-R4" "an interrupted purge is finishable: killed hard at action $r4kill (bondctl unlinked, /etc/bond still standing, $r4mid artifacts left) it leaves a progress record naming the restore step as taken, and a plain re-run RESUMES from it -- exit $r4rc, $r4left old artifacts left, record removed. Without the record that state is the one old_bonding_resident refuses forever"

# OLD-Q2: THE QUARANTINE'S DESTINATION IS RESOLVED, NOT SPELLED.
# p5_old_removable resolves every symlink on the way to the SOURCE (step 6,
# which is what the round-2 SSH-key escape bought). The destination did not get
# the same treatment: p5_old_quarantine_of builds /etc/bond.p5-quarantine/... as
# a STRING and mkdir -p and mv both follow symlinks, so a pre-existing
# /etc/bond.p5-quarantine -> /etc/bond puts the one file this whole action
# exists to keep INSIDE the tree the same plan rm -rf's four actions later,
# while the log says "QUARANTINED, NOT DELETED". The symlink is planted
# RELATIVE on purpose: an absolute target would resolve against the real host
# and measure nothing.
mkoldroot oldq2
mkmgmt "$OR" client none
ln -s bond "$OR/etc/bond.p5-quarantine"
q2before=$(oldleft "$OR" | wc -l | tr -d " ")
unin "$OR" --purge --role client; q2rc=$?
q2left=$(oldleft "$OR" | wc -l | tr -d " ")
q2copies=$(find "$OR" -name 'agg_w*' 2>/dev/null | wc -l | tr -d " ")
a=0
[ "$q2rc" = 5 ] || { a=1; echo "  the purge did not stop on the symlinked quarantine destination (rc=$q2rc)"; }
grep -q 'does not physically land where it is spelled' "$TMPBASE/uerr" || { a=1; echo "  the refusal never named the resolved destination"; }
grep -q "$AGGW_CANARY" "$OR/etc/bond/agg_w" 2>/dev/null || { a=1; echo "  agg_w is not where it was, byte for byte"; }
[ "$q2left" = "$q2before" ] || { a=1; echo "  $((q2before - q2left)) artifact(s) were removed by a purge that should have stopped"; }
[ "$q2copies" = 1 ] || { a=1; echo "  agg_w exists in $q2copies places, so something moved it"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "OLD-Q2" "a quarantine destination that RESOLVES inside a directory this purge removes whole is refused: with /etc/bond.p5-quarantine symlinked to /etc/bond the run stops (rc=$q2rc) naming the resolved path, agg_w is still the original file in its original place ($q2copies copy), and all $q2before old artifacts are untouched"

# MU-OLD-Q: THE MUTATION. The quarantine is deleted from a COPY of the shipped
# uninstaller -- exactly the seeded A/B this unit owes -- and the same fixture
# is purged with it. Without the quarantine the file is taken by the recursive
# removal of /etc/bond that runs later in the SAME plan, so OLD-3's evidence
# disappears. Without this bar, "OLD-3 passes" is indistinguishable from "OLD-3
# cannot fail".
MUTD="$TMPBASE/oldmut"
mkdir -p "$MUTD/bin" "$MUTD/lib" "$MUTD/contract"
cp "$LIB/p5-common.sh" "$MUTD/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$MUTD/contract/"
sed 's/echo "OLDQUAR.*/:/' "$BIN/p5-uninstall" > "$MUTD/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$MUTD/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the OLDQUAR emit site was not found"; }
mkoldroot oldmutr
mkmgmt "$OR" client none
P5_ROOT="$OR" sh "$MUTD/bin/p5-uninstall" --purge --role client >"$TMPBASE/mq.out" 2>"$TMPBASE/mq.err"; mrc=$?
mq=$(find "$OR" -name 'agg_w*' 2>/dev/null | wc -l | tr -d " ")
[ "$mq" = 0 ] || { a=1; echo "  the mutant still preserved agg_w ($mq copies) -- the seed did not bite"; }
grep -q 'QUARANTINED, NOT DELETED' "$TMPBASE/mq.err" "$TMPBASE/mq.out" 2>/dev/null && { a=1; echo "  the mutant still reported a quarantine"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-OLD-Q" "MUTATION: with the quarantine action removed from the shipped uninstaller, the same purge (exit $mrc) DESTROYS /etc/bond/agg_w -- $mq copies of it survive anywhere under the root. OLD-3 is a bar that can fail"

# MU-OLD-R: the same mutation shape for the restore step. The OLDREVERT emit is
# deleted from a COPY of the shipped uninstaller and the same fixture is purged
# with it: the mutant removes the whole old stack WITHOUT ever running
# `bondctl off`, which is precisely the defect OLD-R exists to catch and which
# the first cut of this unit shipped. Without this bar, "OLD-R passes" is
# indistinguishable from "OLD-R cannot fail".
MUTR="$TMPBASE/oldmutr"
mkdir -p "$MUTR/bin" "$MUTR/lib" "$MUTR/contract"
cp "$LIB/p5-common.sh" "$MUTR/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$MUTR/contract/"
sed 's/echo "OLDREVERT.*/:/' "$BIN/p5-uninstall" > "$MUTR/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$MUTR/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the OLDREVERT emit site was not found"; }
mkoldroot oldmutrr
mkmgmt "$OR" client none
P5_ROOT="$OR" sh "$MUTR/bin/p5-uninstall" --purge --role client >"$TMPBASE/mr.out" 2>"$TMPBASE/mr.err"; mrrc=$?
mrc_calls=$(cat "$OR/revert-calls" 2>/dev/null)
[ -z "$mrc_calls" ] || { a=1; echo "  the mutant still ran the revert ('$mrc_calls') -- the seed did not bite"; }
grep -q 'RESTORED FIRST' "$TMPBASE/mr.out" "$TMPBASE/mr.err" 2>/dev/null && { a=1; echo "  the mutant still reported a restore"; }
mrleft=$(oldleft "$OR" | wc -l | tr -d " ")
[ "$mrleft" = 0 ] || { a=1; echo "  the mutant did not get as far as removing the stack ($mrleft left), so this is not the defect OLD-R names"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-OLD-R" "MUTATION: with the restore step removed from the shipped uninstaller, the same purge (exit $mrrc) tears the whole old stack down WITHOUT ever running 'bondctl off' -- engarde gone, WireGuard peer still on the local socket. OLD-R is a bar that can fail"

# ===========================================================================
# KEY -- the transport secret is ON the box, and both preflights refuse without it
# ===========================================================================
# U31 shipped the authenticated framing and left it OFF. daemon/auth.go:117-120
# defaults the secret to /etc/p5/transport.key, pullrun.go:184-199 LOGS a load
# failure and runs on regardless, and nothing placed the file -- so every
# install was byte-for-byte the pre-U31 wire. These bars are the mechanism that
# closes that, and they are falsifiable: MU-KEY-1 removes the install step from
# a COPY of the shipped installer and asserts KEY-1's own predicate goes false.
#
# THEY ASSERT PRESENCE, MODE, SHAPE AND NON-DISCLOSURE, NEVER A VALUE. The one
# bar that touches the bytes at all, KEY-2, uses the key FILE as grep's pattern
# file, so the secret never becomes an argument, a variable or a printed line.
ROOTDIR=$(cd "$P5DIR/.." && pwd)
PRE_S="$ROOTDIR/deploy/server/p5-server-preflight.sh"
PRE_C="$ROOTDIR/deploy/p5/p5-client-preflight.sh"

RK=$TMPBASE/rkey; PK=$TMPBASE/pkgkey; mkpkg "$PK" </dev/null
inst "$RK" "$PK" client; rc=$?
KEYP="$RK/etc/p5/transport.key"
k=0
[ "$rc" = 0 ] || { echo "  the install itself did not succeed (rc=$rc)"; k=1; }
[ -f "$KEYP" ] || { echo "  no transport secret at /etc/p5/transport.key after a clean install"; k=1; }
kperm=$(ls -l "$KEYP" 2>/dev/null | head -1 | cut -c1-10)
[ "$kperm" = "-rw-------" ] || { echo "  transport secret mode is '${kperm:-unreadable}', must be -rw------- (600)"; k=1; }
klines=$(grep -c . "$KEYP" 2>/dev/null); [ -n "$klines" ] || klines=0
[ "$klines" = 1 ] || { echo "  transport secret is $klines line(s); it must be exactly one"; k=1; }
grep -qxE '[0-9a-f]{64}' "$KEYP" 2>/dev/null || { echo "  transport secret is not 64 lower-case hex characters on one line"; k=1; }
grep -q ' /etc/p5/transport.key$' "$RK/usr/lib/p5/installed.files" 2>/dev/null \
    || { echo "  the secret is NOT in installed.files, so --remove would leave it on the box"; k=1; }
grep -q '^P5_TRANSPORT_KEY_ID=[0-9a-f][0-9a-f]*$' "$RK/usr/lib/p5/stamp" 2>/dev/null \
    || { echo "  the stamp carries no P5_TRANSPORT_KEY_ID, so the two boxes cannot be compared without printing the secret"; k=1; }
chk "$(yn "$([ "$k" = 0 ]; echo $?)")" \
    "KEY-1" "a clean install PLACES the transport secret: /etc/p5/transport.key exists, mode $kperm, one 64-hex line, recorded in installed.files, and identified in the stamp by a truncated hash (rc=$rc)"

# KEY-2: THE SECRET IS NEVER DISCLOSED. The installer's stdout, its stderr and
# the stamp are searched for the value itself -- with the key FILE as grep's
# pattern file, so nothing here ever holds or prints it. A leak here is not
# theoretical: the obvious implementations (`echo "$key" > file`, or logging
# what was generated) both put it in a place a later reader keeps.
k2=0
for f in "$TMPBASE/out" "$TMPBASE/err" "$RK/usr/lib/p5/stamp" "$RK/usr/lib/p5/installed.files"; do
    [ -f "$f" ] || continue
    if grep -qF -f "$KEYP" "$f" 2>/dev/null; then
        echo "  THE SECRET'S VALUE APPEARS IN: $f"; k2=1
    fi
done
chk "$(yn "$([ "$k2" = 0 ] && [ -s "$KEYP" ]; echo $?)")" \
    "KEY-2" "the secret's value appears in none of the installer's stdout, its stderr, the stamp or installed.files -- only its hash does"

# MU-KEY-1: THE MUTATION. A copy of the shipped installer with the placement
# line removed still exits 0 and still writes a complete-looking record -- the
# contract set-equality (IN-14/IN-15) compares DECLARED destinations, not what
# landed, so nothing else in this battery notices. KEY-1 is the bar that does.
MUTB=$TMPBASE/mutbin; mkdir -p "$MUTB"
sed '/^place 600 "\$WORK\/transport.key"/d' "$BIN/p5-install" > "$MUTB/p5-install"
cp "$BIN/p5-uninstall" "$BIN/p5-version" "$BIN/p5-deadman" "$MUTB/"
mu=0
cmp -s "$BIN/p5-install" "$MUTB/p5-install" && { mu=1; echo "  MUTATION DID NOT APPLY: the placement line was not found"; }
RKM=$TMPBASE/rkeymut
P5_ROOT="$RKM" P5_LIB_SRC="$LIB" P5_CONTRACT_SRC="$CON" \
    sh "$MUTB/p5-install" --package "$PK" --role client >"$TMPBASE/mkout" 2>"$TMPBASE/mkerr"; murc=$?
[ -f "$RKM/etc/p5/transport.key" ] && { mu=1; echo "  the mutant placed a key anyway -- the mutation did not remove the step"; }
[ -f "$RKM/usr/lib/p5/stamp" ] || { mu=1; echo "  the mutant did not get far enough to be a fair control (rc=$murc)"; }
chk "$(yn "$([ "$mu" = 0 ]; echo $?)")" \
    "MU-KEY-1" "MUTATION: with the placement step deleted the installer still finishes (rc=$murc) and still writes a stamp, and the box carries NO transport secret -- so the daemon would run with authentication off and KEY-1 is a bar that can fail"

# KEY-3: the server gets one too. The contract row is role=both, and a server
# with no secret is the box that cannot be recovered running a forgeable wire.
RKS=$TMPBASE/rkeysrv; PKS=$TMPBASE/pkgkeysrv; mkpkg "$PKS" server </dev/null
inst "$RKS" "$PKS" server; rc=$?
k3=0
[ "$rc" = 0 ] || { echo "  the server install did not succeed (rc=$rc)"; k3=1; }
sperm=$(ls -l "$RKS/etc/p5/transport.key" 2>/dev/null | head -1 | cut -c1-10)
[ "$sperm" = "-rw-------" ] || { echo "  server transport secret mode is '${sperm:-absent}', must be -rw-------"; k3=1; }
chk "$(yn "$([ "$k3" = 0 ]; echo $?)")" \
    "KEY-3" "a --role server install places the secret too, mode ${sperm:-absent} (rc=$rc)"

# KEY-4: REMOVAL TAKES IT. A secret that outlives the product it authenticated
# is a leftover with a longer life than the box's own record of it. This is the
# whole reason the contract row is state=install rather than state=runtime.
unin "$RK" --remove --role client; rc=$?
k4=0
[ "$rc" = 0 ] || { echo "  --remove did not succeed (rc=$rc)"; k4=1; }
[ -e "$KEYP" ] && { echo "  the transport secret survived --remove"; k4=1; }
chk "$(yn "$([ "$k4" = 0 ]; echo $?)")" \
    "KEY-4" "--remove takes the transport secret with the rest of the install (rc=$rc); nothing at /etc/p5/transport.key survives"

# The preflight fixtures. Three roots: a good one per preflight (so a seed on
# one cannot move the other's bar), one with the secret world-readable, and one
# with no secret at all.
mkkey() {   # mkkey ROOT MODE -- put a well-formed secret under ROOT at MODE
    mkdir -p "$1/etc/p5"
    ( umask 077; od -An -v -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' > "$1/etc/p5/transport.key" && echo >> "$1/etc/p5/transport.key" )
    chmod "$2" "$1/etc/p5/transport.key"
}
KFOK_S=$TMPBASE/kfoks; mkkey "$KFOK_S" 600
KFOK_C=$TMPBASE/kfokc; mkkey "$KFOK_C" 600
KF644=$TMPBASE/kf644;  mkkey "$KF644" 644
KFNONE=$TMPBASE/kfnone; mkdir -p "$KFNONE/etc"

# pfbar NAME SCRIPT ROOT WANT_RC MUST_MATCH DESC -- run a preflight against a
# fixture root and assert BOTH its exit code and that its output says why. An
# exit code with no named file is a refusal an operator cannot act on.
pfbar() {
    _pf_n="$1"; _pf_s="$2"; _pf_r="$3"; _pf_w="$4"; _pf_m="$5"; _pf_d="$6"
    if [ ! -f "$_pf_s" ]; then
        bad "$_pf_n" "the preflight script is not in this tree: $_pf_s (this bar FAILS rather than skipping)"
        return 0
    fi
    P5_ROOT="$_pf_r" sh "$_pf_s" >"$TMPBASE/pf.out" 2>&1; _pf_rc=$?
    _pf_bad=0
    if [ "$_pf_w" = 0 ]; then
        [ "$_pf_rc" = 0 ] || { echo "  expected exit 0, got $_pf_rc:"; grep -i 'refuse' "$TMPBASE/pf.out" | sed 's/^/    /'; _pf_bad=1; }
    else
        [ "$_pf_rc" = 0 ] && { echo "  expected a NON-ZERO exit, got 0 -- the preflight passed a box the daemon would run unauthenticated on"; _pf_bad=1; }
    fi
    grep -q "$_pf_m" "$TMPBASE/pf.out" || { echo "  the output never said '$_pf_m':"; sed 's/^/    /' "$TMPBASE/pf.out" | tail -20; _pf_bad=1; }
    grep -q "$_pf_r/etc/p5/transport.key" "$TMPBASE/pf.out" || { echo "  the output did not NAME the file it judged"; _pf_bad=1; }
    chk "$(yn "$([ "$_pf_bad" = 0 ]; echo $?)")" "$_pf_n" "$_pf_d (rc=$_pf_rc)"
}

pfbar KEY-5  "$PRE_S" "$KFOK_S" 0 'transport-key: ok' "the SERVER preflight passes when the secret is present and owner-only"
pfbar KEY-6  "$PRE_S" "$KFNONE" 1 'REFUSE'            "the SERVER preflight REFUSES with a non-zero exit when the secret is ABSENT, naming the file"
pfbar KEY-7  "$PRE_S" "$KF644"  1 'REFUSE'            "the SERVER preflight REFUSES with a non-zero exit when the secret is mode 644, naming the file"
pfbar KEY-8  "$PRE_C" "$KFOK_C" 0 'transport-key: ok' "the CLIENT preflight passes when the secret is present and owner-only"
pfbar KEY-9  "$PRE_C" "$KFNONE" 1 'REFUSE'            "the CLIENT preflight REFUSES with a non-zero exit when the secret is ABSENT, naming the file"
pfbar KEY-10 "$PRE_C" "$KF644"  1 'REFUSE'            "the CLIENT preflight REFUSES with a non-zero exit when the secret is mode 644, naming the file"

# KEY-11: THE PATH IS ONE FACT, NOT THREE. IN-14/IN-15 already tie the
# installer's literal to the contract row. BOTH daemons, though, read the
# secret from a Go constant nothing in this battery had ever looked at, and the
# init scripts set no AGG_KEY_FILE -- so the entire mechanism rests on
# p4-bondagg/daemon/auth.go:120 and p4-bondagg/server/auth.go:204 agreeing with
# contract/paths. Relocate one side alone and the install places a secret at
# one path while the daemon looks at another, finds nothing, LOGS it and RUNS
# ON with authentication OFF (daemon/pullrun.go:184-199, server/main.go:374-386
# both take that branch). Silent by construction on a box with no console,
# which is the exact failure class a bar has to make loud.
k11=0
kp_con=$(awk -F'|' '$1=="file"{p=$3; gsub(/^[ \t]+|[ \t]+$/,"",p); if (p ~ /transport\.key$/) {print p; exit}}' "$CON/paths")
[ -n "$kp_con" ] || { echo "  contract/paths declares no transport-secret row at all"; k11=1; }
for _g in p4-bondagg/daemon/auth.go p4-bondagg/server/auth.go; do
    if [ ! -f "$ROOTDIR/$_g" ]; then
        echo "  $_g is not in this tree, so the coupling cannot be checked -- this bar FAILS rather than skipping"; k11=1; continue
    fi
    _gv=$(sed -n 's/^const KeyFileDefault = "\(.*\)"$/\1/p' "$ROOTDIR/$_g" | head -1)
    if [ -z "$_gv" ]; then
        echo "  $_g declares no KeyFileDefault constant in the form this bar reads"; k11=1; continue
    fi
    [ "$_gv" = "$kp_con" ] || { echo "  $_g reads the secret from '$_gv' but the install places it at '$kp_con'"; k11=1; }
done
chk "$(yn "$([ "$k11" = 0 ]; echo $?)")" \
    "KEY-11" "the placed path and BOTH daemons' KeyFileDefault are one literal ('$kp_con'): contract/paths, p4-bondagg/daemon/auth.go and p4-bondagg/server/auth.go agree, so relocating one side cannot leave the secret unread and authentication silently off"

# FL-1: THE BAR-COUNT FLOOR, INSIDE THE BATTERY (U146).
#
# SC-1 proves the summary matches the bars that RAN. It cannot see bars that
# never ran: a battery that dies early, or one a bad edit truncates, exits 0
# with a smaller honest number and reads as green. The runner has carried a
# floor for this (emulator-gate.yml, job p5-skeleton, `-lt 40`) but the LOCAL
# gate arm (`scripts/ci-wsl.sh e0` -> ci-local.sh gate_e0) runs `sh
# p5/test/run.sh` with no floor at all, so every local green was unfloored.
# The floor therefore lives HERE, where both arms see it.
#
# MEASURED, not chosen: 142 bars at b41a5db (`bash scripts/ci-wsl.sh e0`,
# "p5-skeleton: 142 passed, 0 failed"), of which 140 run BEFORE this point --
# SC-1 and MU-SC come after it -- plus EXG-1/EXG-2/EXG-3/MU-EXG = 144, plus the
# fix round's EXG-4/EXG-5/EXG-6 = 147. RAISE IT when bars are added; never lower
# it to go green: lowering it is the move this bar exists to make visible.
# PK-1 -- EVERY FILE A SHIPPED PROGRAM SOURCES MUST ITSELF BE SHIPPED.
#
# THE DEFECT THIS EXISTS TO CATCH, measured on dev at 97e0254: U124 split
# bond-xctl into five libraries under deploy/p5/lib/ and bond-xctl:161-171
# sources all five from $XCTL_LIB (default /usr/lib/p5), each behind a hard
# `[ -r ... ] || fail "missing ..."`. U28 then wrote the package builder. NEITHER
# added a filemap row for them, so the built package carried /usr/sbin/p5-reconciler
# and no lib/ directory at all: `find "$PKG" -name '*xctl*'` returned exactly one
# path, the reconciler itself. An installed box would run the reconciler once and
# die with "missing /usr/lib/p5/xctl-lock.sh".
#
# NOTHING SAW IT. Layer-2 runs bond-xctl out of the REPO tree with XCTL_LIB
# overridden, so it never meets the packaged layout; the battery's own install and
# manifest bars check that what the filemap DECLARES arrives intact, never that the
# filemap declares enough for the program to start. Both were green.
#
# So this bar is deliberately GENERIC rather than a list of the five names: it reads
# the source lines out of every program the filemap ships and requires each sourced
# basename to be some filemap destination. The next split is covered without anyone
# remembering to extend it.
_pk_repo=$(cd "$P5DIR/.." && pwd)
pk_unshipped() {        # pk_unshipped FILEMAP -> one line per sourced-but-unpackaged file
    _pkf=$1
    _pkd=$(grep -v '^#' "$_pkf" | cut -d'|' -f4)
    grep -v '^#' "$_pkf" | while IFS='|' read -r _pkm _pkr _pks _pkdst; do
        [ -n "${_pks:-}" ] || continue
        [ -f "$_pk_repo/$_pks" ] || continue
        sed -n 's/^[[:space:]]*\.[[:space:]][[:space:]]*"\$[A-Za-z_][A-Za-z0-9_]*\/\([^"]*\)".*/\1/p' \
            "$_pk_repo/$_pks" | sort -u | while read -r _pkn; do
            [ -n "$_pkn" ] || continue
            echo "$_pkd" | grep -q "/$_pkn\$" || \
                echo "  $_pks sources $_pkn -- no filemap row ships it"
        done
    done
}
pk1_out=$(pk_unshipped "$P5DIR/payload/filemap")
pk1_n=$(printf '%s' "$pk1_out" | grep -c . )
[ -n "$pk1_out" ] && printf '%s\n' "$pk1_out"
chk "$(yn "$([ "$pk1_n" = 0 ]; echo $?)")" \
    "PK-1" "every file a shipped program sources is itself in the filemap ($pk1_n unpackaged). A program that starts by sourcing a file the package does not carry dies on its first run, and no install-time or manifest bar can see it"

# MU-PK1 -- THE SEED. A bar nobody has watched fail is not a bar. Drop the
# xctl-lock.sh row from a COPY of the filemap; PK-1's finder must name it.
pk_mut="$TMPBASE/filemap.mu-pk1"
grep -v '^644|client|deploy/p5/lib/xctl-lock.sh|' "$P5DIR/payload/filemap" > "$pk_mut"
pk_mu_out=$(pk_unshipped "$pk_mut")
pk_mu_applied=$(( $(grep -c . "$P5DIR/payload/filemap") - $(grep -c . "$pk_mut") ))
chk "$(yn "$([ "$pk_mu_applied" = 1 ] && echo "$pk_mu_out" | grep -q 'xctl-lock.sh'; echo $?)")" \
    "MU-PK1" "MUTATION: the xctl-lock.sh row removed from a copy of the filemap -> PK-1's finder names it, so PK-1 is able to fail (rows removed: $pk_mu_applied)"

P5T_FLOOR=161
bars_before=$((pass + fail))
chk "$(yn "$([ "$bars_before" -ge "$P5T_FLOOR" ]; echo $?)")" \
    "FL-1" "$bars_before bars ran before this one, floor $P5T_FLOOR: the battery was not truncated. A count BELOW the floor means bars were removed or the run died early -- fix that, or justify the new floor in the commit that lowers it"

# SC-1: THE SUMMARY IS THE LEDGER. Every bar line above was appended to a ledger
# file in the same call that printed it. This reconciles the counters against
# it. It is evaluated BEFORE its own line is emitted, so the two numbers it
# compares are the ones the ledger holds at this instant; p5t_report then
# re-runs the same reconciliation over the final state, including this bar.
if p5t_sc_check "$P5T_LEDGER" "$pass" "$fail"; then
    ok  "SC-1" "the summary and the bars are one record: $P5T_LP PASS and $P5T_LF FAIL lines were written to the ledger as they were printed, and the counters say $pass/$fail"
else
    bad "SC-1" "the summary DISAGREES with the bars: ledger $P5T_LP/$P5T_LF, counters $pass/$fail"
fi

# MU-SC: THE MUTATION, end to end. A whole harness is stood up that sources this
# battery's own ledger.sh and loses one counter in a subshell -- `| while read`,
# the shape that prints a bar line and throws the increment away with the
# subshell, and the only shape that can make printed bars and a summary disagree
# without either side looking wrong on its own. The control runs the same two
# bars with no subshell. The control must exit 0 and say self-checked; the
# mutant must exit non-zero and name SC-1. Without this, "SC-1 passes" is
# indistinguishable from "SC-1 cannot fail".
cat > "$TMPBASE/sc-control.sh" <<'SCEOF'
. "$1/ledger.sh"
W=$(p5t_workdir p5-scmut) || exit 9
trap 'rm -rf "$W"' EXIT
p5t_ledger_init "$W/ledger" || exit 9
ok "SC-A" "a bar counted in the main shell"
ok "SC-B" "a second bar counted in the main shell"
p5t_report "p5-scmut" "$P5T_LEDGER" "$pass" "$fail"
SCEOF
sed 's|^ok "SC-B".*|echo x \| while read -r _; do ok "SC-B" "a bar whose counter dies with the subshell"; done|' \
    "$TMPBASE/sc-control.sh" > "$TMPBASE/sc-mutant.sh"
a=0
cmp -s "$TMPBASE/sc-control.sh" "$TMPBASE/sc-mutant.sh" && { a=1; echo "  MUTATION DID NOT APPLY: the SC-B call site was not found"; }
sh "$TMPBASE/sc-control.sh" "$here" > "$TMPBASE/sc-c.out" 2>&1; sc_crc=$?
sh "$TMPBASE/sc-mutant.sh"  "$here" > "$TMPBASE/sc-m.out" 2>&1; sc_mrc=$?
[ "$sc_crc" = 0 ] || { a=1; echo "  the CONTROL did not pass (rc=$sc_crc):"; sed 's/^/    /' "$TMPBASE/sc-c.out"; }
grep -q 'self-checked' "$TMPBASE/sc-c.out" || { a=1; echo "  the control did not report a self-checked summary"; }
grep -q '^FAIL  SC-1' "$TMPBASE/sc-c.out" && { a=1; echo "  the control reported SC-1 red with nothing wrong"; }
[ "$sc_mrc" = 0 ] && { a=1; echo "  the MUTANT exited 0 -- a lost counter did not fail the run"; }
grep -q '^FAIL  SC-1' "$TMPBASE/sc-m.out" || { a=1; echo "  the mutant did not report SC-1:"; sed 's/^/    /' "$TMPBASE/sc-m.out"; }
grep -q 'PASS  SC-B' "$TMPBASE/sc-m.out" || { a=1; echo "  the mutant did not even print the bar line it loses"; }
grep -q 'NOT TRUSTWORTHY' "$TMPBASE/sc-m.out" || { a=1; echo "  the mutant printed a summary without marking it untrustworthy"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-SC" "MUTATION: a bar whose counter is lost in a subshell still PRINTS its PASS line, and the run goes red -- control exit $sc_crc self-checked, mutant exit $sc_mrc reporting SC-1 over a summary it marks NOT TRUSTWORTHY. SC-1 is a bar that can fail"

p5t_report "p5-skeleton" "$P5T_LEDGER" "$pass" "$fail"
exit $?
