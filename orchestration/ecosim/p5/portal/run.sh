#!/bin/sh
# orchestration/ecosim/p5/portal/run.sh — Layer-2 harness for M9, the portal.
#
# Runs the REAL shipped CGI (deploy/p5/portal/cgi/p5-portal + lib/portal-lib.sh)
# against the REAL shipped bondctl and bond-xctl, under the SAME hermetic shims
# the main Layer-2 battery uses (orchestration/ecosim/p5/bin). A portal write
# therefore goes portal -> bondctl -> bond-xctl -> bond.dag, and the assertions
# are on the facts and the node, not on a mock.
#
# THE TWO SECURITY CONCERNS ARE THE POINT OF THIS FILE.
#
#  1. INJECTION. Five surfaces (shell, HTML/JS, URL/path, config-file, uci). For
#     each, the attack is run TWICE: against a MUTANT with that guard reverted to
#     the form a naive implementation would take, where the attack MUST SUCCEED,
#     and against the shipped code, where it MUST FAIL. A guard whose mutant does
#     not fire is not a guard -- it is a bar that would pass on an empty file.
#     Mutants are made by sed on a COPY; the shipped source carries no test hook.
#
#  2. FACT-WRITER COMPLIANCE. A static scan (PC-2) plus a RUNTIME LEDGER (PC-5):
#     every external argument vector the CGI issues while every control is
#     exercised is recorded, and the whole ledger must be a subset of a fixed
#     allowlist. PC-6 mutates the CGI into a second controller and shows the bars
#     go red. Before this file nothing gated the fact-writer contract at all.
#
# POSIX sh (Git Bash / busybox ash). No Python, no Go. Paths may contain spaces.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
P5="$REPO/deploy/p5"
PORTAL="$P5/portal"
ECOBIN="$HERE/../bin"
CGI_SRC="$PORTAL/cgi/p5-portal"
LIB_SRC="$PORTAL/lib/portal-lib.sh"
INIT_SRC="$PORTAL/init.d/p5-portal"

WORK="${P5PORTAL_WORK:-$(mktemp -d 2>/dev/null || echo "$HERE/work.$$")}"
[ -n "${P5PORTAL_WORK:-}" ] || trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
no() { fail=$((fail+1)); echo "FAIL  $1"; }
asrt() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1 (want '$3' got '$2')"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (no '$3')"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 (found '$3')"; else ok "$1"; fi; }

GOODSID=0123456789abcdef0123456789abcdef
CGI_COOKIE=""
CGI_UBUS=""

# ---------------------------------------------------------------- world ------
# Provenance: setup() is the world orchestration/ecosim/p5/run.sh builds (its
# setup(), lines ~32-65), reduced to what the portal path needs. The shims are
# the SAME files, not copies -- $ECOBIN is on PATH.
setup() {
    rm -rf "$WORK"; mkdir -p "$WORK/etc/bond" "$WORK/run/bond" "$WORK/fakebin" \
                             "$WORK/portalbin" "$WORK/p5state"
    export ECOSIM_STATE="$WORK"
    for b in engarde-client bond-agg bond-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"
    done
    echo lightning            > "$WORK/etc/bond/mode"
    echo wgclient1            > "$WORK/etc/bond/wg-logical"
    echo "203.0.113.9:51820"  > "$WORK/direct"
    echo "203.0.113.9:51820"  > "$WORK/ep"
    echo 1 > "$WORK/capable"; echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"; echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in engarde-client bond-agg bond-ecod bond-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
    export PATH="$ECOBIN:$PATH"
    export BOND_DIR="$WORK/etc/bond"
    export RUN_DIR="$WORK/run/bond"
    export DAG="$P5/bond.dag"
    export WG_DEV=wgclient1
    export SVC="$ECOBIN/svc-engarde"   AGG_SVC="$ECOBIN/svc-agg"
    export ECOD_SVC="$ECOBIN/svc-ecod" WDOG_SVC="$ECOBIN/svc-watchdog"
    export ENGARDE_BIN="$WORK/fakebin/engarde-client"
    export AGG_BIN="$WORK/fakebin/bond-agg"
    export ECOD_BIN="$WORK/fakebin/bond-ecod"
    export LOGGER="$ECOBIN/logger"
    export XCTL="$P5/bond-xctl"

    # ---- the portal's boundary, wrapped so every argv is recorded -----------
    # Only the PORTAL's own calls are logged. Each wrapper resets the env the
    # wrapped artifact uses for its OWN children, so the reconciler's downstream
    # work does not pollute the ledger.
    LEDGER="$WORK/cmdledger"; : > "$LEDGER"; export LEDGER
    cat > "$WORK/portalbin/bondctl" <<EOF
#!/bin/sh
echo "bondctl \$*" >> "$LEDGER"
XCTL="$P5/bond-xctl"; export XCTL
exec sh "$P5/bondctl" "\$@"
EOF
    cat > "$WORK/portalbin/bond-xctl" <<EOF
#!/bin/sh
echo "bond-xctl \$*" >> "$LEDGER"
exec sh "$P5/bond-xctl" "\$@"
EOF
    # uci wrapper: logs, adds the two read-only fixtures the portal path needs
    # (the shared Layer-2 shim is NOT modified -- its 92/0 baseline stays exactly
    # as it was), then delegates.
    cat > "$WORK/portalbin/uci" <<EOF
#!/bin/sh
echo "uci \$*" >> "$LEDGER"
for a in "\$@"; do
  case "\$a" in
    kmwan.global.mode)   echo failover;      exit 0 ;;
    network.lan.ipaddr)  echo 192.0.2.1;     exit 0 ;;
  esac
