# M9 — the P5 management portal (U23)

Built to `docs/knowledge/design/m9-portal-design.md`. Module boundary and exposed
interface: `docs/knowledge/design/module-architecture.md` M9.

```
deploy/p5/portal/
  cgi/p5-portal          the ONLY executable surface: whitelist -> write fact -> reconcile
  lib/portal-lib.sh      every guard, in one file
  catalogue/{modes,fields,probes}   the single source of truth for every enumerated value
  www/{index.html,portal.js}        static; renders what the CGI computes
  init.d/p5-portal       its OWN uhttpd instance, LAN-bound, no uci written
```

Gate: `orchestration/ecosim/p5/portal/run.sh` (POSIX sh).

---

## The contract, and how it is enforced rather than asserted

The portal is a **fact writer and viewer, never a controller** (`bond-xctl:161` —
*"the caller writes facts, reconcile() derives the ONE edge"*). The complete set of
side-effecting externals it may invoke:

| what | why it is not an edge |
|---|---|
| `bondctl on` / `bondctl off` | writes the rc lifecycle fact, then reconciles. Not a service start/stop |
| `bondctl mode <catalogue literal>` | writes `mode` (+ the `auto` rule from ADR-003 §2), then reconciles |
| `bond-xctl reconcile` | the single level-triggered verb |
| a fact write into `$BOND_DIR/<catalogue key>` | for facts with no `bondctl` verb (`shape`, `profile`, `floor_kbit`) |

Mode and lifecycle go **through `bondctl`** on purpose. `bondctl` is itself a fact
writer, already covered by the main Layer-2 battery, and it already implements the
ADR-003 §2 write table (`eco` SETS `auto`; every other mode CLEARS it). Routing
through it means the portal ships **no second implementation of that table**, so
the two cannot drift.

Enforced by two bars, not by the paragraph above:

- **PC-2** — static scan of the CGI and the library for the forbidden verbs
  (`autoratectl`, `uci set|commit|add|delete`, `/etc/init.d/`, `sqm`, `iptables`,
  `wg set`, `ip route`, `agg_restart`, `eval`, any `$SVC start|stop|restart`).
- **PC-5** — a **runtime ledger**. Every external argv the CGI issues while every
  control is exercised is recorded and must be a subset of a fixed allowlist.
- **PC-6** — mutates the CGI into a second controller and shows both bars go red,
  so neither is a bar that would pass on an empty file.

Nothing gated this before; `m9-portal-design.md §6.2` asked for it.

## There is no separate `auto` on/off toggle, and that is ADR-003

`INTENT.md` OBJ-E lists "`auto` on/off" as a control. ADR-003 §3 made `eco` **mean**
the auto policy, so the toggle dissolved into the mode selector: choosing `eco` is
`auto on`, and choosing any manual mode is `auto off`. That is exactly why rule 4
exists and why the portal refuses a manual selection until the client confirms the
pin it will inherit (bars R4-1…3).

Shipping a second `auto` switch alongside the mode selector would give two controls
for one fact — the same duplication ADR-003 deleted `cell` for.

## Injection

Five surfaces, each with a test that FAILS without its guard. The mutants are made
by `sed` on a **copy**; the shipped source carries no test hook.

| id | surface | vector | guard | the mutant, and what it proves |
|---|---|---|---|---|
| INJ-1 | shell | a mode value carrying `;`, `$(...)`, `&&` reaching a command line | the request value is only ever **compared** to a catalogue literal; the **catalogue's** copy is what is passed, as one argv element | four sed edits reconstruct the naive form (no whitelist, no implemented check, no catalogue verb lookup, command built with `sh -c`). `v=eco;touch FILE` then **executes**. That it takes four is itself the finding: the catalogue lookup is an incidental fourth barrier |
| INJ-2 | HTML / JS | a hand-edited fact file or a box-supplied label carrying `</script>` reaching the page | `p5_json_str` escapes `"` `\` `<` `>` `&` and LF/CR/TAB; JSON content type + `nosniff`; the page uses `textContent`, never `innerHTML`; page CSP | replaces the escaper with a bare `printf "%s"`: raw `</script>` reaches the body |
| INJ-3 | URL / path | `k=../../etc/dropbear/authorized_keys` aiming the fact write anywhere — the class E0 demonstrated by deleting an SSH key | the key must be a catalogue literal **and** a bare identifier (`p5_key_sane`), applied to the catalogue's own key too | drops both checks: the write lands outside `$BOND_DIR` |
| INJ-4 | config file | a value that becomes a **second fact** (`on%0Aoff`) or a **second word** (`on ;reboot`) in a line-structured file read back by busybox `sh` | two independent layers: the decoder refuses control characters, and the writer emits the catalogue literal, not the request bytes | **two mutants, one vector each** — a single shared vector cannot reach both layers. Decoder removed: the newline vector stops being refused (400 → 200). Literal substitution removed: `on ;reboot` lands verbatim in the fact file |
| INJ-5 | `uci` | an operator-supplied uci key reaching `uci get` — information disclosure with no shell involved | the probe argv comes from `catalogue/probes`; the head token is a closed symbol set; every remaining token is metacharacter-checked | passes the request's `key` into the uci argv: it reads a config value the catalogue never named |

The structural rule that makes most of this hold: **no request byte is ever written
or executed.** A value that matches a catalogue literal is discarded and the
catalogue's copy is used. The one exception is the numeric field, and `p5_uint`
re-emits a canonical decimal it parsed rather than passing the input through.

## Authentication — read this before trusting it

**ESTABLISHED, from the box** (`docs/INTENT.md:134-137`, a `ps w` reading):
`uhttpd` runs with CGI and ubus enabled, and a `gl-ngx-session` process is running.

**HYPOTHESIS, NOT VERIFIED** — that the vendor's session auth keeps its sessions in
rpcd's ubus `session` namespace (so `ubus call session get` can validate a
presented id), and that a CGI on a **separate** uhttpd instance can reach it.
`m9-portal-design.md §4b` names this "the port-time check owed"; it has not been
done, and **nothing in this repo is evidence about the live box**.

Why it is safe to ship behind anyway: **the check fails closed.** If the hypothesis
is wrong, every request is 403 and the portal is unusable. The failure mode is
never "an unauthenticated caller writes a fact". There is no second credential
store and no bypass — a second one would be the `cell` mistake in another costume.

**To settle it:** `scripts/box-inventory.sh` gained a `### portal-auth` section in
this unit — read-only, run from the PC, no session identifier ever printed. That is
U40's run.

