# pull-study — the water/PULL datapath study (model code + raw results)

**What this is:** the complete executable evidence base behind the datapath pivot
(`docs/knowledge/decisions/ADR-002-datapath-pull-pivot.md`) and the settled build plan
(`docs/knowledge/design/p5-execution-handover.md`). Written 2026-08-26/27; folded into git
2026-08-29 (branch `water-pull-fold`) — it previously existed ONLY in a session scratchpad
temp dir and was one temp sweep away from being lost.

**Status: RESEARCH ARTIFACT, not a CI gate.** These scripts are the reference the Go port must
match (E2a/E2b/E2c equivalence in the execution handover). They are preserved verbatim, warts
included: run logs, falsified branches, superseded variants. Nothing here is wired into
`.github/workflows/emulator-gate.yml`.

> ## ⚠ CORRECTION (2026-08-29) — "runs on the unmodified nsched_model.py" IS MISLEADING
> Verified by inspection, not assumed: `reserved_composite.py` and `ackclock_sim.py` use exactly
> **four constants and one function** from `nsched_model` — `PKT_KB`, `DT`, `QMAX_MS`, `NLAG`, and
> `reorder_release`. Everything else — the link model, the queueing, the loss process, delivery — is
> **their own two-stage fluid simulator**. `modes-r2-study/exp{F,G,H,J,K}` subclass `RC.SimD`, not
> `NSim`.
>
> **So this evidence base was NOT produced on the CI-gated oracle's physics.** It shares a ring
> function and four constants with it, nothing more. Two consequences, both load-bearing:
> 1. The physics behind the settled datapath has **never been through the `MODEL-VALID` gate**. The
>    `eif-model` CI job validates `NSim`, which is a different simulator.
> 2. Folding the settled policies into `nsched_model.py` (OBJ-A) is therefore **not a refactor — it is
>    a decision about which physics is authoritative.** The r2 numbers do not automatically carry
>    across; measured on `NSim` they may differ, and that has to be established, not assumed.
>
> Sentences below claiming shared "validated physics" predate this check and are wrong as written.

## Provenance / physics base — and WHICH FILE, asserted (U35)

**The oracle and the physics are now pinned by path and asserted at import** — see
`rig_pin.py` in this directory, which also carries the canonical decision and the evidence
behind it. `reserved_composite.py` and both `ackclock_sim.py` copies load their dependencies
off their own `__file__`, not off `sys.path`, and raise `RigPinError` on the wrong copy.
Self-tests: `python p4-bondagg/sim/pull-study/test_rig_pin.py` (9/9, negative tests paired with
positive controls). Ask the rig what it is running:

```bash
python -c "import reserved_composite as RC; print(RC.identity_banner())"
```

**There are TWO `ackclock_sim.py` and TWO `nsched_model.py`, and both of each are LIVE.**

| module | copy | canonical for |
|---|---|---|
| `ackclock_sim.py` | `03-reserved-composite/` | the composite study, the **ADR-004 gated oracle**, `modes-r2-study/` |
| `ackclock_sim.py` | `02-ackclock/` | the 02 line only (`pred_*`, `probe_*`, `sweep*`, `verify_*`, `audit_*`) |
| `nsched_model.py` | `p4-bondagg/sim/` | everything except `hedge_measure.py`; carries U1's `hold == 0` guard |
| `nsched_model.py` | `variants/` | `variants/hedge_measure.py` only — a **fork** with the hedge/mirror machinery |

Measured 2026-08-30 (U35), both directions: the two `ackclock_sim.py` copies give **identical**
results for every scheduler the composite line runs (`ewma`/`pull`/`oracle`/`Dc`) — 48 of 60 cells
byte-for-byte over {N2-het,N3-het,N5-het,N5-corr} × {0.65,0.85,0.95} × 3 seeds, rig=mid, T=9 s — and
differ **only** under `sched='C'`, which the composite line never runs. Conversely
`02-ackclock/pred_iii_out.txt` reproduces digit-for-digit under the 02 copy and **not** under the 03
copy. Neither is deleted; `rig_pin.py` states exactly what deleting either would cost.

**Correction to the sha claim this section used to make.** It read "the unmodified
`p4-bondagg/sim/nsched_model.py` (sha256 `e8a7c67d2105…`, identical on dev)". That is stale twice
over: `e8a7c67d2105` is the **CRLF** form of the file as of the fold commit `4dcbcfa` (the LF blob
is `e9b471d218df`), and the file has since changed — U1 added the `hold == 0` termination guard, so
`dev` is now `918c88136f81`. A frozen sha in prose rots silently; the import-time pin above is
checkable at run time instead, and `variants/nsched_model.py` — which is what the pin exists to keep
out — is `a955d88ffcdd`.

## How to run
Scripts import their siblings from the script dir and the base model from two levels up:

```bash
cd p4-bondagg/sim/pull-study/03-reserved-composite && PYTHONPATH=../.. python adv_verify_dc.py
```

Python 3.12. Runs are SLOW — the 24-seed batteries take minutes to ~10 min (`adv_verify_dc.py`
took 440 s). The committed `*.txt` / `*.out` files are the original run outputs.

**Residual, named rather than fixed (U35):** the harness scripts still do `sys.path.insert(0, '.')`
or rely on `PYTHONPATH`, i.e. they still ask *cwd* which sibling to import. What changed is that a
wrong answer now **raises** instead of running: the pin lives in `reserved_composite.py` and in both
`ackclock_sim.py` copies, so any script that reaches either of them inherits it. A script that
imports **only** `ackclock_sim` still picks its copy by cwd — it just cannot pick one that has been
moved out of the line whose outputs it reproduces. `highn_battery.py` was deliberately **not**
touched: `.github/scripts/rig_paired_gate.py` pins its sha256, and editing it would kill the gate at
preflight.

## Map

### `01-pull-vs-push/` — does work-conserving PULL beat the EIF push scheduler?
- `pull_study.py`, `pull_exp.py` — pull vs push (argmin/ETA) batteries → `out_quick.txt`, `out_full.txt`
- `masterpiece_dp.py` — the integrated 24-seed prototype (pull + cap + mirror under one scheduler)
  → `mp_quick.txt`, `mp_full24.txt`. **This is the run that overturned the mirror.**
- `attack1_midnet.py` — the adversary's series-queue rig: bottleneck DOWNSTREAM of the client
  socket → `attack1_out.txt`. **The refutation that makes the cap non-optional.**
- `attack2_regen.py` — regen-EWMA robustness (rapid-flap / asymmetric / soft-dip / correlated)

### `02-ackclock/` — can end-to-end self-clocking REPLACE the statistical cap? (**answer: no**)
`ackclock_sim.py` + probes (`pred_*`, `probe_*`, `sweep*`, `trace.py`, `verify_repro.py`)
→ `final_out.txt`, `pred_*_out.txt`, `probe_*_out.txt`, `q4_out.txt`.
Verdict: REJECTED — dominated in both regimes, and the "estimator-free" claim was illusory
(the fix was a hand-tuned 350 ms RTO constant). See the study writeup.

### `03-reserved-composite/` — the reserved/duplicate layer → the SETTLED design
The executable spec of the shipped design lives here.
- `reserved_composite.py` (**`sched='Dc'` = the settled composite**) + `ackclock_sim.py`
  (pull/cap physics — **this directory's copy, which is a different revision from
  `02-ackclock/ackclock_sim.py`; ADR-004 named the wrong one for a day**. Now asserted at import,
  not asserted in prose — see `rig_pin.py` and the provenance table above)
- earlier rungs: `reserved_dp.py` → `reserved_cap0.py` → `reserved_local.py` → `reserved_meter.py`
  (D′ local-gate and D″ host-meter, both falsified)
- measurement + falsification harnesses: `measure_dc_n2edge.py`, `measure_dc_n2mid.py`,
  `measure_dc_tshare_timeline.py`, `measure_dpp_*`, `battery*.py`, `myslice_*.py`, `pareto.py`,
  `q3_sizing.py`, `q4_latency.py`, `resv_size.py`, `meterfree_check.py`, `dpp_degen_check.py`,
  `p6_dpp_meter.py`, `p7_*.py`
- independent verification (separate harness, not reusing the measurement rig):
  **`adv_verify_dc.py` → `adv_verify_dc.out`** (the headline table), `dc_paired_check.py` →
  `dc_paired.out` (per-seed paired diffs), `indep_verify.py` / `iv_main.py` / `iv_worker.py` /
  `indep_gate.py`, `confirm_falsify.py`, `verify_adv*.py`, `validate_*.py`

### `03-reserved-composite/highn_battery.py` — HIGH-N (N=4 / N=5) as a SCORED case
Added 2026-08-29 (`u3-highn-evidence`). Before it, high-N evidence was thin: N=4 had ONE scenario
(`battery.py` / `myslice_battery.py`) and N=5 existed only as the assert-nothing "N-genericity smoke
test" in `myslice_baseline.py` — a crash test, not a performance result. The client box already
declares FOUR WAN interfaces, so N=4 is current hardware.