done
exec "$ECOBIN/uci" "\$@"
EOF
    # ubus wrapper: serves the `session` namespace the portal's auth needs (the
    # shared shim has none) and delegates the rest. A session id is accepted only
    # when it equals \$GOODSID, so a forged or dead id gets rpcd's "Not found".
    cat > "$WORK/portalbin/ubus" <<EOF
#!/bin/sh
echo "ubus \$*" >> "$LEDGER"
if [ "\${1:-}" = call ] && [ "\${2:-}" = session ]; then
    case "\${4:-}" in
      *'"$GOODSID"'*) echo '{ "values": { "username": "root" } }'; exit 0 ;;
      *) echo "Command failed: Not found" >&2; exit 4 ;;
    esac
fi
exec "$ECOBIN/ubus" "\$@"
EOF
    chmod +x "$WORK/portalbin/bondctl" "$WORK/portalbin/bond-xctl" \
             "$WORK/portalbin/uci" "$WORK/portalbin/ubus"
    export BONDCTL="$WORK/portalbin/bondctl"
    export P_XCTL="$WORK/portalbin/bond-xctl"
    export P_UCI="$WORK/portalbin/uci"
    export P_UBUS="$WORK/portalbin/ubus"
    export P5_STATE_DIR="$WORK/p5state"
    CGI_COOKIE=""; CGI_UBUS=""
}

# ---------------------------------------------------------------- driver -----
# cgi ROOT METHOD QUERY BODY [SID] -> raw CGI response on stdout.
# ROOT lets a bar point at a MUTANT copy of the portal instead of the shipped one.
cgi() {
    _root="$1"; _m="$2"; _q="$3"; _b="$4"; _sid="${5-$GOODSID}"
    _len=$(printf '%s' "$_b" | wc -c | tr -d ' ')
    printf '%s' "$_b" | env \
        P5_PORTAL_DIR="$_root" P5_CAT_DIR="$_root/catalogue" \
        BOND_DIR="$BOND_DIR" P5_STATE_DIR="$P5_STATE_DIR" \
        BONDCTL="$BONDCTL" XCTL="$P_XCTL" UCI="$P_UCI" \
        UBUS="${CGI_UBUS:-$P_UBUS}" \
        REQUEST_METHOD="$_m" QUERY_STRING="$_q" CONTENT_LENGTH="$_len" \
        HTTP_X_P5_SESSION="$_sid" HTTP_COOKIE="$CGI_COOKIE" \
        sh "$_root/cgi/p5-portal" 2>/dev/null
}
G() { cgi "$PORTAL" GET  "$1" ""   "${2-$GOODSID}"; }
P() { cgi "$PORTAL" POST ""   "$1" "${2-$GOODSID}"; }
st() { printf '%s' "$1" | sed -n 's/^Status: \([0-9]*\).*/\1/p' | head -1; }
bd() { printf '%s\n' "$1" | awk 'b{print} /^\r?$/{b=1}'; }
# jf FIELD BODY -> the value of a top-level JSON string field. Naive, and
# sufficient precisely BECAUSE the CGI's escaper guarantees no bare quote inside.
jf() { printf '%s' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1; }

