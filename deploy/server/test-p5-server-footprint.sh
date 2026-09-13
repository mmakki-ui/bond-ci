#!/bin/sh
# shellcheck shell=sh
# test-p5-server-footprint.sh -- executable bars for U129, GOAL.md:32 C4
# ("minimal SERVER-side footprint -- server is shared across peers -- push
# complexity client-side").
#
# WHY THIS EXISTS. Before U129 nothing bounded the daemon's footprint but
# respawn: no `nice`, no `limits`, no GOMAXPROCS on the procd stanza, and no
# bar anywhere checked that the shipped code stays memory-bounded by
# construction. A flood on :59402 could compete for both MT7981 cores with
# engarde-server and every WireGuard peer the box serves -- exactly what C4
# forbids, and nothing would have caught it going in.
#
# FIVE RULES, FIVE SEEDS. Each bar is sized to a single reverted line, not a
# whole-file diff, so a partial regression (one bound dropped, the others
# left) still goes RED on its own bar rather than hiding behind the others:
#   FP-1 the init stanza still opens exactly one procd instance/command
#   FP-2 no script this product ships touches network/wireguard/dropbear/
#        uhttpd via /etc/init.d -- the only /etc/init.d/* verbs anywhere in
#        p5/bin, p5/lib or deploy/server are p5-server's own, `firewall
#        reload` inside the armed deadman, and `cron reload` in p5-deadman
#   FP-3 server/*.go (non-test) stays memory-bounded by construction: exactly
#        one net.ListenUDP, one net.DialUDP, no os/exec, no file writes, no
#        map[ -- see deploy/server/init.d/p5-server's C4 footprint comment
#        for why these five facts are what "bounded by construction" means
#   FP-4 the stanza carries nice/limits/GOMAXPROCS/respawn and still no enable
#   FP-5 the measurer this unit ships is read-only, so running it cannot be
#        the thing that regresses the footprint it is meant to report on
#
# WHAT THIS DOES NOT PROVE. Same qualification as test-p5-server-init.sh:
# these bars read shipped TEXT and CODE on the dev PC. Nothing here has run
# on the GL-MT2500. deploy/server/p5-server-measure.sh is the step that turns
# the bound into a number on the actual box -- docs/deploy-p5-server.md
# section 6.
#
# Usage: sh deploy/server/test-p5-server-footprint.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/init.d/p5-server"
ROOT=$(cd "$HERE/../.." && pwd)
MEASURER="$HERE/p5-server-measure.sh"

# BAR-COUNT RATCHET -- see the same note in test-p5-server-init.sh. A pass
# count with no floor cannot tell "everything passed" from "half the bars
# stopped being reached".
BARS_MIN=17

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { if printf '%s\n' "$2" | grep -q "$3"; then ok "$1"; else bad "$1 (no /$3/ in <<$2>>)"; fi; }

if [ -f "$INIT" ]; then ok "FP-0 deploy/server/init.d/p5-server exists"
else
    bad "FP-0 deploy/server/init.d/p5-server MISSING"
    printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"; exit 1
fi
INIT_CODE=$(sed 's/#.*//' "$INIT")

# --------------------------------------------------------------- FP-1 -------
# Same shape as test-p5-server-init.sh's IS-6/IS-17 exactness bars: one
# instance, one command line. A second `procd_set_param command` would either
# be dead (procd keeps the last) or spawn a second copy of the daemon -- both
# widen the footprint this unit exists to bound.
CMD_N=$(printf '%s\n' "$INIT_CODE" | grep -c '^[[:space:]]*procd_set_param command ')
chk "FP-1 exactly one procd_set_param command in init.d/p5-server" "$CMD_N" "1"

# --------------------------------------------------------------- FP-2 -------
# Every /etc/init.d/<svc> <verb> token in the tree this product ships, text
# stripped of comments first (deploy/server/p5-server-preflight.sh:105
# mentions `/etc/init.d/firewall reload` in PROSE, which must not count).
# A while/read here-doc loop, not `for f in $(find ...)`: this repo's own path
# contains a space ("Claude Code"), and unquoted command-substitution
# word-splitting on that breaks a naive for-loop silently (found it FIRST TRY
# running this bar -- `sed: can't read /c/Users/mmakk/Claude` -- which is why
# it is written this way and not the shorter, wrong way).
FP2_LIST=$(while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    sed 's/#.*//' "$_f" \
        | grep -noE '/etc/init\.d/[A-Za-z0-9_-]+ (restart|reload|stop|start|enable|disable)' \
        | sed "s#^#$_f:#"
done <<EOF1
$(find "$ROOT/p5/bin" "$ROOT/p5/lib" "$HERE" -type f 2>/dev/null)
EOF1
)
FP2_BAD=""
while IFS= read -r _hit; do
    [ -n "$_hit" ] || continue
    _file=${_hit%%:*}
    _rest=${_hit#*:}
    _base=$(basename "$_file")
    _svc=$(printf '%s' "$_rest" | sed -E 's#.*/etc/init\.d/([A-Za-z0-9_-]+) .*#\1#')
    _verb=$(printf '%s' "$_rest" | sed -E 's#.*/etc/init\.d/[A-Za-z0-9_-]+ (restart|reload|stop|start|enable|disable).*#\1#')
    case "$_svc" in
        p5-server) : ;; # p5-server verbs are always in scope for this product
        cron|firewall)
            [ "$_base" = "p5-deadman" ] && [ "$_verb" = "reload" ] \
                || FP2_BAD="$FP2_BAD$_hit; "
            ;;
        *)
            FP2_BAD="$FP2_BAD$_hit; "
            ;;
    esac
