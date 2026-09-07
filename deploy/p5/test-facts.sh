#!/bin/sh
# deploy/p5/test-facts.sh -- U133. THE MECHANICAL COMPLETENESS BAR for the fact
# ledger deploy/p5/facts.
#
# WHY THIS IS A SCRIPT AND NOT A REVIEW CHECKLIST: the U133 ROADMAP row named
# five facts and cited them as bond-xctl:386-387/573/577/850/1026. U124 split
# bond-xctl into bin + lib/xctl-*.sh; the file is 232 lines now and EVERY one of
# those cites points past its end. A hand-written list of facts passes forever
# while the tree moves underneath it. This one greps.
#
# USAGE   sh deploy/p5/test-facts.sh [TREE_ROOT]
#         TREE_ROOT defaults to the repo this script lives in. Pass a COPY of
#         the tree to A/B a seeded defect without touching the shared worktree.
#
# EXIT    0 = every bar green.  1 = any bar red, or a floor unmet.
#
# ABSENCE IS ITS OWN RED. A broken selector returns nothing, and "nothing found"
# reads exactly like "nothing wrong". So the reference and row FLOORS are
# asserted BEFORE any per-fact verdict, and the waiver COUNTS are asserted for
# equality, not for "<=": a waiver set that silently grows is the failure mode.
# shellcheck disable=SC2086
# SWEEP_DIRS is used UNQUOTED on purpose at every grep below: it is a LIST of
# two directory arguments, and quoting it would hand grep one argument named
# "deploy orchestration/ecosim/p5", which matches nothing -- a sweep that finds
# zero references and a checker that then calls the tree clean. The floor bar
# FD-2 exists because that is the failure mode; the directive states the reason
# rather than leaving the next reader to re-derive it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="${1:-$(cd "$HERE/../.." && pwd)}"
LEDGER="$ROOT/deploy/p5/facts"
CATALOGUE="$ROOT/deploy/p5/portal/catalogue/fields"
PORTAL="$ROOT/deploy/p5/portal"

# The two trees a P5 fact can be named in: the shipped artifacts, and the
# Layer-2 harness that drives them. A new fact READ in either must land in the
# ledger, which is what makes seed (a) red.
SWEEP_DIRS="deploy orchestration/ecosim/p5"

# Floors, all MEASURED on this tree at build time, never guessed.
ROWS_MIN=20          # rows in the ledger; 20 facts/subtrees found by the sweep
REFS_MIN=160         # $BOND_DIR|/etc/p5|/etc/bond references; measured 191
WAIVERS_EXPECT=7     # rows with writer=NONE: wg-logical metered spotty_dup agg_w exclude cap tx_backoff_us
                     # 5 -> 7 (U253+U252, 2026-09-06): `cap` and `tx_backoff_us` carry numbers
                     # only the hardware probe can produce -- cap.go ships no default for its
                     # five keys on purpose, and pull.go's S7 register says a backoff constant
                     # would be an invented number. The plumbing ships; the values are E1's.
                     # 6 -> 5 (U214, 2026-09-05): wg_if became writer=OPERATOR. The deploy
                     # ladder makes the operator its writer at S2 (`wg show interfaces`), so
                     # it is a declared operator fact, not an escalation waiver. A DERIVED
                     # writer is still wanted and is still unbuilt -- the row says so.
ROOT_MISMATCH_EXPECT=1   # /etc/bond references inside deploy/p5/portal (U51a NS-5 waiver).
                         # RATCHETED 4 -> 2 by U220 (the two that were CODE: lib/portal-lib.sh's
                         # BOND_DIR default and the comment beside the mode PAIR) and 4 -> 3 by
                         # U227 (the catalogue `shape` label, which now says /etc/p5). MERGED
                         # 2026-09-05: 4 - 2 - 1 = 1 -- the catalogue/fields `exclude` comment is
                         # the last one. This number only ever goes DOWN.
BARS_MIN=12         # bars BEFORE FD-0, MEASURED on this tree: FD-1..FD-12

# The fact root spellings. `\$BOND_DIR`, `\$LIVE_BOND_DIR` (bond-accept), and the
# two LITERAL roots. The literal arm is load-bearing and not decoration: agg_env
# is referenced ONLY as /etc/p5/agg_env by the procd unit, so a checker that
# greps $BOND_DIR alone certifies a false clean.
SWEEP_RE='(\$\{?(LIVE_)?BOND_DIR\}?|/etc/p5|/etc/bond)/[A-Za-z0-9_][A-Za-z0-9_.-]*'

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $*"; }
no() { fail=$((fail + 1)); echo "FAIL $*"; }

