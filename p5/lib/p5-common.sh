#!/bin/sh
# p5-common.sh -- the P5 product's shared shell library.
#
# Sourced by p5-install (from the package) and by p5-uninstall, p5-version and
# p5-deadman (from /usr/lib/p5 on the box). BUSYBOX-SAFE POSIX sh: no `local`,
# no arrays, no `[[`, no `==`, no bashisms. The deployed artifacts under
# deploy/p5 avoid `local` too (grep -c '^\s*local ' deploy/p5/bond-xctl -> 0);
# this follows the same rule rather than assuming busybox ash accepts it.
#
# TEST ROOT. Every production path is composed from $P5_ROOT, which is EMPTY in
# production and a temp dir under test. This is the same override convention
# the shipped reconciler artifacts use (BOND_DIR/RUN_DIR/XCTL in
# deploy/p5/bondctl:17-21) and is what lets test/run.sh exercise the real
# scripts hermetically instead of a copy of them.
#
# ONE SOURCE OF TRUTH FOR "WHAT P5 OWNS". contract/paths is it. This library
# reads that file and every other list is DERIVED from it: what the installer
# may place, what it records, which directories it may record, what the clean
# predicate looks for, and what the removal plan contains. There is no second
# hand-written list to drift. contract/paths states, in its header, the three
# things that remain hand-maintained and what bars them from diverging.
#
# NO CONSTANTS LIVE HERE. There are no timeouts, retries, ports, sizes or
# priorities in this file or in any E0 artifact. The only numbers are exit codes
# (an interface vocabulary, listed below, with no behavioural effect),
# P5_CONTRACT_VERSION (a schema counter) and one sha256 TEST VECTOR (a
# mathematical fact about a fixed string, used to prove the hasher is real).
# None is a tuned parameter. If a later unit needs a real constant here, it must
# arrive with its derivation.

# ---- exit-code vocabulary --------------------------------------------------
# These are an INTERFACE, chosen so a caller can branch on the reason without
# parsing text. They are not derived from measurement and do not need to be.
P5_EX_OK=0          # success
P5_EX_FAIL=1        # generic failure (a check ran and said no)
P5_EX_USAGE=2       # bad arguments
P5_EX_INTEGRITY=3   # sha256/manifest/provenance mismatch, or an unpinned file
P5_EX_CONTRACT=4    # a path violates contract/namespace, contract/foreign or contract/paths
P5_EX_PRECOND=5     # precondition not met (box in a state we refuse to act on)
P5_EX_NOTIMPL=6     # this path is a defined entry point whose logic another unit owns

# ---- schema version --------------------------------------------------------
# Bumped when the on-disk layout or the stamp field set changes in a way an
# older p5-uninstall could not read. A tool that meets a stamp with a HIGHER
# version than it understands must refuse rather than guess: it would be
# removing a layout it does not know.
#
# 2: installed.files became complete -- it now contains the stamp and both
#    record files, and carries one self-referential row whose hash field is the
#    token below instead of a sha256.
# 3: the intent records (install.inprogress / remove.inprogress) became part of
#    the layout, and the completion marker moved from "the stamp exists" to
#    "the stamp exists AND no intent record is left". A version-2 tool reading a
#    version-3 box would call a crashed install "installed".
P5_CONTRACT_VERSION=3

# The hash field of the one row that cannot contain its own hash. A file cannot
# record its own sha256: the record changes the moment the value is written.
# Exactly one row in installed.files carries this token (installed.files
# itself); it is a REMOVAL entry that --verify checks for presence only. The
# alternative -- leaving the record out of the record -- is what wedged the box.
P5_SELFREF="self-referential"

# ---- environment overrides, captured BEFORE any default is applied ---------
# Several gates in this product can be pointed elsewhere from the environment:
# the test harness needs that, and so does an out-of-tree layout. The danger is
# that the same lever silently defeats a check on a real box. So every override
# is captured here, announced loudly by every entry point, and recorded in the
# stamp together with the sha256 of each contract file actually used.
#
# P5_UNINSTALL IS GONE, and its absence is the point. It used to let
# `P5_UNINSTALL=/bin/true p5-install ...` turn the clean-box precondition into a
# no-op, because the installer asked an external program whether the box was
# clean. The installer now computes the P5 half itself, in-process, from
# p5_box_state below -- there is no external program to substitute, so the
# bypass is not defended against, it does not exist. Bar IN-17 asserts the
# variable appears nowhere in p5-install and that setting it changes nothing.
#
# The capture must happen BEFORE the defaults below: afterwards "the operator
# set it" and "we defaulted it" are indistinguishable. P5_TAG is deliberately
# not in the list -- it is the caller's own name for itself, set by each entry
# point before sourcing, and it gates nothing.
P5_OVERRIDES=""
P5_OVERRIDE_NAMES=""
for _p5o_v in P5_ROOT P5_SHA256 P5_LIB_SRC P5_CONTRACT_SRC \
              P5_CONTRACT_NS P5_CONTRACT_FOREIGN P5_CONTRACT_PATHS P5_FAULT_AFTER ; do
    # Indirect READ over the fixed literal list written above. No text from a
    # package, a filemap or an argument is ever evaluated here.
    eval "_p5o_isset=\${$_p5o_v+set}"
    [ "${_p5o_isset:-}" = set ] || continue
    eval "_p5o_val=\${$_p5o_v}"
    P5_OVERRIDE_NAMES="${P5_OVERRIDE_NAMES}${P5_OVERRIDE_NAMES:+ }$_p5o_v"
    P5_OVERRIDES="${P5_OVERRIDES}${P5_OVERRIDES:+
}$_p5o_v=$_p5o_val"
done

# P5_FAULT_AFTER: kill this process hard before write number N. It exists so the
# battery can reproduce power loss at every step of an install (bar CR-1) rather
# than assert that recovery works. It is in the override list, so it is
# announced and recorded like any other. It is safe to ship because it is
# strictly FAIL-CLOSED: its only effect is to abort, so it can never make an
# install succeed that would otherwise have been refused.
P5_FAULT_AFTER="${P5_FAULT_AFTER:-}"
P5_FAULT_N=0

