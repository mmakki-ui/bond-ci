# deploy/p5/portal/lib/portal-lib.sh — M9 portal library. BUSYBOX-SAFE POSIX sh.
# Sourced by deploy/p5/portal/cgi/p5-portal. Contains every guard; the CGI itself
# is control flow only, so the whole attack surface is readable in one file.
#
# THE CONTRACT (m9-portal-design.md §1, bond-xctl:161):
#   "the caller writes facts, reconcile() derives the ONE edge"
# The portal is a CALLER. It writes facts and calls reconcile. It never picks an
# edge, never runs a feeder, never touches wg/uci-write/sqm/iptables, and never
# invokes an init script's start/stop/restart. Enforced by bars PC-2 (static) and
# PC-5 (runtime ledger), not by this comment.
#
# THE ONE STRUCTURAL RULE THAT KILLS MOST OF THE INJECTION SURFACE:
#   NO REQUEST BYTE IS EVER WRITTEN OR EXECUTED.
# A request value is only ever COMPARED against a catalogue literal; on a match
# it is DISCARDED and the CATALOGUE'S OWN literal is what gets written or passed
# on. So a value cannot carry a newline, a quote, a metacharacter or a traversal
# into a fact file or a command line even if every other check were removed --
# there is no data path from the request bytes to the effect. (The numeric field
# is the one exception and is handled by p5_uint, which re-emits the canonical
# decimal it parsed, not the input.)
#
# FORK DISCIPLINE. Everything below that CAN be done with shell builtins IS. A
# CGI on a busybox router pays for every process, and this one is also the
# Layer-2 harness's inner loop: the first cut spawned ~40 awks per state reply
# and a single reply took seconds. Only four things fork here, and each is a real
# external the portal genuinely has to ask: bondctl, bond-xctl, uci, ubus (plus
# one awk to decode the request).

# ---- configuration (all overridable so the harness can shim every external) ---
P5_PORTAL_DIR="${P5_PORTAL_DIR:-/usr/lib/p5/portal}"
P5_CAT_DIR="${P5_CAT_DIR:-$P5_PORTAL_DIR/catalogue}"
# THE THREE DEFAULTS BELOW NAME P5'S OWN INSTALLED PATHS, NOT THE OLD STACK'S
# (U220). Until this unit they named the P3 fact directory and the P3/P4 CLIs --
# three rows of p5/contract/foreign, one of which (the P2/P3 controller under
# /usr/sbin) EXISTS on the client and is engarde's. uhttpd passes this CGI NO
# environment; the init script's command line is the whole of it. So these
# defaults ARE what runs on the box, and shipped as they were, every mode or
# lifecycle click would have driven the OLD stack alongside an engaged P5. No bar
# saw it because the harness exported all three over the top of them.
#   BOND_DIR  -- what every P5 owner defaults to: deploy/p5/bond-xctl:37
#                `BOND_DIR`, bondctl:22, bond-ecod:31, bond-watchdog:20.
#   BONDCTL   -- p5/payload/filemap:92  755|client|deploy/p5/bondctl|/usr/sbin/p5
#   XCTL      -- p5/payload/filemap:93  755|client|deploy/p5/bond-xctl|/usr/sbin/p5-reconciler
#                (bondctl:24 and bond-watchdog:22 already default to it.)
# Bars ROOT-1..3 in the portal harness COMPARE these three against those sources
# rather than restating them; ROOT-4 asserts the old root is gone from here.
BOND_DIR="${BOND_DIR:-/etc/p5}"
P5_STATE_DIR="${P5_STATE_DIR:-/etc/p5/portal}"
BONDCTL="${BONDCTL:-/usr/sbin/p5}"
XCTL="${XCTL:-/usr/sbin/p5-reconciler}"
UCI="${UCI:-/sbin/uci}"
UBUS="${UBUS:-/bin/ubus}"
# The syslog ring reader -- the ONE external the log route runs (U223). It is a
# READ: logread prints logd's buffer and does not clear it. Absolute like the
# four above and for the same reason: uhttpd passes this CGI no environment, so
# a bare name would resolve against whatever PATH the CGI inherits (which is
# itself unmeasured, which is why q=state reports it -- U220).
LOGREAD="${LOGREAD:-/sbin/logread}"
P5_MAX_BODY="${P5_MAX_BODY:-2048}"      # bytes; a larger request is 413
P5_MAX_VALUE="${P5_MAX_VALUE:-128}"     # bytes per decoded value; larger is 400
P5_MAX_EMIT="${P5_MAX_EMIT:-4096}"      # chars per emitted JSON string

