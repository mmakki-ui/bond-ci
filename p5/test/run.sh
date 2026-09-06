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
# THE `rm` ARGV SHIM (U188) -- RULE ZERO MADE MECHANICAL
# ===========================================================================
# Mo's standing requirement is that a removal never does `rm -rf`. RMRF-0 below
# greps the four shipped files for one; this is the other half, and it measures
# the RUN rather than the source: every p5-install / p5-uninstall invocation
# this battery makes goes out with $RMSHIM at the front of PATH, so the `rm`
# those scripts call is this script. It APPENDS THE ARGV to a ledger and
# REFUSES (exit 1, nothing removed) any recursive form, which makes every green
# removal bar in this file also a statement that no recursive rm was invoked.
#
# RULE ZERO, in its own words (docs/knowledge/root-causes/2026-09-03-bin-deletion.md):
# a destructive defect is proved on the ARGV, never by running it. So the shim
# must never replace itself with the real rm -- if it did, the measurement and
# the thing measured would be one process again, which is how the containment in
# an earlier A/B harness vanished unnoticed. Bar NR-2 asserts that word does not
# appear in this file at all, and it is why the real rm is invoked as an
# ordinary child below.
RMSHIM="$TMPBASE/rmshim"
RMLEDGER="$TMPBASE/rm-argv"
mkdir -p "$RMSHIM"
: > "$RMLEDGER"
RMREAL=$(command -v rm 2>/dev/null)
[ -n "$RMREAL" ] || bad "TOOL" "required tool missing: rm"
cat > "$RMSHIM/rm" <<RMSHIMEOF
#!/bin/sh
# p5/test rm argv shim -- see the block in p5/test/run.sh that writes it.
printf '%s\n' "rm \$*" >> "$RMLEDGER"
for _a in "\$@"; do
    case "\$_a" in
        --recursive|--recursive=*|-*[rR]*)
            printf '%s\n' "REFUSED rm \$*" >> "$RMLEDGER"
            echo "rm shim: REFUSED a recursive rm: rm \$*" >&2
            exit 1 ;;
    esac
done
"$RMREAL" "\$@"
RMSHIMEOF
chmod 0755 "$RMSHIM/rm"


# ===========================================================================
# P5_PKG -- run the package bars against a REAL built package (U118)
# ===========================================================================
# UNSET: mkpkg fabricates the fixture it always did and every bar below is the
# run this battery has always made. That path is not touched.
#
# SET: it must name a directory `scripts/build-p5-package.sh` produced, and
# every package bar drives a COPY of THAT tree -- the one U28 ships to a box
# with no console. Until this existed the battery had only ever seen a
# three-file fixture invented eleven lines above the bars, so "the installer
# works" was a claim about mkpkg.
#
# A MISSING OR MALFORMED P5_PKG ABORTS, HERE, BEFORE THE FIRST BAR. It does
# not fall back to mkpkg and it does not skip: either would print a passing
# summary over a package nobody built, which is the same defect as a gate that
# passes when it checks nothing. Aborting before bar 1 also means no partial
# ledger can be read as a result.
# A SET-BUT-EMPTY P5_PKG normalises to unset and runs the synthetic mode. That is
# deliberate -- `P5_PKG=` and `P5_PKG` absent are the same statement ("no package
# handed to this run"), and a CI expression that expands to nothing must not be
# read as a package whose path is "". It is NOT a silent fallback: the summary
# names the mode either way and says empty and unset are the same thing there.
P5_PKG="${P5_PKG:-}"
PKG_MODE=synthetic
if [ -n "$P5_PKG" ]; then
    PKG_MODE=real
    pkg_bad=
    if [ ! -d "$P5_PKG" ]; then
        pkg_bad="P5_PKG is not a directory"
    else
        pkg_miss=
        # Every missing file is named, not just the first: an empty directory is
        # missing all three, and a reader who fixes only the one the harness
        # happened to mention first gets a second abort for free.
        for f in MANIFEST.sha256 PROVENANCE payload/filemap; do
            [ -r "$P5_PKG/$f" ] || pkg_miss="$pkg_miss $f"
        done
        [ -z "$pkg_miss" ] || pkg_bad="P5_PKG names a directory with no readable$pkg_miss"
    fi
    if [ -z "$pkg_bad" ]; then
        ( cd "$P5_PKG" && sha256sum -c MANIFEST.sha256 ) >/dev/null 2>&1 \
            || pkg_bad="P5_PKG's MANIFEST.sha256 does not verify -- not a package a box would accept"
    fi
    if [ -n "$pkg_bad" ]; then
        echo "FAIL  PKG-0  $pkg_bad: '$P5_PKG'"
        echo "  Build one:  PKG=\$(bash scripts/build-p5-package.sh)  then pass  P5_PKG=\"\$PKG\"."
        echo "  This run does NOT fall back to the synthetic package. A battery that says"
        echo "  'passed' over a package nobody built has measured nothing."
        echo
        echo "p5-skeleton: 0 passed, 1 failed -- ABORTED before the first bar"
        exit 2
    fi
fi

# PKG_SRC1 -- a payload src the package in play actually carries. The bars that
# INJECT a filemap row are testing the DEST, never the src, so pointing the
# injected row at a file that is already in the package keeps one bar in both
# modes instead of forking each of them into two.
if [ "$PKG_MODE" = real ]; then
    PKG_SRC1=$(grep -v '^#' "$P5_PKG/payload/filemap" | cut -d'|' -f3 | grep -v '^$' | head -1)
    [ -n "$PKG_SRC1" ] || { echo "FAIL  PKG-0  P5_PKG's payload/filemap declares no rows: '$P5_PKG'"; echo; echo "p5-skeleton: 0 passed, 1 failed -- ABORTED before the first bar"; exit 2; }
else
    PKG_SRC1=p5-datapath.bin
fi

# pkg_dests PKGDIR ROLE -> the production destination of every filemap row that
# applies to ROLE, one per line. Used instead of a hardcoded list so the bars
# that assert "everything the package declares is on the tree" follow whichever
# filemap is actually in play.
pkg_dests() {
    grep -v '^#' "$1/payload/filemap" | while IFS='|' read -r _m _r _s _d; do
        [ -n "${_d:-}" ] || continue
        { [ "$_r" = both ] || [ "$_r" = "$2" ]; } && echo "$_d"
    done
}

# skipbar ID REASON -- a bar whose FIXTURE cannot exist in this mode. It is
# printed and recorded, never counted and never silently dropped: the ledger
# carries only PASS/FAIL so the SC-1 self-check stays exact, and the summary
# below names every skipped bar with its reason.
skips=0
skipbar() { skips=$((skips + 1)); echo "SKIP  $1  $2"; echo "  SKIP  $1  $2" >> "$TMPBASE/skipped"; }
: > "$TMPBASE/skipped"

# PKG-1 (real mode only): the package HANDED to this run is complete -- every
# file under payload/ is pinned by its own MANIFEST. `sha256sum -c` above
# cannot see this: dropping a line from a manifest makes it check FEWER files
# and still exit 0, which is the quiet half of the integrity problem and the
# reason p5-install:179-182 walks the payload separately. The ANCHOR shape is
# the installer's (" " or " *" before the path, end of line after it) so the two
# agree about what "pinned" means.
#
# The path itself is NOT the installer's shape, deliberately. p5-install:179
# splices the relative path straight into the BRE, so a `.` in a filename is a
# wildcard and `payload/deploy/p5/lib/xctl-dag.sh` would count itself pinned by a
# manifest line naming `xctl-dagXsh`. Here every BRE metacharacter is escaped
# first, which can only make this bar STRICTER than the installer -- the safe
# direction: it can raise a file the installer would have accepted, never pass
# one the installer would have rejected. p5/bin/p5-install is not U118's to
# edit; the same defect in it is recorded on the U118 row instead.
if [ "$PKG_MODE" = real ]; then
    ( cd "$P5_PKG" && find payload -type f | LC_ALL=C sort | while read -r rel; do
        rel_re=$(printf '%s\n' "$rel" | sed 's/[][\.*^$]/\\&/g')
        grep -q " \*\{0,1\}${rel_re}\$" MANIFEST.sha256 2>/dev/null || echo "$rel"
      done ) > "$TMPBASE/pkg1.unpinned"
    pkg1_n=$(grep -c . "$TMPBASE/pkg1.unpinned")
    pkg1_t=$(cd "$P5_PKG" && find payload -type f | wc -l)
    [ "$pkg1_n" = 0 ] || sed 's/^/  NOT PINNED by the package MANIFEST: /' "$TMPBASE/pkg1.unpinned"
    chk "$(yn "$([ "$pkg1_n" = 0 ] && [ "$pkg1_t" -gt 0 ]; echo $?)")" \
        "PKG-1" "the built package handed to this run pins all $pkg1_t of its payload file(s) -- $pkg1_n unpinned"
fi

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
#
# UNDER P5_PKG the fabrication is replaced by a COPY of the built package, and
# a copy is not a convenience: bars below tamper with payload files, append
# filemap rows and mutate PROVENANCE. Doing that to $P5_PKG itself would make
# every later bar depend on the order this file happens to run in, and would
# hand the caller back a broken package. The ROLE argument is ignored there --
# a built package carries client AND server rows in one filemap (that is what
# makes one package serve both boxes) and p5-install filters them at install
# time, which is the behaviour under test.
mkpkg() {
    _pd="$1"; _prole="${2:-client}"
    if [ "$PKG_MODE" = real ]; then
        rm -rf "$_pd"; mkdir -p "$_pd"
        cp -Rp "$P5_PKG/." "$_pd/"
        # Re-pin ONLY when a bar actually injected rows. An unconditional
        # remanifest would REPAIR the package on the way in: a MANIFEST that
        # had lost a line -- the corrupt-package case the integrity bars exist
        # for, and this row's own seeded A/B -- would be silently rebuilt by the
        # harness and every bar would stay green over it.
        cat > "$TMPBASE/inject"
        if [ -s "$TMPBASE/inject" ]; then
            cat "$TMPBASE/inject" >> "$_pd/payload/filemap"
            remanifest "$_pd"
        fi
        return 0
    fi
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
# remanifest DIR -- re-pin the package after a bar has changed it.
#
# The two modes pin DIFFERENT SETS and that is deliberate, not an oversight.
# mkpkg's synthetic manifest covers payload/ only, and IN-8 depends on it:
# PROVENANCE is unpinned there, so a mutated PROVENANCE must be refused by the
# provenance check rather than by the manifest. build-p5-package.sh pins the
# WHOLE package except the manifest itself (:224-231) -- bin/, lib/, contract/
# and PROVENANCE are the files that get copied onto a box with no console.
# Re-pinning only payload/ in real mode would quietly DROP those pins for every
# bar that touches the filemap, which is a weakened package produced by the
# harness. So real mode mirrors the builder exactly.
remanifest() {
    if [ "$PKG_MODE" = real ]; then
        ( cd "$1" && find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' \
            | LC_ALL=C sort > "$TMPBASE/mlist" )
        ( cd "$1" && xargs sha256sum < "$TMPBASE/mlist" > MANIFEST.sha256 )
    else
        ( cd "$1" && find payload -type f | sort | xargs sha256sum > MANIFEST.sha256 )
    fi
}

# U188: PATH="$RMSHIM:$PATH" on both. Every removal bar below therefore runs
# with an `rm` that records its argv and refuses a recursive form, and NR-2
# reads that ledger. Only `rm` is shimmed, so nothing else about the run
# changes. Bars that invoke $BIN/p5-uninstall directly (RCV-1's kill matrix and
# the EXS-* mutants) are NOT shimmed -- NR-2 says so rather than implying
# coverage it does not have.
inst() {  # inst ROOT PKG ROLE [extra args...]
    _r="$1"; _p="$2"; _ro="$3"; shift 3
    P5_ROOT="$_r" PATH="$RMSHIM:$PATH" sh "$BIN/p5-install" --package "$_p" --role "$_ro" "$@" >"$TMPBASE/out" 2>"$TMPBASE/err"
}
unin() {  # unin ROOT [args...]
    _r="$1"; shift
    P5_ROOT="$_r" PATH="$RMSHIM:$PATH" sh "$BIN/p5-uninstall" "$@" >"$TMPBASE/uout" 2>"$TMPBASE/uerr"
}

# IN-1: no arguments -> usage
P5_ROOT="$TMPBASE/r1" sh "$BIN/p5-install" >/dev/null 2>&1; rc=$?
chk "$(yn "$([ "$rc" = 2 ]; echo $?)")" "IN-1" "no arguments -> exit 2 (usage), rc=$rc"

# IN-2: package dir absent -> precondition
inst "$TMPBASE/r2" "$TMPBASE/nope" client; rc=$?
chk "$(yn "$([ "$rc" = 5 ]; echo $?)")" "IN-2" "missing package -> exit 5 (precondition), rc=$rc"

# IN-3: a payload file changed after the manifest was made -> integrity.
P=$TMPBASE/pkg3; mkpkg "$P" </dev/null
printf 'tampered\n' > "$P/payload/$PKG_SRC1"
inst "$TMPBASE/r3" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 3 ]; echo $?)")" "IN-3" "payload tampered after manifest -> exit 3 (integrity), rc=$rc"

# IN-4: a payload file that the manifest does not pin -> integrity.
P=$TMPBASE/pkg4; mkpkg "$P" </dev/null
printf 'stowaway\n' > "$P/payload/unpinned.bin"
inst "$TMPBASE/r4" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 3 ]; echo $?)")" "IN-4" "unpinned payload file -> exit 3 (integrity), rc=$rc"

# IN-5: a destination outside the P5 namespace -> contract violation.
P=$TMPBASE/pkg5; mkpkg "$P" <<EOF
755|client|$PKG_SRC1|/usr/sbin/whatever
EOF
remanifest "$P"
inst "$TMPBASE/r5" "$P" client; rc=$?
chk "$(yn "$([ "$rc" = 4 ]; echo $?)")" "IN-5" "destination outside the namespace -> exit 4 (contract), rc=$rc"

# IN-6: THE historical defect, as a bar. The deploy runbook seeded
# /etc/bond/agg_w with an invented 20000,15000 and silently defeated U6
# (removed in 52a76d3). A package that tries it now is refused by name.
P6=$TMPBASE/pkg6; mkpkg "$P6" <<EOF
644|client|$PKG_SRC1|/etc/bond/agg_w
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
644|client|$PKG_SRC1|$dest
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
PS=$TMPBASE/pkgseed; mkpkg "$PS" <<EOF
644|client|$PKG_SRC1|/etc/p5/sources
EOF
remanifest "$PS"
inst "$TMPBASE/rseed" "$PS" client; rc=$?
grep -q 'NOT DECLARED' "$TMPBASE/err" && named=0 || named=1
chk "$(yn "$([ "$rc" = 4 ] && [ "$named" = 0 ]; echo $?)")" "IN-16" "a filemap that seeds a fact into /etc/p5 -> exit 4: the installer cannot write configuration it did not measure (rc=$rc)"

# IN-7: nothing declared for this role -> an empty install is not a success.
if [ "$PKG_MODE" = real ]; then
    skipbar "IN-7" "its fixture is a CLIENT-ONLY filemap. build-p5-package.sh copies p5/payload/filemap verbatim and that file declares server rows, so a package with nothing for role=server cannot be built -- faking one by deleting rows from the copy would be testing mkpkg again. Covered in synthetic mode."
else
P=$TMPBASE/pkg7; mkpkg "$P" </dev/null
inst "$TMPBASE/r7" "$P" server; rc=$?
chk "$(yn "$([ "$rc" = 5 ]; echo $?)")" "IN-7" "a client-only filemap installed with --role server -> exit 5, not a silent success, rc=$rc"
fi

# IN-8: PROVENANCE is VALIDATED, not merely grepped. Round 1 carried it through
# with a bare grep and no check that anything matched, so a garbage PROVENANCE
# produced exit 0 and a stamp carrying none of the fields it exists for. An
# unvalidated stamp is worse than none: it looks authoritative.
prov_bad=0; prov_n=0
for mutate in 'P5_GIT_COMMIT=deadbeef' 'P5_GIT_DIRTY=maybe' 'P5_PRODUCT=notp5' \
              'P5_BUILT_UTC=yesterday' 'P5_VERSION=' 'DELETE:P5_GIT_COMMIT' ; do
    prov_n=$((prov_n + 1))
    PP=$TMPBASE/pkgprov; rm -rf "$PP"; mkpkg "$PP" </dev/null
    # Mutate the package's OWN provenance, not the fixture's: under P5_PKG the
    # two are different files, and remanifest afterwards so the refusal has to
    # come from the provenance check rather than from a manifest the mutation
    # happened to break (the built manifest pins PROVENANCE; mkpkg's does not).
    case "$mutate" in
        DELETE:*) grep -v "^${mutate#DELETE:}=" "$PP/PROVENANCE" > "$TMPBASE/prov.mut" ;;
        *) k=${mutate%%=*}; grep -v "^$k=" "$PP/PROVENANCE" > "$TMPBASE/prov.mut"; echo "$mutate" >> "$TMPBASE/prov.mut" ;;
    esac
    cp "$TMPBASE/prov.mut" "$PP/PROVENANCE"; remanifest "$PP"
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

# IN-9b: everything the contract says an install places is present. The payload
# half is read off the PACKAGE'S OWN FILEMAP rather than hardcoded: the three
# names that used to be listed here are mkpkg's three, so on a real package the
# bar would have asserted the presence of files that package never declared and
# missed every file it did.
in9b=0; in9b_n=0
in9b_d=$(pkg_dests "$P9" client | grep -c .)
for f in $(pkg_dests "$P9" client) \
         /usr/lib/p5/stamp /usr/lib/p5/installed.files /usr/lib/p5/installed.dirs \
         /usr/lib/p5/p5-common.sh /usr/lib/p5/contract-namespace \
         /usr/lib/p5/contract-foreign /usr/lib/p5/contract-paths \
         /usr/sbin/p5-uninstall /usr/sbin/p5-version /usr/sbin/p5-deadman ; do
    in9b_n=$((in9b_n + 1))
    [ -f "$R9$f" ] || { echo "  MISSING after install: $f"; in9b=$((in9b + 1)); }
done
chk "$(yn "$([ "$in9b" = 0 ] && [ "$in9b_d" -gt 0 ]; echo $?)")" "IN-9b" "all $in9b_d payload destination(s) this package declares for role=client, plus stamp, both records, the library, all three contract copies and all three on-box entry points, are present ($in9b_n paths checked)"

# IN-9c: NOTHING WAS ENABLED OR STARTED -- and this bar can now FAIL. Round 1's
# version tested for the absence of /etc/init.d, /etc/rc.d and /etc/hotplug.d
# on a root where the package shipped ONE file into /usr/sbin, so none of those
# directories could have existed whatever the installer did. The package now
# ships an init script and a hotplug hook, so /etc/init.d and
# /etc/hotplug.d/iface DO exist; the live assertion is the one that matters --
# no /etc/rc.d, i.e. nothing was enabled -- and the bar also asserts the two
# directories that prove it is looking at a tree where they could have been.
#
# The non-vacuity half is read off the package's own filemap rather than naming
# mkpkg's two directories: a built package ships an init script but no hotplug
# hook (p5/payload/filemap:25-30), so a hardcoded /etc/hotplug.d/iface would
# have reported the REAL package as a vacuous fixture. Every parent directory
# the package's client rows require must exist -- which is a stronger version
# of the same claim, and it follows whichever filemap is in play.
ic_pre=0; ic_pren=0
for d in $(pkg_dests "$P9" client | sed 's:/[^/]*$::' | sort -u); do
    ic_pren=$((ic_pren + 1))
    [ -d "$R9$d" ] || { echo "  $d does not exist after the install -- this bar would be vacuous there"; ic_pre=1; }
done
[ "$ic_pren" -gt 0 ] || { echo "  the package declares no client destination at all"; ic_pre=1; }
ic_bad=0
[ -e "$R9/etc/rc.d" ] && { echo "  install created /etc/rc.d: something was ENABLED"; ic_bad=1; }
n_links=$(find "$R9" -type l 2>/dev/null | wc -l)
[ "$n_links" = 0 ] || { echo "  install created $n_links symlink(s); E0 creates none"; ic_bad=1; }
chk "$(yn "$([ "$ic_bad" = 0 ] && [ "$ic_pre" = 0 ]; echo $?)")" "IN-9c" "install enabled and started nothing: no /etc/rc.d and 0 symlinks, on a tree where all $ic_pren directory(ies) this package's own filemap requires DO exist so the bar is live"

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
#
# The shared half is derived from the package in play, minus P5's own three:
# the built package puts /usr/lib/p5/dag under an OWNED directory, so a fixed
# list of "shared" names is wrong in both directions on a real package.
sd_bad=0; sd_n=0; sd_list=
for d in $(pkg_dests "$P9" client | sed 's:/[^/]*$::' | sort -u); do
    case "$d" in /usr/lib/p5|/etc/p5|/etc/p5/deadman) continue ;; esac
    sd_n=$((sd_n + 1)); sd_list="$sd_list $d"
    [ -d "$RID$d" ] || { echo "  a shared system directory was REMOVED: $d"; sd_bad=$((sd_bad + 1)); }
done
gone=0
for d in /usr/lib/p5 /etc/p5 /etc/p5/deadman; do
    [ -d "$RID$d" ] && { echo "  an owned directory was NOT removed: $d"; gone=$((gone + 1)); }
done
chk "$(yn "$([ "$sd_bad" = 0 ] && [ "$gone" = 0 ] && [ "$sd_n" -gt 0 ]; echo $?)")" \
    "RM-4" "removal rmdir-ed exactly the 3 directories P5 owns and left the $sd_n shared system directory(ies) this package writes into standing:$sd_list"

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

# RM-9: THE DIRECTORY THAT USED TO BE THE `rm -rf` (U188). /var/run/p5 is the
# one declared `dir runtime` row -- P5's own tmpfs root -- and until this unit it
# was cleared by the product's single recursive removal, behind four gates. It is
# now WALKED: every regular file becomes its own MEMBER action re-gated at the
# point of use, every subdirectory is descended and rmdir-ed DEEPEST-FIRST, and
# anything that is neither is REPORTed and LEFT. Three claims, one fixture:
#   (a) the plan carries zero RMTREE, a MEMBER per file including the NESTED one
#       a shell glob cannot see, an RMDIR for the subdirectory and one for the
#       root, and the subdirectory's RMDIR comes BEFORE the root's -- read off
#       the plan by line number, not argued for in this comment;
#   (b) it still clears a POPULATED tree, which is the whole job the rm -rf did;
#   (c) a FIFO in it is named, left, and takes the exit code with it -- the
#       report an `rm -rf` could never have produced, because it would have
#       taken the fifo without a word.
RZ=$TMPBASE/rz; inst "$RZ" "$P9" client
mkdir -p "$RZ/var/run/p5/sub"
printf 'x\n' > "$RZ/var/run/p5/sub/state"
printf 'y\n' > "$RZ/var/run/p5/top"
unin "$RZ" --remove --dry-run --role client
a=0
grep -q '^MEMBER|/var/run/p5/top$' "$TMPBASE/uout"       || { a=1; echo "  the top-level file is not planned as a MEMBER"; }
grep -q '^MEMBER|/var/run/p5/sub/state$' "$TMPBASE/uout" || { a=1; echo "  the NESTED file is not planned as a MEMBER"; }
grep -q '^RMDIR|/var/run/p5/sub$' "$TMPBASE/uout"        || { a=1; echo "  the subdirectory is not planned as an RMDIR"; }
grep -q '^RMDIR|/var/run/p5$' "$TMPBASE/uout"            || { a=1; echo "  the runtime root is not planned as an RMDIR"; }
n_rmtree=$(grep -c '^RMTREE|' "$TMPBASE/uout" 2>/dev/null); [ -n "$n_rmtree" ] || n_rmtree=0
[ "$n_rmtree" = 0 ] || { a=1; echo "  the plan still carries $n_rmtree RMTREE action(s)"; }
ln_sub=$(grep -n '^RMDIR|/var/run/p5/sub$' "$TMPBASE/uout" | head -1 | cut -d: -f1)
ln_root=$(grep -n '^RMDIR|/var/run/p5$' "$TMPBASE/uout" | head -1 | cut -d: -f1)
if [ -n "$ln_sub" ] && [ -n "$ln_root" ]; then
    [ "$ln_sub" -lt "$ln_root" ] || { a=1; echo "  the rmdirs are not deepest-first (sub at $ln_sub, root at $ln_root)"; }
else
    a=1
fi
unin "$RZ" --remove --role client; rc=$?
[ -e "$RZ/var/run/p5" ] && { a=1; echo "  /var/run/p5 survived the walk"; }
[ "$rc" = 0 ] || { a=1; echo "  the removal did not exit 0 (rc=$rc)"; }
# (c) the same walk with something in it that P5 did not place.
RZF=$TMPBASE/rzf; inst "$RZF" "$P9" client
mkdir -p "$RZF/var/run/p5"
printf 'x\n' > "$RZF/var/run/p5/state"
mkfifo "$RZF/var/run/p5/pipe" 2>/dev/null || { a=1; echo "  could not create the fifo fixture (mkfifo missing?)"; }
unin "$RZF" --remove --role client; frc=$?
[ -p "$RZF/var/run/p5/pipe" ] || { a=1; echo "  the FIFO was removed"; }
[ -d "$RZF/var/run/p5" ]      || { a=1; echo "  the directory holding the fifo was removed anyway"; }
[ -e "$RZF/var/run/p5/state" ] && { a=1; echo "  the declared member was NOT removed"; }
grep -q 'LEFT: /var/run/p5/pipe' "$TMPBASE/uerr" || { a=1; echo "  the fifo was not named in a LEFT line"; }
grep -q 'NOT EMPTY, left in place: /var/run/p5' "$TMPBASE/uerr" || { a=1; echo "  the non-empty directory was not reported"; }
[ "$frc" = 1 ] || { a=1; echo "  a removal that left a fifo behind exited $frc, not 1"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "RM-9" "the declared runtime directory is emptied MEMBER BY MEMBER and rmdir-ed deepest-first with $n_rmtree RMTREE in the plan: a populated /var/run/p5 including a nested subdirectory is cleared (rc=$rc), and a FIFO planted in it is named in a LEFT line, left where it is, keeps its directory standing and takes the exit code with it (rc=$frc)"

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
sed 's|if ! p5_exec_ok "$RROLE" "$svcf"; then|if false; then|' "$BIN/p5-uninstall" > "$EXM/bin/p5-uninstall"
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
sed -e 's|if ! p5_exec_ok "$RROLE" "$svcf"; then|if false; then|' \
    -e 's|if ! p5_exec_ok "$RROLE" "/etc/init.d/$arg"; then|if false; then|' \
    "$BIN/p5-uninstall" > "$EXM2/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$EXM2/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: neither gate call site was found"; }
grep -q 'p5_exec_ok "$RROLE" "/etc/init.d/$arg"' "$EXM2/bin/p5-uninstall" && { a=1; echo "  the executor gate survived the mutation"; }
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

# ===========================================================================
# U153 -- THE FILE THAT IS EXECUTED, NOT JUST ITS NAME.
# EXG-* above closed the UNDECLARED-name door. U146's own adjudicator found
# the same class through the DECLARED-name door, and these bars are it:
# p5_removable judges the NAME and resolves only its PARENT DIRECTORY, so
# /etc/init.d/p5-datapath -> ../../tmp/evil is `-x` (which FOLLOWS the link),
# is declared by contract/paths for role=client, and the TARGET runs as root
# twice. The fixture writes a sentinel when it runs, so "did not execute" is a
# measured absence and not an inference from an exit code.
# ===========================================================================
mkexeclink() {   # mkexeclink ROOT TARGET -- an installed root whose DECLARED
                 # /etc/init.d/p5-datapath is a SYMLINK to TARGET, plus its flag
    _xl_r="$1"; _xl_t="$2"; rm -rf "$_xl_r"
    inst "$_xl_r" "$P9" client
    mkdir -p "$_xl_r/tmp" "$_xl_r/etc/rc.d"
    cat > "$_xl_r/tmp/evil" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$_xl_r/evil-ran"
exit 0
EOF
    chmod 755 "$_xl_r/tmp/evil"
    rm -f "$_xl_r/etc/init.d/p5-datapath"
    ln -s "$_xl_t" "$_xl_r/etc/init.d/p5-datapath"
    printf 'flag\n' > "$_xl_r/etc/rc.d/S94p5-datapath"
}

# EXS-1: A RELATIVE SYMLINK AT THE DECLARED NAME. The finding, seeded exactly
# as the adjudicator described it.
XS1=$TMPBASE/rxs1; mkexeclink "$XS1" "../../tmp/evil"
a=0
unin "$XS1" --remove --role client; rc=$?
[ -e "$XS1/evil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT: $(tr '\n' ' ' < "$XS1/evil-ran")"; }
[ "$rc" = 4 ] || { a=1; echo "  exit was $rc, not 4 (contract) -- the refusal did not reach the exit status"; }
grep -q '/etc/init.d/p5-datapath' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q '/tmp/evil' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the RESOLVED target -- an operator cannot act on it"; }
grep -q 'EXECUTE' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not say the file would have been EXECUTED"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-1" "a DECLARED /etc/init.d/p5-datapath that is a RELATIVE symlink to ../../tmp/evil: the target is NOT executed (no sentinel), --remove exits $rc, and the refusal names both the declared path and the /tmp/evil it resolves to"

# EXS-2: THE ABSOLUTE FORM. Closing only the relative spelling would leave the
# easier attack open. The target is absolute but still lands inside the
# fixture, so nothing is created in the machine's own /tmp.
XS2=$TMPBASE/rxs2; mkexeclink "$XS2" "$TMPBASE/rxs2/tmp/evil"
a=0
unin "$XS2" --remove --role client; rc=$?
[ -e "$XS2/evil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT: $(tr '\n' ' ' < "$XS2/evil-ran")"; }
[ "$rc" = 4 ] || { a=1; echo "  exit was $rc, not 4 (contract)"; }
grep -q '/etc/init.d/p5-datapath' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q '/tmp/evil' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the RESOLVED target"; }
grep -q 'EXECUTE' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not say the file would have been EXECUTED"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-2" "the same closure for an ABSOLUTE symlink target: not executed, exit $rc, and the refusal names the resolved /tmp/evil -- the fix is on the resolved path, not on the spelling"

