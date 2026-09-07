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
#
# SC2016 IS DISABLED FILE-WIDE, DELIBERATELY. Every single-quoted `$` in this
# file is literal ON PURPOSE: the strings are sed scripts, awk programs and grep
# patterns whose SUBJECT is the shipped source's own text -- `case "$M" in`,
# `[ -f "$BOND_DIR/auto" ]`, `"$SVC" stop`, `$_addr:$_port`. Expanding them would
# make the harness match its own environment instead of reading the artifact, so
# every one of these sites would be a defect if it were double-quoted. All sites
# were checked individually; there is no mixed case here to fix per-site.
# shellcheck disable=SC2016
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
    rm -rf "$WORK"; mkdir -p "$WORK/etc/p5" "$WORK/run/bond" "$WORK/fakebin" \
                             "$WORK/portalbin" "$WORK/p5state"
    export ECOSIM_STATE="$WORK"
    for b in engarde-client bond-agg bond-ecod; do
        printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/$b"; chmod +x "$WORK/fakebin/$b"
    done
    echo lightning            > "$WORK/etc/p5/mode"
    echo wgclient1            > "$WORK/etc/p5/wg-logical"
    echo "203.0.113.9:51820"  > "$WORK/direct"
    echo "203.0.113.9:51820"  > "$WORK/ep"
    echo 1 > "$WORK/capable"; echo 100000 > "$WORK/rx"; echo 0 > "$WORK/tx"; echo 0 > "$WORK/hs"
    : > "$WORK/ledger"
    for s in engarde-client bond-agg bond-ecod bond-watchdog; do
        echo 0 > "$WORK/enabled.$s"; echo 0 > "$WORK/running.$s"
    done
    export PATH="$ECOBIN:$PATH"
    # U220: the fixture is etc/p5, not etc/bond. It named the OLD stack's
    # directory, which is how three foreign defaults in lib/portal-lib.sh
    # survived every run of this file: the harness exported over all of them and
    # the fixture agreed with what it exported. ROOT-1..4 below now compare the
    # SHIPPED defaults against their sources instead of trusting these exports.
    export BOND_DIR="$WORK/etc/p5"
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
    # U124: bond-xctl is a bin plus five sourced libs. The installed default is
    # /usr/lib/p5; this harness runs the shipped tree out of a worktree, so it has
    # to say where the libs are or the bin refuses to start (Layer-2 XS-1).
    export XCTL_LIB="$P5/lib"
    # U208: the old-stack quiescence checker the `old_quiescent` guard on the
    # engage row runs. INJECTED here for the same reason the Layer-2 harness
    # injects it: the shipped default is the ABSOLUTE /usr/sbin/p5-uninstall, so
    # a PATH shim can never reach it, and the guard fails CLOSED -- without this
    # every portal scenario that engages would take the guard's 127 arm and the
    # portal would look broken by a gate that is working. The shim (shared with
    # Layer-2) defaults to QUIESCENT, so every portal bar written before this
    # unit keeps its exact meaning. This is the one line U208 changes in this
    # file; the WIRING itself is measured next door in ecosim QG-1..3.
    export QUIESCE_CHECK="$ECOBIN/p5-quiescent"

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
# --- PC-1  the mode set the portal OFFERS vs the mode set bondctl ACCEPTS ----
# THE INSTRUMENT WAS STALE, NOT THE PRODUCT. This bar used to scrape one
# `case "$M" in <arm>)` line out of bondctl and compare it for EQUALITY with the
# catalogue's `implemented` rows. Both halves were wrong.
#
#  * bondctl's acceptance is DERIVED, not listed. The literal `case` arm carries
#    only this CLI's OWN modes -- `lightning|eco`, with both refusal paths going
#    through bondctl `mode_usage` -- and every other mode is delegated by the
#    DEFAULT arm of that same case, which execs the xctl bin, to bond-xctl
#    `_sched`. That is the arm which answers out of AGG_SCHED_TABLE. It is NOT
#    bondctl `_sched`: that verb exists, but its own comment says it is a
#    read-only passthrough kept for bond-ecod, and setting a mode never enters
#    it. Naming the wrong one was this round's defect. U124 moved that
#    table and its two accessors out of the bin into a library: the table is
#    deploy/p5/lib/xctl-probe.sh `AGG_SCHED_TABLE`, the accessors
#    deploy/p5/lib/xctl-probe.sh `agg_sched_of` and
#    deploy/p5/lib/xctl-probe.sh `agg_modes`, and the bin is now just the
#    dispatch -- bond-xctl `_sched` and bond-xctl `_sched_modes`.
#    THE LINE NUMBERS THAT STOOD HERE ARE GONE ON PURPOSE (U186). One of them
#    named the COMMENT above the second dispatch arm rather than an arm, U120
#    caught it by READING, and no gate could have: citation_check.py's SCOPE did
#    not list this file. It does now, so a bare number here fails the gate. The
#    anchor's guarantee is NARROWER than "a rename reddens it", and the gap is
#    MEASURED, not assumed: R2 in citation_check.py `scan` searches the WHOLE
#    target file for the backticked token, so renaming ONLY the second dispatch
#    arm leaves its name in the comment above it and the anchor stays GREEN. It
#    reddens when the name leaves the file, which is what a completed rename
#    does. That split is deliberate: a third aggregate scheduler is ONE
#    row in that table and ZERO edits in bondctl (Layer-2 AGG-L12). A one-line
#    scrape can therefore only ever see HALF the accepted set -- and this one saw
#    the wrong half anyway: the first single-line `case "$M" in` in the file is
#    the one inside bondctl `_mode_auto`, the AUTO-POLICY test.
#  * EQUALITY is not the property. ADR-003 fixes the shipped ladder and
#    the `speed` and `max` rows of catalogue/modes (named, NOT numbered -- this
#    file's own commit moves them; both reworded by U120) state the split:
#    `speed` is the ONE aggregate mode the portal OFFERS, and `max` is carried as
#    `unimplemented` ON PURPOSE -- the portal refuses it until U17b migrates a
#    stored `speed` fact -- while bondctl, whose AGG_SCHED_TABLE already has the
#    `max` row, accepts it. bondctl's accepted set is a legitimate SUPERSET.
#
# So BCTL is derived from the SAME TWO SOURCES bondctl accepts from: the literal
# case arm, PLUS the AGG_SCHED_TABLE keys read through that table's own accessor
# (`bond-xctl _sched_modes`) rather than a second copy of the word list. The
# property is CONTAINMENT, in both directions that can hurt an operator: a mode
# the portal offers as `implemented` that the executor would REFUSE (PC-1), and a
# mode the executor accepts that the catalogue has never heard of (PC-1b) -- the
# shape a new AGG_SCHED_TABLE row takes when it ships unrendered.
# The derivation is FOUR FUNCTIONS, not four inline pipelines, for one reason:
# the control bars below (PC-1c*/PC-1d*) must re-run THE SAME code against a
# mutated executor. A control that re-implements the derivation proves only that
# the copy agrees with itself.
bctl_lit() {   # $1 = bondctl -> the literal `case "$M" in` arm, `|`-separated
    awk '/^[[:space:]]*case "\$M" in[[:space:]]*$/ { b=1; next }
         b && /^[[:space:]]*[a-z][a-z|]*\)/ {
             sub(/^[[:space:]]*/, ""); sub(/\).*/, ""); print; exit }' "$1"
}
xctl_modes() { # $1 = bond-xctl, $2 = its lib dir -> the AGG_SCHED_TABLE half
    XCTL_LIB="$2" sh "$1" _sched_modes 2>/dev/null
}
accepted() {   # $1 = arm, $2 = table -> the union, one mode per line, sorted
    printf '%s\n%s\n' "$1" "$2" | tr '|' '\n' | grep -v '^[[:space:]]*$' | sort -u
}
missing() {    # $1 = set, $2 = reference -> members of $1 absent from $2
    printf '%s\n' "$1" | while read -r _m; do
        [ -n "$_m" ] || continue
        printf '%s\n' "$2" | grep -qx -- "$_m" || echo "$_m"
    done | tr '\n' ' '
}
IMPL=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/modes" \
       | awk -F'|' '$3=="implemented" && $2=="mode"{print $1}' | sort -u)
CATALL=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/modes" \
       | awk -F'|' 'NF>1{print $1}' | sort -u)
BCTL_LIT=$(bctl_lit "$P5/bondctl")
BCTL_TBL=$(xctl_modes "$P5/bond-xctl" "$P5/lib")
BCTL=$(accepted "$BCTL_LIT" "$BCTL_TBL")
if [ -n "$BCTL_LIT" ] && [ -n "$BCTL_TBL" ]; then
    ok "PC-1z both halves of bondctl's accepted set were located (arm '$BCTL_LIT', table '$BCTL_TBL')"
else
    no "PC-1z could not read bondctl's accepted set (arm '$BCTL_LIT', table '$BCTL_TBL') -- PC-1 would be vacuous"
fi
NOTACC=$(missing "$IMPL" "$BCTL")
asrt "PC-1 every catalogue-implemented mode is one bondctl accepts" "$NOTACC" ""
UNLISTED=$(missing "$BCTL" "$CATALL")
asrt "PC-1b every mode bondctl accepts has a catalogue row" "$UNLISTED" ""

# --- PC-1c / PC-1d  THE CONTROL: PC-1 and PC-1b can go RED (U120) -----------
# U95 proved this by editing AGG_SCHED_TABLE in the WORKING TREE and restoring
# it. That A/B was TRANSIENT: it left nothing behind, so nothing in the tree
# distinguishes a working PC-1 from a vacuous one, which is the same gap
# U67h/U129 both paid for. The INJ-* and PC-6 bars in this file already solve it
# with in-tree `mutate` COPIES; this is that shape for the EXECUTOR side.
#
# `xctl_mutate` copies bond-xctl AND its five libraries (U124 moved the table to
# deploy/p5/lib/xctl-probe.sh `AGG_SCHED_TABLE`) into $WORK and seds the TABLE
# LINE ONLY -- the sed anchors on that variable name, not on a line number. The
# shipped tree is never opened for writing -- PC-1e asserts that.
#
# THE NO-OP GUARD IS WHAT MAKES THESE CONTROLS AND NOT DECORATION. PC-1c0/PC-1d0
# assert the mutant's accepted set actually DIFFERS from the shipped one. Make
# either sed a no-op -- or point `xctl_mutate` at a file that no longer carries
# the table -- and PC-1c0/PC-1d0 go RED rather than the control quietly passing
# on an unmutated copy. Measured both ways, U120.
xctl_mutate() {   # $1 = name, rest = sed args applied to lib/xctl-probe.sh
    _xn="$1"; shift
    _xm="$WORK/mut-xctl-$_xn"
    rm -rf "$_xm"; mkdir -p "$_xm"
    cp "$P5/bond-xctl" "$_xm/bond-xctl"
    cp -r "$P5/lib" "$_xm/lib"
    sed "$@" "$_xm/lib/xctl-probe.sh" > "$_xm/lib/xctl-probe.sh.new" \
        && mv "$_xm/lib/xctl-probe.sh.new" "$_xm/lib/xctl-probe.sh"
    printf '%s' "$_xm"
}
# (c) DROP the `speed` row -> a mode the catalogue calls `implemented` that the
#     executor would now REFUSE. That is exactly PC-1's failure.
MX=$(xctl_mutate drop -e 's/^\(AGG_SCHED_TABLE="[^"]*\)[[:space:]]*speed:speed\(.*\)$/\1\2/')
MTBL=$(xctl_modes "$MX/bond-xctl" "$MX/lib")
if [ -n "$MTBL" ] && [ "$MTBL" != "$BCTL_TBL" ]; then
    ok "PC-1c0 MUTANT(row dropped): the executor's table really changed ('$BCTL_TBL' -> '$MTBL')"
else
    no "PC-1c0 the drop did not apply ('$BCTL_TBL' -> '$MTBL') -- PC-1c would be vacuous"
fi
has "PC-1c1 ... and the dropped mode is one the catalogue calls implemented" "$IMPL" speed
MB=$(accepted "$BCTL_LIT" "$MTBL")
asrt "PC-1c MUTANT: PC-1 goes RED -- an implemented mode the executor refuses" "$(missing "$IMPL" "$MB")" "speed "
asrt "PC-1c2 ... and PC-1b stays GREEN (the accepted set only shrank)" "$(missing "$MB" "$CATALL")" ""
# (d) ADD a row -> a mode the executor accepts that the catalogue has never heard
#     of: the shape a new AGG_SCHED_TABLE row takes when it ships unrendered.
MX=$(xctl_mutate add -e 's/^\(AGG_SCHED_TABLE="[^"]*\)"$/\1 turbo:max"/')
MTBL=$(xctl_modes "$MX/bond-xctl" "$MX/lib")
if [ -n "$MTBL" ] && [ "$MTBL" != "$BCTL_TBL" ]; then
    ok "PC-1d0 MUTANT(row added): the executor's table really changed ('$BCTL_TBL' -> '$MTBL')"
else
    no "PC-1d0 the add did not apply ('$BCTL_TBL' -> '$MTBL') -- PC-1d would be vacuous"
