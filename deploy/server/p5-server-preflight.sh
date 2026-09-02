#!/bin/sh
# shellcheck shell=sh
# p5-server-preflight.sh -- READ-ONLY. Answers the questions the U40 inventory
# could not, for the box that cannot be recovered.
#
# WHY THIS EXISTS, and it is not "more inventory".
# docs/knowledge/inventory/2026-08-30-server-brume2.txt is the ground truth for
# what is ON that box, and U38's procedure is written against it. But three of
# its blocks are BLIND, and every blind spot sits on the firewall -- which is
# exactly the subsystem whose reload can lock the operator out of a box with no
# console:
#
#   1. `### firewall-loaded` came back EMPTY, so the LOADED ruleset has never
#      been read on either box. That is the standing fact and it is why this
#      script exists; it is NOT a claim about live code. The collector defect
#      that caused it -- `(nft ... | head -40 || iptables -S | head -40)`, whose
#      `||` binds to the whole left PIPELINE, whose status is `head`'s, which
#      exits 0 on empty input -- is FIXED on the merge target: U40's f376b34,
#      merged into dev at 27ca5f8, tests each backend on its own at
#      scripts/box-inventory.sh:51-59, and the old form survives only as a
#      comment at :45-50. Fixing the collector does not fill an inventory
#      already captured, so a RE-RUN is still owed (U38c) and until then this
#      script is the only fresh read of the loaded ruleset.
#      (The box is OpenWrt 21.02, inventory:10, which is fw3/iptables era, so
#      `nft list ruleset` producing nothing is consistent. That is an inference
#      about WHY; the emptiness of the block is not an inference.)
#
#   2. `### firewall-uci` is TRUNCATED, and nobody noticed. This one is STILL
#      LIVE on dev: box-inventory.sh:44 still ends in `head -60` (U40's fix
#      touched only the block below it), and the block is EXACTLY 60 lines on
#      BOTH boxes
#      (server inventory lines 47-106; client 61-120). uci appends a newly
#      `uci set firewall.NAME=rule` section to the END of /etc/config/firewall,
#      so any rule added after the stock GL defaults -- including the
#      `firewall.engarde` that p2-engarde/bootstrap-bond-server.sh:56-63 writes
#      -- lands past the cap and is INVISIBLE. So the CONFIGURED ruleset was
#      not fully read either. The U40 write-up says the loaded one was missed;
#      the configured one was missed too, and that is worse, because the
#      configured file is what a reload rebuilds from.
#
#   3. `### network-uci-wg` came back EMPTY on the server, so which firewall
#      ZONE `wgserver` (10.0.0.1) belongs to is unknown -- and that decides
#      whether SSH over the tunnel is a management path at all.
#
# Plus four things the inventory never asked and the procedure depends on:
# whether crond actually runs (the deadman's boot limb), which detach applet
# exists (its timer limb), whether there is room for the binary, and -- the one
# that matters most -- WHICH INTERFACE THE OPERATOR'S OWN SSH SESSION LANDS ON.
#
# READ-ONLY. Starts nothing, stops nothing, writes no file, touches no uci
# value. Every probe is guarded so a missing tool degrades to a printed
# "(absent)" rather than a failure.
#
# ONE HONEST QUALIFICATION on "read-only", because the earlier wording said
# "loads no module" and the code does not support that: the `iptables -S`
# probes below (firewall-loaded-iptables, firewall-input-chains,
# firewall-udp-59401-59402) will AUTOLOAD ip_tables/iptable_filter on a kernel
# where they are not already resident. On this box that is a no-op -- it is
# OpenWrt 21.02 with fw3, so those modules are resident before we arrive
# (inventory:10) -- and loading a filter table with no rules changes no
# traffic. But it is a kernel state change, so it is stated rather than
# claimed away.
#
# RUN IT FROM THE PC, NEVER FROM THE CLIENT BOX. `${SERVER_PC_IP}` is the server
# from the PC and the USB tether from the client (HANDOFF s0). The identity
# block below is the mechanism, not the prose rule.
#
#   ssh root@<server> 'sh -s' < deploy/server/p5-server-preflight.sh | tee preflight-server.txt
#
# Run it on the CLIENT too. Every step of the U38 procedure must be rehearsed
# there first, and a rehearsal on a box whose primitives differ proves nothing.
#
# POSIX sh / busybox. No bashisms, no arrays, no fractional sleep, no sleep.

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n### %s\n' "$1"; }