# ---- the runner's world (U228) ----------------------------------------------
# The CGI STARTS a job and then answers; the job itself is p5-portal-run, which
# sources this same file, so both halves resolve these from ONE place.
#
# RESULTS ARE NOT UNDER www/ AND ARE NOT ON tmpfs, and both halves of that are
# deliberate. uhttpd serves the docroot statically (`-h $DOCROOT`,
# init.d/p5-portal:74), so an artifact under www/ would be readable WITHOUT the
# session check this file's p5_auth_ok performs -- the results are served only
# by the CGI, behind that check. And they live on the overlay, not in /var/run:
# evidence of what a test did is the thing this project has now lost to a temp
# directory twice (m9-portal-design.md, "artifacts"), so it survives a reboot.
# The directory is created ON THE BOX by the CGI/runner and is never installed
# (p5/contract/paths declares it state=runtime, the /etc/init.d/p5-shape
# precedent).
P5_RESULTS_DIR="${P5_RESULTS_DIR:-$P5_PORTAL_DIR/results}"
# The job lock IS on tmpfs, for the opposite reason: it must NOT survive a
# reboot. A lock is a statement about a running process, and after a power cut
# there is none -- the same reasoning xctl-lock.sh:51 applies to the reconciler's
# own lock. `mkdir` is the atomic take; the pid file inside decides staleness.
P5_JOB_LOCK="${P5_JOB_LOCK:-/var/run/p5/portal.job}"
P5_RUNNER="${P5_RUNNER:-$P5_PORTAL_DIR/bin/p5-portal-run}"
P5_RESTORE="${P5_RESTORE:-$P5_PORTAL_DIR/bin/p5-portal-restore}"
# The tools a test HEAD resolves to. Both are filemap destinations, never bare
# names: p5/payload/filemap:137 (deploy/p5/bond-accept -> /usr/sbin/p5-accept)
# and :145's contract row for the deadman.
P5_ACCEPT="${P5_ACCEPT:-/usr/sbin/p5-accept}"
P5_DEADMAN="${P5_DEADMAN:-/usr/sbin/p5-deadman}"
# The shared library, for p5_hash ONLY (SH-19: this product has one sha256
# implementation and one place that validates the tool, p5/lib/p5-common.sh:357
# and its test vector at :350). The runner sources it; the CGI does not.
P5_COMMON="${P5_COMMON:-/usr/lib/p5/p5-common.sh}"
# /proc, as a variable so a bar can point a mutant at a fixture. Liveness here is
# a READ of /proc/<pid>, never `kill -0`: PC-2 forbids the token `kill ` in the
# CGI and this library, because a kill from a CGI is a raw side effect (design
# §3b, "no stop/kill verb in the portal"). The one process this product may kill
# is the job's own group, from the restore script, off the pid in its record.
P5_PROC="${P5_PROC:-/proc}"
P5_UPTIME="${P5_UPTIME:-$P5_PROC/uptime}"
# OpenWrt's own published identity for the box, read-only. Same path
# deploy/p5/shape-install:248 and p5-client-preflight.sh:46 already read; it is
# a READ of a vendor fact, not scratch, and it is declared HERE rather than in
# bin/p5-portal-run so bar RUN-6 ("no /tmp path in the runner or the restore
# script") stays a statement about the two executables that touch the box.
P5_SYSINFO_MODEL="${P5_SYSINFO_MODEL:-/tmp/sysinfo/model}"
P5_STAMP_FILE="${P5_STAMP_FILE:-/usr/lib/p5/stamp}"
# HARNESS-ONLY OVERRIDE, and the only one in this file. The portal harness's
# `sleep` is a no-op shim (orchestration/ecosim/p5/bin/sleep:3), so a deadman
# armed the normal way fires its timer at t=0 -- which is exactly the mid-run
# kill bar RUN-8 wants, and exactly what makes the SUCCESS path untestable. Set
# to 0, the runner passes p5-deadman's own `--no-timer` through so the success
# path can be run to its confirm (RUN-12). Default 1 = a real timer; bar RUN-11
# asserts the DEFAULT arm argv carries no --no-timer, so this cannot rot into
# "the product ships without a timer".
P5_PORTAL_DM_TIMER="${P5_PORTAL_DM_TIMER:-1}"

P5_NL='
'
P5_CR=$(printf '\r')
P5_TAB=$(printf '\t')
P5_BS='\'

# ============================ output =========================================
p5_hdr() {   # $1 = status line
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Content-Security-Policy: default-src '\''none'\''\r\n'
    printf '\r\n'
}

# p5_hdr_text: the SAME header set with a text/plain type, for the routes whose
# body is not JSON -- the log tail (U223) and the result artifact (U228). ONE
# header builder shared by both, BY FUNCTION NAME, which is the merge the U228
# ROADMAP row asks for ("p5_hdr_text if U223 has not landed -- MERGE by function
# name"), so a route cannot ship with a weaker set than its neighbour. Its own
# function rather than a parameter on p5_hdr, so "this route emits text" is a
# visible fork in the source and LOG-6 / RUN-1l can assert the set per route.
#
# $2 IS OPTIONAL, and it is the ONLY difference between the two routes. Given, it
# is the filename the browser should offer: `inline`, not `attachment` -- the
# operator reads the artifact in the tab, and the CSP + nosniff pair is what keeps
# a result file that happens to contain markup from being rendered as any of it
# (the design names this header for q=result and for nothing else,
# docs/knowledge/design/p5-portal-plan.md:153). The log tail passes none: it is a
# live tail of the box's ring, not a stored artifact, and there is no id to name.
# `${2:-}` and not `$2` because the CGI runs under `set -u`
# (deploy/p5/portal/cgi/p5-portal:47), where a one-argument call would abort
# inside this function instead of answering.
#
# WHY THE LOG TAIL IS NOT JSON. The ring's lines are not the portal's text: a
# line can be any length, carry any byte the box's own daemons emitted, and there
# can be thousands of them. Putting the ring through p5_json_str would run its
# per-character shell loop over every one and then TRUNCATE at P5_MAX_EMIT --
# both the fork cost this file's FORK DISCIPLINE note exists to avoid and a
# silent loss of the lines you went looking for. So the body is STREAMED: never
# captured into a variable, never escaped, never truncated by us. That is safe
# precisely BECAUSE it is text/plain -- nosniff plus `default-src 'none'` means a
# browser must not parse it as markup, so a ring line carrying a script tag is
# bytes and not a tag (bar LOG-7). The page reads it with .textContent into a
# <pre>, which is the second layer, exactly as it is for the JSON routes.
p5_hdr_text() {   # $1 = status line, $2 = OPTIONAL filename to offer inline
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: text/plain; charset=utf-8\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Content-Security-Policy: default-src '\''none'\''\r\n'
    if [ -n "${2:-}" ]; then
        printf 'Content-Disposition: inline; filename=%s\r\n' "$2"
    fi
    printf '\r\n'
}

