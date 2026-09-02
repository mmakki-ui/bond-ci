# Server-side deploy procedure — GL-MT2500 "Brume 2", `${SERVER_PC_IP}`

**U38.** Written against `docs/knowledge/inventory/2026-08-30-server-brume2.txt` (U40's read-only
capture from Mo's PC), **not** against the repo. The previous server plan
(`docs/knowledge/design/p1-p3-removal-inventory.md`) was built by grepping bootstrap scripts, was
labelled authoritative, and was wrong. Repo state is a hypothesis about box state.

`docs/deploy-p5-runbook.md` is the CLIENT procedure. It said there was no server-side install step.
That was true when written and is false now (U16 added `p4-bondagg/server`). This file is the missing
half.

---

## 0. THE STATE OF THE EVIDENCE. Read this before anything below.

**Nothing in this procedure has been executed on either box. Not one step.** I have no box access from
where this was written. Everything below is reasoning over a read-only inventory. The only things here
that were genuinely EXECUTED are the deadman's bars and the mutant-check that tests those bars; both
are marked as such, and both ran on the dev PC, not on a box.

| what | status |
|---|---|
| `deploy/server/p5-fw-deadman` — the rollback primitive | **EXERCISED. 76 bars, 76 passed / 0 failed, exit 0, on 10 consecutive runs of one frozen tree** (`p5-fw-deadman` md5 `8e11e88c93858a4a620006278c62205f`, `test-p5-fw-deadman.sh` md5 `87bba43425a3c609a306257be408e9dd`). See §0a for why the run count is part of the claim. Run under Git Bash `sh` on the dev PC, **not** busybox ash |
| The deadman's crontab-disarm defect | **EXERCISED.** The bars found a live bug in this file and it was fixed, not relaxed — see §9 |
| `deploy/server/mutant-check-p5-fw-deadman.sh` — the check on the bars themselves | **EXERCISED.** Builds the two-limbs-deleted mutant from the shipped tool and requires the suite to go RED against it. It is the answer to "the suite scored 34/34 on a broken tool", and it is executable rather than argued (§9) |
| `deploy/server/p5-server-preflight.sh` | **NOT EXERCISED.** `sh -n` syntax-clean only. Never run on a box |
| Every firewall step in §5 | **REASONING.** The loaded ruleset has never been read (§2) |
| Every service step in §6 | **REASONING.** `p5-server` has never run on hardware, carried a packet, or talked to a client (ROADMAP, "B2 closed") |
| The client rehearsal in §4 | **NOT DONE.** It is a required gate, and it is open |

**These bars run in no CI job.** `scripts/sync-public-ci.sh:56-71` allowlists `deploy/p5`, not
`deploy/server`, so the mirror never carries them, and no job invokes them. Both fixes sit in other
units' lanes and were not made here (U38d). U35's Fable pass found the same shape once already: a pin
whose own self-tests ran in no CI job, so a pin-disabling regression was invisible everywhere.

Busybox-safety is a **static lint only** — `[[`, `==` inside `[`, arrays, `<<<`, `&>`, `<(`,
`${x^^}`, `echo -e`, `source`, `+=`, `declare` — zero hits across all four scripts (the one match is
`[[:space:]]` inside a grep ERE). A lint is not an execution.

The bars run under Git Bash `sh`, **not busybox ash**. The client rehearsal (§4) is the first thing
that fixes that, and it is why §4 is a gate rather than a suggestion.

### 0a. A PASS COUNT WITHOUT A RUN COUNT IS NOT A MEASUREMENT

This file used to say "34 bars, 34 pass, 0 fail" with no statement of how many times that was run. An
independent verifier's FIRST execution, on a fresh worktree at `75328b7` with an unmodified tree,
returned **32 passed / 2 failed** (`DM-26` `fire` exit 5, `DM-27` restore never ran); eight further
runs across three invocation shapes returned 34/0. **One failure in nine, root cause not established.**
The claim was true of the runs that were done and said nothing about the runs that were not.

Four things changed because of it. Only the third is a fix to the tool; the first two make the next
occurrence legible, and the fourth is a bound, not a cause:

1. **Every number here now carries its run count, and the count is floored.** The figure this file
   states is **76 bars, 76 passed / 0 failed, exit 0, on 10 consecutive runs of one frozen tree** —
   `p5-fw-deadman` md5 `8e11e88c93858a4a620006278c62205f`, `test-p5-fw-deadman.sh` md5
   `87bba43425a3c609a306257be408e9dd`, one run after another with nothing else started by this
   session. Wall time per run went **133 s → 303 s** across those ten as unrelated work loaded the
   PC, which is worth reading next to the bound in point 4.
   The suite also carries a **bar-count floor** now (`BARS_MIN`): a run that REACHES fewer bars than
   the floor exits 1 and says so, so the U46 shape — a silently dropped bar leaving a green tick —
   cannot happen here quietly. Proven by raising the floor past the bar count on a copy and watching
   the suite go red.
2. **The suite keeps its evidence.** Every asserted invocation captures the tool's stderr and, on
   failure, dumps the state directory and the contents of every armed record (`runv`/`chkv`/
   `dump_state`). The old suite discarded both with `>/dev/null 2>&1`, which is why one failure in nine
   arrived as a bare exit code with nothing to diagnose.
3. **`arm`'s SUCCESS is asserted at every arm site** (`arm_ok`, bars `DM-A1..DM-A9`). Before, only
   `arm`'s five refusals were tested, so a transient failure to place a record was invisible until a
   downstream bar tripped three steps later with an unrelated-looking symptom.

4. **The transient is BOUNDED to the interpreter, on evidence — and that is not the same as closed.**
   A 200-invocation `arm` stress on a LOADED box returned 13 anomalies, and every one of them is Git
   Bash failing to read its own script: parse errors at varying offsets (`line 412: usage ;;`,
   `line 435: rm ;;`, `line 462: 'om a new session (%s)…'` — a torn mid-line read of a line that is
   intact on disk), together with `dofork: child died unexpectedly, exit code 0xC0000142` and
   `fork: retry: Resource temporarily unavailable`. **Not one anomaly reached the tool's own logic.**
   The same stress on a quiet box returned **0 anomalies in 200**. Full statement, and the bounds on
   it — 13/200 vs 0/200 is one paired observation, not a controlled experiment — are in ROADMAP under
   **U38e**.

**Still not root-caused, said plainly:** the ORIGINAL 32/2 has not been explained. Attributing it to
the same interpreter failure is inference, not measurement — that run's stderr was discarded before
`runv`/`chkv` existed, so there is nothing left to read. The bound above is about a *reproduction*,
not about that run. It has been made loud and attributed to the step that produces it, which is not
the same thing. On this PC a process spawn costs ~1.3 s (measured: 20 x `sh -c true` = 27.1 s), so the
suite is fork-bound and takes 133 s to 303 s depending on what else the PC is doing; that is an
environment property, not a property of the tool. **The thing that would actually close it is running
these bars on a Linux runner, where the interpreter this bound blames is absent — U38d, then U38e.**

**A rollback primitive for a box with no console should not ship on a self-test with an unexplained
transient.** It has not shipped: nothing in this file has run on either box, and Gate C is open.

---

## 1. The constraint, and the two things it forbids

**The Brume 2 has no console, no recovery button, no power-cycle into failsafe** (ROADMAP, STANDING
CONSTRAINT; HANDOFF §0a). A step that leaves it unreachable loses it permanently.

`:59401` is carrying production traffic **right now** — `engarde-server` pid 15892 on `:::59401`
(inventory:21, :180), peer `${WG_TUNNEL_IP}` with a 53-second-old handshake and 95.33 GiB received
(inventory:155-156).

Two things follow and they are not negotiable:

1. **The server is ADDITIVE. P5 installs alongside and removes NOTHING.** E7 is client-only (ROADMAP,
   "E7 is CLIENT-ONLY"). Retiring `:59401` is a separate, later decision after P5 is proven in
   production, and it is not part of deploy.
2. **Failing closed beats proceeding hopefully.** Every step below refuses on anything it does not
   understand rather than continuing.

### The one that makes this easier than it looks
**The cutover decision lives on the CLIENT, which is recoverable.** The server ends up with two
listeners; which one carries traffic is chosen by the client's endpoint configuration. So the server
is never "switched" at all — there is no server-side cutover step to get wrong, and no window in
which the server has no working listener. That is what coexist-then-switch buys here, and it is
stronger than any rollback.

---

## 2. WHAT THE INVENTORY DID NOT ESTABLISH — three blind spots, all on the firewall

The U40 write-up names one. There are three, and the second is worse than the one named.

### 2a. `### firewall-loaded` came back EMPTY — the collector has since been fixed, the DATA has not
**The historical fact, which is the half that matters and is still true: the loaded ruleset was never
read, on either box.** `### firewall-loaded` is empty in
`docs/knowledge/inventory/2026-08-30-server-brume2.txt:107` (the next marker is `### init.d` at
`:108`), and no re-run has happened. Everything downstream of "what rules are actually loaded" in this
procedure is therefore unmeasured.

The collector defect that caused it was:

```sh
(nft list ruleset 2>/dev/null | grep -iE "udp dport|tcp dport|accept" | head -40 || iptables -S 2>/dev/null | head -40)
```

`||` binds to the whole left **pipeline**, whose exit status is `head`'s, and `head` exits 0 on empty
input, so the `iptables` fallback was unreachable and never attempted.

**That defect is GONE on the merge target and this section must not be read as describing live code.**
U40's `f376b34` ("capture the LOADED firewall ruleset, which the previous form silently skipped"),
merged into `dev` at `27ca5f8`, replaced it: on `dev`, `scripts/box-inventory.sh:45-50` is a comment
recording the old form and `:51-59` tests each backend on its own
(`if command -v nft … && nft list ruleset >/dev/null; then … elif command -v iptables; then …`).
Measured on the merge target, not inferred:
`git show dev:scripts/box-inventory.sh | tr -d '\r' | grep -an -E '\|[[:space:]]*(head|tail|awk|sed)[^|]*\|\|'`
→ one hit, line 46, and it is inside that comment.

So the outstanding work is **a RE-RUN on both boxes** (U38c), not a code fix. Fixing the collector does
not retroactively fill an inventory that was already captured.

Why `nft` produced nothing is still an inference, not a measurement: the box is OpenWrt 21.02-SNAPSHOT
(inventory:10), which is the fw3/iptables era — fw4/nftables arrived in 22.03. That inference is what
§5 probes rather than assumes.

### 2b. `### firewall-uci` is TRUNCATED, and nobody noticed. This is the sharper one.
`scripts/box-inventory.sh:44` ends in `head -60` — **still true on `dev` at `27ca5f8`**; U40’s
fix touched only the loaded-ruleset block below it. Measured: the block is **exactly 60 lines on both
boxes** — server inventory lines 47–106, client lines 61–120
(`sed -n '/^### firewall-uci$/,/^### firewall-loaded$/p' … | sed '1d;$d' | wc -l` → `60`, `60`).

`uci set firewall.NAME=rule` on a section that does not exist **appends it to the end of
`/etc/config/firewall`**, and `uci show` prints in file order. So every rule added after the stock GL
defaults lands past the cap and is invisible — including the `firewall.engarde` that
`p2-engarde/bootstrap-bond-server.sh:56-63` writes (`uci set firewall.engarde=rule … dest_port=$ENGARDE_PORT
… target='ACCEPT'`, then `uci commit firewall` and `/etc/init.d/firewall reload`).

**So the CONFIGURED ruleset was not fully read either.** The U40 note says the loaded one was missed;
the configured one was missed too, and that is the file a reload rebuilds from. Anything in this
procedure that reasons about "what rules exist" is reasoning about the first 60 lines only.

**What is nevertheless established by measurement, and it matters:** inbound `udp/59401` DOES traverse
the `wan` zone today. Not from a rule anyone read — from the traffic. `engarde-server` listens on
`:::59401` (inventory:21), the client's WireGuard peer endpoint is `127.0.0.1:59401` so its traffic
leaves the client through `engarde-client` and arrives at the server's WAN address (client
inventory:189), and the server's peer for that client shows a 53-second handshake and 95.33 GiB
received (inventory:152-156). Traffic is the evidence; the rule is merely presumed.