fi
hasnt "PC-1d1 ... and the added mode has no catalogue row" "$CATALL" turbo
MB=$(accepted "$BCTL_LIT" "$MTBL")
asrt "PC-1d MUTANT: PC-1b goes RED -- an accepted mode with no catalogue row" "$(missing "$MB" "$CATALL")" "turbo "
asrt "PC-1d2 ... and PC-1 stays GREEN (the accepted set only grew)" "$(missing "$IMPL" "$MB")" ""
# (e) the shipped tree is the thing under test, so it must come out untouched --
#     the property U95's working-tree edit could not have.
asrt "PC-1e the SHIPPED table was never edited: both controls ran on copies" \
     "$(xctl_modes "$P5/bond-xctl" "$P5/lib")" "$BCTL_TBL"

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
# SCOPE, U228: the CGI, the library AND deploy/p5/portal/bin -- the runner and
# the restore script reach the box exactly as the CGI does, and until this unit
# the scan could not have seen either of them. TWO files are exempt BY NAME
# because their job IS to issue one of the forbidden verbs, and the exemption is
# a LITERAL LIST HERE rather than a rule: adding a third exempt file means
# editing this bar, which is the same "keep the list short" mechanism the
# disruptive catalogue rows get. Each exempt file has its own static bar naming
# the only argv shapes it may carry (RS-STATIC below; E1-STATIC in U230).
PC2_EXEMPT='p5-e1-probe p5-portal-restore'
pc2_files() {   # one path per line
    printf '%s\n%s\n' "$CGI_SRC" "$LIB_SRC"
    for _p2f in "$PORTAL"/bin/*; do
        [ -f "$_p2f" ] || continue
        _p2b=${_p2f##*/}
        case " $PC2_EXEMPT " in *" $_p2b "*) continue ;; esac
        printf '%s\n' "$_p2f"
    done
}
# One file per grep (paths here may contain spaces, so the list is never
# word-split), which is why the comment filter is anchored at ^LINE: rather than
# the :LINE: form a multi-file grep prints.
pc2_hits() {   # $1 = token -> count of non-comment hits over pc2_files
    _p2h=0
    pc2_files > "$WORK/pc2.list"
    while IFS= read -r _p2n; do
        [ -n "$_p2n" ] || continue
        _p2c=$(grep -n -F -- "$1" "$_p2n" 2>/dev/null | grep -vcE '^[0-9]+:[[:space:]]*#')
        _p2h=$((_p2h + _p2c))
    done < "$WORK/pc2.list"
    printf '%s' "$_p2h"
}
bad=""
# `kill ` is new here (U228): a kill from the portal is a raw side effect on a
# process the reconciler owns, so no stop/kill verb exists in the CGI, the
# library or the runner. The one process this product may signal is the job's
# OWN group, from the restore script, off the pid in its record -- which is
# exactly why that file is exempt and pinned by RS-STATIC instead.
for t in 'autoratectl' 'uci set' 'uci commit' 'uci add' 'uci delete' '/etc/init.d/' 'sqm' 'iptables' 'wg set' 'ip route' 'agg_restart' 'eval ' 'kill '; do
    [ "$(pc2_hits "$t")" = 0 ] || bad="$bad [$t]"
done
asrt "PC-2 no forbidden verb in the portal source (cgi + lib + bin/* less the two named exemptions)" "$bad" ""
PC2_N=$(pc2_files | grep -c .)
if [ "$PC2_N" -ge 3 ]; then ok "PC-2a the scan covers $PC2_N files (cgi, lib and the unexempt bin/*)"
else no "PC-2a the scan covers only $PC2_N file(s) -- the bin/ half is not being read"; fi
# deliberately unquoted: PC2_EXEMPT is a space-separated list of bare file names
# and the split IS the count being asserted.
# shellcheck disable=SC2086
PC2_EXN=$(printf '%s\n' $PC2_EXEMPT | grep -c .)
asrt "PC-2c the exemption list is exactly two file names" "$PC2_EXN" 2
asrt "PC-2d ... and they are the two the design names" "$PC2_EXEMPT" 'p5-e1-probe p5-portal-restore'
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
for p in sources node primary server selfcheck kmwan stats; do G "q=probe&name=$p" >/dev/null; done
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
# THE ALLOWLIST IS ONE FUNCTION, not one per bar (U228). PC-5 exercises the
# CONTROLS; RUN-7 exercises the RUNNER, and both have to be judged against the
# same list or the second one silently widens the first. The runner's lines are
# added HERE for that reason: `p5-portal-run <name> <id>` is the spawn argv the
# CGI issues (both tokens from the catalogue and the clock, never from the
# request -- mutant JOB-M1 shows the other shape), `p5-accept` is the read-only
# battery, and the three p5-deadman verbs are the whole of what a disruptive row
# may ask of the rollback primitive. There is no `fire`, no delete and no kill
# verb in this list, on purpose.
led_viol() {   # $1 = ledger file -> the lines that are NOT allowlisted
    awk -v impl="$IMPLRE" '
      { if ($0 == "bondctl on") next
        if ($0 == "bondctl off") next
        if ($0 ~ ("^bondctl mode (" impl ")$")) next
        if ($0 ~ /^bond-xctl (reconcile refresh|reconcile|node|_sources|_primary|_server|selfcheck|_stats)$/) next
        if ($0 == "uci -q get kmwan.global.mode") next
        if ($0 ~ /^ubus call session get /) next
        if ($0 ~ /^p5-portal-run [a-z][a-z0-9_]* [0-9]+-[0-9]+-[a-z][a-z0-9_]*$/) next
        # U229: the CGI asks the runner for the derived bound of a disruptive
        # row, so the confirm dialog can quote a number and so the derivation has
        # exactly ONE implementation. Read-only by construction -- the arm prints
        # and exits before the catalogue name reaches a tool, a fact or a lock --
        # and its only argument is a catalogue literal, same as the spawn above.
        if ($0 ~ /^p5-portal-run --bound [a-z][a-z0-9_]*$/) next
        if ($0 == "p5-accept") next
        if ($0 ~ /^p5-deadman arm --after [0-9]+ --restore-script [^ ]+ --label portal-[a-z][a-z0-9_]*( --no-timer)?$/) next
        if ($0 ~ /^p5-deadman confirm --label portal-[a-z][a-z0-9_]*$/) next
        if ($0 == "p5-deadman status") next
        print }' "$1" | sort -u
}
VIOL=$(led_viol "$LEDGER")
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

# ============================ U220 =========================================
# DEFAULT PARITY (ROOT), EXEC BIT (XB), WRITE->RECONCILE ORDER (ORD), RE-ENGAGE
# FROM off (MODE-6), AND THE STATE ROUTE'S SELF-REPORT (ST8).
#
# WHY THIS SECTION EXISTS. Everything above ran with BOND_DIR, BONDCTL and XCTL
# EXPORTED by setup(), so every bar in this file measured the paths the HARNESS
# chose and none of them could see the paths the SHIPPED library defaults to.
# Those defaults named the OLD stack -- /etc/bond, /usr/sbin/bondctl,
# /usr/sbin/bond-xctl -- and uhttpd hands a CGI no environment, so on the box the
# defaults are what runs. /usr/sbin/bondctl exists on the client and is P2's
# engarde controller, so a shipped-as-was portal would have driven the old stack
# next to an engaged P5. The fixture directory in setup() was `etc/bond` too,
# which is why the disagreement was invisible: the harness agreed with the bug.
#
# The three defaults are ABSOLUTE paths, so no bar in a userland test tree can
# exercise them at RUN time -- creating /etc/p5 or /usr/sbin/p5 needs root, and
# RULE ZERO says a defect is proven on the argv, not by executing it. ROOT-1..3
# are therefore STATIC: each default is extracted from the shipped library by the
# same extractor used on its reference, and COMPARED against the artifact that
# owns it (the reconciler's own BOND_DIR default; the filemap destination rows).
# Nothing is restated here, so a change to either side reddens the bar.
setup

pl_default() {   # $1 = variable name, $2 = file -> that variable's ${VAR:-default}
    sed -n "s/^$1=\"\${$1:-\\([^}]*\\)}\"\$/\\1/p" "$2" | head -1
}
fm_dest() {      # $1 = a source path -> its destination row in p5/payload/filemap
    awk -F'|' -v s="$1" '$0 !~ /^[[:space:]]*#/ && $3==s {print $4; exit}' \
        "$REPO/p5/payload/filemap"
}
# THE EMPTY-vs-EMPTY GUARD. Two failed extractions compare equal, which is a bar
# that passes on nothing -- the exact shape U67h's blind seed took. Refuse first.
cmp_default() {  # $1 = bar text, $2 = the portal's default, $3 = reference, $4 = its source
    if [ -z "$2" ] || [ -z "$3" ]; then
        no "$1 (portal '$2', $4 '$3' -- one side did not extract; the bar would be vacuous)"
    else
        asrt "$1" "$2" "$3"
    fi
}
PL_BOND_DIR=$(pl_default BOND_DIR "$LIB_SRC")
PL_BONDCTL=$(pl_default BONDCTL  "$LIB_SRC")
PL_XCTL=$(pl_default XCTL        "$LIB_SRC")
cmp_default "ROOT-1 the portal's BOND_DIR default is the one every P5 owner uses" \
            "$PL_BOND_DIR" "$(pl_default BOND_DIR "$P5/bond-xctl")" "bond-xctl"
cmp_default "ROOT-2 the portal's BONDCTL default is the filemap dest of deploy/p5/bondctl" \
            "$PL_BONDCTL" "$(fm_dest deploy/p5/bondctl)" "filemap"
cmp_default "ROOT-3 the portal's XCTL default is the filemap dest of deploy/p5/bond-xctl" \
            "$PL_XCTL" "$(fm_dest deploy/p5/bond-xctl)" "filemap"
# ROOT-4: and the old directory is gone from the executable surface AND from this
# harness's own fixture. The pattern is written /etc/bon[d] so that this line does
# not match ITSELF -- a self-matching grep would make the bar permanently red.
# SCOPE, stated rather than left to be discovered: the CGI, the library, the init
# script and this file. deploy/p5/portal/catalogue/fields still carries /etc/bond
# in the `shape` row's operator LABEL; that row is U227's hunk (it also flips the
# row's stale `unbuilt` consumer), and claiming it here would collide.
ROOTBAD=$(grep -nE -- '/etc/bon[d]' "$CGI_SRC" "$LIB_SRC" "$INIT_SRC" "$HERE/run.sh" \
          | grep -vE ':[0-9]+:[[:space:]]*#' | grep -c .)
asrt "ROOT-4 no old-stack fact directory outside a comment in the CGI, the library, the init script or this harness" "$ROOTBAD" 0

# --- XB  the executable bit (U23c) ------------------------------------------
# A non-executable CGI, init script or harness is a deploy defect that ships
# green: uhttpd answers 403/500, procd never starts the listener, and the CI job
# reports nothing because nothing asserted the mode bit.
xb_one() { if [ -x "$2" ]; then ok "$1"; else no "$1 -- '$2' is not executable"; fi; }
xb_one "XB-1 the CGI is executable"          "$CGI_SRC"
xb_one "XB-2 the init script is executable"  "$INIT_SRC"
xb_one "XB-3 this harness is executable"     "$HERE/run.sh"
# U228: two more programs ship under portal/bin. The CGI execs one and
# p5-deadman execs the other after re-hashing it -- and p5-deadman REFUSES to arm
# a restore script that is not executable (its do_arm precondition), so a mode
# bit lost here is a disruptive run that cannot be rolled back.
xb_one "XB-5 the detached runner is executable"     "$PORTAL/bin/p5-portal-run"
xb_one "XB-6 the restore script is executable"      "$PORTAL/bin/p5-portal-restore"
# XB-4 COMPLETENESS, on SH-15's shape: the three bars above are a hand-written
# list, so the list itself is the thing that rots. Every shipped portal file that
# begins a program (has a shebang) must be named by one of them.
XBLIST="$CGI_SRC
$INIT_SRC
$PORTAL/bin/p5-portal-run
$PORTAL/bin/p5-portal-restore"
XBMISS=$(find "$PORTAL" -type f -exec grep -l '^#!' {} \; 2>/dev/null | sort \
         | while IFS= read -r _xf; do
             [ -n "$_xf" ] || continue
             printf '%s\n' "$XBLIST" | grep -qxF -- "$_xf" || printf '%s ' "$_xf"
           done)
asrt "XB-4 every shipped portal file with a shebang is covered by an XB bar" "$XBMISS" ""

# --- ORD  a field write is followed by a reconcile, per request (U23d) -------
# PC-5 proves MEMBERSHIP of the allowlist and nothing about ORDER: a write that
# landed in $BOND_DIR and was never reconciled passes it unchanged. So mark the
# ledger immediately before each POST and require the reconcile AFTER the mark --
# per request, because one later reconcile would otherwise satisfy every earlier
# write. The verb is pinned too: bondctl uses `reconcile refresh` for its own
# fact writes because a config change must ride the `switch` edge on an engaged
# box, and bare `reconcile` walks ENGAGE (the verify dance, onfail suspend).
setup
printf '5000 90000\n' > "$P5_STATE_DIR/floor_envelope"
: > "$LEDGER"
ORDN=0
ord_case() {   # $1 = bar text, $2 = POST body
    ORDN=$((ORDN+1))
    _mk="ORD-MARK-$ORDN"
    printf '%s\n' "$_mk" >> "$LEDGER"
    P "$2" >/dev/null
    _mi=$(grep -nxF -- "$_mk" "$LEDGER" | head -1 | cut -d: -f1)
    _ri=$(grep -nxF -- 'bond-xctl reconcile refresh' "$LEDGER" | tail -1 | cut -d: -f1)
    if [ -z "$_mi" ]; then
        no "$1 (the marker never reached the ledger -- the bar is vacuous)"
    elif [ -z "$_ri" ]; then
        no "$1 (no 'bond-xctl reconcile refresh' anywhere in the ledger)"
    elif [ "$_ri" -gt "$_mi" ]; then
        ok "$1 (mark at ledger line $_mi, reconcile refresh at $_ri)"
    else
        no "$1 (the last 'reconcile refresh' is line $_ri, at or before the mark at $_mi -- this write was never reconciled)"
    fi
}
ord_case "ORD-1 a shape write is followed by 'bond-xctl reconcile refresh'"     'k=shape&v=on'
ord_case "ORD-2 a profile write is followed by 'bond-xctl reconcile refresh'"   'k=profile&v=balanced'
ord_case "ORD-3 a floor_kbit write is followed by 'bond-xctl reconcile refresh'" 'k=floor_kbit&v=12000'
ord_case "ORD-3b a restore-to-defaults is followed by 'bond-xctl reconcile refresh'" 'k=shape&op=reset'
asrt "ORD-4 the portal issued NO bare 'bond-xctl reconcile' during those writes" \
     "$(grep -cx -- 'bond-xctl reconcile' "$LEDGER")" 0