# mutate NAME [sed args...] -> path to a mutant portal root
mutate() {
    _name="$1"; shift
    _mut="$WORK/mut-$_name"
    rm -rf "$_mut"; mkdir -p "$_mut"
    cp -r "$PORTAL/cgi" "$PORTAL/lib" "$PORTAL/catalogue" "$_mut/"
    for _f in "$_mut/cgi/p5-portal" "$_mut/lib/portal-lib.sh"; do
        sed "$@" "$_f" > "$_f.new" && mv "$_f.new" "$_f"
    done
    printf '%s' "$_mut"
}

echo "===== M9 portal harness (Layer-2 style) ====="

# ============================ AUTHENTICATION =================================
# TESTED: the portal is closed to anything the box's own session backend does
# not recognise, and it FAILS CLOSED when that backend cannot answer.
# NOT TESTED, AND NOT TESTABLE FROM THIS REPO: whether `gl-session` actually
# keeps its sessions in that backend. That is a labelled HYPOTHESIS -- see
# lib/portal-lib.sh and the `### portal-auth` block in scripts/box-inventory.sh.
setup
R=$(G "q=state" "");        asrt "AUTH-1 no session id -> 403"        "$(st "$R")" 403
R=$(G "q=state" "deadbeef");asrt "AUTH-2a short id -> 403"            "$(st "$R")" 403
R=$(G "q=state" '0123456789abcdef0123456789abcde"')
                            asrt "AUTH-2b id carrying a quote -> 403"  "$(st "$R")" 403
hasnt "AUTH-2c the malformed id never reached the session backend" "$(cat "$LEDGER")" 'abcde"'
R=$(G "q=state");           asrt "AUTH-3 valid session -> 200"        "$(st "$R")" 200
CGI_COOKIE="sysauth=$GOODSID"
R=$(P 'k=mode&v=eco' "")
asrt "AUTH-4 a cookie ALONE does not authorise a write (CSRF)" "$(st "$R")" 403
asrt "AUTH-4b ... and the mode fact is untouched" "$(cat "$BOND_DIR/mode")" lightning
CGI_COOKIE=""
CGI_UBUS="$WORK/no-such-ubus"
R=$(P 'k=mode&v=eco')
asrt "AUTH-5 session backend unreachable -> 403 (fails CLOSED)" "$(st "$R")" 403
asrt "AUTH-5b ... and no fact changed"            "$(cat "$BOND_DIR/mode")" lightning
CGI_UBUS=""

# ============================ THE PAIR (ADR-003 rule 5) ======================
# "the test most likely to be skipped and the one the ADR was written for"
# (m9-portal-design.md §6.1).
setup
touch "$BOND_DIR/auto"; echo lightning > "$BOND_DIR/mode"     # auto on, ecod escalated
R=$(G "q=state"); B=$(bd "$R")
asrt "PAIR-1 auto+escalated: intent is what the USER chose"    "$(jf intent "$B")"   eco
asrt "PAIR-1b auto+escalated: position is where the SYSTEM is" "$(jf position "$B")" lightning
setup
rm -f "$BOND_DIR/auto"; echo lightning > "$BOND_DIR/mode"      # manual pin
R=$(G "q=state"); B=$(bd "$R")
asrt "PAIR-2 manual pin: intent IS the pin"        "$(jf intent "$B")"   lightning
asrt "PAIR-2b manual pin: no position is claimed"  "$(jf position "$B")" ""
# teeth: the naive single-readout portal fails PAIR-1.
setup
touch "$BOND_DIR/auto"; echo lightning > "$BOND_DIR/mode"
M=$(mutate pair -e 's#^p5_intent()   { if \[ -f "$BOND_DIR/auto" \]; then echo eco; else p5_raw_mode; fi; }#p5_intent()   { p5_raw_mode; }#')
R=$(cgi "$M" GET "q=state" ""); B=$(bd "$R")
asrt "PAIR-3 MUTANT single-readout portal shows 'lightning' as the selection" "$(jf intent "$B")" lightning
if [ "$(jf intent "$B")" = lightning ]; then ok "PAIR-3b ... so PAIR-1 is non-vacuous"
else no "PAIR-3b the mutant did not reproduce the defect"; fi