done <<EOF2
$FP2_LIST
EOF2
chk "FP-2 the only /etc/init.d/* verbs in p5/bin,p5/lib,deploy/server are p5-server's own + cron/firewall reload in p5-deadman" \
    "$FP2_BAD" ""

# --------------------------------------------------------------- FP-3 -------
# server/*.go, non-test: memory-bounded by construction, not by a runtime
# limit RLIMIT_AS cannot express against a Go binary (see the init script's
# C4 footprint comment). Five facts, five bars, so one regressed fact does
# not hide behind the other four.
SERVER_DIR="$ROOT/p4-bondagg/server"
# `find -exec cat {} +` concatenates without a shell word-split step, so this
# is safe even though this repo's own path contains a space ("Claude Code") --
# see the FP-2 comment above for the bug this sidesteps.
SERVER_CAT=$(find "$SERVER_DIR" -maxdepth 1 -name '*.go' ! -name '*_test.go' -exec cat {} + 2>/dev/null)
if [ -z "$SERVER_CAT" ]; then
    bad "FP-3 no non-test .go files found under $SERVER_DIR"
else
    LISTEN_N=$(printf '%s\n' "$SERVER_CAT" | grep -oE 'net\.ListenUDP\(' | wc -l | tr -d ' ')
    chk "FP-3a exactly one net.ListenUDP( in server/*.go (main.go:300)" "$LISTEN_N" "1"
    DIAL_N=$(printf '%s\n' "$SERVER_CAT" | grep -oE 'net\.DialUDP\(' | wc -l | tr -d ' ')
    chk "FP-3b exactly one net.DialUDP( in server/*.go (main.go:308)" "$DIAL_N" "1"
    EXEC_N=$(printf '%s\n' "$SERVER_CAT" | grep -c '"os/exec"')
    chk "FP-3c no os/exec import in server/*.go" "$EXEC_N" "0"
    WRITE_N=$(printf '%s\n' "$SERVER_CAT" | grep -cE 'os\.(Create|WriteFile|OpenFile)\(')
    chk "FP-3d no os.Create|WriteFile|OpenFile in server/*.go" "$WRITE_N" "0"
    MAP_N=$(printf '%s\n' "$SERVER_CAT" | grep -c 'map\[')
    chk "FP-3e no map[ in server/*.go -- nothing here grows with traffic" "$MAP_N" "0"
fi

# --------------------------------------------------------------- FP-4 -------
has "FP-4a stanza sets nice (procd_set_param nice)" "$INIT_CODE" 'procd_set_param nice'
has "FP-4b stanza sets limits (procd_set_param limits)" "$INIT_CODE" 'procd_set_param limits'
has "FP-4c stanza sets GOMAXPROCS" "$INIT_CODE" 'GOMAXPROCS'
has "FP-4d stanza sets respawn (procd_set_param respawn)" "$INIT_CODE" 'procd_set_param respawn'
if printf '%s\n' "$INIT_CODE" | grep -qE '(^|[^[:alnum:]_])enable([^[:alnum:]_]|$)'; then
    bad "FP-4e no enable call in init.d/p5-server -- S7 is deferred: $(printf '%s\n' "$INIT_CODE" | grep -nE '(^|[^[:alnum:]_])enable([^[:alnum:]_]|$)' | tr '\n' ';')"
else
    ok "FP-4e no enable call in init.d/p5-server -- S7 is deferred"
fi

# --------------------------------------------------------------- FP-5 -------
# The measurer must not be able to regress the very footprint it reports on.
if [ -f "$MEASURER" ]; then
    ok "FP-5-0 deploy/server/p5-server-measure.sh exists"
    MCODE=$(sed 's/#.*//' "$MEASURER")
    UCI_HIT=$(printf '%s\n' "$MCODE" | grep -nE 'uci[[:space:]]+(set|commit)')
    chk "FP-5a measurer has no uci set|commit" "$UCI_HIT" ""
    INITD_HIT=$(printf '%s\n' "$MCODE" | grep -n '/etc/init\.d/')
    chk "FP-5b measurer never invokes /etc/init.d/*" "$INITD_HIT" ""
    REDIR_HIT=$(printf '%s\n' "$MCODE" | grep -nE '>{1,2}[[:space:]]*/(etc|overlay)')
    chk "FP-5c measurer has no > redirection into /etc or /overlay" "$REDIR_HIT" ""
else
    bad "FP-5-0 deploy/server/p5-server-measure.sh MISSING"
    bad "FP-5a measurer has no uci set|commit"
    bad "FP-5b measurer never invokes /etc/init.d/*"
    bad "FP-5c measurer has no > redirection into /etc or /overlay"
fi

_TOTAL=$((PASS + FAIL))
printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"
if [ "$_TOTAL" -lt "$BARS_MIN" ]; then
    printf 'RATCHET FAILED: only %s bars were REACHED, floor is %s.\n' "$_TOTAL" "$BARS_MIN"
    printf 'Bars stopped executing somewhere above. A green run that reaches fewer\n'
    printf 'bars than the last one is a regression in the gate, not a tidier suite.\n'
    exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