# --- MODE-6  from node=off, selecting a bonded mode re-engages (U23g) --------
# Every MODE bar above selects from an already-on state, so the two-call sequence
# `bondctl on` then `bondctl mode <v>` -- the CGI's stated "both calls are
# level-triggered and idempotent" -- was never tested from the state MODE-5
# leaves the box in.
setup
P 'k=mode&v=direct' >/dev/null
asrt "MODE-6a the box is at node=off before the selection" "$(sh "$P5/bond-xctl" node)" off
R=$(P 'k=mode&v=eco')
asrt "MODE-6 from node=off, selecting eco applies"          "$(st "$R")" 200
asrt "MODE-6b ... and the node is engaged"                  "$(sh "$P5/bond-xctl" node)" engaged
asrt "MODE-6c ... and the mode fact is the selected value"  "$(cat "$BOND_DIR/mode")" eco
if [ -f "$BOND_DIR/auto" ]; then ok "MODE-6d ... and eco SET auto (ADR-003 §2)"
else no "MODE-6d eco did not set auto"; fi
setup
P 'k=mode&v=direct' >/dev/null
NSRC6=$(sh "$P5/bond-xctl" _sources 2>/dev/null | grep -c .)
if [ "$NSRC6" -ge 2 ]; then ok "MODE-6e0 the fixture declares $NSRC6 sources, enough for an aggregate mode"
else no "MODE-6e0 the fixture declares only $NSRC6 sources -- MODE-6e cannot engage speed"; fi
R=$(P 'k=mode&v=speed')
asrt "MODE-6e from node=off, selecting speed applies" "$(st "$R")" 200
asrt "MODE-6f ... and the node is engaged"            "$(sh "$P5/bond-xctl" node)" engaged
# MODE-6z THE CONTROL, in-tree and on a COPY: drop the `on` call and the node
# must stay off. Without this, MODE-6b passes on any box that was already
# engaged and the bar would stop measuring the moment something else engaged it.
setup
P 'k=mode&v=direct' >/dev/null
M=$(mutate mode6 -e 's#^        _out=$("$BONDCTL" on 2>&1); _rc=$?#        _out=""; _rc=0#')
if grep -q '_out=""; _rc=0' "$M/cgi/p5-portal"; then
    ok "MODE-6z0 the mutant really dropped the lifecycle call"
else
    no "MODE-6z0 the mutation did not apply -- MODE-6z proves nothing"
fi
cgi "$M" POST "" 'k=mode&v=eco' >/dev/null 2>&1
asrt "MODE-6z MUTANT with no lifecycle call: the node stays off (so MODE-6b is non-vacuous)" \
     "$(sh "$P5/bond-xctl" node)" off

# --- ST8  q=state reports what the CGI WOULD call, and who it is -------------
# The CGI's uid and PATH on GL's build are a known-unknown in the record, and the
# resolved paths are the thing U220 just changed. Both are now readable from the
# page itself, read-only, at S3 before any click -- so the S3 ground-truth run is
# one page load rather than a shell on a box with no console.
setup
R=$(G "q=state"); B=$(bd "$R")
asrt "ST8-1 q=state carries the resolved BONDCTL"  "$(jf bondctl "$B")" "$BONDCTL"
asrt "ST8-1b ... the resolved XCTL"                "$(jf xctl "$B")"    "$P_XCTL"
asrt "ST8-1c ... the portal root"                  "$(jf root "$B")"    "$PORTAL"
asrt "ST8-1d ... the uid the CGI runs as"          "$(jf uid "$B")"     "$(id -u 2>/dev/null)"
if [ -n "$(jf path "$B")" ]; then ok "ST8-1e ... and its PATH"
else no "ST8-1e q=state emitted no PATH"; fi
asrt "ST8-1f ... and that the controller it would call is executable" "$(jf bondctl_x "$B")" 1
asrt "ST8-1g ... and the reconciler it would call is executable"      "$(jf xctl_x "$B")"    1
# the negative control for the two flags: a path that is not executable reads 0,
# so "installed but not executable" is distinguishable from "fine".
: > "$WORK/notexec"; chmod -x "$WORK/notexec" 2>/dev/null
BSAVE="$BONDCTL"; BONDCTL="$WORK/notexec"
R=$(G "q=state"); B=$(bd "$R")
asrt "ST8-1h a non-executable controller reports bondctl_x=0 (the flag measures something)" \
     "$(jf bondctl_x "$B")" 0
BONDCTL="$BSAVE"

# ============================ THE PAGE SKELETON (U222) =======================
# The ids in index.html are the CONTRACT the later portal units bind to by
# getElementById (U223 logs, U224 tunnel/shaping, U226 datapath, U228 tests/
# results/disruptive). A renamed id is SILENT at runtime -- getElementById
# returns null, the card simply stays empty, and an empty card on this page
# reads as a measured zero. So it is caught statically here, and the count is
# exact: each id exactly once, and every id the page's own script binds is in
# the list. UI-2 and COEX-3 pin the two properties the design states about this
# page rather than about a card: nothing is written as markup (the second layer
# behind the CGI's escaper, INJ-2) and the page has no timer of its own (reads
# are clicks; the box emits re-anchor events natively -- design section 3).
setup
UI_IDS='authcard authnote sid authgo cards intent posrow position node auto
        modebtns fields writedetail resolved sources srcrefresh
        tunnel tunnelout qdisc qdiscout stats statsout kmwan
        logsrc logs logout probes probeout tests testsout results resultout
        disruptive disruptiveout err coex'
UI_IDS=$(printf '%s' "$UI_IDS" | tr '\n' ' ' | tr -s ' ')   # for the case match

# ui_missing WWWDIR -> the ids whose occurrence count in index.html is not 1
ui_missing() {
    _bad=""
    for _i in $UI_IDS; do
        _n=$(grep -o "id=\"$_i\"" "$1/index.html" | grep -c .)
        [ "$_n" = 1 ] || _bad="$_bad $_i($_n)"
    done
    printf '%s' "$_bad"
}
# ui_unlisted WWWDIR -> ids portal.js binds that the contract list does not carry
ui_unlisted() {
    _miss=""
    _bound=$(grep -o "getElementById('[A-Za-z0-9_]*')" "$1/portal.js" \
                | sed "s/.*('\\(.*\\)')/\\1/" | sort -u)
    for _i in $_bound; do
        case " $UI_IDS " in *" $_i "*) ;; *) _miss="$_miss $_i";; esac
    done
    printf '%s' "$_miss"
}
# ui_inner WWWDIR -> innerHTML sites that are not a comment line
ui_inner() {
    cat "$1/portal.js" "$1/index.html" | grep -n 'innerHTML' \
      | grep -vE '^[0-9]+:[[:space:]]*(\*|//|/\*|<!--)' | grep -c .
}
# ui_timers WWWDIR -> page-side timer sites
ui_timers() { cat "$1"/*.js | grep -c 'setInterval\|setTimeout'; }
# wwwmut NAME [sed args] -> a mutant COPY of www/ (the shipped tree is never touched)
wwwmut() {
    _n="$1"; shift
    _m="$WORK/mut-www-$_n"; rm -rf "$_m"; mkdir -p "$_m"
    cp "$PORTAL/www/index.html" "$PORTAL/www/portal.js" "$_m/"
    if [ $# -gt 0 ]; then
        for _f in "$_m/index.html" "$_m/portal.js"; do
            sed "$@" "$_f" > "$_f.new" && mv "$_f.new" "$_f"
        done
    fi
    printf '%s' "$_m"
}

asrt "UI-1 every contract id exists exactly once in the page" "$(ui_missing "$PORTAL/www")" ""
asrt "UI-1b every id the page's script binds is in the contract list" "$(ui_unlisted "$PORTAL/www")" ""
asrt "UI-2 no innerHTML outside the rule's own comment" "$(ui_inner "$PORTAL/www")" 0
asrt "COEX-3 the page has no timer of its own" "$(ui_timers "$PORTAL/www")" 0

# THE CONTROL: each of the three bars above can go RED. A bar that has never
# been shown to fail is a bar that would pass on an empty file.
MW=$(wwwmut idrename -e 's#id="tunnelout"#id="tunnelout9"#')
MISSED=$(ui_missing "$MW")
case "$MISSED" in
  *tunnelout*) ok "UI-1c CONTROL: one renamed id is caught ($MISSED)" ;;
  *) no "UI-1c CONTROL: a renamed id was NOT caught -- UI-1 proves nothing" ;;
esac
MW=$(wwwmut inner)
printf "document.getElementById('err').innerHTML = 'x';\n" >> "$MW/portal.js"
if [ "$(ui_inner "$MW")" -ge 1 ]; then ok "UI-2c CONTROL: an innerHTML write is caught"
else no "UI-2c CONTROL: an innerHTML write was NOT caught -- UI-2 proves nothing"; fi
MW=$(wwwmut timer)
printf "setInterval(refresh, 1000);\n" >> "$MW/portal.js"
if [ "$(ui_timers "$MW")" -ge 1 ]; then ok "COEX-3c CONTROL: a page-side timer is caught"
else no "COEX-3c CONTROL: a page-side timer was NOT caught -- COEX-3 proves nothing"; fi

# UI-3: the card ORDER is the 2am question order, and it is this unit's whole
# point -- the ids are a contract only if what surrounds them stays put. The
# order is read off the page, not restated: the sequence of contract ids as they
# appear must equal the declared sequence.
UI_ORDER='authcard cards intent modebtns fields writedetail resolved sources tunnel qdisc stats kmwan logsrc probes tests results disruptive coex'
SEEN=$(grep -o 'id="[A-Za-z0-9_]*"' "$PORTAL/www/index.html" | sed 's/id="\(.*\)"/\1/' \
       | awk -v want="$UI_ORDER" 'BEGIN{n=split(want,a," "); for(i=1;i<=n;i++) k[a[i]]=1}
                                  k[$0]{printf "%s%s", (c++?" ":""), $0}')
asrt "UI-3 the cards are in the 2am question order" "$SEEN" "$UI_ORDER"

# UI-4: no new data path. This unit added no fetch: every request the page makes
# still goes through the one req() helper, and the number of call sites is the
# shipped count. A card that starts fetching on load would also break COEX-3's
# no-timer property in spirit.
NREQ=$(grep -c 'req(' "$PORTAL/www/portal.js")
asrt "UI-4 every request still goes through the one req() helper" \
     "$(grep -c 'fetch(' "$PORTAL/www/portal.js")" 1
if [ "$NREQ" -ge 6 ]; then ok "UI-4b the req() call sites are still there ($NREQ)"
else no "UI-4b only $NREQ req( sites -- the page lost a read"; fi

# ============================ PARAMETER CONSUMERS ============================
# U227. The catalogue's `consumer` column is a CLAIM MADE TO THE OPERATOR: the
# page prints "nothing reads it yet" from it. A claim nobody measures rots in
# both directions, and it had rotted in the expensive one -- `shape` still said
# `unbuilt` for weeks after E4/U210 shipped its reader, so the page told the
# operator a working control did nothing.
#
# PC-7 is MECHANICAL and runs BOTH WAYS: consumer=built if and only if a shipped
# artifact under deploy/p5, outside the portal's own subtree, reads that fact.
# The portal is excluded because a portal that reads its own write proves
# nothing; the fact ledger and its checker are excluded for the reason the
# ledger itself gives about the acceptance runner -- a file that TALKS ABOUT the
# facts is not a consumer of them.
pc7_readers() {   # pc7_readers KEY -> reader lines in deploy/p5 outside portal/
    _k=$1; _n=0
    while IFS= read -r _f; do
        case "$_f" in
          "$PORTAL"/*|*/facts|*/test-facts.sh|*/bond-accept) continue ;;
        esac
        # The trailing class is what keeps `shape` from matching `shape_bounds`.
        _h=$(grep -nE '[$]BOND_DIR/'"$_k"'([^A-Za-z0-9_]|$)|/etc/p5/'"$_k"'([^A-Za-z0-9_]|$)' "$_f" 2>/dev/null \
             | grep -vE ':[0-9]+:[[:space:]]*#' | grep -c .)
        _n=$((_n + _h))
    done < "$WORK/pc7.files"
    printf '%s' "$_n"
}
setup
find "$P5" -type f > "$WORK/pc7.files" 2>/dev/null
PC7FILES=$(grep -c . "$WORK/pc7.files")
if [ "$PC7FILES" -ge 20 ]; then ok "FLD-1 floor: the reader sweep sees $PC7FILES files under deploy/p5"
else no "FLD-1 floor: the sweep found only $PC7FILES files -- every count below would be 0 for the wrong reason"; fi
PC7BAD=""
grep -v '^[[:space:]]*#' "$PORTAL/catalogue/fields" | grep . | cut -d'|' -f1 > "$WORK/pc7.keys"
while IFS= read -r K; do
    [ -n "$K" ] || continue
    CONS=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/fields" \
           | awk -F'|' -v k="$K" '$1==k{print $4}')
    N=$(pc7_readers "$K")
    if [ "$CONS" = built ] && [ "$N" -eq 0 ]; then
        PC7BAD="$PC7BAD $K(consumer=built, NO reader outside the portal)"
    fi
    if [ "$CONS" != built ] && [ "$N" -gt 0 ]; then
        PC7BAD="$PC7BAD $K(consumer=$CONS but $N reader line(s) exist -- a STALE marker)"
    fi
done < "$WORK/pc7.keys"
asrt "FLD-1 PC-7 consumer=built <=> a shipped reader exists, checked BOTH ways" "$PC7BAD" ""
asrt "FLD-1b ... and the instrument counts: the shape fact has readers" \
     "$( [ "$(pc7_readers shape)" -ge 1 ] && echo counts || echo BLIND )" counts
asrt "FLD-1c ... and it does not confuse a longer name: floor_kbit has none" \
     "$(pc7_readers floor_kbit)" 0

# FLD-2/3 -- the `impl` column, catalogue column 6. `balanced` is the only
# escalation profile with a derivation on record (it IS bond-ecod's shipped
# constant set); the other two are refused LOUDLY rather than written and left
# to behave like the default. Same shape as the mode set's 501.
setup
R=$(P 'k=profile&v=balanced')
asrt "FLD-2 an IMPLEMENTED enum literal applies"        "$(st "$R")" 200
asrt "FLD-2b ... and the fact carries the catalogue's literal" "$(cat "$BOND_DIR/profile")" balanced
setup
R=$(P 'k=profile&v=aggressive')
asrt "FLD-3 a literal with no derivation on record -> 501" "$(st "$R")" 501
has  "FLD-3b ... and says which class of refusal it is"    "$(bd "$R")" profile_unimplemented
if [ -f "$BOND_DIR/profile" ]; then no "FLD-3c a fact was written anyway"; else ok "FLD-3c no fact was written"; fi
R=$(P 'k=profile&v=conservative')
asrt "FLD-3d ... the other undecided name is refused identically" "$(st "$R")" 501
R=$(P 'k=shape&v=on')
asrt "FLD-3e ... and a row with NO impl column is unrestricted (every literal applies)" "$(st "$R")" 200