# THE ONE THING THIS SCRIPT REFUSES ON (U115). Everything else here reports and
# lets the operator judge; the transport secret does not get that treatment,
# because a missing or readable-by-anyone key is not a fact to weigh, it is the
# authenticated transport being off. PF_RC is the script's exit code: 0 unless
# the key block below says otherwise, so a preflight that prints a refusal also
# FAILS, and a caller that only reads exit codes still sees it.
PF_RC=0

# ---------------------------------------------------------------- identity --
# First, and fail-loud, for the same reason box-inventory.sh prints it first:
# an answer that names the wrong box is worse than no answer.
sec identity
printf 'hostname: %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
printf 'model:    %s\n' "$( (cat /tmp/sysinfo/model 2>/dev/null) || echo '(unknown)')"
printf 'addrs:    '
ip -o -4 addr show 2>/dev/null | awk '{printf "%s=%s ", $2, $4}'
printf '\n'
_h=$(cat /proc/sys/kernel/hostname 2>/dev/null)
case "$_h" in
  GL-MT2500) printf 'verdict:  SERVER (Brume 2) -- NO physical access. Nothing here may leave it unreachable.\n' ;;
  GL-MT6000) printf 'verdict:  CLIENT (Flint 2) -- recoverable. This is where every step gets rehearsed.\n' ;;
  *)         printf 'verdict:  UNRECOGNISED -- do NOT act on this preflight until the box is identified.\n' ;;
esac

# -------------------------------------------------------- management path --
# THE most important block in this file. No document in the repo states how the
# operator reaches the server; ROADMAP records that as unresolved. It does not
# have to be derived -- it can be MEASURED, because dropbear puts it in the
# environment of the session you are already sitting in.
#
# SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>". The
# THIRD field is the server address your management path actually lands on, and
# that decides which subsystem can cut you off:
#
#   ${SERVER_WAN_IP}  -> the WAN interface. Your session is admitted by a wan-zone
#                     input rule, so `/etc/init.d/firewall reload` CAN CUT IT.
#                     This is the dangerous case and it needs the deadman.
#   ${SERVER_PC_IP}    -> br-lan. lan-zone input is ACCEPT by default, so a firewall
#                     reload is far less likely to cut it -- but "less likely"
#                     is not "cannot", and the zone membership is printed below
#                     rather than assumed.
#   10.0.0.1       -> wgserver. Then read the wg block: if YOUR peer's endpoint
#                     is 127.0.0.1:<port>, your session rides engarde-server on
#                     :59401, and ANY step touching :59401 severs you. If your
#                     peer has a public endpoint, you reach wgserver:51820
#                     directly and are independent of engarde.
sec management-path
printf 'SSH_CONNECTION: %s\n' "${SSH_CONNECTION:-(unset -- not an ssh session, or dropbear did not export it)}"
printf 'SSH_CLIENT:     %s\n' "${SSH_CLIENT:-(unset)}"
printf 'landed-on:      %s\n' "$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')"
printf 'established-22: \n'
# Each backend tested ON ITS OWN, and its OWN exit status read -- not
# `(netstat || ss) | grep`, which this line used to be. There the `||` binds to
# netstat alone, so a netstat that exists and answers EMPTY with status 0 makes
# the ss fallback unreachable and prints an empty table that reads as "no
# sessions". That is the U38b defect class in this unit's own preflight, on the
# one block whose job is to show the operator the connection they are standing
# on. Same shape as `established_peers_raw` in p5-fw-deadman, deliberately.
if _p5_c=$(netstat -tn 2>/dev/null) && [ -n "$_p5_c" ]; then
    printf '%s\n' "$_p5_c" | grep -E '(:22[[:space:]]|:22$)'
    printf '(source: netstat -tn)\n'
elif _p5_c=$(ss -tn 2>/dev/null) && [ -n "$_p5_c" ]; then
    printf '%s\n' "$_p5_c" | grep -E '(:22[[:space:]]|:22$)'
    printf '(source: ss -tn)\n'