# EXS-3: DEFENCE IN DEPTH. The plan is a file on disk between planner and
# executor, so a symlink planted AFTER the plan was written must still be
# caught. Neutralise the PLANNER's gate only and the executor must refuse.
XSM="$TMPBASE/exsmut"
mkdir -p "$XSM/bin" "$XSM/lib" "$XSM/contract"
cp "$LIB/p5-common.sh" "$XSM/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$XSM/contract/"
sed 's|if ! p5_exec_ok "$RROLE" "$svcf"; then|if false; then|' "$BIN/p5-uninstall" > "$XSM/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$XSM/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the planner's execute gate was not found"; }
XS3=$TMPBASE/rxs3; mkexeclink "$XS3" "../../tmp/evil"
P5_ROOT="$XS3" sh "$XSM/bin/p5-uninstall" --remove --role client >"$TMPBASE/xs3.out" 2>"$TMPBASE/xs3.err"; prc=$?
[ -e "$XS3/evil-ran" ] && { a=1; echo "  the target RAN with only the planner gate removed"; }
grep -q '^SVCDOWN|p5-datapath$' "$TMPBASE/xs3.out" || { a=1; echo "  the mutant planner did not emit the action, so this bar is vacuous"; }
grep -q 'REFUSED SVCDOWN on p5-datapath' "$TMPBASE/xs3.err" || { a=1; echo "  the executor did not refuse by name at the point of use"; }
[ "$prc" = 4 ] || { a=1; echo "  the run exited $prc, not 4 (contract), after refusing to execute"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-3" "with the PLANNER's execute gate removed the plan does emit SVCDOWN|p5-datapath, and the EXECUTOR still resolves the symlink and refuses by name (exit $prc, sentinel absent): a link planted after the plan was written is caught"

# EXS-4: AND IT DOES NOT WEDGE THE BOX. A DANGLING symlink at the declared name
# is EXG-4's stale-flag state wearing a link: `-x` is false, so no gate is
# asked, nothing is executed, and the link and its flag are removed at exit 0.
# On a box with no console a blanket refusal here is the worst outcome there is.
XS4=$TMPBASE/rxs4; mkexeclink "$XS4" "../../tmp/nothing-behind-this"
a=0
[ -x "$XS4/etc/init.d/p5-datapath" ] && { a=1; echo "  the fixture's link is NOT dangling, so this bar is not the anti-wedge case"; }
unin "$XS4" --remove --role client; rc=$?
[ "$rc" = 0 ] || { a=1; echo "  a DANGLING symlink at a declared name refused the removal (exit $rc) -- the gate WEDGED the box"; }
grep -q '^exec|' "$TMPBASE/uerr" && { a=1; echo "  an execution refusal was raised for a link with nothing behind it"; }
[ -e "$XS4/etc/rc.d/S94p5-datapath" ] && { a=1; echo "  the rc.d flag survived"; }
[ -L "$XS4/etc/init.d/p5-datapath" ] && { a=1; echo "  the dangling symlink survived"; }
[ -e "$XS4/usr/sbin/p5-datapath" ] && { a=1; echo "  P5 is still installed after a removal that reported success"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-4" "a DANGLING symlink at the declared /etc/init.d/p5-datapath still removes cleanly: exit $rc, no execution refusal, the link and its rc.d flag are gone and P5 is gone -- the resolver is only ever reached when there is a file to execute"

# MU-EXS: THE MUTATION. Both execute gates put back to the U146 shape
# (p5_removable on the NAME) in a copy of the shipped uninstaller, and the
# EXS-1 fixture EXECUTES the symlink target as root. Without this, "EXS-1
# passes" is indistinguishable from "EXS-1 cannot fail". The declared-and-REAL
# fixture and the DANGLING fixture are re-run against the SAME mutant and must
# be unchanged, so the bar also pins that the gate is what changed and that the
# fix wedged nothing that worked before it.
XSM2="$TMPBASE/exsmut2"
mkdir -p "$XSM2/bin" "$XSM2/lib" "$XSM2/contract"
cp "$LIB/p5-common.sh" "$XSM2/lib/p5-common.sh"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$XSM2/contract/"
sed -e 's|if ! p5_exec_ok "$RROLE" "$svcf"; then|if ! p5_removable "$RROLE" "$svcf" file; then|' \
    -e 's|if ! p5_exec_ok "$RROLE" "/etc/init.d/$arg"; then|if ! p5_removable "$RROLE" "/etc/init.d/$arg" file; then|' \
    "$BIN/p5-uninstall" > "$XSM2/bin/p5-uninstall"
a=0
cmp -s "$BIN/p5-uninstall" "$XSM2/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: neither execute gate call site was found"; }
grep -q 'p5_exec_ok "$RROLE"' "$XSM2/bin/p5-uninstall" && { a=1; echo "  an execute gate survived the mutation"; }
XSR=$TMPBASE/rxsm; mkexeclink "$XSR" "../../tmp/evil"
P5_ROOT="$XSR" sh "$XSM2/bin/p5-uninstall" --remove --role client >"$TMPBASE/xsm.out" 2>"$TMPBASE/xsm.err"; mrc=$?
grep -q '^RAN stop$' "$XSR/evil-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the symlink target's stop -- the seed did not bite"; }
grep -q '^RAN disable$' "$XSR/evil-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the symlink target's disable"; }
XSD=$TMPBASE/rxsd; inst "$XSD" "$P9" client
cat > "$XSD/etc/init.d/p5-datapath" <<EOF
#!/bin/sh
echo "RAN \$1" >> "$XSD/declared-ran"
exit 0
EOF
chmod 755 "$XSD/etc/init.d/p5-datapath"
mkdir -p "$XSD/etc/rc.d"; printf 'flag\n' > "$XSD/etc/rc.d/S94p5-datapath"
P5_ROOT="$XSD" sh "$XSM2/bin/p5-uninstall" --remove --role client >/dev/null 2>&1; drc=$?
grep -q '^RAN stop$' "$XSD/declared-ran" 2>/dev/null || { a=1; echo "  the DECLARED real file was not stopped by the mutant, so EXS-1 is not measuring the gate"; }
[ "$drc" = 0 ] || { a=1; echo "  the mutant failed the declared removal (rc=$drc)"; }
XSW=$TMPBASE/rxsw; mkexeclink "$XSW" "../../tmp/nothing-behind-this"
P5_ROOT="$XSW" sh "$XSM2/bin/p5-uninstall" --remove --role client >/dev/null 2>&1; wrc=$?
[ "$wrc" = 0 ] || { a=1; echo "  the DANGLING fixture did not exit 0 before the fix either (rc=$wrc) -- EXS-4 is not an anti-wedge A/B"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-EXS" "MUTATION: with BOTH execute gates put back to the NAME-only U146 shape, the same fixture EXECUTES the symlink target as root -- stop and disable both recorded (exit $mrc) -- while the declared-and-REAL removal still exits $drc and the DANGLING fixture still exits $wrc. EXS-1/EXS-2/EXS-3 are bars that can fail, and EXS-4 removed cleanly both before and after the fix"


# EXS-7 / MU-EXS-S9 (U153 fix round): S9, NOT A REGULAR FILE. A DIRECTORY is
# `-x` -- that is what "searchable" means -- so a directory, fifo, socket or
# device at a declared init-script name reaches the execute gate with `-x` true
# and no symlink to resolve. exec(2) will not run anything but a regular file,
# so this state cannot be turned into someone else's code; what it CAN do
# without the guard is hand the path to the kernel as root, take the silent
# failure behind `2>/dev/null`, and then REPORT "stopped and disabled" for a
# service that was never stopped -- a removal that lies about the box's state,
# on a box with no console. p5_exec_ok / p5_old_exec_ok refuse it by name
# instead. There are TWO such blocks and they are on different code paths, so
# they get one fixture each: EXS-7 / MU-EXS-S9 here cover ONLY the P5 half
# (`p5_exec_ok`, p5/lib/p5-common.sh:821-824, reached by --remove); the old
# half (`p5_old_exec_ok`, :844-847, reachable only under --purge) is covered by
# EXS-10 / MU-EXS-S9-OLD in the old-stack section.
mkexecdir() {   # mkexecdir ROOT -- an installed root whose DECLARED
                # /etc/init.d/p5-datapath is a DIRECTORY, plus its rc.d flag
    _xd_r="$1"; rm -rf "$_xd_r"
    inst "$_xd_r" "$P9" client
    rm -f "$_xd_r/etc/init.d/p5-datapath"
    mkdir -p "$_xd_r/etc/init.d/p5-datapath" "$_xd_r/etc/rc.d"
    chmod 755 "$_xd_r/etc/init.d/p5-datapath"
    printf 'flag\n' > "$_xd_r/etc/rc.d/S94p5-datapath"
}

XS7=$TMPBASE/rxs7; mkexecdir "$XS7"
a=0
[ -x "$XS7/etc/init.d/p5-datapath" ] || { a=1; echo "  the fixture is not -x, so this bar is not the S9 case"; }
[ -f "$XS7/etc/init.d/p5-datapath" ] && { a=1; echo "  the fixture IS a regular file, so this bar is not the S9 case"; }
unin "$XS7" --remove --role client; rc=$?
[ "$rc" = 4 ] || { a=1; echo "  exit was $rc, not 4 (contract) -- a non-regular file at a declared executed name was not refused"; }
grep -q 'NOT A REGULAR FILE' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not say the path is not a regular file"; }
grep -q '/etc/init.d/p5-datapath' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q 'stopped and disabled' "$TMPBASE/uout" "$TMPBASE/uerr" && { a=1; echo "  the run REPORTED stopping a service it cannot have stopped"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-7" "S9: a DIRECTORY at the declared /etc/init.d/p5-datapath is -x and NOT -f -- the execute gate refuses it by name (exit $rc, 'NOT A REGULAR FILE') instead of handing it to the kernel as root and then reporting a stop that never happened"

# MU-EXS-S9: and the P5-HALF guard is what does that. ONE block is removed from
# a COPY of the shipped library -- `p5_exec_ok`'s `[ ! -f "${P5_ROOT}${_p5x_path}" ]`
# at p5/lib/p5-common.sh:821-824, and NOT the call sites, so this is not MU-EXS
# wearing a different fixture -- and the same directory reaches the execution.
# The earlier cut of this bar seded BOTH blocks. That made it a bar on the pair,
# which is exactly how the old half's block (:844-847) stayed uncovered while
# the record read as if it were covered: a mutation that removes two guards is
# red as soon as EITHER fixture bites, and the only fixture here is the P5 one.
# So the old-half block is asserted to SURVIVE this seed; its own bars are
# EXS-10 / MU-EXS-S9-OLD, down in the old-stack section.
XSM3="$TMPBASE/exsmut3"
rm -rf "$XSM3"; mkdir -p "$XSM3/bin" "$XSM3/lib" "$XSM3/contract"
cp "$BIN/p5-uninstall" "$XSM3/bin/p5-uninstall"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$XSM3/contract/"
sed -e 's|if \[ ! -f "${P5_ROOT}${_p5x_path}" ]; then|if false; then|' \
    "$LIB/p5-common.sh" > "$XSM3/lib/p5-common.sh"
a=0
cmp -s "$LIB/p5-common.sh" "$XSM3/lib/p5-common.sh" && { a=1; echo "  MUTATION DID NOT APPLY: the P5-half not-a-regular-file guard was not found"; }
grep -q '! -f "${P5_ROOT}${_p5x_path}"' "$XSM3/lib/p5-common.sh" && { a=1; echo "  the P5-half guard survived the mutation"; }
# ISOLATION, stated as a DIFF against the shipped file rather than as "the other
# guard is present". Presence would make this bar red whenever somebody seeds
# the OLD half of the shipped tree, which is precisely the confusion this split
# exists to end: what has to be true is that THIS seed touched one line and that
# the line is the P5 half's.
s9_rm=$(diff "$LIB/p5-common.sh" "$XSM3/lib/p5-common.sh" | grep '^<' | sed 's/^< *//')
s9_add=$(diff "$LIB/p5-common.sh" "$XSM3/lib/p5-common.sh" | grep '^>' | sed 's/^> *//')
[ "$s9_rm" = 'if [ ! -f "${P5_ROOT}${_p5x_path}" ]; then' ] || { a=1; echo "  the seed removed something other than exactly the P5-half guard line: [$s9_rm]"; }
[ "$s9_add" = 'if false; then' ] || { a=1; echo "  the seed added something other than exactly 'if false; then': [$s9_add]"; }
XS7M=$TMPBASE/rxs7m; mkexecdir "$XS7M"
P5_ROOT="$XS7M" sh "$XSM3/bin/p5-uninstall" --remove --role client >"$TMPBASE/xs7m.out" 2>"$TMPBASE/xs7m.err"; s9rc=$?
grep -q 'NOT A REGULAR FILE' "$TMPBASE/xs7m.err" && { a=1; echo "  the mutant still refused -- the seed did not bite"; }
grep -q 'stopped and disabled p5-datapath' "$TMPBASE/xs7m.out" || { a=1; echo "  the mutant never reached the execution site, so EXS-7 is not measuring the guard"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-EXS-S9" "MUTATION: with p5_exec_ok's not-a-regular-file guard ALONE removed from the shipped LIBRARY (the old half's block asserted still present), the same directory fixture is handed to the kernel as root and the run reports 'stopped and disabled p5-datapath' (exit $s9rc) with no refusal. EXS-7 is a bar that can fail, and it fails on the P5-half block specifically"
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
# CR-5 (U241): a crash INSIDE the FIRST atomic_write on a FRESH box leaves ONLY the
# staging twin (.p5-incoming.install.inprogress) -- the mv never ran. box_state must
# NAME it, --remove --recover must CLEAR it (sweeping the twin, not just the dest
# name), and a reinstall must then succeed. Regression this guards: DROPINTENT rm'd
# only the dest, so the orphan twin persisted -> box stayed damaged -> permanently
# wedged, unrecoverable on the console-less server.
RCB="$TMPBASE/crb"; rm -rf "$RCB"; mkdir -p "$RCB/usr/lib/p5"
CR5_TWIN=$(sh -c '. "$1/p5-common.sh"; p5_incoming_of "$2"' _ "$LIB" "$RCB/usr/lib/p5/install.inprogress")
printf 'half an intent record' > "$CR5_TWIN"   # crash after cat>, before mv
b=0
P5_ROOT="$RCB" sh "$BIN/p5-version" --state >"$TMPBASE/crb.state" 2>/dev/null
cr5_st=$(grep '^P5_BOX_STATE=' "$TMPBASE/crb.state" | head -1 | sed 's/.*=//')
case "$cr5_st" in clean|incomplete|damaged) : ;; *) b=1 ;; esac   # must name a state
P5_ROOT="$RCB" sh "$BIN/p5-uninstall" --remove --recover --role client >/dev/null 2>&1; cr5_rc=$?
[ "$cr5_rc" = 0 ] || b=1
[ -e "$CR5_TWIN" ] && b=1                        # the twin must be gone
cr5_nf=$(find "$RCB" -type f 2>/dev/null | wc -l); [ "$cr5_nf" = 0 ] || b=1
P5_ROOT="$RCB" TMPDIR="$CRTMP" sh "$BIN/p5-install" --package "$P9" --role client >/dev/null 2>&1; cr5_irc=$?
[ "$cr5_irc" = 0 ] || b=1                        # not wedged
rm -rf "$RCB"
chk "$(yn "$([ "$b" = 0 ]; echo $?)")" \
    "CR-5" "a crash mid-first-atomic-write on a FRESH box (lone .p5-incoming twin) is named, --recover sweeps the twin and clears the box, and reinstall succeeds (state=$cr5_st recover=$cr5_rc reinstall=$cr5_irc) -- the fresh-box brick"

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
hp3_n=$(grep -v '^#' "$P9/payload/filemap" | cut -d'|' -f4 | grep -c .)
cat "$TMPBASE/hp3.out"
chk "$(yn "$([ "$hp3_bad" = 0 ] && [ "$hp3_n" -gt 0 ]; echo $?)")" \
    "HP-3" "every staging path stays in its destination's own directory ($((hp3_n + 6)) checked), so the publishing rename is intra-filesystem and stays atomic"

# HP-4: THE INTERRUPTION. Kill the installer between staging the hotplug hook
# and renaming it -- the one window P5_FAULT_AFTER's counter cannot express --
# and then run netifd's scanner over the directory that was left behind.
#
# HP-4 and MU-HP4 are the two bars P5_PKG cannot carry, and the reason is a
# product decision rather than a harness limit: p5/payload/filemap ships NO
# /etc/hotplug.d/iface row at all -- contract/paths:159 leaves the two-digit
# netifd priority unset on purpose and E5 has not chosen it (filemap:25-30).
# There is therefore no staged hook in a built package to interrupt, and no
# scanner run to observe. Inventing one would mean appending a row and a hook
# file of the harness's own -- which is mkpkg, under a different name.
if [ "$PKG_MODE" = real ]; then
    hp4_why="the built package declares NO /etc/hotplug.d/iface destination (p5/payload/filemap:25-30 withholds it until E5 chooses the netifd priority), so there is no staged hook to interrupt. Covered in synthetic mode; it becomes a real-package bar when the filemap gains the row."
    skipbar "HP-4"    "$hp4_why"
    skipbar "MU-HP4"  "$hp4_why"
else
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
fi

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
# nleft is assigned inside the guarded branch below but interpolated
# UNCONDITIONALLY into the bar text; under `set -u` an unbitten mutation would
# kill the run before its self-check summary instead of printing FAIL MU-RCV.
a=0; nleft=0
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

# DM-62 (U244/U202): the timer limb must follow the DEADLINE, not elapsed real time.
# The clock step is simulated the only way a test without root can: arm for 2s, then move
# the RECORD's deadline out to +5s, which is what a clock stepping BACK by 3s looks like
# from the sleeper's side -- it wakes at its planned moment and the deadline has not
# arrived. A one-shot sleeper wakes once, `check` correctly declines to fire, and nothing
# ever wakes again: the rollback silently never happens. The re-checking sleeper sleeps the
# remaining time again and fires. This exercises the SHIPPED spawn (no --no-timer), because
# the defect was in the spawn and a bar that calls `check` by hand cannot see it.
rm -f "$MARK"
dm arm --after 2 --restore "touch $MARK" --label t62
DM62_REC="$RD/etc/p5/deadman/t62"
dm62_now=$(date -u +%s)
sed "s/^P5_DM_DEADLINE=.*/P5_DM_DEADLINE=$((dm62_now + 5))/" "$DM62_REC" > "$TMPBASE/dm62.rec" \
    && cat "$TMPBASE/dm62.rec" > "$DM62_REC"
dm62_dl=$(sed -n 's/^P5_DM_DEADLINE=//p' "$DM62_REC" | head -1)
sleep 9
dm62_fired=0; [ -f "$MARK" ] && dm62_fired=1
dm confirm --label t62 >/dev/null 2>&1
rm -f "$MARK" "$TMPBASE/dm62.rec"
chk "$(yn "$([ "$dm62_fired" = 1 ]; echo $?)")" \
    "DM-62" "the timer limb still fires when the deadline moves out from under it (deadline pushed to $dm62_dl, fired=$dm62_fired) -- the sleeper re-reads the clock and the record at every wake instead of waking once on elapsed time. A box with no RTC steps its clock at the first NTP sync, inside the deploy window"

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
    "ROLE-1" "a server install places the server payload and no client payload, audits clean, and removes to 0 files (install=$rc remove=$rrc)"
# RENAMED FROM `RO-1` BY U209, and the rename is the point: the adjudicated
# design gives the verb-split family the names RO-1..RO-5, and this ROLE bar had
# the first of them. Two bars answering to one id makes every later grep of a
# ledger return two different claims and lets a green line stand in for a bar
# that never ran. Nothing outside this file names it (`grep -rn RO-1 docs
# scripts orchestration deploy` at ec5f7db hits only the two U209 rows).

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
# PRR2 under P5_PKG needs no injection: a BUILT package already carries client
# and server rows in one filemap, which is the shape this bar was written to
# anticipate ("what E8 will ship"). Appending duplicate server rows would put
# two rows on one destination -- something build-p5-package.sh:132-134 refuses
# outright -- so the bar would be driving a package the builder cannot emit.
if [ "$PKG_MODE" = real ]; then
PRR2=$TMPBASE/pkgrr2; mkpkg "$PRR2" client </dev/null
else
PRR2=$TMPBASE/pkgrr2; mkpkg "$PRR2" client <<EOF
755|server|$PKG_SRC1|/usr/sbin/p5-server
755|server|initd.sh|/etc/init.d/p5-server
EOF
fi

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
# The probe is the package's FIRST client destination, not a hardcoded netifd
# hook: what this bar needs is evidence that the other role's payload actually
# landed, and the hook is only mkpkg's way of providing that.
rr4_probe=$(pkg_dests "$PRR2" client | head -1)
hook=1; [ -n "$rr4_probe" ] && [ -f "$RR4$rr4_probe" ] && hook=0
unin "$RR4" --remove; rrc=$?
nf=$(find "$RR4" -type f 2>/dev/null | wc -l)
chk "$(yn "$([ "$rc" = 0 ] && [ "$hook" = 0 ] && [ "$rrc" = 0 ] && [ "$nf" = 0 ]; echo $?)")" \
    "RR-4" "a two-role package installed with the WRONG --role exits 0 and places that role's payload at $rr4_probe (install=$rc placed=$hook) -- and the bare --remove undoes exactly what the stamp records (rc=$rrc left=$nf)"

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
            dir) mkdir -p "$OR$_p"
                 # U188: a declared old `dir` row is no longer rm -rf'd. It is
                 # emptied MEMBER BY MEMBER, and the member gate is asymmetric
                 # on purpose: under /root -- the operator's own home -- only a
                 # member the derived list ALREADY DECLARES may be unlinked, and
                 # anything else is reported and left standing (that asymmetry
                 # is what RM-12 exists to hold). So planting an undeclared file
                 # in EVERY dir row would make OLD-2 assert the opposite of the
                 # shipped policy. The two package/tmpfs roots keep theirs, and
                 # they are what proves the member sweep actually runs.
                 case "$_p" in
                     /root|/root/*) : ;;
                     *) printf 'old-stack state\n' > "$OR$_p/planted" ;;
                 esac ;;
            svc) mkdir -p "$OR${_p%/*}"; printf '#!/bin/sh\nexit 0\n' > "$OR$_p"
                 printf 'flag\n' > "$OR/etc/rc.d/S50${_p##*/}"
                 printf 'flag\n' > "$OR/etc/rc.d/K50${_p##*/}" ;;
            quarantine) mkdir -p "$OR${_p%/*}"; printf '%s\n' "$AGGW_CANARY" > "$OR$_p" ;;
            *) mkdir -p "$OR${_p%/*}"; printf 'old-stack artifact\n' > "$OR$_p" ;;
        esac
    done < "$OLDROWS"
    # THE REAL BOX'S OWN FLAGS FOR THE OLD SHAPER (U208). The loop above plants
    # a symmetrical S50/K50 pair per service, which is a fixture convention, not
    # a fact about the client. The client carries S97cake-autorate and
    # K4cake-autorate (docs/knowledge/inventory/2026-08-30b-client-flint2-N3.txt
    # :128) -- and K4 is a SINGLE-digit priority, which the two-digit glob this
    # unit widened could not see. Planted here so the widening is measured on the
    # shape the box actually has: without it every flag bar in this battery runs
    # on a fixture whose priorities happen to be two digits, and a gate that only
    # ever sees two digits cannot fail on the flag the switch-on gate must catch.
    printf 'flag\n' > "$OR/etc/rc.d/S97cake-autorate"
    printf 'flag\n' > "$OR/etc/rc.d/K4cake-autorate"
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
#
# EVERY quarantine row, not the first one (U209): /root/cake-autorate/config.wg.sh
# joined /etc/bond/agg_w, its holding directory is ALSO a declared `dir` row, and
# a bar written against one path would have said nothing about the second.
sh -c '. "$1" >/dev/null 2>&1 || exit 1
    p5_contract_dir "$2" ""
    p5_old_rows | while IFS="|" read -r o k p d; do
        case "$o" in ""|\#*) continue ;; esac
        [ "$k" = quarantine ] || continue
        q=$(p5_old_quarantine_of "$p"); echo "DEST|$p|$q"
        for kk in quarantine file dir svc; do p5_old_declared "$q" "$kk" && echo "DECLARED|$kk|$q"; done
        for r in client server; do p5_ns_ok "$r" "$q" && echo "NAMESPACE|$r|$q"; done
        for kk in file dir; do p5_old_removable "$q" "$kk" && echo "REMOVABLE|$kk|$q"; done
        qd=${q%/*}
        p5_old_declared "$qd" dir && echo "DECLAREDDIR|$qd"
        for r in client server; do p5_ns_ok "$r" "$qd" && echo "NSDIR|$r|$qd"; done
    done
    exit 0' _ "$LIB/p5-common.sh" "$CON" > "$TMPBASE/oldq" 2>/dev/null
sed -n 's/^DEST|//p' "$TMPBASE/oldq" > "$TMPBASE/oldqdest"
qdest=$(cut -d'|' -f2 "$TMPBASE/oldqdest" | tr '\n' ' ')
qn=$(grep -c . "$TMPBASE/oldqdest" 2>/dev/null); [ -n "$qn" ] || qn=0
qrows=$(awk -F'|' '$1 ~ /^p[1-4]$/ && $2=="quarantine"' "$OLDROWS" | grep -c .)
qbad=$(grep -cE '^(DECLARED|NAMESPACE|REMOVABLE|DECLAREDDIR|NSDIR)\|' "$TMPBASE/oldq" 2>/dev/null)
[ -n "$qbad" ] || qbad=0
[ "$qbad" = 0 ] || { echo "  a quarantine destination is reachable by a removal list:"; grep -E '^(DECLARED|NAMESPACE|REMOVABLE|DECLAREDDIR|NSDIR)\|' "$TMPBASE/oldq" | sed 's/^/    /'; }
[ "$qn" = "$qrows" ] && [ "$qn" -gt 0 ] || { qbad=$((qbad + 1)); echo "  $qn destination(s) resolved for $qrows quarantine row(s)"; }
# THE FORM, per row and derived from the row: <dir>.p5-quarantine/<base>.<stamp>,
# a sibling of the declared directory rather than a path inside it.
qform=0
while IFS='|' read -r qsrc qdst; do
    [ -n "$qsrc" ] || continue
    _qexp="${qsrc%/*}.p5-quarantine/${qsrc##*/}."
    case "$qdst" in "$_qexp"*) : ;; *) qform=1; echo "  unexpected quarantine destination for $qsrc: $qdst" ;; esac
done < "$TMPBASE/oldqdest"
chk "$(yn "$([ "$qbad" = 0 ] && [ "$qform" = 0 ]; echo $?)")" \
    "OLD-Q" "all $qn quarantine destinations ($qdest) are declared by no old-stack row in any kind, are outside the P5 namespace in both roles, are not removable by either half, and neither are the directories holding them -- including the one whose SOURCE directory is itself a declared \`dir\` row this run removes whole"

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
# name and REPORTED -- never deleted, and never left where the later member
# sweep of /etc/bond in the same run can take it. Byte-identical is the assertion: a
# quarantine that truncates is a deletion with a receipt.
qf=$(find "$OR/etc/bond.p5-quarantine" -type f 2>/dev/null | head -1)
a=1; [ -n "$qf" ] && a=0
b=1; [ -n "$qf" ] && grep -qxF "$AGGW_CANARY" "$qf" && b=0
c=0; [ -e "$OR/etc/bond/agg_w" ] && { c=1; echo "  the original is still in place"; }
d=0; [ -d "$OR/etc/bond" ] && { d=1; echo "  /etc/bond survived the purge"; }
grep -q 'QUARANTINED, NOT DELETED' "$TMPBASE/uerr" "$TMPBASE/uout" 2>/dev/null && e=0 || e=1
case "${qf##*/}" in agg_w.*) f=0 ;; *) f=1; echo "  quarantine name carries no timestamp: ${qf##*/}" ;; esac
chk "$(yn "$([ "$a$b$c$d$e$f" = 000000 ]; echo $?)")" \
    "OLD-3" "a pre-existing /etc/bond/agg_w is QUARANTINED, not deleted: moved to ${qf##*/} outside the tree the purge empties, byte-identical to what was there, and reported by name"

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
calls=$(tr '\n' ' ' < "$OR/revert-calls" 2>/dev/null)
# U209: TWO revert rows now, not one -- /usr/sbin/bondctl (p2/p3) and
# /root/autoratectl (p1) -- so the stub's log holds `off` once per row. Counted
# rather than string-compared, and BOTH numbers are asserted: a run that invoked
# one tool twice and the other never would pass a bare line count.
callsn=$(grep -c . "$OR/revert-calls" 2>/dev/null); [ -n "$callsn" ] || callsn=0
callsoff=$(grep -cx 'off' "$OR/revert-calls" 2>/dev/null); [ -n "$callsoff" ] || callsoff=0
revrows=$(awk -F'|' '$1 ~ /^p[1-4]$/ && $2=="revert"' "$OLDROWS" | grep -c .)
d=0; [ "$callsn" = "$revrows" ] && [ "$callsoff" = "$revrows" ] \
    || { d=1; echo "  the $revrows declared revert row(s) produced $callsn invocation(s), $callsoff of them 'off' (log: '$calls')"; }
e=0; grep -q 'RESTORED FIRST' "$TMPBASE/uout" "$TMPBASE/uerr" 2>/dev/null || { e=1; echo "  the purge did not report the restore"; }
f=0; [ "$prc2" = 0 ] || { f=1; echo "  the purge did not exit 0 (rc=$prc2)"; }
chk "$(yn "$([ "$a$b$c$d$e$f" = 000000 ] && [ "$rrc" = 1 ]; echo $?)")" \
    "OLD-R" "the teardown's own first step is carried as an action, not assumed: --check --scope old names the owed '/usr/sbin/bondctl off' (rc=$rrc), --dry-run plans it as the FIRST action ('$first') without running it, and a real --purge invokes all $revrows declared revert rows as '$calls' and reports them before anything is stopped, moved or removed"

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

# EXS-5 / EXS-6 (U153): THE OLD HALF EXECUTES TWO FILES TOO, and p5_old_removable
# resolves parents the same parent-only way p5_phys_ok did. An OLDSVC row is an
# init script this purge runs `stop` and `disable` on; the OLDREVERT row is
# `/usr/sbin/bondctl off`, the FIRST action of the whole purge. A symlink at
# either declared name is the same root-execution hole through the same door.
mkoldevil() {   # mkoldevil ROOT PATH -- replace declared PATH with a symlink to
                # ../../tmp/oldevil, which writes a sentinel when it runs
    mkdir -p "$1/tmp"
    printf '#!/bin/sh\necho "RAN $1" >> "%s/oldevil-ran"\nexit 0\n' "$1" > "$1/tmp/oldevil"
    chmod 755 "$1/tmp/oldevil"
    rm -f "$1$2"
    ln -s ../../tmp/oldevil "$1$2"
}