# FLD-4 -- the page cannot render what the CGI does not send, and a five-field
# read would have swallowed column 6 INTO the label instead.
setup
B=$(bd "$(G 'q=catalogue')")
PROFOBJ=$(printf '%s' "$B" | tr '{' '\n' | grep '"key":"profile"')
case "$PROFOBJ" in
  *'"impl":"balanced"'*) ok "FLD-4 the catalogue JSON carries impl for profile" ;;
  *) no "FLD-4 no impl field in the profile catalogue entry: [$PROFOBJ]" ;;
esac
case "$PROFOBJ" in
  *'balanced|balanced'*|*'|balanced"'*) no "FLD-4b column 6 leaked into the label: [$PROFOBJ]" ;;
  *) ok "FLD-4b ... and it did not leak into the label" ;;
esac
SHAPEOBJ=$(printf '%s' "$B" | tr '{' '\n' | grep '"key":"shape"')
case "$SHAPEOBJ" in
  *'"impl":""'*) ok "FLD-4c a row without column 6 sends an EMPTY impl (= no restriction)" ;;
  *) no "FLD-4c shape's impl is not empty: [$SHAPEOBJ]" ;;
esac


# ================= U226 -- THE DATAPATH CARD'S READ (PRB-ST) =================
# The reader itself is barred next door in the Layer-2 battery (ST-1..4). What is
# established HERE is the portal half: the enumerated `stats` row reaches
# `p5-reconciler _stats` through the CGI's fixed argv, both states arrive at the
# page intact, and the ONLY external argv a click produces is that verb -- which
# is the row PC-5's allowlist now carries.
setup
STF="$RUN_DIR/datapath.stats"
rm -f "$STF"
: > "$LEDGER"
R=$(G 'q=probe&name=stats'); B=$(bd "$R")
asrt "PRB-ST-1 no stats file -> 200, rc 0, and the page is told 'absent'" \
     "$(st "$R")|$(printf '%s' "$B" | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')|$(printf '%s' "$(jf output "$B")" | cut -d' ' -f1)" \
     "200|0|absent:"
asrt "PRB-ST-1b ... and the one external argv the click issued is the read verb" \
     "$(grep -v '^ubus ' "$LEDGER" | sort -u)" "bond-xctl _stats"

# The seeded file, in the grammar the portal plan fixes at section 9. The newline
# after the age arrives ESCAPED (the CGI's own escaper, INJ-2), so the age is
# matched as "digits followed by a NON-DIGIT" rather than against a hand-written
# backslash-n: the escape depth differs between this shell, sed and the JSON, and
# a pattern that gets it wrong matches nothing and reads as a red bar for the
# wrong reason (it did, on the first run of this block). The non-digit terminator
# is what makes `age_s=unknown` and `age_s=stale` yield the empty string, which is
# the property the bar actually needs. Link names are placeholders: nothing in the
# reader or the page tests an interface NAME (NG-1).
ST2T0=$(date +%s)
{ printf 'ts=%s up=1200 ival_ms=1000 PSTAT n=2 sched=speed depth=0 hold=7ms gate=0' "$(( ST2T0 - 100 ))"
  printf ' | linkA sent=5 kb=2048 blk=0ms bp=0 err=0 up=true\n'
  printf 'link linkA loss_pct=0.4\n'
  printf 'latency p50=absent p95=absent\n'; } > "$STF"
: > "$LEDGER"
R=$(G 'q=probe&name=stats'); B=$(bd "$R"); OUT=$(jf output "$B")
PAGEAGE=$(printf '%s' "$OUT" | sed -n 's/^age_s=\([0-9][0-9]*\)[^0-9].*/\1/p')
ST2T1=$(date +%s)
asrt "PRB-ST-2 the file is there -> 200 and a NUMERIC age reaches the page (window 100..$(( ST2T1 - ST2T0 + 100 ))s)" \
     "$(st "$R")|$(if [ -n "$PAGEAGE" ] && [ "$PAGEAGE" -ge 100 ] && [ "$PAGEAGE" -le "$(( ST2T1 - ST2T0 + 100 ))" ]
                   then echo in; else echo "out($PAGEAGE)"; fi)" "200|in"
has  "PRB-ST-2b ... and the per-link loss line survives the JSON escaper" "$OUT" 'link linkA loss_pct=0.4'
has  "PRB-ST-2c ... and the unmeasured percentiles arrive as 'absent', never as a zero" \
     "$OUT" 'latency p50=absent p95=absent'
asrt "PRB-ST-2d ... and the click still issued exactly the one read verb" \
     "$(grep -v '^ubus ' "$LEDGER" | sort -u)" "bond-xctl _stats"
rm -f "$STF"

# ============================ THE TEST RUNNER (U228) =========================
# WHAT IS BEING MEASURED HERE, AND WHY IT NEEDS ITS OWN WORLD.
#
# Every bar above drives the CGI and reads a reply. The runner is the first thing
# the portal has that OUTLIVES a reply: the CGI answers 202 and a detached
# process keeps going. Three properties follow, and none of them can be seen by
# reading a response body:
#   DETACHMENT  the answer must come back while the job is still running. Proved
#               with a FIFO -- the job BLOCKS on it until this file writes to it
#               -- and timed with /bin/sleep BY ABSOLUTE PATH, because the shim
#               first on $PATH is `exit 0` (orchestration/ecosim/p5/bin/sleep:3)
#               and a bar that used it would measure nothing at all.
#   SURVIVAL    killing the CGI's whole process group must not touch the job
#               (RUN-5), which is what `setsid` in p5_detach buys and what makes
#               uhttpd's unmeasured script timeout irrelevant.
#   ROLLBACK    a disruptive job that is killed mid-run must still be put back.
#               The harness's no-op `sleep` makes p5-deadman's timer limb fire at
#               t=0, which is not a nuisance here -- it IS the kill-mid-run bar
#               (RUN-8). The SUCCESS path is then unreachable with a live timer,
#               so it runs under P5_PORTAL_DM_TIMER=0, which passes p5-deadman's
#               own --no-timer through; RUN-11 pins that the DEFAULT argv has no
#               such flag, so this override cannot rot into the shipped shape.
#
# THE SHIPPED CATALOGUE HAS NO DISRUPTIVE ROW (U229/U230 add them), so every
# disruptive bar below runs against a FIXTURE row in a COPY of the catalogue.
# That is deliberate: the mechanism is this unit's, the rows are not, and a bar
# that waited for the rows would leave the mechanism unmeasured on the branch
# that built it.
RUNNER_SRC="$PORTAL/bin/p5-portal-run"
RESTORE_SRC="$PORTAL/bin/p5-portal-restore"
TESTS_CAT="$PORTAL/catalogue/tests"
DM_SRC="$REPO/p5/bin/p5-deadman"
# The real sleep, by absolute path. Everything that has to WAIT in this section
# uses it; $PATH's is the no-op shim and always will be.
RSLEEP=/bin/sleep
if [ -x "$RSLEEP" ]; then ok "RUN-0 /bin/sleep exists, so the timing bars below measure real time"
else no "RUN-0 no /bin/sleep: every timing bar in this section would be vacuous"; fi

# runner_world: the runner's externals, all shimmed into $WORK and all EXPORTED,
# so the CGI's own `env` invocation (which inherits the environment) passes them
# to the job without this section touching the cgi() driver at all.
runner_world() {
    mkdir -p "$WORK/results" "$WORK/run" "$WORK/portalbin" \
             "$WORK/dm/etc/p5/deadman" "$WORK/dm/etc/crontabs" "$WORK/dm/var/run/p5"
    printf 'GL-FIXTURE-MODEL\n'      > "$WORK/model"
    printf 'P5_VERSION=0.0-harness\n' > "$WORK/stamp"
    # The traversal target for RUN-4: one directory ABOVE the results store, so
    # `id=../port` reads it in a mutant that joins the request into the path.
    printf 'FIXTURE-PORT-FILE\n'     > "$WORK/port"
    export P5_PORTAL_DIR="$PORTAL"
    export P5_RESULTS_DIR="$WORK/results"
    export P5_JOB_LOCK="$WORK/run/portal.job"
    export P5_RUNNER="$WORK/portalbin/p5-portal-run"
    export P5_RESTORE="$RESTORE_SRC"
    export P5_ACCEPT="$WORK/portalbin/p5-accept"
    export P5_DEADMAN="$WORK/portalbin/p5-deadman"
    export P5_COMMON="$REPO/p5/lib/p5-common.sh"
    export P5_SYSINFO_MODEL="$WORK/model"
    export P5_STAMP_FILE="$WORK/stamp"
    # The runner wrapper: records the EXACT spawn argv the CGI issued (bar RUN-7)
    # and delegates to the shipped executor.
    cat > "$WORK/portalbin/p5-portal-run" <<EOF
#!/bin/sh
echo "p5-portal-run \$*" >> "$LEDGER"
exec sh "$RUNNER_SRC" "\$@"
EOF
    # The deadman wrapper: records the argv and roots the REAL primitive inside
    # \$WORK -- its record directory, its crontab and its \$P5_ROOT. Nothing here
    # can reach /etc/crontabs/root or /etc/p5.
    cat > "$WORK/portalbin/p5-deadman" <<EOF
#!/bin/sh
echo "p5-deadman \$*" >> "$LEDGER"
P5_ROOT="$WORK/dm"; export P5_ROOT
P5_CRONTAB="$WORK/dm/etc/crontabs/root"; export P5_CRONTAB
exec sh "$DM_SRC" "\$@"
EOF
    chmod +x "$WORK/portalbin/p5-portal-run" "$WORK/portalbin/p5-deadman"
    mk_accept fast
}

# mk_accept fifo|fast -- the ro battery's stand-in. `fifo` BLOCKS until this file
# writes to the pipe, which is how detachment is proved without a sleep.
mk_accept() {
    if [ "$1" = fifo ]; then
        rm -f "$WORK/gate"; mkfifo "$WORK/gate" 2>/dev/null
        cat > "$WORK/portalbin/p5-accept" <<EOF
#!/bin/sh
echo "p5-accept\$(test \$# -gt 0 && echo " \$*")" >> "$LEDGER"
echo "accept: phase A (live, read-only)"
cat "$WORK/gate" >/dev/null
echo "accept: 38 passed, 0 failed, 1 skipped"
exit 0
EOF
    else
        cat > "$WORK/portalbin/p5-accept" <<EOF
#!/bin/sh
echo "p5-accept\$(test \$# -gt 0 && echo " \$*")" >> "$LEDGER"
echo "accept: 38 passed, 0 failed, 1 skipped"
exit 0
EOF
    fi
    chmod +x "$WORK/portalbin/p5-accept"
}
gate_open() { printf 'go\n' 1<>"$WORK/gate" 2>/dev/null; }
gate_drop() { rm -f "$WORK/gate"; }

# await PATH TRIES -- real time, 0.2s a try.
await() {
    _aw=0
    while [ "$_aw" -lt "$2" ]; do
        [ -e "$1" ] && return 0
        "$RSLEEP" 0.2; _aw=$((_aw + 1))
    done
    [ -e "$1" ]
}
await_grep() {   # $1 = file, $2 = fixed string, $3 = tries
    _ag=0
    while [ "$_ag" -lt "$3" ]; do
        grep -qF -- "$2" "$1" 2>/dev/null && return 0
        "$RSLEEP" 0.2; _ag=$((_ag + 1))
    done
    grep -qF -- "$2" "$1" 2>/dev/null
}
li() { grep -n -F -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
# Harness-side hygiene: a FIFO-blocked job is setsid'd, so it would outlive this
# script and sit on a deleted pipe. Guarded: the pid comes from OUR lock file and
# is refused unless it is a plain number.
job_cleanup() {
    _jc=$(cat "$WORK/run/portal.job/pid" 2>/dev/null)
    case "${_jc:-}" in ''|*[!0-9]*) return 0 ;; esac
    kill -KILL "-$_jc" 2>/dev/null
    return 0
}

