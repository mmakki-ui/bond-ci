# latency-bars — the OBJ-D latency gate (U14)

**This is a CI GATE, not a research artifact.** It is run by
`.github/scripts/latency_gate.py`, wired into `.github/workflows/emulator-gate.yml` as the
`latency-bars` job. Contrast `../modes-r2-study/`, which is preserved evidence and gates nothing.

## Why it exists

`docs/INTENT.md` OBJ-D: *"Nothing in the battery constrains p50/p95 today; that is why latency
drifted."* Latency became an objective partway through the project (`docs/HANDOFF.md`, FRONTIER
2026-08-29 "LATENCY became an objective"). Nothing anywhere measured it. `ROADMAP.md` U14 names the
bar set: **SPD-1..6 and HOLD-1..4**, from the r1 design table
(`../modes-r2-study/fable-modes-design.md` §8).

## What ADR-004 lets these bars assert

> *"Until condition 2 is met, the rig gates PAIRED COMPARISONS … It does not gate absolute loss or
> latency figures."*

Latency is precisely what the ADR names, so **there is no absolute class here.** Every bar is:

| class | meaning |
|---|---|
| **PAIRED** | two scorings of the SAME runs, or two runs on the SAME seeds / rig / offer, differing only in the thing under test (draw order, or hold policy). A physics error moves both sides together. |
| **STRUCTURAL** | a count that is ZERO, or one segment of a run against another segment of the same run. Not a magnitude, so the ADR-004 limit does not reach it: *"no frame was placed on a spotty source"* is a statement about the ordering code, not about the physics. |
| **UNIT** | a deterministic assertion on the ratchet's own definition, on a synthetic trace, with no rig physics in it at all. Authority: the design text that DEFINES the formula. |

r1's `SPD-1: gp >= 0.99·offer` is an **absolute loss threshold in a goodput costume** and is not
gated. It is replaced by a paired floor against an N=1 control run on the same seeds.

## The bars

`gran` = `nsched_model.DT * 1000` = **10.0 ms**, the model tick. `TOL = 2·gran = 20 ms`.
`speed` = draw key `owd + local_ms` (expF `v2` / expG `g2`); `max` = hungriest (`v0`/`g0`).
Both arms of every SPD pair are scored under the **same** hold policy (the ratchet), so the only
thing that differs is the draw order.

