# `max` + `speed` — the two-mode design (measured, 2026-08-29)

**Status: model-validated design proposal. Nothing deployed. All numbers MEASURED on the
unmodified `p4-bondagg/sim/nsched_model.py` physics via `pull-study` rigs unless labelled
otherwise. Scratch scripts + raw outputs: this scratchpad dir (`expA_hold.py`, `expB_speed.py`,
`expD_drule.py`, `expE_emergent.py`, `expF_marginal.py`, `expG_mid.py`, `holdlib.py`,
`exp{D,E,F,G}.out`). Med over 6 seeds, T=9s, unless stated.**

---

## 0. TL;DR

- **One datapath, two modes.** `max` = the settled composite (pull-hungriest + E1-gated
  cap + standing lightning), unchanged except the hold policy and the name. `speed` = the
  SAME datapath with a ONE-LINE difference: the pull draw orders open candidates by
  `KEY_i = D̂min_i + local_ms_i` (measured path delay floor + current local queue-wait)
  instead of hungriest-first. No admission machinery, no thresholds, no hysteresis:
  the active set is **emergent** — a slower source draws frames only while every faster
  source's gate is closed, and starves automatically when demand drops.
- **The reorder hold is replaced by a lateness ratchet**: `hold = max(observed lateness
  since last membership change, ping-spread seed) + timer granularity`. Every constant in
  today's formula (`×3`, `+250`, `+130`, floor 150, ceil 350, warmup=max) is deleted.
  The ratchet's ceiling emerges from the existing FSM (`DeadIval=600ms` → membership
  change → reset), not from a knob.
- **Mo's candidate hold (quantile of observed gaps) is REFUTED as stated** — the gap
  distribution is bimodal and a per-frame quantile sits in the wrong mode (§4.2). The
  ratchet is the surviving derived form; it is the VoIP literature's "spike mode"
  adapted to a deliver-everything objective (§1).
- **Key measured facts** that shaped everything:
  - At the edge, hold LENGTH is latency-free: p50/p95/p99 identical for hold
    40→343ms; only late-discard moves (4520→390). At mid it is a real Pareto trade
    (p50 68→129). §4.1.
  - `speed` at fits-load concentrates 100% on the best source: zero gaps, zero hold,
    p95 11ms vs 14ms (max) vs 11ms (single path). At spill it ties `max` goodput
    (89580 vs 89396 @90k) while keeping the spotty source dark. At deep saturation it
    pays a measured, honest −2.3% gp. §3.
  - The same key wins at mid: p95 371 vs 488 (Dc) at 0.85, gp/loss no worse. The
    design is **E1-invariant** — only `room()` flips with E1, which is already the
    settled decision. §5.

---

## 1. Prior art (rule 11 — surveyed before settling; web survey 2026-08-29, subagent, URL-cited in transcript)

