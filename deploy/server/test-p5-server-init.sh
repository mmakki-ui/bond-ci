#!/bin/sh
# shellcheck shell=sh
# test-p5-server-init.sh -- executable bars for deploy/server/init.d/p5-server.
#
# WHY THESE EXIST. U112: docs/deploy-p5-server.md S3 installed a file that was
# in no repo -- the runbook named `/tmp/init.d/p5-server` and `ls deploy/server`
# had no `init.d` at all. A step that installs a file nobody can read is not a
# procedure, it is a note to whoever is at the keyboard. These bars hold the
# shipped file to the four things the runbook and the daemon actually require.
#
# WHAT THEY PROVE AND DO NOT PROVE. They read the shipped file as TEXT and parse
# it with the same shell that will source it. They prove: the START priority
# satisfies the only two ordering constraints the box's evidence supports; the
# procd env block carries exactly the keys the daemon reads and every one of
# them is bound to a value; the respawn triple is present with its three
# parameters; and there is no `enable` anywhere in the executable text. They
# prove NOTHING about procd on the GL-MT2500 -- not that the respawn triple is
# honoured by this firmware build, not that /etc/rc.common accepts the file, not
# that the daemon starts. deploy-p5-server.md S4/S5 are where those are first
# observed, and section 6 says so.
#
# THE SEEDED A/B THIS FILE IS SIZED FOR: delete either AGG_LISTEN line from the
# init script and this suite goes RED. That is why IS-13..IS-20 are two bars per
# key rather than one -- a single `grep AGG_LISTEN` would stay green while the
# key was passed as an empty string, which is the shape that would put the
# daemon on procd's default port on a box with no console.
#
# Usage: sh deploy/server/test-p5-server-init.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/init.d/p5-server"
ROOT=$(cd "$HERE/../.." && pwd)
RUNBOOK="$ROOT/docs/deploy-p5-server.md"

# BAR-COUNT RATCHET. A pass count with no floor cannot tell "everything passed"
# from "half the bars stopped being reached" -- see the same note in
# deploy/server/test-p5-fw-deadman.sh. Raise this when bars are added; a drop is
# a RED, not a tidier suite. Raised 33 -> 41 by U129 (IS-28..IS-35, the C4
# footprint bound: GOMAXPROCS/nice/limits).
BARS_MIN=41

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { if printf '%s\n' "$2" | grep -q "$3"; then ok "$1"; else bad "$1 (no /$3/ in <<$2>>)"; fi; }

# The whole file, and the file with every comment removed. Every bar about what
# the script DOES reads CODE; every bar about what it EXPLAINS reads TEXT. The
# `enable` bar is the reason the split has to exist: the header talks about
# enablement at length precisely because it must never do it.
if [ -f "$INIT" ]; then ok "IS-1 deploy/server/init.d/p5-server exists"
else
    bad "IS-1 deploy/server/init.d/p5-server MISSING -- the file U112 ships"
    printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"; exit 1
fi
TEXT=$(cat "$INIT")
CODE=$(sed 's/#.*//' "$INIT")

# ------------------------------------------------------------ structure --
chk "IS-2 shebang hands the file to /etc/rc.common" \
    "$(head -1 "$INIT")" '#!/bin/sh /etc/rc.common'
if sh -n "$INIT" 2>/dev/null; then ok "IS-3 sh -n parses it"
else bad "IS-3 sh -n rejects it"; fi
has "IS-4 USE_PROCD=1 (procd, not a bare start/stop script)" "$CODE" '^USE_PROCD=1$'
has "IS-5 start_service() is defined -- rc.common calls it" "$CODE" '^start_service()'
has "IS-6 the instance is opened and closed" \
    "$(printf '%s' "$CODE" | grep -c 'procd_open_instance\|procd_close_instance')" '^2$'
has "IS-7 command is the contract-reserved /usr/sbin/p5-server (contract/paths:155)" \
    "$CODE" 'procd_set_param command /usr/sbin/p5-server'
has "IS-8 stderr is captured (a box with no console needs the log)" \
    "$CODE" 'procd_set_param stderr 1'

