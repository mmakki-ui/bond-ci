# p5/test/ledger.sh -- bar bookkeeping shared by the E0 harnesses.
#
# SOURCED, NEVER EXECUTED. It is not part of the shipped set: nothing here ever
# reaches a box.
#
# WHY IT EXISTS. One run of this battery printed 93 unique bar ids and no line
# beginning `FAIL`, and then summarised `91 passed, 2 failed` -- a result the
# harness's own `ok`/`bad` cannot produce, since each of them both prints a line
# AND moves a counter. The output file also carried a spliced partial line. A
# rollback primitive for a box with no console cannot ship with a self-report
# that a reader cannot check, so the bookkeeping is now built so that the
# summary and the bars are THE SAME RECORD rather than two counts that happen to
# agree:
#
#   1. every bar line is appended to a LEDGER FILE the harness creates
#      exclusively, in the same call that prints it;
#   2. the summary is checked against that ledger before it is printed, and a
#      disagreement is itself a reported FAILURE (SC-1) with a non-zero exit --
#      it is not silently reconciled;
#   3. the scratch directory is created with `mkdir`, which FAILS on an existing
#      directory, instead of `mkdir -p`, which adopts one. `$$` alone is not
#      exclusive here: this development machine had 54 leftover `/tmp/p5-*`
#      scratch entries from earlier runs at the time this was written, with pids
#      spanning five and seven digits, so pid REUSE onto a stale directory is
#      not hypothetical. A directory that already exists is stepped over, never
#      shared.
#
# WHAT THIS DOES NOT DO, said plainly: it does not explain the 91/2 run. That
# output file no longer exists and the result was never reproduced. What is
# closed here is the CLASS -- a shared scratch path, and a summary that could
# disagree with the bars without saying so. Whether the class produced that
# particular run is NOT established, and no claim that it did is made anywhere
# in this tree.
#
# A counter lost in a subshell is the one shape that used to be invisible in
# both directions: `cmd | while read; do ok ...; done` prints the bar line and
# throws the increment away with the subshell. The ledger append survives the
# subshell (it is a file), the increment does not, so SC-1 catches it. Bar MU-SC
# seeds exactly that and requires SC-1 to go red.
#
# BUSYBOX-SAFE POSIX sh.

# p5t_workdir PREFIX -> prints a scratch directory this process CREATED, or
# fails. Never adopts an existing directory; steps to the next candidate name
# instead, so a stale leftover cannot wedge a run either.
p5t_workdir() {
    _p5t_i=0
    # 64 is a BOUND, not a tuned value, and it is stated rather than left to be found:
    # candidate names are "$1.$$.<i>", so exhausting it needs 64 live directories sharing
    # ONE pid -- which cannot happen without pid reuse plus 64 stale leftovers of the same
    # name. It exists only so a pathological tree fails FAST instead of spinning forever.
    # If this ever returns 1, the scratch tree is the bug; do not raise the number.
    while [ "$_p5t_i" -lt 64 ]; do
        _p5t_d="${TMPDIR:-/tmp}/$1.$$.$_p5t_i"
        if mkdir "$_p5t_d" 2>/dev/null; then
            echo "$_p5t_d"
            return 0
        fi
        _p5t_i=$((_p5t_i + 1))
    done
    return 1
}

# p5t_ledger_init PATH -- start a fresh ledger and zero the counters.
p5t_ledger_init() {
    P5T_LEDGER="$1"
    : > "$P5T_LEDGER" || return 1
    pass=0
    fail=0
    return 0
}

ok()  { pass=$((pass + 1)); echo "PASS  $1  $2"; echo "PASS $1" >> "$P5T_LEDGER"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1  $2"; echo "FAIL $1" >> "$P5T_LEDGER"; }
chk() { if [ "$1" = 0 ]; then ok "$2" "$3"; else bad "$2" "$3"; fi; }
yn()  { [ "$1" = 0 ] && echo 0 || echo 1; }

# p5t_sc_check LEDGER PASS FAIL -> 0 iff the ledger and the counters agree.
# Sets P5T_LP / P5T_LF to what the ledger says, so a caller can report both
# numbers rather than only that they differ.
#
# `grep -c` exits 1 on a count of zero, so its status is deliberately not read;
# only its output is. The `|| echo 0` idiom is what makes that bite -- on a zero
# count BOTH sides run and the variable becomes two lines of `0`.
p5t_sc_check() {
    P5T_LP=$(grep -c '^PASS ' "$1" 2>/dev/null)
    P5T_LF=$(grep -c '^FAIL ' "$1" 2>/dev/null)
    [ -n "$P5T_LP" ] || P5T_LP=0
    [ -n "$P5T_LF" ] || P5T_LF=0
    [ "$P5T_LP" = "$2" ] && [ "$P5T_LF" = "$3" ]
}

# p5t_report NAME LEDGER PASS FAIL -> prints the summary and returns the
# harness's exit status. The summary is only printed as a verdict once it has
# been reconciled with the ledger; if it cannot be, SC-1 is reported as a
# failure and the status is non-zero even when the counters say zero failures.
#
# The bar-line total is printed as well, so a reader whose CAPTURE lost or
# spliced lines can tell: count the lines beginning PASS/FAIL in what you have
# and compare. That is the check the 91/2 run had no way to make.
p5t_report() {
    echo
    if p5t_sc_check "$2" "$3" "$4"; then
        echo "$1: $3 passed, $4 failed"
        echo "$1: self-checked -- $P5T_LP PASS and $P5T_LF FAIL bar lines were recorded as they were printed, $((P5T_LP + P5T_LF)) bars in total, and the summary above is those same numbers"
        [ "$4" = 0 ]
        return
    fi
    echo "FAIL  SC-1  the summary DISAGREES with the bars it counted: ledger says $P5T_LP passed / $P5T_LF failed, counters say $3 passed / $4 failed. A bar line was emitted whose count was lost (a subshell), or the ledger was written by something other than ok/bad"
    echo "$1: $3 passed, $4 failed -- NOT TRUSTWORTHY, see SC-1 above"
    return 1
}