### 2c. `### network-uci-wg` came back EMPTY on the server
So which firewall zone `wgserver` (`10.0.0.1`) belongs to is unknown — and that decides whether SSH
over the tunnel is a management path at all (§3).

### What this means for the procedure
**Do not treat the inventory as a firewall picture.** Every firewall step in §5 begins by reading the
live and configured rulesets in full (`deploy/server/p5-server-preflight.sh`, which reads each
backend on its own and applies no line cap), and refuses if it cannot. That is a fresh read on the
box, independent of the captured inventory and of whatever `box-inventory.sh` does today.

---

## 3. THE MANAGEMENT PATH — measure it, do not derive it

No document in this repo states how the operator reaches the server. ROADMAP records that as an open
gap and I am not going to derive it: **it can be measured, from inside the session already in use.**

Dropbear exports `SSH_CONNECTION` = `<client ip> <client port> <server ip> <server port>`. The **third
field** is the server address the management path actually lands on:

| landed on | meaning | can a firewall reload cut it? |
|---|---|---|
| `${SERVER_WAN_IP}` | eth0, the **WAN** interface | **YES.** The session is admitted by a wan-zone input rule. This is the dangerous case |
| `${SERVER_PC_IP}` | br-lan | lan-zone input is ACCEPT by default, so far less likely — but zone membership is printed, not assumed |
| `10.0.0.1` | `wgserver` | depends: see below |