mkoldroot oldxs5
mkmgmt "$OR" client none
mkoldevil "$OR" /etc/init.d/engarde-client
before=$(oldleft "$OR" | wc -l | tr -d " ")
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
a=0
[ -e "$OR/oldevil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT: $(tr '\n' ' ' < "$OR/oldevil-ran")"; }
[ "$rc" = 0 ] && { a=1; echo "  the purge exited 0 with a symlinked old-stack init script"; }
grep -q '/etc/init.d/engarde-client' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q '/tmp/oldevil' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the RESOLVED target"; }
[ "$left" = "$before" ] || { a=1; echo "  a refused purge removed $((before - left)) artifact(s)"; }
[ -e "$OR/revert-calls" ] && { a=1; echo "  the purge ran its revert step before refusing"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-5" "OLDSVC: /etc/init.d/engarde-client replaced by a symlink to ../../tmp/oldevil -- the target is NOT executed, the purge exits $rc naming both the path and the /tmp/oldevil it resolves to, and all $before old-stack artifacts are still there"

mkoldroot oldxs6
mkmgmt "$OR" client none
mkoldevil "$OR" /usr/sbin/bondctl
before=$(oldleft "$OR" | wc -l | tr -d " ")
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
a=0
[ -e "$OR/oldevil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT AS THE PURGE'S FIRST ACTION: $(tr '\n' ' ' < "$OR/oldevil-ran")"; }
[ -e "$OR/revert-calls" ] && { a=1; echo "  something was invoked as the revert tool"; }
[ "$rc" = 0 ] && { a=1; echo "  the purge exited 0 with a symlinked revert tool"; }
grep -q '/usr/sbin/bondctl' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q '/tmp/oldevil' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the RESOLVED target"; }
[ "$left" = "$before" ] || { a=1; echo "  a refused purge removed $((before - left)) artifact(s)"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-6" "OLDREVERT: /usr/sbin/bondctl replaced by a symlink to ../../tmp/oldevil -- '<path> off' is the purge's FIRST action and it is NOT run (no sentinel, no revert-calls), the run exits $rc naming the resolved target, and all $before artifacts are untouched"


# EXS-8 / EXS-9 / MU-EXS-OLD (U153 fix round): THE OLD HALF'S EXECUTOR GATES,
# ON THEIR OWN. EXS-5 and EXS-6 above prove the hole is closed, but they are
# stopped by the PLANNER: old_exec_gate writes an `oexec|` row into $OLDBAD and
# the purge refuses ENTIRELY with P5_EX_CONTRACT before a single action runs.
# The two executor-side gates (`p5_old_exec_ok "$_ox_p" revert` in the
# OLDREVERT arm, `... svc` in the OLDSVC arm) are therefore never REACHED by
# EXS-5/EXS-6 -- delete both and those bars stay green, which makes them no
# evidence at all for the code that actually stands between a plan and a root
# exec. These three are the old half's analogue of EXS-3 and MU-EXS: neutralise
# the PLANNER only and the executor must still refuse at the point of use. The
# plan is a file on disk between the two, so a symlink planted after the plan
# was written has nothing but the executor gate in front of it.
oldmut() {   # oldmut DIR SED-ARGS... -- a copy of the shipped uninstaller with
             # its library and contract beside it, mutated by the given seds
    _om_d="$1"; shift
    rm -rf "$_om_d"; mkdir -p "$_om_d/bin" "$_om_d/lib" "$_om_d/contract"
    cp "$LIB/p5-common.sh" "$_om_d/lib/p5-common.sh"
    cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$_om_d/contract/"
    sed "$@" "$BIN/p5-uninstall" > "$_om_d/bin/p5-uninstall"
}

# EXS-8: OLDSVC, planner gate removed, executor must still refuse.
OM8="$TMPBASE/oldxsmut8"
oldmut "$OM8" -e 's@old_exec_gate svc "$_oe_p" || continue@:@'
a=0
cmp -s "$BIN/p5-uninstall" "$OM8/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the planner's OLDSVC execute gate was not found"; }
grep -q 'p5_old_exec_ok "$_ox_p" svc' "$OM8/bin/p5-uninstall" || { a=1; echo "  the EXECUTOR's OLDSVC gate is not in the mutant, so this bar has no subject"; }
mkoldroot oldxs8
mkmgmt "$OR" client none
mkoldevil "$OR" /etc/init.d/engarde-client
P5_ROOT="$OR" sh "$OM8/bin/p5-uninstall" --purge --role client >"$TMPBASE/xs8.out" 2>"$TMPBASE/xs8.err"; rc8=$?
[ -e "$OR/oldevil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT with only the planner gate removed: $(tr '\n' ' ' < "$OR/oldevil-ran")"; }
grep -q '^OLDSVC|/etc/init.d/engarde-client$' "$TMPBASE/xs8.out" || { a=1; echo "  the mutant planner did not emit the action, so this bar is vacuous"; }
grep -q 'REFUSED SVCDOWN on /etc/init.d/engarde-client -- the FILE it would execute' "$TMPBASE/xs8.err" || { a=1; echo "  the executor did not refuse at the point of use"; }
grep -q '/tmp/oldevil' "$TMPBASE/xs8.err" || { a=1; echo "  the executor's refusal did not name the RESOLVED target"; }
[ "$rc8" = 0 ] && { a=1; echo "  the purge exited 0 after refusing an execution"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-8" "with the PLANNER's OLDSVC execute gate removed the plan does emit OLDSVC|/etc/init.d/engarde-client, and the EXECUTOR still resolves the symlink and refuses by name and by resolved target (exit $rc8, sentinel absent): a link planted after the old-stack plan was written is caught"

# EXS-9: OLDREVERT, the purge's FIRST action, same shape.
OM9="$TMPBASE/oldxsmut9"
oldmut "$OM9" -e 's@old_exec_gate revert "$_oe_p" || continue@:@'
a=0
cmp -s "$BIN/p5-uninstall" "$OM9/bin/p5-uninstall" && { a=1; echo "  MUTATION DID NOT APPLY: the planner's OLDREVERT execute gate was not found"; }
grep -q 'p5_old_exec_ok "$_ox_p" revert' "$OM9/bin/p5-uninstall" || { a=1; echo "  the EXECUTOR's OLDREVERT gate is not in the mutant, so this bar has no subject"; }
mkoldroot oldxs9
mkmgmt "$OR" client none
mkoldevil "$OR" /usr/sbin/bondctl
before=$(oldleft "$OR" | wc -l | tr -d " ")
P5_ROOT="$OR" sh "$OM9/bin/p5-uninstall" --purge --role client >"$TMPBASE/xs9.out" 2>"$TMPBASE/xs9.err"; rc9=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
[ -e "$OR/oldevil-ran" ] && { a=1; echo "  THE SYMLINK TARGET RAN AS ROOT AS THE PURGE'S FIRST ACTION: $(tr '\n' ' ' < "$OR/oldevil-ran")"; }
[ -e "$OR/revert-calls" ] && { a=1; echo "  something was invoked as the revert tool"; }
grep -q '^OLDREVERT|/usr/sbin/bondctl$' "$TMPBASE/xs9.out" || { a=1; echo "  the mutant planner did not emit the action, so this bar is vacuous"; }
grep -q 'REFUSED REVERT on /usr/sbin/bondctl -- the FILE it would execute' "$TMPBASE/xs9.err" || { a=1; echo "  the executor did not refuse at the point of use"; }
grep -q '/tmp/oldevil' "$TMPBASE/xs9.err" || { a=1; echo "  the executor's refusal did not name the RESOLVED target"; }
[ "$rc9" = 0 ] && { a=1; echo "  the purge exited 0 after refusing its first action"; }
[ "$left" = "$before" ] || { a=1; echo "  a refused purge removed $((before - left)) artifact(s)"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-9" "with the PLANNER's OLDREVERT execute gate removed the plan does emit OLDREVERT|/usr/sbin/bondctl, and the EXECUTOR still refuses at the point of use (exit $rc9): no sentinel, no revert-calls, and all $before old-stack artifacts still there -- the purge stopped with nothing touched"

# MU-EXS-OLD: and the executor gates are what did that. In the SAME
# planner-neutralised world as EXS-8/EXS-9, both `p5_old_exec_ok` calls are
# removed as well and both fixtures EXECUTE the symlink target as root.
OMM="$TMPBASE/oldxsmutm"
oldmut "$OMM" \
    -e 's@old_exec_gate svc "$_oe_p" || continue@:@' \
    -e 's@old_exec_gate revert "$_oe_p" || continue@:@' \
    -e 's@if ! p5_old_exec_ok "$_ox_p" svc; then@if false; then@' \
    -e 's@if ! p5_old_exec_ok "$_ox_p" revert; then@if false; then@'
a=0
grep -q 'if ! p5_old_exec_ok' "$OMM/bin/p5-uninstall" && { a=1; echo "  an old-half executor gate survived the mutation"; }
grep -q 'old_exec_gate svc\|old_exec_gate revert' "$OMM/bin/p5-uninstall" && { a=1; echo "  an old-half planner gate call survived the mutation"; }
mkoldroot oldxsm1
mkmgmt "$OR" client none
mkoldevil "$OR" /etc/init.d/engarde-client
P5_ROOT="$OR" sh "$OMM/bin/p5-uninstall" --purge --role client >"$TMPBASE/xsmo1.out" 2>"$TMPBASE/xsmo1.err"; mo1=$?
grep -q '^RAN stop$' "$OR/oldevil-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the OLDSVC symlink target's stop -- the seed did not bite"; }
grep -q '^RAN disable$' "$OR/oldevil-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the OLDSVC symlink target's disable"; }
mkoldroot oldxsm2
mkmgmt "$OR" client none
mkoldevil "$OR" /usr/sbin/bondctl
P5_ROOT="$OR" sh "$OMM/bin/p5-uninstall" --purge --role client >"$TMPBASE/xsmo2.out" 2>"$TMPBASE/xsmo2.err"; mo2=$?
grep -q '^RAN off$' "$OR/oldevil-ran" 2>/dev/null || { a=1; echo "  the mutant did not run the OLDREVERT symlink target -- the seed did not bite"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-EXS-OLD" "MUTATION: in the same planner-neutralised world EXS-8/EXS-9 run in, removing BOTH p5_old_exec_ok calls lets the old half EXECUTE the symlink target as root -- 'RAN stop'/'RAN disable' for OLDSVC (exit $mo1) and 'RAN off' for OLDREVERT (exit $mo2). EXS-8 and EXS-9 are bars that can fail, and they measure the EXECUTOR, not the planner"

# EXS-10 / MU-EXS-S9-OLD (U153 fix round 2): S9 ON THE OLD HALF, which EXS-7 and
# MU-EXS-S9 do not reach. `p5_old_exec_ok` has its own not-a-regular-file block
# (p5/lib/p5-common.sh:844-847) and until this bar it had no behavioural cover
# at all: replacing that single line with `if false; then` left the battery at
# 176 passed / 0 failed. Three structural reasons the P5-half bars could not
# cover it -- (1) their fixture is `--remove`, and the old-stack teardown is
# PURGE-only, so `--remove` never calls p5_old_exec_ok; (2) no other fixture in
# this file puts a non-regular file at an OLD-stack executed name (mkoldevil
# plants symlinks, which take the `[ -L ]` path below the guard); (3) the only
# other mention of _p5ox_path in this file was a sed and a mutation-applied
# grep, neither of which is a behavioural assertion. So: a DIRECTORY at the
# declared /etc/init.d/engarde-client, under --purge.
mkolddir() {   # mkolddir ROOT PATH -- replace declared PATH with a DIRECTORY,
               # which is -x (searchable) but not -f, and is not a symlink
    rm -rf "$1$2"
    mkdir -p "$1$2"
    chmod 755 "$1$2"
}

mkoldroot oldxs10
mkmgmt "$OR" client none
mkolddir "$OR" /etc/init.d/engarde-client
before=$(oldleft "$OR" | wc -l | tr -d " ")
a=0
[ -x "$OR/etc/init.d/engarde-client" ] || { a=1; echo "  the fixture is not -x, so this bar is not the S9 case"; }
[ -f "$OR/etc/init.d/engarde-client" ] && { a=1; echo "  the fixture IS a regular file, so this bar is not the S9 case"; }
[ -L "$OR/etc/init.d/engarde-client" ] && { a=1; echo "  the fixture is a SYMLINK, so it would be caught by the resolver and not by the guard under test"; }
unin "$OR" --purge --role client; rc=$?
left=$(oldleft "$OR" | wc -l | tr -d " ")
[ "$rc" = 4 ] || { a=1; echo "  exit was $rc, not 4 (contract) -- a non-regular file at a declared OLD-stack executed name was not refused"; }
grep -q 'is executable but is NOT A REGULAR FILE' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not come from the old half's not-a-regular-file guard"; }
grep -q '/etc/init.d/engarde-client' "$TMPBASE/uerr" || { a=1; echo "  the refusal did not name the declared path"; }
grep -q 'stopped and disabled engarde-client' "$TMPBASE/uout" "$TMPBASE/uerr" && { a=1; echo "  the run REPORTED stopping a service it cannot have stopped"; }
[ -e "$OR/revert-calls" ] && { a=1; echo "  the purge ran its revert step before refusing"; }
[ "$left" = "$before" ] || { a=1; echo "  a refused purge removed $((before - left)) artifact(s)"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "EXS-10" "S9 ON THE OLD HALF: a DIRECTORY at the declared /etc/init.d/engarde-client is -x, not -f and not a symlink -- p5_old_exec_ok refuses it by name (exit $rc, 'NOT A REGULAR FILE'), all $before old-stack artifacts are still there, and the run does NOT report 'stopped and disabled engarde-client' for a service it cannot have stopped"

# MU-EXS-S9-OLD: and the OLD half's block is what does that. ONE line is seded
# out of a COPY of the shipped library -- `[ ! -f "${P5_ROOT}${_p5ox_path}" ]`,
# and the P5 half's block is asserted to SURVIVE, so the two halves are seeded
# independently rather than mutated together. This is the exact seed that found
# the hole; before EXS-10 existed the whole battery stayed green under it.
XSM4="$TMPBASE/exsmut4"
rm -rf "$XSM4"; mkdir -p "$XSM4/bin" "$XSM4/lib" "$XSM4/contract"
cp "$BIN/p5-uninstall" "$XSM4/bin/p5-uninstall"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$XSM4/contract/"
sed -e 's|if \[ ! -f "${P5_ROOT}${_p5ox_path}" ]; then|if false; then|' \
    "$LIB/p5-common.sh" > "$XSM4/lib/p5-common.sh"
a=0
cmp -s "$LIB/p5-common.sh" "$XSM4/lib/p5-common.sh" && { a=1; echo "  MUTATION DID NOT APPLY: the old half's not-a-regular-file guard was not found"; }
grep -q '! -f "${P5_ROOT}${_p5ox_path}"' "$XSM4/lib/p5-common.sh" && { a=1; echo "  the old-half guard survived the mutation"; }
# Same isolation shape as MU-EXS-S9, mirrored: exactly one line changed and it
# is the OLD half's, measured as a diff against the shipped file so that seeding
# the P5 half of the tree cannot redden this bar.
s9o_rm=$(diff "$LIB/p5-common.sh" "$XSM4/lib/p5-common.sh" | grep '^<' | sed 's/^< *//')
s9o_add=$(diff "$LIB/p5-common.sh" "$XSM4/lib/p5-common.sh" | grep '^>' | sed 's/^> *//')
[ "$s9o_rm" = 'if [ ! -f "${P5_ROOT}${_p5ox_path}" ]; then' ] || { a=1; echo "  the seed removed something other than exactly the old-half guard line: [$s9o_rm]"; }
[ "$s9o_add" = 'if false; then' ] || { a=1; echo "  the seed added something other than exactly 'if false; then': [$s9o_add]"; }
mkoldroot oldxs10m
mkmgmt "$OR" client none
mkolddir "$OR" /etc/init.d/engarde-client
P5_ROOT="$OR" sh "$XSM4/bin/p5-uninstall" --purge --role client >"$TMPBASE/xs10m.out" 2>"$TMPBASE/xs10m.err"; s9orc=$?
grep -q 'is executable but is NOT A REGULAR FILE' "$TMPBASE/xs10m.err" && { a=1; echo "  the mutant still refused -- the seed did not bite"; }
grep -q 'stopped and disabled engarde-client' "$TMPBASE/xs10m.out" "$TMPBASE/xs10m.err" || { a=1; echo "  the mutant never reached the old-stack execution site, so EXS-10 is not measuring the guard"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "MU-EXS-S9-OLD" "MUTATION: with p5_old_exec_ok's not-a-regular-file guard ALONE removed from the shipped LIBRARY (the P5 half's block asserted still present), the same directory fixture is handed to the kernel as root under --purge and the run reports 'stopped and disabled engarde-client' (exit $s9orc) with no refusal. EXS-10 is a bar that can fail, and it fails on the OLD-half block specifically"
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
# ARTIFACTS ONLY, NOT THE rc.d FLAGS (U209). `--purge` is now the composition of
# --switch-off and --remove-old, and this refusal happens at the point of use in
# the SECOND of them -- so the first has already stopped and disabled the
# services and taken their boot flags, which is what --switch-off is FOR and is
# undone by the `<tool> on` its rollback block names. What this bar claims, and
# what still has to be exactly true, is that no old-stack ARTIFACT was removed
# and that agg_w is untouched byte for byte.
oldleft "$OR" | grep -v '^rc.d flag ' > "$TMPBASE/q2b"
q2before=$(grep -c . "$TMPBASE/q2b" 2>/dev/null); [ -n "$q2before" ] || q2before=0
unin "$OR" --purge --role client; q2rc=$?
q2left=$(oldleft "$OR" | grep -c -v '^rc.d flag ' 2>/dev/null); [ -n "$q2left" ] || q2left=0
q2copies=$(find "$OR" -name 'agg_w*' 2>/dev/null | wc -l | tr -d " ")
a=0
[ "$q2rc" = 5 ] || { a=1; echo "  the purge did not stop on the symlinked quarantine destination (rc=$q2rc)"; }
grep -q 'does not physically land where it is spelled' "$TMPBASE/uerr" || { a=1; echo "  the refusal never named the resolved destination"; }
grep -q "$AGGW_CANARY" "$OR/etc/bond/agg_w" 2>/dev/null || { a=1; echo "  agg_w is not where it was, byte for byte"; }
[ "$q2left" = "$q2before" ] || { a=1; echo "  $((q2before - q2left)) artifact(s) were removed by a purge that should have stopped"; }
[ "$q2copies" = 1 ] || { a=1; echo "  agg_w exists in $q2copies places, so something moved it"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "OLD-Q2" "a quarantine destination that RESOLVES inside a directory this purge removes whole is refused: with /etc/bond.p5-quarantine symlinked to /etc/bond the run stops (rc=$q2rc) naming the resolved path, agg_w is still the original file in its original place ($q2copies copy), and all $q2before old ARTIFACTS are untouched -- the switch-off phase's stops, disables and boot-flag sweep did run, and are what its rollback block undoes"

# MU-OLD-Q: THE MUTATION. The quarantine is deleted from a COPY of the shipped
# uninstaller -- exactly the seeded A/B this unit owes -- and the same fixture
# is purged with it. Without the quarantine the file is taken by the MEMBER
# SWEEP of /etc/bond that runs later in the SAME plan (U188 replaced the
# recursive removal with it), so OLD-3's evidence
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

# ===========================================================================
# RM-12 / RM-13 / RM-14 (U188) -- THE SURGICAL TRADE, MEASURED ON THE OLD HALF
# ===========================================================================
# The three `rm -rf`s on the old half's `dir` rows are gone; the rows are now
# emptied member by member and rmdir-ed. The trade that buys is stated in the
# uninstaller's header and it is exactly this: a removal can LEAVE A FILE BEHIND
# AND SAY SO, but it can never take a tree it did not enumerate. So it has to be
# provable in both directions -- something unexpected in the tree stops the
# removal and is NAMED (RM-12), a symlink is neither followed nor unlinked and
# its target survives (RM-13), and once the unexpected things are gone the very
# same command finishes the job (RM-14). Without RM-14 the first two would pass
# on an uninstaller that had simply stopped removing anything.

# RM-12: /root/cake-autorate is the one `dir` row inside the OPERATOR'S OWN
# HOME, so its member gate is the strict one: only a member the derived list
# already declares may be unlinked. A stranger's regular file and a FIFO are
# planted in it; both must survive, both must be NAMED on stderr, the directory
# must still be standing, the run must exit 1 -- and the rest of the purge must
# still have happened, or "it left things alone" would be indistinguishable from
# "it did nothing".
mkoldroot oldrm12
mkmgmt "$OR" client none
printf 'not p5 and not p1\n' > "$OR/root/cake-autorate/stranger"
a=0
mkfifo "$OR/root/cake-autorate/pipe" 2>/dev/null || { a=1; echo "  could not create the fifo fixture (mkfifo missing?)"; }
unin "$OR" --purge --role client; rc=$?
[ -f "$OR/root/cake-autorate/stranger" ] || { a=1; echo "  the stranger's file was REMOVED"; }
[ -p "$OR/root/cake-autorate/pipe" ]     || { a=1; echo "  the FIFO was REMOVED"; }
[ -d "$OR/root/cake-autorate" ]          || { a=1; echo "  the directory holding them was removed anyway"; }
grep -q 'LEFT: /root/cake-autorate/stranger' "$TMPBASE/uerr" || { a=1; echo "  the stranger's file was not named in a LEFT line"; }
grep -q 'LEFT: /root/cake-autorate/pipe' "$TMPBASE/uerr"     || { a=1; echo "  the FIFO was not named in a LEFT line"; }
grep -q 'NOT EMPTY, left in place: /root/cake-autorate' "$TMPBASE/uerr" || { a=1; echo "  the non-empty directory was not reported"; }
[ "$rc" = 1 ] || { a=1; echo "  a purge that left two paths behind exited $rc, not 1"; }
[ -d "$OR/etc/bond" ]     && { a=1; echo "  /etc/bond was NOT emptied and removed -- the purge did nothing, which is not the claim"; }
[ -d "$OR/var/run/bond" ] && { a=1; echo "  /var/run/bond was NOT emptied and removed"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "RM-12" "a stranger's file and a FIFO planted in the declared /root/cake-autorate row both SURVIVE the purge, are each named in a LEFT line, keep their directory standing and take the exit code with them (rc=$rc) -- while /etc/bond and /var/run/bond are emptied member by member and gone"
OR12="$OR"   # RM-14 finishes THIS root; RM-13 re-points $OR at its own

# RM-13: A SYMLINK IS NOT A DOOR. Both halves, one bar, because the two answers
# are deliberately different and a single wrong `[ -d ]` test would break either.
#   OLD half: someone else's link. REPORTED, not followed, not unlinked.
#   P5  half: P5's own litter under its own tmpfs root. Unlinked AS A LINK --
#             `rm -f` removes the link, never the target.
# In both, THE TARGET DIRECTORY AND ITS FILE MUST SURVIVE, which is the property
# an `rm -rf` through a followed symlink would have destroyed.
#
# A FRESH FIXTURE, and the first draft of this bar proved why. It re-used the
# root RM-12 had already purged and hand-recreated /etc/bond to hold the link:
# that makes old_bonding_resident true (it probes /etc/bond) while
# /usr/sbin/bondctl is already gone, so the OLDREVERT arm stops the run with
# exit 5 before a plan is ever built, and the bar measured a precondition
# refusal rather than a walk. The interaction is real and is recorded on the
# U188 row as owed; this bar is not the place to assert it.
mkoldroot oldrm13
mkmgmt "$OR" client none
mkdir -p "$OR/outsidedir"; printf 'do not touch\n' > "$OR/outsidedir/keep"
ln -s ../../outsidedir "$OR/etc/bond/olink"
unin "$OR" --purge --role client; rc13=$?
b=0
[ -L "$OR/etc/bond/olink" ] || { b=1; echo "  the OLD half unlinked a symlink it does not own"; }
grep -q 'LEFT: /etc/bond/olink' "$TMPBASE/uerr" || { b=1; echo "  the symlink was not named in a LEFT line"; }
[ -f "$OR/outsidedir/keep" ] || { b=1; echo "  the symlink's TARGET was followed and its contents removed"; }
[ -d "$OR/etc/bond" ] || { b=1; echo "  the directory holding the symlink was removed anyway"; }
[ ! -e "$OR/etc/bond/planted" ] || { b=1; echo "  the DECLARED member beside the symlink was not swept -- the walk did nothing"; }
[ "$rc13" = 1 ] || { b=1; echo "  a purge that left a symlink behind exited $rc13, not 1"; }
RSL=$TMPBASE/rsl; inst "$RSL" "$P9" client
mkdir -p "$RSL/var/run/p5" "$RSL/outsidedir"; printf 'do not touch\n' > "$RSL/outsidedir/keep"
ln -s ../../../outsidedir "$RSL/var/run/p5/plink"
unin "$RSL" --remove --role client; prc13=$?
[ -L "$RSL/var/run/p5/plink" ] && { b=1; echo "  the P5 half left its own symlink in place"; }
[ -f "$RSL/outsidedir/keep" ] || { b=1; echo "  the P5 half followed the symlink and removed the target's contents"; }
[ -d "$RSL/outsidedir" ] || { b=1; echo "  the P5 half removed the symlink's target directory"; }
[ -e "$RSL/var/run/p5" ] && { b=1; echo "  /var/run/p5 survived a walk whose only member was a symlink"; }
[ "$prc13" = 0 ] || { b=1; echo "  the P5 removal exited $prc13, not 0"; }
chk "$(yn "$([ "$b" = 0 ]; echo $?)")" \
    "RM-13" "a symlinked subdirectory is never DESCENDED by either walk: the old half reports it and leaves it (rc=$rc13), the P5 half unlinks it AS A LINK (rc=$prc13), and in both the target directory and the file in it survive"

# RM-14: AND THE SAME COMMAND FINISHES. Clear the two things RM-12 left on ITS
# root, re-run the identical verb, and the directory is gone with exit 0. This
# is what stops RM-12 from passing on an uninstaller that removes nothing: the
# ONLY difference between the red run and the green one is the contents of the
# directory -- not the command, the fixture or the gate.
#
# RM-13's root is NOT finished here, and the reason is named rather than left
# looking like an omission: its /etc/bond survives the first purge (correctly --
# it holds the symlink), and /etc/bond is one of old_bonding_resident's four
# probes, so a second --purge there re-plans the restore step with the bondctl
# the first run removed and stops at exit 5. That interaction is a consequence
# of this unit's change and it is recorded as owed on the U188 row; asserting it
# here would pin a behaviour nobody has decided yet.
rm -f "$OR12/root/cake-autorate/stranger" "$OR12/root/cake-autorate/pipe"
unin "$OR12" --purge --role client; rc14=$?
c=0
[ -d "$OR12/root/cake-autorate" ] && { c=1; echo "  /root/cake-autorate is still there after its members were cleared"; }
[ "$rc14" = 0 ] || { c=1; echo "  the finishing purge exited $rc14, not 0"; }
oldleft "$OR12" > "$TMPBASE/rm14surv"
rm14_left=$(grep -c . "$TMPBASE/rm14surv" 2>/dev/null); [ -n "$rm14_left" ] || rm14_left=0
[ "$rm14_left" = 0 ] || { c=1; echo "  declared old-stack artifacts still present after the finishing run:"; sed 's/^/    /' "$TMPBASE/rm14surv"; }
chk "$(yn "$([ "$c" = 0 ]; echo $?)")" \
    "RM-14" "with the stranger and the FIFO cleared, the SAME --purge finishes the job on the SAME root: /root/cake-autorate is rmdir-ed, $rm14_left declared old-stack artifacts are left and the run exits 0 (rc=$rc14) -- so RM-12's red is the contents of the directory, not a removal that stopped working"

# RM-15: A SYMLINKED ROW ROOT IS NOT WALKED. The exposure this unit CREATED and
# the `rm -rf` did not have, and it is here because nothing planted one: every
# `ln -s` in this file makes an init.d file, a sibling quarantine link or a
# SUBDIRECTORY link (RM-13), never the row root itself.
#
# Make a `dir` row a symlink to a directory that is not the old stack. `[ -d ]`
# follows links so old_emit_plan's presence test passes; p5_old_removable
# resolves the PARENT, not the row path itself, so old_gate passes too. Without
# the refusal at the head of old_walk_dir the three globs resolve THROUGH the
# link and enumerate the TARGET'S members, each arriving back spelled
# /var/run/bond/<name>, with exactly one line of the member gate (the final
# p5_realdir(DIR) == DIR test) between them and an `rm -f`.
#
# TWO ARMS, AND THE FIRST ONE IS THE BAR. /var/run/bond has no member declared
# inside it, so the plan-time expansion gate has nothing to refuse and THE WALK
# IS ACTUALLY REACHED -- that is the state this fix exists for. /etc/bond is
# different for a reason that is an accident of its contents rather than a
# property of the walk, and arm 2 pins it so nobody "simplifies" arm 1 into it:
# /etc/bond/agg_w is a declared `quarantine` row, its own gate 6 resolves
# through the link and fails, and the expansion gate then refuses THE ENTIRE
# PURGE with exit 4 having touched nothing. Both are correct answers; only the
# first one is this unit's code.
#
# THE ASSERTION IS ON THE PLAN as well as on the disk, and that ordering is the
# point: --dry-run is read FIRST, so "no member of the target was ever
# enumerated" is measured on the plan the run would have executed, not inferred
# afterwards from files that happen to still be there.
mkoldroot oldrm15
mkmgmt "$OR" client none
mkdir -p "$OR/var/run/notbond"
printf 'someone else\n' > "$OR/var/run/notbond/hostkey"
rm -f "$OR/var/run/bond/planted"; rmdir "$OR/var/run/bond" 2>/dev/null
ln -s notbond "$OR/var/run/bond"
e=0
[ -L "$OR/var/run/bond" ] || { e=1; echo "  the fixture is wrong: /var/run/bond is not a symlink, so this bar measures nothing"; }
unin "$OR" --purge --role client --dry-run; drc=$?
grep -q '/var/run/bond/hostkey' "$TMPBASE/uout" "$TMPBASE/uerr" && { e=1; echo "  the PLAN enumerated a member of the symlink's TARGET (/var/run/bond/hostkey)"; }
grep -q 'OLDRMDIR|/var/run/bond' "$TMPBASE/uout" "$TMPBASE/uerr" && { e=1; echo "  the plan carries an OLDRMDIR for a row root it refused to walk"; }
unin "$OR" --purge --role client; rc15=$?
[ -L "$OR/var/run/bond" ] || { e=1; echo "  the symlinked row root was itself removed"; }
[ -f "$OR/var/run/notbond/hostkey" ] || { e=1; echo "  A MEMBER OF THE TARGET WAS UNLINKED THROUGH THE LINK"; }
[ -d "$OR/var/run/notbond" ] || { e=1; echo "  the symlink's target directory is gone"; }
grep -q 'LEFT: /var/run/bond (the declared directory row is itself a SYMLINK' "$TMPBASE/uerr" \
    || { e=1; echo "  the symlinked row root was not REPORTED by name and reason"; }
[ "$rc15" = 1 ] || { e=1; echo "  a purge that left the row root behind exited $rc15, not 1"; }
[ -d "$OR/etc/bond" ] && { e=1; echo "  /etc/bond was NOT emptied and removed -- the run did nothing, which is not the claim"; }
# Arm 2: the same shape on the row that DOES carry a declared member.
mkoldroot oldrm15b
mkmgmt "$OR" client none
mkdir -p "$OR/etc/notbond"
printf 'someone else\n' > "$OR/etc/notbond/hostkey"
printf 'someone else\n' > "$OR/etc/notbond/agg_w"
rm -f "$OR/etc/bond/planted" "$OR/etc/bond/agg_w"; rmdir "$OR/etc/bond" 2>/dev/null
ln -s notbond "$OR/etc/bond"
unin "$OR" --purge --role client; rc15b=$?
[ "$rc15b" = 4 ] || { e=1; echo "  a symlinked /etc/bond did not trip the plan-time expansion gate (rc=$rc15b, expected 4)"; }
grep -q 'REFUSING THE ENTIRE PURGE' "$TMPBASE/uerr" || { e=1; echo "  the expansion gate did not refuse the whole purge by name"; }
[ -f "$OR/etc/notbond/agg_w" ] || { e=1; echo "  the target's agg_w was reached through the link by the quarantine step"; }
[ -f "$OR/etc/notbond/hostkey" ] || { e=1; echo "  a member of the target was unlinked through the link"; }
[ -f "$OR/usr/sbin/bondctl" ] || { e=1; echo "  the refusal said NOTHING HAS BEEN TOUCHED and something was"; }
[ "$e" = 0 ] || { echo "  --- the purge's own stderr, last 20 lines (a bar that fails has to say what the run said) ---"; tail -20 "$TMPBASE/uerr" | sed 's/^/    /'; }
chk "$(yn "$([ "$e" = 0 ]; echo $?)")" \
    "RM-15" "a declared old-stack \`dir\` row that is a SYMLINK is REPORTED and never walked: on /var/run/bond, where the walk is actually reached, the --dry-run plan (rc=$drc) names no member of the target and plans no OLDRMDIR for it, and the purge (rc=$rc15) leaves the link and the target's directory and file untouched while the rest of the old stack is still removed; on /etc/bond, whose declared quarantine member fails its own gate through the link, the plan-time expansion gate refuses the ENTIRE purge (rc=$rc15b) with nothing touched"

# RM-16: THE MEMBER GATE'S FOREIGN-ORIGIN LINE IS HELD BY A BAR.
# p5_old_member_removable's `p5_old_origin "$_p5om_file"` (gate 3) refuses a
# member contract/foreign does not classify under p1..p4. Every member of the
# three `dir` rows classifies today -- foreign:74/:99/:101 are `/etc/bond/*`,
# `/root/cake-autorate/*`, `/var/run/bond/*` globs -- so no fixture on this box
# can make that line fire, and an unfirable line is an unheld one: the round
# that shipped it could delete it and the whole battery stayed green.
#
# So the fixture is a CONTRACT, not a file: contract/foreign gets one `gl` row
# ahead of the `/var/run/bond/*` glob, which is exactly the case the gate exists
# for -- a path inside a foreign directory that belongs to the MANAGEMENT stack.
# Three calls, direct, as a process (this harness never sources the library):
#   C  shipped library + shipped contract  -> 0, so the probe really reaches the
#      origin line instead of being refused earlier by something else
#   A  shipped library + the `gl` contract -> non-zero, the line firing
#   B  the library with THAT LINE DELETED  -> 0, the mutant would unlink it
RM16="$TMPBASE/rm16"
mkdir -p "$RM16/con" "$RM16/mut" "$RM16/root/var/run/bond"
cp "$CON/namespace" "$CON/paths" "$CON/foreign" "$RM16/con/"
printf 'gl\n' > "$RM16/root/var/run/bond/glfile"
awk '{ if ($0 == "p3|/var/run/bond/*") print "gl|/var/run/bond/glfile"; print }' \
    "$CON/foreign" > "$RM16/con/foreign.gl"
cp "$LIB/p5-common.sh" "$RM16/mut/shipped.sh"
sed '/p5_old_origin "._p5om_file"/d' "$LIB/p5-common.sh" > "$RM16/mut/nomember.sh"
rm16call() {   # rm16call LIB FOREIGNFILE -> exit status of p5_old_member_removable
    cp "$2" "$RM16/con/foreign"
    sh -c '. "$1" >/dev/null 2>&1 || exit 9
        p5_contract_dir "$2" ""
        P5_ROOT="$3"
        p5_old_member_removable /var/run/bond /var/run/bond/glfile' \
        _ "$1" "$RM16/con" "$RM16/root" >/dev/null 2>&1
}
f=0
rm16_mut=$(diff "$LIB/p5-common.sh" "$RM16/mut/nomember.sh" 2>/dev/null | grep -c '^<')
[ "$rm16_mut" = 1 ] || { f=1; echo "  MUTATION DID NOT APPLY as one line ($rm16_mut deleted) -- the member-level origin call was not found"; }
cp "$CON/foreign" "$RM16/con/foreign.plain"
rm16call "$RM16/mut/shipped.sh" "$RM16/con/foreign.plain"; rm16_c=$?
[ "$rm16_c" = 0 ] || { f=1; echo "  CONTROL: the shipped gate refused the probe member under the SHIPPED contract (rc=$rm16_c) -- something ahead of the origin line is doing the refusing, so A proves nothing"; }
rm16call "$RM16/mut/shipped.sh" "$RM16/con/foreign.gl"; rm16_a=$?
[ "$rm16_a" != 0 ] || { f=1; echo "  A: the shipped gate ADMITTED a member contract/foreign classifies as \`gl\` -- the management stack is reachable by the member sweep"; }
rm16call "$RM16/mut/nomember.sh" "$RM16/con/foreign.gl"; rm16_b=$?
[ "$rm16_b" = 0 ] || { f=1; echo "  B: the mutant with the origin line DELETED still refused (rc=$rm16_b), so A's refusal is not that line and the line is still unheld"; }
cp "$CON/foreign" "$RM16/con/foreign"
chk "$(yn "$([ "$f" = 0 ]; echo $?)")" \
    "RM-16" "MUTATION: the member gate's foreign-origin check is HELD -- the same probe member is admitted under the shipped contract (rc=$rm16_c), REFUSED when contract/foreign classifies it \`gl\` (rc=$rm16_a), and admitted again by a COPY of the library with that one line deleted (rc=$rm16_b, $rm16_mut line). The old-stack member sweep can never reach a management path, and that is now a bar rather than a reading"

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
# QG -- U208 / G5: THE PRE-SWITCH QUIESCENCE GATE, THE PREDICATE ITSELF
# ===========================================================================
# The gate the deploy sequence turns on is a check on QUIESCENCE, not on file
# absence: under the order Mo decided -- switch the old stack OFF, install P5
# alongside it, switch P5 ON, remove the old stack afterwards -- every old-stack
# file is still on disk at the moment P5 is engaged, and `--check --scope old`
# would refuse a box that is exactly where the sequence says it should be.
#
# THIS BLOCK MEASURES THE PREDICATE. The other two halves are named here so a
# green run is not read as more than it is: Layer-1 (bond_model.py QG-L1..L3,
# QG-M) proves the EDGE ALGEBRA -- a false fact leaves the node unmoved and runs
# zero actions -- and Layer-2 (ecosim QG-1..3, MU-QG) proves the WIRING, that
# bond-xctl really executes $QUIESCE_CHECK and that bondctl's exit follows. Only
# here does a $P5_ROOT tree with real rc.d flags and a real sqm file exist, so
# only here can WHAT the predicate asks be measured.
#
# EVERY TOOL IS INJECTED, and that is the bar as much as the fixture. busybox
# ash runs its own applet for an applet name and never consults PATH (U67b/U69),
# so a PATH shim shims nothing on the interpreter the router runs; P5_UBUS /
# P5_PGREP / P5_WG are variables for the same reason IP/PING are in the
# reconciler. It is also what makes QG-E6 possible: under a test root an
# UNINJECTED tool must FIRE its term, so no fixture can ever reach exit 0 by
# absence -- the failure mode a probe of this shape is most likely to have.
QGB="$TMPBASE/qgbin"
mkdir -p "$QGB"
# wg shims. `wg show <dev> endpoints` prints "<pubkey>\t<endpoint>"; the
# predicate reads field 2 of the first line.
QGPUB='3dPZvuL2ZCDKx35M5wp3i/WLgWbhSKB5VeZ6hypkKiU='
for _qg in "wg-old 127.0.0.1:59401" "wg-p5 127.0.0.1:59402" \
           "wg-ip 203.0.113.9:51820" "wg-host oldclient.example:51820"; do
    _qgn=${_qg%% *}; _qge=${_qg#* }
    printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "%s" "%s"\nexit 0\n' "$QGPUB" "$_qge" > "$QGB/$_qgn"
    chmod +x "$QGB/$_qgn"
done
# ubus: a service table with nothing of the old stack in it.
printf '#!/bin/sh\nprintf "{ }\\n"\nexit 0\n' > "$QGB/ubus-empty"
# pgrep: nothing matches / one worker under /root/cake-autorate/ matches. The
# second is the UU-2 case -- a supervisor outside procd keeping a binary alive
# that the service table has never heard of.
printf '#!/bin/sh\nexit 1\n' > "$QGB/pgrep-none"
cat > "$QGB/pgrep-car" <<'QGPGEOF'
#!/bin/sh
# pgrep -f <pattern>. Only the cake-autorate worker directory matches, so the
# bar asserts the DERIVED pattern set reaches it, not that the shim says yes.
for a in "$@"; do
    case "$a" in /root/cake-autorate/) echo 6564; exit 0 ;; esac
done
exit 1
QGPGEOF
chmod +x "$QGB/ubus-empty" "$QGB/pgrep-none" "$QGB/pgrep-car"
# wg shims that are PERFECTLY USABLE and still do not answer -- QG-E8's arms,
# and the shape of the fail-open the adjudicator found: `wg show DEV endpoints`
# exits 1 with no output when the device is absent (a wrong /etc/p5/wg_if, the
# tunnel not up yet) or when wg has no netlink rights, and it can exit 0 with no
# output on a device that has no peer. QG-E6's arm is the tool MISSING; these
# two are the tool PRESENT and silent, which `command -v` cannot tell apart.
printf '#!/bin/sh\nexit 1\n' > "$QGB/wg-fail"
printf '#!/bin/sh\nexit 0\n' > "$QGB/wg-silent"
chmod +x "$QGB/wg-fail" "$QGB/wg-silent"

# qgsweep ROOT -- clear the fixture's rc.d flags. It asserts the root is INSIDE
# this run's scratch directory BEFORE it unlinks anything: `$OR/etc/rc.d/*` with
# $OR empty is the ABSOLUTE path /etc/rc.d/*, and a harness that is safe only by
# accident is not safe (RULE ZERO, docs/knowledge/root-causes/
# 2026-09-03-bin-deletion.md). One regular file at a time, never a tree.
qgsweep() {
    case "$1" in
        "$TMPBASE"/?*) : ;;
        *) bad "QG-SWEEP" "refusing to sweep '$1': not under this run's scratch root"; return 1 ;;
    esac
    for _qgf in "$1"/etc/rc.d/*; do
        [ -f "$_qgf" ] || continue
        rm -f "$_qgf"
    done
    return 0
}

# quiesc ROOT WG PGREP -- run the SHIPPED verb, all three tools injected.
# WG or PGREP given as "-" means DO NOT INJECT that one (QG-E6's arm).
quiesc() {
    _qr="$1"; _qw="$2"; _qp="$3"
    if [ "$_qw" = - ]; then unset P5_WG; else P5_WG="$QGB/$_qw"; export P5_WG; fi
    if [ "$_qp" = - ]; then unset P5_PGREP; else P5_PGREP="$QGB/$_qp"; export P5_PGREP; fi
    P5_UBUS="$QGB/ubus-empty"; export P5_UBUS
    P5_ROOT="$_qr" sh "$BIN/p5-uninstall" --quiescent >"$TMPBASE/qg.out" 2>"$TMPBASE/qg.err"
    _qrc=$?
    unset P5_WG P5_PGREP P5_UBUS
    return $_qrc
}

# QG-E1: A NON-QUIESCENT BOX IS REFUSED, AND THE SINGLE-DIGIT FLAG IS NAMED.
# The root carries the old stack with its flags, including the K4 the client
# actually has. Nothing is running and the endpoint is a direct IP, so the ONLY
# terms that may fire are flags -- which is what makes the K4 assertion sharp:
# if the widened glob did not reach it, this bar still exits 1 on S50/K50 and
# only the named-path check catches the defect. Both are asserted.
mkoldroot oldqg1
quiesc "$OR" wg-ip pgrep-none; rc=$?
a=0
grep -q '^NOT QUIESCENT: flags /etc/rc.d/K4cake-autorate ' "$TMPBASE/qg.out" || { a=1; echo "  the SINGLE-DIGIT flag /etc/rc.d/K4cake-autorate was not named"; }
grep -q '^NOT QUIESCENT: flags /etc/rc.d/S97cake-autorate ' "$TMPBASE/qg.out" || { a=1; echo "  /etc/rc.d/S97cake-autorate was not named"; }
grep -q '^NOT QUIESCENT: flags /etc/rc.d/S50engarde-client ' "$TMPBASE/qg.out" || { a=1; echo "  /etc/rc.d/S50engarde-client was not named"; }
grep -q '^remedy: p5-uninstall --switch-off --role client$' "$TMPBASE/qg.out" || { a=1; echo "  the output carries no remedy line"; }
grep -q '^NOT QUIESCENT: endpoint ' "$TMPBASE/qg.out" && { a=1; echo "  the endpoint term fired on a DIRECT IP endpoint -- the term is '== the old socket', not '== live_direct'"; }
grep -q '^NOT QUIESCENT: running ' "$TMPBASE/qg.out" && { a=1; echo "  a running term fired with an empty service table and no matching worker"; }
qg1n=$(grep -c '^NOT QUIESCENT: flags ' "$TMPBASE/qg.out" 2>/dev/null); [ -n "$qg1n" ] || qg1n=0
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-E1" "a box carrying the old stack's rc.d flags is NOT QUIESCENT (rc=$rc): all $qg1n flags are named one by one INCLUDING the single-digit /etc/rc.d/K4cake-autorate the two-digit glob could not see, the remedy names the verb that fixes it, and neither the endpoint nor the running term fired on a direct IP with an empty service table"

# QG-E2 CONTROL: THE SAME ROOT, SWEPT BY THE SHIPPED REMOVAL, IS QUIESCENT.
# Without this QG-E1 is indistinguishable from a predicate that can only say no.
# The sweep is the product's own --purge, not `rm` in this harness, so the bar
# also measures that the WIDENED sweep reaches the flag the WIDENED probe found:
# a probe that saw K4 and a sweep that did not would leave the operator with a
# gate that never goes green.
mkmgmt "$OR" client none
unin "$OR" --purge --role client; prc=$?
quiesc "$OR" wg-ip pgrep-none; rc=$?
a=0
[ "$prc" = 0 ] || { a=1; echo "  the purge itself did not succeed (rc=$prc)"; }
qg2n=$(grep -c '^NOT QUIESCENT' "$TMPBASE/qg.out" 2>/dev/null); [ -n "$qg2n" ] || qg2n=0
[ "$qg2n" = 0 ] || { a=1; echo "  terms still firing after the sweep:"; sed 's/^/    /' "$TMPBASE/qg.out"; }
[ -e "$OR/etc/rc.d/K4cake-autorate" ] && { a=1; echo "  the shipped sweep left /etc/rc.d/K4cake-autorate behind"; }
chk "$(yn "$([ "$rc" = 0 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-E2" "CONTROL: after the SHIPPED removal swept that same root the predicate says QUIESCENT (rc=$rc, $qg2n terms) and the single-digit K4 flag is gone -- the probe and the sweep were widened together, and QG-E1 is a refusal rather than a predicate that cannot pass"

# QG-E3: A WORKER NOTHING SUPERVISES STILL FIRES. procd's service table is
# empty here; the only thing that says the old shaper is alive is the worker
# argv, which is UU-2 -- a supervisor outside procd (cron, rc.local, a hand
# started shell). The pattern set is DERIVED from the `dir` rows under /root/,
# so the bar also proves the derivation reaches this path.
mkoldroot oldqg3
qgsweep "$OR"
quiesc "$OR" wg-ip pgrep-car; rc=$?
a=0
grep -q '^NOT QUIESCENT: running /root/cake-autorate/ (pid 6564)$' "$TMPBASE/qg.out" || { a=1; echo "  the worker term did not name the derived pattern and the pid"; }
grep -q '^NOT QUIESCENT: flags ' "$TMPBASE/qg.out" && { a=1; echo "  a flag term fired on a root whose rc.d is empty"; }
chk "$(yn "$([ "$rc" = 1 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-E3" "on a flag-swept root a worker alive under NO supervisor procd knows about still refuses the switch (rc=$rc): the term names the derived argv pattern /root/cake-autorate/ and the pid, so the probe does not depend on the service table being honest"

# QG-E4: THE ENDPOINT TERM IS '== THE OLD LOCAL SOCKET', NOT '== live_direct'.
# The client's uci end_point is a DDNS HOSTNAME while `wg show endpoints` prints
# the RESOLVED IP (inventory :198 vs :192), so an equality against live_direct
# is unimplementable on this box -- and it would ALSO be wrong after the switch,
# when the endpoint is P5's own 127.0.0.1:59402. Three endpoints, one root.
mkoldroot oldqg4
qgsweep "$OR"
quiesc "$OR" wg-old  pgrep-none; rc_old=$?
grep -q "^NOT QUIESCENT: endpoint wgclient1 is still 127.0.0.1:59401 " "$TMPBASE/qg.out" && e_named=0 || e_named=1
quiesc "$OR" wg-p5   pgrep-none; rc_p5=$?
quiesc "$OR" wg-host pgrep-none; rc_host=$?
quiesc "$OR" wg-ip   pgrep-none; rc_ip=$?
chk "$(yn "$([ "$rc_old" = 1 ] && [ "$e_named" = 0 ] && [ "$rc_p5" = 0 ] && [ "$rc_host" = 0 ] && [ "$rc_ip" = 0 ]; echo $?)")" \
    "QG-E4" "the endpoint term fires on the OLD LOCAL SOCKET and on nothing else: 127.0.0.1:59401 -> rc=$rc_old naming it, P5's own 127.0.0.1:59402 -> rc=$rc_p5, a DDNS hostname (oldclient.example:51820 -- the client's real one is in the inventory under docs/ and stays there) -> rc=$rc_host and the resolved IP 203.0.113.9:51820 -> rc=$rc_ip. A '== live_direct' spelling would refuse all three of the passing cases"

# QG-E5: NATIVE SQM IS A WARN LINE AND NEVER A TERM (R2/INV8). GL's own queue on
# the tunnel iface blocks P5 from attaching its qdisc (xctl-shape.sh refuses
# while an enabled queue names the tunnel), so the operator has to be told -- but
# shaping must never refuse the tunnel, so it must not gate the switch. The
# fixture is the client's own object: section eth1, interface wgclient1,
# enabled 1.
mkoldroot oldqg5
qgsweep "$OR"
cat > "$OR/etc/config/sqm" <<'QGSQMEOF'
config queue 'eth1'
	option interface 'wgclient1'
	option qdisc 'cake'
	option enabled '1'
QGSQMEOF
quiesc "$OR" wg-ip pgrep-none; rc=$?
grep -q '^WARN: a native sqm queue is ENABLED on wgclient1' "$TMPBASE/qg.out" && w=0 || w=1
# CONTROL, in the same bar: the same object with enabled 0 must print NO warning,
# or the "warning" is a line the parser prints unconditionally.
cat > "$OR/etc/config/sqm" <<'QGSQM0EOF'
config queue 'eth1'
	option interface 'wgclient1'
	option qdisc 'cake'
	option enabled '0'
QGSQM0EOF
quiesc "$OR" wg-ip pgrep-none; rc0=$?
grep -q '^WARN: a native sqm queue is ENABLED' "$TMPBASE/qg.out" && w0=1 || w0=0
chk "$(yn "$([ "$rc" = 0 ] && [ "$w" = 0 ] && [ "$rc0" = 0 ] && [ "$w0" = 0 ]; echo $?)")" \
    "QG-E5" "an ENABLED native sqm queue on the tunnel iface prints a WARN line and still exits 0 (rc=$rc) -- it is not a quiescence term -- and with the same object DISABLED the warning is absent (rc=$rc0), so the line is a measurement and not a constant"

# QG-E6: NO PASS BY ABSENCE. This is the failure mode a probe of this shape
# actually has: the tool it asks with is missing, it finds nothing, and it
# reports a quiet box. Under a test root an UNINJECTED tool must FIRE its term.
# The root here is otherwise perfectly quiescent, so the ONLY thing that can
# make it exit 1 is the missing tool.
mkoldroot oldqg6
qgsweep "$OR"
quiesc "$OR" - pgrep-none; rc_wg=$?
grep -q '^NOT QUIESCENT: endpoint UNREADABLE' "$TMPBASE/qg.out" && a=0 || { a=1; echo "  an uninjected P5_WG did not fire the endpoint term as UNREADABLE"; }
quiesc "$OR" wg-ip -; rc_pg=$?
grep -q '^NOT QUIESCENT: running UNREADABLE' "$TMPBASE/qg.out" || { a=1; echo "  an uninjected P5_PGREP did not fire the running term as UNREADABLE"; }
quiesc "$OR" wg-ip pgrep-none; rc_both=$?
chk "$(yn "$([ "$rc_wg" = 1 ] && [ "$rc_pg" = 1 ] && [ "$rc_both" = 0 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-E6" "a term whose tool is not usable FIRES instead of passing: P5_WG unset -> rc=$rc_wg 'endpoint UNREADABLE', P5_PGREP unset -> rc=$rc_pg 'running UNREADABLE', and the SAME root with both injected -> rc=$rc_both. No fixture reaches exit 0 by absence"

# QG-E8: A USABLE TOOL THAT DOES NOT ANSWER IS ALSO NOT A PASS. QG-E6 covers the
# tool being ABSENT, which `command -v` can see. This is the case it cannot: wg
# is present and executable and still returns nothing -- `wg show DEV endpoints`
# exits 1 with no output when the device is absent (a wrong /etc/p5/wg_if, the
# tunnel not up yet) or when wg has no netlink rights, and it can exit 0 with no
# output on a device carrying no peer. The first shipped spelling read the
# ENDPOINT out of a pipeline and never wg's own status, so an unanswered probe
# compared unequal to the old socket and the verb exited 0 QUIESCENT: a
# fail-open in the one term that decides whether the operator may switch. The
# root is otherwise perfectly quiescent (QG-E6's rc_both arm proves it exits 0
# with a usable wg), so the ONLY thing that can make these two arms exit 1 is
# the silent tool.
mkoldroot oldqg8
qgsweep "$OR"
a=0
quiesc "$OR" wg-fail pgrep-none; rc_f=$?
grep -q '^NOT QUIESCENT: endpoint UNREADABLE .*exited 1' "$TMPBASE/qg.out" || { a=1; echo "  a wg that EXITED 1 with no output did not fire the endpoint term as UNREADABLE"; sed 's/^/    /' "$TMPBASE/qg.out"; }
quiesc "$OR" wg-silent pgrep-none; rc_s=$?
grep -q '^NOT QUIESCENT: endpoint UNREADABLE .*named no peer endpoint' "$TMPBASE/qg.out" || { a=1; echo "  a wg that exited 0 printing NOTHING did not fire the endpoint term as UNREADABLE"; sed 's/^/    /' "$TMPBASE/qg.out"; }
# CONTROL, same root, same shims directory: a wg that ANSWERS with a direct IP
# still passes, so this bar is a refusal and not a predicate that cannot pass.
quiesc "$OR" wg-ip pgrep-none; rc_ok=$?
chk "$(yn "$([ "$rc_f" = 1 ] && [ "$rc_s" = 1 ] && [ "$rc_ok" = 0 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-E8" "a wg that is USABLE but does not answer FIRES the endpoint term instead of passing: exit 1 with no output -> rc=$rc_f 'endpoint UNREADABLE ... exited 1', exit 0 with no output -> rc=$rc_s 'named no peer endpoint', and the SAME root with a wg that answers a direct IP -> rc=$rc_ok. The status read is wg's own, not the pipeline's"

# QG-E7: THE GUARD IS ON THE TWO EDGES THAT BRING P5 UP, AND ON NO OTHER.
# A quiescence guard on `disengage` (the way back to off) or on `suspend` (the
# failure escape) would TRAP a box whose old stack came half-alive -- the exact
# failure this gate exists to prevent. Read out of the shipped table by FIELD,
# so it does not depend on the guard list's order or spelling.
DAGF="$(cd "$P5DIR/.." && pwd)/deploy/p5/bond.dag"
qg7_bad=0
for _r in engage switch; do
    awk -F'|' -v r="$_r" '!/^#/ && NF>=8 && $1==r {print $4}' "$DAGF" | grep -q 'old_quiescent' \
        || { qg7_bad=1; echo "  the $_r row does not carry old_quiescent"; }
done
for _r in disengage suspend; do
    awk -F'|' -v r="$_r" '!/^#/ && NF>=8 && $1==r {print $4}' "$DAGF" | grep -q 'old_quiescent' \
        && { qg7_bad=1; echo "  the $_r row CARRIES old_quiescent -- a half-alive old stack would trap the box"; }
done
qg7_rows=$(awk -F'|' '!/^#/ && NF>=8 {print $1}' "$DAGF" | grep -c . )
chk "$(yn "$([ "$qg7_bad" = 0 ] && [ "$qg7_rows" -ge 4 ]; echo $?)")" \
    "QG-E7" "over all $qg7_rows rows of the shipped bond.dag the old_quiescent guard is on engage and on switch and on NEITHER disengage NOR suspend: the way back to off and the failure escape stay walkable while the old stack is alive"

# QG-10: THE VERB TAKES NO ROLE AND NEEDS NO INSTALL STAMP, AND ITS EXIT IS ONLY
# EVER 0 OR 1. The reconciler treats ANY non-zero as a refusal, so an exit that
# means "usage" (2) or "precondition" (5) would read as "not quiescent" forever
# and no operator action could clear it. Run from BOTH contract shapes, because
# the two are different code paths in this file's preamble: from the PACKAGE
# (p5/contract/paths beside the bin) on a bare root, and from the INSTALLED BOX
# ($P5_ROOT/usr/lib/p5/contract-paths, prefix contract-) after a real install.
RQG=$TMPBASE/rqg
mkdir -p "$RQG"
quiesc "$RQG" wg-ip pgrep-none; rc_pkg=$?
quiesc "$RQG" - -;               rc_pkg_bare=$?
PQG=$TMPBASE/pkgqg; mkpkg "$PQG" </dev/null
RQG2=$TMPBASE/rqg2
inst "$RQG2" "$PQG" client; irc=$?
P5_ROOT="$RQG2" P5_UBUS="$QGB/ubus-empty" P5_PGREP="$QGB/pgrep-none" P5_WG="$QGB/wg-ip" \
    sh "$RQG2/usr/sbin/p5-uninstall" --quiescent >"$TMPBASE/qgbox.out" 2>"$TMPBASE/qgbox.err"
rc_box=$?
a=0
[ "$irc" = 0 ] || { a=1; echo "  the install this arm needs did not succeed (rc=$irc)"; }
[ -r "$RQG2/usr/lib/p5/contract-paths" ] || { a=1; echo "  the installed arm has no /usr/lib/p5/contract-paths, so it did not exercise the box shape"; }
grep -q 'no --role was given' "$TMPBASE/qg.err" "$TMPBASE/qgbox.err" 2>/dev/null && { a=1; echo "  the verb demanded a --role"; }
chk "$(yn "$([ "$rc_pkg" = 0 ] && [ "$rc_pkg_bare" = 1 ] && [ "$rc_box" = 0 ] && [ "$a" = 0 ]; echo $?)")" \
    "QG-10" "\`--quiescent\` consumes no --role and no install stamp, and exits 0 or 1 and never 2 or 5: from the PACKAGE contract on a bare root rc=$rc_pkg (and rc=$rc_pkg_bare with the tools withheld), and from the INSTALLED box's own /usr/lib/p5/contract-* copies rc=$rc_box"

# QS-LIT: THE SET IS DERIVED, NOT TYPED, AND THE PROBE EXECUTES NOTHING.
# A second hand-kept list is how a gate goes vacuous one rename at a time: the
# services would be renamed in p5_old_rows and the probe would keep asking about
# names that no longer exist, green forever. And U153 is the other half -- the
# probe reads the rc.d FLAG rather than running `/etc/init.d/<svc> enabled`,
# because a pre-switch gate must not execute an old init script as root to find
# out whether it is enabled.
awk '/^p5_old_quiescent\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$LIB/p5-common.sh" > "$TMPBASE/qsfn"
qs_lines=$(grep -c . "$TMPBASE/qsfn" 2>/dev/null); [ -n "$qs_lines" ] || qs_lines=0
qs_lit=$(grep -cE 'engarde|cake-autorate|bond-ecod|bond-agg|bond-watchdog|bondctl|autoratectl' "$TMPBASE/qsfn" 2>/dev/null); [ -n "$qs_lit" ] || qs_lit=0
qs_ini=$(grep -c '/etc/init.d/' "$TMPBASE/qsfn" 2>/dev/null); [ -n "$qs_ini" ] || qs_ini=0
qs_der=$(grep -c 'p5_old_rows' "$TMPBASE/qsfn" 2>/dev/null); [ -n "$qs_der" ] || qs_der=0
a=0
[ "$qs_lines" -gt 10 ] || { a=1; echo "  p5_old_quiescent was not extracted (only $qs_lines lines) -- this bar is not measuring anything"; }
[ "$qs_lit" = 0 ] || { a=1; echo "  the probe carries $qs_lit old-stack service literal(s):"; grep -nE 'engarde|cake-autorate|bond-ecod|bond-agg|bond-watchdog|bondctl|autoratectl' "$TMPBASE/qsfn" | sed 's/^/    /'; }
[ "$qs_ini" = 0 ] || { a=1; echo "  the probe names /etc/init.d/ $qs_ini time(s) -- it must read the flag, never execute the script (U153)"; }
[ "$qs_der" -ge 1 ] || { a=1; echo "  the probe never calls p5_old_rows, so its set is not derived"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "QS-LIT" "the $qs_lines-line p5_old_quiescent contains ZERO old-stack service literals and ZERO /etc/init.d/ references, and derives its service and worker sets from p5_old_rows ($qs_der call(s)): renaming a service in the derivation moves the probe with it, and the probe never executes an old init script as root to learn whether it is enabled"

# ===========================================================================
# SO / RO / PIN-ROWS (U209) -- THE UNINSTALLER VERB SPLIT
# ===========================================================================
# G2 made executable. Switching the old stack OFF and REMOVING it are two verbs
# taken at two moments with P5's whole install, switch-on and soak in between, so
# each has to be measured for what it does AND for what it does NOT do:
#
#   SO-*  --switch-off UNLINKS NOTHING AND MOVES NOTHING (the only paths it
#         removes are rc.d boot flags), leaves the box QUIESCENT by the shipped
#         predicate, and prints a rollback block naming ONLY the restore verbs it
#         actually ran -- the switchback that re-enables the whole list is design
#         section 7 must-not 17.
#   RO-*  --remove-old refuses a non-quiescent box and an incomplete P5 box,
#         EXECUTES NOTHING of the old stack, and finishes the job when it may.
#   RO-5  neither verb runs an old restore step against an ENGAGED P5, because
#         `<tool> off` ends in apply_endpoint live_direct and would re-point a
#         live P5 tunnel (must-not 11).
#   PIN-ROWS  the seven /root/cake-autorate `file` rows ARE the pin's FILES
#         block, both directions -- a set equality, so a pin that gains or loses
#         a file makes the removal list wrong LOUDLY instead of quietly.
#
# EVERY TOOL IS INJECTED HERE for the same reason the QG block injects them: the
# two new verbs consult p5_old_quiescent, which is fail-closed on an uninjected
# tool under a test root (QG-E6), so a fixture that did not inject would be
# measuring the injection rule instead of the verb.
oldv() {   # oldv ROOT WGSHIM args... -- an old-stack verb, all three tools injected
    _ov_r="$1"; _ov_w="$2"; shift 2
    P5_ROOT="$_ov_r" PATH="$RMSHIM:$PATH" \
        P5_WG="$QGB/$_ov_w" P5_PGREP="$QGB/pgrep-none" P5_UBUS="$QGB/ubus-empty" \
        sh "$BIN/p5-uninstall" "$@" >"$TMPBASE/uout" 2>"$TMPBASE/uerr"
}

# oldsnap ROOT OUT SKIPFLAGS -- a sha256 manifest of every regular file under
# ROOT, so "nothing was unlinked or moved" is a byte comparison and not a
# presence count. The harness's own scratch is excluded (the management report
# under /tmp and the revert stub's call log); SKIPFLAGS=1 also excludes
# /etc/rc.d, which --switch-off is SUPPOSED to sweep.
oldsnap() {
    ( cd "$1" 2>/dev/null || exit 0
      if [ "$3" = 1 ]; then
          find . -type f ! -path './etc/rc.d/*' ! -path './tmp/*' ! -name 'revert-calls'
      else
          find . -type f ! -path './tmp/*' ! -name 'revert-calls'
      fi | LC_ALL=C sort | xargs sha256sum ) > "$2" 2>/dev/null
    return 0
}

# oldblock -- the rollback block's COMMAND lines, from the last oldv's stdout.
oldblock() {
    sed -n '/^# ---- ROLLBACK BLOCK/,/^# ---- end of rollback block/p' "$TMPBASE/uout" \
        | grep -v '^#'
}

# SO-1: --switch-off UNLINKS NOTHING AND MOVES NOTHING, and the whole old stack
# is still there afterwards byte for byte. That is the property the deploy order
# rests on: P5 is installed ALONGSIDE a stack that is off but intact, so the way
# back is two commands rather than a re-install.
mkoldroot so1
mkmgmt "$OR" client none
oldsnap "$OR" "$TMPBASE/so1.before" 1
oldv "$OR" wg-ip --switch-off --role client; so1rc=$?
oldsnap "$OR" "$TMPBASE/so1.after" 1
a=0
[ "$so1rc" = 0 ] || { a=1; echo "  --switch-off exited $so1rc, not 0"; }
if ! cmp -s "$TMPBASE/so1.before" "$TMPBASE/so1.after"; then
    a=1; echo "  --switch-off changed the tree outside /etc/rc.d:"
    diff "$TMPBASE/so1.before" "$TMPBASE/so1.after" 2>/dev/null | sed 's/^/    /' | head -20
fi
so1files=$(grep -c . "$TMPBASE/so1.before" 2>/dev/null); [ -n "$so1files" ] || so1files=0
[ "$so1files" -gt 20 ] || { a=1; echo "  the snapshot covered only $so1files files -- this bar is not measuring a tree"; }
so1flags=0
for _f in "$OR"/etc/rc.d/*; do
    [ -e "$_f" ] || continue
    case "${_f##*/}" in [SK][0-9]*sqm) continue ;; esac
    so1flags=$((so1flags + 1)); echo "  rc.d flag survived the switch-off: ${_f##*/}"
done
[ "$so1flags" = 0 ] || a=1
[ -e "$OR/etc/rc.d/K4cake-autorate" ] && { a=1; echo "  the SINGLE-DIGIT K4cake-autorate survived"; }
so1calls=$(grep -c . "$OR/revert-calls" 2>/dev/null); [ -n "$so1calls" ] || so1calls=0
so1off=$(grep -cx 'off' "$OR/revert-calls" 2>/dev/null); [ -n "$so1off" ] || so1off=0
[ "$so1calls" = 2 ] && [ "$so1off" = 2 ] || { a=1; echo "  the run invoked $so1calls revert(s), $so1off of them as 'off' -- expected 2 and 2"; }
oldblock > "$TMPBASE/so1.block"
so1n=$(grep -c . "$TMPBASE/so1.block" 2>/dev/null); [ -n "$so1n" ] || so1n=0
[ "$so1n" = 2 ] || { a=1; echo "  the rollback block has $so1n line(s), not 2:"; sed 's/^/    /' "$TMPBASE/so1.block"; }
[ "$(head -1 "$TMPBASE/so1.block")" = "/root/autoratectl on" ] \
    || { a=1; echo "  the block does not start with the LAST revert executed"; }
[ "$(tail -1 "$TMPBASE/so1.block")" = "/usr/sbin/bondctl on" ] \
    || { a=1; echo "  the block does not end with the FIRST revert executed"; }
so1tok=$(grep -cE '^(OLDQUAR|OLDDROP|OLDFILE|OLDMEMBER|OLDRMDIR|OLDUCI|REPORT)\|' "$TMPBASE/uout" 2>/dev/null)
[ -n "$so1tok" ] || so1tok=0
[ "$so1tok" = 0 ] || { a=1; echo "  the switch-off plan carries $so1tok unlink/move action(s):"; grep -E '^(OLDQUAR|OLDDROP|OLDFILE|OLDMEMBER|OLDRMDIR|OLDUCI|REPORT)\|' "$TMPBASE/uout" | sed 's/^/    /'; }
quiesc "$OR" wg-ip pgrep-none; so1q=$?
[ "$so1q" = 0 ] || { a=1; echo "  the box is NOT quiescent after --switch-off:"; sed 's/^/    /' "$TMPBASE/qg.out"; }
chk "$(yn "$([ "$a" = 0 ]; echo $?)")" \
    "SO-1" "--switch-off leaves all $so1files old-stack files byte-identical (sha256 manifest before == after, /etc/rc.d excluded), emits ZERO unlink or move actions, takes every boot flag including the single-digit K4cake-autorate, invokes $so1off restore verb(s) as 'off', prints a rollback block of exactly $so1n line(s) in reverse order of execution, and leaves the box QUIESCENT by the shipped predicate (rc=$so1rc, quiescent rc=$so1q)"

# SO-2: --dry-run changes NOTHING, and the revert set is decided PER ORIGIN.
# The two revert rows undo two different stacks, so residence is asked twice: a
# box whose bonding half is gone must still be offered `autoratectl off`, and a
# box whose shaping control plane is gone must still be offered `bondctl off`.
# One shared predicate would have made each one wrong on the other's box.
mkoldroot so2
mkmgmt "$OR" client none
oldsnap "$OR" "$TMPBASE/so2.before" 0
oldv "$OR" wg-ip --switch-off --role client --dry-run; so2rc=$?
oldsnap "$OR" "$TMPBASE/so2.after" 0
b=0
[ "$so2rc" = 0 ] || { b=1; echo "  --switch-off --dry-run exited $so2rc, not 0"; }
cmp -s "$TMPBASE/so2.before" "$TMPBASE/so2.after" || { b=1; echo "  --dry-run changed the tree:"; diff "$TMPBASE/so2.before" "$TMPBASE/so2.after" | sed 's/^/    /' | head; }
[ -e "$OR/revert-calls" ] && { b=1; echo "  --dry-run actually RAN a revert"; }
[ -e "$OR/etc/rc.d/K4cake-autorate" ] || { b=1; echo "  --dry-run removed an rc.d flag"; }
so2first=$(grep -E '^OLD[A-Z]+\|' "$TMPBASE/uout" | head -1)
[ "$so2first" = "OLDREVERT|/usr/sbin/bondctl" ] || { b=1; echo "  the first planned action is not the bonding restore: '$so2first'"; }
# P1 ONLY: every probe of old_bonding_resident removed.
mkoldroot so2b
mkmgmt "$OR" client none
rm -f "$OR/usr/sbin/bondctl" "$OR/usr/sbin/engarde-client" "$OR/etc/init.d/engarde-client"
rm -f "$OR"/etc/bond/*
rmdir "$OR/etc/bond" 2>/dev/null
oldv "$OR" wg-ip --switch-off --role client --dry-run; so2brc=$?
grep -q '^OLDREVERT|/root/autoratectl$'  "$TMPBASE/uout" || { b=1; echo "  P1-only root: the autoratectl restore was not planned"; }
grep -q '^OLDREVERT|/usr/sbin/bondctl$'  "$TMPBASE/uout" && { b=1; echo "  P1-only root: a bonding restore was planned with no bonding stack on the box"; }
# P2/P3 ONLY: every probe of old_p1_resident removed.
mkoldroot so2c
mkmgmt "$OR" client none
rm -f "$OR/etc/init.d/cake-autorate" "$OR/root/autoratectl"
rm -f "$OR"/etc/rc.d/[SK]*cake-autorate
oldv "$OR" wg-ip --switch-off --role client --dry-run; so2crc=$?
grep -q '^OLDREVERT|/usr/sbin/bondctl$' "$TMPBASE/uout" || { b=1; echo "  P2/P3-only root: the bonding restore was not planned"; }
grep -q '^OLDREVERT|/root/autoratectl$' "$TMPBASE/uout" && { b=1; echo "  P2/P3-only root: the shaping restore was planned with no shaping control plane on the box"; }
chk "$(yn "$([ "$b" = 0 ]; echo $?)")" \
    "SO-2" "--switch-off --dry-run prints the plan and changes not one byte (rc=$so2rc, sha256 manifest identical INCLUDING /etc/rc.d, no revert ran), plans the bonding restore FIRST ('$so2first'), and residence is asked PER ORIGIN: a root with no bonding half plans autoratectl and not bondctl (rc=$so2brc), a root with no shaping control plane plans bondctl and not autoratectl (rc=$so2crc)"

# SO-3: THE SWITCHBACK NAMES ONLY WHAT WAS REVERTED (must-not 17). A block built
# from the row list instead of from the record would tell the operator to switch
# on a half of the stack this box does not have, and to `enable` services this
# run never disabled -- so the fixture removes the bonding half AND pre-disables
# one service, and neither may appear.
mkoldroot so3
mkmgmt "$OR" client none
rm -f "$OR/usr/sbin/bondctl" "$OR/usr/sbin/engarde-client" "$OR/etc/init.d/engarde-client"
rm -f "$OR"/etc/bond/*
rmdir "$OR/etc/bond" 2>/dev/null
rm -f "$OR/etc/rc.d/S50bond-agg" "$OR/etc/rc.d/K50bond-agg"
oldv "$OR" wg-ip --switch-off --role client; so3rc=$?
oldblock > "$TMPBASE/so3.block"
c=0
so3n=$(grep -c . "$TMPBASE/so3.block" 2>/dev/null); [ -n "$so3n" ] || so3n=0
[ "$so3n" = 1 ] || { c=1; echo "  the block has $so3n line(s), not 1:"; sed 's/^/    /' "$TMPBASE/so3.block"; }
[ "$(cat "$TMPBASE/so3.block")" = "/root/autoratectl on" ] || { c=1; echo "  the block does not name the one revert that ran"; }
grep -q 'bondctl' "$TMPBASE/so3.block" && { c=1; echo "  the block names a revert this box could not run"; }
grep -q 'enable' "$TMPBASE/so3.block" && { c=1; echo "  the block re-enables a service by name -- '<tool> on' is the old package's own verb and does that itself"; }
grep -q 'bond-agg' "$TMPBASE/so3.block" && { c=1; echo "  the block names the service that was ALREADY disabled before the run"; }
so3calls=$(grep -c . "$OR/revert-calls" 2>/dev/null); [ -n "$so3calls" ] || so3calls=0
[ "$so3calls" = 1 ] || { c=1; echo "  $so3calls revert(s) ran on a root with only the shaping half"; }
[ -f "$OR/etc/init.d/bond-agg" ] || { c=1; echo "  the pre-disabled service's init script was unlinked by --switch-off"; }
chk "$(yn "$([ "$c" = 0 ]; echo $?)")" \
    "SO-3" "the rollback block is RECORD-DRIVEN, not the row list: on a root carrying only the shaping half and with one service already disabled before the run, --switch-off (rc=$so3rc) runs $so3calls restore verb and the block is exactly that one line -- no bondctl the box could not have reverted, no 'enable' for a service '<tool> on' re-enables itself, and nothing for the service that was already off"

# SO-4: A RESUMED SWITCH-OFF THAT STOPS AGAIN STILL HANDS BACK THE REVERTS THE
# FIRST RUN RAN. $OLDREVDONE holds only what THIS process invoked, and a resumed
# run SKIPS every revert the progress record calls done (purge_record_done), so
# for those the executor's append never fires. The fold that reads them back sat
# where the plan RAN OUT -- and a run that STOPS part way returns before that
# line. So the second run printed an EMPTY block and then said, in as many
# words, that it had executed no restore verb, on a box whose WireGuard endpoint
# `bondctl off` had already moved back to the real server. One failing tool, two
# runs, and the SECOND run is the bar.
mkoldroot so4
mkmgmt "$OR" client none
# The SECOND revert row's tool FAILS. bondctl is planned first (SO-2), succeeds
# and is recorded `done|OLDREVERT`; autoratectl stops the run at rc 2 both times,
# which is what keeps run 2 on the stopped path instead of the cleared one.
printf '#!/bin/sh\necho "$*" >> "%s/revert-calls"\nexit 1\n' "$OR" > "$OR/root/autoratectl"
chmod +x "$OR/root/autoratectl"
oldv "$OR" wg-ip --switch-off --role client; so4r1=$?
oldblock > "$TMPBASE/so4.b1"
so4n1=$(grep -c . "$TMPBASE/so4.b1" 2>/dev/null); [ -n "$so4n1" ] || so4n1=0
oldv "$OR" wg-ip --switch-off --role client; so4r2=$?
oldblock > "$TMPBASE/so4.b2"
so4n2=$(grep -c . "$TMPBASE/so4.b2" 2>/dev/null); [ -n "$so4n2" ] || so4n2=0
j=0
[ "$so4r1" = 5 ] || { j=1; echo "  run 1 exited $so4r1, not 5 -- the failing revert did not stop it"; }
[ "$so4r2" = 5 ] || { j=1; echo "  run 2 exited $so4r2, not 5"; }
grep -q '^done|OLDREVERT|/usr/sbin/bondctl$' "$OR/var/run/p5/purge.inprogress" 2>/dev/null \
    || { j=1; echo "  run 1 left no record that the bonding restore step was taken, so run 2 is not the case this bar names"; }
grep -q 'already done by an earlier run' "$TMPBASE/uout" \
    || { j=1; echo "  run 2 never reported skipping a recorded action -- it did not resume"; }
so4calls=$(grep -cx 'off' "$OR/revert-calls" 2>/dev/null); [ -n "$so4calls" ] || so4calls=0
[ "$so4calls" = 3 ] || { j=1; echo "  the two runs invoked $so4calls 'off' verb(s), expected 3 (bondctl once, autoratectl twice)"; }
[ "$so4n1" = 1 ] || { j=1; echo "  run 1's block has $so4n1 line(s), not 1:"; sed 's/^/    /' "$TMPBASE/so4.b1"; }
[ "$so4n2" = 1 ] || { j=1; echo "  run 2's block has $so4n2 line(s), not 1 -- the resumed run dropped the revert its first run performed:"; sed 's/^/    /' "$TMPBASE/so4.b2"; }
[ "$(cat "$TMPBASE/so4.b2" 2>/dev/null)" = "/usr/sbin/bondctl on" ] \
    || { j=1; echo "  run 2's block does not name '/usr/sbin/bondctl on'"; }
grep -q 'rollback block is EMPTY' "$TMPBASE/uout" \
    && { j=1; echo "  run 2 told the operator no restore verb had run, on a box whose endpoint bondctl had already moved back"; }
chk "$(yn "$([ "$j" = 0 ]; echo $?)")" \
    "SO-4" "the rollback block survives a RESUME: with the second revert tool failing, run 1 stops (rc=$so4r1) after reverting bondctl and prints $so4n1 line, and run 2 -- which SKIPS that revert from the record and stops on the same tool (rc=$so4r2) -- still prints exactly $so4n2 line naming '/usr/sbin/bondctl on', with no claim that this run executed no restore verb. $so4calls 'off' invocations across the two runs, the recorded one never repeated"

# SO-5: THE OPERATOR-FACING REMEDY NAMES A VERB THAT MATCHES THE DEPLOY ORDER.
# `--check --scope old` is what an operator runs at the old stack before the
# switch, and it told them to run `--purge` -- the one verb CONTRACT.md section 4
# says the runbook must never use, and which on a pre-switch box would take the
# old stack out from under a P5 install that has not happened yet. The remedy is
# the two verbs, split by the moment; the pre-switch GATE is --quiescent, not
# this scope at all. Mechanical, because prose drifts: the only `--purge` this
# report may contain is the one telling the operator NOT to use it.
mkoldroot so5
unin "$OR" --check --scope old --role client; so5rc=$?
k5=0
[ "$so5rc" = 1 ] || { k5=1; echo "  --check --scope old on a dirty root exited $so5rc, not 1"; }
grep -qF 'old half: NOT CLEAN -- before the switch run --switch-off; after P5 is engaged run --remove-old' "$TMPBASE/uout" \
    || { k5=1; echo "  the remedy line is not the one the design assigns:"; grep -F 'old half:' "$TMPBASE/uout" | sed 's/^/    /'; }
grep -qF 'p5-uninstall --quiescent' "$TMPBASE/uout" \
    || { k5=1; echo "  the report never names the pre-switch gate"; }
grep -qF -- '--switch-off runs it' "$TMPBASE/uout" \
    || { k5=1; echo "  the restore-step line still credits another verb with running it first"; }
grep -F -- '--purge' "$TMPBASE/uout" > "$TMPBASE/so5.purge" 2>/dev/null
so5p=$(grep -c . "$TMPBASE/so5.purge" 2>/dev/null); [ -n "$so5p" ] || so5p=0
so5bad=$(grep -vc 'NOT --purge' "$TMPBASE/so5.purge" 2>/dev/null); [ -n "$so5bad" ] || so5bad=0
[ "$so5bad" = 0 ] || { k5=1; echo "  --check still sends the operator to --purge:"; grep -v 'NOT --purge' "$TMPBASE/so5.purge" | sed 's/^/    /'; }
chk "$(yn "$([ "$k5" = 0 ]; echo $?)")" \
    "SO-5" "--check --scope old (rc=$so5rc) tells the operator what the deploy order actually offers: 'before the switch run --switch-off; after P5 is engaged run --remove-old', names 'p5-uninstall --quiescent' as the pre-switch gate, credits --switch-off with running the restore step first, and of its $so5p line(s) mentioning --purge, $so5bad recommend it"

# RO-1: --remove-old REFUSES A BOX THAT IS NOT QUIESCENT, and refuses it whole.
# The whole point of the gate is that files are removed only once P5 is carrying
# the traffic; unlinking out from under a running stack leaves procd restarting a
# service whose script is gone.
mkoldroot ro1
mkmgmt "$OR" client none
oldsnap "$OR" "$TMPBASE/ro1.before" 0
oldv "$OR" wg-ip --remove-old --role client; ro1rc=$?
oldsnap "$OR" "$TMPBASE/ro1.after" 0
d=0
[ "$ro1rc" = 5 ] || { d=1; echo "  --remove-old on a live box exited $ro1rc, not 5"; }
cmp -s "$TMPBASE/ro1.before" "$TMPBASE/ro1.after" || { d=1; echo "  a refused --remove-old changed the tree:"; diff "$TMPBASE/ro1.before" "$TMPBASE/ro1.after" | sed 's/^/    /' | head; }
grep -q 'NOT QUIESCENT: flags /etc/rc.d/K4cake-autorate ' "$TMPBASE/uerr" || { d=1; echo "  the refusal did not print the predicate's own terms"; }
grep -q 'NOT QUIESCENT' "$TMPBASE/uerr" || d=1
grep -q 'REFUSING --remove-old' "$TMPBASE/uerr" || { d=1; echo "  the refusal did not name the verb"; }
[ -e "$OR/revert-calls" ] && { d=1; echo "  --remove-old invoked a revert tool"; }
chk "$(yn "$([ "$d" = 0 ]; echo $?)")" \
    "RO-1" "--remove-old on a box that is still live REFUSES whole (rc=$ro1rc): the sha256 manifest of the tree is identical before and after, no old-stack tool was invoked, and the refusal prints the quiescence predicate's own terms including the single-digit K4 flag"

# RO-2: AND THE SAME VERB FINISHES ONCE THE SWITCH-OFF HAS RUN. Without this
# RO-1 would pass on a verb that can only ever say no. Two quarantines now, not
# one: agg_w and Mo's own config.wg.sh, both moved aside and both byte-identical.
mkoldroot ro2
mkmgmt "$OR" client none
oldv "$OR" wg-ip --switch-off --role client; ro2src=$?
oldv "$OR" wg-ip --remove-old --role client; ro2rc=$?
oldleft "$OR" > "$TMPBASE/ro2surv"
ro2left=$(grep -c . "$TMPBASE/ro2surv" 2>/dev/null); [ -n "$ro2left" ] || ro2left=0
e=0
[ "$ro2src" = 0 ] || { e=1; echo "  the switch-off this bar depends on exited $ro2src"; }
[ "$ro2rc" = 0 ] || [ "$ro2rc" = 1 ] || { e=1; echo "  --remove-old exited $ro2rc, expected 0 or 1"; }
[ "$ro2left" = 0 ] || { e=1; echo "  declared old-stack artifacts survived:"; sed 's/^/    /' "$TMPBASE/ro2surv"; }
for _d in /etc/bond /root/cake-autorate /var/run/bond; do
    [ -d "$OR$_d" ] && { e=1; echo "  $_d was not emptied and removed"; }
done
ro2q=$(find "$OR" -name 'agg_w.*' -o -name 'config.wg.sh.*' 2>/dev/null | wc -l | tr -d " ")
[ "$ro2q" = 2 ] || { e=1; echo "  $ro2q quarantined file(s), expected 2 (agg_w and config.wg.sh)"; }
for _q in $(find "$OR" -name 'agg_w.*' -o -name 'config.wg.sh.*' 2>/dev/null); do
    grep -qxF "$AGGW_CANARY" "$_q" || { e=1; echo "  quarantined file is not byte-identical: $_q"; }
done
[ -e "$OR/root/cake-autorate/config.wg.sh" ] && { e=1; echo "  Mo's config.wg.sh is still in the tree the run removed"; }
chk "$(yn "$([ "$e" = 0 ]; echo $?)")" \
    "RO-2" "after --switch-off the SAME --remove-old finishes the job (rc=$ro2rc, $ro2left declared artifacts left): /etc/bond, /root/cake-autorate and /var/run/bond are emptied member by member and gone, and $ro2q files are QUARANTINED byte-identical rather than deleted -- agg_w and Mo's own config.wg.sh, which is the evidence for the shape_bounds fact P5's shaper needs"

# RO-3: --remove-old EXECUTES NOTHING OF THE OLD STACK. Asserted two ways,
# because a plan grep alone would not catch an arm that runs something the plan
# does not name: every declared init script AND every revert tool is replaced by
# a RECORDING stub before the verb runs, and the log must not exist afterwards.
mkoldroot ro3
mkmgmt "$OR" client none
oldv "$OR" wg-ip --switch-off --role client; ro3src=$?
rm -f "$OR/revert-calls"
while IFS='|' read -r _o _k _p _d; do
    case "$_o" in ''|\#*) continue ;; esac
    case "$_k" in svc|revert) : ;; *) continue ;; esac
    [ -f "$OR$_p" ] || continue
    printf '#!/bin/sh\necho "%s $*" >> "%s/exec-log"\nexit 0\n' "$_p" "$OR" > "$OR$_p"
    chmod +x "$OR$_p"
done < "$OLDROWS"
oldv "$OR" wg-ip --remove-old --role client; ro3rc=$?
f=0
[ "$ro3src" = 0 ] || { f=1; echo "  the switch-off this bar depends on exited $ro3src"; }
[ -e "$OR/exec-log" ] && { f=1; echo "  --remove-old EXECUTED an old-stack file: $(tr '\n' ' ' < "$OR/exec-log")"; }
ro3rev=$(grep -c '^OLDREVERT|' "$TMPBASE/uout" 2>/dev/null); [ -n "$ro3rev" ] || ro3rev=0
ro3svc=$(grep -c '^OLDSVC|'    "$TMPBASE/uout" 2>/dev/null); [ -n "$ro3svc" ] || ro3svc=0
[ "$ro3rev" = 0 ] || { f=1; echo "  the remove-old plan carries $ro3rev OLDREVERT action(s)"; }
[ "$ro3svc" = 0 ] || { f=1; echo "  the remove-old plan carries $ro3svc OLDSVC action(s)"; }
ro3drop=$(grep -c '^OLDDROP|' "$TMPBASE/uout" 2>/dev/null); [ -n "$ro3drop" ] || ro3drop=0
[ "$ro3drop" -gt 0 ] || { f=1; echo "  the remove-old plan unlinked no init script at all, so this bar has no subject"; }
chk "$(yn "$([ "$f" = 0 ]; echo $?)")" \
    "RO-3" "--remove-old runs NOTHING of the old stack (rc=$ro3rc): with every declared init script and every restore tool replaced by a recording stub the log is never written, and the plan carries $ro3rev OLDREVERT and $ro3svc OLDSVC actions while still unlinking $ro3drop init script(s) -- so the zero is a policy, not an empty plan"

# RO-4: AN INCOMPLETE P5 BOX IS NOT OPERATED ON. This verb removes the old stack
# on the strength of P5 having taken the traffic; a half-finished install or
# removal means it has not, and the record that says so is the only thing that
# can finish it.
mkoldroot ro4
mkmgmt "$OR" client none
oldv "$OR" wg-ip --switch-off --role client; ro4src=$?
mkdir -p "$OR/usr/lib/p5"
g=0
for _rec in install.inprogress remove.inprogress; do
    : > "$OR/usr/lib/p5/$_rec"
    oldsnap "$OR" "$TMPBASE/ro4.before" 0
    oldv "$OR" wg-ip --remove-old --role client; _rc=$?
    oldsnap "$OR" "$TMPBASE/ro4.after" 0
    [ "$_rc" = 5 ] || { g=1; echo "  with $_rec present --remove-old exited $_rc, not 5"; }
    cmp -s "$TMPBASE/ro4.before" "$TMPBASE/ro4.after" || { g=1; echo "  with $_rec present a refused --remove-old changed the tree"; }
    grep -q "$_rec" "$TMPBASE/uerr" || { g=1; echo "  the refusal did not name $_rec"; }
    rm -f "$OR/usr/lib/p5/$_rec"
done
# CONTROL: with neither record present the SAME verb on the SAME root proceeds.
oldv "$OR" wg-ip --remove-old --role client; ro4rc=$?
[ "$ro4src" = 0 ] || { g=1; echo "  the switch-off this bar depends on exited $ro4src"; }
[ "$ro4rc" = 0 ] || [ "$ro4rc" = 1 ] || { g=1; echo "  with both records cleared --remove-old still exited $ro4rc"; }
chk "$(yn "$([ "$g" = 0 ]; echo $?)")" \
    "RO-4" "--remove-old refuses while a P5 install or removal is unfinished: install.inprogress -> exit 5 naming it with the tree byte-identical, remove.inprogress -> the same, and with both cleared the SAME verb on the SAME root proceeds (rc=$ro4rc) -- a refusal, not a predicate that cannot pass"

# RO-5: NO OLD RESTORE VERB AGAINST AN ENGAGED P5 (must-not 11). `<tool> off`
# ends in apply_endpoint live_direct (p2-engarde/bondctl:263-269), so on an
# S3/S4 box it would re-point a LIVE P5 tunnel behind the reconciler's back.
# Two terms and a control: the intent fact `p5 on` writes, the live endpoint as a
# backstop for a box whose fact was removed by hand, and the same root with a
# direct endpoint and no fact going through.
mkoldroot ro5
mkmgmt "$OR" client none
mkdir -p "$OR/etc/p5"; : > "$OR/etc/p5/rc"
oldsnap "$OR" "$TMPBASE/ro5.before" 0
oldv "$OR" wg-ip --purge --role client; ro5prc=$?
oldsnap "$OR" "$TMPBASE/ro5.after" 0
h=0
[ "$ro5prc" = 5 ] || { h=1; echo "  --purge against an engaged P5 exited $ro5prc, not 5"; }
cmp -s "$TMPBASE/ro5.before" "$TMPBASE/ro5.after" || { h=1; echo "  a refused --purge changed the tree"; }
[ -e "$OR/revert-calls" ] && { h=1; echo "  --purge invoked a revert tool against an engaged P5"; }
grep -q '/etc/p5/rc' "$TMPBASE/uerr" || { h=1; echo "  the refusal did not name the intent fact"; }
grep -q 'p5 off' "$TMPBASE/uerr" || { h=1; echo "  the refusal did not print the remedy"; }
oldv "$OR" wg-ip --switch-off --role client; ro5src=$?
[ "$ro5src" = 5 ] || { h=1; echo "  --switch-off against an engaged P5 exited $ro5src, not 5"; }
[ -e "$OR/revert-calls" ] && { h=1; echo "  --switch-off invoked a revert tool against an engaged P5"; }
# THE BACKSTOP: the fact removed by hand, the tunnel still on P5's own feeder.
rm -f "$OR/etc/p5/rc"; rmdir "$OR/etc/p5" 2>/dev/null
oldv "$OR" wg-p5 --switch-off --role client; ro5erc=$?
[ "$ro5erc" = 5 ] || { h=1; echo "  with the fact gone and the endpoint on P5's own socket --switch-off exited $ro5erc, not 5"; }
[ -e "$OR/revert-calls" ] && { h=1; echo "  the endpoint backstop did not stop the revert"; }
grep -q 'LOCAL socket on the same' "$TMPBASE/uerr" || { h=1; echo "  the endpoint refusal did not say what it saw"; }
# CONTROL: same root, direct endpoint, no fact -> the verb runs.
oldv "$OR" wg-ip --switch-off --role client; ro5crc=$?
[ "$ro5crc" = 0 ] || { h=1; echo "  the CONTROL arm exited $ro5crc, not 0 -- this bar would be a predicate that cannot pass"; }
ro5calls=$(grep -c . "$OR/revert-calls" 2>/dev/null); [ -n "$ro5calls" ] || ro5calls=0
[ "$ro5calls" = 2 ] || { h=1; echo "  the CONTROL arm ran $ro5calls revert(s), not 2"; }
chk "$(yn "$([ "$h" = 0 ]; echo $?)")" \
    "RO-5" "no old-stack restore verb runs against an ENGAGED P5: with /etc/p5/rc present --purge exits $ro5prc and --switch-off exits $ro5src with ZERO revert invocations and the tree byte-identical; with the fact removed by hand but the peer endpoint still on P5's own loopback feeder --switch-off exits $ro5erc naming what it saw; and on the SAME root with a direct endpoint and no fact the verb runs and reverts $ro5calls tool(s) (rc=$ro5crc)"

# PIN-ROWS: THE SEVEN /root/cake-autorate FILE ROWS *ARE* THE PIN'S FILES BLOCK.
# Set equality, both directions, because the two lists are kept in different
# files for different reasons and drift is silent: a pin that gains a file leaves
# a member the removal cannot unlink (the home-tree gate admits only what the
# derived list names, so the directory stays standing and named), and a row with
# no pin behind it is a path nobody read off the box.
# config.wg.sh is asserted to be in NEITHER direction: it is a `quarantine` row
# precisely because the pin deliberately does not pin it (pin:24-47).
P5REPO=$(cd "$P5DIR/.." && pwd)
PINF="$P5REPO/deploy/p5/shape/cake-autorate.pin"
awk '/^BEGIN_FILES/{f=1;next} /^END_FILES/{f=0} f && NF==2 {print $2}' "$PINF" 2>/dev/null \
    | LC_ALL=C sort > "$TMPBASE/pin.names"
awk -F'|' '$1=="p1" && $2=="file" && $3 ~ /^\/root\/cake-autorate\// {n=$3; sub(/.*\//,"",n); print n}' \
    "$OLDROWS" | LC_ALL=C sort > "$TMPBASE/row.names"
i=0
pinn=$(grep -c . "$TMPBASE/pin.names" 2>/dev/null); [ -n "$pinn" ] || pinn=0
rown=$(grep -c . "$TMPBASE/row.names" 2>/dev/null); [ -n "$rown" ] || rown=0
[ "$pinn" -ge 7 ] || { i=1; echo "  the pin's FILES block yielded $pinn name(s) -- this bar is not reading the pin"; }
if ! cmp -s "$TMPBASE/pin.names" "$TMPBASE/row.names"; then
    i=1; echo "  the pinned set and the derived removal rows are not the same set:"
    diff "$TMPBASE/pin.names" "$TMPBASE/row.names" 2>/dev/null | sed 's/^/    /'
fi
grep -qx 'config.wg.sh' "$TMPBASE/pin.names" && { i=1; echo "  config.wg.sh is in the pin's FILES block -- it is deliberately NOT pinned (pin:24-47)"; }
grep -qx 'config.wg.sh' "$TMPBASE/row.names" && { i=1; echo "  config.wg.sh is carried as a \`file\` row -- it must be a \`quarantine\` row: it is moved aside, never deleted"; }
awk -F'|' '$1=="p1" && $2=="quarantine" && $3=="/root/cake-autorate/config.wg.sh"' "$OLDROWS" | grep -q . \
    || { i=1; echo "  there is no quarantine row for /root/cake-autorate/config.wg.sh"; }
chk "$(yn "$([ "$i" = 0 ]; echo $?)")" \
    "PIN-ROWS" "the $rown \`p1|file|/root/cake-autorate/*\` rows and the $pinn names in deploy/p5/shape/cake-autorate.pin's FILES block are the SAME SET in both directions, and config.wg.sh is in neither -- it is a \`quarantine\` row because the pin deliberately does not pin Mo's own tuning"

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
# ===========================================================================
# THE SHAPER'S CARRIAGE (U210) -- PK-2, PK-3, MK-1
# ===========================================================================
# P5's shaper is the one feature whose bytes are NOT in this repo: the vendored
# cake-autorate files are Mo's read off the client (G8), pinned by sha in
# deploy/p5/shape/cake-autorate.pin. Three states are possible and the middle
# one is the dangerous one -- empty (declared, the package says so), complete
# (every pinned sha matches), or PARTIAL/MISMATCHED, which is a package that
# installs on a router with no console and then refuses at the last step, or
# stages code nobody pinned. These bars refuse the middle state on the PC.
# the repo root, resolved here and not borrowed from a block further down: a
# bar that reads a variable another bar happens to set first is one reorder
# away from "parameter not set", which is how this block died on its first run.
_sh_repo=$(cd "$P5DIR/.." && pwd)
_sh_pin="$_sh_repo/deploy/p5/shape/cake-autorate.pin"
_sh_ven="$_sh_repo/deploy/p5/shape/vendor"
# NOFILE-guarded like every other set bar in this file: an absent pin makes
# `grep -c` over nothing 0, and 0 is what a clean vendor set also scores.
if [ -r "$_sh_pin" ]; then
    sed -n '/^BEGIN_FILES$/,/^END_FILES$/p' "$_sh_pin" \
        | grep -E '^[0-9a-f]{64}  ' | sed 's/^[0-9a-f]\{64\}  //' \
        | LC_ALL=C sort > "$TMPBASE/pk2.want"
    ( cd "$_sh_ven" 2>/dev/null && find . -type f ! -name .gitkeep -print ) \
        | sed 's|^\./||' | LC_ALL=C sort > "$TMPBASE/pk2.have"
    if [ ! -s "$TMPBASE/pk2.want" ]; then
        pk2_state=NOPIN
    elif [ ! -s "$TMPBASE/pk2.have" ]; then
        pk2_state=empty
    elif ! cmp -s "$TMPBASE/pk2.have" "$TMPBASE/pk2.want"; then
        pk2_state="PARTIAL($(comm -13 "$TMPBASE/pk2.have" "$TMPBASE/pk2.want" | tr '\n' ' ')|$(comm -23 "$TMPBASE/pk2.have" "$TMPBASE/pk2.want" | tr '\n' ' '))"
    elif sed -n '/^BEGIN_FILES$/,/^END_FILES$/p' "$_sh_pin" \
           | grep -E '^[0-9a-f]{64}  ' > "$TMPBASE/pk2.sums" \
         && ( cd "$_sh_ven" && sha256sum -c "$TMPBASE/pk2.sums" >/dev/null 2>&1 ); then
        pk2_state=complete
    else
        pk2_state=SHAMISMATCH
    fi
else
    pk2_state=NOPIN
fi
chk "$(yn "$([ "$pk2_state" = empty ] || [ "$pk2_state" = complete ]; echo $?)")" \
    "PK-2" "deploy/p5/shape/vendor/ is EXACTLY one of the two declared states -- empty (.gitkeep only, G8's bytes not read yet) or exactly the pin's FILES set with every sha256 matching. Measured: $pk2_state. A partial or mismatched set is a package that installs on a console-less router and then refuses at the last step"

# PK-3 -- the PROVENANCE stamp must AGREE with what the package actually holds.
# The stamp is how a box answers "can shaping be installed from this package"
# without unpacking it, so a stamp that disagrees with the payload is worse than
# no stamp. Synthetic mode has no built package to read, and says so rather than
# scoring: mkpkg's fixture has no shape/ tree and asserting over one would be a
# claim about mkpkg (the PKG_MODE rule this file already applies to IN-7).
if [ "$PKG_MODE" = real ]; then
    pk3_stamp=$(grep '^P5_SHAPE_VENDORED=' "$P5_PKG/PROVENANCE" 2>/dev/null | cut -d= -f2)
    pk3_have=$( ( cd "$P5_PKG/shape/vendor" 2>/dev/null && find . -type f ! -name .gitkeep -print ) | grep -c . )
    if [ "$pk3_have" -gt 0 ]; then pk3_want=yes; else pk3_want=no; fi
    chk "$(yn "$([ -n "$pk3_stamp" ] && [ "$pk3_stamp" = "$pk3_want" ]; echo $?)")" \
        "PK-3" "the built package's PROVENANCE says P5_SHAPE_VENDORED=${pk3_stamp:-<ABSENT>} and its shape/vendor/ holds $pk3_have pinned file(s), so the stamp says $pk3_want. A box reads that stamp instead of unpacking the package; a stamp that disagrees with the payload is worse than none"
else
    skipbar "PK-3" "PROVENANCE P5_SHAPE_VENDORED can only be read off a package the builder produced. The synthetic fixture carries no shape/ tree, and asserting over one would be a claim about mkpkg, not about the product. Run with P5_PKG=\$(bash scripts/build-p5-package.sh)."
fi

# MK-1 -- THE OWNERSHIP MARKER IS ONE STRING IN THREE SHIPPED FILES.
# The reconciler's shape leaves refuse to enable, restart, disable or stop a
# controller whose file does not carry it (xctl-shape.sh shape_svc_owned), and
# shape-install refuses to make a payload live under one. That check is an
# ownership test only while all three spellings agree: the init script CARRIES
# the marker, shape-install greps for it, and bond-xctl DEFINES the variable the
# leaves read. Two spellings and P5 silently stops recognising its own
# controller -- which reads as "foreign", so the failure is a permanently
# unshaped box, not a crash. Read as three whole lines, so a partial edit to any
# one of them is a red bar and not a near-miss.
_mk_init=$(sed -n '3p' "$_sh_repo/deploy/p5/init.d/p5-shape" 2>/dev/null)
_mk_si=$(grep -c 'P5_MARK="P5-OWNED-INIT: deploy/p5/init.d/p5-shape"' "$_sh_repo/deploy/p5/shape-install" 2>/dev/null)
_mk_xc=$(grep -c 'P5_MARK="P5-OWNED-INIT: deploy/p5/init.d/p5-shape"' "$_sh_repo/deploy/p5/bond-xctl" 2>/dev/null)
chk "$(yn "$([ "$_mk_init" = "# P5-OWNED-INIT: deploy/p5/init.d/p5-shape" ] && [ "$_mk_si" = 1 ] && [ "$_mk_xc" = 1 ]; echo $?)")" \
    "MK-1" "the P5 ownership marker is byte-equal in all three shipped files: init.d/p5-shape line 3 ('$_mk_init'), shape-install P5_MARK ($_mk_si), bond-xctl P5_MARK ($_mk_xc). Disagreement makes P5 read its OWN controller as foreign and leave the box permanently unshaped"

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

# ---------------------------------------------------------------------------
# RB-* -- THE CLIENT RUNBOOK IS A CHECKED ARTIFACT, NOT PROSE (U173 -> U213).
#
# docs/deploy-p5-runbook.md is the document a human executes against a router,
# and the box at the other end of the pair has no console. Measured on dev at
# cb8dd71, the version these bars first replaced: it named engarde 22 times and
# its bring-up engaged the engarde client service on the PRODUCTION port (U141
# folded that feeder away; the feeder is p5-datapath on AGG_PORT); its install
# section pushed deploy/p5 by scp against a HAND-WRITTEN sha manifest whose file
# list predated the five reconciler libraries U124 split out, so following it
# placed a reconciler with no libraries; it said the payload was client-side
# only two lines under a warning saying that was no longer true; and it used
# three mode names that ADR-003 as amended does not have.
#
# EVERY ONE OF THOSE IS A CORRESPONDENCE FAILURE between a document and a tree,
# and every one of them was invisible to nine green gates. So the correspondence
# is checked here, mechanically and in BOTH directions, against the same two
# files the installer itself is judged by -- payload/filemap and contract/paths.
# A finder is a function so the same code that reports on the real document is
# run against a deliberately-broken copy by the MU-RB* bars below.
#
# U213 REWROTE THAT DOCUMENT TO THE G2 LADDER (T1, S0..S4) and added five bars
# for the properties the ladder itself has and prose cannot hold: RB-11 the box
# labels, RB-12 the rung order and the two verbs the ladder must never name,
# RB-13 no recursive removal written down anywhere, RB-14 the prerequisite
# merges resolved against this repository, RB-15 every verb resolved against
# the parser that would receive it.
# ---------------------------------------------------------------------------
_rb_repo=$(cd "$P5DIR/.." && pwd)
RB_DOC="$_rb_repo/docs/deploy-p5-runbook.md"

# THE MIRROR HAS A docs/ DIRECTORY AND DOES NOT HAVE THIS FILE, AND THAT IS A
# PUBLISHING DECISION, NOT A DEFECT. scripts/sync-public-ci.sh's ALLOW list
# publishes p5/, deploy/, orchestration/, .github/ and a handful of named
# files -- among them docs/deploy-p5-server.md, ONE docs/ file by exact path --
# and its staging loop does `mkdir -p "$WORK/$(dirname "$p")"` for every entry,
# so the published tree HAS docs/, holding exactly that one file.
# docs/deploy-p5-runbook.md is not on that list and is not published.
#
# SO THE PREDICATE BELOW TESTS FOR THE FILE THESE BARS READ, NOT FOR THE
# DIRECTORY. A `[ -d "$_rb_repo/docs" ]` test is TRUE on the mirror: it would
# set RB_PRESENT=1 there, raise the floor to the full-checkout number, and fail
# RB-1 on a document that is absent by design -- the exact U162 shape these
# bars exist to prevent (four deadman bars have never once passed on the mirror
# because they grep a runbook that is not published there, and they report it
# as a failure every run).
#
# On the mirror the bars below have nothing to read. They SKIP, each with that
# reason, and a skip is not a pass: the floor at the end of this file is the
# count for the mode this run is in, stated as two numbers rather than lowered
# to whatever the run produced.
#
# WHAT THIS PREDICATE GIVES UP, SAID OUT LOUD: a full checkout in which the
# runbook was DELETED now skips these bars instead of failing RB-1 on them.
# That case is a deletion visible in the diff and in git; the case this
# predicate fixes was a red CI job on the mirror on every branch, by
# construction. The battery cannot tell the two trees apart by a docs/ probe,
# because the mirror has docs/ too.
if [ -f "$_rb_repo/docs/deploy-p5-runbook.md" ]; then
    RB_PRESENT=1
else
    RB_PRESENT=0
    for _rb_b in RB-1 RB-2 RB-3 RB-4 RB-5 RB-6 RB-7 RB-8 RB-9 RB-10 \
                 RB-11 RB-12 RB-13 RB-14 RB-15 \
                 MU-RB1 MU-RB2 MU-RB3 MU-RB4 MU-RB5 MU-RB6 \
                 MU-RB7 MU-RB8 MU-RB9 MU-RB10 MU-RB11; do
        skipbar "$_rb_b" "docs/deploy-p5-runbook.md is not in this tree, so there is nothing here to check. That is the published-mirror shape: sync-public-ci.sh ALLOW-lists docs/deploy-p5-server.md and no other docs/ file, so the mirror HAS a docs/ directory and does not have this runbook -- an unpublished document, not a missing one. Run this battery in a full checkout to measure the runbook"
    done
fi

if [ "$RB_PRESENT" = 1 ]; then
    RB_W="$TMPBASE/rb"
    mkdir -p "$RB_W"

    # --- the declared sets, all derived, none typed here ------------------------
    grep -v '^#' "$P5DIR/payload/filemap" 2>/dev/null \
        | awk -F'|' 'NF>=4 && $4 ~ /^\//{print $4}' | LC_ALL=C sort -u > "$RB_W/fm.all"
    # contract/paths is `kind |role |path |owner |state |reason`, space-padded.
    awk -F'|' 'NF>=3 && $0 !~ /^#/ {
            k=$1; p=$3; gsub(/[ \t]/,"",k); gsub(/[ \t]/,"",p);
            if (p ~ /^\//) print k "|" p
        }' "$P5DIR/contract/paths" > "$RB_W/cp.rows"
    awk -F'|' '$1=="file"||$1=="dir"||$1=="staging"{print $2}' "$RB_W/cp.rows" > "$RB_W/cp.exact"
    awk -F'|' '$1=="glob"{print $2}'                            "$RB_W/cp.rows" > "$RB_W/cp.globs"
    awk -F'|' '$1=="dir"||$1=="staging"{print $2}'              "$RB_W/cp.rows" > "$RB_W/cp.dirs"
    # contract/foreign is `owner|path`; uci: rows are objects, not paths.
    awk -F'|' 'NF>=2 && $0 !~ /^#/ && $2 ~ /^\//{print $2}' "$P5DIR/contract/foreign" \
        | LC_ALL=C sort -u > "$RB_W/fg.all"
    grep -e '[*]' -e '\[' "$RB_W/fg.all" > "$RB_W/fg.globs" 2>/dev/null || :
    grep -v -e '[*]' -e '\[' "$RB_W/fg.all" > "$RB_W/fg.exact" 2>/dev/null || :

    rb_ancestors() {        # stdin: paths -> stdout: every proper ancestor directory
        while read -r _ra; do
            while :; do
                _ra=${_ra%/*}
                [ -n "$_ra" ] || break
                echo "$_ra"
            done
        done
    }
    { cat "$RB_W/fm.all" "$RB_W/cp.exact" "$RB_W/cp.globs" "$RB_W/fg.all"; } \
        | rb_ancestors | LC_ALL=C sort -u > "$RB_W/ancestors"
    cat "$RB_W/fm.all" "$RB_W/cp.exact" | LC_ALL=C sort -u > "$RB_W/product"

    # rb_region DOC BEGIN END -- the lines strictly between two markers.
    rb_region() { awk -v b="$2" -v e="$3" 'index($0,e){f=0} f{print} index($0,b){f=1}' "$1"; }

    # rb_cells DOC BEGIN END -- the first backticked absolute path of each table row
    # in a marked region. The region markers are HTML comments, so they are visible
    # to this parser and invisible to a reader of the rendered document.
    rb_cells() { rb_region "$1" "$2" "$3" | sed -n 's/^|[^|]*`\(\/[^`]*\)`.*/\1/p' | LC_ALL=C sort -u; }

    # rb_except DOC -- the paths section 3e declares as deliberately outside the
    # product. Read from the document itself, so a mutant carries its own.
    rb_except() { rb_cells "$1" RB-EXCEPT-BEGIN RB-EXCEPT-END; }

    # rb_tokens DOC -- `F|LINE|PATH` for every absolute path the document names
    # under the FIVE roots this regex lists: /usr /etc /var /tmp /root. F is set
    # when the line is marked FOREIGN, either by the token or by sitting inside
    # the section 0a region. The root set is stated rather than implied because
    # it is a LIMIT: /sbin, /bin, /lib and every other live OpenWrt root are
    # invisible to this function. They are not unchecked -- RB-9 below scans them
    # with the same declaration test -- but nothing here sees them, so a reader of
    # RB-1 alone must not conclude that RB-1 covers the whole filesystem.
    rb_tokens() {
        awk '
            index($0,"RB-FOREIGN-END"){r=0}
            {
                f = (r || index($0,"FOREIGN")>0) ? "F" : "N"
                s = $0
                while (match(s, "/(usr|etc|var|tmp|root)/[A-Za-z0-9_./*-]*")) {
                    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART+RLENGTH)
                    sub(/[.,;:)]+$/, "", t); sub(/\/$/, "", t)
                    if (t != "") print f "|" NR "|" t
                }
            }
            index($0,"RB-FOREIGN-BEGIN"){r=1}
        ' "$1" | LC_ALL=C sort -u
    }

    rb_under() {            # rb_under PATH LISTFILE -> 0 if PATH is under a listed directory
        while read -r _ru; do
            [ -n "$_ru" ] || continue
            case "$1" in "$_ru"/*) return 0 ;; esac
        done < "$2"
        return 1
    }
    rb_globmatch() {        # rb_globmatch PATH LISTFILE -> 0 if PATH matches a listed glob
        while read -r _rg; do
            [ -n "$_rg" ] || continue
            case "$1" in $_rg) return 0 ;; esac
        done < "$2"
        return 1
    }
    rb_is_foreign() {       # exact or glob only: an ANCESTOR of a foreign path is not foreign
        grep -qxF "$1" "$RB_W/fg.exact" && return 0
        rb_globmatch "$1" "$RB_W/fg.globs" && return 0
        return 1
    }
    rb_is_product() {
        grep -qxF "$1" "$RB_W/product"   && return 0
        grep -qxF "$1" "$RB_W/ancestors" && return 0
        rb_under    "$1" "$RB_W/cp.dirs" && return 0
        rb_globmatch "$1" "$RB_W/cp.globs" && return 0
        return 1
    }

    # --- RB-1: every absolute path the document names is DECLARED somewhere -----
    rb_undeclared() {       # rb_undeclared DOC -> one line per undeclared path
        rb_except "$1" > "$RB_W/except.$$"
        rb_tokens "$1" | while IFS='|' read -r _f _l _p; do
            rb_is_product "$_p" && continue
            rb_is_foreign "$_p" && continue
            grep -qxF "$_p" "$RB_W/except.$$" && continue
            rb_under "$_p" "$RB_W/except.$$"  && continue
            echo "  $(basename "$1"):$_l names $_p -- no filemap row, no contract/paths row, no contract/foreign row, no section 3e exception"
        done
        rm -f "$RB_W/except.$$"
    }
    rb1_out=$(
        if [ -r "$RB_DOC" ]; then
            rb_undeclared "$RB_DOC"
        else
            # RB_PRESENT=1 already required -f on this exact path, so a MISSING
            # runbook SKIPPED above and cannot reach here. The only state that
            # reaches this branch is a file that EXISTS and cannot be READ --
            # a mode or ownership problem in this tree. Fail, do not skip: a
            # document the battery cannot open is one it cannot judge, and that
            # is not the mirror's absent-by-design case.
            echo "  docs/deploy-p5-runbook.md exists but is not readable by this user -- the client deploy ladder cannot be checked; fix its mode or ownership"
        fi
    )
    rb1_n=$(printf '%s' "$rb1_out" | grep -c . )
    [ -n "$rb1_out" ] && printf '%s\n' "$rb1_out"
    chk "$(yn "$([ "$rb1_n" = 0 ]; echo $?)")" \
        "RB-1" "every absolute path the client runbook names is declared -- by p5/payload/filemap, by p5/contract/paths, by p5/contract/foreign, or by its own section 3e with a reason ($rb1_n undeclared). An operator cannot be sent to a path the product does not own"

    # --- RB-2: a FOREIGN path may only appear on a line marked FOREIGN ----------
    # This is the bar that reproduces the actual defect: the old section 5a engaged
    # the engarde client service on the production port, in a document whose own
    # section 0 said the old stack is untouchable.
    rb_foreign_unmarked() {
        rb_tokens "$1" | while IFS='|' read -r _f _l _p; do
            [ "$_f" = N ] || continue
            rb_is_foreign "$_p" || continue
            echo "  $(basename "$1"):$_l names the FOREIGN path $_p on a line that is not marked FOREIGN and is not in the section 0a inventory"
        done
    }
    rb2_out=$(rb_foreign_unmarked "$RB_DOC")
    rb2_n=$(printf '%s' "$rb2_out" | grep -c . )
    [ -n "$rb2_out" ] && printf '%s\n' "$rb2_out"
    chk "$(yn "$([ "$rb2_n" = 0 ]; echo $?)")" \
        "RB-2" "every path p5/contract/foreign declares appears in the runbook ONLY on a line marked FOREIGN ($rb2_n unmarked). A step that reaches for the old stack cannot be written down without going red"

    # --- RB-3 / RB-4: the payload tables equal the filemap, BOTH directions -----
    rb_payload_diff() {     # rb_payload_diff DOC FILEMAP ROLE BEGIN END
        awk -F'|' -v role="$3" 'NF>=4 && $0 !~ /^#/ && ($2==role||$2=="both"){print $4}' "$2" \
            | LC_ALL=C sort -u > "$RB_W/want.$$"
        rb_cells "$1" "$4" "$5" > "$RB_W/have.$$"
        comm -13 "$RB_W/have.$$" "$RB_W/want.$$" | sed "s|^|  the package installs it for role=$3 and the runbook does not name it: |"
        comm -23 "$RB_W/have.$$" "$RB_W/want.$$" | sed "s|^|  the runbook names it for role=$3 and no filemap row ships it: |"
        rm -f "$RB_W/want.$$" "$RB_W/have.$$"
    }
    rb3_out=$(rb_payload_diff "$RB_DOC" "$P5DIR/payload/filemap" client RB-PAYLOAD-BEGIN RB-PAYLOAD-END)
    rb3_n=$(printf '%s' "$rb3_out" | grep -c . )
    [ -n "$rb3_out" ] && printf '%s\n' "$rb3_out"
    chk "$(yn "$([ "$rb3_n" = 0 ]; echo $?)")" \
        "RB-3" "the runbook's client payload table and the filemap's role=client rows are the SAME SET ($rb3_n differences). This is the anti-rot mechanism: a new payload row reddens the document until it names it"

    rb4_out=$(rb_payload_diff "$RB_DOC" "$P5DIR/payload/filemap" server RB-SERVER-BEGIN RB-SERVER-END)
    rb4_n=$(printf '%s' "$rb4_out" | grep -c . )
    [ -n "$rb4_out" ] && printf '%s\n' "$rb4_out"
    chk "$(yn "$([ "$rb4_n" = 0 ]; echo $?)")" \
        "RB-4" "the runbook's server payload table and the filemap's role=server rows are the SAME SET ($rb4_n differences). The document that used to say there was no server-side install step now cannot: the rows are checked"

    # --- RB-5: every operator entry point the package ships is documented -------
    rb5_out=$(
        for _b in "$P5DIR"/bin/*; do
            [ -f "$_b" ] || continue
            _n=${_b##*/}
            grep -qF -- "$_n" "$RB_DOC" || echo "  the package ships p5/bin/$_n and the runbook never names it"
        done
        grep -qF 'scripts/build-p5-package.sh' "$RB_DOC" \
            || echo "  the runbook does not name scripts/build-p5-package.sh, and there is no other way to make a package"
    )
    rb5_n=$(printf '%s' "$rb5_out" | grep -c . )
    [ -n "$rb5_out" ] && printf '%s\n' "$rb5_out"
    chk "$(yn "$([ "$rb5_n" = 0 ]; echo $?)")" \
        "RB-5" "the runbook names the package builder and every operator entry point in p5/bin ($rb5_n missing). The version this replaces named none of them and told the operator to scp a file list instead"

    # --- RB-6: the ports, derived from the tree and from the measured inventory --
    rb_p5port=$(sed -n 's/^AGG_PORT="\([0-9][0-9]*\)".*/\1/p' "$_rb_repo/deploy/p5/bond-xctl" | head -1)
    rb_srvport=$(sed -n 's/^AGG_LISTEN="\${AGG_LISTEN:-:\([0-9][0-9]*\)}".*/\1/p' "$_rb_repo/deploy/server/init.d/p5-server" | head -1)
    rb_prodport=$(sed -n 's/.*:::\([0-9][0-9]*\)[ 	].*engarde-serve.*/\1/p' \
        "$_rb_repo/docs/knowledge/inventory/2026-08-30-server-brume2.txt" 2>/dev/null | head -1)
    rb_badports() {         # rb_badports DOC -> one line per port that is neither
        awk -v p5="$rb_p5port" -v prod="$rb_prodport" -v doc="$(basename "$1")" '
            index($0,"RB-FOREIGN-END"){r=0}
            {
                f = (r || index($0,"FOREIGN")>0) ? "F" : "N"
                s = $0
                while (match(s, "(^|[^0-9])5[0-9][0-9][0-9][0-9]([^0-9]|$)")) {
                    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART+RLENGTH)
                    gsub(/[^0-9]/, "", t)
                    if (t != p5 && t != prod)
                        printf "  %s:%d names port %s -- the tree uses %s (P5) and %s (production) and no other\n", doc, NR, t, p5, prod
                    else if (t == prod && f != "F")
                        printf "  %s:%d names the PRODUCTION port %s on a line that is not marked FOREIGN\n", doc, NR, t
                }
            }
            index($0,"RB-FOREIGN-BEGIN"){r=1}
        ' "$1"
    }
    rb6_out=$(
        [ -n "$rb_p5port" ]   || echo "  cannot derive P5's port: no AGG_PORT= line in deploy/p5/bond-xctl"
        [ -n "$rb_srvport" ]  || echo "  cannot derive the server's listen port: no AGG_LISTEN= line in deploy/server/init.d/p5-server"
        [ -n "$rb_prodport" ] || echo "  cannot derive the production port: no engarde-server listener in the 2026-08-30 server inventory"
        [ "$rb_p5port" = "$rb_srvport" ] \
            || echo "  the client reconciler and the server service DISAGREE about P5's port: $rb_p5port vs $rb_srvport"
        grep -qF "$rb_p5port" "$RB_DOC" || echo "  the runbook never names P5's own port $rb_p5port"
        rb_badports "$RB_DOC"
    )
    rb6_n=$(printf '%s' "$rb6_out" | grep -c . )
    [ -n "$rb6_out" ] && printf '%s\n' "$rb6_out"
    chk "$(yn "$([ "$rb6_n" = 0 ]; echo $?)")" \
        "RB-6" "every port the runbook names is P5's own $rb_p5port (derived from the reconciler AND the server service, which agree) or the production port $rb_prodport (derived from the measured server inventory), and the production port appears only on FOREIGN lines ($rb6_n findings)"

    # --- RB-7: the mode vocabulary is ADR-003's, as the TREE realises it --------
    rb_live_modes=$(
        grep -oE '^[[:space:]]*[a-z]+\|[a-z]+\)[[:space:]]*:[[:space:]]*;;' "$_rb_repo/deploy/p5/bondctl" \
            | head -1 | sed 's/[^a-z|]//g' | tr '|' ' '
        sed -n 's/^AGG_SCHED_TABLE="\(.*\)".*/\1/p' "$_rb_repo/deploy/p5/lib/xctl-probe.sh" \
            | head -1 | tr ' ' '\n' | cut -d: -f1 | tr '\n' ' '
    )
    # One line, one bar: the two derivations above are newline-joined, and a bar
    # description carrying a newline prints as two lines and parses as neither.
    rb_live_modes=$(printf '%s' "$rb_live_modes" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ $//')
    rb7_out=$(
        _n=0
        for _m in $rb_live_modes; do
            _n=$((_n + 1))
            grep -qwF -- "$_m" "$RB_DOC" || echo "  the tree accepts mode '$_m' and the runbook never names it"
        done
        [ "$_n" -ge 3 ] || echo "  could not derive the live mode set from deploy/p5/bondctl + deploy/p5/lib/xctl-probe.sh (got '$rb_live_modes')"
        for _r in bonded redundant cell; do
            for _m in $rb_live_modes; do
                [ "$_r" = "$_m" ] && echo "  '$_r' is LIVE in the tree again -- the runbook's section 0b retired-name table is now wrong"
            done
            awk 'index($0,"RB-RETIRED-BEGIN"){f=1} index($0,"RB-RETIRED-END"){f=0;next} !f' "$RB_DOC" \
                | grep -qwF -- "$_r" \
                && echo "  the retired mode name '$_r' appears outside the runbook's section 0b region"
        done
        :
    )
    rb7_n=$(printf '%s' "$rb7_out" | grep -c . )
    [ -n "$rb7_out" ] && printf '%s\n' "$rb7_out"
    chk "$(yn "$([ "$rb7_n" = 0 ]; echo $?)")" \
        "RB-7" "the runbook names every mode the tree accepts ($rb_live_modes) and no retired name outside its own section 0b region ($rb7_n findings). The version this replaces used bonded/redundant/cell, none of which ADR-003 as amended has"

    # --- RB-8: the exception table cannot be used to launder a real path --------
    rb8_out=$(
        rb_region "$RB_DOC" RB-EXCEPT-BEGIN RB-EXCEPT-END | grep '^|' | grep -v '^|---' | \
        while IFS= read -r _row; do
            _p=$(printf '%s' "$_row" | sed -n 's/^|[^|]*`\(\/[^`]*\)`.*/\1/p')
            _why=$(printf '%s' "$_row" | awk -F'|' '{print $3}' | sed 's/[ \t]//g')
            [ -n "$_p" ] || continue
            [ -n "$_why" ] || echo "  section 3e names $_p with no reason"
            rb_is_product "$_p" && echo "  section 3e claims $_p is outside the product, but the filemap or contract/paths declares it"
            rb_is_foreign "$_p" && echo "  section 3e claims $_p is outside the product, but contract/foreign declares it"
            :
        done
    )
    rb8_n=$(printf '%s' "$rb8_out" | grep -c . )
    [ -n "$rb8_out" ] && printf '%s\n' "$rb8_out"
    chk "$(yn "$([ "$rb8_n" = 0 ]; echo $?)")" \
        "RB-8" "the runbook's section 3e exception table names nothing the contract or the foreign list already declares, and every entry carries a reason ($rb8_n findings). Without this, RB-1 has a hole the width of one table row"

    # --- MU-RB*: the seeds. A bar nobody has watched fail is not a bar. ---------
    # Each mutates a COPY of the document (or of the filemap) and asserts the same
    # finder that reported clean above now names the defect. The mutations are the
    # three shapes the old runbook actually had.
    rb_mu1="$TMPBASE/runbook.mu1"
    cp "$RB_DOC" "$rb_mu1"
    printf '\n- start the second feeder service at `/etc/init.d/p5-feeder2` before the first.\n' >> "$rb_mu1"
    rb_mu1_out=$(rb_undeclared "$rb_mu1")
    chk "$(yn "$(echo "$rb_mu1_out" | grep -q 'p5-feeder2'; echo $?)")" \
        "MU-RB1" "MUTATION: a copy of the runbook told to start a SECOND FEEDER at /etc/init.d/p5-feeder2 -- a service U141 folded away and no filemap row ships -- and RB-1's finder names it. RB-1 is a bar that can fail"

    rb_mu2="$TMPBASE/runbook.mu2"
    cp "$RB_DOC" "$rb_mu2"
    printf '\n- engage the engarde client service: `/etc/init.d/engarde-client` then reconcile.\n' >> "$rb_mu2"
    rb_mu2_out=$(rb_foreign_unmarked "$rb_mu2")
    chk "$(yn "$(echo "$rb_mu2_out" | grep -q 'engarde-client'; echo $?)")" \
        "MU-RB2" "MUTATION: a copy of the runbook told to ENGAGE the old stack's engarde client service on an unmarked line -- the exact step the version this replaces carried in its section 5a -- and RB-2's finder names it. RB-2 is a bar that can fail"

    rb_mu3="$TMPBASE/runbook.mu3"
    cp "$RB_DOC" "$rb_mu3"
    printf '\n- the feeder listens on 59409 in this deployment.\n' >> "$rb_mu3"
    rb_mu3_out=$(rb_badports "$rb_mu3")
    chk "$(yn "$(echo "$rb_mu3_out" | grep -q '59409'; echo $?)")" \
        "MU-RB3" "MUTATION: a copy of the runbook naming port 59409, which nothing in the tree listens on, and RB-6's finder names it. RB-6 is a bar that can fail"

    rb_mu4="$TMPBASE/filemap.mu-rb4"
    grep -v '^644|client|deploy/p5/bond.dag|' "$P5DIR/payload/filemap" > "$rb_mu4"
    rb_mu4_applied=$(( $(grep -c . "$P5DIR/payload/filemap") - $(grep -c . "$rb_mu4") ))
    rb_mu4_out=$(rb_payload_diff "$RB_DOC" "$rb_mu4" client RB-PAYLOAD-BEGIN RB-PAYLOAD-END)
    chk "$(yn "$([ "$rb_mu4_applied" = 1 ] && echo "$rb_mu4_out" | grep -q '/usr/lib/p5/dag'; echo $?)")" \
        "MU-RB4" "MUTATION: the /usr/lib/p5/dag row removed from a copy of the filemap -> RB-3's finder reports the runbook naming a file no row ships (rows removed: $rb_mu4_applied). RB-3 measures the correspondence in both directions, not just one"

    # =======================================================================
    # RB-9 / RB-10 -- THE TWO HOLES RB-1 AND RB-6 CANNOT SEE.
    #
    # Added in U173's fix round because the runbook's honesty section claimed
    # "every absolute path it names is declared" and "every port it names",
    # and neither finder is that wide:
    #
    #   RB-1  scans /usr /etc /var /tmp /root only (rb_tokens' regex), so a
    #         step naming /sbin/... or /lib/... -- both live roots on OpenWrt
    #         -- passes it unread.
    #   RB-6  matches 5[0-9][0-9][0-9][0-9] only (rb_badports' regex), so a
    #         step naming 1194, 8472 or 443 passes it unread.
    #
    # The choice was a qualifying clause in the document or a bar that makes
    # the unqualified claim true. Both were taken: the honesty section now
    # states what each bar covers, AND the gaps are closed here, so the
    # document is not relying on the reader noticing a footnote.
    #
    # MEASURED before writing them: p5/contract/paths, p5/contract/foreign and
    # p5/payload/filemap between them declare ZERO paths outside the five roots
    # rb_tokens scans. So RB-9's admissible set is empty by derivation, not by
    # assertion: any /sbin, /bin or /lib path in the runbook is a path the
    # product does not own, and RB-9 says so.

    # rb_tokens_wide DOC -- `F|LINE|PATH` for every absolute path OUTSIDE the
    # five roots rb_tokens scans, less /dev /proc /sys. Those three are kernel
    # pseudo-filesystems that no install writes to and that appear in this
    # document only as redirection targets (`>/dev/null`); excluding them is a
    # stated limit, not an oversight, and it is the ONLY root class neither
    # RB-1 nor RB-9 reads.
    #
    # THE LEADING BOUNDARY CLASS IS LOAD-BEARING. Without it the repo-relative
    # `p5/payload/filemap` matches as `/payload/filemap` and this bar invents
    # findings against a clean document -- U176's failure (a completeness check
    # whose own matcher is wrong manufactures work) reproduced while writing
    # this, and fixed before it shipped.
    rb_tokens_wide() {
        awk '
            index($0,"RB-FOREIGN-END"){r=0}
            {
                f = (r || index($0,"FOREIGN")>0) ? "F" : "N"
                s = " " $0
                while (match(s, "[^A-Za-z0-9_.*-]/[A-Za-z][A-Za-z0-9_-]*/[A-Za-z0-9_./*-]*")) {
                    t = substr(s, RSTART+1, RLENGTH-1); s = substr(s, RSTART+RLENGTH)
                    sub(/[.,;:)]+$/, "", t); sub(/\/$/, "", t)
                    root = t; sub(/^\//, "", root); sub(/\/.*$/, "", root)
                    if (root=="usr"||root=="etc"||root=="var"||root=="tmp"||root=="root") continue
                    if (root=="dev"||root=="proc"||root=="sys") continue
                    if (t != "") print f "|" NR "|" t
                }
            }
            index($0,"RB-FOREIGN-BEGIN"){r=1}
        ' "$1" | LC_ALL=C sort -u
    }

    # --- RB-9: the roots RB-1's regex does not reach ---------------------------
    rb_undeclared_wide() {  # rb_undeclared_wide DOC -> one line per undeclared path
        rb_except "$1" > "$RB_W/exceptw.$$"
        rb_tokens_wide "$1" | while IFS='|' read -r _f _l _p; do
            rb_is_product "$_p" && continue
            rb_is_foreign "$_p" && continue
            grep -qxF "$_p" "$RB_W/exceptw.$$" && continue
            rb_under "$_p" "$RB_W/exceptw.$$" && continue
            echo "  $(basename "$1"):$_l names $_p -- a root RB-1 does not scan, and nothing in filemap, contract/paths, contract/foreign or section 3e declares it"
        done
        rm -f "$RB_W/exceptw.$$"
    }
    rb9_out=$(rb_undeclared_wide "$RB_DOC")
    rb9_n=$(printf '%s' "$rb9_out" | grep -c . )
    [ -n "$rb9_out" ] && printf '%s\n' "$rb9_out"
    chk "$(yn "$([ "$rb9_n" = 0 ]; echo $?)")" \
        "RB-9" "every absolute path the runbook names OUTSIDE RB-1's five roots -- /sbin, /bin, /lib, /opt, /srv and the rest of a live OpenWrt filesystem, less the /dev /proc /sys pseudo-filesystems -- is declared, or there are none ($rb9_n undeclared). RB-1's regex reads five roots and this reads every other one, so 'every path is declared' is true of the pair and of neither alone"

    # --- RB-10: the ports RB-6's regex does not reach --------------------------
    # Three forms: `port NNNN`, a BARE `:NNNN` whose colon follows whitespace
    # or punctuation OTHER THAN - . _ : , and a backticked number. 3-5 digits,
    # so an ordinary two-digit count in prose does not have to be escaped.
    # THE COLON FORM IS NOT A HOST SUFFIX, and the bar text below says so: the
    # alternative's leading class is exactly [^A-Za-z0-9_.:-] , which excludes
    # the four punctuation characters - . _ : as well as every alphanumeric.
    # So a real suffix on a host or address (name:1194) matches nothing here,
    # and neither do host-:1194 , x.:1194 or x_:1194 , which look bare and are
    # not. Stated as the class behaves, not as "non-alphanumeric", which was
    # the round-2 wording and was still an overclaim -- a port written any of
    # those ways is invisible to RB-6 AND to RB-10.
    rb_badports_wide() {    # rb_badports_wide DOC -> one line per port that is neither
        awk -v p5="$rb_p5port" -v prod="$rb_prodport" -v doc="$(basename "$1")" '
            {
                s = " " $0
                while (match(s, "([Pp]orts?[ \t]+`?|[^A-Za-z0-9_.:-]:|`)[0-9][0-9][0-9][0-9]?[0-9]?(`|[^0-9`]|$)")) {
                    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART+RLENGTH)
                    n = t; gsub(/[^0-9]/, "", n)
                    if (n != p5 && n != prod)
                        printf "  %s:%d names port %s -- the tree uses %s (P5) and %s (production) and no other\n", doc, NR, n, p5, prod
                }
            }
        ' "$1"
    }
    rb10_out=$(
        [ -n "$rb_p5port" ]   || echo "  cannot derive P5's port: no AGG_PORT= line in deploy/p5/bond-xctl"
        [ -n "$rb_prodport" ] || echo "  cannot derive the production port: no engarde-server listener in the 2026-08-30 server inventory"
        rb_badports_wide "$RB_DOC"
    )
    rb10_n=$(printf '%s' "$rb10_out" | grep -c . )
    [ -n "$rb10_out" ] && printf '%s\n' "$rb10_out"
    chk "$(yn "$([ "$rb10_n" = 0 ]; echo $?)")" \
        "RB-10" "every port-shaped number the runbook names -- 'port N', a BARE ':N' whose colon follows whitespace or punctuation OTHER THAN - . _ : , or a backticked bare number, 3 to 5 digits -- is P5's own $rb_p5port or the production port $rb_prodport ($rb10_n findings). RB-6 matches only 5xxxx, so 1194, 8472 and 443 are invisible to it and visible here; the FOREIGN-line rule on the production port stays RB-6's. NOT A HOST SUFFIX: the colon alternative's leading class is exactly [^A-Za-z0-9_.:-] , which excludes those four punctuation characters as well as every alphanumeric, so name:1194 matches nothing and neither do host-:1194 , x.:1194 or x_:1194 -- a port written any of those ways is outside this finder too"

    rb_mu5="$TMPBASE/runbook.mu5"
    cp "$RB_DOC" "$rb_mu5"
    printf '\n- start the second feeder from `/sbin/p5-feeder2` before the first.\n' >> "$rb_mu5"
    rb_mu5_out=$(rb_undeclared_wide "$rb_mu5")
    rb_mu5_rb1=$(rb_undeclared "$rb_mu5")
    chk "$(yn "$(echo "$rb_mu5_out" | grep -q '/sbin/p5-feeder2' \
                 && ! echo "$rb_mu5_rb1" | grep -q 'p5-feeder2'; echo $?)")" \
        "MU-RB5" "MUTATION: a copy of the runbook told to start a SECOND FEEDER from /sbin/p5-feeder2 -- U141 folded that service away and no row ships it -- and RB-9's finder names it WHILE RB-1's finder does not. Both halves are asserted: the first says RB-9 can fail, the second says it is not duplicating a bar that already existed"

    rb_mu6="$TMPBASE/runbook.mu6"
    cp "$RB_DOC" "$rb_mu6"
    printf '\n- the feeder listens on port 8472 in this deployment.\n' >> "$rb_mu6"
    rb_mu6_out=$(rb_badports_wide "$rb_mu6")
    rb_mu6_rb6=$(rb_badports "$rb_mu6")
    chk "$(yn "$(echo "$rb_mu6_out" | grep -q '8472' \
                 && ! echo "$rb_mu6_rb6" | grep -q '8472'; echo $?)")" \
        "MU-RB6" "MUTATION: a copy of the runbook naming port 8472, which nothing in the tree listens on, and RB-10's finder names it WHILE RB-6's finder does not -- 8472 is outside RB-6's 5xxxx regex. RB-10 can fail, and it catches what RB-6 structurally cannot"

    # =======================================================================
    # RB-11 .. RB-15 (U213) -- THE LADDER'S OWN PROPERTIES.
    #
    # RB-1..RB-10 check that the document agrees with the tree about paths,
    # ports, payload rows and mode names. They say nothing about the four
    # things that make a DEPLOY LADDER either safe or fatal:
    #   which BOX a command runs on          -> RB-11
    #   which ORDER the rungs are executed in -> RB-12
    #   whether a removal is bounded          -> RB-13
    #   whether the prerequisites are IN the tree the package is built from
    #                                         -> RB-14
    #   whether a verb the operator is told to type EXISTS -> RB-15
    # The client is recoverable and the server is not, so "a command on the
    # wrong box" is the one class of operator error a document can be made to
    # refuse mechanically. That is RB-11's whole justification.
    # =======================================================================

    # --- RB-11: one box label per fenced command -------------------------------
    # Fences are typed: ```sh holds commands, ```text holds output quoted from
    # the code that prints it. Only sh fences are label-checked, and an untyped
    # or differently-typed fence is itself a finding, so a command cannot dodge
    # the rule by being written in an unlabelled block.
    rb_labels() {           # rb_labels DOC -> one line per unlabelled/mislabelled command
        awk -v doc="$(basename "$1")" '
            /^```/ {
                if (inf) { inf=0; nsh=0; next }
                inf=1; info=substr($0,4); gsub(/[ \t\r]/,"",info)
                if (info != "sh" && info != "text")
                    printf "  %s:%d opens a fenced block whose info string is \"%s\" -- every fence is `sh` (commands, labelled) or `text` (output, not labelled)\n", doc, NR, info
                nsh = (info=="sh"); if (nsh) nshseen++
                cont=0
                next
            }
            inf && nsh {
                if ($0 ~ /^[ \t]*$/) next
                if (cont) { cont = ($0 ~ /\\[ \t]*$/); next }
                cont = ($0 ~ /\\[ \t]*$/)
                line=$0; n=gsub(/\[(PC|CLIENT|SERVER)\]/, "&", line)
                if ($0 !~ /^\[(PC|CLIENT|SERVER)\] /)
                    printf "  %s:%d a fenced sh command does not begin with a [PC]/[CLIENT]/[SERVER] label: %s\n", doc, NR, substr($0,1,72)
                else if (n != 1)
                    printf "  %s:%d a fenced sh command carries %d box labels; exactly one is the rule: %s\n", doc, NR, n, substr($0,1,72)
            }
            END {
                if (inf) printf "  %s: a fenced block is never closed\n", doc
                if (nshseen == 0) printf "  %s: the document has no `sh` fence at all -- a runbook with no commands is not a runbook\n", doc
            }
        ' "$1"
    }
    rb11_out=$(rb_labels "$RB_DOC")
    rb11_n=$(printf '%s' "$rb11_out" | grep -c . )
    [ -n "$rb11_out" ] && printf '%s\n' "$rb11_out"
    chk "$(yn "$([ "$rb11_n" = 0 ]; echo $?)")" \
        "RB-11" "every fenced block in the runbook is typed \`sh\` or \`text\`, and every command line in an sh fence begins with exactly one of [PC], [CLIENT] or [SERVER] ($rb11_n findings). The client is recoverable and the server is not, so a command run on the wrong box is the one operator error a document can refuse by machine"

    # --- RB-12: the ladder is in G2 order, and two verbs appear nowhere ---------
    # The rung headings are the spine. The order is not a preference: the old
    # stack must be quiescent BEFORE P5 is installed alongside it, P5 must carry
    # traffic BEFORE any old byte is unlinked, and the removal is last because it
    # is the only step with no rollback. The two refused strings are the two ways
    # to collapse that: the composite reset verb runs all three halves in one
    # command, and the both-scope cleanliness check answers NOT CLEAN on every
    # box that has reached S2 and would tell the operator to undo the install.
    rb_rung_line() {        # rb_rung_line DOC RUNG -> line number of its heading
        grep -n "^## $2 " "$1" | head -1 | cut -d: -f1
    }
    rb_fenced_first() {     # rb_fenced_first DOC TEXT -> line of the first sh-fenced use
        awk -v pat="$2" '
            /^```/ { if (inf) { inf=0; nsh=0; next } inf=1; nsh=(substr($0,4) ~ /^sh[ \t\r]*$/); next }
            inf && nsh && index($0,pat) { print NR; exit }
        ' "$1"
    }
    rb_ladder() {           # rb_ladder DOC -> one line per ordering/vocabulary finding
        _rl_doc="$1"
        _rl_prev=0
        for _rl_r in T1 S0 S1 S2 S3 S4; do
            _rl_c=$(grep -c "^## $_rl_r " "$_rl_doc")
            [ "$_rl_c" = 1 ] || echo "  the rung heading '## $_rl_r ' appears $_rl_c time(s); exactly one is the rule"
            _rl_l=$(rb_rung_line "$_rl_doc" "$_rl_r")
            [ -n "$_rl_l" ] || _rl_l=0
            if [ "$_rl_l" -le "$_rl_prev" ]; then
                echo "  rung $_rl_r's heading is at :$_rl_l, which is not after the rung before it (:$_rl_prev) -- the ladder is not in T1,S0,S1,S2,S3,S4 order"
            fi
            _rl_prev=$_rl_l
        done
        # Each ladder verb's FIRST FENCED use must fall inside its own rung. Prose
        # and quoted output are not scanned: S0's CHECK legitimately quotes the
        # remedy line that names the S1 verb, and a bar that read it would force
        # the document to hide the remedy the code prints.
        for _rl_pair in "--quiescent:S0" "--switch-off:S1" "p5-install --package:S2" "p5 on:S3" "--remove-old:S4"; do
            _rl_pat=${_rl_pair%:*}; _rl_rung=${_rl_pair##*:}
            _rl_at=$(rb_fenced_first "$_rl_doc" "$_rl_pat")
            if [ -z "$_rl_at" ]; then
                echo "  no fenced command in the runbook contains '$_rl_pat', and rung $_rl_rung is where the ladder puts it"
                continue
            fi
            _rl_s=$(rb_rung_line "$_rl_doc" "$_rl_rung"); [ -n "$_rl_s" ] || _rl_s=0
            _rl_e=$(awk -v s="$_rl_s" 'NR>s && /^## /{print NR; exit}' "$_rl_doc")
            [ -n "$_rl_e" ] || _rl_e=$(( $(grep -c '' "$_rl_doc") + 1 ))
            if [ "$_rl_at" -lt "$_rl_s" ] || [ "$_rl_at" -ge "$_rl_e" ]; then
                echo "  the first FENCED use of '$_rl_pat' is at :$_rl_at, outside rung $_rl_rung (:$_rl_s to :$((_rl_e - 1))) -- the ladder is out of G2 order"
            fi
        done
        grep -n -- '--purge' "$_rl_doc" | while IFS=: read -r _rl_n _rl_rest; do
            echo "  :$_rl_n names the composite reset verb. The ladder never uses it: the install, the switch-on and the soak belong BETWEEN the two old-stack halves, and one command that runs all three has no rung to stop at"
        done
        grep -n -- '--check --scope both' "$_rl_doc" | while IFS=: read -r _rl_n _rl_rest; do
            echo "  :$_rl_n names the both-scope cleanliness check. It runs the P5 half FIRST and answers 'P5 half: NOT CLEAN -- run --remove' on every box that has reached S2, so as a pre-switch gate it tells the operator to undo the install they just made. The gate is --quiescent"
        done
    }
    rb12_out=$(rb_ladder "$RB_DOC")
    rb12_n=$(printf '%s' "$rb12_out" | grep -c . )
    [ -n "$rb12_out" ] && printf '%s\n' "$rb12_out"
    chk "$(yn "$([ "$rb12_n" = 0 ]; echo $?)")" \
        "RB-12" "the runbook's six rung headings are T1,S0,S1,S2,S3,S4 exactly once each and in that order, the first FENCED use of --quiescent / --switch-off / p5-install --package / p5 on / --remove-old falls inside S0/S1/S2/S3/S4 respectively, and neither the composite reset verb nor the both-scope cleanliness check appears anywhere ($rb12_n findings)"

    # --- RB-13: no recursive removal is written down ---------------------------
    # The same doctrine RMRF-0 holds over the removal path's SOURCE, held here
    # over the document that tells a human what to type. RULE ZERO: this bar
    # asserts on TEXT and executes nothing; the mutation below appends the
    # string to a scratch copy of a markdown file and greps it.
    rb_norecurse() {        # rb_norecurse DOC -> one line per recursive removal written down
        grep -nE '(^|[];&|(`]|then|else|do)[[:space:]]*rm[[:space:]]+-[A-Za-z]*[rR]' "$1" \
            | sed "s|^\([0-9]*\):.*|  $(basename "$1"):\1 writes a recursive rm in command position -- the removal path has ZERO of them (RMRF-0) and a document that teaches one puts it back by hand|"
        grep -nE '[-][-]recursive' "$1" \
            | sed "s|^\([0-9]*\):.*|  $(basename "$1"):\1 writes the long-form recursive flag|"
        grep -nE 'find[^|]*[-]delete' "$1" \
            | sed "s|^\([0-9]*\):.*|  $(basename "$1"):\1 writes a find that deletes what it matches -- unbounded by the same argument|"
    }
    rb13_out=$(rb_norecurse "$RB_DOC")
    rb13_n=$(printf '%s' "$rb13_out" | grep -c . )
    [ -n "$rb13_out" ] && printf '%s\n' "$rb13_out"
    chk "$(yn "$([ "$rb13_n" = 0 ]; echo $?)")" \
        "RB-13" "the runbook writes down no recursive removal at all -- no rm with a recursive flag in command position, no long-form spelling of it, no find that deletes ($rb13_n findings). RMRF-0 holds the removal path's source to zero; this holds the document that tells a human what to type to the same number"

    # --- RB-14: the prerequisite merges are IN this tree ------------------------
    # The runbook's own section 0c says no box step may be taken until five
    # merges are in the tree the package was built from. That claim is worth
    # exactly what resolving it is worth, so it is resolved: every sha in the
    # table must be a commit in THIS repository and an ancestor of THIS
    # checkout. Like P-2, a tree with no reachable git FAILS this bar rather
    # than skipping it -- a prerequisite nobody can resolve is not a
    # prerequisite.
    rb_shas() {             # rb_shas DOC -> one line per unresolvable/missing prerequisite
        _rs_doc="$1"
        _rs_rows=$(rb_region "$_rs_doc" RB-SHAS-BEGIN RB-SHAS-END | grep '^|' | grep -v '^|---')
        if [ -z "$_rs_rows" ]; then
            echo "  the runbook has no RB-SHAS prerequisite table, so its own 'do not touch a box before these merged' rule resolves to nothing"
            return 0
        fi
        for _rs_u in U208 U209 U210 U211 U216; do
            printf '%s\n' "$_rs_rows" | awk -F'|' -v u="$_rs_u" '{gsub(/[ \t]/,"",$2); if ($2==u) f=1} END{exit !f}' \
                || echo "  the prerequisite table does not carry a row for $_rs_u, and that merge is what makes one of the rungs safe"
        done
        if command -v git >/dev/null 2>&1 && git -C "$_rb_repo" rev-parse --git-dir >/dev/null 2>&1; then
            printf '%s\n' "$_rs_rows" | while IFS='|' read -r _rs_x _rs_unit _rs_sha _rs_rest; do
                _rs_unit=$(printf '%s' "$_rs_unit" | tr -d ' \t')
                _rs_sha=$(printf '%s' "$_rs_sha" | tr -d ' \t')
                case "$_rs_unit" in ''|unit) continue ;; esac
                case "$_rs_sha" in
                    ''|*[!0-9a-f]*) echo "  prerequisite row $_rs_unit carries '$_rs_sha', which is not a hex object name"; continue ;;
                esac
                if ! git -C "$_rb_repo" cat-file -e "${_rs_sha}^{commit}" 2>/dev/null; then
                    echo "  prerequisite row $_rs_unit names $_rs_sha and no such commit exists in this repository"
                elif ! git -C "$_rb_repo" merge-base --is-ancestor "$_rs_sha" HEAD 2>/dev/null; then
                    echo "  prerequisite row $_rs_unit names $_rs_sha and it is NOT an ancestor of this checkout -- the package this tree builds does not contain it"
                fi
            done
        else
            echo "  cannot reach a git repository to resolve the prerequisite shas -- this bar FAILS rather than skipping, the rule P-2 uses for the same reason"
        fi
        grep -qF 'P5_GIT_COMMIT' "$_rs_doc" \
            || echo "  no CHECK reads P5_GIT_COMMIT back off the box, so nothing compares the prerequisite table with what was actually installed"
    }
    rb14_out=$(rb_shas "$RB_DOC")
    rb14_n=$(printf '%s' "$rb14_out" | grep -c . )
    [ -n "$rb14_out" ] && printf '%s\n' "$rb14_out"
    chk "$(yn "$([ "$rb14_n" = 0 ]; echo $?)")" \
        "RB-14" "the runbook's section 0c names a prerequisite merge for U208, U209, U210, U211 and U216, every sha in that table resolves to a commit in THIS repository and is an ancestor of THIS checkout, and the S2 CHECK reads P5_GIT_COMMIT back off the box ($rb14_n findings). Before U210 a single reconcile at S2 re-enabled the old stack's own controller from inside P5"

    # --- RB-15: every verb the operator is told to type EXISTS -----------------
    # The verb sets are DERIVED from the four programs' own case arms, never
    # typed here, so a rename in the tree reddens this bar instead of silently
    # making the document wrong. Only COMMAND TEXT is scanned -- a backticked
    # span or a label-stripped sh-fenced line -- because prose legitimately
    # writes things like `p5 <verb>` and a scan of running text invents findings.
    rb_cmdtext() {          # rb_cmdtext DOC -> `LINE|TEXT` per backticked span / sh command
        awk '
            /^```/ { if (inf) { inf=0; nsh=0; next } inf=1; nsh=(substr($0,4) ~ /^sh[ \t\r]*$/); next }
            {
                if (inf) {
                    if (nsh) { s=$0; sub(/^\[[A-Z]*\][ \t]*/,"",s); print NR "|" s }
                    next
                }
                s=$0
                while (match(s, "`[^`]*`")) {
                    print NR "|" substr(s, RSTART+1, RLENGTH-2)
                    s = substr(s, RSTART+RLENGTH)
                }
            }
        ' "$1"
    }
    rb_caseverbs() {        # rb_caseverbs FILE INDENTRE -> the case-arm labels, one per line
        awk -v re="$2" '$0 ~ re' "$1" | sed 's/).*//' | tr -d ' \t' | tr '|' '\n' \
            | grep -v '^$' | LC_ALL=C sort -u
    }
    rb_verbs() {            # rb_verbs DOC -> one line per verb the tree does not have
        _rv_doc="$1"
        _rv_un=$(awk '/^[[:space:]]*-[-a-z|]*\)/' "$_rb_repo/p5/bin/p5-uninstall" \
                    | grep -oE '\-\-[a-z][a-z-]*' | LC_ALL=C sort -u)
        _rv_in=$(awk '/^[[:space:]]*-[-a-z|]*\)/' "$_rb_repo/p5/bin/p5-install" \
                    | grep -oE '\-\-[a-z][a-z-]*' | LC_ALL=C sort -u)
        _rv_cli=$(rb_caseverbs "$_rb_repo/deploy/p5/bondctl"      '^  [a-z_][a-z_|]*[)]')
        _rv_sh=$(rb_caseverbs  "$_rb_repo/deploy/p5/shape-install" '^[[:space:]]*[a-z][a-z|]*[)]')
        _rv_dm=$(rb_caseverbs  "$_rb_repo/p5/bin/p5-deadman"       '^[[:space:]]*[a-z][a-z|]*[)]')
        [ -n "$_rv_un" ]  || echo "  could not derive p5-uninstall's option set from its own parser"
        [ -n "$_rv_in" ]  || echo "  could not derive p5-install's option set from its own parser"
        [ -n "$_rv_cli" ] || echo "  could not derive the CLI's verb set from deploy/p5/bondctl"
        [ -n "$_rv_sh" ]  || echo "  could not derive p5-shape-install's verb set"
        [ -n "$_rv_dm" ]  || echo "  could not derive p5-deadman's verb set"
        rb_cmdtext "$_rv_doc" > "$RB_W/cmd.$$"
        # options, per tool, from the command text that names that tool
        for _rv_pair in "p5-uninstall:un" "p5-install:in"; do
            _rv_tool=${_rv_pair%:*}; _rv_which=${_rv_pair##*:}
            case "$_rv_which" in un) _rv_set="$_rv_un" ;; *) _rv_set="$_rv_in" ;; esac
            while IFS='|' read -r _rv_l _rv_t; do
                case "$_rv_t" in *"$_rv_tool"*) : ;; *) continue ;; esac
                # p5-uninstall is a prefix of nothing; p5-install IS a suffix of it,
                # so the p5-install pass skips text that names the uninstaller.
                if [ "$_rv_tool" = p5-install ]; then
                    case "$_rv_t" in *p5-uninstall*) continue ;; esac
                fi
                printf '%s\n' "$_rv_t" | grep -oE '\-\-[a-z][a-z-]*' | while read -r _rv_o; do
                    printf '%s\n' "$_rv_set" | grep -qxF -- "$_rv_o" \
                        || echo "  $(basename "$_rv_doc"):$_rv_l tells the operator to type '$_rv_tool $_rv_o', and that option is not in $_rv_tool's own parser"
                done
            done < "$RB_W/cmd.$$"
        done
        # `p5 <verb>` and the two package tools' verbs
        for _rv_pair in "p5:cli" "p5-shape-install:sh" "p5-deadman:dm"; do
            _rv_tool=${_rv_pair%:*}; _rv_which=${_rv_pair##*:}
            case "$_rv_which" in
                cli) _rv_set="$_rv_cli" ;; sh) _rv_set="$_rv_sh" ;; *) _rv_set="$_rv_dm" ;;
            esac
            awk -v tool="$_rv_tool" '
                {
                    l = substr($0, 1, index($0,"|")-1)
                    s = " " substr($0, index($0,"|")+1)
                    while (match(s, "[ ;(/]" tool " [a-z][a-z-]*")) {
                        t = substr(s,RSTART,RLENGTH); s = substr(s,RSTART+RLENGTH)
                        sub("^[ ;(/]" tool " ","",t)
                        print l "|" t
                    }
                }' "$RB_W/cmd.$$" | while IFS='|' read -r _rv_l _rv_v; do
                printf '%s\n' "$_rv_set" | grep -qxF -- "$_rv_v" \
                    || echo "  $(basename "$_rv_doc"):$_rv_l tells the operator to type '$_rv_tool $_rv_v', and that verb is not in $_rv_tool's own case"
            done
        done
        rm -f "$RB_W/cmd.$$"
    }
    rb15_out=$(rb_verbs "$RB_DOC")
    rb15_n=$(printf '%s' "$rb15_out" | grep -c . )
    [ -n "$rb15_out" ] && printf '%s\n' "$rb15_out"
    chk "$(yn "$([ "$rb15_n" = 0 ]; echo $?)")" \
        "RB-15" "every option the runbook tells the operator to give p5-uninstall or p5-install is in that program's own parser, and every 'p5 <verb>', 'p5-shape-install <verb>' and 'p5-deadman <verb>' is in that program's own case ($rb15_n findings). The sets are derived from the five programs; a rename in the tree reddens this bar instead of quietly making the document wrong"

    # --- MU-RB7 .. MU-RB11: one watched failure per new bar --------------------
    rb_mu7="$TMPBASE/runbook.mu7"
    awk 'BEGIN{done=0}
         /^```sh$/ && !done { print; getline; sub(/^\[(PC|CLIENT|SERVER)\] /,""); print; done=1; next }
         { print }' "$RB_DOC" > "$rb_mu7"
    rb_mu7_out=$(rb_labels "$rb_mu7")
    rb_mu7_applied=$(( $(grep -c '^\[' "$RB_DOC") - $(grep -c '^\[' "$rb_mu7") ))
    chk "$(yn "$([ "$rb_mu7_applied" = 1 ] && echo "$rb_mu7_out" | grep -q 'does not begin with a'; echo $?)")" \
        "MU-RB7" "MUTATION: the box label stripped from the FIRST fenced command of a copy of the runbook (labels removed: $rb_mu7_applied) -> RB-11's finder names that line. RB-11 is a bar that can fail, and the shape it catches is the one that sends a client command to the box with no console"

    rb_mu8="$TMPBASE/runbook.mu8"
    awk -v v="p5-uninstall --purge" '
        {print}
        /^## S4 /{print ""; print "```sh"; print "[CLIENT] " v; print "```"}' "$RB_DOC" > "$rb_mu8"
    rb_mu8_out=$(rb_ladder "$rb_mu8")
    chk "$(yn "$(echo "$rb_mu8_out" | grep -q 'composite reset verb'; echo $?)")" \
        "MU-RB8" "MUTATION: the composite reset verb inserted into rung S4 of a copy of the runbook -> RB-12's finder names it. One command that runs switch-off, remove-old and remove has no rung to stop at, and RB-12 is a bar that can fail"

    rb_mu9="$TMPBASE/runbook.mu9"
    cp "$RB_DOC" "$rb_mu9"
    # TEXT ONLY. The string is appended to a scratch markdown file and grepped;
    # nothing here executes it, and nothing here is a path (RULE ZERO).
    printf '\n```sh\n[CLIENT] rm -%s /usr/lib/p5\n```\n' "rf" >> "$rb_mu9"
    rb_mu9_out=$(rb_norecurse "$rb_mu9")
    chk "$(yn "$(echo "$rb_mu9_out" | grep -q 'recursive rm in command position'; echo $?)")" \
        "MU-RB9" "MUTATION: a recursive rm written into a copy of the runbook (as TEXT -- this bar greps a scratch markdown file and executes nothing) -> RB-13's finder names the line. RB-13 is a bar that can fail"

    rb_mu10="$TMPBASE/runbook.mu10"
    sed 's/^| U210 | [0-9a-f]* |/| U210 | 0000000 |/' "$RB_DOC" > "$rb_mu10"
    rb_mu10_applied=$(diff "$RB_DOC" "$rb_mu10" 2>/dev/null | grep -c '^> ')
    rb_mu10_out=$(rb_shas "$rb_mu10")
    chk "$(yn "$([ "$rb_mu10_applied" = 1 ] && echo "$rb_mu10_out" | grep -q 'U210'; echo $?)")" \
        "MU-RB10" "MUTATION: U210's prerequisite sha replaced with a well-formed object name that is not in this repository (rows changed: $rb_mu10_applied) -> RB-14's finder names U210. A prerequisite table nobody resolves is a paragraph, and RB-14 is a bar that can fail"

    rb_mu11="$TMPBASE/runbook.mu11"
    sed 's/--switch-off/--switchoff/g' "$RB_DOC" > "$rb_mu11"
    rb_mu11_applied=$(grep -c -- '--switchoff' "$rb_mu11")
    rb_mu11_out=$(rb_verbs "$rb_mu11")
    chk "$(yn "$([ "$rb_mu11_applied" -ge 1 ] && echo "$rb_mu11_out" | grep -q -- '--switchoff'; echo $?)")" \
        "MU-RB11" "MUTATION: --switch-off respelled --switchoff throughout a copy of the runbook ($rb_mu11_applied occurrences) -> RB-15's finder names it against p5-uninstall's own parser. A verb the operator is told to type and the program does not have is a step that cannot be run, and RB-15 is a bar that can fail"

fi

# ===========================================================================
# RMRF-0 / NR-2 / MU-RMRF (U188) -- ZERO RECURSIVE REMOVALS, HELD BY A BAR
# ===========================================================================
# Mo's standing requirement, in his words: "uninstalling shouldn't rm so that is
# not an excuse ... it needs to be selective switch off first install and then
# remove surgically". Prose does not hold that; two bars do, and they measure
# different things on purpose:
#   RMRF-0 reads the SOURCE of every file in the removal path and requires ZERO
#          recursive-removal sites, with NO exclusion list -- an allow-list is
#          how "we only do it in the one safe place" comes back.
#   NR-2   reads the RUN. Every p5-install/p5-uninstall invocation this battery
#          makes goes out with an `rm` PATH shim in front of it that records the
#          argv and refuses any recursive form, so a green removal bar is also a
#          statement that no recursive rm was invoked at runtime.
# One is a grep over text that could be dead; the other is a ledger of what the
# code actually called. Neither alone is the claim.

# rmrf_scan FILE -> one `LINE:text` per recursive-removal SITE in FILE.
#
# COMMENT- AND STRING-STRIPPED, and that is the whole difficulty. This product
# TALKS about `rm -rf` constantly -- the uninstaller's header explains why there
# is none, one_rmdir's refusal message says forcing it would mean one, and the
# printed plan legend spells the words. A grep for the literal would match all
# of those and would then have to be quieted with an exclusion list, which is
# must-not 8. So double-quoted strings go first (every one of those mentions is
# inside one), then comments. Single-quoted spans are deliberately NOT stripped:
# `trap 'rm -rf "$WORK"' EXIT` is a real invocation and stripping it would make
# this bar blind to exactly the shape that fires on paths nobody re-checked.
# `sed` deletes no lines, so grep -n's numbers are the file's own.
#
# TWO EVASIONS THIS SCANNER HAD, EACH TWO CHARACTERS WIDE. Both were found by
# the adjudicator of this unit's first round and both were reproduced on scratch
# TEXT -- read, never executed (RULE ZERO). Neither was a product defect (`grep
# -nE '/bin/rm|busybox rm'` over the four files is 0), but a mechanical gate with
# a two-character bypass is not a gate:
#
#   1. `/bin/rm -rf "$x"`. The boundary class was `[^A-Za-z0-9_./-]`, which
#      EXCLUDES `/`, so an ABSOLUTE-PATH invocation was not a site. `/` is gone
#      from the class. This is the only half that can see that shape: NR-2's
#      runtime shim is PATH-resident, and an absolute path never consults PATH.
#      Dropping `/` widens nothing that matters -- `rmdir` in `unlink/rmdir` now
#      clears the boundary but still fails the rest of the pattern, which needs
#      whitespace and a flag after `rm`, and the negative control in MU-RMRF
#      asserts the prose in these files stays unmatched.
#   2. `rm "-rf" "$x"` and `rm '-rf' "$x"`. The string strip ran FIRST, so a
#      QUOTED FLAG was deleted before grep ever saw it. A pre-pass now un-quotes
#      a quoted span that is ENTIRELY a flag token, and only that: it removes a
#      MATCHED PAIR, so the strip that follows still sees balanced quoting, and
#      it cannot expose prose -- every `rm -rf` this product talks about is a
#      whole sentence inside one string, never a bare `"-rf"`.
rmrf_scan() {
    sed -e 's/"\(-[A-Za-z][A-Za-z]*\)"/\1/g' \
        -e "s/'\\(-[A-Za-z][A-Za-z]*\\)'/\\1/g" \
        -e 's/"[^"]*"//g' -e 's/#.*$//' "$1" \
      | grep -nEi '(^|[^A-Za-z0-9_.-])rm([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*[rR]|--recursive|[[:space:]]-delete([[:space:]]|$)|rmtree'
}