# p5_json_str: emit $1 as a JSON string, escaped. GUARD FOR INJECTION SURFACE
# INJ-2 (HTML/JS). The values reaching here include FACT FILE CONTENTS and PROBE
# OUTPUT -- neither of which the portal controls. A hand-edited fact file, or a
# label the box returns over ubus, can carry a quote, a backslash, a newline or
# the bytes `</script>`; unescaped they break out of the JSON string and become
# markup in the page. `<` `>` `&` are escaped as well as the JSON-mandatory pair,
# so the body stays inert even if a browser is coaxed into parsing it as HTML.
#
# NAMED LIMIT: C0 characters other than LF/CR/TAB are passed through rather than
# \u-escaped (doing it in-shell costs a fork per value, which this file exists to
# avoid). They are not an XSS vector -- every character that could terminate a
# string or open a tag IS escaped -- but such a byte would make the body
# technically invalid JSON. The write path cannot produce one: p5_decode_kv
# refuses control characters outright. The residual case is probe/ubus output.
p5_json_str() {
    _s=$1; _o=''; _n=0
    while [ -n "$_s" ]; do
        _n=$((_n+1))
        if [ "$_n" -gt "$P5_MAX_EMIT" ]; then _o="$_o ...[truncated]"; break; fi
        _c=${_s%"${_s#?}"}; _s=${_s#?}
        if   [ "$_c" = '"' ];       then _o="$_o\\\""
        elif [ "$_c" = "$P5_BS" ];  then _o="$_o\\\\"
        elif [ "$_c" = '<' ];       then _o="$_o\\u003c"
        elif [ "$_c" = '>' ];       then _o="$_o\\u003e"
        elif [ "$_c" = '&' ];       then _o="$_o\\u0026"
        elif [ "$_c" = "$P5_NL" ];  then _o="$_o\\n"
        elif [ "$_c" = "$P5_CR" ];  then _o="$_o\\r"
        elif [ "$_c" = "$P5_TAB" ]; then _o="$_o\\t"
        else _o="$_o$_c"
        fi
    done
    printf '"%s"' "$_o"
}

p5_die() {   # $1 = status line, $2 = machine-readable reason
    p5_hdr "$1"
    printf '{"ok":false,"error":'
    p5_json_str "$2"
    printf '}\n'
    exit 0
}

# ============================ request parsing =================================
# p5_decode_kv: stdin = raw application/x-www-form-urlencoded; stdout = one
# "KEY<TAB>VALUE" line per pair.
#
# GUARD FOR INJECTION SURFACE INJ-4 (config file). Percent-decoding happens
# BEFORE any whitelist runs, so `%0A` cannot smuggle a newline past a check that
# only ever sees the encoded form. A decoded key or value carrying a control
# character (newline, tab, CR, ...) is REFUSED here rather than silently
# stripped: stripping would turn `lightning%0Aspeed` into `lightningspeed` and
# hide the attempt, and a fact file is line-structured, so a newline inside a
# value is a second fact.
p5_decode_kv() {
    awk '
      function hexv(c,   p) { p = index("0123456789abcdef", tolower(c)); return p - 1 }
      function dec(s,   o, i, c, h1, h2, L) {
        o = ""; i = 1; L = length(s)
        while (i <= L) {
          c = substr(s, i, 1)
          if (c == "+") { o = o " "; i++; continue }
          if (c == "%" && i + 2 <= L) {
            h1 = hexv(substr(s, i+1, 1)); h2 = hexv(substr(s, i+2, 1))
            if (h1 >= 0 && h2 >= 0) { o = o sprintf("%c", h1 * 16 + h2); i += 3; continue }
          }
          o = o c; i++
        }
        return o
      }
      function ctl(s) { return (s ~ /[[:cntrl:]]/) }
      { buf = buf (NR > 1 ? "\n" : "") $0 }
      END {
        n = split(buf, P, "&")
        for (j = 1; j <= n; j++) {
          if (P[j] == "") continue
          e = index(P[j], "=")
          if (e == 0) { print "__P5_REJECT__\tmalformed_pair"; exit }
          k = dec(substr(P[j], 1, e - 1)); v = dec(substr(P[j], e + 1))
          if (ctl(k) || ctl(v)) { print "__P5_REJECT__\tcontrol_char"; exit }
          if (length(v) > MAXV) { print "__P5_REJECT__\tvalue_too_long"; exit }
          printf "%s\t%s\n", k, v
        }
      }' MAXV="$P5_MAX_VALUE"
}

p5_read_request() {   # sets P5_KV
    case "${REQUEST_METHOD:-GET}" in
      GET)  _raw="${QUERY_STRING:-}" ;;
      POST)
        _len="${CONTENT_LENGTH:-0}"
        case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
        [ "$_len" -gt "$P5_MAX_BODY" ] && p5_die "413 Payload Too Large" too_large
        # bs=1 count=N, not bs=N count=1: a single read() can come up short when
        # the body spans TCP segments, and a truncated body would be silently
        # parsed as a shorter request rather than refused. N is bounded by
        # P5_MAX_BODY above, so the syscall count is bounded too.
        if [ "$_len" -gt 0 ]; then _raw=$(dd bs=1 count="$_len" 2>/dev/null); else _raw=''; fi
        ;;
      *) p5_die "405 Method Not Allowed" method ;;
    esac
    P5_KV=$(printf '%s' "$_raw" | p5_decode_kv)
    case "$P5_KV" in
      __P5_REJECT__*)
        _r=${P5_KV#*"$P5_TAB"}; _r=${_r%%"$P5_NL"*}
        p5_die "400 Bad Request" "$_r" ;;
    esac
}

