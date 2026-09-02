# The P5 on-disk contract

Every path P5 owns, so E7 can remove precisely those and nothing else.

The machine-readable form is what actually gates: `contract/namespace` (the
rule the installer enforces), `contract/paths` (the inventory) and
`contract/foreign` (what P5 must never write). This file is the statement of
what those three files mean and why they are shaped that way. If it and they
disagree, **they win** — they are the ones the installer and the tests read.

---

## 1. The contract has two levels, because "what P5 owns" has two answers

| level | artifact | answers | who reads it |
|---|---|---|---|
| design-time | `contract/paths` + `contract/namespace` | what P5 is **allowed** to own on any box, ever | the installer (refuses anything else), the tests, a human reasoning about scope |
| install-time | `/usr/lib/p5/installed.files` + `installed.dirs` | what P5 **did** own on **this** box at **this** version | E7 (removes exactly this), `p5-version --verify` |

E7 removes the install-time record, not the design-time list. The design-time
list bounds it: a path outside `contract/namespace` was never P5's, so E7 must
not touch it even if it looks related. The record is per-file sha256 in
`sha256sum` output format, so it survives version skew (a box installed at
version A is removed correctly by an uninstaller shipped with version B, as
long as the contract schema version in the stamp is one that uninstaller
understands).

Anything E7 removes that is **not** in the record is old-stack removal — a
different list, a different owner (U26), and a different justification. It must
come from the old package's own teardown (`bond-rollback.sh`, `autoratectl
off`, `bondctl` revert, engarde stop — `p5-execution-handover.md:80`), **not**
from `contract/foreign`, which is a refusal list for the installer and is a
subset.

---

## 2. The namespace, and why it is disjoint from everything else

P5 owns, and may only own:

| path | role | what |
|---|---|---|
| `/usr/sbin/p5`, `/usr/sbin/p5-*` | both | executables and the operator CLI |
| `/usr/lib/p5/`, `/usr/lib/p5/*` | both | product metadata: the stamp, the install record, the shared library, the shipped contract copies |
| `/etc/p5/`, `/etc/p5/*` | both | configuration and discovered facts |
| `/etc/config/p5` | both | UCI config, **if** E5 chooses UCI (otherwise the row and the pattern get deleted, not left standing) |
| `/etc/init.d/p5-*` | both | procd services |
| `/etc/hotplug.d/iface/[0-9][0-9]-p5` | client | the netifd hook; the priority digits are deliberately unset |
| `/var/run/p5/`, `/var/run/p5/*` | both | volatile runtime state (tmpfs; not in the removal record — a reboot clears it) |

Three things fix this shape, none of them taste:

1. **The OpenWrt/GL.iNet stock layout** decides the roots. Executables in
   `/usr/sbin`, product data in `/usr/lib`, config in `/etc`, procd services in
   `/etc/init.d`, netifd hooks in `/etc/hotplug.d/iface`, volatile state in
   `/var/run`.

2. **The standalone-product requirement forces the `p5` infix.** The deploy
   shape is "cleanly uninstall the old package, then install P5 fresh"
   (`p5-execution-handover.md:8`). For E7 to remove precisely the old stack and
   precisely P5, no path may be claimed by both — otherwise "remove exactly
   this and nothing else" is not a decidable question, and a rollback to the
   frozen P1–P3 baseline cannot be reasoned about at all. The old stack
   occupies `/etc/bond`, `/usr/sbin/{bond-*,bondctl,engarde-*}`,
   `/etc/init.d/{bond-*,engarde-*,cake-autorate,sqm}`,
   `/etc/hotplug.d/iface/{97-bond,98-wg-autorate,99-tether-autorate}`,
   `/etc/wg-*`, `/root/cake-autorate`, `/var/run/bond`. Disjointness from that
   set is the requirement; the infix is the cheapest way to get it.

   **This has a consequence worth stating before someone discovers it in a
   diff: the datapath binary cannot install as `/usr/sbin/bond-agg`.** That
   path is on the old stack's removal list. It installs under a `p5-*` name.
   Test bar NS-3 asserts the disjointness mechanically, so a later widening of
   the namespace that reclaims an old-stack path goes red and names the
   collision.

3. **What is deliberately NOT owned.** `/var/log/*` — OpenWrt logging is syslog
   via `logger`, and a P5 log file is a decision nobody has made. `/root/*` —
   the old stack scattered binaries and helpers into the operator's home
   directory; P5 puts nothing there. Any GL.iNet native config surface
   (`/etc/config/network`, `firewall`, `wireless`, `sqm`, …) — the
   non-interference constraint (`p5-execution-handover.md:26`) is enforced here
   as a write refusal, not as an intention.

---

## 3. The version and provenance stamp

`/usr/lib/p5/stamp` is `KEY=value` text, written by `p5-install`, read by
`p5-version`. It is **parsed, never sourced**: sourcing would execute whatever
a corrupted stamp contained, and the point of the stamp is to be trusted when
nothing else on the box is.

| field | answers |
|---|---|
| `P5_CONTRACT_VERSION` | which on-disk layout this is. An uninstaller meeting a higher version than it understands must refuse, not guess |
| `P5_PRODUCT`, `P5_VERSION` | what product, what release |
| `P5_GIT_COMMIT`, `P5_GIT_BRANCH`, `P5_GIT_DIRTY` | exactly which source. `DIRTY` is carried and printed rather than refused — a hand-built package for a lab box is legitimate, but it must be visible **on the box**, not remembered |
| `P5_BUILT_UTC`, `P5_BUILDER` | when and where the package was built |
| `P5_PKG_MANIFEST_SHA256` | one number pinning the whole payload |
| `P5_INSTALLED_UTC`, `P5_INSTALL_ARCH` | when this box was installed, and on what. Arch is recorded because the daemon binary is arch-specific and picking the wrong one is a live risk — `uname -m` has still never been run on either box |
| `P5_ROLE` | client or server |
| `P5_INSTALL_FILES`, `P5_INSTALL_DIRS` | where the removal record lives |
| `P5_E1_VERDICT` | `unmeasured` \| `edge` \| `mid`. E1 sets the enablement of the cap and the standing lightning (`p5-execution-handover.md:85`); it has not run, so the value is `unmeasured` and the open gate is visible **on the box** rather than only in a document |
| `P5_FEATURES` | which optional mechanisms this install actually enabled |
| `P5_INSTALL_OVERRIDES` | which environment overrides were in effect for this install, by name. Empty on a normal one |
| `P5_CONTRACT_NS_SHA256`, `P5_CONTRACT_FOREIGN_SHA256`, `P5_CONTRACT_PATHS_SHA256` | the sha256 of each contract file the install was actually **judged against**. With the line above, this makes an install judged against a mutated contract detectable on the box afterwards, rather than only in someone's shell history |

The fields the package supplies (`P5_PRODUCT` through `P5_BUILDER`) are copied
**verbatim** from the package's `PROVENANCE` file, so the stamp cannot disagree
with the package it came from — and every one of them is **shape-checked
first**. A bare `grep` with no check that anything matched writes a stamp that
looks authoritative and carries none of the fields it exists for, which is worse
than writing no stamp: it answers the question wrongly instead of not answering
it. Bar IN-8 mutates six provenance fields and asserts exit 3 with zero files
written for each.

`installed.files` contains **every** file the install placed, itself included.
Exactly one row — its own — carries the token `self-referential` in the hash
field, because a file cannot record its own sha256: the value changes the moment
it is written. `--verify` reports that row as `SELFREF` (present, hash not
verifiable by construction) rather than skipping it. Leaving the record out of
the record is what wedged the box in round 1: a clean install placed 9 files and
recorded 6, and an uninstaller obeying the contract verbatim left the three
behind, kept `/usr/lib/p5` non-empty, and made every later install refuse. Bars
RC-1 and RC-2 count both sides on the real tree.

`p5-version --verify` re-hashes every recorded file against the record and
names each `MISSING` or `CHANGED` path. That is **drift detection, not
authentication** — anyone who can change a file can change the record.
Authenticating an install is out of scope for E0; the related transport
question is ROADMAP U31.

---

## 4. The four entry points

**`p5-install --package DIR --role client|server [--dry-run]`** — the only
thing that installs P5. It runs from the unpacked package and is not itself
installed on the box: a box with no package has nothing to install. Its order
is fixed and each step refuses rather than continues:

1. tools and contracts present — and the hasher is proved to *be* a hasher by a
   sha256 test vector, because `P5_SHA256` is an override and a program that
   printed plausible hashes would defeat both the manifest check and the record
2. package layout complete (`MANIFEST.sha256`, `PROVENANCE`, `payload/filemap`)
3. **integrity** — the manifest verifies (corruption / partial `scp`) **and** is
   complete: a payload file the manifest does not pin is a file nobody signed
   off, and a manifest-only check would install it silently
4. **provenance is validated, field by field.** Every field the stamp will carry
   is shape-checked. A bare `grep` with no check that anything matched produces
   a stamp that looks authoritative and carries none of the fields it exists
   for, which is worse than no stamp at all
5. **the box is in a state this tool understands** — computed in-process (§5),
   not by asking an external program. `clean` is the only state an install
   proceeds from; every other state names itself and names its remedy
6. **contract** — every destination in the filemap is judged against
   `contract/foreign`, then `contract/namespace`, then `contract/paths`. Any
   violation refuses the **whole** install; there is no partial install with the
   bad row skipped
7. the installer's own file set is checked against the contract's
   `install`-state rows in **both** directions and aborts on any divergence
8. `--dry-run` stops here, having printed the placement set, the owned
   directories, and the removal set that would result
9. the **install intent record** goes down first, synced (§5)
10. owned directories are created and recorded; files are placed atomically
11. `installed.dirs`, then the stamp, then `installed.files` — in that order,
    because each needs the hash of the one before it
12. the intent record is dropped. **That**, not the stamp, is the completion
    marker

It enables nothing, starts nothing, stops nothing and commits no config. It
seeds no configuration: `/etc/p5/*` is declared `state=runtime`, so the
installer *cannot* place a fact there. An installer that writes a value nobody
measured is an installer that ships a constant — which is precisely how the old
runbook's `echo 20000,15000 > /etc/bond/agg_w` silently defeated U6 (removed in
`52a76d3`). Bars IN-6 and IN-16 are those two lines, as bars.

**`p5-uninstall --check | --list | --remove | --purge  [--role client|server]`**
— the only thing that removes P5. The **P5 half is E0's and is implemented**:
`--check` (derived from `contract/paths`), `--list`, and `--remove` (with
`--dry-run` and `--recover`).

`--role` is optional and is resolved by `p5-uninstall` in one place: an explicit
flag wins; otherwise the role is read from `P5_ROLE` in the install stamp, and
the run says so; otherwise — a box with no readable stamp — the run refuses with
exit 2 naming the flag. **This signature previously omitted `--role` entirely,
and that omission was load-bearing**: `RROLE="${ROLE:-both}"` fed `both` to
`p5_declared`/`p5_rows`, which treat `both` as a literal row VALUE and not a
wildcard, so the documented invocation matched no client and no server row,
exited 4, removed nothing, and blamed the install record. U25's adjudication
measured it end to end on both roles; RR-1..RR-4 and MU-RR are the bars.
The **old-stack half is U26/E7's**: `--purge`, and `--check --scope old`, exit 6
naming their owner.

That split moved from round 1, where `--remove` was unimplemented too. The
result was a box that could be wedged against *both* its own reinstall and its
own removal. The P5 half of removal is fully determined by the install-time
record and the shipped contract; it needs nothing from the old package, so it
belongs here, where it can be written against the record E0 itself defines.

**`p5-version [--verify|--files|--dirs|--contract|--state]`** — interrogation.
`--state` is the one mode that answers in every state, including the ones with
no stamp, and is what to run first on a box that will not install.

**`p5-deadman arm|check|confirm|fire|status`** — the automatic-rollback
primitive (§6).

Exit codes are an interface vocabulary — chosen so a caller can branch on the
reason without parsing text. They are not derived from measurement and do not
need to be; they have no behavioural effect.

| code | meaning |
|---|---|
| 0 | success / clean |
| 1 | a check ran and said no; or a rollback ran |
| 2 | usage |
| 3 | integrity: sha mismatch, unpinned payload file, bad provenance, fake hasher |
| 4 | contract violation: a path outside the namespace, inside the foreign set, or undeclared |
| 5 | precondition: the box is in a state this tool refuses to act on, or a deadman is armed |
| 6 | a defined entry point whose logic another unit owns (named on stderr) |

---

## 5. Unbrickability: the server has no physical access

The GL-MT2500 at `${SERVER_PC_IP}` has no console, no recovery button and no
power-cycle into failsafe (ROADMAP, **STANDING CONSTRAINT**). Everything below
is a **mechanism with a bar behind it**. A claim that a failure mode is
impossible is worth nothing without the test that demonstrates it.

| failure mode | mechanism that makes it impossible | bar |
|---|---|---|
| a step severs the SSH path | `contract/foreign` carries an explicit management-path class (sshd, network, firewall, their boot flags) and is consulted **before** the namespace, so no filemap row, packaging mistake or widened namespace can put a P5 file on one. E0 writes files and nothing else, so a destination gate is a complete gate *for E0* | `MG-1` — 9 destinations, each exit 4, refusal names the origin |
| `rm -rf` on a directory P5 does not own | three gates. `installed.dirs` is written by exactly one loop over the contract's `dir` rows, so it *cannot* contain `/usr/sbin`; every entry is re-validated against the shipped contract at removal time and one bad entry refuses the whole run; recorded directories are removed with `rmdir`, **never** `rm -rf` | `DR-1`, `RM-6`, `RM-7`, `RM-8` |
| a **contract row** unlinks outside the namespace | the same gate, extended to the rows the contract itself expands to. Round 2 validated the install RECORD row by row and *obeyed* the contract's glob/runtime rows, so a `../../` row produced a real `UNLINK` of `/etc/dropbear/authorized_keys` **and executed it**. `contract-paths` on a box is a file on disk exactly like the record, so every destructive action now passes `p5_removable` at plan time **and** at the point of use, and `p5_removable` additionally resolves symlinks — a path spelled inside the namespace that lands outside it is refused, which no lexical check can see. One refusal refuses the whole removal | `PS-1` `../..` · `PS-2` absolute · `PS-3` symlinked `/etc/p5` (no contract edit at all) · `PS-4` widened glob · `PS-5` a path collapsed to `/` · `PS-6` the mutation that brings the escape back |
| a half-completed run that can be neither finished nor undone | an **intent record** written and synced *before* the first write, not a completion stamp after the last. A crashed run becomes a named state (`incomplete`) carrying the plan needed to undo it | `CR-1` — SIGKILL before **every** write, 17 of them — plus `CR-2`, `CR-3` |
| a truncated file at a live path | every persistent write stages beside the destination, syncs, and renames | `CR-4` |
| a file goes live **before it is finished**, because placement is activation | the stage is a **dot-prefixed sibling** (`dir/.p5-incoming.NAME`), not a suffixed twin. A leading period is excluded from `*` by the shell itself, so the stage is invisible to every glob-scanning activator; the rename that publishes it is atomic and intra-directory | `HP-1`..`HP-4`, `MU-HP2`, `MU-HP4` |
| the box proceeds in a state nobody modelled | five enumerated states, one function, every entry point branches on it and nothing else | `VS-9`, `RM-10`, `RM-11` |
| the clean-box gate is defeated from the environment | there is no external program to substitute: the gate is computed in-process. `P5_UNINSTALL` does not exist | `IN-17` |
| an install judged against a mutated contract goes unnoticed | overrides are announced on stderr, recorded in the stamp by name, and the sha256 of every contract file actually used is recorded beside them | `VS-8` |
| a removal reloads the firewall the SSH session rides | `--remove` REPORTS the UCI object as `UCIMANUAL` and refuses to execute `uci delete`/`uci commit`. It prints the exact command and the deadman sequence instead. The first version of `--remove` executed it | `UC-1` |
| the removal goes blind after deleting its own contract copy | the contract is snapshotted to scratch before the first unlink and the snapshot drives the rest of the run | measured, then fixed; covered by `RM-3`/`RM-4` |
| an interrupted removal leaves a box with no verb that can finish it | the **recovery toolchain** — `/usr/lib/p5/p5-common.sh`, the three contract copies and `/usr/sbin/p5-uninstall` itself — is removed in ONE final `SELFDROP` action after everything else, and is kept if the run did not finish. Round 2 sorted the entry point into the payload pass and then told the operator to run it — measured on the battery's client fixture at **action 5 of 17**, and re-measured live by `MU-RCV`, which puts it back there and shows a kill at the next index leaving 11 files and no `p5-uninstall`. (The round-2 review recorded `6 of 18` from a fixture of its own; the defect is the same, the count is fixture-dependent, so the bar prints its own.) | `RCV-1` — SIGKILL before **every** action index, recovered each time by the ON-BOX verb with no package present; `RCV-2` the order; `MU-RCV` the mutation |
| a REFUSED removal leaves a verb that exists but cannot run | the emptiness of the owned directory is settled BEFORE `SELFDROP` unlinks anything, measured against `SELFDROP`'s own unlink set. If a file P5 did not place is still there, the whole action is skipped and the library, the contract copies and the entry point all survive together — a runnable verb, not a stranded one | `RCV-5` runs the survivor on the box with no package present; `MU-RCV5` disables the pre-check and shows the kept entry point exiting 5 on its first line |
| a path means something else by the time the `rm` runs | every destructive arm re-asks `p5_removable` AT THE POINT OF USE, not only while the plan is being built. The plan is a file on disk under a shared `/tmp` between the two, and an ancestor of a planned path can become a symlink in between, so a gate that runs only at plan time is a gate on a snapshot. `UNLINK` and `RMTREE` have re-checked since B1; `SELFDROP` — the arm that unlinks the recovery toolchain itself — did not until U75, and was covered by no bar. A refusal there keeps the file, names it, and marks the run unfinished so the "keeping the toolchain" message stays true | `PS-7` swaps `/usr/lib/p5` for a symlink out of the namespace MID-RUN, from a `stop` handler `SVCDOWN` itself executes, and requires the operator's file to survive; `MU-PS7` neutralises that one guard and the same run deletes it |
| a refusal names a remedy that is not on the box | `p5-install` resolves its remedy through `p5_recovery_verb`, which checks the box's copy **and** its library are present and otherwise names the copy beside the running installer. The residual window — a SIGKILL landing *inside* `SELFDROP` — is closed this way rather than claimed away | `RCV-3` names it, `RCV-4` runs what it named |

**Placement is activation, and the staging name is what decides it.** For
`/etc/hotplug.d/iface` there is no enable step: OpenWrt's `/sbin/hotplug-call`
is `for script in /etc/hotplug.d/$1/*; do ( [ -f $script ] && . $script ); done`,
so a file is live to netifd the instant its NAME lands in that directory. Round
1 staged at `DEST.p5-incoming`, which matches `*` — so the hook was published
while `install` was still writing it (a half-written hook half-runs: the
commands above the truncation execute, then the shell errors), and stayed
published for as long as an interrupted run left it there. The rule is
therefore not "stage beside" but **stage under a name no activator can see**,
and it is applied to every destination rather than to a list of directories
known to be activating — such a list is wrong the first time a destination is
added. The staging name is formed in exactly one function, `p5_incoming_of`;
`HP-2` reads the name from that function rather than retyping it, and `MU-HP4`
reverts only that function and shows the same interrupted install leaving a
hook netifd executes.

**Ordering fails safe: install-new-then-switch, not remove-then-install.** This
is a deliberate departure from `p5-execution-handover.md:8`, and the reasoning
is worth stating rather than hiding. That line exists to make "remove precisely
those and nothing else" decidable. E0 satisfies the same requirement a different
and stronger way — **disjointness**, which bar `NS-3` checks mechanically in
both directions. Given disjointness, placing P5's files cannot disturb the old
stack, so requiring a removal *first* buys nothing and costs the one thing that
must never be spent: a window in which the unreachable server has had its
working stack removed and its replacement not yet installed. The old-stack half
of "clean" is still required — **before the switch** (`enable`/`start`, E5) and
before the teardown (E7), not before the install. If U26 or Mo disagrees, the
change is one line in `p5-install`; the reasoning is here.

### The five box states

| state | meaning | what may act on it |
|---|---|---|
| `clean` | no declared P5 path is present | install |
| `installed` | a stamp, no intent record: a run that finished | `--verify`, `--remove` |
| `incomplete` | an intent record is present: a run started and did not finish | `--remove`, which undoes the recorded plan whether or not each step landed |
| `damaged` | P5 paths present, no stamp, no intent record | `--remove --recover` only, and it says loudly that the set is derived from the contract rather than from a record |
| `future` | the stamp declares a layout this build does not understand | nothing destructive |

---

## 6. The deadman, and the rule that binds E5 and E7

E0 cannot cut the management path, and that is proved. **E5 and E7 can**, and no
path list can catch them: `uci commit firewall`, restarting the network, and
stopping the service carrying the tunnel the session rides all write nothing
forbidden — they change the running state of something the session depends on.

`/usr/sbin/p5-deadman` is the primitive. **The rule: any step that touches
routing, the firewall, an init script that brings up management, or the SSH
daemon MUST arm a deadman before it runs, and confirm only after reachability
has been re-proved.**

The armed state is a **file on persistent storage carrying an absolute
deadline**, not a background sleeper. A `sleep && rollback` inside the SSH
session dies with the session — and the session dying is the event it exists to
notice — and it does not survive a power cut. Firing is a pure function of (that
file, the clock), and three things call the same code path: the detached timer,
a boot hook, and a human. Testing `check` against a past deadline therefore
tests all three; there is no second implementation to diverge (`DM-1`…`DM-10`).

`--after` has **no default** and `arm` refuses without it: how long an operator
needs to prove reachability is not derivable from anything this product can
measure (`DM-2`). `--remove` refuses while any deadman is armed, because tearing
down the product would delete the thing that fires it (`DM-8`).

**OPEN, and it is a real gap rather than a caveat.** The boot limb needs a hook
that runs `p5-deadman check` early in boot. E0 ships no init script and invents
no procd priority — that ordering is E5's derivation to make and justify. Until
E5 wires it, a power cut while armed leaves the record armed and **un-fired**
until something calls `check`. `p5-deadman status` says so on every run
(`DM-10`).

---

## 7. What this contract does not settle

- **Whether `/etc/config/p5` is used at all.** Whether P5's facts live in UCI or
  in plain files under `/etc/p5` is E5/E6's call. The row and the pattern are
  reserved so E7 knows the possible scope; if E5 chooses plain files, both get
  deleted rather than left standing as an unused claim.
- **The hotplug priority.** `[0-9][0-9]` is a wildcard on purpose. Choosing the
  number is choosing an ordering against netifd's other hooks, which needs a
  reason. E0 refuses to invent one.
- **Which architecture's binary is right for a box.** That is a packaging
  decision (U28) expressed as filemap rows, and `uname -m` has never been run
  on either box.
- **Init script content and service priorities.** E0 ships no init script and
  invents no `START`/`STOP` value. Those are E5's, with the same
  no-arbitrary-constants rule applied. The deadman's boot hook is one of them.
- **How the operator actually reaches the server.** Nothing in this repo states
  it, and you cannot enumerate what severs a path you have not written down.
  `HANDOVER-STABLE.md:15-19` puts the Brume 2 behind the ISP's router at
  `${SERVER_WAN_IP}` with UDP 59401 forwarded; `deploy-p5-runbook.md:3` says
  `ssh root@${SERVER_PC_IP}`; `INTENT.md:216` uses that same address on the CLIENT
  for the Android tether gateway. If reachability rides the WG tunnel, the
  session rides engarde `:59401` — the first thing `p5-execution-handover.md:80`
  tells E7 to remove on the server, which would make **E7's first server step
  self-severing as specified**. E0 cannot close this: it needs a machine-derived
  report from the box itself (`ss -tnp` for the sshd peer, `ip route get <peer>`
  for the interface, then the WG peer/endpoint and the service carrying it),
  written down and checked against every destructive step. Owner: **U26**, and
  it is a precondition for E7's first server command, not a nice-to-have.
- **The server-deploy procedure.** `deploy-p5-runbook.md:95` says "Server
  (${SERVER_PC_IP}) — NOTHING is installed or changed here", while `contract/paths`
  declares `/usr/sbin/p5-server`, `/etc/init.d/p5-server` and `uci firewall.p5`
  as `role=server`. The runbook is stale against the P5 design, so the document
  that would govern a server deploy currently denies one exists. `docs/` is
  outside this unit's lane; recorded here for U26/U28.