# THE WORK DIR IS PRIVATE, AND ITS LOSS IS A RED. `$$/tmp` is not private: two
# runs of this checker under the same pid namespace (the CI arms run
# concurrently) can land on the same path, and one of them removes it on exit
# while the other is still reading. mktemp -d is the same call the caller
# orchestration/ecosim/p5/run.sh:32 makes, for the same reason, in a comment
# that says so.
#
# THAT ALONE IS NOT THE FIX. Even with a unique dir, every read below is a
# `grep`/`cut` on a file that answers EMPTY when it is gone, and an empty answer
# is what a clean tree also looks like: FD-3/FD-4/FD-5/FD-6 all printed PASS on
# ZERO input when the dir was removed mid-run. The floors FD-1/FD-2 do not
# protect them -- those read $ROWS/$REFS captured earlier, so they stay green.
# So every working file is checked at ITS OWN READ SITE by need(), which ABORTS
# the whole run rather than letting a bar score a verdict on nothing.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-facts.XXXXXX" 2>/dev/null) || TMP=""
# if/then, not `A && B || C` (U66/SC2015: C also runs when A is true).
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
    echo "FAIL FD-0 cannot create a private work dir under ${TMPDIR:-/tmp}"
    exit 1
fi
trap 'rm -rf "$TMP" 2>/dev/null' EXIT INT TERM

need() {   # need FILE BAR -- a working file that VANISHED is a RED, never a clean run
    [ -f "$1" ] && return 0
    no "$2 the working file ${1##*/} is GONE -- the private work dir was lost mid-run, so NOTHING below it was checked"
    echo "===== facts: $pass passed, $fail failed ====="
    exit 1
}

cd "$ROOT" || { echo "FAIL cannot enter tree root $ROOT"; exit 1; }

# ---------------------------------------------------------------- the sweep
# grep -o prints `path:line:MATCH`. The NAME is everything after the last `/`
# of the match; trailing prose punctuation (`shape_reflectors.`) is stripped
# HERE, and the rule is stated in the ledger header rather than hidden.
grep -rnoE "$SWEEP_RE" $SWEEP_DIRS 2>/dev/null \
  | awk -F: '{ n = $NF; sub(/^.*\//, "", n); sub(/[.-]+$/, "", n);
               if (n != "") print n "\t" $1 ":" $2 }' \
  | sort -u > "$TMP/refs"
REFS=$(grep -c . "$TMP/refs" 2>/dev/null); [ -n "$REFS" ] || REFS=0

# ---------------------------------------------------------------- the ledger
if [ ! -f "$LEDGER" ]; then
    no "FD-1 the ledger deploy/p5/facts is MISSING at $LEDGER"
    echo "===== facts: $pass passed, $fail failed ====="
    exit 1
fi
grep -v '^[[:space:]]*#' "$LEDGER" | grep . > "$TMP/rows" || true
ROWS=$(grep -c . "$TMP/rows" 2>/dev/null); [ -n "$ROWS" ] || ROWS=0
cut -d'|' -f1 "$TMP/rows" | sort -u > "$TMP/names"

# FD-1 / FD-2 -- the floors, FIRST. A truncated ledger or a broken selector must
# read as a failure, never as a clean run.
if [ "$ROWS" -ge "$ROWS_MIN" ]; then ok "FD-1 ledger rows $ROWS >= floor $ROWS_MIN"
else no "FD-1 ledger has $ROWS rows, floor $ROWS_MIN -- truncated or emptied"; fi
if [ "$REFS" -ge "$REFS_MIN" ]; then ok "FD-2 fact references swept $REFS >= floor $REFS_MIN"
else no "FD-2 the sweep found $REFS references, floor $REFS_MIN -- the SELECTOR is broken, not the tree"; fi

# ---------------------------------------------------------------- FD-3 UNDECLARED
bad=""
need "$TMP/refs" FD-3
need "$TMP/names" FD-3
cut -f1 "$TMP/refs" | sort -u > "$TMP/swept"
need "$TMP/swept" FD-3
# `while read < FILE`, never a pipe into the loop: a piped loop is a subshell in
# every POSIX shell here and $bad would be discarded -- the bar would then be
# green because its accumulator vanished, which is the worst possible red.
while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! grep -qx -- "$n" "$TMP/names"; then
        where=$(grep -m1 "^$n	" "$TMP/refs" | cut -f2)
        bad="$bad $n@$where"
    fi