p5_arg() {   # $1 = key -> stdout value ('' when absent). No fork.
    _rest=$P5_KV
    while [ -n "$_rest" ]; do
        _line=${_rest%%"$P5_NL"*}
        if [ "$_line" = "$_rest" ]; then _rest=''; else _rest=${_rest#*"$P5_NL"}; fi
        [ -n "$_line" ] || continue
        _lk=${_line%%"$P5_TAB"*}
        [ "$_lk" = "$1" ] || continue
        printf '%s' "${_line#*"$P5_TAB"}"
        return 0
    done
    return 0
}

# ============================ the whitelist ==================================
# p5_match_literal: $1 = space-separated catalogue literals, $2 = candidate.
# On an EXACT match it echoes the CATALOGUE'S copy of the literal and returns 0;
# otherwise it returns 1 and echoes nothing.
#
# THE GUARD FOR INJECTION SURFACE INJ-1 (shell). Callers use the RETURNED string,
# never their own input, so the bytes that reach `bondctl mode <v>` or a fact
# file provably originate in a file that ships with the package. A value like
# `eco;reboot` or `$(id)` or `eco lightning` matches nothing, is a 400, and is
# never interpolated anywhere -- the request bytes are dropped on the floor.
p5_match_literal() {
    _cand="$2"
    for _lit in $1; do
        [ "$_lit" = "$_cand" ] && { printf '%s' "$_lit"; return 0; }
    done
    return 1
}

# p5_key_sane: a catalogue KEY (used to build a fact path) must be a bare
# lowercase identifier. GUARD FOR INJECTION SURFACE INJ-3 (URL/path): this is
# what stops `../../etc/dropbear/authorized_keys` from becoming "$BOND_DIR/$key".
# Applied to the CATALOGUE'S key as well as the request's, so a corrupted
# catalogue cannot aim a write outside BOND_DIR either.
p5_key_sane() {
    case "$1" in
      ''|*[!a-z0-9_]*) return 1 ;;
      [!a-z]*)         return 1 ;;
      *)               return 0 ;;
    esac
}

# p5_uint: accept a decimal integer and echo its CANONICAL form. The one place a
# request-derived value survives -- so it is re-emitted from a parse, never
# passed through. Rejects the empty string, a sign, and any non-digit.
p5_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    _u=$1
    while [ "${#_u}" -gt 1 ] && [ "${_u#0}" != "$_u" ]; do _u=${_u#0}; done
    printf '%s' "$_u"
}

# p5_readfile: first line of $1, or ''. Builtin redirect, no fork.
p5_readfile() {
    _fl=''
    [ -r "$1" ] || { printf ''; return 0; }
    IFS= read -r _fl < "$1" 2>/dev/null
    printf '%s' "${_fl:-}"
}

# ============================ catalogue readers ==============================
# All fork-free: each walks its file with the read builtin. Comment lines start
# at column 0 with '#'.
p5_cat_field() {   # $1=file $2=key $3=column(2..6)
    # COLUMN 6 IS READ EXPLICITLY, not left to the last variable (U227). The
    # fields catalogue gained an OPTIONAL sixth column (`impl`), and with a
    # five-variable read the sixth column would be swallowed INTO the label:
    # every consumer of column 5 would start returning "<label>|balanced" and
    # the page would print it. An absent column 6 reads as the empty string,
    # which is what "no restriction, every literal is implemented" means.
    _cf="$P5_CAT_DIR/$1"; [ -r "$_cf" ] || return 0
    while IFS='|' read -r _c1 _c2 _c3 _c4 _c5 _c6 || [ -n "${_c1:-}" ]; do
        case "${_c1:-}" in ''|'#'*) continue ;; esac
        [ "$_c1" = "$2" ] || continue
        case "$3" in
          2) printf '%s' "${_c2:-}" ;;
          3) printf '%s' "${_c3:-}" ;;
          4) printf '%s' "${_c4:-}" ;;
          5) printf '%s' "${_c5:-}" ;;
          6) printf '%s' "${_c6:-}" ;;
        esac
        return 0
    done < "$_cf"
    return 0
}

p5_cat_keys() {    # $1=file -> "k1 k2 k3 "
    _cf="$P5_CAT_DIR/$1"; [ -r "$_cf" ] || return 0
    while IFS='|' read -r _c1 _rest2 || [ -n "${_c1:-}" ]; do
        case "${_c1:-}" in ''|'#'*) continue ;; esac
        printf '%s ' "$_c1"
    done < "$_cf"
}