If it lands on `10.0.0.1`, read `wg show` and find **your own** peer:
- your peer's endpoint is `127.0.0.1:<port>` → your session rides `engarde-server` on **`:59401`**, and
  any step touching `:59401` severs you;
- your peer has a public endpoint → you reach `wgserver:51820` directly and are **independent of
  engarde**. Inventory:158-168 shows two such peers (`10.0.0.4` via `185.76.177.240`, `10.0.0.2` via
  `80.77.189.17`), so an engarde-independent path plausibly exists. Plausibly is not established.

**GATE M.** Before step 1, the operator records the measured management path AND a **second,
independent** path, and proves the second works while the first is idle. A procedure with one
management path on a box with no console has no rollback — the deadman restores the box, but nothing
tells you whether it worked.

**GATE M CREATES A HAZARD AND YOU MUST KNOW WHICH ONE.** That second session is open *before* the
change, so it survives `/etc/init.d/firewall reload` through conntrack ESTABLISHED exactly like the
arming session does — and reaching the box over it proves nothing about whether the box still admits
NEW connections. Confirming the deadman from it would be the same false green the deadman exists to
close, moved one session across. The tool now refuses every connection that existed when `arm` ran,
not just the arming one (§7, DM-46..DM-48), so this is enforced rather than asked for. **The
confirming connection must be opened after the change.** Do not open extra sessions between `arm` and
the change: the snapshot is taken at `arm`, so anything opened in that window would be accepted.

**Run every server command from the PC, never from the client box.** `${SERVER_PC_IP}` is the server from
the PC and the USB tether from the client (HANDOFF §0). Both scripts here print an identity verdict
first; that is the mechanism, the rule is the weaker half.

---

## 4. GATE C — REHEARSE ON THE CLIENT FIRST. This is not optional.

The Flint 2 is reachable and recoverable; the Brume 2 is not. **Every step in §5 and §6 runs on the
client first, in full, including a deliberate failure and a deliberate deadman fire.**

The client is a good rehearsal rig and it is worth saying why, from the inventories rather than from
assumption: same OpenWrt 21.02-SNAPSHOT `aarch64_cortex-a53` with the `busybox override` taint
(client:10, server:10), same `wan`/`lan` zone pair (client:85-88, server:47-50), dropbear on `:22`
(client:50, server:35), `cron` in init.d on both (client:123, server:109), a `20-firewall` hotplug
hook on both (client:156, server:130), and **`udp/59402` free on both** (0 hits for `59402` in either
file).

Rehearsal set, all of it:

| # | rehearse | proves |
|---|---|---|
| C1 | `p5-server-preflight.sh` end to end | it runs under busybox ash and answers every question |
| C2 | `p5-fw-deadman` `arm` → `confirm` from a NEW session | the timer and boot limbs exist on GL firmware; `setsid`/`nohup`/`crond` are real here |
| C3 | `arm` → let it **expire** | the rollback actually fires unattended. Do this one with a real firewall change |
| C4 | `arm` → `reboot` before the deadline | the boot limb fires after a power cut. **The only way to test it** |
| C5 | the full §5 firewall sequence, ephemeral and persistent | chain names, `uci` object handling, reload survival |
| C6 | the full §6 service sequence | procd behaviour, respawn, binding `:59402` |
| C7 | **confirm from the ARMING session and watch it be refused** | the arming-session case of the conntrack false-green |
| C7a | **confirm from the GATE M SECOND session — the one opened before the change — and watch it be refused** | the case C7 does not reach, and the one the procedure itself creates. Bars DM-46/DM-47 |
| C7b | **confirm from a session opened AFTER the change, and watch it succeed** | the refusal is not simply refusing everything. Bar DM-48 |
| C7c | **read `deadman-connection-snapshot` in the preflight and check your own `SSH_CONNECTION` id appears** | that `netstat`/`ss` answer in a format the deadman parses on THIS firmware. If they do not, `A_PRESNAP` is not `ok` and every `confirm` will refuse — DM-49/DM-50 |

**C4 is the one people skip.** A deadman whose boot limb has never fired is a deadman with two limbs,
not three, and the third is the one that covers power loss.

Only after C1–C7c pass on the client does anything below touch the server. **C7a, C7b and C7c are
part of the gate, not an appendix to C7** — they are the three the round-2 verify showed a passing
C7 does not reach.

---

## 5. THE FIREWALL — three phases, and only one of them can lock you out

P5 needs `udp/59402` admitted on the `wan` zone. The ISP router forwards `:59402` to the server (Mo),
so external reachability is handled upstream — but **the forward only delivers to the WAN interface,
and OpenWrt's `wan` zone drops unsolicited input by default.** The box still needs its own accept
rule. That rule is `firewall.p5`.

### The contract contradiction is already resolved, at the object level
`p5-execution-handover.md` / the earlier U38 note claimed P5's contract forbids `/etc/config/firewall`
while P5 needs a rule in it. **That is resolved on `u25-e0-skeleton`, not open:** the contract's unit
for a uci config file is the named **OBJECT**, not the file (`contract/paths:184-190`), and
`contract/paths:200` reserves exactly one — `uci|server|firewall.p5` — "P5 owns this OBJECT and no
other object in that file". `contract/foreign:41` says the same. `firewall.engarde` stays foreign
(`contract/foreign:121`).

**Caveat, and it is load-bearing: that resolution lives on an unmerged branch whose own verify
returned `verified:false`.** It is not on `dev`. So the contradiction is closed in design and open in
the tree.