# fixcat -- a COPY of the catalogue carrying ONE disruptive row. Head ACCEPT so
# the fixture blocks on the FIFO exactly like the real battery would, class
# disruptive so the runner takes the pre-state/arm/restore path, and bound 1s
# because a disruptive row MUST declare one (the runner refuses a row that does
# not) and 1 s is the shortest deadline this file can then let pass in real time.
FIXNAME=fixture_roundtrip
fixcat() {
    _fc="$WORK/fixcat"; rm -rf "$_fc"; mkdir -p "$_fc"
    cp "$PORTAL/catalogue/fields" "$PORTAL/catalogue/modes" \
       "$PORTAL/catalogue/probes" "$PORTAL/catalogue/tests" "$_fc/"
    printf '%s|disruptive|ACCEPT|1|FIXTURE ONLY: bounded 1s; exercises the disruptive limbs against the FIFO shim.\n' \
        "$FIXNAME" >> "$_fc/tests"
    printf '%s' "$_fc"
}
mk_id() {   # $1 = name -> an id of the shipped grammar, built the same way
    _mu=$(cut -d' ' -f1 /proc/uptime); _ms=${_mu%%.*}; _mf=${_mu#*.}
    printf '%s-%s%s-%s' "$(date -u '+%s')" "$_ms" "$_mf" "$1"
}
dis_run() {   # $1 = id, $2 = catalogue dir, $3 = P5_PORTAL_DM_TIMER
    env P5_PORTAL_DIR="$PORTAL" P5_CAT_DIR="$2" XCTL="$P_XCTL" \
        P5_PORTAL_DM_TIMER="$3" \
        setsid sh "$RUNNER_SRC" "$FIXNAME" "$1" >/dev/null 2>&1 &
}

# binmut NAME [sed args] -> a portal ROOT whose bin/ is mutated (the shipped tree
# is never touched; mutate() above does the same for cgi/lib).
binmut() {
    _bn="$1"; shift
    _bm="$WORK/mut-bin-$_bn"; rm -rf "$_bm"; mkdir -p "$_bm"
    cp -r "$PORTAL/cgi" "$PORTAL/lib" "$PORTAL/catalogue" "$PORTAL/bin" "$_bm/"
    for _bf in "$_bm/bin/p5-portal-run" "$_bm/bin/p5-portal-restore"; do
        sed "$@" "$_bf" > "$_bf.new" && mv "$_bf.new" "$_bf" && chmod +x "$_bf"
    done
    printf '%s' "$_bm"
}

# --- RUN-C: the catalogue is closed -----------------------------------------
BADH=$(grep -v '^[[:space:]]*#' "$TESTS_CAT" \
       | awk -F'|' 'NF>1 && $3!="ACCEPT" && $3!="XCTL_TICK" && $3!="ROUNDTRIP_LIFECYCLE" && $3!="ROUNDTRIP_MODE" && $3!="E1" {print $3}')
asrt "RUN-C1 every test head is in the DESIGN's closed symbol set (U228 shipped ACCEPT/XCTL_TICK, U229 adds ROUNDTRIP_LIFECYCLE/ROUNDTRIP_MODE; E1 stays reserved for U230 -- RUN-C1b counts the four shipped heads)" "$BADH" ""
RUNHEADS=$(grep -cE '^  (ACCEPT|XCTL_TICK|ROUNDTRIP_LIFECYCLE|ROUNDTRIP_MODE)\)' "$RUNNER_SRC")
# U229 raised this from 2 to 4 WITH the two arms it added. The number is the
# point: RUN-C1 compares the catalogue against a symbol set written in THIS file,
# and if the runner's own case were to shrink back the comparison would be
# against a fiction. U230's E1 arm raises it to 5.
if [ "$RUNHEADS" -ge 4 ]; then ok "RUN-C1b the runner's own case names $RUNHEADS heads, so the set above is not a fiction"
else no "RUN-C1b the runner's head case names only $RUNHEADS of the heads RUN-C1 allows -- RUN-C1 is comparing against a fiction"; fi
# RUN-C2 "keep the disruptive list short", mechanised: the set of disruptive rows
# in the shipped catalogue must equal the LITERAL written here, in file order. It
# was EMPTY on U228's branch; U229 added the two lifecycle round trips and had to
# edit this line to do it, and U230 has to edit it again to add `e1`. A row that
# arrives without a bar author noticing is exactly what this refuses.
DIS_WANT='lifecycle_roundtrip mode_roundtrip'
DIS_GOT=$(grep -v '^[[:space:]]*#' "$TESTS_CAT" | awk -F'|' '$2=="disruptive"{printf "%s ",$1}')
DIS_GOT=${DIS_GOT% }
asrt "RUN-C2 the shipped disruptive set is exactly the literal this bar names" "$DIS_GOT" "$DIS_WANT"
# RUN-C3: a disruptive row must say what it disturbs and for how long. Vacuous
# while the set is empty, so it says so rather than printing a green square.
DIS_N=$(grep -v '^[[:space:]]*#' "$TESTS_CAT" | awk -F'|' '$2=="disruptive"' | grep -c .)
if [ "$DIS_N" = 0 ]; then
    ok "RUN-C3 no disruptive row ships yet, so there is no label to check (U229/U230 bring the rows AND the check's subject)"
else
    # A DECLARED bound is either a literal number of seconds or the symbol
    # `DERIVED` (U229), which is the row saying "this window is not an opinion --
    # compute it from the installed sources". What is refused is a row with an
    # EMPTY column 4, or one whose label is too short to describe a disturbance.
    # `DERIVED` is not a loophole: DIS-5 recomputes the number the runner
    # produces for such a row out of the DAG, xctl-dag.sh and the watchdog.
    DIS_BAD=$(grep -v '^[[:space:]]*#' "$TESTS_CAT" \
              | awk -F'|' '$2=="disruptive" && ($4 !~ /^([0-9]+|DERIVED)$/ || length($5) < 40){print $1}')
    asrt "RUN-C3 every disruptive row declares a bound (seconds or DERIVED) and a label that describes the disturbance" "$DIS_BAD" ""
fi

# --- RUN-1 / RUN-2: detachment, and one job at a time ------------------------
setup; runner_world; mk_accept fifo
: > "$LEDGER"
rm -f "$WORK/late"
( "$RSLEEP" 1; : > "$WORK/late" ) &
LATEP=$!
R=$(P 'k=run&name=accept'); B=$(bd "$R")
if [ -f "$WORK/late" ]; then
    no "RUN-1 the CGI did not answer within 1 s -- the job is NOT detached (it ran in the request)"
else
    ok "RUN-1 the CGI answered while the job was still blocked on the FIFO, inside 1 s (measured with /bin/sleep, not the shim)"
fi
[ -n "${LATEP:-}" ] && kill "$LATEP" 2>/dev/null
asrt "RUN-1a ... with 202 Accepted" "$(st "$R")" 202
RID=$(jf id "$B")
RIDOK=$(printf '%s' "$RID" | grep -cE '^[0-9]+-[0-9]+-accept$')
asrt "RUN-1b ... and an id of the declared grammar <epoch>-<uptime>-<name>" "$RIDOK" 1
await "$WORK/results/$RID.part" 50
if [ -f "$WORK/results/$RID.part" ]; then ok "RUN-1c the artifact exists as .part while the job runs"
else no "RUN-1c no .part artifact appeared for $RID"; fi
hasnt "RUN-1d ... and it carries NO end marker yet" "$(cat "$WORK/results/$RID.part" 2>/dev/null)" '### ended'
R2=$(P 'k=run&name=accept')
asrt "RUN-2 a second POST while that job runs -> 409" "$(st "$R2")" 409
has  "RUN-2b ... and says which job holds the slot" "$(bd "$R2")" '"error":"busy"'
asrt "RUN-2c ... naming the running test" "$(jf name "$(bd "$R2")")" accept
# release the FIFO: the job finishes, and only then is there a .txt
gate_open
await "$WORK/results/$RID.txt" 100
A=$(cat "$WORK/results/$RID.txt" 2>/dev/null)
has "RUN-1e the finished artifact carries the job header"   "$A" "### job accept id=$RID class=ro"
has "RUN-1f ... the box and version lines"                  "$A" '### box GL-FIXTURE-MODEL'
has "RUN-1g ... the sha256 of the runner and the tool"      "$A" '### sha256 '
has "RUN-1h ... the tool's own output"                      "$A" '38 passed, 0 failed'
has "RUN-1i ... and the end marker"                         "$A" '### ended '
SHAOK=$(printf '%s' "$A" | sed -n 's/^### sha256 \([0-9a-f]*\) .*/\1/p' | head -1)
if command -v sha256sum >/dev/null 2>&1; then
    asrt "RUN-1j the header's runner sha is p5_hash's (SH-19: this product has ONE sha256)" \
         "$SHAOK" "$(sha256sum "$RUNNER_SRC" | cut -d' ' -f1)"
else
    no "RUN-1j no sha256sum on this host, so the header's sha cannot be checked against an independent one"
fi
RES=$(G 'q=results'); RB=$(bd "$RES")
has "RUN-1k q=results reports it DONE" "$RB" '"status":"DONE"'
RTXT=$(G "q=result&id=$RID")
has "RUN-1l q=result serves the artifact as text/plain"     "$RTXT" 'Content-Type: text/plain'
has "RUN-1m ... with nosniff and a locked-down CSP"         "$RTXT" 'X-Content-Type-Options: nosniff'
has "RUN-1n ... and the body is the file"                   "$(bd "$RTXT")" '### ended '
job_cleanup; gate_drop

# --- RUN-3: a job that dies leaves INCOMPLETE, and frees the slot ------------
setup; runner_world; mk_accept fifo
: > "$LEDGER"
R=$(P 'k=run&name=accept'); KID=$(jf id "$(bd "$R")")
await "$WORK/results/$KID.part" 50
KPID=$(cat "$WORK/run/portal.job/pid" 2>/dev/null)
case "${KPID:-}" in
  ''|*[!0-9]*) no "RUN-3 the lock carries no usable pid, so nothing can be killed and the bar is vacuous" ;;
  *) kill -KILL "-$KPID" 2>/dev/null
     _w=0; while [ "$_w" -lt 50 ] && [ -d "/proc/$KPID" ]; do "$RSLEEP" 0.2; _w=$((_w+1)); done
     if [ -d "/proc/$KPID" ]; then no "RUN-3 the job group survived the kill -- the rest of this scenario means nothing"
     else ok "RUN-3 the job group is gone (killed mid-run, holding the FIFO)"; fi ;;
esac
if [ -f "$WORK/results/$KID.txt" ]; then no "RUN-3a a killed job still produced a .txt -- the footer is not what marks an end"
else ok "RUN-3a the artifact is still .part: no footer was written, so the run is INCOMPLETE"; fi
RB=$(bd "$(G 'q=results')")
has "RUN-3b q=results reports it INCOMPLETE" "$RB" '"status":"INCOMPLETE"'
gate_drop
mk_accept fast
R=$(P 'k=run&name=accept')
asrt "RUN-3c the next POST takes the STALE lock over -> 202" "$(st "$R")" 202
await "$WORK/results/$(jf id "$(bd "$R")").txt" 100
job_cleanup

# --- RUN-4: an id is a matched listing entry, never a path -------------------
setup; runner_world
R=$(G 'q=result&id=1-1-nosuch')
asrt "RUN-4 q=result with an id that is not in the listing -> 400" "$(st "$R")" 400
has  "RUN-4a ... and names the reason" "$(bd "$R")" unknown_result
R=$(G 'q=result&id=..%2Fport')
asrt "RUN-4b a traversal id -> 400"    "$(st "$R")" 400
hasnt "RUN-4c ... and nothing outside the store was read" "$(bd "$R")" 'FIXTURE-PORT-FILE'
# THE CONTROL: a mutant that joins the request's id into the path reads the file
# one level above the store. Without this, RUN-4b would pass on a route that
# never opens anything at all.
M=$(mutate run4 \
    -e 's#^    _rid=$(p5_match_literal .*#    _rid=$(p5_arg id)#' \
    -e 's#^    _rp=$(p5_result_path "$_rid")#    _rp="$P5_RESULTS_DIR/$_rid"#')
if grep -q '_rp="$P5_RESULTS_DIR/$_rid"' "$M/cgi/p5-portal"; then
    ok "RUN-4d the mutant really joins the request into the path"
else
    no "RUN-4d the mutation did not apply -- RUN-4b/4c prove nothing"
fi
MR=$(cgi "$M" GET 'q=result&id=..%2Fport' "")
has "RUN-4e MUTANT: the traversal reads the fixture file one level above the store" "$(bd "$MR")" 'FIXTURE-PORT-FILE'

# --- RUN-5: the CGI's process group is killed after 202 ----------------------
# uhttpd kills a CGI at its script timeout, and that timeout is UNVERIFIED on
# GL's build. The job must not be in that group.
setup; runner_world; mk_accept fifo
cat > "$WORK/post5" <<EOF
#!/bin/sh
B='k=run&name=accept'
printf '%s' "\$B" | env P5_PORTAL_DIR="$PORTAL" P5_CAT_DIR="$PORTAL/catalogue" \\
  BOND_DIR="$BOND_DIR" P5_STATE_DIR="$P5_STATE_DIR" BONDCTL="$BONDCTL" \\
  XCTL="$P_XCTL" UCI="$P_UCI" UBUS="$P_UBUS" \\
  REQUEST_METHOD=POST QUERY_STRING= CONTENT_LENGTH=\$(printf '%s' "\$B" | wc -c | tr -d ' ') \\
  HTTP_X_P5_SESSION="$GOODSID" sh "$PORTAL/cgi/p5-portal" > "$WORK/r5.out" 2>/dev/null
EOF
chmod +x "$WORK/post5"
setsid sh "$WORK/post5" & CGIP=$!
await "$WORK/run/portal.job/id" 100
JID=$(cat "$WORK/run/portal.job/id" 2>/dev/null)
case "${CGIP:-}" in
  ''|*[!0-9]*) no "RUN-5 could not start the CGI in its own group -- vacuous" ;;
  *) kill -KILL "-$CGIP" 2>/dev/null; ok "RUN-5 the CGI's whole process group was killed after the 202" ;;
esac
gate_open
if [ -n "${JID:-}" ] && await "$WORK/results/$JID.txt" 150; then
    ok "RUN-5a the job completed anyway: it is not in the request's process group"
else
    no "RUN-5a the job did not complete after its CGI's group was killed -- the detach does not survive uhttpd"
fi
has "RUN-5b ... and the artifact is whole" "$(cat "$WORK/results/$JID.txt" 2>/dev/null)" '### ended '
job_cleanup; gate_drop

# --- RUN-6: the two executables carry no box-mutating token ------------------
# Distinct from PC-2: PC-2 scans the unexempt files for the CONTROLLER verbs;
# this names the four the design calls out for the runner plus `/tmp`, and it
# scans the EXEMPT restore script too -- the exemption is about `kill` and `ip
# route`, not about these.
r6=""
for t in '/tmp' '/etc/init.d/' 'uci set' 'wg set' 'tc qdisc replace' 'tc qdisc del'; do
    for f in "$RUNNER_SRC" "$RESTORE_SRC"; do
        grep -n -F -- "$t" "$f" 2>/dev/null | grep -vqE '^[0-9]+:[[:space:]]*#' && r6="$r6 [$t]"
    done
done
asrt "RUN-6 neither bin file carries /tmp, an init-script action, a uci/wg write or a tc qdisc verb" "$r6" ""
# The ONE /tmp path the portal has is the vendor's own model file, and it is a
# READ, declared in the library where the two executables above cannot be
# accused of it. Named here so the exemption is visible rather than implied.
TMPLIB=$(grep -n '/tmp' "$LIB_SRC" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -c .)
asrt "RUN-6a the library's only /tmp site is one line" "$TMPLIB" 1
has  "RUN-6b ... and it is the P5_SYSINFO_MODEL default (a read of OpenWrt's own identity file)" \
     "$(grep '/tmp' "$LIB_SRC" | grep -v '^[[:space:]]*#')" 'P5_SYSINFO_MODEL='