# p5_fault_point -- called immediately before each destructive write.
p5_fault_point() {
    P5_FAULT_N=$((P5_FAULT_N + 1))
    [ -n "$P5_FAULT_AFTER" ] || return 0
    [ "$P5_FAULT_N" = "$P5_FAULT_AFTER" ] || return 0
    # No trap, no cleanup, no message on stdout: this is meant to look like the
    # power going out, not like an orderly abort.
    kill -9 $$
}

# p5_fault_stage DEST -- test-only, and a different instrument from the one
# above. P5_FAULT_AFTER counts WRITES, so it cannot express an interruption
# INSIDE one: the window between "the stage exists on disk" and "the rename has
# published it". That window is the whole of blocker B3 -- it is where a file
# sits in a live activation directory under a name the product never meant to
# publish -- so it needs its own injector. Naming a destination rather than a
# counter also keeps P5_FAULT_AFTER's numbering, and every bar written against
# it, untouched.
p5_fault_stage() {
    [ -n "${P5_FAULT_STAGE:-}" ] || return 0
    [ "$1" = "$P5_FAULT_STAGE" ] || return 0
    kill -9 $$
}

# ---- roots -----------------------------------------------------------------
P5_ROOT="${P5_ROOT:-}"
# $P5_ROOT with its own symlinks resolved, memoised on first use by p5_phys_ok.
P5_ROOT_REAL=""
P5_SBIN="${P5_ROOT}/usr/sbin"
P5_LIBDIR="${P5_ROOT}/usr/lib/p5"
P5_ETCDIR="${P5_ROOT}/etc/p5"
P5_RUNDIR="${P5_ROOT}/var/run/p5"
P5_DEADDIR="${P5_ETCDIR}/deadman"

P5_STAMP="${P5_LIBDIR}/stamp"
P5_FILEREC="${P5_LIBDIR}/installed.files"
P5_DIRREC="${P5_LIBDIR}/installed.dirs"
P5_INPROG_INSTALL="${P5_LIBDIR}/install.inprogress"
P5_INPROG_REMOVE="${P5_LIBDIR}/remove.inprogress"

# Contract copies. Left EMPTY on purpose: WHERE the contract lives differs by
# caller -- the package's own copy for p5-install, the installed copy under
# /usr/lib/p5 for the on-box entry points -- and a default applied here would
# make an operator override indistinguishable from that difference. Each entry
# point calls p5_contract_dir with its own location.
P5_CONTRACT_NS="${P5_CONTRACT_NS:-}"
P5_CONTRACT_FOREIGN="${P5_CONTRACT_FOREIGN:-}"
P5_CONTRACT_PATHS="${P5_CONTRACT_PATHS:-}"

# p5_contract_dir DIR PREFIX -- point any contract file the caller did not
# override at DIR/<PREFIX><name>. The package ships them as namespace/foreign/
# paths; the box carries them as contract-namespace/contract-foreign/
# contract-paths, because /usr/lib/p5 is one flat directory.
p5_contract_dir() {
    [ -n "$P5_CONTRACT_NS" ]      || P5_CONTRACT_NS="$1/${2}namespace"
    [ -n "$P5_CONTRACT_FOREIGN" ] || P5_CONTRACT_FOREIGN="$1/${2}foreign"
    [ -n "$P5_CONTRACT_PATHS" ]   || P5_CONTRACT_PATHS="$1/${2}paths"
}

# ---- THE RECOVERY TOOLCHAIN ------------------------------------------------
# p5_self_toolchain -> the installed paths WITHOUT WHICH the box's own
# /usr/sbin/p5-uninstall cannot run, dependency-first, entry point LAST.
#
# It is not a taste list and it is not a second inventory: it is exactly what
# every entry point's preamble reads before it can do anything -- p5-common.sh
# (sourced) and the three contract copies (p5_contract_dir) -- plus the entry
# point itself. Every one of them is also a declared `install` row in
# contract/paths, so removal still refuses anything the contract does not
# declare; this function only says in WHAT ORDER they may go.
#
# Why it exists. A removal that unlinks any of these and is then interrupted
# leaves a box carrying P5 files with no verb on it that can finish the job.
# Round 2 measured exactly that: /usr/sbin/p5-uninstall went in the payload
# pass -- action 5 of 17 on the battery's client fixture, and MU-RCV prints the
# index rather than this comment asserting it -- and p5-install then printed
# "Remedy: p5-uninstall --remove", naming the file
# the run had just deleted. On a box with no console that is the box. So
# --remove takes this whole set in ONE final action, after everything else it
# will ever touch (bar RCV-1), and p5-install resolves its remedy to a verb it
# has checked is present and runnable (bar RCV-3).
#
# The residual window is named rather than claimed away: a SIGKILL landing
# BETWEEN the unlinks inside that one action can still strand the toolchain
# half-removed. What that leaves is a subset of these five paths and nothing
# else, the package's own bin/p5-uninstall --remove --recover clears it (bar
# RCV-4), and p5-install names that copy instead of the box's.
p5_self_toolchain() {
    echo /usr/lib/p5/contract-foreign
    echo /usr/lib/p5/contract-namespace
    echo /usr/lib/p5/contract-paths
    echo /usr/lib/p5/p5-common.sh
    echo /usr/sbin/p5-uninstall
}

# p5_recovery_verb -> the p5-uninstall an operator can actually RUN right now,
# printed as the command to type. Prefers the box's own copy, but only when it
# and its library are both present; otherwise names the package copy beside
# $1 (the caller's own bin directory), which exists whenever the caller does.
# Callers print what this returns and never a hard-coded "p5-uninstall".
p5_recovery_verb() {
    if [ -x "${P5_ROOT}/usr/sbin/p5-uninstall" ] && [ -r "${P5_ROOT}/usr/lib/p5/p5-common.sh" ]; then
        echo "p5-uninstall"
    else
        # Quoted: the package is often unpacked under a path with a space in
        # it, and a remedy the operator cannot paste is not a remedy.
        echo "sh '${1}/p5-uninstall'"
    fi
}