# ============================ the log catalogue ==============================
# catalogue/logs is `name|regex|label`, and it is the ONE catalogue whose payload
# may legitimately contain the field separator: the datapath row's pattern is an
# ERE alternation, because the procd ident for the Go daemon has never been read
# on a box and the row has to match either spelling. p5_cat_field would hand back
# the text up to the FIRST `|` and silently truncate that pattern to something
# that still compiles and matches the wrong thing -- the worst kind of failure
# for a debugging surface. So the split here is at the LAST `|` instead:
#   column 2 = everything between the first and the last  -> the ERE
#   column 3 = everything after the last                  -> the label
# CONSEQUENCE, STATED IN THE CATALOGUE'S OWN HEADER: a label must not contain
# `|`. Bars LOG-1j/k round-trip the datapath row through this reader.
p5_log_row() {   # $1 = name, $2 = re|label -> stdout; rc 1 if no such row
    _lf="$P5_CAT_DIR/logs"; [ -r "$_lf" ] || return 1
    while IFS='|' read -r _l1 _lrest || [ -n "${_l1:-}" ]; do
        case "${_l1:-}" in ''|'#'*) continue ;; esac
        [ "$_l1" = "$1" ] || continue
        case "${_lrest:-}" in *'|'*) ;; *) return 1 ;; esac   # no label column
        case "$2" in
          re)    printf '%s' "${_lrest%|*}" ;;
          label) printf '%s' "${_lrest##*|}" ;;
        esac
        return 0
    done < "$_lf"
    return 1
}

# p5_regex_sane: the charset check every catalogue ERE passes before it is handed
# to grep. GUARD FOR THE LOG ROUTE'S ONE REMAINING SURFACE: the pattern is the
# only thing on that command line that is not a fixed string, and it comes from
# a shipped file -- so this is not defending against the request (no request byte
# reaches it; the request supplies a NAME that must match a row) but against a
# CORRUPTED OR MISEDITED CATALOGUE, the same reason p5_key_sane is applied to the
# catalogue's own key. Allowed: alphanumerics, `_ | ( ) [ ] : . space \ -`.
#
# WHAT THE SET EXCLUDES IS THE POINT. No `/` -- a row cannot name a path. No
# `* ? + { }` -- a row cannot build a catastrophic backtracker out of nested
# quantifiers on a ring that may hold thousands of lines. No `$ ^` -- and none of
# `; & > < ' " $( ` -- so even if a caller ever interpolated one of these
# patterns instead of passing it as an argument, there is nothing in it to
# interpolate. A row that fails is a 500 naming the row, never a dropped source.
#
# Written as a per-character loop rather than one `case` with a bracket
# expression on purpose: a bracket expression containing `]`, `-`, `[` and `\`
# has four separate ordering rules, and this file has to be right under busybox
# ash as well as bash. Each punctuation character below is QUOTED, so it is a
# literal in the pattern and not glob syntax. Fork-free; the patterns are short
# and this runs once per request.
p5_regex_sane() {
    _rs=$1
    [ -n "$_rs" ] || return 1
    while [ -n "$_rs" ]; do
        _rc=${_rs%"${_rs#?}"}; _rs=${_rs#?}
        case "$_rc" in
          [0-9]|[A-Z]|[a-z]) ;;
          '_'|'|'|'('|')'|'['|']'|':'|'.'|' '|'-'|'\') ;;
          *) return 1 ;;
        esac
    done
    return 0
}

p5_modes_all() {
    _cf="$P5_CAT_DIR/modes"; [ -r "$_cf" ] || return 0
    while IFS='|' read -r _c1 _c2 _c3 _c4 || [ -n "${_c1:-}" ]; do
        case "${_c1:-}" in ''|'#'*) continue ;; esac
        printf '%s ' "$_c1"
    done < "$_cf"
}

p5_modes_impl() {
    _cf="$P5_CAT_DIR/modes"; [ -r "$_cf" ] || return 0
    while IFS='|' read -r _c1 _c2 _c3 _c4 || [ -n "${_c1:-}" ]; do
        case "${_c1:-}" in ''|'#'*) continue ;; esac
        [ "${_c3:-}" = implemented ] || continue
        printf '%s ' "$_c1"
    done < "$_cf"
}

# ============================ the runner (U228) ==============================
# THE ONE REQUEST-DERIVED TOKEN THAT REACHES A PATH IS A MATCHED LISTING ENTRY.
# An artifact id is built HERE, from the clock and the catalogue's own name, and
# it is served only after p5_match_literal has matched it against the directory
# listing (the INJ-3 rule this file already applies to a fact key). So `../port`
# is not "sanitised" -- it is compared against a set it is not in, and dropped.

# p5_run_id_sane: `<epoch>-<uptime>-<name>`, i.e. ^[0-9]+-[0-9]+-[a-z][a-z0-9_]*$
# written as case patterns because that is what busybox ash has. Used by the
# runner (defence in depth on its own argv) and by the results routes.
p5_run_id_sane() {
    case "$1" in *[!a-z0-9_-]*) return 1 ;; esac
    _ri_e=${1%%-*};  _ri_r=${1#*-}
    [ "$_ri_e" != "$1" ]    || return 1
    _ri_u=${_ri_r%%-*}; _ri_n=${_ri_r#*-}
    [ "$_ri_u" != "$_ri_r" ] || return 1
    case "$_ri_e" in ''|*[!0-9]*) return 1 ;; esac
    case "$_ri_u" in ''|*[!0-9]*) return 1 ;; esac
    case "$_ri_n" in ''|[!a-z]*|*[!a-z0-9_]*) return 1 ;; esac
    return 0
}

