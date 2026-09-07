# modes-r2-study — the evidence base behind `max` + `speed` (design r2)

**What this is:** the executable evidence behind
`docs/knowledge/design/modes-max-speed-design.md` (r2, 2026-08-29) — the design that adopts
**deliver-on-arrival for `speed`** and the **lateness ratchet for `max`**, and that ADR-003's mode
split rests on.

**Why it is here:** written 2026-08-29 in a session scratchpad; folded into git 2026-08-29 because it
existed **only** in `%TEMP%` and was one sweep from being lost — the same failure that
`water-pull-fold` fixed for the r1/pull evidence (`p4-bondagg/sim/pull-study/`). Design r2 §11 cited
these files as "same scratchpad"; that citation was dangling until now.

**Status: RESEARCH ARTIFACT, not a CI gate.** Nothing here is wired into
`.github/workflows/emulator-gate.yml`. Preserved verbatim, warts included — run logs, refuted
branches, superseded variants.

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

## Provenance / physics base
Every experiment runs on the **unmodified** `p4-bondagg/sim/nsched_model.py` physics, imported from
two levels up — the same validated physics as the `eif-model` CI gate.

**One exception, and it matters:** `expH_frontier.py` carries `reorder_release_z()`, a **patched**
copy of the model's `reorder_release()` with the `hold == 0` termination guard applied (design r2
§4.6). The repo's `nsched_model.py` does **not** have that guard yet, so:

> **The measurements that justify the adopted `speed` design (deliver-on-arrival) cannot be
> reproduced from the repo's model as it stands.** Applying the §4.6 one-guard fix to
> `nsched_model.py` is what closes that gap.

## What each file answers

| file | question it answered | outcome |
|---|---|---|
| `expA_hold.py` · `holdlib.py` | hold policies across rigs/loads | the hold is an exchange rate; slope only at mid |
| `expB_speed.py` | `speed` source activation | emergent activation confirmed |
| `expD_drule.py` · `expD.out` | the "D-rule" hold | REFUTED |
| `expE_emergent.py` · `expE.out` | emergent activation without an admission controller | confirmed |
| `expF_marginal.py` · `expF.out` | marginal-source value | r1 core confirmed |
| `expG_mid.py` · `expG.out` | `speed` rank under a mid gate | rank is E1-invariant |
| **`expH_frontier.py` · `expH.out`** | **arrival vs zero/tick/spread/sp+1j/sp+2j/sp+3j/ratchet/343, paired** | **arrival dominates on every axis, every scenario → §4.3.** Also: the `hold==0` fix + its inertness check |
| `expI_spillfork.py` | spill-vs-adapt fork | superseded before run (`speed` spills) |
| `expJ_demote.py` · `expJ.out` · `expJ2.out` | the three degradations × K1–K4 rank candidates | K4 adopted; K3 fusion refuted |
| `expK_mix.py` · `expK.out` | call + concurrent bulk coexistence; bounded wait-window sweep | identical call metrics through spill; wait-window not free at mid → not adopted |
| `verify_inert.py` | is the `hold==0` guard byte-identical for positive holds? | inert, verified on both rigs |
| `vmin.py` · `vmin.out` | `D̂min` behaviour | a minimum cannot learn worse → superseded by `lastD` |
| `fable-modes-design.md` | the r1 design draft | superseded by the r2 doc in `docs/` |

## How to run
Scripts import the base model from two levels up:

```bash
cd p4-bondagg/sim/modes-r2-study && PYTHONPATH=../.. python -u expH_frontier.py
```

Measurement hygiene that applies here (`module-architecture.md` §4): `python -u`, per-seed progress
with elapsed time, scope the run to the rig that answers the question, and time-box it.
