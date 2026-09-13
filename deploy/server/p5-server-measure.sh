#!/bin/sh
# shellcheck shell=sh
# p5-server-measure.sh -- READ-ONLY. Turns the C4 footprint bound (U129,
# GOAL.md:32) into a number on the actual box, before and after S3-S6 of
# docs/deploy-p5-server.md.
#
# WHY THIS EXISTS, and it is not "more preflight". p5-server-preflight.sh asks
# whether it is SAFE to install; this asks what the daemon's footprint
# ACTUALLY IS once installed, and -- the number that answers C4 -- whether
# every OTHER peer the server carries is still unaffected. "Minimal footprint"
# is a claim about a running process; a stanza with `nice`/`limits`/
# `GOMAXPROCS` in it is evidence of INTENT, not of EFFECT, until something
# reads the box.
#
# READ-ONLY, same guards as p5-server-preflight.sh (:53-60 there): `have()`
# checks a tool before using it, `sec()` marks a section, and every probe
# degrades to a printed "(absent)" rather than a failure. Starts nothing,
# stops nothing, writes no file, sets no uci value, reloads no service.
# deploy/server/test-p5-server-footprint.sh bar FP-5 holds this file to that.
#
# RUN IT FROM THE PC, NEVER FROM THE CLIENT BOX -- same identity rule as
# p5-server-preflight.sh. Run it twice: once BEFORE S3 (nothing installed --
# the baseline every other number is read against) and once AFTER S6 (the
# daemon has carried real traffic). The `wg show` block is the load-bearing
# one: it prints `date +%s` alongside every peer's raw handshake epoch so the
# age (now - epoch) is computable from either run. The criterion is PER-PEER,
# not a blanket freshness check -- WireGuard only rekeys on traffic/keepalive,
# so an idle peer's epoch legitimately sits unchanged for days (measured on
# the server: docs/knowledge/inventory/2026-08-30-server-brume2.txt:152-174
# shows peers at 53s, 1 day, 12 days and two that have NEVER handshaked --
# every one of those is a normal idle peer, not a fault). So: a peer FRESH at
# baseline must still be fresh after S6; a peer IDLE at baseline staying
# unchanged after S6 is expected; a peer that WAS fresh at baseline and goes
# unchanged/stale after S6 is the regression this step exists to catch.
# Runbook section 7 item 1 states it this way.
#
#   ssh root@<server> 'sh -s' < deploy/server/p5-server-measure.sh | tee footprint-before.txt
#   ... S3 - S6 ...
#   ssh root@<server> 'sh -s' < deploy/server/p5-server-measure.sh | tee footprint-after.txt
#
# POSIX sh / busybox. No bashisms, no arrays, no fractional sleep.

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n### %s\n' "$1"; }

# ---------------------------------------------------------------- identity --
sec identity
printf 'hostname: %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
printf 'date:     %s\n' "$(date 2>/dev/null)"
_h=$(cat /proc/sys/kernel/hostname 2>/dev/null)
case "$_h" in
  GL-MT2500) printf 'verdict:  SERVER (Brume 2) -- this is the box C4 bounds.\n' ;;
  GL-MT6000) printf 'verdict:  CLIENT (Flint 2) -- this script measures the SERVER; wrong box.\n' ;;
  *)         printf 'verdict:  UNRECOGNISED -- confirm the box before trusting these numbers.\n' ;;
esac

# ------------------------------------------------------------- p5-server ----
# rss/vsz/pcpu answer "how much of the box does the daemon use right now".
# Absent entirely (not installed, or not running) is a valid, printed answer.
sec p5-server-process
_pid=""
if have pgrep; then
    _pid=$(pgrep -f '/usr/sbin/p5-server' 2>/dev/null | head -1)
fi
# Anchored on argv[0], not a substring of the whole cmdline: cmdline is
# NUL-separated, `tr '\0' '\n' | head -1` reads exactly the first field, and
# that field must equal the contract-reserved path byte-for-byte. A substring
# grep for 'p5-server' would also match this measurer's own filename
# (p5-server-measure.sh) or any wrapper whose argv happens to carry the
# string -- anchoring to argv[0] == /usr/sbin/p5-server matches the pgrep
# pattern above (:63) instead of being looser than it.
if [ -z "$_pid" ] && [ -d /proc ]; then
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _argv0=$(tr '\0' '\n' < "$_p/cmdline" 2>/dev/null | head -1)
        if [ "$_argv0" = "/usr/sbin/p5-server" ]; then
            _pid=$(basename "$_p")
            break
        fi
    done