# --- RS-STATIC: the restore script's permitted argv shapes -------------------
# p5-portal-restore is PC-2-exempt BY NAME, so what it may issue is pinned here.
RSK=$(grep -n 'kill ' "$RESTORE_SRC" | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -vcE 'kill -(TERM|KILL) "?-\$PID"?')
asrt "RS-STATIC-1 every kill site in the restore script is -TERM/-KILL of the job GROUP named by its record's pid" "$RSK" 0
RSKN=$(grep -cE 'kill -(TERM|KILL) "-\$PID"' "$RESTORE_SRC")
if [ "$RSKN" -ge 1 ]; then ok "RS-STATIC-1b ... and there is at least one such call ($RSKN), so RS-STATIC-1 is not passing on an empty set"
else no "RS-STATIC-1b the restore script issues no group kill at all"; fi
RSIP=$(grep -n '^[^#]*ip route' "$RESTORE_SRC" | grep -vcE 'ip route (del|add) ')
asrt "RS-STATIC-2 every ip-route site (none until U230) is a del or an add" "$RSIP" 0
RSCTL=$(grep -nE '^[^#]*"\$BONDCTL" ' "$RESTORE_SRC" | grep -vcE '"\$BONDCTL" (on|off|mode)([; ]|$)')
asrt "RS-STATIC-3 the controller is only ever called with on|off|mode" "$RSCTL" 0
RSX=$(grep -nE '^[^#]*"\$XCTL" ' "$RESTORE_SRC" | grep -vcE '"\$XCTL" (reconcile|node)([; ]|$)')
asrt "RS-STATIC-4 the reconciler is only ever called with reconcile|node" "$RSX" 0
RSF=""
for t in '/tmp' '/etc/init.d/' 'uci set' 'wg set' 'iptables' 'eval ' 'sqm'; do
    grep -n -F -- "$t" "$RESTORE_SRC" | grep -vqE '^[0-9]+:[[:space:]]*#' && RSF="$RSF [$t]"
done
asrt "RS-STATIC-5 and none of the forbidden verbs is in it either" "$RSF" ""

# --- RUN-7: the runtime ledger over a RUN, judged by PC-5's own allowlist -----
setup; runner_world
: > "$LEDGER"
R=$(P 'k=run&name=accept'); RID7=$(jf id "$(bd "$R")")
await "$WORK/results/$RID7.txt" 150
R=$(P 'k=run&name=converged_tick'); RID7b=$(jf id "$(bd "$R")")
await "$WORK/results/$RID7b.txt" 150
V7=$(led_viol "$LEDGER")
asrt "RUN-7 every argv the runner path issued is in the allowlist" "$V7" ""
has "RUN-7a the ledger carries the EXACT spawn argv the CGI issued" "$(cat "$LEDGER")" "p5-portal-run accept $RID7"
N7=$(grep -c . "$LEDGER")
if [ "$N7" -ge 4 ]; then ok "RUN-7b the ledger is non-empty ($N7 invocations)"
else no "RUN-7b the ledger has $N7 lines -- RUN-7 is judging nothing"; fi
has "RUN-7c converged_tick really ran three reconciles" \
    "$(cat "$WORK/results/$RID7b.txt" 2>/dev/null)" '--- reconcile 3 of 3'

# --- JOB-M1 / JOB-M2: the two naive shapes of "run a named test" -------------
setup; runner_world
rm -f "$WORK/M1"
M=$(mutate jobm1 \
    -e 's#^    _tn=$(p5_match_literal .*#    _tn="$_want"#' \
    -e 's#^      \*) p5_die "500 Internal Server Error" bad_class ;;#      *) ;;#' \
    -e 's#^    if ! p5_detach "$P5_RUNNER" "$_tn" "$_id"; then#    sh -c "$P5_RUNNER $_tn $_id" >/dev/null 2>\&1 \&\n    if false; then#')
if grep -q 'sh -c "$P5_RUNNER $_tn $_id"' "$M/cgi/p5-portal"; then
    ok "JOB-M1a the mutant really interpolates the request's name into a command line"
else
    no "JOB-M1a the mutation did not apply -- JOB-M1 proves nothing"
fi
cgi "$M" POST "" "k=run&name=accept;touch $WORK/M1" >/dev/null 2>&1
"$RSLEEP" 1
if [ -f "$WORK/M1" ]; then ok "JOB-M1b MUTANT: the request's own bytes executed (the file it named exists)"
else no "JOB-M1b the mutant did not execute the injected token; JOB-M1c would be vacuous"; fi
rm -f "$WORK/M1"
R=$(P "k=run&name=accept;touch $WORK/M1")
asrt "JOB-M1c SHIPPED: the same request is 400" "$(st "$R")" 400
has  "JOB-M1d ... unknown_test, and the bytes never reached a command line" "$(bd "$R")" unknown_test
"$RSLEEP" 1
if [ -f "$WORK/M1" ]; then no "JOB-M1e the shipped CGI executed the injected token"
else ok "JOB-M1e ... and nothing was executed"; fi

# JOB-M2: the runner without its closed head case runs whatever the catalogue
# names. The fixture catalogue row is what a corrupted or edited catalogue would
# look like; the shipped runner must refuse it and write nothing.
setup; runner_world
rm -f "$WORK/M2"
printf '#!/bin/sh\ntouch "%s"\n' "$WORK/M2" > "$WORK/evil"; chmod +x "$WORK/evil"
EVCAT="$WORK/evilcat"; rm -rf "$EVCAT"; mkdir -p "$EVCAT"
cp "$PORTAL/catalogue/"* "$EVCAT/"
printf 'evil|ro|%s||FIXTURE: a head that is a PATH, which is what the closed case exists to refuse.\n' "$WORK/evil" >> "$EVCAT/tests"
MB=$(binmut jobm2 -e 's#^  \*)         echo "p5-portal-run: unknown head .*#  *)         TOOL="$HEAD" ;;#' \
                  -e 's#^        echo "p5-portal-run: unknown head .$HEAD."; return 2 ;;#        "$HEAD" ;;#')
if grep -q 'TOOL="$HEAD"' "$MB/bin/p5-portal-run"; then
    ok "JOB-M2a the mutant runner really resolves its program from the catalogue"
else
    no "JOB-M2a the mutation did not apply -- JOB-M2 proves nothing"
fi
env P5_PORTAL_DIR="$MB" P5_CAT_DIR="$EVCAT" XCTL="$P_XCTL" \
    sh "$MB/bin/p5-portal-run" evil "$(mk_id evil)" >/dev/null 2>&1
if [ -f "$WORK/M2" ]; then ok "JOB-M2b MUTANT: a catalogue-supplied head executed"
else no "JOB-M2b the mutant did not run the catalogue's head; JOB-M2c would be vacuous"; fi
rm -f "$WORK/M2"
env P5_PORTAL_DIR="$PORTAL" P5_CAT_DIR="$EVCAT" XCTL="$P_XCTL" \
    sh "$RUNNER_SRC" evil "$(mk_id evil)" >/dev/null 2>&1; M2RC=$?
asrt "JOB-M2c SHIPPED: the same row is refused"      "$M2RC" 2
if [ -f "$WORK/M2" ]; then no "JOB-M2d the shipped runner executed the catalogue's head"
else ok "JOB-M2d ... and the head was never executed"; fi

# --- RUN-8: armed BEFORE the tool, killed mid-run, put back ------------------
setup; runner_world; mk_accept fifo
FIX=$(fixcat)
: > "$LEDGER"; : > "$WORK/ledger"
D8=$(mk_id "$FIXNAME")
dis_run "$D8" "$FIX" 1
# WHAT FIRES THE DEADMAN HERE, said plainly. The harness's `sleep` is a no-op
# (orchestration/ecosim/p5/bin/sleep:3), so the timer limb's sleeper wakes
# `check` at t=0 -- BEFORE the 1 s deadline -- and correctly does nothing. So
# this bar lets the declared bound pass in real time and calls `check` itself,
# which is the SAME code path all three limbs share (p5-deadman's own header
# says so, and DM-30..DM-33 own the SCHEDULING half next door). What is being
# measured here is the portal's side: that a record existed before the tool
# started, that firing kills the job's own group, replays the intent and clears
# the record, and that the artifact is left INCOMPLETE.
if await "$WORK/results/$D8.meta" 200 && await "$WORK/dm/etc/p5/deadman/portal-$FIXNAME" 200; then
    ok "RUN-8x the job wrote its pre-state record and ARMED before anything below runs"
else
    no "RUN-8x no job record or no armed deadman appeared -- nothing below this line has a subject"
fi
# Past the row's declared bound, measured from the moment the record EXISTS (the
# deadline is written at arm time, not at spawn time).
"$RSLEEP" 1.5
env P5_PORTAL_DIR="$PORTAL" XCTL="$P_XCTL" sh "$WORK/portalbin/p5-deadman" check >/dev/null 2>&1
if await_grep "$WORK/ledger" 'kill -TERM -' 200; then
    ok "RUN-8 the deadman fired mid-run and the restore issued the group kill"
else
    no "RUN-8 no group kill was logged: the record never fired, or the restore never ran"
fi
D8PID=$(sed -n 's/^P5_PORTAL_PID=//p' "$WORK/results/$D8.meta" 2>/dev/null | head -1)
has "RUN-8a ... the pid it killed is the one in the job's own record" \
    "$(cat "$WORK/ledger")" "kill -TERM -$D8PID"
# THE LOG LINE IS NOT THE KILL. Before this bar existed the restore logged a
# group kill it had not performed: `kill -- "-$PID"` is the POSIX UTILITY argv
# and NEITHER dash NOR busybox ash accepts it in the shell BUILTIN (measured
# 2026-09-05: "Illegal number: -" and "invalid number '--'"), so the call failed
# and the job ran on. Every other assertion in this scenario passed through that,
# because the job was blocked on a FIFO and looked killed. So assert the EFFECT.
_w=0
while [ "$_w" -lt 100 ] && [ -n "${D8PID:-}" ] && [ -d "/proc/$D8PID" ]; do "$RSLEEP" 0.2; _w=$((_w+1)); done
if [ -n "${D8PID:-}" ] && [ -d "/proc/$D8PID" ]; then
    no "RUN-8a2 the job group is STILL RUNNING after the rollback logged a kill -- the kill argv is wrong for this shell"
else
    ok "RUN-8a2 ... and the job group is actually gone (the effect, not just the log line)"
fi
A_I=$(li "$LEDGER" 'p5-deadman arm '); T_I=$(li "$LEDGER" 'p5-accept')
if [ -n "$A_I" ] && [ -n "$T_I" ] && [ "$A_I" -lt "$T_I" ]; then
    ok "RUN-8b the record existed BEFORE the tool started (arm at ledger line $A_I, tool at $T_I)"
else
    no "RUN-8b the arm is not before the tool (arm='${A_I:-none}' tool='${T_I:-none}') -- there is a window in which the box is disturbed and nothing owes a rollback"
fi
await_grep "$LEDGER" 'bond-xctl reconcile' 100
has "RUN-8c the rollback replayed the lifecycle intent through the controller" "$(cat "$LEDGER")" 'bondctl off'
has "RUN-8d ... the mode intent"                                              "$(cat "$LEDGER")" 'bondctl mode '
has "RUN-8e ... and asked the reconciler to derive the edge"                  "$(cat "$LEDGER")" 'bond-xctl reconcile'
_w=0; while [ "$_w" -lt 100 ] && [ -e "$WORK/dm/etc/p5/deadman/portal-$FIXNAME" ]; do "$RSLEEP" 0.2; _w=$((_w+1)); done
if [ -e "$WORK/dm/etc/p5/deadman/portal-$FIXNAME" ]; then
    no "RUN-8f the deadman record is still armed after a successful restore"
else
    ok "RUN-8f the record was cleared: the rollback returned 0 and nothing is still owed"
fi
if [ -f "$WORK/results/$D8.txt" ]; then no "RUN-8g a job killed mid-run produced a .txt"
else ok "RUN-8g the artifact stays .part -- the run reads INCOMPLETE, which is what happened"; fi
job_cleanup; gate_drop
# RUN-11 rides the same run: the DEFAULT arm carries no --no-timer.
ARMLINE=$(grep -F 'p5-deadman arm ' "$LEDGER" | head -1)
hasnt "RUN-11 the default arm argv carries no --no-timer" "$ARMLINE" '--no-timer'
has   "RUN-11a ... and it pins the restore SCRIPT (sha-checked at fire), not a command string" "$ARMLINE" '--restore-script '
has   "RUN-11b ... with the bound the catalogue row declares"  "$ARMLINE" '--after 1 '

# --- RUN-9: a tampered restore script is refused, and the record is KEPT ------
# The pin is p5-deadman's, over THIS unit's script. Armed against a COPY so the
# shipped file is never written to.
setup; runner_world
cp "$RESTORE_SRC" "$WORK/restore-copy"; chmod +x "$WORK/restore-copy"
: > "$LEDGER"; : > "$WORK/ledger"
sh "$WORK/portalbin/p5-deadman" arm --after 0 --restore-script "$WORK/restore-copy" \
   --label portal-tamper --no-timer >/dev/null 2>&1
if [ -f "$WORK/dm/etc/p5/deadman/portal-tamper" ]; then ok "RUN-9 the record armed, sha-pinned to the restore script"
else no "RUN-9 the record did not arm -- the tamper bar has no subject"; fi
printf '# tampered\n' >> "$WORK/restore-copy"
CHKOUT=$(sh "$WORK/portalbin/p5-deadman" check 2>&1); CHKRC=$?
has "RUN-9a the deadman refuses to run a restore whose sha changed" "$CHKOUT" 'sha CHANGED'
if [ -f "$WORK/dm/etc/p5/deadman/portal-tamper" ]; then ok "RUN-9b ... and the record is KEPT armed (rc=$CHKRC): nothing was rolled back and nothing was silently retired"
else no "RUN-9b the record was dropped after a refused restore -- a rollback that never happened would be gone"; fi
hasnt "RUN-9c ... and the tampered script never ran" "$(cat "$LEDGER")" 'bondctl'
rm -f "$WORK/dm/etc/p5/deadman/portal-tamper"

