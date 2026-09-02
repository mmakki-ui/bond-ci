# p5/ — the P5 product skeleton (E0, ROADMAP U25)

P5 is a **standalone product**. This directory is the product's own shape:
where its files live, how it is installed, how it is removed, how a box says
what is on it, and how a step that could cut the operator's own SSH session is
made to undo itself.

**Spec:** `docs/knowledge/design/p5-execution-handover.md` §3 E0/E7/E8.
**The on-disk contract:** `CONTRACT.md` (prose) + `contract/` (what actually gates).

```
p5/
  bin/p5-install      the single install entry point   (runs from the package)
  bin/p5-uninstall    the single uninstall entry point (installed to /usr/sbin)
  bin/p5-version      version + provenance interrogation (installed to /usr/sbin)
  bin/p5-deadman      automatic rollback for anything that can cut the SSH path
  lib/p5-common.sh    shared busybox-safe sh library
  contract/namespace  the paths P5 may own          -- the installer enforces this
  contract/paths      THE inventory. Everything else is derived from it
  contract/foreign    the paths P5 must never write -- old stack, GL native, and
                      the management-path class
  test/run.sh         the E0 battery (121 bars)
  CONTRACT.md         the statement of the on-disk contract
```

Run the battery: `sh p5/test/run.sh`. Most of the time is two crash matrices —
CR-1 does a full install/recover/reinstall cycle for every one of the 17 points
at which the INSTALLER can be killed, and RCV-1 does the same for every one of
the 14 actions in the REMOVAL plan. Stdlib only. **Wall time is environment
bound and has only been measured on the Windows dev machine (Git Bash), where
it is over an hour** — process creation there is the cost, not the work. It has
not been timed on the Linux CI runner; the "about 8 minutes" this file used to
claim was never measured here and is withdrawn rather than re-guessed.

**CI job `p5-skeleton` (`.github/workflows/emulator-gate.yml:349`) needs two
changes this unit did not make, because `.github/**` is U8's lane:**

1. Its truncation floor is **40 passing bars** (`:364`). The battery now passes
   **93**, so the floor no longer detects a battery that died more than
   half way through — it is a bar that can barely fail. Raise it to 93.
2. It runs `sh p5/test/run.sh` **twice** (`:354` and `:361`), once to gate and
   once to count — two full crash matrices for no extra information. The second
   invocation should be the only one, with the first step deleted.
3. Its header comment is now false: it says the battery "does NOT prove an
   install works end to end" and that "bar IN-8 asserts that a real run STOPS at
   that check". Both were true of round 1. The battery now drives real installs
   with no stubs, and IN-8 is the provenance-validation bar.

---

## The one thing to understand first: the server cannot be reached

The GL-MT2500 at `${SERVER_PC_IP}` has no console, no recovery button and no
power-cycle into failsafe (ROADMAP, **STANDING CONSTRAINT**). Every design
choice below that looks over-careful is there because a step that leaves that
box unreachable loses it permanently.

The rule this tree is written to: **a claim that a failure mode is impossible
must name the mechanism AND the test.** `CONTRACT.md` §5 is that table. Nothing
in it is an intention.

Four consequences worth knowing before reading the code:

1. **Install is additive and switches nothing.** P5's paths are disjoint from
   P1/P2/P3/P4/GL (bar NS-3, checked in both directions), so P5 installs
   *beside* the old stack rather than after removing it. There is never a
   window in which the server carries neither. This is a deliberate departure
   from `p5-execution-handover.md:8`; the reasoning is in `CONTRACT.md` §5 and
   the change back is one line if U26 or Mo disagrees.

2. **The completion marker is the removal of an intent record, not a stamp.**
   The plan is written and synced *before* the first file is placed. A run that
   dies half way is therefore a named state carrying exactly what is needed to
   undo it, instead of an installed-looking box with an incomplete record.