### Why a NAMED section and never an anonymous one
`uci set firewall.p5=rule` converges on re-run (idempotent), and `uci delete firewall.p5` removes
exactly one object. An anonymous `@rule[N]` is addressed by **index**, and indices shift when
neighbours change — every server rule THAT WAS CAPTURED is anonymous (`firewall.@rule[0..7]`,
inventory:51-106 — `:107` is the `### firewall-loaded` marker, not a rule), and the capture stops at
the `head -60` cap (§2b), so there may be more of them past it. Both readings point the same way:
deleting by index on this box is a way to delete somebody else's rule. Never do it.

### F1 — EPHEMERAL. Prove reachability with no config write and no reload.
Insert an ACCEPT straight into the live table. This is **purely additive**: it flushes nothing,
rebuilds nothing, and reloads nothing, so **it cannot cut the management path.** It self-clears on
reboot and on any firewall reload, which makes it a proving device, not a deploy.

Chain name comes from `p5-server-preflight.sh` (`### firewall-input-chains`), **not from memory**. On
fw3 it is `zone_wan_input`; do not type that until the preflight prints it.

```sh
# idempotent: -C checks, -I only if absent
iptables -C "$CHAIN" -p udp --dport 59402 -j ACCEPT 2>/dev/null \
  || iptables -I "$CHAIN" 1 -p udp --dport 59402 -j ACCEPT
```

No deadman needed for F1. Nothing it does can take the box away. Prove `:59402` reaches the daemon
from outside, then continue.

**F1 is fragile on purpose and you must know how:** the server has
`/etc/hotplug.d/iface/20-firewall` — measured only as far as `ls` goes: inventory:130 is the row
`-rw------- 1 root root 424 Mar 27 2025 20-firewall`, so the file EXISTS and its CONTENTS were never
read. That an iface event through it triggers a firewall reload, which silently drops the ephemeral
rule, is standard OpenWrt behaviour taken from the platform, not from this box. It is conservative in
direction — it says the rule is more fragile than measured, never less. Never leave the box in F1 and
walk away.

### F2 — PERSIST. `uci commit` changes nothing that is running.
```sh
uci set firewall.p5=rule
uci set firewall.p5.name='p5-bond'
uci set firewall.p5.src='wan'
uci set firewall.p5.proto='udp'
uci set firewall.p5.dest_port='59402'
uci set firewall.p5.target='ACCEPT'
uci commit firewall
```
Back up `/etc/config/firewall` byte-exact **before** the commit. Commit alone does not touch the
running ruleset, so F2 is also safe. Verify the committed file parses (`uci show firewall`) before F3.

### F3 — RELOAD. THE ONLY STEP THAT CAN LOCK YOU OUT. Deadman it.
`/etc/init.d/firewall reload` **flushes and rebuilds every chain from `/etc/config/firewall`**. If the
committed file is wrong, truncated, or drops a rule the operator's own session depends on, the session
dies and there is no console.

**Arm before, not after:**

```sh
# restore script — a FILE, sha-pinned into the record, no eval:
cat > /etc/p5/restore-firewall.sh <<'EOF'
#!/bin/sh
cp /etc/p5/firewall.pre-p5 /etc/config/firewall
/etc/init.d/firewall reload
EOF
chmod +x /etc/p5/restore-firewall.sh

p5-fw-deadman arm --after <SECONDS> --restore-script /etc/p5/restore-firewall.sh --label fw
/etc/init.d/firewall reload
# ... then, FROM A NEW SSH SESSION:
p5-fw-deadman confirm --label fw
```

`--after` has **no default and the tool refuses without it**. How long an operator needs to prove
reachability is not derivable from physics and not measurable by this tool — it depends on the link,
the step and the person. It is supplied explicitly, every time. Inventing a number here would be
exactly the arbitrary constant this project bans.

**`confirm` REFUSES every connection that already existed when `arm` ran, and that refusal is the
point.** An established TCP connection keeps flowing through the conntrack ESTABLISHED rule after the
ACCEPT rule that admitted it is gone. Confirming over a connection that predates the change proves the
box was reachable a minute ago, not that it is reachable — the classic false green for precisely this
step, and the one that loses the box.

**Comparing only the ARMING session was not enough, and that is what this file used to claim.**
`SSH_CONNECTION` fields 1:2 are the client ip:port, so a mismatch proves *a different 4-tuple* and
nothing more. The Gate M second session has a different client port, survives the reload identically,
and would have confirmed — and Gate M *requires* that session to exist. So `arm` now snapshots every
TCP peer the box has established (`netstat -tn`, or `ss -tn` if netstat is absent — the server has
busybox netstat and no `ss`, server inventory:12-13,29-30) into the record, and `confirm` refuses any
id in that set. Bars DM-13..DM-16 (arming session, non-ssh), **DM-46..DM-48** (the Gate M session
refused, a post-arm session accepted), **DM-49/DM-50** (both ways the snapshot can be worthless).

**The snapshot validates itself at arm time.** If the parse cannot find the arming session's own id in
its own output, the format is not the one the tool understands and the record is marked
`A_PRESNAP=untrusted`; if no tool answers at all, `A_PRESNAP=none`. In both cases `confirm` REFUSES,
because "cannot tell a new connection from an old one" must fail closed on this box. `status` prints
the snapshot state of every armed record, and the preflight's `deadman-connection-snapshot` block
answers it before the deploy rather than during it.

**WHAT THIS STILL DOES NOT PROVE, stated rather than implied:** it proves the confirming connection was
admitted after **`arm`**, not after **the change**. `arm` runs immediately before the change, so the
residual window is the operator's own arm→change gap, and Gate M above forbids opening anything inside
it. Proving admission after the change itself would need the box to timestamp inbound connections; no
mechanism for that has been demonstrated on this hardware, so none is claimed.

**Restore is a byte-exact file copy, not a targeted `uci delete`.** A targeted delete undoes the
change you intended; a file copy also undoes a partial or corrupt commit, which is the failure you
cannot see from the other end of a dead session.

**Check `p5-fw-deadman status` before F3.** It prints which limbs are actually live on that box. If it
says `boot: ABSENT -- crond is not running`, **stop**: a power cut during F3 would leave the box
rolled-forward and unreachable with nothing scheduled to undo it. Whether crond runs on the server is
**not established** — the inventory's `### ps` filters to `engarde|bond|agg|autorate|cake`
(the `### ps` line of `scripts/box-inventory.sh`, cited by its section marker because the line number
has now rotted twice: it was `:58` when U38 was written, `:72` at `dev` `27ca5f8`, and `:78` at `dev`
`43b1ccf`), so it could not have shown crond. `cron` is in init.d (inventory:109) and
`S50cron` is in rc.d (inventory:111), which means enabled at boot, not running now.