# --- RUN-10: no job record -> reconcile only ---------------------------------
setup; runner_world
: > "$LEDGER"; : > "$WORK/ledger"
env P5_PORTAL_DIR="$PORTAL" XCTL="$P_XCTL" sh "$RESTORE_SRC" >/dev/null 2>&1; R10=$?
asrt "RUN-10 with no unfinished job record the restore exits 0"    "$R10" 0
has   "RUN-10a ... having asked the reconciler to converge to the stored facts" "$(cat "$LEDGER")" 'bond-xctl reconcile'
hasnt "RUN-10b ... and replayed no intent it does not have"        "$(cat "$LEDGER")" 'bondctl '
# node == desired, where desired is derived HERE from the rc fact (presence-only,
# xctl-probe.sh desired()) -- the restore script does not carry a second copy of
# that rule, and it must not.
if [ -f "$BOND_DIR/rc" ]; then WANT10=engaged; else WANT10=off; fi
asrt "RUN-10c ... and the node the reconciler converged to is the one the facts ask for" \
     "$(sh "$P5/bond-xctl" node)" "$WANT10"

# --- RUN-12: the success path confirms and leaves nothing armed --------------
setup; runner_world; mk_accept fast
FIX=$(fixcat)
: > "$LEDGER"; : > "$WORK/ledger"
D12=$(mk_id "$FIXNAME")
dis_run "$D12" "$FIX" 0
if await "$WORK/results/$D12.txt" 200; then ok "RUN-12 the disruptive success path ran to its footer"
else no "RUN-12 the job never finished under P5_PORTAL_DM_TIMER=0"; fi
A12=$(cat "$WORK/results/$D12.txt" 2>/dev/null)
has "RUN-12a the artifact records the pre-state it will replay" "$A12" '### pre rc='
has "RUN-12b ... the restore came back ok"                      "$A12" 'restore=ok'
has "RUN-12c ... and the deadman was confirmed"                 "$A12" 'deadman=confirmed'
if [ -e "$WORK/dm/etc/p5/deadman/portal-$FIXNAME" ]; then
    no "RUN-12d a confirmed record is still on disk -- the box would roll itself back later for no reason"
else
    ok "RUN-12d nothing is left armed"
fi
has "RUN-12e the arm carried --no-timer, which is the ONLY thing the override changes" \
    "$(grep -F 'p5-deadman arm ' "$LEDGER" | head -1)" '--no-timer'
V12=$(led_viol "$LEDGER")
asrt "RUN-12f and the whole disruptive path stayed inside the allowlist" "$V12" ""
job_cleanup

# ============ U229: THE TWO DISRUPTIVE ROUND TRIPS ===========================
# WHAT IS NEW HERE. U228 built the disruptive MECHANISM and measured it against a
# fixture row. These are the first disruptive rows that SHIP, so what is measured
# below is not the mechanism again but the two arms themselves: the ORDER of the
# fact writes, that the box is left exactly as it was found, that a REFUSED
# lifecycle edge ends as a FAIL with the record still armed, that the arms can
# reach nothing but the controller and the reconciler, that the bound is derived
# from the installed DAG rather than typed, and that the operator's confirm text
# is the box's own words.
#
# THE WORLD NEEDS ONE THING runner_world does not give it: a box that is actually
# ENGAGED. A lifecycle round trip from `off` is refused BY DESIGN (engaging a
# bond the operator left down is not a round trip), so a bar that ran in the
# default world would measure the refusal and nothing else.
dis229_world() {
    setup; runner_world
    P5_WATCHDOG="$P5/bond-watchdog"; export P5_WATCHDOG
    : > "$BOND_DIR/rc"
    sh "$P5/bond-xctl" reconcile >/dev/null 2>&1
}
# ALWAYS setsid. Not decoration: p5-portal-restore skips the group kill when the
# record's pid is its OWN process group, and that is only true when the job was
# started the way p5_detach starts it. Run in the foreground the restore takes
# the kill limb instead and waits out the whole declared bound under the no-op
# sleep shim -- measured at ~595 forks and 100+ seconds for one bar.
dis229_run_in() {   # $1 = portal ROOT, $2 = name, $3 = id, $4 = P5_PORTAL_DM_TIMER
    env P5_PORTAL_DIR="$1" P5_CAT_DIR="$1/catalogue" XCTL="$P_XCTL" \
        DAG="$P5/bond.dag" P5_WATCHDOG="$P5/bond-watchdog" P5_PORTAL_DM_TIMER="$4" \
        setsid sh "$1/bin/p5-portal-run" "$2" "$3" >/dev/null 2>&1 &
}
dis229_run() { dis229_run_in "$PORTAL" "$1" "$2" "$3"; }
dis_auto() { if [ -f "$BOND_DIR/auto" ]; then echo 1; else echo 0; fi; }
# dis_fn NAME -> that shell function's body out of the shipped runner.
dis_fn() {
    awk -v f="$1" 'index($0, f "() {") == 1 {inf=1} inf {print} inf && $0 == "}" {exit}' "$RUNNER_SRC"
}

# --- DIS-1: the lifecycle round trip, in order, and the box left as found -----
# THE ORDER IS THE PROPERTY. `off` then `on` then the rollback's reconcile: put
# the facts back before the second half has run and the artifact says PASS about
# a box that never went anywhere. The seed for this bar moves the rollback above
# the `p5 on` and the ledger order inverts.
dis229_world
D1_PRE=$(sh "$P5/bond-xctl" node)
D1_MODE=$(cat "$BOND_DIR/mode" 2>/dev/null)
: > "$LEDGER"; : > "$WORK/ledger"
D1=$(mk_id lifecycle_roundtrip)
dis229_run lifecycle_roundtrip "$D1" 0
if await "$WORK/results/$D1.txt" 900; then ok "DIS-1x the lifecycle row ran to its footer (pre node '$D1_PRE')"
else no "DIS-1x the lifecycle row never finished -- nothing below this line has a subject"; fi
A1=$(cat "$WORK/results/$D1.txt" 2>/dev/null)
D1_OFF=$(li "$LEDGER" 'bondctl off')
D1_ON=$(li "$LEDGER" 'bondctl on')
D1_REC=$(li "$LEDGER" 'bond-xctl reconcile')
if [ -n "$D1_OFF" ] && [ -n "$D1_ON" ] && [ -n "$D1_REC" ] \
   && [ "$D1_OFF" -lt "$D1_ON" ] && [ "$D1_ON" -lt "$D1_REC" ]; then
    ok "DIS-1 the ledger order is off ($D1_OFF), on ($D1_ON), then the rollback's reconcile ($D1_REC)"
else
    no "DIS-1 the order is wrong (off='${D1_OFF:-none}' on='${D1_ON:-none}' reconcile='${D1_REC:-none}') -- facts put back before the second half ran would make the PASS meaningless"
fi
asrt "DIS-1a the node is back where the job found it" "$(sh "$P5/bond-xctl" node)" "$D1_PRE"
asrt "DIS-1b ... and so is the mode fact"             "$(cat "$BOND_DIR/mode" 2>/dev/null)" "$D1_MODE"
has  "DIS-1c the artifact records the round trip as a PASS" "$A1" 'RESULT PASS lifecycle_roundtrip'
has  "DIS-1d ... the rollback verified the node back"       "$A1" 'restore=ok'
has  "DIS-1e ... and the deadman was retired"               "$A1" 'deadman=confirmed'
has  "DIS-1f the artifact names the disturbance it made and how long it may last" "$A1" '### pre rc='
V1=$(led_viol "$LEDGER")
asrt "DIS-1g every argv the whole round trip issued is in the shared allowlist" "$V1" ""
# THE ROLLBACK MUST NOT RUN UNTIL THE ROUND TRIP HAS A RESULT, and this is the
# half the ledger order above CANNOT see. p5-portal-restore replays `p5 on`
# itself, so a rollback fired between the two halves leaves the ledger reading
# off, on, reconcile exactly as a clean run does -- MEASURED: the seeded mutant
# for this bar (a restore call planted before the arm's second `p5` call) was
# GREEN on DIS-1 until this assertion existed. The artifact settles it, because
# the runner writes RESULT and only then calls the restore, whose `restore: job`
# line is the first thing that rollback logs.
D1_RES=$(li "$WORK/results/$D1.txt" 'RESULT ')
D1_RST=$(li "$WORK/results/$D1.txt" 'restore: job ')
if [ -n "$D1_RES" ] && [ -n "$D1_RST" ] && [ "$D1_RES" -lt "$D1_RST" ]; then
    ok "DIS-1h the rollback ran only after the round trip had a result (RESULT at artifact line $D1_RES, rollback at $D1_RST)"
else
    no "DIS-1h the facts were put back before the round trip finished (RESULT='${D1_RES:-none}' rollback='${D1_RST:-none}') -- the PASS above would be about a box that never went anywhere"
fi
job_cleanup

# --- DIS-2: the mode round trip restores mode AND auto presence exactly -------
# Run from the SUPERVISED state (auto present, mode `eco`), because that is the
# state the restore rule is about: pinning a manual mode clears auto and stops
# bond-ecod, and the way back is `eco` -- the INTENT -- not the position ecod had
# escalated to. A restore that replayed the position would pin a mode nobody ever
# chose (ADR-003 rule 4), and on this fixture the two happen to differ.
dis229_world
printf 'eco\n' > "$BOND_DIR/mode"; : > "$BOND_DIR/auto"
sh "$P5/bond-xctl" reconcile >/dev/null 2>&1
D2_MODE=$(cat "$BOND_DIR/mode"); D2_AUTO=$(dis_auto); D2_NODE=$(sh "$P5/bond-xctl" node)
# What the arm SHOULD pin, derived here from the catalogue exactly as
# pick_other_mode derives it: the first `implemented` mode-verb row that is
# neither `eco` nor the mode in force. Naming a mode literally in this bar would
# make the bar the authority instead of the catalogue.
D2_WANT=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/modes" \
          | awk -F'|' -v cur="$D2_MODE" '$3=="implemented" && $2=="mode" && $1!="eco" && $1!=cur {print $1; exit}')
: > "$LEDGER"; : > "$WORK/ledger"
D2=$(mk_id mode_roundtrip)
dis229_run mode_roundtrip "$D2" 0
if await "$WORK/results/$D2.txt" 900; then ok "DIS-2x the mode row ran to its footer (pre mode '$D2_MODE', auto $D2_AUTO)"
else no "DIS-2x the mode row never finished -- nothing below this line has a subject"; fi
A2=$(cat "$WORK/results/$D2.txt" 2>/dev/null)
asrt "DIS-2 the mode fact is exactly what the job found"        "$(cat "$BOND_DIR/mode" 2>/dev/null)" "$D2_MODE"
asrt "DIS-2a the auto fact is present exactly as it was"        "$(dis_auto)" "$D2_AUTO"
asrt "DIS-2b ... and the node is unchanged"                     "$(sh "$P5/bond-xctl" node)" "$D2_NODE"
if [ -n "$D2_WANT" ]; then
    has "DIS-2c the arm pinned the mode the CATALOGUE picks, not one typed into the runner" "$(cat "$LEDGER")" "bondctl mode $D2_WANT"
else
    no "DIS-2c the catalogue offers no second implemented manual mode -- the bar has no subject"
fi
has "DIS-2d ... and returned to the INTENT (eco), not to the position ecod had escalated to" "$(cat "$LEDGER")" 'bondctl mode eco'
has "DIS-2e the artifact says the ecod stop is what happened"   "$A2" 'stops bond-ecod'
has "DIS-2f ... and records the round trip as a PASS"           "$A2" 'RESULT PASS mode_roundtrip'
V2=$(led_viol "$LEDGER")
asrt "DIS-2g every argv the mode round trip issued is in the shared allowlist" "$V2" ""
job_cleanup

# --- DIS-3: a REFUSED engage ends FAIL, and the record stays armed ------------
# The failure this pair exists for. `p5 off` is not gated by `old_quiescent`
# (bond.dag: the way back to off is deliberately ungated), so the job takes the
# bond down and is then REFUSED on the way back. The box is left off, the
# rollback replays the same refused intent and cannot verify the node back -- and
# the ONE thing that must not happen then is a confirm, because `confirm` retires
# the record and the record is the only thing still going to retry.
dis229_world
echo 0 > "$ECOSIM_STATE/old_quiescent"
: > "$LEDGER"; : > "$WORK/ledger"
D3=$(mk_id lifecycle_roundtrip)
dis229_run lifecycle_roundtrip "$D3" 0
if await "$WORK/results/$D3.txt" 900; then ok "DIS-3x the refused round trip ran to its footer"
else no "DIS-3x the refused round trip never finished -- nothing below this line has a subject"; fi
A3=$(cat "$WORK/results/$D3.txt" 2>/dev/null)
has "DIS-3 a refused engage is a FAIL, not a silent pass"        "$A3" 'RESULT FAIL lifecycle_roundtrip'
has "DIS-3a ... quoting the reconciler's own refusal line"       "$A3" "guard 'old_quiescent' refused"
has "DIS-3b ... the rollback could not verify the node back"     "$A3" 'restore=mismatch'
has "DIS-3c ... so the deadman was NOT confirmed"                "$A3" 'deadman=ARMED-LEFT'
if [ -f "$WORK/dm/etc/p5/deadman/portal-lifecycle_roundtrip" ]; then
    ok "DIS-3d the armed record is KEPT: the box still owes a rollback and the deadman will retry it on its own cadence"
else
    no "DIS-3d the record was retired after a rollback that never verified -- the retry that would fix this box is gone"
fi
hasnt "DIS-3e and no confirm was issued at all" "$(cat "$LEDGER")" 'p5-deadman confirm'
job_cleanup
echo 1 > "$ECOSIM_STATE/old_quiescent"
rm -f "$WORK/dm/etc/p5/deadman/portal-lifecycle_roundtrip"