fi
if [ -n "$_pid" ]; then
    printf 'pid: %s\n' "$_pid"
    if have ps; then
        # BusyBox ps -o rejects 'pcpu' (BusyBox v1.36.1: "ps: bad -o argument
        # 'pcpu'"; reproduced against the target's ps applet, not just this
        # host's). rss/vsz/args are supported -- print those from ps, and read
        # CPU time straight from /proc/<pid>/stat below, which works
        # regardless of which ps build is on the box.
        ps -o pid,ppid,rss,vsz,args 2>/dev/null | head -1
        ps -o pid,ppid,rss,vsz,args 2>/dev/null | grep "^[[:space:]]*${_pid}[[:space:]]" \
            || printf '(ps did not report pid %s)\n' "$_pid"
    else
        printf 'ps: (absent)\n'
    fi
    if [ -r "/proc/$_pid/stat" ]; then
        # man proc(5): fields are pid (comm) state ppid ... utime(14) stime(15)
        # in clock ticks. comm can itself contain ')' or spaces, so strip
        # through the LAST ') ' (greedy ##) rather than splitting on
        # whitespace from the start; after that strip, state is field 1 of
        # what remains, so utime is field 12 and stime is field 13.
        _stat_rest=$(cat "/proc/$_pid/stat" 2>/dev/null)
        _stat_rest=${_stat_rest##*) }
        # shellcheck disable=SC2086
        set -- $_stat_rest
        printf 'cpu-ticks (utime+stime, /proc/%s/stat, sysconf CLK_TCK not queried): %s+%s\n' \
            "$_pid" "${12:-?}" "${13:-?}"
    fi
    if [ -r "/proc/$_pid/status" ]; then
        grep -E '^(VmRSS|VmSize|Threads):' "/proc/$_pid/status" 2>/dev/null
    fi
else
    printf '(p5-server is not running)\n'
fi

# --------------------------------------------------------------- rc.d ------
# S7 is deferred (deploy-p5-server.md section 6). A rc.d symlink here BEFORE
# an operator has deliberately enabled it is the thing the runbook exists to
# prevent -- print the count, do not assume it is zero.
sec rc-d-p5-server
printf 'S<pri>p5-server symlinks in /etc/rc.d: %s\n' \
    "$(ls /etc/rc.d 2>/dev/null | grep -c 'p5-server')"
ls /etc/rc.d 2>/dev/null | grep 'p5-server' || printf '(none)\n'

# ------------------------------------------------------------- owned ports --
sec p5-server-owned-ports
if _p5_udp=$(netstat -ulnp 2>/dev/null) && [ -n "$_p5_udp" ]; then
    printf '%s\n' "$_p5_udp" | { head -1; grep ':59402' || printf '(nothing on :59402)\n'; }
    printf '(source: netstat -ulnp)\n'
elif have ss; then
    ss -ulnp 2>/dev/null | { head -1; grep ':59402' || printf '(nothing on :59402)\n'; }
    printf '(source: ss -ulnp)\n'
else
    printf '(neither netstat nor ss produced a UDP listener table)\n'
fi

# ------------------------------------------------------------- firewall ----
sec firewall-p5
printf 'firewall.p5 uci objects: %s\n' \
    "$(uci show firewall 2>/dev/null | grep -c '^firewall\.p5')"
uci show firewall 2>/dev/null | grep '^firewall\.p5' || printf '(none)\n'

# --------------------------------------------------------------- deadman ---
sec p5-deadman-crontab
if [ -f /etc/crontabs/root ]; then
    printf 'p5-deadman lines in /etc/crontabs/root: %s\n' \
        "$(grep -c 'p5-deadman' /etc/crontabs/root 2>/dev/null)"
    grep 'p5-deadman' /etc/crontabs/root 2>/dev/null || printf '(none)\n'
else
    printf '(no /etc/crontabs/root)\n'
fi

# ------------------------------------------------------------------ wg -----
# THE load-bearing block. `wg show all latest-handshakes` prints a UNIX EPOCH
# per peer, not an age -- so `date +%s` is printed alongside it, here, on
# every run, and the age is (that date) minus (the epoch), computed by
# whoever reads footprint-before.txt / footprint-after.txt.
#
# THE PASS CRITERION IS FRESHNESS, NOT EQUALITY. A healthy peer re-handshakes
# every ~2 minutes; an epoch that is IDENTICAL between the before and after
# run means that peer's handshake went STALE while p5-server ran -- the
# regression this script exists to catch, not the proof of health. The proof
# C4 asks for is: every peer's handshake is still FRESH after S6 (close to
# `date +%s` at read time), not that any two numbers match. This is not
# caught by any bar in test-p5-server-*.sh -- those read shipped text; only a
# run on the box reads this.
sec wg-show-all-peers
printf 'now (epoch, date +%%s): %s\n' "$(date +%s 2>/dev/null)"
if have wg; then
    wg show all latest-handshakes 2>/dev/null || wg show 2>/dev/null
else
    printf '(wg absent)\n'
fi

# --------------------------------------------------------------- memory ----
sec memory-and-disk
if have free; then free 2>/dev/null; else cat /proc/meminfo 2>/dev/null | head -5; fi
if have df; then df -h /overlay 2>/dev/null || df -h 2>/dev/null; fi

# --------------------------------------------------------------- logs ------
sec logread-p5-server
if have logread; then
    printf 'p5-server lines in logread: %s\n' "$(logread 2>/dev/null | grep -c 'p5-server')"
else
    printf 'logread: (absent)\n'
fi