# ---------------------------------------------------------------- START --
# The two constraints are deploy-p5-server.md:452-456: after S19firewall and
# after S20network. They bound START from BELOW at 20 and that is all they do,
# so the bar is the bound -- not the number, which is a stated tie-break the
# file argues for in prose. A bar asserting 94 would be asserting the choice,
# and the next person to re-derive it would have to weaken a bar to change it.
START_LINES=$(printf '%s\n' "$CODE" | grep -c '^START=')
chk "IS-9 exactly one START assignment" "$START_LINES" "1"
START_VAL=$(printf '%s\n' "$CODE" | sed -n 's/^START=\([0-9][0-9]*\)$/\1/p')
if [ -n "$START_VAL" ]; then ok "IS-10 START is a bare integer"
else bad "IS-10 START is not a bare integer: <<$(printf '%s\n' "$CODE" | grep '^START=')>>"; fi
if [ -n "$START_VAL" ] && [ "$START_VAL" -gt 20 ]; then
    ok "IS-11 START ($START_VAL) > 20 -- after S20network, and so after S19firewall"
else
    bad "IS-11 START ('$START_VAL') must be > 20: S19firewall and S20network both precede it"
fi
if [ -n "$START_VAL" ] && [ "$START_VAL" -lt 100 ]; then
    ok "IS-12 START ($START_VAL) < 100 -- rc.d flags are two digits (S<pri>p5-server)"
else
    bad "IS-12 START ('$START_VAL') must be < 100 or the rc.d symlink name is malformed"
fi
has "IS-13 the START derivation names S19firewall" "$TEXT" 'S19firewall'
has "IS-14 the START derivation names S20network" "$TEXT" 'S20network'
has "IS-15 the derivation separates the bound from the tie-break" "$TEXT" 'TIE-BREAK'
has "IS-16 STOP is set so the daemon stops before the network does" "$CODE" '^STOP=[0-9][0-9]*$'

# ------------------------------------------------------------------ env --
# EXACTLY the keys p4-bondagg/server/main.go:152-155 reads. Two bars per key:
# the key is PASSED in the procd env block, and the key is BOUND to a value in
# the file. One bar would pass on `AGG_LISTEN="$AGG_LISTEN"` with nothing
# assigning AGG_LISTEN -- procd would then hand the daemon an empty string and
# the daemon would fall back to its own default silently.
ENV_LINE=$(printf '%s\n' "$CODE" | grep 'procd_set_param env' | head -1)
ENV_COUNT=$(printf '%s\n' "$CODE" | grep -c 'procd_set_param env')
chk "IS-17 exactly one procd env block" "$ENV_COUNT" "1"
for k in AGG_LISTEN AGG_WG AGG_HOLD_MIN_MS AGG_HOLD_MAX_MS; do
    if printf '%s\n' "$ENV_LINE" | grep -q "$k=\"\\\$$k\""; then
        ok "IS-18/$k env block passes $k (main.go reads it)"
    else
        bad "IS-18/$k env block does not pass $k=\"\$$k\": <<$ENV_LINE>>"
    fi
    if printf '%s\n' "$CODE" | grep -q "^$k=\"\\\${$k:-"; then
        ok "IS-19/$k $k is bound to a default in the file"
    else
        bad "IS-19/$k $k has no ^$k=\"\${$k:-...}\" binding -- procd would pass it empty"
    fi