done < "$TMP/swept"
if [ -z "$bad" ]; then ok "FD-3 every swept fact name has a ledger row (UNDECLARED: none)"
else no "FD-3 UNDECLARED -- referenced with no ledger row:$bad"; fi

# ---------------------------------------------------------------- FD-4 catalogue keys
# The portal writes through a dynamic key bounded by this catalogue, so those
# keys never appear in the sweep. `profile` exists in the ledger ONLY because of
# this arm.
cbad=""
if [ -f "$CATALOGUE" ]; then
    grep -v '^[[:space:]]*#' "$CATALOGUE" | grep . | cut -d'|' -f1 > "$TMP/keys"
    need "$TMP/keys" FD-4
    need "$TMP/names" FD-4
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        grep -qx -- "$k" "$TMP/names" || cbad="$cbad $k"
    done < "$TMP/keys"
    if [ -z "$cbad" ]; then ok "FD-4 every portal catalogue key has a ledger row"
    else no "FD-4 catalogue key with no ledger row:$cbad"; fi
else
    no "FD-4 the portal catalogue $CATALOGUE is MISSING -- the dynamic-key arm cannot be checked"
fi

# ---------------------------------------------------------------- cite resolution
cite_bad=""
check_cites() {   # $1 = fact name (the token a cite must still carry), $2 = cell
    _cn=$1
    for _c in $2; do
        case "$_c" in NONE|OPERATOR) continue ;; esac
        _tok=$_cn
        _p=$_c
        case "$_c" in *'~'*) _tok=${_c##*~}; _p=${_c%%~*} ;; esac
        _f=${_p%:*}
        _l=${_p##*:}
        case "$_l" in ''|*[!0-9]*) cite_bad="$cite_bad $_cn->$_c(not-a-cite)"; continue ;; esac
        if [ ! -f "$_f" ]; then cite_bad="$cite_bad $_cn->$_c(no-such-file)"; continue; fi
        _line=$(sed -n "${_l}p" "$_f")
        case "$_line" in
            *"$_tok"*) : ;;
            *) cite_bad="$cite_bad $_cn->$_c(line-no-longer-names-$_tok)" ;;
        esac
    done
}

orphan=""; waivers=0; wbad=""; opbad=""
need "$TMP/rows" FD-5
while IFS='|' read -r name kind root writer readers deflt rest; do
    [ -n "${name:-}" ] || continue
    check_cites "$name" "$writer"
    [ "$readers" = NONE ] || check_cites "$name" "$readers"
    check_cites "$name" "${deflt##*@}"

    case "$writer" in
        NONE)
            waivers=$((waivers + 1))
            case "${rest:-}" in
                ESCALATED:*) : ;;
                *) wbad="$wbad $name(writer=NONE without an ESCALATED: disposition)" ;;
            esac
            ;;
        OPERATOR)
            [ "$kind" = operator ] || opbad="$opbad $name(writer=OPERATOR but kind=$kind)"
            ;;
    esac
    if [ "$readers" = NONE ]; then
        case "${rest:-}" in
            UNBUILT:*) : ;;
            *) orphan="$orphan $name(readers=NONE without an UNBUILT: disposition)" ;;
        esac
    fi
    [ "$root" = /etc/p5 ] || [ "$root" = /etc/bond ] || wbad="$wbad $name(root=$root is neither fact root)"
done < "$TMP/rows"

# FD-5 STALE-CITE
if [ -z "$cite_bad" ]; then ok "FD-5 every ledger cite resolves and its line still names the fact"
else no "FD-5 STALE-CITE:$cite_bad"; fi

# FD-6 ORPHAN
if [ -z "$orphan" ]; then ok "FD-6 no ledger row is an ORPHAN (readers=NONE only where declared unbuilt)"
else no "FD-6 ORPHAN:$orphan"; fi

# FD-7 the escalation waivers, counted for EQUALITY
if [ -n "$wbad" ]; then
    no "FD-7 malformed writer/root cell:$wbad"
elif [ "$waivers" = "$WAIVERS_EXPECT" ]; then
    ok "FD-7 writer=NONE rows: $waivers, all ESCALATED:, exactly the expected $WAIVERS_EXPECT"
else
    no "FD-7 writer=NONE rows: $waivers, expected exactly $WAIVERS_EXPECT -- a fact lost its writer, or one was silently added"
fi

# FD-8 operator declarations
if [ -z "$opbad" ]; then ok "FD-8 writer=OPERATOR appears only on kind=operator rows"
else no "FD-8 $opbad"; fi