# RMRF-0: the four files that make up the removal path. NO EXCLUSION LIST, and
# the count is printed per file so the summary line is the measurement.
RMRF_FILES="$BIN/p5-uninstall $BIN/p5-install $LIB/p5-common.sh $ROOTDIR/deploy/p5/shape-install"
rmrf_counts=""; rmrf_total=0; rmrf_files_n=0
for _rf in $RMRF_FILES; do
    if [ ! -f "$_rf" ]; then
        echo "  RMRF-0: $_rf is not a file -- the bar cannot have measured it"
        rmrf_total=$((rmrf_total + 1)); rmrf_counts="$rmrf_counts ?"; continue
    fi
    rmrf_files_n=$((rmrf_files_n + 1))
    _rn=$(rmrf_scan "$_rf" | grep -c .)
    if [ "$_rn" != 0 ]; then
        echo "  $_rf -- $_rn recursive-removal site(s):"
        rmrf_scan "$_rf" | sed 's/^/    /'
    fi
    rmrf_counts="$rmrf_counts $_rn"; rmrf_total=$((rmrf_total + _rn))
done
chk "$(yn "$([ "$rmrf_total" = 0 ] && [ "$rmrf_files_n" = 4 ]; echo $?)")" \
    "RMRF-0" "ZERO recursive removals in the removal path, counted per file (p5-uninstall p5-install p5-common.sh shape-install ->$rmrf_counts) over $rmrf_files_n files, comment- and string-stripped, with NO exclusion list: no rm with an r/R flag, no --recursive, no -delete, no rmtree"