# p5_run_id NAME -> `<epoch>-<uptime>-<name>`.
#
# BOTH HALVES OF THE CLOCK, because neither one is enough on these boxes. The
# epoch is bogus before NTP has run (xctl-lock.sh:51 says so about the same
# hardware), and the uptime restarts at every boot -- but the PAIR sorts
# correctly within a boot and carries a wall-clock stamp when there is one.
#
# THE UPTIME IS IN CENTISECONDS, not seconds, and that is not a tuning number:
# /proc/uptime publishes exactly two decimals, and with whole seconds two runs of
# the same test inside one second resolve to ONE id and the second silently
# overwrites the first artifact. This product has no delete verb and no rotation,
# so a silently overwritten result is unrecoverable; using the digits the kernel
# already prints costs nothing and removes the case.
p5_run_id() {   # $1 = the catalogue's own name
    _rid_e=$(date -u '+%s' 2>/dev/null || echo 0)
    case "$_rid_e" in ''|*[!0-9]*) _rid_e=0 ;; esac
    _rid_u=$(p5_readfile "$P5_UPTIME"); _rid_u=${_rid_u%% *}
    _rid_s=${_rid_u%%.*}; _rid_f=${_rid_u#*.}
    case "$_rid_s" in ''|*[!0-9]*) _rid_s=0 ;; esac
    case "$_rid_f" in ''|*[!0-9]*) _rid_f=00 ;; esac
    printf '%s-%s%s-%s' "$_rid_e" "$_rid_s" "$_rid_f" "$1"
}

# p5_detach RUNNER NAME ID: start the job so that it OUTLIVES this CGI.
#
# uhttpd holds the response until the CGI's stdout closes and kills the script at
# its own timeout (the default is upstream's and is UNVERIFIED on GL's build --
# init.d/p5-portal:74 sets no -t). A job that is minutes long therefore cannot be
# a child of the request. This is the SAME spawn p5-deadman:507-510 uses for its
# timer, for the same reason and with the same two properties:
#   - </dev/null AND >/dev/null on the spawn, so the child holds no descriptor of
#     the request's -- a child keeping stdout open makes the response hang, which
#     is the defect that hung this project's own test harness once already;
#   - the arguments are PASSED AS ARGUMENTS to `sh -c`, never interpolated into
#     its string. An install path with a space split into two words and killed
#     the deadman's timer silently (DM-30/DM-31); here it would also be the one
#     place a catalogue name could reach a command line.
# Sets P5_JOB_PID to the session leader's pid. setsid makes the job its OWN
# session and process group, which is what lets the restore script kill the whole
# job with one `kill -- -<pid>` and what stops uhttpd's kill of the CGI's group
# from taking the job with it (bar RUN-5).
p5_detach() {   # $1 = runner path, $2 = name, $3 = id
    if command -v setsid >/dev/null 2>&1; then
        setsid sh -c 'exec "$1" "$2" "$3"' _ "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
    else
        nohup sh -c 'exec "$1" "$2" "$3"' _ "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
    fi
    P5_JOB_PID=$!
    [ -n "$P5_JOB_PID" ]
}

# p5_job_alive PID -> 0 when that pid is a live process. A READ of /proc, not a
# signal: see P5_PROC above for why this file may not say `kill `.
p5_job_alive() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "$P5_PROC/$1" ]
}

# p5_job_take NAME ID -> 0 when WE hold the one job slot.
# `mkdir` is the take: it is atomic on every filesystem here, which is why the
# lock is a DIRECTORY and not a file test followed by a write. A lock whose
# holder is gone is STALE and is taken over -- a job that died (or a box that was
# power-cut, though tmpfs already handles that one) must not lock the runner out
# for ever. Only the three files this function wrote are removed; nothing here is
# recursive.
p5_job_take() {   # $1 = name, $2 = id
    _jt_par=${P5_JOB_LOCK%/*}
    [ -d "$_jt_par" ] || mkdir -p "$_jt_par" 2>/dev/null
    if mkdir "$P5_JOB_LOCK" 2>/dev/null; then
        p5_job_stamp "$1" "$2"; return 0
    fi
    # Taken. A lock with no readable pid is treated as LIVE, not stale: the
    # window between the take and the pid write is microseconds wide, and
    # refusing a second run is the safe direction.
    _jt_p=$(p5_readfile "$P5_JOB_LOCK/pid")
    [ -n "$_jt_p" ] || return 1
    p5_job_alive "$_jt_p" && return 1
    rm -f "$P5_JOB_LOCK/pid" "$P5_JOB_LOCK/name" "$P5_JOB_LOCK/id" 2>/dev/null
    p5_job_stamp "$1" "$2"; return 0
}

p5_job_stamp() {  # $1 = name, $2 = id
    printf '%s\n' "$1" > "$P5_JOB_LOCK/name" 2>/dev/null
    printf '%s\n' "$2" > "$P5_JOB_LOCK/id"   2>/dev/null
}

# p5_job_release ID: drop the lock, but ONLY if it is still ours. A runner that
# was declared stale and whose slot another job now holds must not delete that
# job's lock on its way out.
p5_job_release() {
    [ -d "$P5_JOB_LOCK" ] || return 0
    [ "$(p5_readfile "$P5_JOB_LOCK/id")" = "$1" ] || return 0
    rm -f "$P5_JOB_LOCK/pid" "$P5_JOB_LOCK/name" "$P5_JOB_LOCK/id" 2>/dev/null
    rmdir "$P5_JOB_LOCK" 2>/dev/null
    return 0
}

# p5_result_ids -> every artifact id on disk, one per line. ONE `ls` fork for the
# whole directory, and the id is taken from the NAME: `<id>.part` is a job that
# has not written its footer, `<id>.txt` is one that has. `.meta` is the runner's
# own record and is never listed or served.
p5_result_ids() {
    [ -d "$P5_RESULTS_DIR" ] || return 0
    for _rl_f in "$P5_RESULTS_DIR"/*.txt "$P5_RESULTS_DIR"/*.part; do
        [ -f "$_rl_f" ] || continue
        _rl_i=${_rl_f##*/}; _rl_i=${_rl_i%.*}
        p5_run_id_sane "$_rl_i" || continue
        printf '%s\n' "$_rl_i"
    done
}