### Firewall-before-removal
On the server there is **no removal**, so this ordering rule is currently vacuous — and saying so is
better than implying a step exists. It is retained as a standing invariant for the day `:59401` is
retired: `firewall.p5` must exist, be committed, be loaded, and be **proven admitting traffic** before
`firewall.engarde` is ever deleted. Deleting it is a uci-object delete plus a reload — the same
lockout step as F3, needing the same deadman.

---

## 6. THE SERVICE — coexist, in an order graded by what happens if it fails

Paths are contract-reserved and confirmed free by the preflight: `/usr/sbin/p5-server` and
`/etc/init.d/p5-server` (`contract/paths:155,158`). The server's `/usr/sbin` holds exactly one of our
binaries today — `engarde-server` (inventory:121) — and `/etc/bond` holds exactly one file,
`engarde-server.yml` (inventory:113-115). Nothing collides.

The binary is CI artifact `bondsrv-linux-arm64`, sha
`2c46ccbec1a73e39465073d62ccaea508d2d9cd155b495407f481b698e1f61cb` (ROADMAP, "B2 closed"). `uname -m`
on the box is `aarch64` (inventory:8), so the arch is right — checked, because the roadmap carried
"whether the GL-MT2500 actually runs a 64-bit userspace is still unverified" for a while and the
inventory settles it.

**Order, each step chosen for what happens if it fails halfway:**

| # | step | if it fails halfway |
|---|---|---|
| S1 | `scp` to `/tmp`, verify sha **before** `/usr/sbin` | a corrupt push is caught in `/tmp`, nothing installed |
| S2 | `install -m755 /tmp/p5-server /usr/sbin/p5-server` | an unreferenced file. Nothing runs it. Harmless |
| S3 | `scp deploy/server/init.d/p5-server` to `/tmp/init.d/p5-server`, then `install -m755 /tmp/init.d/p5-server /etc/init.d/p5-server` — **do NOT enable** | an init script with no rc.d symlink is inert |
| S4 | run it **by hand, in the foreground**, bounded | you watch it fail and Ctrl-C. No supervisor retries it |
| S5 | `/etc/init.d/p5-server start` (procd, still not enabled) | `stop` fixes it; a reboot fixes it regardless |
| S6 | prove end-to-end with the real client on `:59402` while `:59401` keeps carrying production | — |
| S7 | `enable` at boot — **DEFER. See below** | this is the step that can produce a box that does not come back |

**S4 before S5 is the whole point.** A daemon that crash-loops under procd respawn on a box you cannot
reach is worse than one that failed once in front of you. Prove it starts, binds `:59402`, and exits
cleanly on SIGTERM before any supervisor owns it.

### S7 — recommend DEFERRING boot enablement out of the first deploy
Enabling at boot is only meaningfully proven by rebooting, and **the first reboot of that box after
deploy is the single highest-risk event in this plan.** It is also unnecessary on day one: coexist
means `:59401` still carries production, so a server that loses `p5-server` on reboot degrades to
exactly today's working state.

So: finish the first deploy at S6, with `p5-server` running but not enabled, and schedule boot
enablement as its own separately-gated step once P5 has run in production. If S7 does run, note
ROADMAP's B4 class: `/etc/rc.d/S??p5-server` is created at **enable** time, so no install-time record
covers it — `disable` must precede any future removal, and the absence must be verified.

**The START priority: the box derives a BOUND, and the number itself is a stated choice.** The only
derivable constraints are after `S19firewall` and after `S20network` (inventory:111), which give
`START > 20` and nothing narrower. Anything past that bound is a choice, and choosing a priority is
choosing an ordering against every other service on the box. **U112 makes that choice and labels it
one:** `START=94`, engarde-server's own priority (`p2-engarde/bootstrap-bond-server.sh:44`).

`procd_set_param respawn` threshold/timeout/retry for this firmware build are likewise **not
verified**.

The file S3 installs is **`deploy/server/init.d/p5-server`** in this repo. It did not exist when this
runbook was written — that gap is ROADMAP U112. Its header carries the derivation above and the
respawn caveat verbatim, and it contains no `enable` anywhere.
**`deploy/server/test-p5-server-init.sh`** holds it to that: `START > 20` and two digits, the procd
`env` block carrying exactly the four keys `p4-bondagg/server/main.go:152-155` reads with every one of
them bound to a value, the three respawn parameters present, no `enable` in the comment-stripped text,
and this S3 row still naming the tree file and still saying **do NOT enable**.

### C4 footprint bound (U129) — GOAL.md:32, "minimal SERVER-side footprint"

Before U129 the stanza bounded nothing but respawn: no `nice`, no `limits`, no `GOMAXPROCS` (`grep -n
'limits\|nice' deploy/server/init.d/p5-server` was empty on the pre-U129 file). A flood on `:59402`
would compete for both MT7981 cores with `engarde-server` and every WireGuard peer the box serves —
exactly the risk C4 exists to bound. Three additions to `start_service()`, none of them a `limits as=`:

| bound | what it does | what it does NOT do |
|---|---|---|
| `procd_set_param env … GOMAXPROCS="$GOMAXPROCS"` (default `1`) | caps the daemon's Go scheduler at one P (one OS thread running Go code at a time) — bounds `p5-server`'s own userland compute to one core | does not cap the process's total OS thread count — the runtime still spawns its own sysmon/GC/syscall threads regardless, so the measurer's `Threads:` line reading above 1 is expected, not a contradiction; is not a fifth `main.go` `Getenv` key — Go's runtime reads `GOMAXPROCS` at process start, before `main()` runs; and does NOT bound kernel-side packet processing — softirq/NAPI for a `:59402` flood runs on whichever core takes the NIC interrupt, unrelated to this value, so the second MT7981 core is not guaranteed free of that load |
| `procd_set_param nice 10` | lowers scheduling priority on the core the daemon DOES share, so a burst loses the CPU race against production rather than contending for it equally | does not affect memory or sockets |
| `procd_set_param limits core="0"` | disables core dumps — `/overlay` is small flash on a box with no console to clean one up from | is not a memory bound |