# NR-2: THE RUN, NOT THE SOURCE -- and RULE ZERO MADE MECHANICAL.
# The shim is asserted NEVER TO `exec`: a shim that replaced itself with the
# real rm would be the measurement and the thing measured in one process, which
# is precisely how the containment in an earlier A/B harness vanished unnoticed
# (docs/knowledge/root-causes/2026-09-03-bin-deletion.md). It is invoked BY ITS
# OWN PATH in the A/B below, never through PATH resolution, so a broken or
# missing shim can fail this bar but can never fall through to a real recursive
# rm. The recursive argv is therefore ASSERTED ON, never executed.
nr2=0
nr_exec=$(grep -c 'exec' "$RMSHIM/rm" 2>/dev/null); [ -n "$nr_exec" ] || nr_exec=?
[ "$nr_exec" = 0 ] || { nr2=1; echo "  the rm shim contains $nr_exec line(s) matching 'exec' -- RULE ZERO forbids a measuring shim that replaces itself with what it measures"; }
nr_lines=$(grep -c . "$RMLEDGER" 2>/dev/null); [ -n "$nr_lines" ] || nr_lines=0
[ "$nr_lines" -gt 0 ] || { nr2=1; echo "  the argv ledger is EMPTY -- the shim was never reached, so a green run says nothing"; }
nr_ref=$(grep -c '^REFUSED ' "$RMLEDGER" 2>/dev/null); [ -n "$nr_ref" ] || nr_ref=0
[ "$nr_ref" = 0 ] || { nr2=1; echo "  a shimmed run invoked a recursive rm:"; grep '^REFUSED ' "$RMLEDGER" | sed 's/^/    /'; }
NRD="$TMPBASE/nr2"; mkdir -p "$NRD/keepdir"
printf 'x\n' > "$NRD/keepdir/keep"; printf 'y\n' > "$NRD/plain"
"$RMSHIM/rm" -rf "$NRD/keepdir" >/dev/null 2>&1; nr_rc=$?
[ "$nr_rc" = 1 ] || { nr2=1; echo "  the shim did not REFUSE a recursive form (rc=$nr_rc)"; }
[ -f "$NRD/keepdir/keep" ] || { nr2=1; echo "  the refused recursive rm REMOVED something -- the shim is not containment"; }
grep -q "^REFUSED rm -rf $NRD/keepdir\$" "$RMLEDGER" || { nr2=1; echo "  the refused argv was not logged verbatim"; }
"$RMSHIM/rm" -f "$NRD/plain" >/dev/null 2>&1; nr_prc=$?
[ "$nr_prc" = 0 ] || { nr2=1; echo "  the shim refused a NON-recursive rm (rc=$nr_prc) -- it is broken, not selective"; }
[ -e "$NRD/plain" ] && { nr2=1; echo "  the shim did not actually remove a non-recursive target -- it is inert, so its silence is worthless"; }
nr_path=$(PATH="$RMSHIM:$PATH" sh -c 'command -v rm' 2>/dev/null)
[ "$nr_path" = "$RMSHIM/rm" ] || { nr2=1; echo "  PATH interception is not in force: 'rm' resolves to '${nr_path:-nothing}', not the shim"; }
chk "$(yn "$([ "$nr2" = 0 ]; echo $?)")" \
    "NR-2" "the rm argv shim never execs ($nr_exec 'exec' lines), it was really reached ($nr_lines argv line(s) recorded) and NOT ONE of the battery's shimmed install/uninstall runs invoked a recursive rm ($nr_ref refusals); the shim itself refuses -rf with the argv logged and nothing removed (rc=$nr_rc), still removes a non-recursive target (rc=$nr_prc), and PATH resolves rm to it"