P5_TAG="${P5_TAG:-p5}"

# ---- logging ---------------------------------------------------------------
# stdout for the operator, syslog when there is one. Never silent: an installer
# that says nothing is an installer nobody can audit after the fact.
p5_log() {
    echo "$P5_TAG: $*"
    logger -t "$P5_TAG" "$*" 2>/dev/null
    return 0
}

p5_err() {
    echo "$P5_TAG: ERROR: $*" >&2
    logger -t "$P5_TAG" "ERROR: $*" 2>/dev/null
    return 0
}

# p5_die CODE MESSAGE...
p5_die() {
    _p5d_code="$1"; shift
    p5_err "$*"
    exit "$_p5d_code"
}

# p5_announce_overrides -- say, loudly, that a gate was pointed elsewhere.
# Called by every entry point once its arguments are parsed. Silence here is
# the failure mode: an override that nobody sees is an override nobody audits.
p5_announce_overrides() {
    [ -n "$P5_OVERRIDES" ] || return 0
    p5_err "ENVIRONMENT OVERRIDE IN EFFECT -- these were supplied by the caller and are NOT the shipped defaults:"
    printf '%s\n' "$P5_OVERRIDES" | while IFS= read -r _p5a_line; do
        [ -n "$_p5a_line" ] && p5_err "  $_p5a_line"
    done
    p5_err "Each of these can relocate a check (P5_CONTRACT_* relocate the contract the install is judged"
    p5_err "against; P5_ROOT relocates the whole box; P5_FAULT_AFTER aborts the run at a chosen write)."
    p5_err "The NAMES are recorded in the install stamp as P5_INSTALL_OVERRIDES, and the sha256 of every"
    p5_err "contract file actually used is recorded beside them, so an install judged against a mutated"
    p5_err "contract is detectable on the box afterwards."
    return 0
}

# ---- tools -----------------------------------------------------------------
# sha256sum is busybox-provided on OpenWrt and is the ONLY hashing dependency.
# Overridable so the test harness can prove the failure path when it is absent.
P5_SHA256="${P5_SHA256:-sha256sum}"

# THE TEST VECTOR. sha256("p5\n") -- a mathematical fact about a fixed string,
# not a tuned parameter. It exists because P5_SHA256 is an override, and an
# override that points at a program which prints plausible-looking hashes would
# defeat BOTH the package integrity check and the install record while leaving
# every message reassuring. Announcing the override is not enough; this proves
# the hasher is the function it claims to be. A hasher that fails this is an
# integrity failure (exit 3), not a missing tool.
P5_SHA256_VECTOR="36c946c9dd2838dc32099d4acbe7c3ac7348ebef8edac3b977444652e75f667b"

# p5_workdir PREFIX -> prints a scratch directory THIS process created, or fails.
#
# `mkdir -p` ADOPTS an existing directory. Every P5 tool used it, on a name that is only
# "$prefix.$$" -- and $$ is not unique: pids wrap, and p5_fault_point's `kill -9 $$` skips
# the cleanup trap BY DESIGN, so stale scratch dirs are the EXPECTED state, not bad luck.
# MEASURED 2026-08-31: 52-54 leftover /tmp/p5-* entries with pids spanning five and seven
# digits.
#
# On this product that is not tidiness. $P5_WORK/ordered IS THE REMOVAL PLAN -- the file
# sitting on disk between the gate that approved a path and the `rm` that acts on it, which
# is precisely the window U75's point-of-use re-check exists to survive. A second process
# adopting that directory can change the plan underneath the check. The server has no
# console.
#
# So: create EXCLUSIVELY (plain `mkdir` fails on an existing directory -- that is the whole
# point) and step to the next candidate rather than adopting, so a stale leftover can neither
# be inherited nor wedge a run. 64 is a BOUND, not a tuned value: exhausting it needs 64 live
# directories sharing one pid. If it ever fails, the scratch tree is the bug -- do not raise
# the number. Mirrors p5/test/ledger.sh:p5t_workdir, deliberately: harness and product must
# not differ on this.
p5_workdir() {
    _p5w_i=0
    while [ "$_p5w_i" -lt 64 ]; do
        _p5w_d="${TMPDIR:-/tmp}/$1.$$.$_p5w_i"
        if mkdir "$_p5w_d" 2>/dev/null; then
            printf '%s
' "$_p5w_d"
            return 0
        fi
        _p5w_i=$((_p5w_i + 1))
    done
    return 1
}

p5_require_tools() {
    command -v "$P5_SHA256" >/dev/null 2>&1 || \
        p5_die "$P5_EX_PRECOND" "$P5_SHA256 not found; cannot verify or record integrity"
    # The test vector is written inside an EXCLUSIVELY created directory rather than to a
    # bare "$$"-named path. `>` truncates whatever is already there, so the old form both
    # clobbered a stranger's file and let a stranger pre-place ours -- and this vector
    # decides whether $P5_SHA256 is trusted to verify every other file (U82).
    _p5t_dir=$(p5_workdir p5-hashvec) || \
        p5_die "$P5_EX_PRECOND" "cannot create an exclusive temp directory under ${TMPDIR:-/tmp}; refusing to continue"
    _p5t_tmp="$_p5t_dir/vector"
    printf 'p5\n' > "$_p5t_tmp" 2>/dev/null || \
        p5_die "$P5_EX_PRECOND" "cannot write a temp file under ${TMPDIR:-/tmp}; refusing to continue"
    _p5t_got=$(p5_hash "$_p5t_tmp")
    rm -rf "$_p5t_dir"
    [ "$_p5t_got" = "$P5_SHA256_VECTOR" ] || \
        p5_die "$P5_EX_INTEGRITY" "$P5_SHA256 does not compute sha256: test vector gave '$_p5t_got', expected '$P5_SHA256_VECTOR'. Refusing to verify anything with it"
    return 0
}

# p5_hash FILE -> prints the bare hash, or fails
p5_hash() {
    "$P5_SHA256" "$1" 2>/dev/null | cut -d' ' -f1
}