Scores the settled composite (`reserved_composite.SimD` `sched='Dc'`) against the SAME paired
references the N=2 headline used (`ewma` = shipped one-sided cap, `pull`, `Dpp`) on six heterogeneous
mixes — a NESTED chain N2 ⊂ N3 ⊂ N4-het ⊂ N5-het plus a tether-heavy N4 (3 cell + eth) and an N5 with
CORRELATED tether stalls. Physics = unmodified `nsched_model.py`; no new archetype, no new numeric
knob. Bars: **B1** no-collapse `gp ≥ 0.99·ewma`, **B2** loss-parity `≤ ewma+0.5 pt`, **B3** spare-load
win, **B4a/b** no-eviction-spiral (spotty-class native share ≤ pull's, and no monotonic walk) — B1–B4b
are the `adv_verify_dc.py` bar shapes, B4a generalised N-generically to the spotty CLASS — plus
**B5 SCALING**, derived from the motivating requirement: on the nested chain at ONE fixed absolute
offer (0.85 × nominal of the largest member, so the small configs are genuinely over-subscribed) each
added source must strictly raise goodput and strictly cut loss. Raw output: **`highn.txt`**
(`highn.err` = progress). Env: `SEEDS`, `WORKERS`, `T`, `RIG`.
**Supersedes as EVIDENCE** the `myslice_baseline.py` N=1/N=5 smoke test (left in place verbatim as the
historical import/sanity check it was).

**Rig honesty (rule 4)** — before any new number was trusted, `adv_verify_dc.py` was re-run on this
worktree and reproduced `adv_verify_dc.out` EXACTLY (every gp/loss/tshare/paired-stat digit; only the
wall-clock lines differ). Raw: **`adv_verify_dc.repro-20260829.out`**. The battery's own `N2-het` row
then reproduces the same headline numbers a SECOND time from an independent harness
(68794/0.96%, 84307/7.19%, 91062/10.30%; paired Dc−ewma +0.845 / +0.655, 24/24 seeds).

**Result (raw in `highn.txt`) — the design HOLDS at N=4 and N=5, with 11 honest bar failures:**
- **B1 no-collapse PASSES at every N and every load** (N=2…5, incl. tether-heavy and correlated).
- **B5 SCALING PASSES on every step**: at one fixed offer of 162 350 kb/s, Dc gp 90 252 → 107 513 →
  147 269 → 148 546 and loss 44.3% → 33.7% → 9.2% → 8.4% for N=2→5; p95 also *improves* (460→258 ms).
  *Limitation:* the last step is under-stressed — N4-het's nominal (174 000) already exceeds the offer,
  so the N=5 increment (+1 277 gp, −0.79 pt) is a diminishing-returns datum, not a hard test.
- **B2 loss-parity: the known N=2 honest fail SHRINKS AS N GROWS and disappears.** paired Dc−ewma
  median @0.85/0.95 = +0.845/+0.655 (N2) → +0.515/+0.644 (N3) → +0.458/+0.690 (N4-het) →
  **−0.202/+0.286 (N5-het, PASS)**, **−0.092/+0.221 (N4-teth, PASS)**, **−0.252/+0.285 (N5-corr, PASS)**.
  It tracks the size of the steady-host pool, not N alone.
- **B3's absolute half does NOT survive N>2 — OPEN QUESTION.** `loss ≤ 2%` at load 0.65 fails for every
  N≥3 (3.07–5.39%) even though Dc is roughly HALF the shipped cap's loss there (e.g. N5-het 3.24% vs
  ewma 7.44%) and B3's *paired* half (`gp ≥ ewma gp`) passes everywhere. The 2% is an absolute constant
  inherited from the N=2 tuning; it is not N-generic. It is left UNWEAKENED and reported as a fail —
  replacing it with a derived/paired form is an open question, not something this unit picked.
- **B4a fails ONE cell:** N5-corr @0.95, spotty-class native share Dc 0.340 vs pull 0.335 (+0.005). Under
  fully correlated tether stalls at near-saturation the composite loses its eviction margin over raw
  pull. B4b (no monotonic walk) passes there and everywhere.

### `03-reserved-composite/hold_sweep.py` — the hold-cost harness
Added 2026-08-29. Scores ONE simulation run under many reorder-hold policies at once: the hold is
applied post-hoc in `finalize()`, so re-running `reorder_release` over `sim.arr`/`sim.enq` gives an
exactly-paired comparison with zero re-run variance. Prints p50/p95/p99, loss and skips per policy for
the daemon formula, the model formula, and constant-free variants. This is the harness OBJ-B (derived
hold) and OBJ-D (latency bars) need. Env: `SEEDS`, `LOADS`.
**Honest limitation:** in this sim the hold does NOT feed back into the scheduler, so this measures the
delivery-side cost only. In the real daemon the hold also feeds the loss meter
(`main.go: lossM[p].Data(fseq, now, hd)`), which can perturb control — not modelled here.

### `variants/`
`hedge_measure.py` + `hedge_out.txt` (the opportunistic-mirror `hedge_free` measurement, run under
the PUSH stack — its net-positive result did NOT transfer to pull) and the forked
`nsched_model.py` it needs.

## Reading order
1. `docs/knowledge/design/research/datapath-pull-study.md` — the writeup (claims → files)
2. `docs/knowledge/design/research/session-context/datapath-decision.md` — the full arc incl. every falsification
3. `docs/knowledge/design/p5-execution-handover.md` — what to actually build