# MU-RMRF: THE SEED. Put back exactly what this unit took out -- a recursive
# removal of the declared old-stack `dir` row, the shape the OLDDIR arm
# carried on dev -- in a COPY, and require RMRF-0's own scanner to name it.
# Cited by ARM NAME and not by line: a line number into a file this unit is
# rewriting rots before the commit lands.
#
# STATIC ONLY, AND DELIBERATELY SO. The mutant is never RUN. Its line is
# `rm -rf "${P5_ROOT}${_ox_p}"`, and with P5_ROOT empty that argv is the
# ABSOLUTE path /etc/bond on this machine -- the exact shape that unlinked /bin
# here on 2026-09-03. RULE ZERO: a destructive defect is proved on the ARGV, and
# the argv is what this bar reads. NR-2 above already proves, independently and
# without ever executing one, that a recursive form reaching the runtime is
# refused with its argv recorded.
MURD="$TMPBASE/murmrf"; mkdir -p "$MURD"
sed 's:if one_rmdir "\$_ox_p"; then:if rm -rf "${P5_ROOT}${_ox_p}" 2>/dev/null; then:' \
    "$BIN/p5-uninstall" > "$MURD/p5-uninstall"
d=0
mu_applied=$(diff "$BIN/p5-uninstall" "$MURD/p5-uninstall" 2>/dev/null | grep -c '^>')
[ "$mu_applied" = 1 ] || { d=1; echo "  MUTATION DID NOT APPLY as one line ($mu_applied changed) -- the OLDRMDIR site was not found"; }
mu_n=$(rmrf_scan "$MURD/p5-uninstall" | grep -c .)
[ "$mu_n" -ge 1 ] || { d=1; echo "  RMRF-0's scanner did NOT see the restored recursive removal -- the bar cannot fail"; }
rmrf_scan "$MURD/p5-uninstall" | sed 's/^/    seeded site: /'
mu_ctl=$(rmrf_scan "$BIN/p5-uninstall" | grep -c .)
[ "$mu_ctl" = 0 ] || { d=1; echo "  the CONTROL (the shipped file) is not clean, so the comparison says nothing"; }
# THE TWO EVASIONS, AS MUTANTS. One line of this bar per two-character bypass
# the first round's scanner had, in the SAME arm and the same shape as the
# mutant above, because "we fixed the regex" is a claim about a regex and this
# is a claim about the file. `/bin/rm` is the one the runtime shim can never
# cover (it is PATH-resident; an absolute path does not consult PATH), and the
# quoted flag is the one the string-strip used to swallow. NEITHER IS EXECUTED,
# for the reason stated above: these copies are read by the scanner and by
# nothing else, and no shell ever interprets them.
for _mue in abs qf; do
    case "$_mue" in
        abs) sed 's:if one_rmdir "\$_ox_p"; then:if /bin/rm -rf "${P5_ROOT}${_ox_p}" 2>/dev/null; then:' \
                 "$BIN/p5-uninstall" > "$MURD/p5-uninstall.$_mue"
             _mud="an ABSOLUTE-PATH \`/bin/rm -rf\`" ;;
        qf)  sed 's:if one_rmdir "\$_ox_p"; then:if rm "-rf" "${P5_ROOT}${_ox_p}" 2>/dev/null; then:' \
                 "$BIN/p5-uninstall" > "$MURD/p5-uninstall.$_mue"
             _mud="a QUOTED-FLAG \`rm \"-rf\"\`" ;;
    esac
    _mua=$(diff "$BIN/p5-uninstall" "$MURD/p5-uninstall.$_mue" 2>/dev/null | grep -c '^>')
    [ "$_mua" = 1 ] || { d=1; echo "  the $_mue mutation did not apply as one line ($_mua changed)"; }
    _mun=$(rmrf_scan "$MURD/p5-uninstall.$_mue" | grep -c .)
    [ "$_mun" -ge 1 ] || { d=1; echo "  RMRF-0's scanner is BLIND to $_mud -- a two-character bypass of the gate Mo's requirement rests on"; }
    rmrf_scan "$MURD/p5-uninstall.$_mue" | sed "s/^/    seeded site ($_mue): /"
    eval "mu_$_mue=\$_mun"