# ---- durable writes --------------------------------------------------------
# EVERY persistent write in this product goes through one of these two, and the
# reason is FM-4: `install -m` and `> file` both truncate in place, so power
# loss during a record write leaves a TRUNCATED removal record -- an
# uninstaller that silently under-removes -- and power loss during the stamp
# leaves a stamp missing the very fields it exists to carry. Write beside,
# sync, rename: rename is atomic within a filesystem, and the temp file is
# always in the destination's own directory so it never crosses one.
#
# The temp name is fixed so a leftover from a killed run is findable and is
# swept by the removal plan, rather than being a random name nobody can name.
#
# It is a DOT-PREFIXED SIBLING (`dir/.p5-incoming.NAME`), not a suffixed twin
# (`dir/NAME.p5-incoming`), and that is a safety property, not a style choice.
# Some destination directories are ACTIVATION DIRECTORIES: a daemon scans them
# with a shell glob and runs whatever it finds, so PLACEMENT IS ACTIVATION and
# the NAME is the only thing that decides membership. The one this product
# ships into is /etc/hotplug.d/iface, and OpenWrt's /sbin/hotplug-call is, in
# full:
#     for script in /etc/hotplug.d/$1/*; do ( [ -f $script ] && . $script ); done
# There is no enable step. A stage named `94-p5.p5-incoming` matches `*` and is
# SOURCED by netifd -- while `install` is still writing it (so a half-written
# hook half-runs: the commands before the truncation point execute, then the
# shell errors), and again on every iface event for as long as an interrupted
# run leaves it there.
#
# A leading <period> is excluded from `*` by the shell itself (POSIX XCU
# 2.13.3: a filename's leading period must be matched explicitly), and every
# scanner of this shape also gates on `[ -f ]`. So a dot-prefixed sibling is
# invisible to EVERY such directory scanner, which means this product does not
# have to carry a list of which of its destination directories are activating
# -- a list that would be wrong the first time a destination was added.
#
# The stage stays in the DESTINATION'S OWN DIRECTORY, so the rename cannot
# cross a filesystem and cannot degrade to a copy. Bar HP-3 asserts that for
# every destination the package ships.
P5_INCOMING=".p5-incoming"

# p5_incoming_of DEST -> the staging path for DEST. The ONLY place the staging
# name is formed; nothing may spell it inline.
p5_incoming_of() {
    case "$1" in
        */*) echo "${1%/*}/$P5_INCOMING.${1##*/}" ;;
        *)   echo "$P5_INCOMING.$1" ;;
    esac
}

p5_sync() { sync 2>/dev/null; return 0; }

# p5_atomic_write DEST [MODE] -- content on stdin.
p5_atomic_write() {
    _aw_dest="$1"; _aw_mode="${2:-644}"; _aw_tmp=$(p5_incoming_of "$1")
    cat > "$_aw_tmp" || { p5_err "cannot write $_aw_tmp"; return 1; }
    chmod "$_aw_mode" "$_aw_tmp" 2>/dev/null
    p5_sync
    mv -f "$_aw_tmp" "$_aw_dest" || { p5_err "cannot rename $_aw_tmp -> $_aw_dest"; rm -f "$_aw_tmp"; return 1; }
    p5_sync
    return 0
}

# p5_atomic_install MODE SRC DEST -- place a file, never truncating the live one.
p5_atomic_install() {
    _ai_tmp=$(p5_incoming_of "$3")
    install -m "$1" "$2" "$_ai_tmp" || { p5_err "cannot stage $2 -> $_ai_tmp"; return 1; }
    p5_sync
    p5_fault_stage "$(p5_unroot "$3")"
    mv -f "$_ai_tmp" "$3" || { p5_err "cannot rename $_ai_tmp -> $3"; rm -f "$_ai_tmp"; return 1; }
    return 0
}

# ---- contract matching -----------------------------------------------------
# All matchers take a PRODUCTION path (no $P5_ROOT prefix) because that is what
# the contract, the record and the box all speak. Callers holding a rooted path
# strip the prefix with p5_unroot first.