| bar | scenario | asserts | class | threshold, and where it came from |
|---|---|---|---|---|
| SPD-1a | S3 edge 60k | spotty-class share == 0 | STRUCTURAL | none — zero |
| SPD-1b | S3 edge 60k | out-of-order arrivals == 0 | STRUCTURAL | none — zero |
| SPD-1c | S3 edge 60k | p95 ≤ p95(N=1 eth control) + 2·gran | PAIRED | `2·gran` = model tick. **Not gated** |
| SPD-1d | S3 edge 60k | gp ≥ gp(N=1 eth control) | PAIRED | none. **Not gated** |
| SPD-2a | S3 edge 90k | gp ≥ gp(max) | PAIRED | none — r1 §6 measured 0% ordering cost at ≤90k |
| SPD-2b | S3 edge 90k | p95 ≤ p95(max) | PAIRED | none. **Fails on the clean tree** |
| SPD-2c | S3 edge 90k | spotty-class share == 0 at spill | STRUCTURAL | none — zero |
| SPD-3a | S3 edge 140k | gp ≥ 0.99 · gp(max) | PAIRED | **measured on this instrument**: the gp ratio over the five-geometry sample is 0.9993 / 0.9986 / 0.9996 / 0.9990 / 0.9985 (`out/geo_*.txt`); the WORST, floored outward to 2 dp, is **0.99**. It was 0.97, and this cell used to derive 0.97 from "0.9993 floored outward" — which gives 0.99, not 0.97. 0.97 in fact came from r1 §6's −2.3% at 140k, a different instrument under a different hold policy, and it left 2.9 pt of dilution headroom under a **gated** bar. Retightened to what this battery measures |
| SPD-3b | S3 edge 140k | p95 ≤ 1.03 · p95(max) | PAIRED | **measured**: canonical ratio 1.0276, ceiled outward to 2 dp. **Not gated** — it reaches 1.0446 on rot19 (`out/geo_19.txt`), which is the flip that demotes it |
| SPD-4a | S4 edge 50k, all-spotty | gp ≥ gp(max) | PAIRED | none. **Not gated** |
| SPD-4b | S4 edge 50k | p95 ≤ p95(max) | PAIRED | none. **Not gated** |
| SPD-5a | N2 mid 0.65 / 0.85 | gp ≥ gp(Dc) | PAIRED | none. **Fails on the clean tree** |
| SPD-5b | N2 mid 0.65 / 0.85 | p95 ≤ p95(Dc) | PAIRED | none. **Not gated** |
| SPD-5c | N2 mid 0.65 / 0.85 | late-discard ≤ late(Dc) | PAIRED | none. **Not gated** |
| SPD-6a | S3 edge step 30k→90k→30k | share rises or holds into the step | STRUCTURAL | none — segment vs segment of the SAME run |
| SPD-6b | " | share returns to the fits-load value after it | STRUCTURAL | none |
| SPD-6c | " | no residual pinning: seg3 ≤ seg2 | STRUCTURAL | none |
| HOLD-1a | N2 edge 0.85 | p50(ratchet) ≤ p50(343) + 2·gran | PAIRED | `2·gran`. **Not gated** |
| HOLD-1b | " | p95(ratchet) ≤ p95(343) + 2·gran | PAIRED | `2·gran`. **Not gated** |
| HOLD-1c | " | p99(ratchet) ≤ p99(343) + 2·gran | PAIRED | `2·gran`. **Not gated** |
| HOLD-1d | " | late(ratchet) ≤ late(343) + one event burst | PAIRED | `burst` **measured per run**: the largest contiguous run of late-arriving seqs in that same trace. r1 §4.4's "first-macro-event honesty" — the ratchet provably cannot cover the first event. r1's HOLD-2 wrote `1.10 ×`; 1.10 is invented and is not used |
| HOLD-2a | N2 mid 0.85 | p50(ratchet) ≤ p50(343) + 2·gran | PAIRED | `2·gran`. **Not gated** |
| HOLD-2b | " | late(ratchet) ≤ late(343) + one event burst | PAIRED | per-run burst, as HOLD-1d |
| HOLD-3a/b | edge / mid | p95 of frames enqueued in [0,1s) ≤ overall p95 + 2·gran | PAIRED (within run) | `2·gran`. **Not gated** |
| HOLD-4a | — | zero observations ⇒ hold == gran | UNIT | the formula. Slack is `math.ulp(expected)` — IEEE754 double spacing, not a tolerance. Measured error 0 ULP |
| HOLD-4b | — | injected gap g ⇒ hold == g + gran | UNIT | the formula. Measured error **1 ULP** (147.00000000000003 vs 147.0), which is why the bar is `≤ 1 ULP` and not `== 0` |
| HOLD-4c | — | membership change ⇒ hold == spread(D̂) + gran | UNIT | the formula. Measured error 0 ULP |

**15 of 28 bar ids are gated.** The other 13 are printed every run and gate nothing, for two
measured reasons — see `out/geometry.md` and `out/mutations.md`.

## What is here

| file | what it is |
|---|---|
| `ratchet.py` | the **lateness ratchet**, implemented for the first time. It is specified in the design (r1/r2 §4.4) and existed nowhere: `holdlib.dyn_release` is the refuted quantile, and expF/expG/expH all score a *clairvoyant* `max(gaps over the whole run) + TICK` applied as a fixed hold |
| `latency_battery.py` | the bars. Always exits 0 and prints a verdict, like `nsched_model.py` and `highn_battery.py`. `DEFECT=<name>` injects one of six real design errors |
| `geometry_split.py` | derives which bars may be gated at all, from 5 stall geometries |
| `mutation_matrix.py` | derives which defect reddens which bar |
| `out/RUNME.sh` | regenerates both studies |

## A bar is one signed number, and PASS is its sign

`bar(id, subject, margin, detail)`. There is no `ok` argument. `PASS` means `margin >= 0`, and the
margin is printed on every check line as `MARGIN <id> | <subject> | <%.9g>`.

This is not cosmetic. The previous signature took the verdict and the margin as **independent**
arguments, so a tolerance could be widened in the verdict expression while the margin went on
printing the undiluted number. Four **gated** bars were diluted exactly that way — SPD-3a
`0.97 → 0.60`, HOLD-1d and HOLD-2b `+burst → +20*burst`, HOLD-4a `< 1e-9 → < 5.0` ms — the hash pin
was re-measured the way this unit's own DEMO B/C prescribe, and the gate exited **0** with all four
mutation rows `-> ok`. That is the fourth weakened-green gate in this project.

Why neither existing mechanism saw it:

| mechanism | what it bounds | why it missed this |
|---|---|---|
| hash pin (`PIN`) | the battery being edited **without saying so** | the attack re-measures it; `--rehash` is one command |
| mutation matrix (`MUTATIONS`) | a bar detecting a **gross** defect | proves the bar fires at 13×–30× the clean margin; says nothing about the 12× in between |
| `MUST_FAIL` shrink detector | a recorded fail that **stops** failing | only reaches bars that already fail — SPD-2b and SPD-5a, **3 of 15** gated bars |
| **`MARGIN_PIN`** (new) | **how much headroom the bar has** | a widened bar *is* a moved margin |

`latency_gate.py:MARGIN_PIN` pins all **31** check-line margins, gated and reported alike, to 9
significant digits (IEEE754 doubles carry ~16, so seven digits of headroom for accumulated rounding).
Re-baseline with `--remargin`, which prints pinned-vs-measured with the delta. `--rehash` deliberately
does **not** touch it: "dilute, `--rehash`, commit" is the attack.

A margin that moves because the system under test genuinely moved is equally loud, and that is the
same discipline as `MUST_FAIL` — from the gate's position the two are indistinguishable, so both
are exit 1.

## The granularity-inflation guard, both limbs

r1 §8 pre-registers it as two limbs: *"HOLD-4 asserts hold==gran with zero observations AND gran is
asserted ≤10ms in model and == ticker period in Go"*. Only the first was implemented, and HOLD-4
compares the ratchet's floor against **the same variable it was handed** — so raising
`nsched_model.DT` moves `GRAN`, `TOL`, the ratchet floor and all three HOLD-4 expectations together
and every bar still passes.

`latency_battery._gran_guard()` is limb two:

- `GRAN` must equal `DT * 1000` **re-read from `nsched_model.py`'s source text**, so it cannot be set
  from a literal in the battery;
- `GRAN <= 10.0` ms — r1's own pre-registered bound, and the tick every published margin here was
  measured at. Inflate `DT` and the battery exits non-zero with a named guard message before any
  physics runs, which is what makes the failure *isolate* the artifact;
- the Go side is **measured and reported, not asserted**: `daemon/main.go` ticks the ring
  (`ring.Tick(now)`) once per control-loop iteration, and that loop sleeps `PingIval = 100 ms`. So
  r1's "== ticker period in Go" **does not hold**: 10 ms in the model against 100 ms in the shipped
  ring. Every HOLD bar here is scored at a granularity 10× finer than the daemon can resolve. That is
  a new honest fail, printed in the banner on every run.

Inflation at the *call site* (`ratchet_release(items, GRAN*3)`) is a different attack and is covered
by HOLD-4 plus the `ratchet-x3` mutation. The two limbs cover the two places.

## Two things this gate does that no other job in this repo does

**1. It only gates bars whose verdict survives a change of stall geometry.** U33 measured that this
rig's stall schedule is hand-placed, that seeds vary jitter and not phase, and that even *paired*
quantities move ~0.9 pt when the phase is rotated (`ROADMAP.md`, "U33 — the corrected phase result").
`out/geometry.md` scores all 31 checks on canonical + four `rig_checks.phase_drops` rotations. Seven
bar ids flip and are demoted. **The split is measured, not chosen.**

**2. It runs a mutation matrix every time.** Every gated bar has a pre-registered defect that must
turn it RED, and the job FAILS if it does not. This repo has shipped two bars that passed while
deliberately weakened — a 4× B2 dilution and a hardcoded seed count, both exit 0
(`.github/scripts/rig_paired_gate.py`, `preflight`) — and review caught both, not CI. **A hash pin
stops the battery being EDITED; only a mutation matrix stops it being HOLLOW.**

## What this unit found about the r1 bar table itself

Recorded rather than smoothed over, because four of the six ungated bars are ungated *because of it*.

1. **`gran` is 10 ms, and the r1 table computed its tolerances at 1 ms.**
   `nsched_model.py:62` is `DT = 0.010`. `modes-r2-study/expH_frontier.py:21` says
   `TICK = 1.0  # model granularity, ms (DT)`. `holdlib.py:51` had it right (the `dyn_release`
   default is `gran_ms=10.0`; the floor it applies is at `:68`).
   Every `+2·gran` in the r1 bar table is therefore 10× tighter than the instrument can resolve.
   Corrected here — which is what removes SPD-1c's teeth: the whole p95 spread between "use every
   source" and "use only the fastest" at a fits-load offer is 3 ms, inside a 20 ms tolerance.