done
# AND THE NEGATIVE CONTROL, which is the half a widened regex breaks. The four
# shipped files TALK about `rm -rf` -- in comments, in one_rmdir's refusal, in
# the printed plan legend -- and RMRF-0 counts 0 on them (asserted just above,
# and by RMRF-0 itself). This probe is the same claim made deliberately rather
# than incidentally: the prose shapes, plus `unlink/rmdir`, which only clears
# the boundary class because `/` was dropped from it. TEXT, never run.
MUPROBE="$MURD/prose-probe.txt"
{
    printf '%s\n' 'p5_err "  rmdir is deliberate. Forcing it would mean rm -rf on a directory whose"'
    printf '%s\n' '# the header says why there is no rm -rf here'
    printf '%s\n' 'echo "RMTREE  rm -rf <dir>   -- the arm this unit removed"'
    printf '%s\n' '# p5_removable ROLE PATH KIND -> 0 if --remove may unlink/rmdir PATH.'
    printf '%s\n' 'rm -f "${P5_ROOT}${_ox_p}" 2>/dev/null'
    printf '%s\n' 'one_rmdir "$_ox_p"'
} > "$MUPROBE"
mu_prose=$(rmrf_scan "$MUPROBE" | grep -c .)
[ "$mu_prose" = 0 ] || { d=1; echo "  the widened scanner now matches PROSE and non-recursive removals -- that is how an exclusion list gets born (must-not 8):"; rmrf_scan "$MUPROBE" | sed 's/^/    /'; }
chk "$(yn "$([ "$d" = 0 ]; echo $?)")" \
    "MU-RMRF" "MUTATION x3, one per evasion the scanner must not have: the old half's OLDRMDIR restored to \`rm -rf \"\${P5_ROOT}\${_ox_p}\"\` in a COPY ($mu_applied line changed) -> $mu_n site(s); to \`/bin/rm -rf\` -> $mu_abs site(s) (the shape NR-2's PATH shim can NEVER see); to \`rm \"-rf\"\` -> $mu_qf site(s) (the shape the string-strip used to swallow); and $mu_ctl in the shipped file, with $mu_prose in a probe of the prose and non-recursive shapes these files really contain. RMRF-0 is a bar that can fail, and it did not become a literal grep needing an exclusion list. NO MUTANT IS EVER EXECUTED: with P5_ROOT empty those argvs are absolute paths on this machine (RULE ZERO)"

# ===========================================================================
# PK-4 / MU-PK4 -- MECHANICAL PAYLOAD COMPLETENESS (U176 folded into U211)
# ===========================================================================
# THE DEFECT THIS EXISTS TO CATCH, measured: deploy/p5/bond-accept IS feature
# F23 ("validates a P5 install on the box"), deploy/p5/p5-client-preflight.sh is
# the client's preflight and deploy/server/p5-server-preflight.sh the server's.
# All three were in NEITHER p5/payload/filemap NOR the filemap header's
# deliberately-not-shipped list, so the only way to run any of them on a box was
# to scp it by hand -- the exact hand-copy path the package exists to replace.
# Every gate was green the whole time, because nothing anywhere asked the
# question "is every file under deploy/ accounted for".
#
# It is PK-4 and not PK-1 because PK-1 above is already taken by the sibling
# question (every file a shipped program SOURCES is itself shipped -- the U124
# xctl-lib defect). PK-1 asks whether the payload is enough for what it ships to
# RUN; PK-4 asks whether the payload is everything that should be in it.
#
# THREE ACCOUNTS, AND EXACTLY ONE PER FILE:
#   1. the filemap's src column                 -- p5-install places it
#   2. the builder's package-tool copy list     -- it rides in the package and
#      runs from there (p5-install's own precedent). PARSED OUT OF
#      scripts/build-p5-package.sh, never hand-listed here: a second hand-list
#      is a second thing to drift.
#   3. an `# EXCLUDE|<glob>|<reason>` line in the filemap header
# EXACTLY ONE, not at least one: a file that starts riding in the package as a
# tool has to LOSE its EXCLUDE line in the same commit, or this bar names it.
# That is what stops the exclusion list from becoming a place where a shipped
# file's stale reason for not shipping sits unread.
#
# THE MATCHER IS A POSIX `case`, so `*` spans `/` and `deploy/p5/portal/*`
# covers every depth beneath it. U176's own first cut of this check compared a
# file's immediate parent directory and manufactured eight false findings out of
# the portal alone; a completeness check whose matcher is incomplete invents
# work, and invented work is how a real finding gets lost.
pk4_tools() {           # every repo path under deploy/ the BUILDER copies
    sed 's/#.*//' "$_pk_repo/scripts/build-p5-package.sh" \
        | grep -E '(^|[;&|(]|[[:space:]])cp[[:space:]]' \
        | sed -n 's|.*[$]REPO/\(deploy/[A-Za-z0-9_./-]*\).*|\1|p' \
        | LC_ALL=C sort -u | while read -r _pk4t; do
            [ -n "$_pk4t" ] || continue
            if [ -d "$_pk_repo/$_pk4t" ]; then
                ( cd "$_pk_repo" && find "$_pk4t" -type f )
            elif [ -f "$_pk_repo/$_pk4t" ]; then
                echo "$_pk4t"
            fi
        done
}
# pk4_audit FILEMAP -> one line per file that is in no account or in more than
# one. Takes the filemap as an ARGUMENT so MU-PK4 can hand it a mutated copy;
# a finder that can only read the shipped file is a finder nobody can seed.
pk4_audit() {
    _pk4f=$1
    grep -v '^#' "$_pk4f" | cut -d'|' -f3 | grep '^deploy/' \
        | LC_ALL=C sort -u > "$TMPBASE/pk4.ship"
    sed -n 's/^# EXCLUDE|\([^|]*\)|.*/\1/p' "$_pk4f" > "$TMPBASE/pk4.excl"
    ( cd "$_pk_repo" && find deploy -type f ) | LC_ALL=C sort > "$TMPBASE/pk4.all"
    while read -r _pk4x; do
        _pk4n=0
        grep -qxF "$_pk4x" "$TMPBASE/pk4.ship" && _pk4n=$((_pk4n + 1))
        grep -qxF "$_pk4x" "$TMPBASE/pk4.tool" && _pk4n=$((_pk4n + 1))
        while read -r _pk4g; do
            [ -n "$_pk4g" ] || continue
            # shellcheck disable=SC2254
            case "$_pk4x" in
                $_pk4g) _pk4n=$((_pk4n + 1)); break ;;
            esac
        done < "$TMPBASE/pk4.excl"
        if [ "$_pk4n" = 0 ]; then
            echo "  UNACCOUNTED $_pk4x -- not a filemap src, not copied by the builder, no EXCLUDE glob covers it"
        elif [ "$_pk4n" -gt 1 ]; then
            echo "  DOUBLE-COUNTED $_pk4x -- accounted for $_pk4n times; a file rides in exactly one of the three"
        fi
    done < "$TMPBASE/pk4.all"
}
pk4_tools > "$TMPBASE/pk4.tool"
pk4_out=$(pk4_audit "$P5DIR/payload/filemap")
pk4_n=$(printf '%s' "$pk4_out" | grep -c .)
pk4_t=$(grep -c . "$TMPBASE/pk4.all")
pk4_k=$(grep -c . "$TMPBASE/pk4.tool")
[ -n "$pk4_out" ] && printf '%s\n' "$pk4_out"
chk "$(yn "$([ "$pk4_n" = 0 ] && [ "$pk4_t" -gt 0 ]; echo $?)")" \
    "PK-4" "all $pk4_t files under deploy/ are accounted for exactly once ($pk4_n offenders; $pk4_k package-tool copies parsed out of the builder). A file that is neither shipped nor deliberately excluded is one nobody decided about, and scp is what happens next"

# MU-PK4 -- THE SEED, both directions. A bar nobody has watched fail is not a
# bar, and this one has two ways to fail, so both are seeded.
#   (a) drop the p5-accept row from a COPY of the filemap -> UNACCOUNTED, and
#       the offender line must name deploy/p5/bond-accept, not just a count.
#   (b) add an EXCLUDE glob over a file the filemap already ships ->
#       DOUBLE-COUNTED. Without (b) the "exactly one" half would be untested
#       and an exclusion could silently shadow a shipped row.
pk4_mut="$TMPBASE/filemap.mu-pk4"
grep -v '^755|client|deploy/p5/bond-accept|' "$P5DIR/payload/filemap" > "$pk4_mut"
pk4_mua=$(pk4_audit "$pk4_mut")
pk4_applied=$(( $(grep -c . "$P5DIR/payload/filemap") - $(grep -c . "$pk4_mut") ))
pk4_mut2="$TMPBASE/filemap.mu-pk4b"
{ echo '# EXCLUDE|deploy/p5/bondctl|seeded overlap, not a real exclusion'
  cat "$P5DIR/payload/filemap"; } > "$pk4_mut2"
pk4_mub=$(pk4_audit "$pk4_mut2")
pk4_sa=0; pk4_sb=0
echo "$pk4_mua" | grep -q 'UNACCOUNTED deploy/p5/bond-accept' || pk4_sa=1
echo "$pk4_mub" | grep -q 'DOUBLE-COUNTED deploy/p5/bondctl' || pk4_sb=1
chk "$(yn "$([ "$pk4_applied" = 1 ] && [ "$pk4_sa" = 0 ] && [ "$pk4_sb" = 0 ]; echo $?)")" \
    "MU-PK4" "MUTATION x2: the p5-accept row removed from a copy of the filemap -> PK-4's finder names deploy/p5/bond-accept UNACCOUNTED (rows removed: $pk4_applied), and an EXCLUDE glob laid over a shipped row -> DOUBLE-COUNTED deploy/p5/bondctl. PK-4 is able to fail in both of its directions"

# ===========================================================================
# RP-1..RP-3 -- ROLE PLACEMENT OF THE THREE VALIDATORS (G6/F23, U211)
# ===========================================================================
# The rows above are a claim about what p5-install DOES. These bars drive the
# real installer over the REAL repo filemap and read the answer back.
#
# WHY A FIXTURE OF ITS OWN AND NOT mkpkg's. mkpkg fabricates a three-row
# filemap in synthetic mode and copies the built package in real mode; neither
# is a statement about the filemap this repo ships, and under `ci-wsl.sh e0`
# the mode is synthetic. This fixture IS p5/payload/filemap, byte for byte,
# with a stub standing in for the two Go binaries nothing here builds. So a row
# deleted from the shipped filemap reddens these bars, which is the property
# they exist for.
mkpkg_repo() {          # mkpkg_repo DIR -- a package whose payload IS the repo filemap
    _rpd=$1
    rm -rf "$_rpd"; mkdir -p "$_rpd/payload"
    cp "$P5DIR/payload/filemap" "$_rpd/payload/filemap"
    grep -v '^#' "$P5DIR/payload/filemap" | while IFS='|' read -r _rpm _rpr _rps _rpdst; do
        [ -n "${_rps:-}" ] || continue
        mkdir -p "$_rpd/payload/$(dirname "$_rps")"
        if [ -f "$_pk_repo/$_rps" ]; then cp -p "$_pk_repo/$_rps" "$_rpd/payload/$_rps"
        else printf '#!/bin/sh\nexit 0\n' > "$_rpd/payload/$_rps"; fi
        chmod "$_rpm" "$_rpd/payload/$_rps"
    done
    cp "$PROV" "$_rpd/PROVENANCE"
    ( cd "$_rpd" && find payload -type f | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256 )
}
RPP=$TMPBASE/rp-pkg; mkpkg_repo "$RPP"

# RP-1: --role client places the two client validators and NOT the server one.
# The negative half is the half that matters: a role filter that ignored the
# role column would still put p5-accept on the box and would read as green.
inst "$TMPBASE/rp-c" "$RPP" client --dry-run; rc=$?
rp_a=0
grep -q '/usr/sbin/p5-accept' "$TMPBASE/out" || { rp_a=1; echo "  client dry-run does not place /usr/sbin/p5-accept"; }
grep -q '/usr/sbin/p5-client-preflight' "$TMPBASE/out" || { rp_a=1; echo "  client dry-run does not place /usr/sbin/p5-client-preflight"; }
grep -q '/usr/sbin/p5-server-preflight' "$TMPBASE/out" && { rp_a=1; echo "  client dry-run places the SERVER preflight"; }
chk "$(yn "$([ "$rc" = 0 ] && [ "$rp_a" = 0 ]; echo $?)")" \
    "RP-1" "--role client over the real filemap places p5-accept and p5-client-preflight and NOT p5-server-preflight (rc=$rc)"