| Mechanism here | Field practice | Verdict |
|---|---|---|
| `speed`: latency-ranked incremental source admission | **Nobody ships it documented.** Speedify "Secondary Threshold" = aggregate-Mbps watermark, user/cost-ranked, no hysteresis documented. Bondix claims "interactive→fastest link, never saturate a link" — marketing only, no criterion published. Academic CPF/ACPF (arXiv:2106.16003) = strict-priority spill, and documents the pinning failure. | **Novel as a shipped mode** — flagged risk (§10). Our V1 refutation (§3.2) independently reproduced CPF's documented failure mode. |
| `speed`'s per-frame key `D̂ + queue-wait` | **ECF** (CoNEXT'17): wait-for-fast iff `n·RTT_f < (1+waiting·β)(RTT_s+δ)`, β=0.25; **BLEST**: skip slow if its RTT-window cost blocks the send window, λ±δλ adaptive. | **Converges.** Ours is ECF's inequality rearranged as a sort key, with NO β/δλ constants — hysteresis is unnecessary because there is no discrete switch state (§3.4). |
| Lateness-ratchet hold | VoIP adaptive playout (Moon–Kurose–Towsley 1998): quantile of last-w delays + **spike mode** (follow macro events directly, exit on revert). RACK (RFC 8985): reo_wnd from min_RTT/4, grows on evidence, capped at SRTT. QUIC (RFC 9002): 9/8·max(SRTT, latest) + 1ms granularity. | **Converges on shape** (measure lateness, adapt, granularity floor). We diverge from the quantile half (measured: wrong mode of a bimodal distribution, §4.2) and keep the spike-following half — justified because our objective is deliver-everything, theirs tolerates concealed loss. RACK/QUIC keep multiplicative pads (9/8, /4) — we don't need them: our sample IS the needed wait, not an RTT proxy. |
| Reorder buffer sizing | Peplink: user knob, default **off**, max 2000ms (the "150ms" in P5-MODES.md is actually their recommended max inter-WAN latency spread — correct the doc). MPTCP: 2·Σbw·RTT_max receive buffer (RFC 6182). | Field has no derived hold. RFC 6182's bound cross-checks our ring memory ceiling (§4.5). |
| `max`/`redundant` taxonomy | Speedify Speed/Redundant/Streaming; Peplink Bonding/WAN-Smoothing/Hot-Failover; Cisco/Fortinet SLA-gated duplication. | Converges — our ladder maps cleanly; `redundant`≈Speedify Redundant, `max`≈Speed bonding. Fortinet's "duplicate only while SLA=0" is the reactive trigger our study already falsified (fires late); our standing lightning diverges deliberately, evidence in the study. |
| Flap prevention | ECF: multiplicative margin on measured RTT. Fortinet/Cisco: fixed hold-down timers (0–10^7 s knobs). | We need neither: no discrete activation state exists to flap (§3.4). |

In-repo: `docs/knowledge/design/prior-art-brief.md` already flagged "no slow-path
admission veto (ECF/BLEST) — conscious omission; justify or add the exposing test".
`speed` IS that veto, at the draw-order level. The orphaned derived hold at
`ackclock_sim.py:571` (0.5·RTTmin-spread + 3σ, sched='C' only) is prior internal art;
it is superseded here (it still carries a 3σ multiplier; the ratchet carries none).

---

## 2. The two modes, precisely

Shared datapath (BOTH modes — the settled design, restated for locality):
- One shared client send-FIFO, seq assigned at enqueue (seq order == enqueue order ==
  draw order — load-bearing for §4.3).
- Per-frame TX: draw FIFO head; `cand = {i : room(i)}`; place on first candidate (in
  mode order, below) whose socket accepts. `room()` is the settled E1-gated gate:
  edge → `local_ms(i) < target_ms`; mid → `_meter_ok(i)` (local AND lag-aligned
  far-inflight < target_ms).
- CAP + standing spotty-class LIGHTNING exactly as settled (E1-gated, native-first
  through the same `room()`, first-copy-wins, TTL = current ring hold). Zero changes.
- RX (both ends): seq ring, in-order release, dedup-by-seq needs no wait; hold policy
  = the ratchet (§4.4). Ring memory ceiling and skip semantics unchanged (ring.go).
- Server: **unchanged and mode-blind** — receives N tunnels, per-peer seq ring (same
  ratchet code), forwards to local WG endpoint, echoes per-link cumulative
  received-count + timestamp. No per-flow state, no reassembly, no mode awareness.
  C4 intact.