# ============================ ADR-003 rule 4 =================================
setup
touch "$BOND_DIR/auto"; echo lightning > "$BOND_DIR/mode"
R=$(P 'k=mode&v=speed'); B=$(bd "$R")
asrt "R4-1 pinning out of auto without confirm -> 409" "$(st "$R")" 409
asrt "R4-1b ... and it names the pin it would create"  "$(jf pin "$B")" lightning
asrt "R4-1c ... and nothing was written"               "$(cat "$BOND_DIR/mode")" lightning
if [ -f "$BOND_DIR/auto" ]; then ok "R4-1d ... and auto is still on"; else no "R4-1d auto was cleared anyway"; fi
R=$(P 'k=mode&v=speed&confirm=lightning')
asrt "R4-2 with the confirmation -> applied" "$(st "$R")" 200
asrt "R4-2b ... mode pinned"                 "$(cat "$BOND_DIR/mode")" speed
if [ -f "$BOND_DIR/auto" ]; then no "R4-2c auto should be cleared by a manual pin"; else ok "R4-2c auto cleared"; fi
setup
touch "$BOND_DIR/auto"; echo lightning > "$BOND_DIR/mode"
M=$(mutate rule4 -e 's#^    _pin=$(p5_pin_needing_confirm "$_v")#    _pin=""#')
R=$(cgi "$M" POST "" 'k=mode&v=speed')
asrt "R4-3 MUTANT without the gate pins SILENTLY (so R4-1 is non-vacuous)" "$(st "$R")" 200

# ============================ the mode set ===================================
setup
R=$(P 'k=mode&v=max')
asrt "MODE-1 a catalogue mode the EXECUTOR does not implement is refused" "$(st "$R")" 501
asrt "MODE-1b ... and the fact is untouched" "$(cat "$BOND_DIR/mode")" lightning
R=$(P 'k=mode&v=redundant')
asrt "MODE-2 the pre-ADR-003 name is unknown" "$(st "$R")" 400
setup
R=$(P 'k=mode&v=eco')
asrt "MODE-3 eco applies"      "$(st "$R")" 200
asrt "MODE-3b eco writes mode" "$(cat "$BOND_DIR/mode")" eco
if [ -f "$BOND_DIR/auto" ]; then ok "MODE-3c eco SETS auto (the one verb that enables the policy)"
else no "MODE-3c eco did not set auto"; fi
R=$(P 'k=mode&v=speed&confirm=eco')
asrt "MODE-4 speed engages"              "$(st "$R")" 200
asrt "MODE-4b node"                      "$(sh "$P5/bond-xctl" node)" engaged
asrt "MODE-4c the endpoint moved to the aggregate listener" "$(cat "$WORK/ep")" "127.0.0.1:59402"
R=$(P 'k=mode&v=direct')
asrt "MODE-5 direct is the lifecycle off state" "$(st "$R")" 200
asrt "MODE-5b node"                             "$(sh "$P5/bond-xctl" node)" off
IMPL=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/modes" \
       | awk -F'|' '$3=="implemented" && $2=="mode"{print $1}' | sort | tr '\n' ' ')
BCTL=$(sed -n 's/^[[:space:]]*case "$M" in \([a-z|]*\)).*/\1/p' "$P5/bondctl" \
       | head -1 | tr '|' '\n' | sort | tr '\n' ' ')
asrt "PC-1 catalogue implemented modes == bondctl's own accepted set" "$IMPL" "$BCTL"

# ============================ INJECTION ======================================

# --- INJ-1  SHELL ---------------------------------------------------------
# The chosen value ends up on a command line. The shipped guard is STRUCTURAL:
# the request value is only COMPARED to a catalogue literal and it is the
# CATALOGUE'S copy that is passed, as one argv element. The mutant is the form a
# naive implementation takes -- accept the value, build a command string, run it
# through a shell.
setup
PWN="$WORK/pwned"; PWN_ENC=$(printf '%s' "$PWN" | sed 's|/|%2F|g')
M=$(mutate inj1 \
  -e 's#^    _v=$(p5_match_literal "$(p5_modes_all)" "$_v_raw").*#    _v="$_v_raw"#' \
  -e 's#^    p5_match_literal "$(p5_modes_impl)" "$_v" >/dev/null.*#    :#' \
  -e 's#^    _verb=$(p5_cat_field modes "$_v" 2)#    _verb=mode#'   -e 's#^        _out=$("$BONDCTL" mode "$_v" 2>&1); _rc=$?#        _out=$(sh -c "$BONDCTL mode $_v" 2>\&1); _rc=$?#')
rm -f "$PWN"
cgi "$M" POST "" "k=mode&v=eco%3Btouch+$PWN_ENC" >/dev/null 2>&1
if [ -e "$PWN" ]; then ok "INJ-1a MUTANT: 'v=eco;touch FILE' EXECUTED -- the surface is real"
else no "INJ-1a the mutant did not execute; INJ-1b would be a vacuous bar"; fi
setup
PWN="$WORK/pwned"; PWN_ENC=$(printf '%s' "$PWN" | sed 's|/|%2F|g')
rm -f "$PWN"
R=$(P "k=mode&v=eco%3Btouch+$PWN_ENC")
asrt "INJ-1b SHIPPED: the same request is 400" "$(st "$R")" 400
if [ -e "$PWN" ]; then no "INJ-1c a file was created -- shell injection"; else ok "INJ-1c nothing executed"; fi
asrt "INJ-1d ... and no fact moved" "$(cat "$BOND_DIR/mode")" lightning
hasnt "INJ-1e ... and the payload never reached a command line" "$(cat "$LEDGER")" ';touch'