2. **The r1 table's `gp` and `p95` columns were measured under different hold policies.**
   `expF_marginal.py:92` appends `gp` from `sim.run()`, which scores under the legacy
   `(spread + 3·jit + 130)/1000` hold the design deletes (`nsched_model.py:1412`), while `p95`/`late`
   on the same printed line come from the clairvoyant ratchet built at `:98` and scored at `:99`.
   Scored consistently under one policy, SPD-2's p95 claim (`14 ≤ 14`) does not hold: it is 21 vs 14.
3. **At the edge, a latency bar on the hold cannot fail** — which is r1 §4.1's own headline finding
   (*"the 343ms-paid-on-every-packet framing is FALSE at the edge … it is a LOSS knob there"*),
   independently reproduced here. HOLD-1a/1b are therefore unfailable as written, and it is the
   design's own measurement that says so.
4. **HOLD-3's reference absorbs the defect it exists to catch.** Comparing the warm window's p95
   against the *overall* p95 compares 12 ms against 242 ms; arming the ring at HoldMax instead of
   granularity moves the warm window to 12 ms (edge) / 76 ms (mid) and the bar still passes.

## Named non-coverage: SPD-6 is degenerate on the clean tree

All three of SPD-6's segment shares measure **0.0000** — `speed` never draws on the spotty source at
any point in the 30k→90k→30k profile, because S3's eth+wifi carry 90k between them. So on the clean
tree SPD-6 asserts *"the spotty class is dark throughout the step profile"*, not *"the share returns
after the step"*. It is **not vacuous** — `rank-hungriest` reddens all three limbs (seg1 0.1431 /
seg2 0.1327 / seg3 0.1464, and 6b and 6c both fire) — but the step-RESPONSE property the bar was
written for is untested until the step reaches an offer that actually forces a spill onto the spotty
class. That is one more offer, not a redesign.

## Running it

```bash
cd p4-bondagg/sim/latency-bars
SEEDS=6 python -u latency_battery.py              # the bars
SEEDS=2 DEFECT=rank-static python -u latency_battery.py   # a known-bad tree
SEEDS=6 T=9.0 PYTHONHASHSEED=0 python ../../../.github/scripts/latency_gate.py   # the gate
sh out/RUNME.sh && python geometry_split.py && python mutation_matrix.py

# re-baselining, after a change you can explain:
python ../../../.github/scripts/latency_gate.py --rehash     # hash pin ONLY
SEEDS=6 T=9.0 PYTHONHASHSEED=0 \
  python ../../../.github/scripts/latency_gate.py --remargin # margin pin + deltas

# and the gate's own RED demonstrations, six of them, real exit codes:
sh out/reddemo.sh      # from the worktree ROOT
```

## What a green run does NOT mean

The rig has never been compared against a real router (ADR-004, "Open"). A green `latency-bars` says
the **ordering** held on one hand-placed stall geometry under a fixed seed set. It says nothing about
any absolute latency number, and nothing about hardware. Three bars fail on the clean tree and are
carried in the gate's baseline with their measured margins.

Six more limits, all measured, all printed in the gate banner on every run:

1. **The system under test is `expF_marginal.VSim` / `expG_mid.GSim`** — the r2 *study* simulators,
   draw keys `v0/v1/v2` and `g0/g2/g2m`. It is **not** `nsched_model.py`'s scheduler and it is **not**
   `p4-bondagg/daemon/`. `INTENT.md:118-119` scopes OBJ-D to `emulator-gate.yml` + `nsched_model.py`.
   A green run constrains a research prototype's draw order; it constrains no shipping code.
2. **SPD-2a is a knife edge on a fatal job.** No `continue-on-error`, and SPD-2a is gated at a
   measured paired margin of `0.046310` — `0.000000` on three of the five geometries. Deterministic,
   so it will not flake; one adverse frame in the SUT turns the whole emulator-gate red.
3. **Every gate run is `GEO=canonical`.** The geometry study that produced the GATED/REPORTED split
   is never re-run by the job, so a bar that becomes geometry-unstable will not be noticed here
   (`out/RUNME.sh` does it by hand). Tracked as U14c.
4. **The geometry sample is 4 phase rotations** of one hand-placed stall schedule; stall count and
   duration never vary. A lower bound on the true spread.
5. **Rig sizes are N ∈ {1,2,3}.** The wire ceiling is 256. Nothing here measures latency above N=3.
6. **The model tick is 10 ms; the shipped ring ticks at 100 ms** (`daemon/main.go` `PingIval`, the
   cadence that calls `ring.Tick(now)`). Every HOLD bar is scored 10× finer than the daemon resolves.
   Tracked as U14d.