**`max`** (today's `speed` behaviour, renamed):
- Draw order: `cand.sort(key = local_ms(i))` — hungriest-first. Work-conserving
  aggregate of everything usable. This IS the settled pull; zero mechanical change
  beyond the hold policy.

**`speed`** (new semantics):
- Draw order: `cand.sort(key = D̂min_i + local_ms(i))` — marginal completion time at
  the draw instant: measured per-path delay floor plus the queue-wait a frame placed
  there now would experience. No prediction, no committed future state — both terms
  are current measurements; the frame still goes through the same gate and socket.
- Everything else identical, including cap and lightning (§5).

State added by `speed`, client-side only: `D̂min_i` — per-path windowless minimum of
(arrival − txstamp) from the existing pong/data timestamps, reset on membership change
(§9 for the honesty on staleness). That is the entire diff between the modes.

---

## 3. `speed` source activation — measured, and mostly deleted

### 3.1 The emergent-activation thesis (CONFIRMED)
No admission controller exists. Ranking = the sort key. Activation = spill: a source
with rank k draws only while sources 1..k−1 have closed gates (their measured wait
exceeds the latency gap to k). Deactivation = starvation: when demand drops, higher-key
sources' queues drain within `target_ms` and they stop being drawn.

MEASURED (expF, S3 = eth 9ms / wifi 16ms / cellA 27ms·25jit·dropouts, edge, 6 seeds):

| offer | mode | gp | loss% | share eth/wifi/cell | gaps (n, max ms) | p50/p95 ms |
|---|---|---|---|---|---|---|
| 30k | max (V0) | 29798 | 0.55 | .54/.30/.16 | 12240, 3 | 14/14 |
| 30k | speed (V2) | 29964 | 0.00 | **1.00/0/0** | **0, 0** | **11/11** |
| 60k | speed | 59926 | 0.00 | 1.00/0/0 | 0, 0 | 11/11 |
| 90k | max | 89396 | 0.55 | .56/.31/.12 | 36037, 411 | 14/14 |
| 90k | speed | **89580** | **0.34** | .83/.17/**0.00** | 14666, 7 | 11/14 |
| 115k | max | 113746 | 0.97 | .55/.32/.13 | 48271, 411 | 14/87 |
| 115k | speed | 112476 (−1.1%) | 2.07 | .67/.30/.02 | 55194, 391 | 21/64 |
| 140k | max | 134780 | 3.61 | .54/.31/.15 | 61626, 411 | 33/254 |
| 140k | speed | 131728 (−2.3%) | 5.79 | .57/.33/.10 | 90724, 391 | 34/261 |

All-spotty S4 (cellA/B/C, homogeneous-latency, high-jitter): speed ≥ max on gp at every
load, p95 302 vs 422 at 50k. Homogeneity of OWD does NOT eliminate gaps (jitter and
dropouts dominate there) — the ratchet stays necessary; it just stays small when the
set is genuinely clean.

### 3.2 REFUTED: static latency ranking (V1 = strict priority = CPF)
`sort(key=(owd_i, local_ms))`: at 90k it never opens the third source, under-spills
bang-bang at the 40ms gate, loses **9.07%** with p50 41ms while V2 loses 0.34% at p50
11ms. Same failure mode CPF documents (§1). Any design that "activates" whole sources
on a threshold inherits this quantization; the per-frame marginal key does not.

### 3.3 REFUTED: Mo's candidate admission rule as a separate controller
"Admit source k+1 when active-set queueing delay exceeds its skew cost" is exactly what
`KEY = D̂min + local_ms` computes per frame, continuously — the controller form adds a
discrete state (the active set), a comparison cadence, and a flap surface, and can do
no better than the per-frame form it approximates. Deleting it is the simplest-form
answer (directive: deleting beats parameterizing). The candidate's INSIGHT (queue-cost
vs skew-cost breakeven) survives as the sort key itself.

### 3.4 Flap/churn
No discrete activation state exists → nothing can flap. Share follows demand
continuously (measured shares above; S3 30k→spotty=0.16 under max vs 0.00 under speed).
Residual churn surface: per-frame alternation between near-equal-key paths — harmless
(both are open and near-equal by construction; this is just striping). Hysteresis
constants: none, and none needed. (Field comparison: ECF needs β=0.25 precisely because
it keeps a binary "waiting" state; we removed the state instead of damping it.)

### 3.5 Ranking measurement + reliability gate
`D̂min_i` from existing 100ms pings + data timestamps (arrival − txstamp; clock offset
cancels in the comparison since only differences of same-direction stamps are compared
across paths — same argument as the model's theta tripwire). Reliability is NOT a rank
input: a flapping source is handled by the same gates as today (FSM DEAD at 600ms
removes it; lightning duplicates spotty-class carriage when E1=mid). Rank inputs stay
pure latency; loss protection stays in the settled machinery. N-generic: rank over
range(N), no classes, no privileged path.

---

## 4. The reorder hold, replaced

### 4.1 What the hold actually costs (the diagnosis, corrected by measurement)
Canonical N2 rig (cellA 27ms/25jit + eth 9ms/1jit), 0.85 load, post-hoc rescoring of
identical runs under many holds (zero re-run variance):

EDGE (pull):
| hold ms | p50 | p95 | p99 | late-discard |
|---|---|---|---|---|
| 40 | 12 | 231 | 261 | 4520 |
| 120 | 12 | 232 | 261 | 1388 |
| 223 (model) | 12 | 232 | 261 | 470 |
| 343 (daemon) | 12 | 232 | 261 | 390 |

MID (Dc):
| hold ms | p50 | p95 | late |
|---|---|---|---|
| 40 | 68 | 330 | 16489 |
| 120 | 89 | 350 | 6345 |
| 223 | 109 | 363 | 2524 |
| 343 | 129 | 367 | 1612 |

- **The "343ms paid on every packet" framing is FALSE at the edge**: in-order frames
  release on arrival; hold length moved no percentile at all. It is a LOSS knob there.
- **At mid it is a genuine latency/loss trade** (p50 +61ms across the sweep) because
  the hidden far queue keeps the ring blocked often.
- The model/daemon formula divergence (223 vs 343 on this rig; `nsched_model.py:1403`
  vs `paths.go:74`+`main.go:21`) is REAL and must die (bar EQ-1), but its shipped
  consequence was late 470→390 (edge) / p50 109→129 (mid) — not the ~120ms-on-
  everything the arithmetic suggested.
- Warm-up = HoldMax is backwards (one path delivering ⇒ no reorder possible) — deleted.

### 4.2 REFUTED: high-quantile-of-observed-gaps (the proposal as stated)
Measured gap census (expA, 8 seeds, pooled): edge 0.85 — 20193 gaps/run, p50=1ms,
p90=19, p99=31, **p99.9=381, max=411ms**, 28% of delivered frames arrive late; mid
0.85 — 57132 gaps/run, p50=4, p99=91, p99.9=419, max=615ms, late-frac 0.82.
**Bimodal**: micro-gaps (striping jitter, ≤~30ms, tens of thousands) and macro-gaps
(a dropout's in-flight batch arriving after the stall, 150–600ms, rare events of
hundreds of frames). A per-frame quantile sits in the micro mode: implemented online
(uncensored, with skip-memory), q≤0.99 settles at hold 10–21ms and discards bursts
(edge 0.85: late 3737–9275 vs 390 at fixed-343; S2@115k: late 4773). Between the
modes every quantile is equivalent; inside them every quantile is wrong for one
objective. The knob q is not derivable from physics — refuted, do not ship.
The windowed-MAX variant (q=1.0, W=3s) confirms the max-form works but shows the
window constant failing in both directions: at edge it FORGETS bursts spaced wider
than W (late 1887 vs 390); at mid it beats every fixed hold on late (145 vs 1610,
p50 139 vs 129). Hence the ratchet is windowLESS — reset by membership events, not
by a time constant.

### 4.3 REFUTED: the D-rule (RACK-style bound from currently-delivering paths)
`give up when now − txstamp(oldest buffered) > windowed-max per-path delay` (valid
inequality: seq order == send order under pull, so a missing frame was sent before
every buffered successor). Measured: reactive-after-the-fact — a stalled path's delay
samples are stale-low DURING the stall (the burst is skipped: late 2539–6053 at edge)
and inflated AFTER it (p99 +90ms for W=3s). Worse than fixed on both axes at edge;
W-sensitive. At mid it reaches very low late (46–299) but at p50 139–193 vs 129 —
dominated by the ratchet's operating point for `max` (late 950–1612 at p50 125–137).

### 4.4 ADOPTED: the lateness ratchet
One statistic, receiver-side, both ends:
- **Sample** `L(f)` for every frame that arrives after the ring wanted it:
  `L = arrival − t_block(f)` where `t_block` is when the frontier first blocked on
  (or passed) f's seq — ring.go already has both timestamps (`blockAt`; plus a small
  recently-passed map for the un-censored case). This single definition covers late
  frames AND hole-stragglers (frames run-skipped behind a genuine loss, measured to
  matter: gap-only ratchet cost 4427 late at S3@90k; L-fed ratchet closes it).
- **Hold** = `max(L observed since last reset, seed) + granularity`, where granularity
  is the ring-tick period (the only floor; model 1ms tick / daemon ticker — verify
  ≤10ms at port time). Strictly-greater release comparison (a gap equal to hold must
  be covered — tie-artifact measured, ~1% late from ties alone).
- **Seed** at reset = current `spread(D̂min)` over member paths (0 while one path) —
  the measured skew floor, available from pings before data flows. Warm-up hold =
  granularity, not HoldMax.
- **Reset** on path-set membership change (hotplug add/remove, FSM DEAD/revive).
  This also provides the ceiling with NO knob: an outage long enough to inflate the
  ratchet badly (>600ms) trips the existing `DeadIval` → membership change → reset.
  Ring memory (existing mask/flushTo) remains the physical backstop (RFC 6182 bound).
- **Cost**: O(1)/frame, one float + a bounded passed-map per ring. Computable from the
  existing 16-byte header (seq + txstamp + pathID); **zero wire changes**.
- **Genuine loss vs late**: a lost frame blocks the head for ≤ hold (typ. spread+jitter,
  8–40ms in speed; up to learned-burst size in max) then run-skips — vs 150–350ms
  today. A late frame releases on arrival, always.
- First-macro-event honesty: the ratchet cannot cover the first-ever burst (learning
  costs one event: e.g. S4@15k speed late=15 vs max late=510 — the speed set rarely
  pays it; max pays one burst per cold start). Covering event #1 requires either a
  prior constant (rejected) or duplication — which is exactly what lightning provides
  when E1=mid. Reported, not hidden.

### 4.5 Does `speed` need a hold at all?
While demand fits the best source: NO — measured zero gaps, hold sits at granularity,
and the ratchet IS zero-by-construction there (nothing observed → seed 0 + gran).
When striping begins, micro-gaps appear (≤7ms at S3@90k) and the ratchet buys them at
their measured price, not at a padded one. Deleting the ring entirely (deliver out of
order, let inner TCP/RACK absorb) is attractive-by-physics but unmeasurable in this
emulator (no inner-flow model) — parked as a hardware question (§10), NOT assumed.
Dedup/first-copy-wins keeps needing the seq ring regardless; it waits for nothing.

---

## 5. Interaction with the settled cap + lightning

- **Both modes keep both mechanisms, E1-gated exactly as settled.** The draw-order key
  is orthogonal to `room()`; measured at mid (expG): speed with the settled Dc gate
  beats Dc-hungriest on every axis at 0.65/0.85 (gp 68884/84532 vs 68792/84296, loss
  0.83/6.94 vs 0.96/7.20, p95 56/371 vs 67/488) — and REDUCES the study's honest-fail
  loss overshoot at 0.65.
- Feeding the meter into the KEY (`owd + max(local_ms, far_ms)`) was measured WORSE at
  0.85 (p95 456 vs 371) — refuted; the gate does the regime work, the key stays one
  form. **The speed design is E1-invariant**; E1 only decides `room()` and lightning,
  which it already did.
- Lightning in `speed` is naturally thrifty: spotty sources are dark below spill →
  standing nomination idle (dup tx measured 8669→0 at mid 0.40; 12414→~258–496 at
  0.65). When demand pushes carriage onto spotty class, the same native-first slack
  rule protects it — and pre-empts exactly the macro-gaps the ratchet can't foresee.
- `max` differs from today's shipped design ONLY in: the hold policy (§4.4), the
  warm-up fix, and the name.

## 6. Ordering vs work-conservation (deliverable 5, measured)

Dispatch accounting for arrival time (the key) costs goodput ONLY at deep saturation:
0% at ≤90k, −1.1% at 115k, **−2.3% at 140k** (0.92 of Σcap), edge S3; ≈0% at mid
(g2 ≥ g0 everywhere measured). That is the honest price of `speed`'s semantics and is
why `max` retains hungriest-first: at saturation `max` must win throughput. A
homogeneous active set does NOT make ordering moot (S4: ordering still improved p95
by 120ms at 0.73 load) because jitter/dropouts, not OWD spread, dominate there.

## 7. Mode plumbing (grounded in `deploy/p5/*` as of `water-pull-fold`)

Current facts: mode ∈ {redundant, eco, cell, speed} (`bondctl:42`); `direct` = node
`off`, not a mode; `mode_of()` defaults `redundant` (`bond-xctl:119`); `speed` walks
`bond.dag:57` gated on `installed,manual,agg_installed,two_wans`; ecod auto never
selects it (`bondctl:62`).

The ladder becomes: `direct(off) · eco · cell · redundant · speed · max`
(bandwidth ↑ rightward; latency-under-loss best = redundant; clean-latency best =
speed at fits-load).

Changes (minimal-diff, converge-safe):
1. `bondctl`: accept `mode max`; case list + usage strings. Auto policy still never
   selects either agg mode.
2. **Both agg modes share ONE dag intent** (the feeder lifecycle is identical). Rename
   intent `speed`→`agg` in `bond.dag` + `bond_model.py` + xctl function names
   (`is_speed`→`is_agg` testing mode∈{speed,max}; `engaged_speed`→`engaged_agg`;
   `speeddown_if_speed`→`aggdown_if_agg`; `verify_speed`, `ep_speed`, `speed_revert`
   likewise). The scheduler mode rides `agg_env` as `AGG_SCHED=max|speed` emitted by
   `build_agg_env` → a speed↔max flip is an env byte-change → existing
   `agg_env_changed` crumb → `agg_restart`. No new dag rows, no new nodes; the
   equivalence proof re-runs on the renamed table.
3. **Migration (the rename breaks stored facts)**: a box with `$BOND_DIR/mode`=`speed`
   under the old semantics must come up in `max` (behaviour-preserving). The P5
   installer (E7 flow) maps the fact once at install. Old `bondctl mode speed` callers
   (scripts, ecod) get today's behaviour only under the new name — release-note item.
   `P5-MODES.md` is stale on two counts (speed semantics; the Peplink 150ms claim) —
   update or re-flag.
4. `mode_wans()` stays `*`→all-WANs for BOTH agg modes: source selection is the
   daemon's per-frame job (ms timescale), never the reconciler's (seconds). eco/cell
   pins unchanged.
5. `guard_two_wans` kept for both agg modes (N≥2; a 1-WAN box belongs in eco).
6. **`build_agg_env` is hard 2-WAN** (`bond-xctl:293-301`: `P`/`O`, `head -1`,
   `AGG_PATHS=$P,$O`, 2-value `AGG_W`) — violates N-generic today; must emit the full
   live-WAN list. Already E6's "nothing hardcoded" scope; the mode work lands on top.

## 8. What must be MEASURED to gate this (the battery + bars)

New scenarios (all on existing rigs/archetypes, fixed seeds, T=9, ≥6 seeds; paired —
every bar compares two scorings of the SAME runs or same-seed runs):

| bar | scenario | assert | measured today |
|---|---|---|---|
| SPD-1 | S3 edge, offer 60k, speed | spotty share = 0 AND gaps = 0 AND p95 ≤ p95(single-eth, same seeds)+2·gran AND gp ≥ 0.99·offer | 1.00/0/0; 0; 11≤11+2; 59926 |
| SPD-2 | S3 edge 90k | gp ≥ 0.99·gp(max) AND p95 ≤ p95(max) AND spotty share ≤ 0.02 | 89580≥88502; 14≤14; 0.00 |
| SPD-3 | S3 edge 140k | gp ≥ 0.97·gp(max) AND p95 ≤ 1.05·p95(max) | 0.977; 1.03 |
| SPD-4 | S4 edge 50k | gp ≥ 0.99·gp(max) AND p95 ≤ p95(max) | 47087≥46521; 302≤422 |
| SPD-5 | N2 mid 0.65+0.85, speed-key vs Dc | gp ≥ Dc AND loss ≤ Dc AND p95 ≤ p95(Dc) | see §5 |
| SPD-6 | step-load 30k→90k→30k (new offer_fn) | spotty share returns to ≤0.02 within the drain time implied by target_ms; no share oscillation between steps | unmeasured — build with battery |
| HOLD-1 | canonical edge 0.85, ratchet vs fixed-343 (post-hoc pair) | p50/p95/p99 within +2·gran; late ≤ late(343) + max single-event burst | 12/232/261; late gap = 1 burst |
| HOLD-2 | canonical mid 0.85 | p50 ≤ p50(343)+2·gran AND late ≤ 1.10·late(343) | 125–137 vs 129; 950–1315 vs 1612 ✓ |
| HOLD-3 | warm-up | p95 of frames sent in [0,1s) ≤ overall p95 + 2·gran (ring arms at gran, not HoldMax) | unmeasured — port assert |
| HOLD-4 | unit derivation | zero observations → hold == gran; injected gap g → hold == g+gran; membership change → hold == spread(D̂)+gran | unit test |
| EQ-1 | Go↔model trace equivalence | Go ring on a recorded arrival trace releases byte-identically to model `reorder_release` under the same policy | kills the 130/250 divergence class |

**Ways each bar could pass by artifact, and the guard:**
- *Shrink hold, book late frames as loss* → late-discard is its own barred column
  (HOLD-1/2) and loss bars are unchanged from the settled battery (rule 9).
- *Pass latency by under-delivering* → every SPD bar carries a paired gp floor;
  SPD-2's 0.99 has measured teeth (V1 fails it at 0.90).
- *Hide the tail in p99.9* → HOLD bars pin absolute late counts, not only percentiles;
  battery also reports ring depth.
- *Warm-up exclusion hides warmup artifacts* → HOLD-3 scores inside [0,1s); the rigs'
  first dropout (2.6s) is inside the scored window.
- *Tune the rig homogeneous so ΔD≈0* → rig set is fixed and includes S4 + canonical
  heterogeneous; hash-pin the battery script like the manifest.
- *Granularity inflation (gran becomes the new pad)* → HOLD-4 asserts hold==gran with
  zero observations AND gran is asserted ≤10ms in model and == ticker period in Go.
- *Offer shaping avoids spill transitions* → SPD-6 exists precisely for this.
- *Key gamed via stale D̂min* → add an owd-step scenario (route change): rank must
  re-order after the membership-reset path; KU flagged §10 — this is the one bar I
  cannot state honestly without deciding the staleness mechanism (open question #2).

## 9. Statistics census (directive: every survivor earns its place)

| # | statistic | status | why physics alone loses (measurement) |
|---|---|---|---|
| 1 | `drain_ewma` (local egress rate, τ=100ms) | pre-existing (pull core) | the gate is specified in time; raw backlog bytes have no time unit. Settled/validated with pull. |
| 2 | lag-aligned delivered-rate meter | pre-existing, E1-gated | attack1: the edge-physics gate is blind at mid (−13% gp, eviction spiral). Settled. |
| 3 | `D̂min_i` per-path delay floor | NEW (speed only) | pure-physics alternatives measured: hungriest (no rank) = V0, +3ms p95 and spotty burn at fits-load; static rank = V1, −9% gp. The key needs a per-path delay number; min is the thinnest (no α, no window — reset-scoped). |
| 4 | lateness ratchet (max L) | NEW (replaces 6 constants) | hold=0/gran discards 0.8–9% (measured); quantile refuted §4.2; D-rule refuted §4.3. A max is the thinnest surviving form. |
| deleted | rel-EWMA(0.1), jit-EWMA, ×3, +250, +130, HoldMin 150, HoldMax 350, warmup=max, quantile-q, D-rule window W | — | all replaced by #3/#4 + FSM reset events. |

Zero invented numeric constants remain in the new mechanisms. Residual numbers and
their provenance: `target_ms` (settled cap knob, pre-existing), granularity (timer
tick, physical), `DeadIval` 600ms (pre-existing validated FSM), ping cadence 100ms
(pre-existing). The mode split adds NO new tunable.

## 10. Pre-mortem

**Known knowns (measured here):** everything in §3–§6; g0≡Dc reproduction (sanity of
the harness); V1/quantile/D-rule/g2m refuted; hold economics differ by regime; the
−2.3% saturation cost of speed; first-macro-event learning cost of the ratchet;
bimodal gap census.

**Known unknowns (each with its planned closer):**
1. **E1 edge-vs-mid** — gates cap+lightning and `room()`, as settled. The speed key is
   measured to work under both gates, so E1 does NOT gate the mode split itself. If
   E1=edge: lightning dormant ⇒ the ratchet's first-burst sacrifice on spotty actives
   is uninsured (measured size: one burst ≈ dropout-duration × spotty rate — 100–300
   frames on the rigs); accepted cost, reported. If E1=mid: lightning covers it.
2. **D̂min staleness under a genuine route change** (floor rises, min stays low →
   mis-ranking until a membership event). No windowless fix exists without a
   staleness constant. Honest options: accept + document (mis-ranking costs latency,
   not loss — the gate still spills correctly, measured by V1-at-mid behaving), or
   refresh min per-membership-epoch. **Open question for Mo, not a knob I picked.**
3. Dark-source physical wake latency (tether RRC idle→connected, hundreds of ms) —
   invisible to the model (model sockets never sleep). Existing 100ms pings may keep
   radios warm; MUST be probed on hardware alongside E1 (one measurement: latency of
   first spill onto a 60s-idle tether, pings on).
4. Clock-offset steps (NTP) transiently poison D̂min/L samples for ≤ one reset epoch.
   The model's theta tripwire covers static offsets only. Port-time guard: reject
   negative L; flag |ΔD̂| jumps.
5. Daemon/ring timer granularity on the boxes (assumed ≤10ms) — verify at port.
6. Multi-flow fairness inside the tunnel (single-aggregate offer modeled). The study
   already carries this (its §"p95 tail / inner-flow awareness"). Unchanged by this
   design; still open.
7. Ring-delete option (no hold at all, inner RACK absorbs micro-reorder) — hardware
   question; would remove statistic #4 entirely. Parked, not assumed.

**Unknown unknowns (surprise surface):** carrier middlebox reactions to striping
patterns changing per mode (CGNAT flow pinning, policers); interactions between
emergent activation and cake-autorate's own control loop on the same tunnel (two
controllers, timescale separation unproven — INV8 audit item); server-side per-peer
ring behaviour with multiple bonded clients simultaneously (C4 audit at E3);
wifi-as-WAN latency multimodality not represented by any archetype (retry bursts could
look like dropouts to the ratchet — probably benign, ratchet covers, but unmodeled).

## 11. Raw-number index (scenario → file)

- expD.out: canonical N2 edge+mid fixed-hold sweeps + D-rule (6 seeds).
- expF.out: S3/S4 edge ladder, V0/V1/V2 + ratchet scoring (6 seeds).
- expG.out: N2 mid g0/g2/g2m + Dc reproduction (6 seeds).
- expB (task b0ytcibp6): subset ladder S1/S2/S3/S4 + legacy-vs-dyn holds + lat_bias
  ablation (6–8 seeds).
- expA (task bza7i8lyk, 8 seeds, 23 min): pooled gap census edge+mid at 0.65/0.85,
  9-point fixed-hold sweeps (independently corroborates expD's rows number-for-number),
  and the dyn quantile/windowed-max grid quoted in §4.2. The mid 0.65 sweep also shows
  the model-vs-daemon holds at 21/74/108 vs 21/73/99 p50/p95/p99 — late 454 vs 261 —
  same story as 0.85.