# --- INJ-2  HTML / JS -----------------------------------------------------
# The values the portal reads BACK are not values it controls: a fact file can be
# hand-edited and ubus output belongs to the box. Unescaped they land inside the
# page's JSON and become markup.
setup
printf 'on"</script><script>alert(1)</script>\n' > "$BOND_DIR/shape"
_mut="$WORK/mut-inj2"; rm -rf "$_mut"; mkdir -p "$_mut"
cp -r "$PORTAL/cgi" "$PORTAL/lib" "$PORTAL/catalogue" "$_mut/"
awk 's==1 && /^\}/ { s=0; next }
     s==1 { next }
     /^p5_json_str\(\) \{/ { print "p5_json_str() { printf \"\\\"%s\\\"\" \"$1\"; }"; s=1; next }
     { print }' "$LIB_SRC" > "$_mut/lib/portal-lib.sh"
R=$(cgi "$_mut" GET "q=state" ""); B=$(bd "$R")
has   "INJ-2a MUTANT: raw '</script>' reaches the response body" "$B" '</script>'
R=$(G "q=state"); B=$(bd "$R")
hasnt "INJ-2b SHIPPED: no raw '</script>' in the body" "$B" '</script>'
hasnt "INJ-2c SHIPPED: no raw '<' anywhere in the body" "$B" '<'
has   "INJ-2d SHIPPED: it is escaped as \\u003c"        "$B" 'u003c'
has   "INJ-2e SHIPPED: the response is typed JSON + nosniff" "$R" 'X-Content-Type-Options: nosniff'

# --- INJ-3  URL / PATH ----------------------------------------------------
# The fact path is "$BOND_DIR/$key". A key that is not a catalogue literal, or
# not a bare identifier, aims the write anywhere -- the same class as E0's
# demonstrated `../../` removal of an SSH key (ROADMAP.md "B1 SERVER-LOSS PATH").
TRAV='..%2F..%2Fvictim%2Fauthorized_keys'
setup
mkdir -p "$WORK/victim"; : > "$WORK/victim/authorized_keys"
M=$(mutate inj3 \
  -e 's#^    _k=$(p5_match_literal "$(p5_cat_keys fields)" "$_k_raw").*#    _k="$_k_raw"#' \
  -e 's#^    p5_key_sane "$_k" .*#    :#' \
  -e 's#^    _kind=$(p5_cat_field fields "$_k" 2)#    _kind=enum#' \
  -e 's#^    _dom=$(p5_cat_field fields "$_k" 3)#    _dom="on off"#')
cgi "$M" POST "" "k=$TRAV&v=on" >/dev/null 2>&1
if [ -s "$WORK/victim/authorized_keys" ]; then ok "INJ-3a MUTANT: the write landed OUTSIDE \$BOND_DIR"
else no "INJ-3a the mutant did not escape BOND_DIR; INJ-3b would be a vacuous bar"; fi
setup
mkdir -p "$WORK/victim"; : > "$WORK/victim/authorized_keys"
R=$(P "k=$TRAV&v=on")
asrt "INJ-3b SHIPPED: a traversal key -> 400" "$(st "$R")" 400
if [ -s "$WORK/victim/authorized_keys" ]; then no "INJ-3c a file outside \$BOND_DIR was written"
else ok "INJ-3c nothing outside \$BOND_DIR was touched"; fi
R=$(G "q=probe&name=..%2F..%2Fbin%2Fsh")
asrt "INJ-3d SHIPPED: a traversal probe name -> 400" "$(st "$R")" 400

# --- INJ-4  CONFIG FILE ---------------------------------------------------
# A fact file is line-structured AND is read back by busybox sh, so a value
# carrying a newline is a SECOND fact and a value carrying a space plus a
# metacharacter is a SECOND WORD. Two independent layers stop that: the decoder
# refuses control characters, and the writer emits the CATALOGUE'S literal rather
# than the request's bytes. Each layer gets its own mutant AND its own vector --
# one shared vector cannot reach both, because the key/value transport between
# them is itself line-based and truncates a newline before the writer ever sees
# it. Naming that third, incidental barrier is the point: a mutant that cannot
# fire proves nothing, and pretending one vector covered both layers would have
# been exactly that.
setup
# 4a -- the DECODER layer, vector "on<LF>off". Removing the reject does not put a
# newline in the file (the transport truncated it); what it changes is the
# verdict, 400 -> 200. So the decoder is what refuses, and the writer's literal
# substitution is what still holds the file to one line.
M4A=$(mutate inj4a -e 's#          if (ctl(k) .*#          if (0) { }#')
R=$(cgi "$M4A" POST "" 'k=shape&v=on%0Aoff')
asrt "INJ-4a MUTANT(decoder guard removed): the newline vector stops being refused" "$(st "$R")" 200
asrt "INJ-4a2 ... and the SECOND layer still holds the fact file to one line"      "$(wc -l < "$BOND_DIR/shape" 2>/dev/null | tr -d ' ')" 1
setup
# 4b -- the WRITER layer, vector "on ;reboot". No control character, so it passes
# the decoder untouched and only the literal substitution stands between it and
# the fact file. In a fact file read unquoted by busybox sh that value is two
# words, the second of which is a command.
M4B=$(mutate inj4b -e 's#^        _v=$(p5_match_literal "$_dom" "$_v_raw").*#        _v="$_v_raw"#')
cgi "$M4B" POST "" 'k=shape&v=on+%3Breboot' >/dev/null 2>&1
asrt "INJ-4b MUTANT(literal substitution removed): the raw bytes land in the fact file"      "$(cat "$BOND_DIR/shape" 2>/dev/null)" "on ;reboot"
setup
R=$(P 'k=shape&v=on%0Aoff')
asrt "INJ-4c SHIPPED: an embedded newline -> 400" "$(st "$R")" 400
if [ -f "$BOND_DIR/shape" ]; then no "INJ-4d a fact was written anyway"; else ok "INJ-4d no fact written"; fi
R=$(P 'k=shape&v=on+%3Breboot')
asrt "INJ-4e SHIPPED: a value with a space and a metacharacter -> 400" "$(st "$R")" 400
if [ -f "$BOND_DIR/shape" ]; then no "INJ-4f a fact was written anyway"; else ok "INJ-4f no fact written"; fi
R=$(P 'k=shape&v=on')
asrt "INJ-4g SHIPPED: the clean value applies"      "$(st "$R")" 200
asrt "INJ-4h ... exactly one line"                  "$(wc -l < "$BOND_DIR/shape" | tr -d ' ')" 1
asrt "INJ-4i ... and it is the catalogue's literal" "$(cat "$BOND_DIR/shape")" on

# --- INJ-5  uci -----------------------------------------------------------
# uci holds the box's whole configuration, keys included. A request-supplied uci
# key is an information-disclosure surface with no shell involved at all.
setup
M=$(mutate inj5 -e 's#^    _argv=$(p5_cat_field probes "$_n" 2)#    _argv="UCI -q get $(p5_arg key)"#')
R=$(cgi "$M" GET 'q=probe&name=kmwan&key=network.lan.ipaddr' ""); B=$(bd "$R")
LEAK=$(jf output "$B")
if [ -n "$LEAK" ] && [ "$LEAK" != failover ]; then ok "INJ-5a MUTANT: a request-supplied uci key was read ('$LEAK')"
else no "INJ-5a the mutant did not reach uci with the request's key; INJ-5b would be vacuous"; fi
setup
R=$(G 'q=probe&name=kmwan&key=network.lan.ipaddr'); B=$(bd "$R")
asrt "INJ-5b SHIPPED: the extra key is ignored, the catalogue argv is used" "$(jf output "$B")" failover
asrt "INJ-5c SHIPPED: uci saw only the fixed catalogue vector" \
     "$(grep '^uci ' "$LEDGER" | sort -u)" "uci -q get kmwan.global.mode"

# ============================ FACT-WRITER COMPLIANCE =========================
# PC-2 static. The forbidden set is the design's own list of what makes a UI a
# second controller: an init-script lifecycle ACTION, the shaper CLI, uci/sqm
# writes, and any bond.dag edge verb.
setup
bad=""
for t in 'autoratectl' 'uci set' 'uci commit' 'uci add' 'uci delete' '/etc/init.d/' 'sqm' 'iptables' 'wg set' 'ip route' 'agg_restart' 'eval '; do
    if grep -n -F -- "$t" "$CGI_SRC" "$LIB_SRC" | grep -vE ':[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
        bad="$bad [$t]"
    fi
done
asrt "PC-2 no forbidden verb in the portal source" "$bad" ""
SVCACT=$(grep -nE '"\$[A-Z_]*SVC" (start|stop|restart)' "$CGI_SRC" "$LIB_SRC" \
         | grep -vcE ':[0-9]+:[[:space:]]*#')
asrt "PC-2b no service start/stop/restart" "$SVCACT" 0
BADHEAD=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/probes" \
          | awk -F'|' 'NF>1{split($2,a," "); if (a[1]!="XCTL" && a[1]!="UCI" && a[1]!="BONDCTL") print a[1]}')
asrt "PC-3 every probe argv head is in the closed symbol set" "$BADHEAD" ""
BADVERB=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/probes" \
          | awk -F'|' 'NF>1{split($2,a," "); v=a[2]; if (v=="reconcile"||v=="on"||v=="off"||v=="mode"||v=="set"||v=="commit") print v}')
asrt "PC-3b no probe row is a mutating verb" "$BADVERB" ""
BADFIELD=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/fields" \
           | awk -F'|' 'NF>1{k=$1; if (k=="exclude"||k=="sources"||k=="agg_paths"||k=="agg_w"||k=="metered") print k}')
asrt "PC-4 no per-source participation field is exposed (ADR-003 §4)" "$BADFIELD" ""

# PC-5 RUNTIME LEDGER over every control the portal has.
setup
: > "$LEDGER"
G "q=catalogue" >/dev/null; G "q=state" >/dev/null
for p in sources node primary server selfcheck kmwan; do G "q=probe&name=$p" >/dev/null; done
P 'k=mode&v=eco'                    >/dev/null
P 'k=mode&v=lightning&confirm=eco'  >/dev/null
P 'k=mode&v=speed'                  >/dev/null
P 'k=shape&v=on'                    >/dev/null
P 'k=profile&v=balanced'            >/dev/null
P 'k=shape&op=reset'                >/dev/null
P 'k=mode&v=direct'                 >/dev/null
IMPLRE=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/modes" \
         | awk -F'|' '$3=="implemented" && $2=="mode"{printf "%s|",$1}')
IMPLRE=${IMPLRE%|}
VIOL=$(awk -v impl="$IMPLRE" '
  { if ($0 == "bondctl on") next
    if ($0 == "bondctl off") next
    if ($0 ~ ("^bondctl mode (" impl ")$")) next
    if ($0 ~ /^bond-xctl (reconcile|node|_sources|_primary|_server|selfcheck)$/) next
    if ($0 == "uci -q get kmwan.global.mode") next
    if ($0 ~ /^ubus call session get /) next
    print }' "$LEDGER" | sort -u)
asrt "PC-5 every external argv the portal issued is in the allowlist" "$VIOL" ""
NLED=$(grep -c . "$LEDGER")
if [ "$NLED" -ge 20 ]; then ok "PC-5b the ledger is non-empty ($NLED invocations)"
else no "PC-5b ledger has only $NLED lines -- the bar may be exercising nothing"; fi

# PC-6 teeth: a portal that acts directly must fail both bars.
M=$(mutate pc6 -e 's#^        _out=$("$BONDCTL" off 2>&1); _rc=$?#        _out=$("$SVC" stop 2>\&1); _rc=$?#')
if grep -q '"\$SVC" stop' "$M/cgi/p5-portal"; then ok "PC-6a the mutant really became a second controller"
else no "PC-6a the mutation did not apply -- PC-6 proves nothing"; fi
MSVC=$(grep -nE '"\$[A-Z_]*SVC" (start|stop|restart)' "$M/cgi/p5-portal" \
       | grep -vcE ':[0-9]+:[[:space:]]*#')
if [ "$MSVC" -ge 1 ]; then ok "PC-6b PC-2b's static scan catches it (it would report $MSVC)"
else no "PC-6b the static scan does NOT catch a direct service action"; fi
setup
: > "$LEDGER"
cgi "$M" POST "" 'k=mode&v=direct' >/dev/null 2>&1
if grep -q 'bondctl off' "$LEDGER"; then no "PC-6c the mutant still went through bondctl"
else ok "PC-6c the mutant bypassed bondctl entirely -- what PC-5's ledger exists to catch"; fi

# ============================ the numeric field ==============================
setup
R=$(P 'k=floor_kbit&v=12000')
asrt "NUM-1 with no declared envelope the field is refused, not given an invented ceiling" "$(st "$R")" 409
has  "NUM-1b ... and says why" "$(bd "$R")" no_envelope
printf '5000 90000\n' > "$P5_STATE_DIR/floor_envelope"
R=$(P 'k=floor_kbit&v=12000')
asrt "NUM-2 inside a declared envelope it applies" "$(st "$R")" 200
asrt "NUM-2b ... and the canonical decimal is written" "$(cat "$BOND_DIR/floor_kbit")" 12000
R=$(P 'k=floor_kbit&v=99999999')
asrt "NUM-3 outside the envelope -> 400" "$(st "$R")" 400
R=$(P 'k=floor_kbit&v=12000abc')
asrt "NUM-4 non-numeric -> 400"          "$(st "$R")" 400
R=$(P 'k=floor_kbit&op=reset')
asrt "NUM-5 restore-to-defaults REMOVES the fact" "$(st "$R")" 200
if [ -f "$BOND_DIR/floor_kbit" ]; then no "NUM-5b the fact survived the reset"; else ok "NUM-5b the fact is gone"; fi

# ============================ size / method ==================================
setup
LONG=$(awk 'BEGIN{ for(i=0;i<300;i++) s = s "A"; print s }')
R=$(P "k=shape&v=$LONG");  asrt "LEN-1 an over-long value -> 400" "$(st "$R")" 400
HUGE=$(awk 'BEGIN{ for(i=0;i<3000;i++) s = s "A"; print s }')
R=$(P "k=shape&v=$HUGE");  asrt "LEN-2 an over-long BODY -> 413"  "$(st "$R")" 413
R=$(P 'kmodev');           asrt "LEN-3 a malformed pair -> 400"   "$(st "$R")" 400
R=$(cgi "$PORTAL" PUT "" ""); asrt "LEN-4 an unexpected method -> 405" "$(st "$R")" 405

# ============================ N-GENERIC ======================================
setup
NG=$(grep -nE 'WAN ?[0-9]|eth[0-9]|usb[0-9]|wwan[0-9]|first source|second source|both WANs|two (WANs|sources)' \
       "$CGI_SRC" "$LIB_SRC" "$PORTAL/www/portal.js" "$PORTAL/www/index.html" \
       "$INIT_SRC" "$PORTAL/catalogue/modes" "$PORTAL/catalogue/fields" \
       "$PORTAL/catalogue/probes" | grep -c .)
asrt "NG-1 no source name, index or two-source phrasing anywhere in the portal" "$NG" 0
R=$(G "q=sources"); B=$(bd "$R")
NSRC=$(printf '%s' "$B" | tr ',' '\n' | grep -c '"iface"')
NREAL=$(sh "$P5/bond-xctl" _sources 2>/dev/null | grep -c .)
asrt "NG-2 every source the box declares is rendered, none truncated" "$NSRC" "$NREAL"
if [ "$NREAL" -ge 3 ]; then ok "NG-2b ... and the fixture is beyond two sources ($NREAL)"
else no "NG-2b the fixture has only $NREAL sources -- NG-2 cannot see truncation"; fi

# ============================ LAN-BOUND ======================================
# The real bar -- "not reachable from the WAN interface" (design §6.4) -- needs
# the box and belongs to G3. What IS establishable here: the service cannot come
# up bound to anything but a derived LAN address, and refuses rather than guess.
WILD=$(grep -cE '\-p[[:space:]]*"?(0\.0\.0\.0|\[::\]|\*)' "$INIT_SRC")
asrt "LAN-1 no wildcard bind anywhere in the init script" "$WILD" 0
PLIT=$(grep -oE '\-p "[^"]*"' "$INIT_SRC" | grep -vc '\$_addr:\$_port')
asrt "LAN-2 the ONLY -p argument is the derived \$_addr:\$_port" "$PLIT" 0
UBUSPROX=$(grep -cE '^[^#]*-u[[:space:]]+/ubus' "$INIT_SRC")
asrt "LAN-3 the ubus HTTP proxy is NOT exposed on this instance" "$UBUSPROX" 0
if grep -q 'REFUSING TO START' "$INIT_SRC"; then ok "LAN-4 the service fails closed when address or port cannot be established"
else no "LAN-4 no fail-closed path in the init script"; fi
UCIW=$(grep -cE '^[^#]*uci[[:space:]]+(set|add|delete|commit)' "$INIT_SRC")
asrt "LAN-5 the init script writes no uci (GL's uhttpd config is untouched)" "$UCIW" 0

echo "===== M9 portal: $pass passed, $fail failed ====="
[ "$fail" -eq 0 ] || exit 1