# p5_unroot PATH -> PATH with $P5_ROOT removed from the front
p5_unroot() {
    if [ -n "$P5_ROOT" ]; then
        case "$1" in
            "$P5_ROOT"/*) echo "${1#"$P5_ROOT"}" ;;
            *) echo "$1" ;;
        esac
    else
        echo "$1"
    fi
}

# p5_trim TEXT -> sets $P5_TRIM to TEXT without leading/trailing blanks.
# contract/paths is column-aligned for reading, so every field arrives padded.
# Sets a variable instead of printing because it runs once per field per row
# and a subshell per field would be the whole cost of parsing the file.
p5_trim() {
    P5_TRIM="$1"
    while :; do
        case "$P5_TRIM" in
            ' '*|'	'*) P5_TRIM=${P5_TRIM#?} ;;
            *) break ;;
        esac
    done
    while :; do
        case "$P5_TRIM" in
            *' '|*'	') P5_TRIM=${P5_TRIM%?} ;;
            *) break ;;
        esac
    done
}

# p5_require_contracts -- all three contract files must be readable before any
# destination is judged. Called ONCE, up front, by every entry point. The
# matchers below never die: they are called inside `$( )` in places, where an
# `exit` would only leave the subshell and the caller would read the non-zero
# status as "no match" -- i.e. fail OPEN, which is the one thing a contract
# check must never do. So the matchers fail CLOSED (deny) and this function is
# what turns a missing contract into a loud abort.
p5_require_contracts() {
    [ -r "$P5_CONTRACT_NS" ] || p5_die "$P5_EX_PRECOND" "namespace contract not readable: $P5_CONTRACT_NS"
    [ -r "$P5_CONTRACT_FOREIGN" ] || p5_die "$P5_EX_PRECOND" "foreign contract not readable: $P5_CONTRACT_FOREIGN"
    [ -r "$P5_CONTRACT_PATHS" ] || p5_die "$P5_EX_PRECOND" "path inventory not readable: $P5_CONTRACT_PATHS"
}

# p5_ns_ok ROLE PATH -> 0 if the path is inside the namespace P5 may own.
# Unreadable contract => 1 (deny).
p5_ns_ok() {
    [ -r "$P5_CONTRACT_NS" ] || return 1
    _p5n_role="$1"; _p5n_path="$2"; _p5n_hit=1
    while IFS='|' read -r _p5n_r _p5n_pat; do
        case "$_p5n_r" in ''|\#*) continue ;; esac
        [ -n "$_p5n_pat" ] || continue
        if [ "$_p5n_r" = both ] || [ "$_p5n_r" = "$_p5n_role" ]; then
            # Unquoted on purpose: this is glob matching, not comparison.
            case "$_p5n_path" in $_p5n_pat) _p5n_hit=0; break ;; esac
        fi
    done < "$P5_CONTRACT_NS"
    return "$_p5n_hit"
}

# p5_foreign PATH -> 0 if the path belongs to a stack that is NOT P5.
# Prints "origin|pattern" of the first match so the refusal can name it.
# Unreadable contract => 0 with origin `unreadable` (deny), never fail-open.
p5_foreign() {
    [ -r "$P5_CONTRACT_FOREIGN" ] || { echo "unreadable|$P5_CONTRACT_FOREIGN"; return 0; }
    _p5f_path="$1"; _p5f_hit=1
    while IFS='|' read -r _p5f_o _p5f_pat; do
        case "$_p5f_o" in ''|\#*) continue ;; esac
        [ -n "$_p5f_pat" ] || continue
        case "$_p5f_path" in $_p5f_pat) echo "$_p5f_o|$_p5f_pat"; _p5f_hit=0; break ;; esac
    done < "$P5_CONTRACT_FOREIGN"
    return "$_p5f_hit"
}

# p5_declared ROLE PATH KIND STATES -> 0 if contract/paths declares PATH.
#
# THE derivation point. The inventory decides what may be written, what may be
# recorded and what may be removed, so a path that is not declared cannot be
# installed, cannot enter the removal record, and cannot be unlinked by
# --remove. KIND is the kind of thing being judged (`file` or `dir`); STATES is
# the space-separated set of `state` values the caller admits, which is how the
# contract says WHO may create a path:
#
#   install/payload/reserved   the installer may place it
#   transient                  an entry point writes it during a run only
#   runtime                    P5 creates it while running; the installer must not
#   enable                     procd creates it at service-enable time
#   uci                        a named UCI object, not a filesystem path at all
#
# A file subject matches a `file` row exactly or a `glob` row by pattern; a dir
# subject matches a `dir` row exactly. Unreadable inventory => 1 (deny).
p5_declared() {
    [ -r "$P5_CONTRACT_PATHS" ] || return 1
    _p5p_role="$1"; _p5p_path="$2"; _p5p_kind="$3"; _p5p_states="$4"; _p5p_hit=1
    while IFS='|' read -r _p5p_k _p5p_r _p5p_p _p5p_o _p5p_s _p5p_n; do
        case "$_p5p_k" in ''|\#*) continue ;; esac
        p5_trim "$_p5p_k"; _p5p_k="$P5_TRIM"
        p5_trim "${_p5p_r:-}"; _p5p_r="$P5_TRIM"
        p5_trim "${_p5p_p:-}"; _p5p_p="$P5_TRIM"
        p5_trim "${_p5p_s:-}"; _p5p_s="$P5_TRIM"
        [ -n "$_p5p_p" ] || continue
        _p5p_sok=1
        for _p5p_x in $_p5p_states; do
            [ "$_p5p_x" = "$_p5p_s" ] && { _p5p_sok=0; break; }
        done
        [ "$_p5p_sok" = 0 ] || continue
        [ "$_p5p_r" = both ] || [ "$_p5p_r" = "$_p5p_role" ] || continue
        if [ "$_p5p_kind" = dir ]; then
            if [ "$_p5p_k" = dir ] && [ "$_p5p_p" = "$_p5p_path" ]; then _p5p_hit=0; break; fi
        else
            if [ "$_p5p_k" = file ]; then
                if [ "$_p5p_p" = "$_p5p_path" ]; then _p5p_hit=0; break; fi
            elif [ "$_p5p_k" = glob ]; then
                # Unquoted on purpose: a glob row's path IS a pattern.
                case "$_p5p_path" in $_p5p_p) _p5p_hit=0; break ;; esac
            fi
        fi
    done < "$P5_CONTRACT_PATHS"
    return "$_p5p_hit"
}

# p5_rows ROLE KINDS STATES -> print `kind|state|path` for every matching row.
# The generic reader every derived list is built from: p5_installable_paths, the
# clean predicate and the removal planner are all one call to this plus a
# filter, which is what keeps them from becoming three lists again.
p5_rows() {
    [ -r "$P5_CONTRACT_PATHS" ] || return 1
    _p5r_role="$1"; _p5r_kinds="$2"; _p5r_states="$3"
    while IFS='|' read -r _p5r_k _p5r_r _p5r_p _p5r_o _p5r_s _p5r_n; do
        case "$_p5r_k" in ''|\#*) continue ;; esac
        p5_trim "$_p5r_k"; _p5r_k="$P5_TRIM"
        p5_trim "${_p5r_r:-}"; _p5r_r="$P5_TRIM"
        p5_trim "${_p5r_p:-}"; _p5r_p="$P5_TRIM"
        p5_trim "${_p5r_s:-}"; _p5r_s="$P5_TRIM"
        [ -n "$_p5r_p" ] || continue
        _p5r_ok=1
        for _p5r_x in $_p5r_kinds; do [ "$_p5r_x" = "$_p5r_k" ] && { _p5r_ok=0; break; }; done
        [ "$_p5r_ok" = 0 ] || continue
        _p5r_ok=1
        for _p5r_x in $_p5r_states; do [ "$_p5r_x" = "$_p5r_s" ] && { _p5r_ok=0; break; }; done
        [ "$_p5r_ok" = 0 ] || continue
        [ "$_p5r_r" = both ] || [ "$_p5r_r" = "$_p5r_role" ] || continue
        echo "$_p5r_k|$_p5r_s|$_p5r_p"
    done < "$P5_CONTRACT_PATHS"
    return 0
}

# p5_installable_paths ROLE KIND -> every production path the inventory says the
# INSTALLER places unconditionally. Used by p5-install to check its own
# source/mode map against the contract, so the two cannot drift.
p5_installable_paths() {
    p5_rows "$1" "$2" install | cut -d'|' -f3
}

# p5_glob_hits PATTERN -> every EXISTING path under $P5_ROOT matching the
# production glob PATTERN, printed as production paths. Used for the states the
# install-time record cannot cover (enable flags, runtime files).
p5_glob_hits() {
    for _p5g_h in ${P5_ROOT}$1; do
        [ -e "$_p5g_h" ] || [ -L "$_p5g_h" ] || continue
        p5_unroot "$_p5g_h"
    done
    return 0
}

# p5_path_sane PATH -> 0 if the path is a usable absolute destination.
# Rejects relative paths, `..` traversal and shell metacharacters, so a
# malformed filemap line cannot escape the contract check by construction.
p5_path_sane() {
    case "$1" in
        /*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *..*) return 1 ;;
        *'*'*|*'?'*|*'['*|*' '*|*'	'*) return 1 ;;
    esac
    return 0
}

# p5_realdir DIR -> DIR with every symlink on the way to it resolved, or 1.
# `cd -P` + `pwd -P` is the only symlink resolver POSIX guarantees. busybox ash
# has both; `realpath` and `readlink -f` are not on every OpenWrt image.
# No `--`: busybox ash's cd does not take it, and every path this is called
# with is absolute, so there is nothing for an option parser to mistake.
p5_realdir() {
    [ -d "$1" ] || return 1
    ( CDPATH='' cd -P "$1" 2>/dev/null && pwd -P ) || return 1
}

# p5_phys_ok ROLE PATH -> 0 if the PHYSICAL location of PATH is still inside
# the P5 namespace once every symlink on the way to it has been resolved.
#
# THE LEXICAL CHECKS ARE NOT ENOUGH ON THEIR OWN, and that gap is what cost an
# SSH key in the round-2 review. `/etc/p5/*` is a shipped, correct,
# namespace-admitted glob row; if `/etc/p5` is a SYMLINK to /etc/dropbear then
# every hit is SPELLED inside the namespace and LANDS outside it. No amount of
# string matching on the spelling can see that -- only resolving the parent can.
#
# A parent that does not exist is ADMITTED, and that is deliberate rather than
# an oversight: if the parent is absent the target cannot exist either, so the
# unlink is a no-op. It keeps `--remove` idempotent (re-running it after the
# directories are already gone must still succeed) without opening a hole,
# because the admitted case is one where there is nothing there to destroy.
p5_phys_ok() {
    _p5y_role="$1"; _p5y_path="$2"
    _p5y_dir=${_p5y_path%/*}
    [ -n "$_p5y_dir" ] || _p5y_dir=/
    _p5y_base=${_p5y_path##*/}
    [ -n "$_p5y_base" ] || return 1
    [ -d "${P5_ROOT}${_p5y_dir}" ] || return 0
    # The directory exists, so a failure here is the RESOLVER failing, not the
    # path being bad. Fail closed -- but say so, or an interpreter without
    # `cd -P` would make every path unremovable for no stated reason, which is
    # the wedge this whole unit exists to prevent.
    if ! _p5y_real=$(p5_realdir "${P5_ROOT}${_p5y_dir}"); then
        p5_err "cannot resolve the physical location of ${_p5y_dir} (cd -P / pwd -P failed); refusing"
        return 1
    fi
    if [ -n "$P5_ROOT" ]; then
        [ -n "$P5_ROOT_REAL" ] || P5_ROOT_REAL=$(p5_realdir "$P5_ROOT") || return 1
        case "$_p5y_real" in
            "$P5_ROOT_REAL")   _p5y_real="" ;;
            "$P5_ROOT_REAL"/*) _p5y_real="${_p5y_real#"$P5_ROOT_REAL"}" ;;
            # resolved clean out of the test root: outside by any reading
            *) return 1 ;;
        esac
    fi
    _p5y_full="${_p5y_real}/${_p5y_base}"
    p5_path_sane "$_p5y_full" || return 1
    p5_foreign "$_p5y_full" >/dev/null && return 1
    p5_ns_ok "$_p5y_role" "$_p5y_full" || return 1
    return 0
}

# p5_check_dest ROLE PATH [KIND] -> 0 if PATH may be written by the installer.
# One place, so install, the record and any later packaging check agree by
# construction. KIND defaults to `file`; pass `dir` to judge a directory.
#
# ORDER IS LOAD-BEARING. foreign is consulted BEFORE namespace, so widening the
# namespace to reclaim an old-stack path -- or a management-path file -- still
# refuses (bars IN-6b, MG-1). The inventory is consulted LAST, so its message is
# the one an operator sees when the path is in the right neighbourhood but was
# never declared.
p5_check_dest() {
    _p5c_role="$1"; _p5c_path="$2"; _p5c_kind="${3:-file}"
    p5_path_sane "$_p5c_path" || {
        p5_err "not a sane absolute destination: $_p5c_path"
        return 1
    }
    _p5c_f=$(p5_foreign "$_p5c_path") && {
        p5_err "destination belongs to a FOREIGN stack ($_p5c_f): $_p5c_path"
        return 1
    }
    p5_ns_ok "$_p5c_role" "$_p5c_path" || {
        p5_err "destination is outside the P5 namespace for role=$_p5c_role: $_p5c_path"
        return 1
    }
    p5_declared "$_p5c_role" "$_p5c_path" "$_p5c_kind" "install payload reserved" || {
        p5_err "destination is inside the namespace but is NOT DECLARED as an installable $_p5c_kind in the inventory ($P5_CONTRACT_PATHS): $_p5c_path"
        p5_err "declare it there, with an owner and a reason, or do not ship it. A path nobody declared is a path removal cannot know about."
        return 1
    }
    return 0
}

# p5_removable ROLE PATH KIND -> 0 if --remove may unlink/rmdir PATH.
#
# THE SECOND GATE, and the one that makes `rm -rf /usr/sbin` impossible rather
# than unlikely. The install-time record is data on disk: it can have been
# written by an older installer with the very bug this replaces, or edited by
# hand. So nothing in it is trusted. Every entry is re-validated against the
# SHIPPED contract before anything is unlinked, and one bad entry refuses the
# WHOLE removal.
#
# For a directory this admits ONLY `dir` rows -- the inventory has no row for
# /usr/sbin or /etc/init.d, and cannot acquire one without also acquiring an
# owner, a reason and NS-3 disjointness -- so a shared system directory can
# never be named by a removal plan.
#
# IT IS ALSO THE GATE THE CONTRACT-DERIVED ROWS GO THROUGH, which round 2 they
# did not: the contract's glob and runtime rows became UNLINK/RMTREE with no
# check at all while the RECORD was re-validated row by row. contract-paths on
# a box is a file on disk exactly like the record -- shipped, then editable --
# and a row does not have to be hostile to be lethal: a widened glob, a package
# template whose substituted variable was empty, or a perfectly correct row
# under a directory that has since become a symlink all reach the same rm.
# So there is now ONE gate, and everything destructive passes it.
#
# `/` is refused outright, ahead of everything else. It is lexically sane, it
# is a plausible `dir` row, and it is what an empty substitution collapses to.
p5_removable() {
    _p5rm_role="$1"; _p5rm_path="$2"; _p5rm_kind="$3"
    case "$_p5rm_path" in /|*/) return 1 ;; esac
    p5_path_sane "$_p5rm_path" || return 1
    p5_phys_ok "$_p5rm_role" "$_p5rm_path" || return 1
    p5_foreign "$_p5rm_path" >/dev/null && return 1
    p5_ns_ok "$_p5rm_role" "$_p5rm_path" || return 1
    if [ "$_p5rm_kind" = dir ]; then
        p5_declared "$_p5rm_role" "$_p5rm_path" dir "install runtime" || return 1
    else
        p5_declared "$_p5rm_role" "$_p5rm_path" file "install payload reserved transient runtime enable" || return 1
    fi
    return 0
}