else
    printf '(neither netstat nor ss produced a connection table -- the deadman\n'
    printf ' takes its pre-arm snapshot from these, so confirm will FAIL CLOSED)\n'
fi

# --------------------------------------------------------------- firewall --
# Blind spot 2. NO `head` cap here: the whole configured ruleset, because the
# rows that matter are the ones appended at the end.
sec firewall-uci-FULL
uci show firewall 2>/dev/null || printf '(uci show firewall failed)\n'

sec firewall-uci-named-sections
# Named sections are the removable, idempotent kind. `uci set firewall.p5=rule`
# converges on re-run and `uci delete firewall.p5` removes exactly one object;
# an anonymous @rule[N] shifts index when its neighbours change and must never
# be deleted by index on this box. Print what named objects already exist so
# `p5` can be confirmed free before anything claims it.
uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([a-zA-Z_][a-zA-Z0-9_]*\)=.*/\1/p' | sort -u

# Blind spot 1. Both backends tried INDEPENDENTLY -- no `||`, because that is
# the bug that produced the empty block in the first place. Uncapped.
sec firewall-loaded-backend
if have nft; then printf 'nft: present\n'; else printf 'nft: (absent)\n'; fi
if have iptables; then printf 'iptables: present\n'; else printf 'iptables: (absent)\n'; fi
if have fw3; then printf 'fw3: present (iptables-era firewall, OpenWrt 21.02)\n'; else printf 'fw3: (absent)\n'; fi
if have fw4; then printf 'fw4: present (nftables-era firewall)\n'; else printf 'fw4: (absent)\n'; fi

sec firewall-loaded-nft
if have nft; then nft list ruleset 2>&1; else printf '(nft absent)\n'; fi

sec firewall-loaded-iptables
if have iptables; then iptables -S 2>&1; else printf '(iptables absent)\n'; fi

# The deadman's pre-arm connection snapshot depends on one of these answering
# in a format it can parse (p5-fw-deadman, established_peers_raw). If neither
# does, `confirm` FAILS CLOSED and the only ways out of an arm are the deadline
# and `fire`. Learn that here, before the change, not at confirm time.
# NO head cap on either table: the operator's job here (Gate C, C7c) is to find
# THEIR OWN id in it, and a capped table can hide exactly that row -- the same
# `head -60` truncation that lost `### firewall-uci` (s2b). Evidence prints whole.
sec deadman-connection-snapshot
if have netstat; then printf 'netstat: present
'; netstat -tn 2>&1; else printf 'netstat: (absent)
'; fi
if have ss; then printf 'ss: present
'; ss -tn 2>&1; else printf 'ss: (absent)
'; fi
printf 'this session SSH_CONNECTION 1:2 = %s
' "$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1 ":" $2}')"
printf 'READ IT LIKE THIS, and the two halves are not the same rule:
'
printf '  ARM time  -- if THIS id is MISSING from the table above, arm marks the
'
printf '               snapshot untrusted and confirm will then refuse everything.
'
printf '  CONFIRM   -- refuses any connection that WAS in that table, including
'
printf '               this one. Confirm from a session opened after the change.
'

sec firewall-input-chains
# The chain an ephemeral ACCEPT would be inserted into. NOT guessed: printed.
# On fw3 this is `zone_wan_input`. Do not assume that name -- read it here.
if have iptables; then iptables -S 2>/dev/null | grep -E '^-N ' ; else printf '(iptables absent)\n'; fi

sec firewall-udp-59401-59402
# Is anything already admitting either port, configured or loaded?
uci show firewall 2>/dev/null | grep -E '5940[12]' || printf '(no 59401/59402 in uci firewall)\n'
if have iptables; then iptables -S 2>/dev/null | grep -E '5940[12]' || printf '(no 59401/59402 in loaded iptables)\n'; fi
if have nft; then nft list ruleset 2>/dev/null | grep -E '5940[12]' || printf '(no 59401/59402 in loaded nft)\n'; fi

# ------------------------------------------------------------ wg + zones --
# Blind spot 3.
sec network-uci-wg-FULL
uci show network 2>/dev/null | grep -iE 'wireguard|wgserver|wgclient|proto=' || printf '(none)\n'

