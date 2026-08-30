# p4-bondagg/sim/ — emulator ownership (single source of truth)

This file is the ONE place that states what each emulator here is for. Comments inside the files
have drifted on this before (stated three different ways) — if you touch that framing, update it
here first, then let the file comments defer to this doc rather than restating it.

| File | Role | CI job |
|---|---|---|
| **`nsched_model.py`** | **AUTHORITATIVE EIF oracle.** The rule-3 MODEL GATE for the `speed`-mode N-path scheduler design (`docs/knowledge/design/speed-mode-scheduler.md`): closed-loop CapEst (busy-gated delivered-rate + lag) + Smith-predictor queue estimate + argmin-ETA path pick. This is what the Go EIF daemon port (`p4-bondagg/daemon/{eif,estr,qtrack2}.go`) is validated against. | `eif-model` |
| **`sched_model.py`** | **Legacy-pinned P4 model.** The 2-path AIMD rate controller that `daemon/paths.go`'s `Ctl` mirrors verbatim (fields, constants, branch order). Kept as the validated behavioral reference and the `[2]→[N]` port source — not the target for new scheduler-design work. | `model` |
| **`pathsim.py`** | **Non-fatal daemon-timing smoke ladder.** Spawns real `bond-agg` daemon processes end-to-end (scenarios S1–S9). Daemon-timing variance flips S3/S6/S8 run-to-run (the documented P4 marginality) — it gates as informational/non-fatal, not a hard pass/fail bar. | `ladder` |
| `mpath_model.py` | Earlier N-path reference harness — hands the scheduler PERFECT per-path info (no closed-loop CapEst, no estimator lag). Superseded by `nsched_model.py` for scheduler-design validation; kept as a comparison harness, not wired as a CI gate. | — |

CI wiring: `.github/workflows/emulator-gate.yml`. Design docs: `docs/knowledge/design/{speed-mode,speed-mode-scheduler,eif-port-plan,capest-go-port-spec,fec-port-findings,fidelity-closure-spec}.md`. Live project state: `docs/HANDOFF.md`.