3. **The recovery verb outlives the removal that needs it.** `--remove` takes
   the whole recovery toolchain — `/usr/lib/p5/p5-common.sh`, the three
   contract copies, the rmdir of `/usr/lib/p5`, and `/usr/sbin/p5-uninstall`
   itself, in that order — in ONE final `SELFDROP` action, after every other
   action in the plan (`p5_self_toolchain`; the order is bar `RCV-2`). So a
   kill before ANY action leaves a box that can still finish or reverse its own
   removal with nothing but what is on disk: `RCV-1` kills before all 14 action
   indices and requires the ON-BOX verb — never the package copy — to clear the
   box and let the next install exit 0. And if the run will not finish —
   because a file P5 did not place is still sitting in an owned directory —
   `SELFDROP` decides that BEFORE it unlinks anything and keeps the toolchain
   **whole**, so what the operator is left with is a verb that RUNS, not one
   that merely exists beside a deleted library. Before this, the entry point
   was sorted into the payload pass and the box lost its uninstaller part-way
   through; `MU-RCV` restores that ordering and shows the box being lost, and
   `MU-RCV5` disables the emptiness pre-check and shows the kept entry point
   exiting 5 on its first line.

4. **Nothing here can cut the management path, and E5/E7 can.** E0 writes files
   and nothing else, so a destination gate is complete for E0 (bar MG-1). E5's
   `uci commit firewall` and E7's engarde teardown write nothing forbidden —
   they change the running state of something the SSH session rides. That is
   what `p5-deadman` is for, and `CONTRACT.md` §6 states the rule that binds
   them.

---

## What E0 is, honestly

The **driver is complete and it really installs**, and since U28 **the payload
exists**: `scripts/build-p5-package.sh` builds a real package from a clean
checkout and prints its path on stdout, so
`sh p5/bin/p5-install --package "$(bash scripts/build-p5-package.sh)" --role client --dry-run`
is one command. What it produces:

- `payload/filemap` — `p5/payload/filemap`, verbatim: rows of `mode|role|src|dest`
  whose `src` is the file's **repo** path (ADR-005 §4 leaves source paths alone)
  and whose `dest` is ADR-005 §4's destination under `/etc/p5`, `/usr/lib/p5`,
  `/usr/sbin/p5-*` or `/etc/init.d/p5-*`. Nine rows install for `--role client`,
  two for `--role server` -- the daemon `/usr/sbin/p5-server` and its procd
  service `/etc/init.d/p5-server`, whose source is `deploy/server/init.d/p5-server`;
  every dest is a declared row in `contract/paths`.
- the payload files themselves, copied from the repo, plus the two Go binaries
  cross-compiled here — `p4-bondagg/daemon` → `/usr/sbin/p5-datapath` and
  `p4-bondagg/server` → `/usr/sbin/p5-server`, `GOOS=linux GOARCH=arm64`
  (both boxes are aarch64), which is the packaging decision `CONTRACT.md:348-350`
  assigns to U28.
- `MANIFEST.sha256` pinning **every file in the package** — payload, the filemap,
  `PROVENANCE`, and the driver/library/contract copies. Only the payload half is
  what `p5-install:179-182` walks for completeness; the rest is pinned because
  those are the files that get copied onto a box with no console.
- `PROVENANCE` — commit, branch, tree-dirty flag, build time and builder
  toolchain, in the `key=value` form `p5-install:196-213` shape-checks.
- `bin/`, `lib/`, `contract/` — so the package is self-contained and
  `<pkg>/bin/p5-install` works, which is the real deploy shape.

**Nothing is best-effort.** A filemap row whose `src` is neither built nor in the
repo, a missing Go toolchain, a payload file no row declares, or a manifest the
builder cannot verify all abort the build naming the input. A partial package is
never emitted.

What is still owed by other units:

- **U26 / E7** supplies the OLD-STACK half: `--purge`, and
  `p5-uninstall --check --scope old`. Both exit 6 naming U26 today. Its
  artifact list must come from the old package's own teardown
  (`bond-rollback.sh`, `autoratectl off`, `bondctl` revert, engarde stop —
  `p5-execution-handover.md:80`), **not** from `contract/foreign`, which is a
  refusal list for the installer and a subset. It also owes the
  management-path report (`CONTRACT.md` §7) *before* its first server command.