sec firewall-zone-membership
# Which zone each interface is in -- decides whether 10.0.0.1 and ${SERVER_PC_IP}
# are reachable for management at all, and whether a wan-zone reload can cut them.
uci show firewall 2>/dev/null | grep -E '\.(name|network|device|input|output|forward)=' || printf '(none)\n'

sec wg
if have wg; then wg show 2>/dev/null; else printf '(wg absent)\n'; fi

# ---------------------------------------------------------------- port free --
# Each backend tested ON ITS OWN, its own exit status read, non-empty required --
# the same fix as `### management-path` above, applied here in round 3, because
# these three blocks still carried the `(ss || netstat) | grep` shape this unit
# itself named (s9, U38b): the `||` binds to `ss` alone, so an `ss` that answers
# EMPTY with status 0 makes the netstat fallback unreachable -- and an empty
# table read as "59402 FREE" (the unsafe direction) and "59401 ABSENT". The
# empty/unreadable case is now its own verdict, never a default to FREE.
sec listeners-udp-FULL
_p5_udp=""
if _p5_udp=$(netstat -lnup 2>/dev/null) && [ -n "$_p5_udp" ]; then
    printf '%s\n(source: netstat -lnup)\n' "$_p5_udp"
elif _p5_udp=$(ss -lnup 2>/dev/null) && [ -n "$_p5_udp" ]; then
    printf '%s\n(source: ss -lnup)\n' "$_p5_udp"
else
    _p5_udp=""
    printf '(neither netstat nor ss produced a UDP listener table)\n'
fi

sec port-59402-free
# The install-alongside plan's whole premise. Re-checked at deploy time, not
# taken from an inventory captured earlier -- a port that was free in August is
# not evidence about a port today.
if [ -z "$_p5_udp" ]; then
    printf 'UNKNOWN -- no UDP listener table could be read. STOP: unknown is not FREE.\n'
elif printf '%s\n' "$_p5_udp" | grep -q ':59402'; then
    printf 'BUSY -- 59402 has a listener. STOP. The install-alongside premise does not hold.\n'
else
    printf 'FREE -- nothing listens on udp/59402\n'
fi

sec port-59401-live
# Production. It must be untouched at the end of every step, and this is the
# before-picture each step is compared against.
if [ -z "$_p5_udp" ]; then
    printf 'UNKNOWN -- no UDP listener table could be read. Production state UNVERIFIED. STOP.\n'
elif printf '%s\n' "$_p5_udp" | grep -q ':59401'; then
    printf 'LIVE -- udp/59401 has a listener (production engarde-server)\n'
else
    printf 'ABSENT -- udp/59401 has NO listener. Production is already down. STOP.\n'
fi

# ------------------------------------------------------- deadman primitives --
# The deadman needs a timer limb that outlives the SSH session and a boot limb
# that outlives a power cut. Neither is assumed; both are probed. A box that
# has neither cannot safely run the firewall reload step AT ALL, and the
# procedure says so rather than degrading quietly.
sec deadman-primitives
for a in setsid nohup start-stop-daemon crond crontab date sleep sha256sum; do
    if have "$a"; then printf '%-18s present\n' "$a"; else printf '%-18s (ABSENT)\n' "$a"; fi
done

sec deadman-cron
printf 'init.d/cron:  %s\n' "$( [ -x /etc/init.d/cron ] && echo present || echo '(absent)')"
printf 'rc.d symlink: %s\n' "$(ls /etc/rc.d/ 2>/dev/null | grep -c cron) matching 'cron'"
printf 'crond running: '
if ps w 2>/dev/null | grep -v grep | grep -q '[c]rond'; then printf 'YES\n'; else printf 'NO -- the boot limb of the deadman does NOT work on this box\n'; fi
printf 'crontabs dir: %s\n' "$( [ -d /etc/crontabs ] && echo present || echo '(absent)')"
printf 'root crontab (current contents, so a deploy can restore it byte-exact):\n'
cat /etc/crontabs/root 2>/dev/null || printf '(no /etc/crontabs/root)\n'