# --- DIS-4: STATIC -- what the two arms are allowed to reach ------------------
# Read off the four function bodies, not off a comment above them. The expected
# set is a LITERAL here for the same reason RUN-C2's is: widening what a
# disruptive arm may call means editing this bar.
DIS4_BODY=$(dis_fn rt_lifecycle; dis_fn rt_mode; dis_fn poll_node; dis_fn pick_other_mode)
DIS4_N=$(printf '%s\n' "$DIS4_BODY" | grep -c .)
if [ "$DIS4_N" -ge 40 ]; then ok "DIS-4x the four arm bodies were read ($DIS4_N lines)"
else no "DIS-4x only $DIS4_N lines of the arm bodies were read -- the scan below has almost no subject"; fi
# An INVOCATION is `"$VAR" <verb>`: the quoted-variable head followed by a word.
# `"$PRE_MODE"` and friends are arguments, never followed by a bare verb, so they
# do not appear -- and DIS-4b pins that only two head NAMES occur at all.
DIS4_CALLS=$(printf '%s\n' "$DIS4_BODY" | grep -oE '"\$[A-Z_][A-Z_0-9]*" [a-z][a-z_]*' | sort -u | tr '\n' ';')
asrt "DIS-4 the two arms issue exactly p5 on|off|mode and p5-reconciler node" \
     "$DIS4_CALLS" '"$BONDCTL" mode;"$BONDCTL" off;"$BONDCTL" on;"$XCTL" node;'
DIS4_HEADS=$(printf '%s\n' "$DIS4_BODY" | grep -oE '"\$[A-Z_][A-Z_0-9]*" [a-z][a-z_]*' | sed 's/^"\$//; s/".*//' | sort -u | tr '\n' ' ')
asrt "DIS-4a ... reaching exactly two externals, the controller and the reconciler" "$DIS4_HEADS" "BONDCTL XCTL "
# `reconcile` is deliberately ABSENT above and that is not an omission: neither
# arm calls it. bondctl reconciles for its own fact writes (deploy/p5/bondctl,
# the `on)` and `off)` arms) and p5-portal-restore reconciles for the rollback,
# so an arm that called it too would be a THIRD site deriving the same edge.
hasnt "DIS-4b no arm derives an edge itself" "$DIS4_CALLS" '"$XCTL" reconcile'
# THE CONTROL: the scan has to be able to fail.
DIS4_M=$(binmut dis4 -e 's#^    "\$BONDCTL" off; _l_off=\$?#    "$SVC" stop; "$BONDCTL" off; _l_off=$?#')
DIS4_MB=$(awk 'index($0, "rt_lifecycle() {") == 1 {inf=1} inf {print} inf && $0 == "}" {exit}' "$DIS4_M/bin/p5-portal-run")
if printf '%s\n' "$DIS4_MB" | grep -qE '"\$SVC" stop'; then
    ok "DIS-4c CONTROL: a service verb planted in an arm is visible to the same scan"
else
    no "DIS-4c CONTROL: the mutation did not apply -- DIS-4 proves nothing"
fi

# --- DIS-5: the bound is DERIVED, and it MOVES when the DAG moves -------------
# Recomputed here from the same three files, INDEPENDENTLY of the runner: the
# engage row's retries out of the DAG, verify_agg's own loop bounds/ping/sleep
# out of xctl-dag.sh, and the watchdog's CYCLE default. If verify_agg's loops
# ever change, this bar goes red and the runner's transcription has to follow --
# which is the whole reason the arithmetic is allowed to live in the runner at
# all rather than being parsed out of shell source on the box.
dis_verify_worst() {   # $1 = xctl-dag.sh -> one verify_agg attempt-set, worst case
    _va=$(awk 'index($0, "verify_agg() {") == 1 {inf=1} inf {print} inf && $0 == "}" {exit}' "$1")
    _att=$(printf  '%s\n' "$_va" | sed -n 's/.*"\$ATT" -le \([0-9][0-9]*\).*/\1/p' | head -1)
    _rep=$(printf  '%s\n' "$_va" | sed -n 's/.*"\$j" -le \([0-9][0-9]*\).*/\1/p'   | head -1)
    _hold=$(printf '%s\n' "$_va" | sed -n 's/.*"\$k" -le \([0-9][0-9]*\).*/\1/p'   | head -1)
    _rsl=$(printf  '%s\n' "$_va" | sed -n 's/^ *sleep \([0-9][0-9]*\); j=.*/\1/p'  | head -1)
    _pc=$(printf   '%s\n' "$_va" | sed -n 's/.* -c \([0-9][0-9]*\) -W \([0-9][0-9]*\) .*/\1 \2/p' | tail -1)
    _gap=$(printf  '%s\n' "$_va" | sed -n 's/.*&& sleep \([0-9][0-9]*\);.*/\1/p'   | head -1)
    _pn=${_pc%% *}; _pw=${_pc##* }
    for _v in "$_att" "$_rep" "$_hold" "$_rsl" "$_pn" "$_pw" "$_gap"; do
        case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    done
    printf '%s' "$(( _att * (_rep * _rsl + _hold * (_pn * _pw + _gap)) ))"
}
DIS5_VW=$(dis_verify_worst "$P5/lib/xctl-dag.sh") || DIS5_VW=""
DIS5_R=$(grep -v '^[[:space:]]*#' "$P5/bond.dag" | awk -F'|' 'NF==8 && $1=="engage"{print $7; exit}')
DIS5_C=$(sed -n 's/^CYCLE="${CYCLE:-\([0-9][0-9]*\)}".*/\1/p' "$P5/bond-watchdog" | head -1)
if [ -n "$DIS5_VW" ] && [ -n "$DIS5_R" ] && [ -n "$DIS5_C" ]; then
    ok "DIS-5x the three sources read: retries=$DIS5_R verify_worst_s=$DIS5_VW cycle_s=$DIS5_C"
else
    no "DIS-5x a source could not be read (retries='$DIS5_R' verify_worst='$DIS5_VW' cycle='$DIS5_C') -- the recomputation below is vacuous"
fi
DIS5_WANT=$(( ${DIS5_R:-0} * ${DIS5_VW:-0} + ${DIS5_C:-0} ))
dis_bound() {   # $1 = DAG file, $2 = row name -> the runner's own derived bound
    env P5_PORTAL_DIR="$PORTAL" P5_CAT_DIR="$PORTAL/catalogue" \
        DAG="$1" P5_WATCHDOG="$P5/bond-watchdog" sh "$RUNNER_SRC" --bound "$2" 2>/dev/null
}
asrt "DIS-5 the runner's bound for the lifecycle row is what these three files derive" \
     "$(dis_bound "$P5/bond.dag" lifecycle_roundtrip)" "$DIS5_WANT"
asrt "DIS-5a ... and the mode row is bounded by the same derivation" \
     "$(dis_bound "$P5/bond.dag" mode_roundtrip)" "$DIS5_WANT"
# THE MOVE. A COPY of the DAG whose engage row declares one retry instead of
# five. Nothing in the runner is touched; the number has to follow the file.
awk -F'|' 'BEGIN{OFS="|"} /^engage\|/ && NF==8 {$7=1} {print}' "$P5/bond.dag" > "$WORK/dag-r1"
DIS5_R1=$(grep -v '^[[:space:]]*#' "$WORK/dag-r1" | awk -F'|' 'NF==8 && $1=="engage"{print $7; exit}')
asrt "DIS-5b the fixture DAG really carries retries=1" "$DIS5_R1" 1
DIS5_MOVED=$(dis_bound "$WORK/dag-r1" lifecycle_roundtrip)
asrt "DIS-5c a DAG with retries=1 moves the bound, with no edit to the runner" \
     "$DIS5_MOVED" "$(( 1 * ${DIS5_VW:-0} + ${DIS5_C:-0} ))"
if [ -n "$DIS5_MOVED" ] && [ "$DIS5_MOVED" != "$DIS5_WANT" ]; then
    ok "DIS-5d ... and it is a DIFFERENT number ($DIS5_MOVED vs $DIS5_WANT): a bound typed into the catalogue could not do this"
else
    no "DIS-5d the bound did not move ($DIS5_MOVED vs $DIS5_WANT) -- it is not being derived from the DAG at all"
fi
has "DIS-5e the artifact carries the arithmetic, not just the number" "$A1" "### bound $DIS5_WANT = retries=$DIS5_R"
# A source that cannot be read is a REFUSAL, never a fallback number.
if dis_bound "$WORK/no-such-dag" lifecycle_roundtrip >/dev/null 2>&1; then
    no "DIS-5f the runner produced a bound from a DAG that does not exist -- there is a fallback constant in there"
else
    ok "DIS-5f an unreadable DAG refuses the row rather than inventing a window"
fi

# --- DIS-6: the confirm text is the BOX'S OWN words, and the gates hold -------
dis229_world
R=$(P 'k=run&name=mode_roundtrip')
asrt "DIS-6x an unconfirmed disruptive row is refused" "$(st "$R")" 409
B6=$(bd "$R")
has  "DIS-6y ... with confirm_required, the same shape a mode pin uses" "$B6" 'confirm_required'
# THE TEXT IS THE CATALOGUE'S LABEL. The page quotes it; it does not compose one.
D6_TEXT=$(jf text "$B6")
has "DIS-6 the confirm text names the bond-ecod stop" "$D6_TEXT" 'bond-ecod is stopped and restarted'
has "DIS-6a ... and says the baseline restarts, so the operator knows what does NOT come back" "$D6_TEXT" 'EWMA baseline restarts'
D6_CATLAB=$(grep -v '^[[:space:]]*#' "$PORTAL/catalogue/tests" | awk -F'|' '$1=="mode_roundtrip"{print $5}')
asrt "DIS-6b the text IS the catalogue row's label, not a sentence the CGI composed" "$D6_TEXT" "$D6_CATLAB"
D6_BS=$(printf '%s' "$B6" | sed -n 's/.*"bound_s":\([0-9][0-9]*\).*/\1/p')
asrt "DIS-6c ... and the bound it quotes is the derived number, not the catalogue's symbol" "$D6_BS" "$DIS5_WANT"
hasnt "DIS-6d the symbol never reaches the operator" "$B6" 'DERIVED'
# The echo is required, and it is the row's own name.
R=$(P 'k=run&name=mode_roundtrip&confirm=wrong_name')
asrt "DIS-6e a WRONG echo is still refused" "$(st "$R")" 409
R=$(P 'k=run&name=mode_roundtrip&confirm=mode_roundtrip')
asrt "DIS-6f the right echo starts it" "$(st "$R")" 202
job_cleanup
# GATE A: nothing disruptive starts while a rollback is still owed. The armed
# record lives under the deadman's own root, which the harness re-roots into
# $WORK; on the box P5_ROOT is empty and the two are the same directory.
dis229_world
mkdir -p "$WORK/deadfix"
printf 'P5_DM_LABEL=portal-lifecycle_roundtrip\n' > "$WORK/deadfix/portal-lifecycle_roundtrip"
R=$(P5_DEADDIR="$WORK/deadfix" P 'k=run&name=mode_roundtrip&confirm=mode_roundtrip')
asrt "DIS-6g a disruptive row is refused while a deadman record is armed" "$(st "$R")" 409
has  "DIS-6h ... saying which record"  "$(bd "$R")" 'deadman_armed'
R=$(P5_DEADDIR="$WORK/deadfix" P 'k=run&name=accept')
asrt "DIS-6i ... and a read-only row is NOT gated by it" "$(st "$R")" 202
job_cleanup
# The DEFAULT the CGI resolves that directory to, asserted statically: on the box
# P5_DEADDIR is $P5_ROOT/etc/p5/deadman (p5/lib/p5-common.sh) with P5_ROOT empty,
# which is $BOND_DIR/deadman. A default that named the OLD stack's directory is
# exactly the class of defect U220 found three of.
if grep -qF '${P5_DEADDIR:-$BOND_DIR/deadman}' "$CGI_SRC"; then
    ok "DIS-6j the CGI's armed-record directory defaults to \$BOND_DIR/deadman, which is p5-common.sh's P5_DEADDIR on the box"
else
    no "DIS-6j the CGI does not resolve the armed-record directory from \$BOND_DIR -- it can point at a directory the deadman never writes"
fi

# --- BB: the two executables parse under the shell the BOX runs ---------------
# The claim written at the top of both bin files is "BUSYBOX-SAFE POSIX sh", and
# until this bar nothing measured it: the busybox gate parses
# orchestration/ecosim/p5/run.sh, not these, and every bar above runs them under
# whatever /bin/sh this host has. A construct dash accepts and busybox ash does
# not (or the reverse) would ship green and fail on the one interpreter that
# matters. `-n` is a PARSE, not a run: it cannot touch the box.
#
# NO INTERPRETER IS NOT A PASS. If busybox or dash is missing the bar says so
# with a FAIL rather than skipping, because "nothing ran" and "nothing was
# wrong" must not print the same square.
for _bbsh in busybox dash; do
    for _bbf in "$CGI_SRC" "$LIB_SRC" "$PORTAL/bin/p5-portal-run" "$PORTAL/bin/p5-portal-restore"; do
        _bbn=${_bbf##*/}
        if [ "$_bbsh" = busybox ]; then
            command -v busybox >/dev/null 2>&1 || { no "BB-$_bbn no busybox on this host: the busybox-safe claim is UNMEASURED"; continue; }
            _bbo=$(busybox ash -n "$_bbf" 2>&1); _bbrc=$?
        else
            command -v dash >/dev/null 2>&1 || { no "BBD-$_bbn no dash on this host: the POSIX claim is UNMEASURED"; continue; }
            _bbo=$(dash -n "$_bbf" 2>&1); _bbrc=$?
        fi
        if [ "$_bbrc" = 0 ]; then ok "BB-$_bbsh-$_bbn parses under $_bbsh"
        else no "BB-$_bbsh-$_bbn does not parse under $_bbsh: $_bbo"; fi
    done
done
# THE CONTROL: the parse check has to be able to fail, or the eight squares above
# are decoration. A copy of the runner with one `fi` removed must be refused by
# the same call.
cp "$PORTAL/bin/p5-portal-run" "$WORK/bb-mutant"
sed -i '0,/^fi$/s/^fi$/# fi REMOVED BY THE CONTROL/' "$WORK/bb-mutant"
if command -v busybox >/dev/null 2>&1; then
    if busybox ash -n "$WORK/bb-mutant" >/dev/null 2>&1; then
        no "BB-CTL busybox ash accepted a runner with an unbalanced if -- the parse bars above prove nothing"
    else
        ok "BB-CTL CONTROL: the same call rejects a runner whose first \`fi\` was removed"
    fi
else
    no "BB-CTL no busybox: the control cannot run either"
fi

echo "===== M9 portal: $pass passed, $fail failed ====="
[ "$fail" -eq 0 ] || exit 1