- **U28 / E8** is the builder above. What it still cannot ship, because no
  destination exists for it yet: the hotplug hook (`contract/paths:159` leaves
  the two-digit priority unset on purpose — E5's derivation), `/etc/config/p5`
  (`:160`, conditional on E5), and `deploy/p5/shape-install`,
  `init.d/cake-autorate`, `shape/*` and `portal/*`, none of which has a
  `contract/paths` row. `/etc/init.d/p5-server` is NOT in that list any more:
  it ships, from `deploy/server/init.d/p5-server`, as the second `--role server`
  row above. `contract/paths:158` marks it *reserved*, and reserved is not a
  bar — `p5_check_dest` admits it exactly as it admits `/etc/init.d/p5-datapath`.
  The server half of `/usr/sbin/p5` (`:156`, `both`) is deliberately unshipped:
  the CLI itself is E5's, and only the client row exists today.
  Each is listed with its reason at the head of `p5/payload/filemap`. Running the 121-bar battery against the built package
  rather than a synthetic one is **U118**.
- **E5** owns init scripts and procd priorities, including the boot hook that
  must call `p5-deadman check`. Until it lands, the deadman's boot limb is
  armed-state-only and `p5-deadman status` says so on every run.

---

## Everything is derived from `contract/paths`

The defect class this round exists to close is two hand-written lists that
could not see each other: what the installer records, and what "clean" means.
Round 1 had both, and both were wrong in the same way — a clean install placed
9 files and recorded 6, and a root carrying seven declared P5 paths reported
CLEAN.

Both are now derived from `contract/paths`, so a declared path is automatically
recorded, automatically checked and automatically planned for removal, and an
undeclared path cannot be installed at all.

**What remains hand-maintained, exhaustively:**

1. `contract/paths` itself — a human adds a row. Bars NS-2/NS-3/NS-4/NS-5
   constrain its shape, its disjointness from `contract/foreign` and its
   agreement with `contract/namespace`.
2. `p5-install`'s source→destination→mode map for the product's *own* files.
   The contract is about destinations; it cannot carry "copied from where, with
   what mode". That map plus the three files the installer synthesises must
   equal the contract's `install`-state file rows **in both directions** —
   asserted at install time, and barred by IN-14 and IN-15.
3. `contract/namespace`'s patterns, tied to the inventory by NS-4.

Nothing else is a list. There is no hand-written removal list and no
hand-written clean predicate. Bar CL-2 proves the derivation by declaring a
path *only* in a test copy of the contract and watching the unmodified
predicate find it.

---

## The four blockers from round 1, and where each is closed

| blocker | closed by | bar |
|---|---|---|
| **B1** the removal record does not record itself (9 placed, 6 recorded) → the box wedges against its own reinstall | `installed.files` now carries every file including the stamp and both records, with one `self-referential` row for itself; and `--remove` is implemented, so there is always a verb that clears the box | `RC-1`, `RC-2`, `VS-4`, `RM-3` |
| **B2** `installed.dirs` is not contract-checked (held `/usr/sbin`, `/etc/init.d`) | its only writer is one loop over the contract's `dir` rows, so it cannot contain a shared directory; the record is re-validated at removal time; recorded directories are removed with `rmdir`, never `rm -rf` | `DR-1`, `RM-6`, `RM-8` |
| **B3** the clean predicate checked 4 of 12 declared paths | derived from `contract/paths` via `p5_present_paths` | `CL-1` (all 26 declared non-uci paths, planted one at a time), `CL-2` |
| **B4** `/etc/rc.d/S??p5-*` is created by P5 and the contract neither declares nor admits it | `contract/paths` gained a `state` axis for everything created after the installer exits — `enable`, `runtime`, `transient`, `uci` — and the clean predicate and the removal plan both handle them by the mechanism that created them | `UN-7`, `RM-9` |

**B1 and B3 shared one root and it is fixed at the root**, not patched twice:
both lists are now one derivation from the inventory.

## Round 2's B1: a CONTRACT row could unlink outside the namespace

The round-2 review demonstrated it by doing it. A `../../` row in
`contract/paths` became a real `UNLINK` of `/etc/dropbear/authorized_keys`,
**and it executed** — on the server that is the box, permanently.

The root was an asymmetry: `build_plan` re-validated every entry of the install
**record** against the contract, while the rows the **contract itself** expands
to — enable globs, runtime globs, runtime dirs — went straight to
`UNLINK`/`RMTREE` with no check at all. But `contract-paths` on a box is a file
on disk exactly like the record: shipped, then editable. And a row does not
have to be hostile to be lethal — a widened glob, a package template whose
substituted variable was empty, or a perfectly correct row under a directory
that has since become a symlink all reach the same `rm`.

So there is now **one gate and everything destructive passes it**:
`p5_removable`, at plan time (`plan_gate`) and again at the point of use, for
`UNLINK`, `RMTREE` and the service name spliced into `SVCDOWN`. `p5_removable`
gained two things it did not have: `/` and any trailing-slash path are refused
outright, and `p5_phys_ok` resolves every symlink on the way to the path and
re-checks the **physical** location. That last one is the only check that can
see the case no string matching can: `/etc/p5/*` is a shipped, correct,
namespace-admitted row, and if `/etc/p5` is a symlink to `/etc/dropbear` then
every hit is *spelled* inside the namespace and *lands* outside it.

One refusal refuses the whole removal, with exit 4 and the offending rows
named — the same rule the record side already followed.

| escape | bar |
|---|---|
| `../..` traversal (the exact round-2 demonstration) | `PS-1` |
| an absolute path wholly outside the namespace | `PS-2` |
| a symlink pointing out, **with no contract edit at all** | `PS-3` |
| a glob that widens (`/etc/*`) | `PS-4` |
| a path collapsed to `/` by an empty substitution, both the `RMTREE` and the `UNLINK` limb | `PS-5` |
| the mutation: stub `p5_phys_ok` and the symlink escape must come back | `PS-6` |
| the toolchain path is swapped out from under the plan MID-RUN and `SELFDROP` must refuse it | `PS-7` |
| the mutation: neutralise that one guard and the same run deletes the file outside the namespace | `MU-PS7` |

`PS-0` does not assert a plan LENGTH — length is a property of the fixture, and
the constant it used to carry (`# end of plan: 18 action(s)`) made a red bar
mean "somebody regrouped the actions". It **re-measures** instead: every path
the hand-built record names must be reachable by the plan, the plan's own tally
must equal the actions it emitted, and the measured length is PRINTED. `MU-PS0`
mutates the shipped planner twice — a lying tally, and a dropped recorded path
— and requires PS-0's own predicate to go red for each, so "PS-0 passes" is
distinguishable from "PS-0 cannot fail". Measured against the pre-fix tree the
escape bars go red and the victim files are deleted; measured against this tree
they are 10/10. `p5/test/pathsanity.sh` runs them, and `test/run.sh` folds its
counts in **through the shared ledger** (`p5/test/ledger.sh`), not through a
grep over its printed output.

Also closed: **PROVENANCE is validated field by field** (IN-8, six mutations);
**IN-9c and IN-10 can now fail** (MU-9c, MU-10 — the package ships three
destinations in three different parent directories, and the tree audit walks
files, directories *and* symlinks); **every override is announced and recorded**
with the sha256 of the contract actually used (VS-8); and the
`P5_UNINSTALL=/bin/true` bypass is **eliminated rather than defended against**
— the gate is computed in-process, so there is no external program to
substitute (IN-17).

`contract/foreign`'s `/etc/config/sqm` and `/etc/config/firewall` entries now
name their replacements: P5 shapes its own tunnel and *observes* GL native SQM
(E4, owner U22), and it owns one named UCI **object** (`firewall.p5`) inside a
file it never owns — the same shape the old stack used for `firewall.engarde`,
and the reason NS-5 exists.

---

## Known limits of a green run

- It does **not** run under busybox ash. There is no busybox on this machine
  (Windows, Python 3.12 only, no WSL/Docker). L-1 is a static lint, not an
  execution proof on the target interpreter.
- Nothing here has ever run on hardware. No P5 install has ever existed on a
  box.
- **ENOSPC is not simulated.** Atomicity is by construction (stage beside,
  sync, rename) and the rename half is exercised (CR-4); a full disk is not.
- **The SHIPPED tools still adopt their scratch directory.** `p5-install:140`,
  `p5-uninstall:253`, `p5-deadman:269` and `p5_hashvec` all build
  `${TMPDIR:-/tmp}/<name>.$$` and `mkdir -p` it. That is the same class the
  harness just had fixed, and it matters more here than there, because
  `$P5_WORK/ordered` is the removal plan — the file written to disk between the
  gate and the `rm`, which is exactly what SELFDROP's new point-of-use check
  exists to survive. Not changed in this unit: it is shipped removal code with
  its own bars (`IN-13` counts those directories), and widening this unit past
  its three defects is how a one-writer commit becomes a merge conflict. **It is
  an open item, not a judgement that it is safe.**
- A **UCI object cannot be probed under a test root**. The clean predicate
  reports those rows as `UNPROBED` instead of guessing, and UN-8 asserts it
  says so — a green verdict always carries the size of its own blind spot.
- The deadman's **timer limb** spawns a real detached sleeper that the battery
  does not wait on. What is tested is the deadline logic all three triggers
  share; there is only one implementation.
- **The counts below are the B2 tree's, not this one's.** The battery was 93
  bars there; U74's and U82's bars took it to **121**, re-measured 2026-08-31 on
  `dev` at `65549dc`: `121 passed, 0 failed`, 121 unique bar ids, exit 0, and
  the harness's own self-check agrees with its summary. The run recorded here is
  kept at its original numbers because a record of a measurement must not be
  restated in a later tree's units.
- **One battery run has never been explained. The CLASS is closed; that RUN is
  not, and this section does not pretend otherwise.** On the B2 tree the
  battery was run three times. Two printed 93 `PASS` lines, 0 `FAIL` lines and
  the summary `93 passed, 0 failed`, exit 0. A third, on the same tree, printed
  93 unique `PASS` ids and NO `FAIL` line yet summarised `91 passed, 2 failed`
  — arithmetically impossible from the harness's own `ok`/`bad`, since each of
  them prints a line and moves a counter in the same call. Its output file also
  carried a spliced partial line.

  **What was found.** Two shared-path defects, both measured, both now closed:

  1. *The harness adopted whatever was at its scratch-directory name.*
     `TMPBASE=${TMPDIR:-/tmp}/p5-e0-test.$$` with `mkdir -p`. `$$` is not
     exclusive here — `p5_fault_point` kills with `kill -9 $$`, which skips the
     cleanup trap, so killed runs leave scratch directories behind by design,
     and pids are reused. Measured while this was being fixed: **54 leftover
     `/tmp/p5-*` scratch entries**, including two `p5-e0-test.<pid>` directories
     dated inside the very window those three runs were taken (03:16 and 04:17
     on 2026-08-31), with pids spanning five and seven digits. Two runs that
     collide on that name share `err`, `out` and the plan files, and either
     one's exit trap deletes the other's fixtures. `ledger.sh` now creates the
     directory with `mkdir`, which fails on an existing one, and steps to the
     next candidate name rather than adopting or wedging (bar `SC-2`).
  2. *The path-sanity fold counted failures a reader could not see.* It ran
     `grep -c '^PASS '` over `pathsanity.sh`'s stdout and then printed that same
     stdout **indented by two spaces**, so a failed `PS-*` bar was added to
     `fail` while being invisible to any `^FAIL` grep of the battery's own
     output — a summary that disagrees with what a reader counts, which is the
     shape of the anomaly. The fold now reads the child's ledger file and prints
     its output verbatim, bar lines at column 0.

  **What is NOT established.** That either defect produced *that* run. The
  output file no longer exists, the result was never reproduced, and no bar was
  ever identified as failing. Anyone reading this should treat the cause of the
  91/2 run as open.

  **What can no longer happen.** The summary and the bars are now one record:
  every bar line is appended to a ledger in the same call that prints it, and
  the summary is reconciled against that ledger before it is printed. A
  disagreement is reported as `SC-1` and exits non-zero instead of being
  printed as a verdict. `MU-SC` seeds the one shape that used to be invisible
  in both directions — a counter lost in a subshell — and requires `SC-1` to go
  red; on the pre-fix bookkeeping the same scenario printed two `PASS` lines,
  summarised `1 passed, 0 failed` and exited 0.
- **The removal has one window the ordering cannot close, and it is named
  rather than argued away.** `RCV-1` covers a kill BETWEEN actions. A SIGKILL
  landing *inside* the final `SELFDROP` — between two of its five unlinks — can
  still strand the toolchain half-removed, and the on-box verb is then either
  gone or unable to source its library. What that leaves is a subset of those
  five paths and nothing else: no payload, no stamp, no records. Recovery there
  DOES need the package. It is bounded by two things rather than by hope: the
  operator who hits this state is by definition running `p5-install`, which
  runs from a package that also carries `bin/p5-uninstall`; and `p5-install`
  now resolves its remedy through `p5_recovery_verb`, so it names that package
  copy instead of the box path that may be gone (`RCV-3` reads the message and
  checks the file exists, `RCV-4` runs exactly what the message named and
  requires a clean box and a successful reinstall). Making the window zero
  would need an atomic multi-unlink, which this filesystem does not offer.
- `p5-uninstall --remove` on a `damaged` box needs `--recover`, and after a
  crash between the intent-record drop and the `rmdir` pass the box lands in
  `damaged`. That is a remedy, not a wedge — every tool names it — but it is
  one extra flag on a box nobody can walk up to.

## U25 adjudication (2026-08-31) — what five lenses found, and what is still open

The E0 skeleton went through four adversarial lenses (severance, interrupt,
escape, activation) plus an address read, and one adjudication pass. Everything
below was RE-MEASURED by the adjudicator against this tree, not carried over
from a lens report. **Every result is a temp root under Git Bash on Windows.
Nothing in E0 has run on either box, or under busybox ash, or under dash.**

### Closed in this pass

- **The documented removal verb did not work, on either role.** `--remove` with
  no `--role` exited 4 and unlinked nothing; `--remove --dry-run` exited 4 with
  no plan printed; `--remove --recover` exited 4. The refusal blamed the install
  record ("version-skew guard") when the record was correct and the row filter
  was wrong. Every remedy string in this product and `CONTRACT.md`'s own
  signature spelled the broken form. Invisible to an 86/0 battery because all 53
  `--remove` call sites in `test/run.sh` passed `--role` explicitly. Fixed at
  the resolution point in `p5-uninstall` (flag, then stamp, then refuse by
  name), NOT by widening the row filters — those are shared with
  `p5_check_dest` on the install side, where a wildcard role would let the
  installer place any role's payload. Bars: RR-1..RR-4, mutation MU-RR.
- **PS-0 owned a constant it could not own** (`# end of plan: 18 action(s)`).
  Plan length is fixture-dependent — 12, 13, 14, 16 and 18 have all been
  measured on this tree — so the only way to clear that red was to edit the
  number, which is weakening a bar to go green. It now re-measures: every
  recorded path must be reachable by the plan, and the plan's own tally must
  equal the actions it emitted. Both halves are demonstrated falsifiable — a
  lying tally and an unreachable recorded path each turn it red.

### Closed in the follow-up pass (U74 / U75 / U76)

The adjudication above left three things that a green run could not have caught,
all in the same three files, so they were done as one unit with one writer.

- **U74 — the constant survived in PROSE, and the demonstration was not a bar.**
  `PS-0`'s predicate was already re-measuring, but this file and
  `pathsanity.sh`'s own header still told the reader it "asserts the same
  18-action plan", and the two falsifiability demonstrations lived in a commit
  message rather than in the harness. Both claims corrected, and `MU-PS0` now
  mutates the SHIPPED planner two ways — a constant tally, and step (b) dropping
  a recorded path — and requires the same predicate `PS-0` passes to refuse each.
  Measured on the merged root: the plan is **13 actions**, so the retired
  constant was red on a correct tree.
- **U75 — `SELFDROP` re-checks at the point of use.** See the entry below, now
  struck through. `PS-7` / `MU-PS7`.
- **U76 — the summary and the bars are one record.** Two shared-path defects
  found and closed (an adopted scratch directory, and a fold that counted
  failures a reader could not see); the summary is now reconciled against a
  ledger written by `ok`/`bad` themselves, and a disagreement is `SC-1` with a
  non-zero exit rather than a printed verdict. `SC-1`, `SC-2`, `MU-SC`. **The
  91/2 run itself is still not explained and is not claimed to be** — see the
  known-limits entry above.

### Measured, NOT fixed — this is why E0 does not merge

- ~~**A contract glob row can make `--remove` EXECUTE an undeclared
  `/etc/init.d/p5-*` as root.**~~ **CLOSED — U146.** The defect was real as
  written: `emit_plan` step a gated the `/etc/rc.d` FLAG (`plan_gate file
  "$hit"`) and then emitted `SVCDOWN`, which execs `/etc/init.d/<svc>
  stop|disable`; the file that is EXECUTED was never gated — neither planner
  nor executor asked about it, both only anchored the NAME to `p5|p5-*`. It was
  reproduced on the RECOVERY path with no rogue name and no contract edit: a
  record-less (`damaged`) box — the exact state `--recover` exists for —
  carrying `/etc/init.d/p5-datapath` and its `/etc/rc.d/S94p5-datapath` flag ran
  that script twice as root and `--remove` exited **0**; in the reproduction the
  script deleted the operator's SSH key. The asymmetry that made it reachable is
  in the contract itself: `/etc/rc.d/[SK][0-9][0-9]p5-*` is `role=both` while the
  init scripts it points at are `role=client` / `role=server`, so the flag
  survives every role filter its own target does not. **What changed:** the
  README argued it was not yet reachable because E0 ships no init script and
  only E5 ships `/etc/init.d/p5-server`; U28's package ships that file on
  `--role server`, so it lands on the box with no physical access at install
  time. **The fix:** the EXECUTED file now goes through the SAME predicate as
  the flag beside it (`p5_removable`, i.e. declared by `contract/paths` for this
  role, in the namespace, not foreign, physically where it says it is), in
  BOTH the planner and the executor — the planner refuses the whole removal
  (exit 4, nothing unlinked, nothing executed), and the executor re-asks at the
  point of use because the plan is written to disk in between, exactly as
  `UNLINK` and `RMTREE` already did. Closing it also surfaced a second, smaller
  hole and closed it: an executor refusal used to be invisible in the EXIT
  STATUS, because the verdict is `p5_half_clean` and an undeclared
  `/etc/init.d/p5-*` is not a P5 path — the P5 half really is clean afterwards,
  so the run exited **0** after declining to act. It now exits 4 and says why.
  **Recovery is not made impossible, and that was the constraint** — but the
  first cut of this fix DID wedge one recovery, and the round that closed it is
  the reason this paragraph is worth reading. Round 1 asked the gate about the
  service NAME whether or not `/etc/init.d/<svc>` existed. A **stale rc.d flag
  whose target is absent** — the state `contract/paths:182` names out loud
  (*"or the flag outlives its target"*, which is why that glob is `role=both`)
  and an ordinary state for a record-less box — therefore refused the WHOLE
  removal: exit 4 with P5 still installed, where the pre-gate code cleared the
  flag and exited 0. On `${SERVER_PC_IP}` that is a wedge, not a warning. And the
  printed remedy did not converge: it named only the init script, so following
  `mv /etc/init.d/<file> /root/` hit the identical refusal, and the one step
  that ended it — removing the flag — was never named. **Both are fixed in
  code, not in wording:** the gate's precondition is now the execution's
  precondition (`-x` on the file, in the planner and again in the executor), so
  a flag with nothing behind it plans no `SVCDOWN` and is simply unlinked; and
  the refusal prints BOTH ends of the pair, the file to move and the flag to
  drop, either of which converges. `--recover` on a record-less box still
  removes everything P5 declares, and a DECLARED init script is still stopped
  and disabled normally — on a fresh root (`EXG-2`) and on the record-less root
  the gate actually lives on (`EXG-5`). Bars: `EXG-1` (planner refuses, sentinel
  absent, tree byte-identical), `EXG-2` (a declared service is still stopped and
  disabled — not a blanket refusal), `EXG-3` (with the planner's gate removed
  the executor still refuses, exit 4), `MU-EXG` (with BOTH removed the same
  fixture executes the rogue script — so `EXG-1`/`EXG-3` are bars that can
  fail), `EXG-4` (a stale flag with NO target removes cleanly, exit 0, flag
  gone — the pre-gate semantics, pinned), `EXG-5` (declared service on a
  record-less root), `EXG-6` (the refusal names both paths, and FOLLOWING what
  it printed — either the `mv` or the `rm` — makes the next run exit 0 with the
  rogue script never executed and, on the `rm` path, still present: the product
  does not delete what it refused). `FL-1` puts a bar-count floor inside the
  battery, where the local gate arm can see it.
- ~~**SELFDROP has no point-of-use gate.**~~ **CLOSED.** B1 added a
  `p5_removable` re-check to UNLINK and RMTREE precisely because the plan is
  written to disk between build and execute; the SELFDROP arm had zero
  `p5_removable` calls and still ran `rm -f` on `/usr/lib/p5` and `/usr/sbin`
  targets — the arm that removes the recovery toolchain of a box with no
  console, covered by no bar. It now asks the same predicate, at the point of
  use, and a refusal keeps the file, reports why and marks the run unfinished
  so the "KEEPING the toolchain" message stays true. `PS-7` swaps
  `/usr/lib/p5` for a symlink out of the namespace MID-RUN — from a `stop`
  handler the product's own `SVCDOWN` executes, so the change is deterministic
  rather than a race — and requires the operator's file to survive with the
  refusal named; `MU-PS7` neutralises that one guard and the same run deletes
  it. **The mid-run lever was the executor defect above, used only as a clock;
  nothing in that unit fixed it — U146 did, and PS-7 still holds.**
- **A path DERIVED from a gated path is not itself gated.** UNLINK and SELFDROP
  both follow the gated `rm -f "$arg"` with an ungated
  `rm -f "$(p5_incoming_of "$arg")"`. Measured: decoys planted at staging names
  under `/usr/sbin`, `/etc/init.d` and `/etc/hotplug.d/iface` — all outside the
  namespace by this product's own `p5_ns_ok` — were deleted, exit 0, driven by
  the SHIPPED `glob|both|/etc/rc.d/[SK][0-9][0-9]p5-*` row with no contract
  edit. The string `.p5-incoming` appears ZERO times in the printed plan, while
  that same plan prints "NOT in this plan, and never will be: any directory P5
  does not exclusively own ... /usr/sbin, /etc/init.d and /etc/hotplug.d/iface
  ... cannot be recorded or removed." Bounded — the prefix is a fixed literal so
  the basename cannot be steered onto `authorized_keys` — but the printed
  invariant is false as written. **Still open after the SELFDROP gate landed,
  and deliberately so:** that gate judges the path the plan NAMES, and the
  `p5_incoming_of` line runs after it on a path the plan never named. Both call
  sites now carry a comment saying that out loud rather than reading as covered.
- **Install and removal use DIFFERENT gates, and they disagree in the direction
  "installable, not removable".** `p5_phys_ok` is called from exactly one place,
  `p5_removable`. `p5_check_dest` — the install gate — is `p5_path_sane` plus
  `p5_foreign` plus `p5_ns_ok` plus `p5_declared`, all lexical. So a box whose
  ancestor directory is a symlink takes the install (exit 0, product written
  outside the namespace) and then refuses every removal: `--remove` 4,
  `--remove --recover` 4, `p5-install` 5 printing "Remedy: p5-uninstall
  --remove". Reached on a first clean install with no operator error.
- **One ordinary filename in E6's fact directory wedges the box.** Measured on
  three names — `wan cfg`, `wan..cfg`, `wan[0].cfg`: `--remove` 4 with 14 files
  left, `--recover` 4, reinstall 5. Control `wan.cfg` gives 0 and a clean box.
  Cause: `p5_glob_hits` expands `${P5_ROOT}$1` UNQUOTED, so a hit word-splits
  and re-globs, and one bad expansion refuses the WHOLE removal.
  `contract/paths` says of that glob "Names are E6's" — the names that wedge the
  box have not been chosen yet. The refusal text tells the operator to "Fix the
  row (or the symlink)"; the row is fine, and the named remedy does not apply.
  The same unquoted expansion is a live HARNESS artifact: a test root whose path
  contains a space silently produces a SHORTER plan with no error, so a battery
  run from a directory with a space in it tests a smaller subject and cannot
  know it. This repository's own checkout path contains a space.
- **A power cut inside `p5_atomic_write` of the install intent record leaves a
  box no product path can clear.** On a bare box holding only
  `/usr/lib/p5/.p5-incoming.install.inprogress`: `p5-install` 5, the PACKAGE's
  `p5-uninstall --remove --recover` 1 with the file still present, `p5-install`
  5 again. Only a hand `rm -f` over SSH clears it, after which install returns
  0. The two `inprogress` rows are excluded from every UNLINK emission and are
  handled by DROPINTENT, a bare `rm -f` with no `p5_incoming_of` sweep.
  Control: the same stray staging files on a POPULATED box ARE swept (exit 0,
  nothing left) — the wedge is specific to the fresh-install cut, which is
  exactly the case with no recovery verb on the box.
- **The deadman silently truncates a multi-line rollback and then retires itself
  as successful** — `p5_deadman_field` is `grep | head -1` and `do_arm` writes
  the value verbatim with no shape check. Neither automatic firing limb has ever
  been exercised: the boot limb is stated OPEN and unwired, and all ten DM-*
  bars pass `--no-timer`.

### Not settleable here — one command each

- Whether `/var` is a symlink to `/tmp` on these boxes. Any symlinked ANCESTOR
  of a declared path refuses the entire removal, exit 4 — measured. Whether that
  fires on the real boxes is one command per box:
  `ls -ld /var /usr/lib /usr/sbin /etc/rc.d`. `scripts/box-inventory.sh` does
  not collect it.
- Whether the client's `usb0` default gateway is literally `${SERVER_PC_IP}`. Both
  U40 inventories carry addresses but no routing-table section, so that fact
  still rests on `docs/INTENT.md:216`, captured one day earlier. Settling
  command, run ON THE CLIENT: `ip route show default`. The collision stays
  inert either way — re-verified on this tree, all 7 hits of `${SERVER_PC_IP}` under
  `p5/` and `.github/` are comments or prose, none is an executable
  `ssh` / `scp` / `curl` / `wget`.