**Deliberately absent: `limits as=`.** Go reserves virtual address space at process start (the runtime
maps the heap arena up front), so an `RLIMIT_AS` here would make the binary **fail to launch**, not
bound its steady-state memory — the opposite of a footprint bound. Memory is bounded by construction
instead, and `deploy/server/test-p5-server-footprint.sh` (bar FP-3) holds the shipped `server/*.go` to
these five facts, all outside `_test.go` files: fixed `[256]`-element arrays sized by the wire's own
one-byte pathID ceiling (`MaxLinks=256`, `p4-bondagg/server/echo.go:12`; used at `main.go:141-142`,
`echo.go:48-49`, `owd.go:26-28`), one 2048-slot resequencer ring (`RingPow2=11`, `main.go:54`,
consumed by `NewRing` at `main.go:320` and `ring.go:87`), exactly one `net.ListenUDP` (`main.go:300`),
exactly one `net.DialUDP` (`main.go:308`), and no `map[` anywhere in `server/*.go` — there is no
collection here that grows with traffic, so nothing needs a memory bound the runtime would fight.

**`deploy/server/test-p5-server-footprint.sh`** is the gate for all of this: FP-1 the stanza still has
exactly one `procd_set_param command`; FP-2 no script under `p5/bin`, `p5/lib` or `deploy/server`
touches `/etc/init.d/network|wireguard|dropbear|uhttpd`, and the only `/etc/init.d/*` verbs anywhere in
that tree are `p5-server`'s own, `firewall reload` inside an armed `p5-deadman`, and `cron reload` in
`p5-deadman`; FP-3 the five construction facts above; FP-4 the stanza carries `nice`/`limits`/
`GOMAXPROCS`/`respawn` and still no `enable`; FP-5 the measurer below is read-only.

**`deploy/server/p5-server-measure.sh`** is the read-only step that turns the bound into a number on
the actual box, mirroring `p5-server-preflight.sh`'s own guards (`have()`/`sec()`, every probe degrades
to `(absent)` rather than failing): `p5-server`'s rss/vsz (BusyBox `ps -o` rejects `pcpu`; CPU time
comes from `/proc/<pid>/stat` utime+stime instead), the UDP ports it owns (`netstat -ulnp`), whether
`/etc/rc.d` carries a `p5-server` symlink (S7 is still deferred — it should not), the `firewall.p5`
object count, the `p5-deadman` marker count in `/etc/crontabs/root`, **`wg show` handshake epochs for
every peer, plus `date +%s`** — `latest-handshakes` prints a raw UNIX epoch, not an age, so the script
prints the current time alongside it and the age is computed as the difference — plus `free`,
`df /overlay` and a `logread` count. Run it before S3 (baseline: nothing installed yet) and again after
S6 (the daemon has carried real traffic); the criterion is **per-peer, not a blanket freshness check**.
WireGuard only rekeys on traffic/keepalive, so an idle peer's epoch legitimately sits unchanged for
days — the server's own peer set shows this at baseline (`docs/knowledge/inventory/2026-08-30-server-brume2.txt:152-174`:
peers at 53s, 1 day, 12 days, and two that have never handshaked). So: a peer that is **fresh at
baseline** (close to `date +%s`) must **still be fresh** after S6; a peer **idle at baseline staying
unchanged** after S6 is expected, not a fault; a peer that **was fresh at baseline and goes unchanged or
stale** after S6 is the regression this step exists to catch (runbook section 7 item 1 states the
freshness half of this — "handshake is still fresh" — for the always-active client peer at `:59401`).

    ssh root@<server> 'sh -s' < deploy/server/p5-server-measure.sh | tee footprint-before.txt
    # ... S3-S6 ...
    ssh root@<server> 'sh -s' < deploy/server/p5-server-measure.sh | tee footprint-after.txt

---

## 7. Verify, and what counts as verified

After each step, all three:
1. `:59401` still has a listener and the client's handshake is still fresh (`wg show`).
2. `:59402` behaves as the step intends.
3. **A NEW ssh session connects.** Not the one you are in. See §5 F3.

`p5-server` has never carried a packet or talked to a client anywhere (ROADMAP, "B2 closed"). S6 is
the first time, and it is a real experiment, not a confirmation.

---

## 8. Rollback

| phase | undo | cuts management? |
|---|---|---|
| F1 ephemeral | `iptables -D "$CHAIN" -p udp --dport 59402 -j ACCEPT`, or reboot | no |
| F2 commit | `cp /etc/p5/firewall.pre-p5 /etc/config/firewall` (no reload) | no |
| F3 reload | `p5-fw-deadman fire --label fw`, or let the deadline pass | this is what the deadman is for |
| S2–S3 files | `rm -f /usr/sbin/p5-server /etc/init.d/p5-server` | no |
| S5 running | `/etc/init.d/p5-server stop` | no |
| S7 enabled | `/etc/init.d/p5-server disable`, verify no `/etc/rc.d/*p5-server` | no |

Every step is idempotent, safe to interrupt, and safe to retry. Nothing here removes anything that
existed before P5, so "restore the old stack" is not a rollback path that has to work — the old stack
was never touched.

**`reboot` as a last-limb restore is deliberately NOT the default.** It is the strongest recovery when
the running state is unreachable and the on-disk state is known-good, and it is also a step that can
fail to come back. Arm it only as an explicit operator choice.

---

## 9. The bug these bars found, recorded because it is the general shape

`p5-fw-deadman`'s disarm wrote:

```sh
grep -v "$CRONMARK" "$CRONTAB" > "$CRONTAB.p5tmp" && mv "$CRONTAB.p5tmp" "$CRONTAB"
```

`grep` exits **1** when it selects no lines — the common case here, because our line was the only one.
The `&&` short-circuits, the correctly-filtered file is never moved into place, and **the boot limb is
left armed forever pointing at a tool the operator believes is disarmed.** Caught by DM-25, fixed in
the tool, and DM-25a/b/c now assert byte-exact restore against a seeded pre-existing crontab.

It is the same shape as the `box-inventory.sh` collector that lost the server's loaded firewall
(§2a) — a `||` fallback made unreachable because `head` always exits 0. **The exit status of a filter
is not a success signal.** That instance is FIXED on the merge target (U40's `f376b34`, merged at
`27ca5f8`; the old form survives only as a comment at `box-inventory.sh:46` on `dev`); this one is
fixed here. The sweep for further instances is U38b and it found **zero live instances on `dev`**.