done
# Exactness in the other direction: no key the daemon does not read. A constant
# nobody consumes is the /etc/bond/agg_w defect (ROADMAP U82 / 52a76d3).
# GOMAXPROCS (U129) is allowed alongside the four Getenv keys even though it is
# not one of them: it is read by the Go RUNTIME at process start, not by
# main.go's Getenv calls -- see the C4 footprint comment in the init script.
EXTRA=$(printf '%s\n' "$ENV_LINE" | tr ' ' '\n' | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' \
        | grep -vx 'AGG_LISTEN\|AGG_WG\|AGG_HOLD_MIN_MS\|AGG_HOLD_MAX_MS\|GOMAXPROCS' | tr '\n' ' ')
chk "IS-20 env block carries NO key outside main.go:152-155 + GOMAXPROCS" "$(printf '%s' "$EXTRA")" ""

# ------------------------------------------------------- C4 footprint (U129) --
# GOAL.md:32, C4: minimal server footprint. Three bounds, each its own bar so a
# partial revert (one line dropped, the others left) still goes RED:
if printf '%s\n' "$ENV_LINE" | grep -q 'GOMAXPROCS="\$GOMAXPROCS"'; then
    ok "IS-28 env block passes GOMAXPROCS (Go runtime reads it at process start)"
else
    bad "IS-28 env block does not pass GOMAXPROCS=\"\$GOMAXPROCS\": <<$ENV_LINE>>"
fi
if printf '%s\n' "$CODE" | grep -q '^GOMAXPROCS="\${GOMAXPROCS:-'; then
    ok "IS-29 GOMAXPROCS is bound to a default in the file"
else
    bad "IS-29 GOMAXPROCS has no ^GOMAXPROCS=\"\${GOMAXPROCS:-...}\" binding"
fi
NICE_LINES=$(printf '%s\n' "$CODE" | grep -c '^[[:space:]]*procd_set_param nice ')
chk "IS-30 exactly one procd_set_param nice line" "$NICE_LINES" "1"
has "IS-31 nice is set to 10 (shares a core with production; loses the race, not the socket)" \
    "$CODE" 'procd_set_param nice 10$'
LIMITS_CORE_LINES=$(printf '%s\n' "$CODE" | grep -c '^[[:space:]]*procd_set_param limits core=')
chk "IS-32 exactly one procd_set_param limits core= line" "$LIMITS_CORE_LINES" "1"
has "IS-33 limits core is \"0\" (no crash dumps onto /overlay's small flash)" \
    "$CODE" 'procd_set_param limits core="0"$'
if printf '%s\n' "$CODE" | grep -qE 'limits[^$]*[[:space:]]as='; then
    bad "IS-34 the file sets limits as= -- Go reserves address space at start, this would fail to launch: $(printf '%s\n' "$CODE" | grep -nE 'limits[^$]*[[:space:]]as=')"
else
    ok "IS-34 no limits as= anywhere (Go would fail to launch under an address-space cap)"
fi
if [ -f "$RUNBOOK" ]; then
    has "IS-35 runbook section 6 states the C4 footprint bound" \
        "$(sed -n '/^## 6\./,/^## 7\./p' "$RUNBOOK")" 'GOMAXPROCS'
else
    bad "IS-35 runbook missing: $RUNBOOK"
fi

# -------------------------------------------------------------- respawn --
has "IS-21 respawn is set (procd supervises it after S5)" "$CODE" 'procd_set_param respawn'
RESPAWN_ARGS=$(printf '%s\n' "$CODE" | sed -n 's/.*procd_set_param respawn \(.*\)/\1/p' | head -1)
# word splitting is the point: the three respawn params are separate fields.
# shellcheck disable=SC2086
set -- $RESPAWN_ARGS
chk "IS-22 respawn carries its three parameters (threshold timeout retry)" "$#" "3"
if [ "$#" -eq 3 ] && [ "$3" -ge 1 ] 2>/dev/null; then
    ok "IS-23 the respawn RETRY cap is >= 1 -- a bounded crash loop, not an endless one"
else
    bad "IS-23 respawn retry cap unreadable or < 1: <<$RESPAWN_ARGS>>"
fi

# --------------------------------------------------------------- enable --
# S7 is deferred (deploy-p5-server.md:437-447). An init script that enables
# itself, or a runbook step that enables it, creates /etc/rc.d/S<pri>p5-server
# and puts the daemon in the boot path of a box with no recovery button. This
# reads the COMMENT-STRIPPED text on purpose: the header discusses enablement
# at length and must be allowed to.
if printf '%s\n' "$CODE" | grep -qE '(^|[^[:alnum:]_])enable([^[:alnum:]_]|$)'; then
    bad "IS-24 the init script CALLS enable -- S7 is deferred: $(printf '%s\n' "$CODE" | grep -nE '(^|[^[:alnum:]_])enable([^[:alnum:]_]|$)' | tr '\n' ';')"
else
    ok "IS-24 no enable call anywhere in the executable text"
fi

# -------------------------------------------------------------- runbook --
# The deliverable is only half a deliverable if S3 still installs a file from
# /tmp with no stated origin.
if [ -f "$RUNBOOK" ]; then
    S3=$(grep -n '^| S3 |' "$RUNBOOK" | head -1)
    has "IS-25 runbook S3 names the tree file" "$S3" 'deploy/server/init\.d/p5-server'
    has "IS-26 runbook S3 still says do NOT enable" "$S3" 'do NOT enable'
    if grep -q '^| S7 |.*DEFER' "$RUNBOOK"; then
        ok "IS-27 runbook S7 (boot enablement) is still deferred"
    else
        bad "IS-27 runbook S7 no longer defers boot enablement -- IS-24 assumes it does"
    fi
else
    bad "IS-25 runbook missing: $RUNBOOK"
    bad "IS-26 runbook missing: $RUNBOOK"
    bad "IS-27 runbook missing: $RUNBOOK"
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