# FD-9 ROOT-MISMATCH -- the portal USED to read and write P5 facts at the
# PRE-ADR-005 root /etc/bond. Not U133's file: it is inside U51a's named NS-5
# waiver, owners U23/U56/U120. Named and COUNTED, never normalised away -- a
# checker that skipped the portal is a checker that would not have found this.
# CLOSED IN CODE BY U220: lib/portal-lib.sh now defaults BOND_DIR to /etc/p5, and
# the portal harness compares that default against the reconciler's own (ROOT-1)
# instead of against an export. The residue this waiver still counts is TEXT in
# catalogue/fields, owned by U227 -- see the constant above.
RM=$(grep -rn '/etc/bond' "$PORTAL" 2>/dev/null | grep -c .); [ -n "$RM" ] || RM=0
echo "NOTE ROOT-MISMATCH deploy/p5/portal -> root=/etc/bond, $RM references, owner=U23/U56/U120 (U51a NS-5 waiver)"
if [ "$RM" = "$ROOT_MISMATCH_EXPECT" ]; then
    ok "FD-9 portal ROOT-MISMATCH references: $RM, exactly the waived $ROOT_MISMATCH_EXPECT"
else
    no "FD-9 portal ROOT-MISMATCH references: $RM, waived $ROOT_MISMATCH_EXPECT -- the waiver moved"
fi

# FD-10 THE RENAME BAR. `lightning` is the user-facing MODE name (ADR-003 sec 2);
# the operator fact that switches the internal spotty-class duplicator was
# renamed to spotty_dup by U133. A reader left on the old name is a half-landed
# rename: the verb writes one file and the reconciler reads another, silently.
#
# FD-10 IS BOUNDED BY SWEEP_DIRS AND SAYS SO. "no reference survives" would be a
# claim about the whole repo, and this grep cannot make it: two references live
# outside the swept trees. They are not swept away silently -- FD-12 below greps
# the WHOLE tree and asserts, for EQUALITY, exactly which files outside the
# sweep still carry the old name.
OLD_RE='(\$\{?BOND_DIR\}?|/etc/p5|/etc/bond)/lightning'
OLD=$(grep -rnE "$OLD_RE" $SWEEP_DIRS 2>/dev/null | grep -c .); [ -n "$OLD" ] || OLD=0
if [ "$OLD" = 0 ]; then
    ok "FD-10 no reference to the OLD fact name lightning survives IN THE SWEPT TREES ($SWEEP_DIRS) -- renamed to spotty_dup"
else
    echo "     offending references:"
    grep -rnE "$OLD_RE" $SWEEP_DIRS 2>/dev/null | sed 's/^/       /'
    no "FD-10 $OLD reference(s) still name the OLD fact lightning -- the rename to spotty_dup is HALF-LANDED"
fi

# FD-12 THE OUT-OF-SCOPE HALF OF THE RENAME, NAMED AND COUNTED. FD-10 only sees
# deploy + orchestration/ecosim/p5. The whole tree is grepped here and the set of
# OTHER files carrying the old name is asserted for equality against the two this
# unit found and does not own:
#   p4-bondagg/daemon/lightning.go   a COMMENT naming the old fact under the fact
#                                    root, beside the AGG_LIGHTNING env key, which
#                                    U133 deliberately did NOT rename (U47a/U138).
#   docs/ROADMAP.md                  records: the U133 row's own premise text and
#                                    the OPEN U47b row, which specifies the
#                                    mechanism as the old name (owner U47b).
# THIS COMMENT DELIBERATELY DOES NOT SPELL THE OLD PATH. Writing it out here makes
# the checker its own offender: FD-10 and FD-3 both fired on these two lines the
# first time they were written, which is the bar working, not a false positive.
# Neither is executable P5 code, so neither can half-land the rename the way a
# reader would -- but a NEW file naming the old fact reddens this bar the moment
# it appears. The set is compared by PATH, not by path:line: the ROADMAP's line
# numbers move every time a row is added, and a bar that reds on unrelated
# editing is a bar that gets deleted.
OUT_WAIVED="docs/ROADMAP.md p4-bondagg/daemon/lightning.go"
# U259: only the waived files that are PRESENT can be expected. sync-public-ci.sh publishes
# docs/deploy-p5-server.md and no other docs/ file, so docs/ROADMAP.md is absent on the mirror
# and this exact-set comparison could never be green there -- the arms were red on every
# published branch while a full checkout stayed green. A file that is not in the tree cannot
# carry the old name, so intersecting keeps the bar exact on each shape instead of weakening it.
OUT_WAIVED_HERE=""
for _ow in $OUT_WAIVED; do
    [ -e "$_ow" ] && OUT_WAIVED_HERE="${OUT_WAIVED_HERE}${_ow} "