# p5_result_path ID -> the file that carries that id's output, or nothing. The
# finished artifact wins over the in-progress one; a job that is still running is
# readable while it runs, which is the whole point of a detached runner.
p5_result_path() {
    if [ -f "$P5_RESULTS_DIR/$1.txt" ]; then printf '%s' "$P5_RESULTS_DIR/$1.txt"
    elif [ -f "$P5_RESULTS_DIR/$1.part" ]; then printf '%s' "$P5_RESULTS_DIR/$1.part"
    fi
}

# p5_space_ok NAME -> 1 (refuse) when the results filesystem could not hold
# another artifact the size of the LARGEST this test has already produced.
#
# NO CONSTANT, THREE WAYS: the size comes from this test's own history, the free
# space from df, and a test that has never run is never refused (there is nothing
# to derive a size from, and refusing the first run would be inventing one).
# `df` printing nothing -- no df, an unmounted path, a busybox that formats
# differently -- runs the job: absence of a measurement is not a refusal.
p5_space_ok() {   # $1 = name
    _sp_max=0
    for _sp_f in "$P5_RESULTS_DIR"/*-"$1".txt; do
        [ -f "$_sp_f" ] || continue
        _sp_b=$(wc -c < "$_sp_f" 2>/dev/null); _sp_b=${_sp_b# }
        case "$_sp_b" in ''|*[!0-9]*) continue ;; esac
        [ "$_sp_b" -gt "$_sp_max" ] && _sp_max=$_sp_b
    done
    [ "$_sp_max" -gt 0 ] || return 0
    _sp_free=$(df -k "$P5_RESULTS_DIR" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+$/ {print $4; exit}')
    case "$_sp_free" in ''|*[!0-9]*) return 0 ;; esac
    [ "$((_sp_free * 1024))" -ge "$_sp_max" ]
}

# ============================ authentication =================================
# WHAT IS ESTABLISHED, AND WHAT IS A HYPOTHESIS. Read this before trusting it.
#
# ESTABLISHED (observed on the client box, INTENT.md:134-137, from a `ps w`):
#   - uhttpd runs with CGI and ubus enabled:
#     `/usr/sbin/uhttpd -f -h /www -r GL-MT6000 -x /cgi-bin -u /ubus ...`
#   - a process named `gl-ngx-session` is running, and the vendor UI is nginx.
#
# HYPOTHESIS, NOT VERIFIED (m9-portal-design.md §4b calls this "the port-time
# check owed"; it has not been done):
#   - that `gl-session` keeps its sessions in rpcd's ubus `session` namespace, so
#     `ubus call session get {"ubus_rpc_session":"<sid>"}` answers for a session
#     minted by the vendor login and fails for anything else;
#   - that a CGI on a SEPARATE uhttpd instance can reach that namespace.
# The repo contains no evidence for either. Nothing in P5 has ever run on the
# box, and repo state is a hypothesis about box state -- so this label is what
# the project's own rule requires, not a hedge.
#
# WHY IT IS SAFE TO SHIP BEHIND ANYWAY: the check FAILS CLOSED. If the hypothesis
# is wrong -- namespace absent, ubus unreachable, sessions kept elsewhere -- every
# request is denied 403 and the portal is merely unusable. The failure mode is
# never "an unauthenticated caller writes a fact". There is no second credential
# store and no bypass: rolling our own would be the `cell` mistake in another
# costume (design §4b).
#
# ESTABLISHING GROUND TRUTH: scripts/box-inventory.sh gained a `### portal-auth`
# section in this unit. It is read-only, runs from the PC, and answers exactly
# the two questions above. Until it has run, this remains a hypothesis.

# CSRF: the session id must arrive in a header a browser does not attach on its
# own (HTTP_X_P5_SESSION) or in the request body. A cookie ALONE is never
# accepted, so a third-party page cannot drive this CGI with the operator's
# ambient session.
p5_session_id() {
    _s="${HTTP_X_P5_SESSION:-}"
    [ -n "$_s" ] || _s=$(p5_arg sid)
    printf '%s' "$_s"
}

# Strict shape check BEFORE the id is interpolated into the ubus JSON argument.
# That interpolation is itself an injection surface -- a crafted id could close
# the JSON string and add members -- and the hex check makes it unreachable.
p5_sid_sane() {
    case "$1" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
    [ "${#1}" -eq 32 ]
}

p5_auth_ok() {
    _sid=$(p5_session_id)
    p5_sid_sane "$_sid" || return 1
    _r=$("$UBUS" call session get "{\"ubus_rpc_session\":\"$_sid\"}" 2>/dev/null) || return 1
    [ -n "$_r" ] || return 1
    case "$_r" in
      *'"values"'*|*'"username"'*|*'"acls"'*) return 0 ;;
      *) return 1 ;;
    esac
}

# ============================ the mode PAIR ==================================
# m9-portal-design.md §2 / ADR-003 rule 5. `$BOND_DIR/mode` alone is NOT the
# user's choice: with `auto` set it is bond-ecod's CURRENT POSITION. Derived
# SERVER-SIDE and emitted as two distinct fields, so the page cannot conflate
# them and the bar can test it without a browser.
#
#   auto set   -> intent = eco     position = <mode>   (eco|lightning)
#   auto unset -> intent = <mode>  position = ""       (no position row)
p5_raw_mode() { p5_readfile "$BOND_DIR/mode"; }
p5_intent()   { if [ -f "$BOND_DIR/auto" ]; then echo eco; else p5_raw_mode; fi; }
p5_position() { if [ -f "$BOND_DIR/auto" ]; then p5_raw_mode; else printf ''; fi; }

# ADR-003 rule 4: turning auto off leaves `mode` at whatever position ecod had
# escalated to -- a pin the user never chose. The ADR forbids doing that
# silently, so selecting a manual mode while auto is set must carry
# `confirm=<the pin>`. Returns the pin needing confirmation, or nothing.
p5_pin_needing_confirm() {   # $1 = the mode being selected
    [ -f "$BOND_DIR/auto" ] || return 0        # auto already off: nothing implicit
    [ "$1" = eco ] && return 0                 # staying in eco: nothing implicit
    [ "$1" = direct ] && return 0              # lifecycle off: the mode fact is untouched
    _pos=$(p5_raw_mode)
    [ "$_pos" = "$1" ] && return 0             # pinning exactly where it already is
    printf '%s' "$_pos"
}

# ======================= the log route's TWO ERE guards =======================
# APPENDED AT THE END OF THIS FILE ON PURPOSE, not placed beside p5_regex_sane:
# `deploy/p5/facts` cites this file by `path:LINE` (rows mode/auto -> :454, :455,
# :456, :463) and `docs/knowledge/design/p5-portal-plan.md` cites it by RANGE,
# and neither file is this unit's to edit. Inserting mid-file would shift both
# and turn a comment fix into a red FD-5. The placement is a records constraint,
# stated here rather than left for the next reader to guess.
#
# THE TWO CHECKS ANSWER DIFFERENT QUESTIONS.
#   p5_regex_sane      CHARSET. Refuses `/`, every quantifier and every shell
#                      metacharacter, so a misedited row cannot name a path or
#                      build a backtracker over a ring of thousands of lines.
#   p5_regex_compiles  COMPILES. The charset admits `[` and `(` WITHOUT
#                      requiring their closers, so `a[b` passes the charset and
#                      is still not an ERE.
#
# WHY THE SECOND ONE HAD TO EXIST. emit_log's whole error model is that every
# refusal is decided BEFORE p5_hdr_text writes a byte, because after a 200 header
# there is no way left to say 500. An uncompilable row escaped that: it passed
# the charset, the header went out, and grep then failed on its own argument --
# so the route answered 200 WITH AN EMPTY BODY, which on this surface reads as
# "the ring holds no line carrying this tag". That is the one answer an operator
# has to be able to trust (the card's whole caveat is about absence), so a silent
# empty answer is worse here than a 500. No request byte can reach the pattern
# (the request supplies a NAME matched against a shipped row), so this is a
# SHIPPED-ROW defect class, not a leak.
#
# TWO THINGS ABOUT THE PROBE ARE MEASURED, NOT ASSUMED, AND BOTH BIT.
#
# 1. rc IS NOT ENOUGH.  `grep -E -- 'a[b'` over one line of input exits 2 under
#    GNU grep 3.11 and exits 1 under busybox 1.36.1, and rc 1 is also "no match".
#    Both write the complaint ("Unmatched [, [^, [:, [., or [=") to stderr. So the
#    probe reads BOTH: any stderr byte, or rc >= 2. An rc-only probe would refuse
#    the broken row in CI and ACCEPT it on the box -- the target runtime -- which
#    is the failure nothing in this repo would ever have seen.
#
# 2. THE PROBE MUST FEED A LINE.  The first version piped `printf ''` and bar
#    LOG-4d caught it: busybox grep compiles the pattern LAZILY, when it has a
#    line to match, so on EMPTY stdin it exits 1 in silence and `a[b` came back
#    ACCEPTED under busybox while GNU grep refused it. One byte of input is what
#    makes the two agree. `x` is that byte; nothing about it has to be true of
#    the ring, because only the COMPILE is being asked about.
#
# The probe's stdout goes to /dev/null, so a pattern that happens to match `x`
# leaks nothing, and `grep` is not on the portal's external boundary, so the PC-5
# ledger is unchanged. Bars LOG-4d/e (busybox grep), LOG-5e..h (the route, and
# the control that shows the 200-empty comes back without it).
p5_regex_compiles() {   # $1 = an ERE -> rc 0 if `grep -E` accepts it, 1 if not
    # stderr and the status are captured TOGETHER in one substitution: `$?` read
    # after a separate assignment is the assignment's, and this file has to be
    # right under busybox ash as well as bash.
    _rk=$(printf 'x\n' | grep -E -- "$1" 2>&1 >/dev/null; printf 'rc%s' "$?")
    case "$_rk" in
      rc0|rc1) return 0 ;;
      *)       return 1 ;;
    esac
}

# p5_regex_ok: the pair, in the order the error model needs -- charset first (it
# forks nothing), compile probe second. BOTH refusals are `bad_log_regex`: to the
# operator the row is unusable either way, and emit_log keeps ONE guard line, so
# adding this check shifted no `path:LINE` cite into cgi/p5-portal either.
p5_regex_ok() {   # $1 = an ERE -> rc 0 if it is servable, 1 if not
    p5_regex_sane "$1"     || return 1
    p5_regex_compiles "$1" || return 1
    return 0
}