# RP-2: --role server, the mirror image.
inst "$TMPBASE/rp-s" "$RPP" server --dry-run; rc=$?
rp_b=0
grep -q '/usr/sbin/p5-server-preflight' "$TMPBASE/out" || { rp_b=1; echo "  server dry-run does not place /usr/sbin/p5-server-preflight"; }
grep -q '/usr/sbin/p5-accept' "$TMPBASE/out" && { rp_b=1; echo "  server dry-run places the client's p5-accept"; }
grep -q '/usr/sbin/p5-client-preflight' "$TMPBASE/out" && { rp_b=1; echo "  server dry-run places the client preflight"; }
chk "$(yn "$([ "$rc" = 0 ] && [ "$rp_b" = 0 ]; echo $?)")" \
    "RP-2" "--role server over the real filemap places p5-server-preflight and NEITHER client validator (rc=$rc)"

# RP-3: the whole round trip, because "placed" is only half of G6. A real
# install must put the files on disk, RECORD them in installed.files, and
# `--remove` must take them away and leave the P5 half CLEAN. A file placed but
# unrecorded survives a removal and is exactly the leftover the clean predicate
# exists to find.
RPR=$TMPBASE/rp-real
inst "$RPR" "$RPP" client; rc=$?
rp_c=0
[ "$rc" = 0 ] || { rp_c=1; echo "  the real install refused (rc=$rc):"; sed 's/^/    /' "$TMPBASE/err"; }
for f in /usr/sbin/p5-accept /usr/sbin/p5-client-preflight; do
    [ -f "$RPR$f" ] || { rp_c=1; echo "  $f was not placed"; }
    grep -q "$f\$" "$RPR/usr/lib/p5/installed.files" 2>/dev/null \
        || { rp_c=1; echo "  $f is not in installed.files -- removal would leave it behind"; }
done
[ -e "$RPR/usr/sbin/p5-server-preflight" ] && { rp_c=1; echo "  the server preflight landed on a CLIENT install"; }
unin "$RPR" --remove --role client; rrc=$?
for f in /usr/sbin/p5-accept /usr/sbin/p5-client-preflight; do
    [ -e "$RPR$f" ] && { rp_c=1; echo "  $f survived --remove"; }
done
unin "$RPR" --check --scope p5 --role client; crc=$?
grep -q 'P5 half: CLEAN' "$TMPBASE/uout" || { rp_c=1; echo "  --check does not report the P5 half CLEAN after --remove"; }
chk "$(yn "$([ "$rp_c" = 0 ] && [ "$rrc" = 0 ] && [ "$crc" = 0 ]; echo $?)")" \
    "RP-3" "the three validators install by role, are RECORDED in installed.files, and --remove takes them away leaving a CLEAN P5 half (install=$rc remove=$rrc check=$crc)"

# RP-4: THE SECOND INVOCATION OF THE SERVER PREFLIGHT -- out of the UNPACKED
# PACKAGE, before anything is installed. docs/deploy-p5-server.md's gate C1 is
# `sh $PKG/payload/deploy/server/p5-server-preflight.sh`, which resolves only
# because the payload carries every file at its REPO path; a filemap row proves
# the installed copy and says nothing about that one. This bar asserts the
# package path exists, parses under `sh -n`, and is the same bytes as the repo
# file -- so a builder that flattened payload/ or a row whose src drifted from
# the documented path reddens here rather than at gate C1 on the server.
rp_pf=payload/deploy/server/p5-server-preflight.sh
rp_d=0
[ -f "$RPP/$rp_pf" ] || { rp_d=1; echo "  the package does not carry $rp_pf -- gate C1's pre-install invocation cannot resolve"; }
if [ -f "$RPP/$rp_pf" ]; then
    sh -n "$RPP/$rp_pf" 2>/dev/null || { rp_d=1; echo "  $rp_pf does not parse under sh -n"; }
    rp_h1=$(sha256sum < "$RPP/$rp_pf" | cut -d" " -f1)
    rp_h2=$(sha256sum < "$_pk_repo/deploy/server/p5-server-preflight.sh" | cut -d" " -f1)
    [ "$rp_h1" = "$rp_h2" ] || { rp_d=1; echo "  the packaged copy is not the repo file byte for byte"; }
fi
chk "$(yn "$([ "$rp_d" = 0 ]; echo $?)")" \
    "RP-4" "the package carries the server preflight at $rp_pf, byte-identical and sh-parseable, so gate C1 can run it BEFORE the install -- the second of its two documented invocations"

# ===========================================================================
# RP-5 / MU-RP5 -- THE INSTALLED VALIDATORS EXECUTE FROM /usr/sbin, FOREIGN cwd
# ===========================================================================
# THE CATCH NO BAR ABOVE PERFORMS. RP-1..RP-3 ask where the installer PUTS the
# three validators and whether --remove takes them back; RP-4 asks whether the
# packaged server preflight PARSES (`sh -n`). None of them RUNS an installed
# copy. The brief's failures bullet for this unit names precisely that gap --
# "a script that assumed it ran from deploy/ (relative sourcing) -> caught by
# running each from /usr/sbin under the E0 root" -- and a relative `.` line is
# invisible to all four: `sh -n` parses `. ./lib.sh` happily, the file is
# present at its destination, and installed.files records it. The defect only
# appears when the interpreter tries to RESOLVE the relative path, which needs
# an execution with a cwd that is not the source directory.
#
# TWO cwds, not one. `/` is the cwd an init script or a `ssh box p5-accept`
# hands the process. `$ROOT/tmp` is the second, because a relative path can
# ACCIDENTALLY resolve: `. ./lib.sh` from `/` looks for `/lib.sh`, and a box
# that happened to have one would read as green. Two unrelated cwds means the
# accident has to happen twice.
#
# WHAT IS ASSERTED IS THE OFFENDING LINE, NOT THE EXIT CODE. All three refuse
# on a machine that is not a box -- no transport secret, no P5 install -- so
# they exit non-zero HERE by design and an exit-code bar would have to be
# waived into uselessness. `not found|No such file|syntax error` is the
# signature of an unresolved source or an unparsed line under both interpreters
# this tree can meet: dash says "cannot open ./lib.sh: No such file", busybox
# ash says "can't open './lib.sh': No such file or directory". The rc of every
# run is still PRINTED, so a reader sees it without the bar depending on it.
rp5_scan() {            # rp5_scan ROOT NAME... -- run each installed validator
                        # from two foreign cwds. Prints one RC line per run and
                        # one OFFENDING line per hit; no OFFENDING line is green.
    _r5r=$1; shift
    mkdir -p "$_r5r/tmp"
    for _r5n in "$@"; do
        if [ ! -f "$_r5r/usr/sbin/$_r5n" ]; then
            echo "OFFENDING $_r5n -- $_r5r/usr/sbin/$_r5n was never installed"
            continue
        fi
        for _r5c in / "$_r5r/tmp"; do
            ( cd "$_r5c" && BOND_ACCEPT_MODE=sandbox sh "$_r5r/usr/sbin/$_r5n" ) \
                >"$TMPBASE/rp5.out" 2>&1
            _r5rc=$?
            echo "RC $_r5n cwd=$_r5c rc=$_r5rc"
            grep -nE 'not found|No such file|syntax error' "$TMPBASE/rp5.out" \
                | sed "s|^|OFFENDING $_r5n cwd=$_r5c |"
        done
    done
}

# Fresh roots: RP-3 ran --remove over $RPR, so its /usr/sbin is empty by the
# time this line is reached. Two roots because no single role carries all three
# validators -- that is RP-1/RP-2's whole point.
RPX=$TMPBASE/rp-exec-c;  inst "$RPX"  "$RPP" client; rp5_ic=$?
RPXS=$TMPBASE/rp-exec-s; inst "$RPXS" "$RPP" server; rp5_is=$?
rp5_out=$( rp5_scan "$RPX" p5-accept p5-client-preflight
           rp5_scan "$RPXS" p5-server-preflight )
rp5_rcs=$(echo "$rp5_out" | grep '^RC ' | sed 's/^RC //' | tr '\n' ';')
rp5_e=0
[ "$rp5_ic" = 0 ] || { rp5_e=1; echo "  the client install for this bar refused (rc=$rp5_ic)"; }
[ "$rp5_is" = 0 ] || { rp5_e=1; echo "  the server install for this bar refused (rc=$rp5_is)"; }
if echo "$rp5_out" | grep -q '^OFFENDING'; then
    rp5_e=1
    echo "$rp5_out" | grep '^OFFENDING' | sed 's/^/  /'
fi
chk "$(yn "$([ "$rp5_e" = 0 ]; echo $?)")" \
    "RP-5" "the three INSTALLED copies each execute from \$ROOT/usr/sbin with a foreign cwd (/ and \$ROOT/tmp) and emit no 'not found', 'No such file' or 'syntax error' line -- nothing in them assumes it was started from deploy/. Exit codes (refusals off a box are expected and not asserted): $rp5_rcs"

# MU-RP5: the seeded A/B, in the harness rather than in a commit message. A
# relative `. ./lib.sh` is inserted into a COPY of the installed client
# preflight and the same scan is re-run. Two directions, because a scanner that
# reported every validator would also "catch" this one: the mutated name must be
# named, and the untouched p5-accept beside it must stay silent.
RPXM=$TMPBASE/rp-exec-mut
rm -rf "$RPXM"; cp -a "$RPX" "$RPXM"
rp5_mf=$RPXM/usr/sbin/p5-client-preflight
{ echo '#!/bin/sh'; echo '. ./lib.sh'; sed '1d' "$rp5_mf"; } > "$rp5_mf.seed" \
    && mv "$rp5_mf.seed" "$rp5_mf" && chmod 755 "$rp5_mf"
rp5_seeded=$(grep -c '^\. \./lib\.sh$' "$rp5_mf" 2>/dev/null || echo 0)
rp5_mout=$(rp5_scan "$RPXM" p5-accept p5-client-preflight)
rp5_m=0
echo "$rp5_mout" | grep -q '^OFFENDING p5-client-preflight' \
    || { rp5_m=1; echo "  the seeded relative source in p5-client-preflight did NOT red the scan"; }
echo "$rp5_mout" | grep -q '^OFFENDING p5-accept' \
    && { rp5_m=1; echo "  the scan also names p5-accept, which was not touched -- it does not localise"; }
chk "$(yn "$([ "$rp5_m" = 0 ] && [ "$rp5_seeded" = 1 ]; echo $?)")" \
    "MU-RP5" "MUTATION: a relative '. ./lib.sh' inserted into a COPY of the installed p5-client-preflight (lines seeded: $rp5_seeded) -> RP-5's scan names p5-client-preflight and ONLY it. RP-5 is able to fail, and it fails at the right file"

# ===========================================================================
# PO-1..PO-6 / MU-PO -- THE PORTAL SHIPS (F17, U217)
# ===========================================================================
# WHAT WAS TRUE UNTIL THIS BLOCK EXISTED, measured by scripts/feature-status.py:
# F17 read COVERED-NOT-SHIPPED with "Ship anchors 0/8". The portal was built and
# had 103 bars of its own in orchestration/ecosim/p5/portal/run.sh, and not one
# byte of it could reach a box: no row in p5/contract/paths declared a
# destination for any of the eight files, so p5/payload/filemap could not carry
# them (p5_check_dest refuses an undeclared dest and takes the WHOLE install
# down with exit 4), and the filemap header excluded the whole subtree with the
# reason "a second uhttpd listener on a router with no console is a decision
# nobody has made". Mo made it on 2026-09-05: the portal is built before
# deployment. These bars are the mechanical half of that decision.
#
# THE FIXTURE IS THE REAL REPO FILEMAP, $RPP from RP-1 above -- not mkpkg's
# synthetic three-row package. That is the property these bars exist for: a row
# deleted from the shipped filemap, or a dest whose contract row is missing,
# reddens here. MU-PO seeds exactly that.
#
# WHY DISABLED IS ITS OWN BAR. p5-install enables nothing anywhere, and the
# portal is the first thing P5 ships that would LISTEN if it were enabled. Two
# independent things keep an un-configured box quiet -- no /etc/rc.d/S??p5-portal
# flag, and the init script's own refusal to start with no /etc/p5/portal/port
# (deploy/p5/portal/init.d/p5-portal:57-59) -- and PO-3 pins the first, which is
# the one an installer could get wrong.
#
# U228 ADDED THREE DESTS AND ONE DIRECTORY: the on-box test runner. The lists
# below are what PO-1..PO-6 iterate, so a runner file that reached deploy/ with
# no filemap row, or with a dest no contract row declares, reddens the same six
# bars the eight original files do -- there is no second list to keep in step.
# The artifact store /usr/lib/p5/portal/results is deliberately NOT here: it is
# created ON THE BOX at run time (contract state=runtime) and a filemap row that
# tried to ship into it is refused exit 4, which is IN-16's own bar.
PO_DESTS="/usr/lib/p5/portal/www/cgi-bin/p5-portal
/etc/init.d/p5-portal
/usr/lib/p5/portal/lib/portal-lib.sh
/usr/lib/p5/portal/catalogue/fields
/usr/lib/p5/portal/catalogue/modes
/usr/lib/p5/portal/catalogue/probes
/usr/lib/p5/portal/catalogue/tests
/usr/lib/p5/portal/bin/p5-portal-run
/usr/lib/p5/portal/bin/p5-portal-restore
/usr/lib/p5/portal/www/index.html
/usr/lib/p5/portal/www/portal.js"
PO_DIRS="/usr/lib/p5/portal
/usr/lib/p5/portal/lib
/usr/lib/p5/portal/catalogue
/usr/lib/p5/portal/bin
/usr/lib/p5/portal/www
/usr/lib/p5/portal/www/cgi-bin"
po_n=$(printf '%s\n' "$PO_DESTS" | grep -c .)
po_dn=$(printf '%s\n' "$PO_DIRS" | grep -c .)

# PO-1: --role client's dry run names all eight destinations, and --role server
# names none of them. The negative half is the half that matters: the portal is
# CLIENT-only, and a role filter that ignored the role column would put a
# listener on the server -- the box with no physical access.
inst "$TMPBASE/po-dc" "$RPP" client --dry-run; rc=$?
po_a=0
while read -r d; do
    [ -n "$d" ] || continue
    grep -qF "$d" "$TMPBASE/out" || { po_a=1; echo "  the client dry-run does not place $d"; }
done <<PO1EOF
$PO_DESTS
PO1EOF
inst "$TMPBASE/po-ds" "$RPP" server --dry-run; src=$?
po_srv=$(grep -c 'portal' "$TMPBASE/out")
[ "$po_srv" = 0 ] || { po_a=1; echo "  the server dry-run names the portal $po_srv time(s):"; grep 'portal' "$TMPBASE/out" | sed 's/^/    /'; }
chk "$(yn "$([ "$rc" = 0 ] && [ "$src" = 0 ] && [ "$po_a" = 0 ]; echo $?)")" \
    "PO-1" "--role client over the real filemap places all $po_n portal destinations and --role server places NONE of them ($po_srv portal mentions in the server plan; client rc=$rc server rc=$src)"

# PO-2: a REAL install puts all eight on disk at the modes the filemap declares
# -- 0755 for the two things that execute (the CGI uhttpd forks, the init script
# procd runs), 0644 for the six that are read. A CGI installed 0644 is a portal
# that answers 500 forever, and nothing above this line would see it.
POR=$TMPBASE/po-real
inst "$POR" "$RPP" client; rc=$?
po_b=0
[ "$rc" = 0 ] || { po_b=1; echo "  the real install refused (rc=$rc):"; sed 's/^/    /' "$TMPBASE/err"; }
po_mode_of() { ls -l "$1" 2>/dev/null | head -1 | cut -c1-10; }
while IFS='|' read -r want d; do
    [ -n "$d" ] || continue
    [ -f "$POR$d" ] || { po_b=1; echo "  $d was not placed"; continue; }
    got=$(po_mode_of "$POR$d")
    [ "$got" = "$want" ] || { po_b=1; echo "  $d is mode '$got', the filemap declares $want"; }
done <<PO2EOF
-rwxr-xr-x|/usr/lib/p5/portal/www/cgi-bin/p5-portal
-rwxr-xr-x|/etc/init.d/p5-portal
-rw-r--r--|/usr/lib/p5/portal/lib/portal-lib.sh
-rw-r--r--|/usr/lib/p5/portal/catalogue/fields
-rw-r--r--|/usr/lib/p5/portal/catalogue/modes
-rw-r--r--|/usr/lib/p5/portal/catalogue/probes
-rw-r--r--|/usr/lib/p5/portal/catalogue/tests
-rwxr-xr-x|/usr/lib/p5/portal/bin/p5-portal-run
-rwxr-xr-x|/usr/lib/p5/portal/bin/p5-portal-restore
-rw-r--r--|/usr/lib/p5/portal/www/index.html
-rw-r--r--|/usr/lib/p5/portal/www/portal.js
PO2EOF
chk "$(yn "$([ "$po_b" = 0 ]; echo $?)")" \
    "PO-2" "a --role client install places all $po_n portal files at the modes the filemap declares: 0755 for the CGI, the init script and the two runner executables (uhttpd execs one, the CGI execs the runner, p5-deadman execs the restore script), 0644 for the library, the four catalogues and the two page files (rc=$rc)"

# PO-3: PLACED DISABLED. `/etc/init.d/<svc> enable` is what writes
# /etc/rc.d/S??p5-portal, and p5-install never calls it. So a fresh install of a
# box that has declared no port has a portal on disk and nothing listening.
po_c=0
po_flags=$(ls "$POR/etc/rc.d/" 2>/dev/null | grep -c 'p5-portal')
[ "$po_flags" = 0 ] || { po_c=1; echo "  the install wrote $po_flags rc.d flag(s) for p5-portal:"; ls "$POR/etc/rc.d/" 2>/dev/null | grep 'p5-portal' | sed 's/^/    /'; }
[ -f "$POR/etc/init.d/p5-portal" ] || { po_c=1; echo "  the init script is not there at all, so 'disabled' says nothing"; }
[ -e "$POR/etc/p5/portal/port" ] && { po_c=1; echo "  the installer wrote /etc/p5/portal/port -- the listen port is an OPERATOR declaration, never a shipped constant"; }
chk "$(yn "$([ "$po_c" = 0 ]; echo $?)")" \
    "PO-3" "the portal is placed DISABLED: the init script exists and NO /etc/rc.d/[SK]??p5-portal flag was written ($po_flags found), and the installer wrote no /etc/p5/portal/port -- an installed box listens on nothing until an operator declares a port and enables the service"

# PO-4: RECORDED. A file placed but not in installed.files survives --remove and
# is exactly the leftover the clean predicate exists to find; a directory
# created as a `mkdir -p` parent rather than from a `dir` row is never in
# installed.dirs and is never rmdir-ed, which leaves the tree standing empty
# after a removal and wedges the box against its own reinstall.
po_d=0
while read -r d; do
    [ -n "$d" ] || continue
    awk '{ if (NF >= 2) print $2 }' "$POR/usr/lib/p5/installed.files" 2>/dev/null | grep -qxF "$d" \
        || { po_d=1; echo "  $d is not in installed.files -- removal would leave it behind"; }
done <<PO4EOF
$PO_DESTS
PO4EOF
while read -r d; do
    [ -n "$d" ] || continue
    grep -qxF "$d" "$POR/usr/lib/p5/installed.dirs" 2>/dev/null \
        || { po_d=1; echo "  $d is not in installed.dirs -- removal would leave the directory standing"; }
done <<PO4DEOF
$PO_DIRS
PO4DEOF
chk "$(yn "$([ "$po_d" = 0 ]; echo $?)")" \
    "PO-4" "all $po_n portal files are recorded in installed.files and all $po_dn portal directories in installed.dirs, so --remove has a record to work from"

# PO-5: THE BYTES SERVED ARE THE BYTES IN THE REPO. uhttpd serves the docroot
# straight off disk and execs the CGI, so an install that transformed a file --
# a line-ending rewrite, a truncation, a mode-only copy of the wrong source --
# ships a portal that is not the one 103 ecosim bars measured. cmp, not a hash
# of a hash: the comparison is against the repo file the filemap's src column
# names, which is the only thing those bars ever ran.
po_e=0
while IFS='|' read -r s d; do
    [ -n "$d" ] || continue
    cmp -s "$_pk_repo/$s" "$POR$d" \
        || { po_e=1; echo "  $d differs from its repo source $s"; }
done <<PO5EOF
deploy/p5/portal/cgi/p5-portal|/usr/lib/p5/portal/www/cgi-bin/p5-portal
deploy/p5/portal/init.d/p5-portal|/etc/init.d/p5-portal
deploy/p5/portal/lib/portal-lib.sh|/usr/lib/p5/portal/lib/portal-lib.sh
deploy/p5/portal/catalogue/fields|/usr/lib/p5/portal/catalogue/fields
deploy/p5/portal/catalogue/modes|/usr/lib/p5/portal/catalogue/modes
deploy/p5/portal/catalogue/probes|/usr/lib/p5/portal/catalogue/probes
deploy/p5/portal/catalogue/tests|/usr/lib/p5/portal/catalogue/tests
deploy/p5/portal/bin/p5-portal-run|/usr/lib/p5/portal/bin/p5-portal-run
deploy/p5/portal/bin/p5-portal-restore|/usr/lib/p5/portal/bin/p5-portal-restore
deploy/p5/portal/www/index.html|/usr/lib/p5/portal/www/index.html
deploy/p5/portal/www/portal.js|/usr/lib/p5/portal/www/portal.js
PO5EOF
chk "$(yn "$([ "$po_e" = 0 ]; echo $?)")" \
    "PO-5" "every placed portal file is byte-identical (cmp) to the repo file the filemap's src column names -- the page and the CGI on the box are the ones orchestration/ecosim/p5/portal/run.sh measures"

# PO-6: --remove takes all of it and leaves the P5 half CLEAN. The directory
# half is the part that is easy to get wrong and invisible without this bar: an
# empty /usr/lib/p5/portal left behind is a path the clean predicate declares
# NOT CLEAN, and a box that is not clean cannot be reinstalled.
#
# IT COUNTS WHAT IT IS ABOUT TO REMOVE FIRST, and that is not bookkeeping. The
# seeded A/B for this unit produced exactly the failure this guards: with a
# filemap row dropped or a dest outside the namespace, the install above
# REFUSES, nothing is placed, and "none of the eight survived --remove" is then
# true of a root that never had them -- PO-6 printed PASS through both seeds
# while every bar around it went red. So the pre-state is asserted: eight files
# present before the removal, or this bar is measuring nothing and says so.
po_before=0
while read -r d; do
    [ -n "$d" ] || continue
    [ -e "$POR$d" ] && po_before=$((po_before + 1))
done <<PO6PREEOF
$PO_DESTS
PO6PREEOF
unin "$POR" --remove --role client; rrc=$?
po_f=0
[ "$po_before" = "$po_n" ] || { po_f=1; echo "  only $po_before of $po_n portal files were on disk BEFORE --remove: this bar has no subject, and its 'nothing survived' would be vacuous"; }
while read -r d; do
    [ -n "$d" ] || continue
    [ -e "$POR$d" ] && { po_f=1; echo "  $d survived --remove"; }
done <<PO6EOF
$PO_DESTS
PO6EOF
[ -d "$POR/usr/lib/p5/portal" ] && { po_f=1; echo "  /usr/lib/p5/portal survived --remove as an empty tree"; }
unin "$POR" --check --scope p5 --role client; crc=$?
grep -q 'P5 half: CLEAN' "$TMPBASE/uout" || { po_f=1; echo "  --check does not report the P5 half CLEAN after --remove:"; sed 's/^/    /' "$TMPBASE/uout"; }
chk "$(yn "$([ "$po_f" = 0 ] && [ "$rrc" = 0 ] && [ "$crc" = 0 ]; echo $?)")" \
    "PO-6" "all $po_n portal files were on disk, --remove takes them AND the $po_dn directories, and --check reports the P5 half CLEAN afterwards (present before=$po_before remove=$rrc check=$crc)"

# MU-PO: THE SEED, both halves of the account. Drop ONE portal row -- the init
# script -- from a COPY of the filemap and nothing else changes. Two independent
# things must go red, and they are the two this unit added:
#   (a) PK-4's finder must name deploy/p5/portal/init.d/p5-portal UNACCOUNTED.
#       That is the completeness half: the file is under deploy/, it is no
#       longer a filemap src, the builder does not copy it, and no EXCLUDE glob
#       covers it any more (the subtree glob left in the same commit that
#       shipped these rows -- which is exactly the state PK-4's "exactly one"
#       rule exists to catch going the other way).
#   (b) PO-1's own finder, re-run against a package built from the mutant, must
#       stop seeing /etc/init.d/p5-portal in the plan. That is the placement
#       half: a bar that only asked PK-4 would pass a filemap whose rows the
#       installer refuses.
# The mutant is a COPY. The shipped filemap is never edited, so this bar is safe
# to run in a shared tree and cannot leave a seeded row behind.
po_mut="$TMPBASE/filemap.mu-po"
po_row='755|client|deploy/p5/portal/init.d/p5-portal|/etc/init.d/p5-portal'
grep -vxF "$po_row" "$P5DIR/payload/filemap" > "$po_mut"
po_applied=$(( $(grep -c . "$P5DIR/payload/filemap") - $(grep -c . "$po_mut") ))
po_mua=$(pk4_audit "$po_mut")
po_g=0
echo "$po_mua" | grep -q 'UNACCOUNTED deploy/p5/portal/init.d/p5-portal' \
    || { po_g=1; echo "  PK-4's finder does NOT name the dropped portal row:"; echo "$po_mua" | sed 's/^/    /'; }
echo "$po_mua" | grep -q 'deploy/p5/portal/cgi/p5-portal' \
    && { po_g=1; echo "  the finder also names the CGI, which was not touched -- it does not localise"; }
POM=$TMPBASE/po-pkg-mut
rm -rf "$POM"; cp -a "$RPP" "$POM"
cp "$po_mut" "$POM/payload/filemap"
( cd "$POM" && find payload -type f | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256 )
inst "$TMPBASE/po-dm" "$POM" client --dry-run; mrc=$?
grep -qF '/etc/init.d/p5-portal' "$TMPBASE/out" \
    && { po_g=1; echo "  the mutant plan still places /etc/init.d/p5-portal -- PO-1's finder cannot fail"; }
grep -qF '/usr/lib/p5/portal/www/cgi-bin/p5-portal' "$TMPBASE/out" \
    || { po_g=1; echo "  the mutant plan lost the CGI too, so the mutation is not localised to one row"; }
chk "$(yn "$([ "$po_g" = 0 ] && [ "$po_applied" = 1 ] && [ "$mrc" = 0 ]; echo $?)")" \
    "MU-PO" "MUTATION: the init.d/p5-portal row removed from a COPY of the filemap (rows removed: $po_applied) -> PK-4's finder names deploy/p5/portal/init.d/p5-portal UNACCOUNTED and ONLY it, and a package built from the mutant no longer places /etc/init.d/p5-portal while the other seven rows still do (mutant dry-run rc=$mrc). PO-1 and PK-4 are both able to fail, at the right file"

# U153 raised this 161 -> 173 -> 175. Seven bars in the build round
# (EXS-1..EXS-6 and MU-EXS) for the executed file's own symlink; five in fix
# round 1 for the two pieces of that code the first seven could not fail on:
# EXS-7 and MU-EXS-S9 (S9, a non-regular file at a declared executed name -- the
# P5 HALF of it only) and EXS-8, EXS-9, MU-EXS-OLD (the old half's two EXECUTOR
# gates, which the old half's PLANNER refusal reaches first and so hides); and
# two in fix round 2, EXS-10 and MU-EXS-S9-OLD, for the OLD half's S9 block,
# which fix round 1 MUTATED but never had a fixture for -- seeding
# p5/lib/p5-common.sh:844 alone left the whole battery green.
# U188 raised it 175 -> 181: SIX bars, and none of them replaces another --
# RM-12 (a stranger and a fifo survive an old-half `dir` row and are named),
# RM-13 (neither walk descends a symlink; its target survives on both halves),
# RM-14 (the same verb finishes once they are cleared, so RM-12/RM-13's red is
# the contents and not a removal that stopped working), RMRF-0 (zero recursive
# removals in the four removal-path files, no exclusion list), NR-2 (the argv
# ledger of the shimmed runs) and MU-RMRF (RMRF-0 reddens on the restored
# `rm -rf`). RM-9 was rewritten in place, so it is not part of the rise.
# The fix round raised it 181 -> 183: RM-15 (a `dir` row that is a SYMLINK is
# REPORTED and never walked, so no member of the target enters the plan) and
# RM-16 (the member gate's foreign-origin line is held by a contract mutant,
# where no file fixture on this box can fire it). MU-RMRF grew two more mutants
# and a prose negative control inside the same bar, so it is not part of the
# rise either.
# U210 added three (PK-2, PK-3, MK-1) and raised this 175 -> 176, not 177, and
# the missing one is deliberate headroom for the OTHER MODE. THE COUNT IS NOT
# MODE-INDEPENDENT: a SKIP does not count toward pass+fail, and which bars skip
# depends on whether P5_PKG names a real package. MEASURED, and both numbers are
# written down because the pair is the point:
#   this tree, synthetic  180 passed 0 failed, 177 bars before this one, 1 SKIP
#   this tree, real       180 passed 0 failed, 177 bars before this one, 1 SKIP
#   this unit's tree BEFORE it merged dev, real: 178 passed, 176 bars, 3 SKIPs
#     (IN-7, HP-4, MU-HP4) -- which FAILED a floor of 177 while synthetic passed
#     it, and at the old 175 that same real mode was already below the floor
#     (176 - 3 = 173) before this unit touched anything. FL-1 had only ever been
#     read in synthetic mode.
# So 176 is the lowest number measured on any mode of this battery, and it is a
# RISE from 175. Raise it when bars are added; never lower it to go green --
# lowering it is the move this bar exists to make visible.
# MERGE 2026-09-05 (U188 + U210 on dev): U188's rise to 183 and U210's three bars
# land together. Synthetic mode MEASURED on the merged tree (6681e1e) by the e0
# gate: "185 bars ran before this one", 188 passed 0 failed. The floor is ONE
# below that synthetic count, carrying U210's measurement that real mode reads
# one bar fewer before FL-1 -- real mode was NOT re-measured after this merge.
#
# U211 raised it 175 -> 181 in the build round (PK-4, MU-PK4, RP-1..RP-4) and
# 181 -> 183 in the fix round: RP-5 and MU-RP5, the from-/usr/sbin execution
# bar and its mutation. All eight run above this line.
# MERGE 2026-09-05 (U211 onto dev 69f0b29 = U188 + U210): U211's eight bars (PK-4,
# MU-PK4, RP-1..RP-5, MU-RP5) land on the 184 floor. MEASURED on the merged
# branch (9b8ae9e) by the e0 gate: "193 bars ran before this one". The floor is
# ONE below that synthetic count (real mode reads one bar fewer -- U210's
# measurement, not re-measured here).
# U208 raised this 175 -> 184: nine bars for the pre-switch quiescence gate
# (QG-E1..E7, QG-10, QS-LIT), the E0 half of a gate whose other two halves are
# in bond_model.py and the ecosim harness. Its fix round added QG-E8 (a wg that
# is usable and still does not answer -- the fail-open QG-E6 could not see,
# because `command -v` finds that tool), 184 -> 185.
# MERGE 2026-09-05 (U208 onto dev d32f980 = U188 + U210 + U211): U208's E0 bars
# (QG-E1..E8, QG-10, QS-LIT) land on the 192 floor. MEASURED on the merge by the
# e0 gate: "203 bars ran before this one", 206 passed 0 failed, Layer-2 617/0.
# The floor is ONE below that synthetic count (real mode reads one bar fewer --
# U210's measurement, not re-measured here).
# U217 raised it 202 -> 209: SEVEN bars for the portal's placement (PO-1..PO-6
# and MU-PO), all of them above this line. MEASURED on this branch by the e0
# gate arm of `bash scripts/ci-wsl.sh e0 portal shellcheck`, synthetic mode:
# "210 bars ran before this one", 211 passed 0 failed, 0 skipped. The floor is
# ONE below that synthetic count, carrying U210's measurement that real mode
# reads one bar fewer before FL-1 -- real mode was NOT re-measured here, and the
# whole point of the -1 is that FL-1 had only ever been read in synthetic mode
# until U210 found the two modes disagree. Raise it when bars are added; never
# lower it to go green.
# MERGE 2026-09-05: dev had moved 202 -> 213 (U209 and later units, 214 synthetic
# bars before FL-1 measured on dev 2b56d08); U217's seven come on top: 214 + 7 =
# 221 synthetic, floor 220. MEASURED on the merged tree by the e0 gate (the merge
# commit's gate log names the FL-1 line).
# U213 raises this 220 -> 246 IN A FULL CHECKOUT ONLY, and the pair of numbers is
# the point. Twenty-six bars for the CLIENT RUNBOOK land above: RB-1..RB-10 and
# MU-RB1..MU-RB6 are U173's, taken as text (that branch is superseded, not
# merged); RB-11..RB-15 and MU-RB7..MU-RB11 are U213's, for the properties the
# G2 ladder has and prose cannot hold -- box labels, rung order, no recursive
# removal written down, the prerequisite merges resolved against this repo, and
# every verb resolved against the parser that would receive it.
# MERGE 2026-09-05 (U213 onto dev fa2f818 = ... U217): the branch measured 240
# synthetic on the 213 base; dev has since moved 213 -> 220 (U217's seven portal
# bars), so the merged full-checkout count is 221 + 26 = 247 synthetic, floor
# 246. MEASURED on the merged tree by the e0 gate, synthetic mode -- the FL-1
# line names the count.
# ON THE PUBLISHED MIRROR ALL TWENTY-SIX SKIP -- docs/deploy-p5-runbook.md is not
# published (sync-public-ci.sh ALLOW-lists docs/deploy-p5-server.md and no other
# docs/ file) -- so the mirror's count is unchanged at 221 and its floor stays
# 220, dev's number. Two numbers with the reason, not one number lowered until
# it fits. A skip is not a pass, and FL-1 only ever ratchets up.
if [ "${RB_PRESENT:-0}" = 1 ]; then P5T_FLOOR=246; else P5T_FLOOR=220; fi
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

# WHICH PACKAGE THIS RUN MEASURED, and every bar it could not run. The two
# modes do not have the same bar count, so a bare number cannot be compared
# between them: the mode, the package's own commit stamp and the skip list are
# part of the verdict rather than something a reader must reconstruct from the
# log. A skipped bar is NOT a passed bar and is not counted as one.
echo
if [ "$PKG_MODE" = real ]; then
    echo "p5-skeleton: the package bars ran against the BUILT package $P5_PKG"
    echo "p5-skeleton: that package stamps $(grep '^P5_GIT_COMMIT=' "$P5_PKG/PROVENANCE" | head -1) $(grep '^P5_GIT_DIRTY=' "$P5_PKG/PROVENANCE" | head -1)"
else
    echo "p5-skeleton: the package bars ran against mkpkg's SYNTHETIC fixture (P5_PKG unset or empty -- the two are the same statement here)"
fi
if [ "$skips" = 0 ]; then
    echo "p5-skeleton: 0 bars skipped"
else
    echo "p5-skeleton: $skips bar(s) SKIPPED -- not counted as passes, each with its reason:"
    cat "$TMPBASE/skipped"
fi

p5t_report "p5-skeleton" "$P5T_LEDGER" "$pass" "$fail"
exit $?