done
OUT_WAIVED_HERE=$(printf '%s' "$OUT_WAIVED_HERE" | sed 's/ *$//')
: > "$TMP/old.out"
for _e in * .[!.]*; do
    [ -e "$_e" ] || continue
    case "$_e" in .git) continue ;; esac
    grep -rnE "$OLD_RE" "$_e" 2>/dev/null >> "$TMP/old.out" || true
done
need "$TMP/old.out" FD-12
# Drop the swept trees (FD-10 owns those) and reduce to unique paths.
OUT_PATHS=$(cut -d: -f1 "$TMP/old.out" | sed 's|^\./||' \
    | grep -vE '^(deploy/|orchestration/ecosim/p5/)' | sort -u | tr '\n' ' ' | sed 's/ *$//')
OUT_N=$(grep -vE '^(\./)?(deploy/|orchestration/ecosim/p5/)' "$TMP/old.out" | grep -c .)
echo "NOTE OUT-OF-SWEEP lightning references: $OUT_N line(s) in [$OUT_PATHS], owners U47a/U138 (the env key) and U47b (the record)"
if [ "$OUT_PATHS" = "$OUT_WAIVED_HERE" ]; then
    ok "FD-12 outside the sweep the OLD name lightning survives in exactly the waived files present here: $OUT_WAIVED_HERE"
else
    # Truncated: one of the waived hits is a ROADMAP row 4 KB wide, and a bar that
    # prints a 4 KB line is a bar whose real message scrolls away.
    grep -vE '^(\./)?(deploy/|orchestration/ecosim/p5/)' "$TMP/old.out" | cut -c1-140 | sed 's/^/       /'
    no "FD-12 out-of-sweep lightning files are [$OUT_PATHS], waived-and-present [$OUT_WAIVED_HERE] (full waiver [$OUT_WAIVED]) -- a file gained or lost the OLD fact name"
fi

# FD-11 BOTH new files are REPO-ONLY. A file under /etc/p5 that the installer does
# not know about trips its own namespace refusal (IN-16, p5/contract/paths:229-232).
# TWO files were added by this unit and BOTH must stay out of the install set: the
# ledger AND this checker. The earlier form greped for the ledger only, so the
# checker was unasserted while orchestration/ecosim/p5/run.sh's NS-5 waiver already
# claimed FD-11 covered both.
#
# THE SUBJECTS ARE ASSERTED TO EXIST FIRST, like FD-4's `[ -f "$CATALOGUE" ]`. A
# grep over a renamed or moved install set returns zero hits, and zero hits is the
# green answer here -- so a renamed filemap would silently certify a file as
# never-shipped. That is the same absence-reads-as-success shape the header refuses.
INSTALL_SET="p5/payload/filemap p5/bin/p5-install"
smiss=""
for _s in $INSTALL_SET; do [ -f "$_s" ] || smiss="$smiss $_s"; done
if [ -n "$smiss" ]; then
    no "FD-11 the install set MOVED -- missing:$smiss . This bar checked NOTHING; re-point it, do not delete it"
else
    # NON-COMMENT lines only (U211 merge, 2026-09-05): p5/payload/filemap's header now
    # carries PK-4's mechanical EXCLUDE account, which must NAME deploy/p5/facts and
    # deploy/p5/test-facts.sh as deliberately-not-shipped. A comment ships nothing;
    # a ROW does. The seeded A/B for this bar is a row, not a comment.
    SHIP=$( { grep -n 'deploy/p5/facts\|p5/facts\|test-facts\.sh' $INSTALL_SET 2>/dev/null || true; } | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -c . )
    if [ "$SHIP" = 0 ]; then
        ok "FD-11 both new files are repo-only: deploy/p5/facts AND deploy/p5/test-facts.sh are absent from $INSTALL_SET"
    else
        { grep -n 'deploy/p5/facts\|p5/facts\|test-facts\.sh' $INSTALL_SET 2>/dev/null || true; } | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | sed 's/^/       /'
        no "FD-11 the install set references the ledger or its checker ($SHIP hit(s)) -- it would ship and trip IN-16"
    fi
fi

BARS=$((pass + fail))
if [ "$BARS" -ge "$BARS_MIN" ]; then ok "FD-0 bar count $BARS >= floor $BARS_MIN"
else no "FD-0 only $BARS bars ran, floor $BARS_MIN -- the checker exited early"; fi

echo "===== facts: $pass passed, $fail failed ====="
[ "$fail" = 0 ] || exit 1