# ---- stamp -----------------------------------------------------------------
# The stamp is KEY=value text. It is PARSED, never sourced: sourcing would
# execute whatever a corrupted or hostile stamp contained, and the whole point
# of the stamp is to be trusted when nothing else on the box is.

# p5_stamp_get KEY [FILE]
p5_stamp_get() {
    _p5s_file="${2:-$P5_STAMP}"
    [ -r "$_p5s_file" ] || return 1
    _p5s_line=$(grep "^$1=" "$_p5s_file" 2>/dev/null | head -1)
    [ -n "$_p5s_line" ] || return 1
    echo "${_p5s_line#*=}"
}

# ---- the box state machine -------------------------------------------------
# "Refuse to proceed when the box is not in a state the tool understands" is
# only enforceable if the states are enumerated. They are, here, once, and every
# entry point branches on this and nothing else.
#
#   clean       no P5 trace of any kind
#   installed   a stamp, no intent record left over: a run that finished
#   incomplete  an intent record is present: a run that STARTED and did not
#               finish. Distinct from `damaged` because the plan it carries is
#               exactly what is needed to undo it
#   damaged     P5 paths on the box, no stamp, no intent record. Something other
#               than this product's own tools put them there, or a pre-v3
#               installer crashed. Refuse and say so; do not guess a plan
#   future      the stamp declares a contract version this build does not
#               understand. Refuse everything destructive
#
# Sets P5_STATE and P5_STATE_WHY. Always returns 0: the CALLER decides which
# states it is willing to act on, and a state function that also carried a
# verdict would have to be re-read at every call site.
p5_box_state() {
    P5_STATE=clean; P5_STATE_WHY=""
    _p5b_role="${1:-both}"
    if [ -r "$P5_STAMP" ]; then
        _p5b_sv=$(p5_stamp_get P5_CONTRACT_VERSION || echo "")
        if [ -n "$_p5b_sv" ] && [ "$_p5b_sv" -gt "$P5_CONTRACT_VERSION" ] 2>/dev/null; then
            P5_STATE=future
            P5_STATE_WHY="stamp declares contract version $_p5b_sv; this build understands $P5_CONTRACT_VERSION"
            return 0
        fi
    fi
    if [ -e "$P5_INPROG_INSTALL" ]; then
        P5_STATE=incomplete
        P5_STATE_WHY="an install intent record is present ($(p5_unroot "$P5_INPROG_INSTALL")): an install started and did not finish"
        return 0
    fi
    if [ -e "$P5_INPROG_REMOVE" ]; then
        P5_STATE=incomplete
        P5_STATE_WHY="a removal intent record is present ($(p5_unroot "$P5_INPROG_REMOVE")): a removal started and did not finish"
        return 0
    fi
    if [ -r "$P5_STAMP" ]; then
        P5_STATE=installed
        P5_STATE_WHY="stamp present at $(p5_unroot "$P5_STAMP")"
        return 0
    fi
    # NOT `grep -c . || echo 0`. grep exits 1 on a ZERO count, so the fallback
    # ALSO runs, and the variable becomes two lines each holding 0 -- which is
    # neither empty nor equal to 0, so EVERY CLEAN BOX reported `damaged` and
    # refused to install. Caught by the battery on its first full run; worth the
    # comment because the idiom reads as obviously safe and is not.
    _p5b_traces=$(p5_present_paths "$_p5b_role" | grep -c . 2>/dev/null)
    [ -n "$_p5b_traces" ] || _p5b_traces=0
    if [ "$_p5b_traces" != 0 ]; then
        P5_STATE=damaged
        P5_STATE_WHY="$_p5b_traces declared P5 path(s) are present but there is no stamp and no intent record"
        return 0
    fi
    P5_STATE_WHY="no declared P5 path is present"
    return 0
}