sec clock
# The deadman fires on an ABSOLUTE deadline, so a box whose clock is wrong
# fires early or never. sysntpd/chronyd state is part of the deadman's
# correctness, not a nicety.
date 2>/dev/null
printf 'uptime: %s\n' "$(cat /proc/uptime 2>/dev/null)"
ps w 2>/dev/null | grep -v grep | grep -E '[n]tpd|[c]hronyd' || printf '(no ntpd/chronyd in ps)\n'

# ------------------------------------------------------------------ space --
sec space
# Nothing in the U40 inventory measured free flash or RAM. engarde-server is
# 5.3 MB (inventory:121) and a second static Go binary is the same order. A
# deploy that fills the overlay on a box with no console is a way to lose it.
df -h 2>/dev/null
printf '\n'
free 2>/dev/null || cat /proc/meminfo 2>/dev/null | head -5

sec overlay
mount 2>/dev/null | grep -iE 'overlay|jffs2|ubifs' || printf '(no overlay line)\n'

# ------------------------------------------------------------ p5 namespace --
sec p5-paths-free
# contract/paths reserves /usr/sbin/p5-server and /etc/init.d/p5-server for the
# server. Confirm they are free rather than assuming the box is bare.
for p in /usr/sbin/p5-server /etc/init.d/p5-server /etc/rc.d/*p5-server /etc/p5 /usr/lib/p5; do
    if [ -e "$p" ]; then printf '%-28s EXISTS -- investigate before installing\n' "$p"
    else printf '%-28s free\n' "$p"; fi
done

sec procd
printf 'procd: %s\n' "$( [ -e /sbin/procd ] && echo present || echo '(absent)')"
printf 'ubus:  %s\n' "$(command -v ubus >/dev/null 2>&1 && echo present || echo '(absent)')"

# ------------------------------------------------- transport secret (U115) --
# A REFUSAL, not a report. Every other block here prints a fact and lets the
# operator judge; this one does not, because p4-bondagg/server/auth.go:196-204
# reads the per-install secret from this path and, when it cannot,
# server/main.go:374-386 LOGS the failure and the daemon runs on with
# authentication OFF -- byte-for-byte the forgeable framing U31 exists to
# close. "Not there" and "readable by anyone on the box" are both stop
# conditions, so this script exits non-zero on either and names the file.
#
# THE MODE IS READ FROM `ls -l`, NOT `stat`: busybox builds without stat exist,
# and a preflight that cannot read the mode must not pass because of it.
# Characters 5-10 of the permission string are the group and other bits;
# anything but six dashes means somebody other than the owner can reach it.
sec transport-key
KEYF="${P5_ROOT:-}/etc/p5/transport.key"
if [ ! -f "$KEYF" ]; then
    printf '%-28s ABSENT\n' "$KEYF"
    printf 'REFUSE: the transport secret is not on this box, so the daemon would start with\n'
    printf '        authentication OFF and the bonded framing forgeable. p5-install places\n'
    printf '        it; a second box adopts the first one with --transport-key.\n'
    printf '        File: %s\n' "$KEYF"
    PF_RC=1
else
    # shellcheck disable=SC2012
    # ls, not find -perm: busybox find's permission predicates vary by build
    # and this is one fixed, known path, not a tree walk over hostile names.
    _perm=$(ls -l "$KEYF" 2>/dev/null | head -1 | cut -c1-10)
    _rest=$(printf '%s' "$_perm" | cut -c5-10)
    printf '%-28s %s\n' "$KEYF" "${_perm:-(mode unreadable)}"
    if [ -z "$_perm" ]; then
        printf 'REFUSE: the mode of %s could not be read. A mode that cannot be read is not a\n' "$KEYF"
        printf '        mode that passes.\n'
        PF_RC=1
    elif [ "$_rest" != "------" ]; then
        printf 'REFUSE: %s is reachable beyond its owner (%s). The secret must be mode 600:\n' "$KEYF" "$_perm"
        printf '        chmod 600 %s   then re-run this preflight.\n' "$KEYF"
        PF_RC=1
    else
        printf 'transport-key: ok -- present and owner-only\n'
    fi
fi

sec END

# The exit code IS the verdict: 0 only when the transport secret is present and
# owner-only. Every other block above reports; this line is what makes the one
# refusal in this file reach a caller that reads nothing but the status.
exit "$PF_RC"