**And then a third instance turned up in this unit's own preflight, in a shape the sweep's regexes
cannot see.** `### management-path` read `(netstat -tn || ss -tn) | grep -E ':22'`. The `||` is inside
a subshell *before* the pipe, so U38b's patterns — which look for `|| ` after a pipeline — do not
match it, yet the failure is identical: `||` binds to `netstat` alone, so a `netstat` that exists and
answers EMPTY with status 0 makes the `ss` fallback unreachable and the block prints nothing, which
reads as "no sessions established". That is the one block whose entire job is to show the operator
which connection they are standing on. Fixed: each backend is tested on its own, its own exit status
is read, a non-empty table is required, and the both-absent case prints a named fail-closed message
saying the deadman's snapshot will refuse. **The lesson is about the sweep, not the line** — U38b's
regex set is now known to be incomplete, and it says so.

**Round 3 (adversarial review) found THREE MORE of the same `(A || B) |` shape in the same file** —
`### listeners-udp-FULL`, `### port-59402-free`, `### port-59401-live` all read
`(ss -lnu … || netstat -lnu …)`, so an `ss` that answers empty with status 0 made `:59402` read
**FREE** (the unsafe direction: proceed) and `:59401` read ABSENT. The round-2 fix had been applied
to ONE block of the preflight and the sweep corpus was `dev` — this unit's own new files were never
in it. Fixed the same way: one netstat-first per-backend read of the UDP listener table, non-empty
required, and an explicit UNKNOWN → STOP verdict for both port blocks, because an unreadable table
must never default to FREE. A partial fix of a named defect class is the class's own shape.

### Three more, all found by the bars added in round 2 — and all in code no bar had ever reached

**The timer limb never worked, anywhere, and nothing could see it.** The detached sleeper was spawned
as `sh -c "sleep $AFTER; $SELF check"`. `$SELF` was interpolated into the command string unquoted, so
an install path containing a space split into two words and the sleeper died instantly with `No such
file or directory` — into `/dev/null`, from a detached process, while `arm` still exited 0 and printed
`armed`. `/usr/sbin/p5-fw-deadman` has no space so this would not have bitten on the box; it bit every
run from a checkout, which is where Gate C's rehearsal happens. It was invisible because **every arm
in the old suite passed `--no-timer`**, so the spawn executed zero times. `DM-30`/`DM-31` went red the
first time they ran; the arguments are now passed as arguments, not interpolated.

**A failed rollback always reported `exit 0`.** `run_restore` had `_r=1; log "rollback FAILED (exit
$?)"` — the assignment is a command and it succeeds, so `$?` was always 0. That is the single line an
operator gets about a box they cannot reach. Status is captured before anything else runs (`DM-42`).

**A corrupt record was skipped silently, on every check, forever.** `check` had
`( . "$f"; [ "$_t" -ge "$A_DEADLINE" ] ) || continue`, so an unreadable record was indistinguishable
from one that is not due yet — a deadman that cannot fire and never says so, which the tool's own
header names as the outcome the atomic write exists to prevent. `check` and `status` now read every
record through a guarded subshell and say `CAN NEVER FIRE`; `check` returns a precondition failure
rather than success (`DM-43`/`DM-43a`/`DM-44`). `confirm` and `fire` used to source the record raw in
the live shell, so an unreadable one ended the process with the shell's own status and none of our
messages; they are guarded the same way now.

**The shape shared by all three:** each lived in a code path the suite never executed. A bar count is
not coverage. The check that catches that class is a **runnable script, not a paragraph** —
`deploy/server/mutant-check-p5-fw-deadman.sh` builds the exact mutant (`do_status` gutted, timer spawn
deleted) from the shipped tool, runs the shipped suite against it, and **fails if the suite passes**.
It asserts that both mutations actually applied, so restructuring the tool breaks it loudly instead of
leaving it mutating nothing. Run it with the suite; both are the unit's gate.

---

## 10. Out of scope, explicitly

- **Retiring `:59401`.** A separate, later decision after P5 is proven in production. Not deploy's.
- **Removing anything on the server.** E7 is client-only.
- **`/etc/config/sqm`, autorate, cake.** The server has none — `### sqm` is empty (inventory:178) and
  no autorate process runs (inventory:180). Client-only concerns.
- **U50b.** Mo's decision that P5's DAG drops engarde changes what the *client* needs. The server side
  is unaffected: `p5-server` never referenced engarde.

---

## 11. Open, and each one names what would close it