# p5_installed -> 0 if a COMPLETED install is present. It is deliberately not
# `[ -r $P5_STAMP ]` any more: a stamp with an intent record beside it is a run
# that died between its last file write and its cleanup, and calling that
# "installed" is what let a crashed install look finished.
p5_installed() {
    p5_box_state "${1:-both}"
    [ "$P5_STATE" = installed ]
}

# p5_present_paths ROLE -> every DECLARED path that currently exists, one per
# line as `kind|state|path`. THE clean predicate, and the answer to B3.
#
# It probes every non-staging row in contract/paths, so it cannot check 4 of 12:
# adding a row to the inventory extends it with no code change. The previous
# form was a hand-written list of four locations, and a root carrying seven
# other declared paths reported CLEAN.
#
# uci rows: a UCI object is not a filesystem path, so $P5_ROOT cannot relocate
# it. Under a test root it cannot be probed at all -- the harness has no uci,
# and probing the developer machine's uci would be a lie -- so it is reported
# separately by p5_unprobed_paths and the caller says so out loud. On a real box
# (P5_ROOT empty) a missing `uci` binary counts the object as PRESENT: fail
# closed, because "we could not tell" must never read as "it is gone".
p5_present_paths() {
    _p5pp_role="${1:-both}"
    p5_rows "$_p5pp_role" "dir file glob uci" \
            "install payload reserved transient runtime enable uci" | \
    while IFS='|' read -r _p5pp_k _p5pp_s _p5pp_p; do
        case "$_p5pp_k" in
            dir)  [ -d "${P5_ROOT}${_p5pp_p}" ] && echo "$_p5pp_k|$_p5pp_s|$_p5pp_p" ;;
            file) { [ -e "${P5_ROOT}${_p5pp_p}" ] || [ -L "${P5_ROOT}${_p5pp_p}" ]; } && echo "$_p5pp_k|$_p5pp_s|$_p5pp_p" ;;
            glob) for _p5pp_h in $(p5_glob_hits "$_p5pp_p"); do echo "$_p5pp_k|$_p5pp_s|$_p5pp_h"; done ;;
            uci)
                if [ -n "$P5_ROOT" ]; then
                    :
                elif ! command -v uci >/dev/null 2>&1; then
                    echo "$_p5pp_k|$_p5pp_s|$_p5pp_p"
                elif uci -q get "$_p5pp_p" >/dev/null 2>&1; then
                    echo "$_p5pp_k|$_p5pp_s|$_p5pp_p"
                fi
                ;;
        esac
    done
    return 0
}