CSRF: the session id must arrive in `X-P5-Session` or the POST body. A cookie
**alone** is refused, so a third-party page cannot drive the CGI with the
operator's ambient session (bar AUTH-4).

## Profiles, not constants

- The mode list, the field list and the probe list all live in `catalogue/`.
  Nothing enumerates a mode name, a source count, a source name or a rate in code
  or in the page. Bar **NG-1** greps for exactly that and must find nothing.
- **PC-1** re-derives the implemented mode set from `bondctl`'s own `case` and
  fails if the catalogue drifts from it.
- `max` is rendered (ADR-003's ladder has five positions) but **refused with 501**:
  `bond-xctl` has no fail-loud arm for an unknown mode (`mode_wans`' case ends
  `*) R="$W"`), so writing it today would silently behave like `lightning`.
  ADR-003 rule 6 wants that loud; until U17 lands, the portal is where it is loud.
- The escalation policy is exposed as `conservative · balanced · aggressive`. The
  mapping to `bond-ecod`'s constants belongs **inside `bond-ecod`**; the portal
  never names one.
- The **service floor** is the one numeric field, and it is labelled a requirement.
  Its upper bound is **not a number in this package**: the only non-arbitrary
  ceiling is the autorate max OBJ-F derives, and OBJ-F is not built. So the field
  is refused (`409 no_envelope`) unless an operator declares
  `/etc/p5/portal/floor_envelope` as `<min> <max>`, and the page renders it
  disabled with that reason. Bar **NUM-1**.

## Not a control: per-source participation

There is deliberately **no `exclude` fact and no per-source switch** (ADR-003 §4 +
OBJ-A: source status comes FROM the box, not from inference; the native interface
configuration owns the metrics). The portal **shows** each source's state, device
and metric and points at the native GUI. Bar **PC-4**.

## Hosting

Its own `uhttpd` instance, started from `init.d/p5-portal`: own docroot, own port,
LAN-bound. **No uci is written** — the instance is configured entirely by argv, so
`/etc/config/uhttpd` is never touched (the same entanglement class that leaves
`/etc/config/firewall` an unresolved contradiction in E0's contract).

- The bind address is **derived** from the box's own LAN interface (netifd first,
  uci second). It cannot be a wildcard, and if the address cannot be established
  the service **refuses to start**.
- The port is an **operator declaration** in `/etc/p5/portal/port`. With none
  declared the service refuses to start rather than invent a number.
- The ubus HTTP proxy (`-u /ubus`) is **not** enabled on this instance. The page
  talks to one CGI; a ubus HTTP surface would be far larger than the one the
  design asks us to keep minimal.

Bars LAN-1…5 cover the above statically. **The real reachability bar — "not
reachable from the WAN interface" (design §6.4) — needs the box and is G3's.**

## What is deliberately NOT built, and why

- **The disruptive half of the test runner** (design §3b: the Layer-2 fault battery
  on the box, E1's saturating edge-vs-mid probe). Only the **read-only** probes
  ship. The design says "keep the disruptive list short"; shipping a
  datapath-perturbing trigger before anything has ever run on hardware widens the
  attack surface of a box with no physical access for no proven benefit. The
  enumerated-action mechanism is built and tested, so adding a gated disruptive row
  later is a catalogue entry plus a confirm flow, not a redesign.
- **The log tail** (design §3b). It is a file-read surface whose whole value is
  reading paths, and every path would have to be enumerated in the catalogue
  anyway. Deferred rather than half-guarded.
- **Live datapath numbers** (throughput, loss, p50/p95, hold, cap, duplication).
  Their source is M2's read-only stats endpoint, which is **unbuilt**. The portal
  does not fake them.

## Install (owned by E0/U25, not by this unit)

| from | to |
|---|---|
| `deploy/p5/portal/cgi/p5-portal` | `/usr/lib/p5/portal/cgi/p5-portal` (0755) |
| `deploy/p5/portal/lib/portal-lib.sh` | `/usr/lib/p5/portal/lib/portal-lib.sh` (0644) |
| `deploy/p5/portal/catalogue/*` | `/usr/lib/p5/portal/catalogue/` (0644) |
| `deploy/p5/portal/www/*` | `/usr/lib/p5/portal/www/` (0644) |
| `deploy/p5/portal/init.d/p5-portal` | `/etc/init.d/p5-portal` (0755) |
| operator-declared | `/etc/p5/portal/port` |

The docroot must expose `cgi-bin/p5-portal`; uhttpd is started with `-x /cgi-bin`,
so the CGI is symlinked or installed at `<docroot>/cgi-bin/p5-portal`. **This unit
does not edit E0's `contract/paths`** — U25 is in flight and owns that file. The
rows above are what it needs to add.