| # | open | closed by |
|---|---|---|
| O1 | **The whole procedure is unexercised.** §0 | Gate C, §4 |
| O2 | The loaded firewall ruleset has never been read; the configured one was truncated at 60 lines | run `p5-server-preflight.sh` on the server |
| O3 | The management path is not established, and a second independent path is not proven | Gate M, §3 |
| O4 | Whether `crond` runs on the server — the deadman's power-cut limb depends on it | preflight `### deadman-cron` |
| O5 | Whether `setsid`/`nohup` exist in this busybox — the deadman's timer limb | preflight `### deadman-primitives` |
| O6 | Free flash and RAM are unmeasured. A second ~5 MB static binary on a box with no console | preflight `### space` |
| O7 | Two rollback primitives now exist (`p5-fw-deadman` here, `p5-deadman` on `u25-e0-skeleton`) | **U38a** — consolidate. Two implementations of a rollback is how you get a rollback that does not roll back |
| O8 | The contract's object-level resolution of the firewall contradiction is on an unmerged `verified:false` branch, not on `dev` | U25 round 3 |
| O9 | `p5-server`'s START priority and procd respawn parameters are underived | E5 |
| O10 | `p5-server` has never carried a packet or talked to a client | S6, and G3 |
| O11 | The box's clock feeds an absolute deadline; no ntpd/chronyd was observed on the server (the inventory could not have shown it) | preflight `### clock` |
| O12 | **The self-test has a transient that is bounded but not explained.** An independent verifier measured 1 failure in 9 runs of the pre-round-2 suite; a round-2 run showed a different one (`DM-25a` confirm exit 2). Round 2 then ran the round-2 suite **10 consecutive times at 76/0** and bounded the failure mode to the Git Bash interpreter mis-reading its own script under host load (§0a point 4). **What is not established is that the original occurrence had that cause** — its evidence was discarded before `runv`/`chkv` existed | running the bars on a Linux runner (**U38d**, then **U38e**), plus the next occurrence, which will now carry its own evidence |
| O13 | **`confirm` proves admission after `arm`, not after the CHANGE.** The residual window is the operator's own arm→change gap; Gate M forbids opening anything inside it, which is prose, not a mechanism | a box-side way to timestamp inbound connections. None has been demonstrated on this hardware, so none is claimed (§7) |
| O14 | **CLOSED (U130, fix round).** `arm` still ARMS when the crontab directory is absent — refusing would leave NO deadman at all, which stays the worse outcome — and it still says so loudly on stderr (`boot_limb_install`, `p5/bin/p5-deadman`) and in `status`'s `boot: ABSENT`. A first build of this unit ALSO changed `arm`'s exit status to a 7th code (`P5_EX_ARMED_NO_BOOT`) for this case; that broke `p5/test/run.sh`'s DM-1, which hard-requires `arm` to exit 0 and is owned by another row, the moment its fake root has no `/etc/crontabs` directory. The exit-code change is reverted — `arm` exits plain 0 whether or not the boot limb installed, exactly as before U130 — because reporting the distinction in the exit status would need every caller, including that row's, to accept a second success code. **Third fix round:** the other half of that verdict was still wrong. `do_status`'s OWN boot check was `grep -q "$CRONMARK"`, an UNANCHORED substring test, even after install and removal had been anchored (O15) — so a crontab holding only an operator line that merely *contains* `# p5-deadman`, with p5's real line never installed, made `status` print `boot: LIVE (crond running, crontab line installed)`, which §5 tells the operator to read as "the power-cut limb is wired" before F3. `status` now matches `CRONLINE` with `grep -qxF`, the same anchor install and removal use | `DM-45` (`deploy/server/test-p5-fw-deadman.sh`) now asserts exit 0 with no crontab dir; `DM-45a`/`DM-45b` still assert the stderr warning and that the record is written anyway. `DM-61`/`DM-61a` assert that a look-alike-only crontab with `crond` up does NOT produce `boot: LIVE` and produces the honest `crond running but NO crontab line` instead. MEASURED on this branch's tree, ext4 under WSL Ubuntu-24.04 (not on NTFS): the suite is **114 passed / 0 failed**; reverting that one `grep` back to the substring form and changing nothing else gives **112 passed / 2 failed**, red at `DM-61`/`DM-61a`. `p5/test/run.sh`'s DM-1 — owned by another row, not by this suite — was RUN, not assumed: a full `sh p5/test/run.sh` on a git checkout of this branch's HEAD with the working tree overlaid, on ext4, gave **`p5-skeleton: 121 passed, 0 failed`**, DM-1 among the passes |
| O15 | **CLOSED (U130, fix round).** `fire` and `check` now call `boot_limb_remove_if_last` — the same function `confirm` always called — once no armed record remains. Both verbs share `fire_one()`, so a single call site covers a human `fire` and, more importantly, the boot limb's own `check` invocation, which is the path a real power-cut rollback actually takes. The separate pre-arm backup file (`CRONPRE`, `${CRONTAB}.p5-pre`) is gone too — it was a path outside p5's own contract namespace (`p5/contract/namespace:69-80` owns `/etc/p5/*`, not `/etc/crontabs/*`). "did the crontab exist before this arm" is now a field on the armed record itself (`P5_DM_CRON_PREEXISTED`), which lives under `$P5_DEADDIR` and so stays inside the namespace; removal strips the marked line rather than restoring a saved copy. That strip now matches the EXACT literal line p5 appends (`CRONLINE`, whole-line fixed-string `grep -qxF`/`-vxF`) rather than the marker text `# p5-deadman` as a bare substring — the first build of this unit matched the substring, which meant an operator crontab line that merely CONTAINED that text made `boot_limb_install` think the limb was already in place (skipping the real append, so the boot limb was silently absent under a 0 exit) and made removal strip that operator's WHOLE line, not just p5's. `boot_limb_install` also now inserts a separating newline before appending when the pre-existing crontab does not already end in one, so p5's `>>` append never glues onto the operator's last line — without that guard, a crontab with no trailing newline lost its final line entirely on removal (the merged line matched and was stripped whole; reproduced: crontab left at 0 bytes). **Third fix round:** the rewrite itself was still not neutral on a file p5 does not own. `grep -vxF … > "$CRONTAB.p5tmp"; mv` onto an existing path unlinks the destination and leaves the SOURCE file there, so the temp file's own umask-derived mode became the crontab's — a crontab seeded `600` came back `644`. `boot_limb_remove_if_last` now reads mode/uid/gid with `stat -c` (busybox carries `%a`/`%u`/`%g`; it has no GNU `chmod --reference`, which is why the mode is carried in a variable) and stamps them onto the temp file **before** the `mv`, so `$CRONTAB` is never observable at the wrong mode — not even for the instant a stamp-after-mv would leave open. Both stamps are best-effort on top of a correct removal: a `stat` that fails leaves its variable empty and the step is skipped, and the `chown` is expected to fail when not root, which is exactly when the ids are already ours | `DM-52a`/`DM-52b` (through `fire`) and `DM-56`/`DM-56a`/`DM-57`/`DM-57a` (through `check`) assert the removal and the byte-exact result when the crontab already ends in a newline; `DM-10a`/`DM-57a` assert the backup file no longer exists anywhere; `DM-58`..`DM-58d` assert a look-alike operator line survives install and removal untouched while p5's own line still installs and strips correctly; `DM-60`..`DM-60d` assert a no-trailing-newline crontab keeps the operator's job intact (not 0 bytes) through install and removal via `check`. `DM-62`/`DM-62a` seed a non-default `640` crontab, arm and disarm through it, and assert `640` back; `DM-62b` guards that bar itself by asserting the seed actually took, so a filesystem that ignores `chmod` (NTFS under Git Bash) fails loudly instead of letting `DM-62a` pass for the wrong reason. MEASURED on ext4 under WSL: deleting only the two stamp lines gives **113 passed / 1 failed**, red at `DM-62a` with `640 -> 644`. Inverted from the pre-U130 bars, which pinned the original O15 defect on purpose — a regression back to it goes red |
| O16 | **The deadman's connection snapshot needs `netstat` or `ss` to answer in a format it parses.** If neither does, `confirm` fails closed and only the deadline or `fire` ends an arm | preflight `### deadman-connection-snapshot`, which prints both tables and this session's own id — run it before the deploy, not during |
