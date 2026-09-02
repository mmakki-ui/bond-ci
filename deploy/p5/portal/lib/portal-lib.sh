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
BOND_DIR="${BOND_DIR:-/etc/bond}"
P5_STATE_DIR="${P5_STATE_DIR:-/etc/p5/portal}"
BONDCTL="${BONDCTL:-/usr/sbin/bondctl}"
XCTL="${XCTL:-/usr/sbin/bond-xctl}"
UCI="${UCI:-/sbin/uci}"
UBUS="${UBUS:-/bin/ubus}"
P5_MAX_BODY="${P5_MAX_BODY:-2048}"      # bytes; a larger request is 413
P5_MAX_VALUE="${P5_MAX_VALUE:-128}"     # bytes per decoded value; larger is 400
P5_MAX_EMIT="${P5_MAX_EMIT:-4096}"      # chars per emitted JSON string

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
p5_cat_field() {   # $1=file $2=key $3=column(2..5)
    _cf="$P5_CAT_DIR/$1"; [ -r "$_cf" ] || return 0
    while IFS='|' read -r _c1 _c2 _c3 _c4 _c5 || [ -n "${_c1:-}" ]; do
        case "${_c1:-}" in ''|'#'*) continue ;; esac
        [ "$_c1" = "$2" ] || continue
        case "$3" in
          2) printf '%s' "${_c2:-}" ;;
          3) printf '%s' "${_c3:-}" ;;
          4) printf '%s' "${_c4:-}" ;;
          5) printf '%s' "${_c5:-}" ;;
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
# m9-portal-design.md §2 / ADR-003 rule 5. `/etc/bond/mode` alone is NOT the
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