# p5_unprobed_paths ROLE -> every declared row this run could NOT decide about.
# Today that is exactly the uci rows under a test root. It is printed by
# --check so a green verdict always carries the size of its own blind spot,
# rather than the blind spot being invisible.
p5_unprobed_paths() {
    [ -n "$P5_ROOT" ] || return 0
    p5_rows "${1:-both}" uci uci
    return 0
}

# ---- installed-file record -------------------------------------------------
# sha256sum output format ("<hash>  <path>") on PRODUCTION paths, so a human or
# a later tool can read it with the box's own sha256sum. Verification is done
# by our own loop rather than `sha256sum -c` because under test the recorded
# production paths must be re-rooted; one loop, one behaviour, no divergence
# between the tested path and the shipped one. That loop is also what lets the
# record carry the one self-referential row (see P5_SELFREF).

# p5_verify_files -> 0 if every recorded file is present and matches
p5_verify_files() {
    [ -r "$P5_FILEREC" ] || { p5_err "no installed-file record at $P5_FILEREC"; return 1; }
    _p5v_bad=0; _p5v_n=0; _p5v_self=0
    while read -r _p5v_want _p5v_path; do
        case "$_p5v_want" in ''|\#*) continue ;; esac
        [ -n "$_p5v_path" ] || continue
        _p5v_n=$((_p5v_n + 1))
        _p5v_full="${P5_ROOT}${_p5v_path}"
        if [ ! -f "$_p5v_full" ]; then
            echo "MISSING  $_p5v_path"; _p5v_bad=$((_p5v_bad + 1)); continue
        fi
        if [ "$_p5v_want" = "$P5_SELFREF" ]; then
            # Present, and that is the whole claim. A file cannot carry its own
            # hash; saying so is honest, omitting the row is what wedges the box.
            _p5v_self=$((_p5v_self + 1))
            echo "SELFREF  $_p5v_path (present; hash not verifiable by construction)"
            continue
        fi
        _p5v_got=$(p5_hash "$_p5v_full")
        if [ "$_p5v_got" != "$_p5v_want" ]; then
            echo "CHANGED  $_p5v_path"; _p5v_bad=$((_p5v_bad + 1))
        fi
    done < "$P5_FILEREC"
    echo "$P5_TAG: verified $_p5v_n recorded files, $_p5v_self self-referential, $_p5v_bad bad"
    [ "$_p5v_bad" = 0 ]
}

# ---- deadman ---------------------------------------------------------------
# The armed-record directory is on persistent storage, so `is a rollback owed?`
# survives a reboot. p5-deadman owns the verbs; these two live here because
# p5-uninstall needs them and must not have to parse the record format itself.

# p5_deadman_armed -> prints each armed record path; returns 0 if any are armed.
p5_deadman_armed() {
    _p5da_n=0
    [ -d "$P5_DEADDIR" ] || return 1
    for _p5da_f in "$P5_DEADDIR"/*; do
        [ -f "$_p5da_f" ] || continue
        case "${_p5da_f##*/}" in "$P5_INCOMING".*) continue ;; esac
        echo "$_p5da_f"; _p5da_n=$((_p5da_n + 1))
    done
    [ "$_p5da_n" != 0 ]
}

# p5_deadman_field KEY FILE
p5_deadman_field() {
    _p5df_l=$(grep "^$1=" "$2" 2>/dev/null | head -1)
    [ -n "$_p5df_l" ] || return 1
    echo "${_p5df_l#*=}"
}
