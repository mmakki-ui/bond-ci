# EQ-1 — trace equivalence between the Go pull core and the two-stage rig

**Task U9. ADR-004 condition 1.** Until this directory existed, no trace had ever been
recorded, so the condition was untestable. It is now testable, partially met, and the
uncovered part is enumerated below rather than argued away.

## Why a trace, and what it has to contain

The oracle (`pull-study/03-reserved-composite/reserved_composite.py`, `SimD`, `sched='pull'`)
and the port (`p4-bondagg/daemon/pull.go`) do not share a state space:

| | oracle | Go pull core |
|---|---|---|
| time | fixed 10 ms ticks | continuous |
| concurrency | single threaded | N goroutines on one pool |
| admission gate | `_local_ms(i) < target_ms` — a backlog / drain-EWMA **estimate** | the socket refuses the write |
| draw order | `cand.sort(key=_local_ms)` — hungriest first | Go mutex acquisition order |
| pop | peek, pop on success | pop, roll back on refusal |

Feeding both the same *inputs* would diverge on tick 1 for reasons that say nothing about
the port. So a trace carries four things, and the split between the first three and the
fourth is the whole design:

1. **Arrival process** — every enqueue, in order, at its tick, with the seq the oracle stamped.
2. **Physics events** — per-link stage-2 capacity every tick, dropout intervals, owd/jit.
   Audit and reproducibility only: the Go core consumes no rate anywhere. Arm B does use
   them, to drive fake sockets.
3. **Admission decisions** — which link took which seq, in the oracle's order, plus the
   `room()` exclusion set at the moment the oracle's draw loop stopped. **Supplied to the
   port, not compared against it.** This is what makes the two commensurable at all.
4. **Outputs** — the emitted frame stream as wire bytes, the shed set, and a digest of the
   whole pool at every tick boundary. **This is what is compared.**

## Format — `EQ1TRACE` v2

Line-oriented ASCII, `|`-separated, `\n` endings, optionally gzipped (`.eq1` / `.eq1.gz`).
Records appear in execution order; a reader replays them as a program.

| record | fields | meaning |
|---|---|---|
| `V` | version | format version (2) |
| `M` | `k=v` … | header: `n`, `sched`, `rig`, `seed`, `T`, `dt_ns`, `frame_bytes`, `payload_bytes`, `hdr_len`, `ver`, `magic`, `pkt_kb`, `maxq_kb`, `pool_max_frames`, `pool_max_bytes`, `pool_max_age_ns`, and the sha256 of all three pinned oracle files |
| `L` | idx, label, class, nominal kb/s, owd ms, jit ms, dropouts | one per link, exactly `n` of them |
| `T` | tick, ns, `a=`alive mask | tick boundary |
| `C` | cap per link | **LOCAL** stage capacity this tick, i.e. `lcaps` as the oracle's PIECE 1 computes it. Arm B's fake socket is clocked by these |
| `Cd` | cap per link | downstream stage capacity this tick. Audit only |
| `A` | seq | one arrival, enqueued at the current tick |
| `S` | seq, reason | one pool shed (`b` = byte limb) |
| `D` | idx, seq, `a`, fseq | link idx took seq; fseq is its accept ordinal |
| `D` | idx, seq, `r` | link idx attempted seq and its stage refused (never observed — see below) |
| `R` | idx,… | links that were alive but failed `room()` when the draw loop stopped |
| `P` | tick, depth, digest | sha256 of the pool's seq list (first 16 bytes) at the end of that tick |
| `X` | `k=v` … | totals: arrivals, placed, refused, shed, room_excluded, per-link `assigned`, `emission_sha256`, and the rig's own gp/loss for the record |
| `E` | sha256 | sha256 of every preceding line, `\n` included |

**v1 → v2:** v1 emitted only the *downstream* capacity under `C`. In the edge rig that
is `lambda t: HUGE` (`reserved_composite.py@'down_cap_fn=lambda t: HUGE'`), so Arm B's device queue ran at
1e9 kb/s, never refused, and reported a peak occupancy of 0 ms on every link of every
trace. Both replays now refuse a v1 trace rather than misread it.

`n` is a header field and the link records are counted against it. Nothing in the format,
the recorder or either replay is 2-shaped; `n1-cell` and `n5-het` fixtures exercise the ends.

## What "byte-wise" means here, exactly

For every placement the recorder builds the frame the port must emit — from the `frame.go`
layout, reimplemented independently in Python — and folds it into a rolling sha256:

```
[0]=0xB0  [1]=(Ver<<4)|FlagData  [2]=pathID  [3]=0
[4:8]=seq32   [8:12]=ZEROED      [12:16]=fseq32   [16:1224]=body
```

The body of frame `seq` is byte `j` = `(seq*31 + j) & 0xFF`, so a body attached to the wrong
seq is a byte mismatch rather than an invisible swap. **1220 of the 1224 bytes are compared.**
The excluded four are `[8:12]`, the txstamp: it is `time.Now()` (`paths.go@'func nowMS() uint32'`) and is not
reproducible. That is the only masked field, and it is masked in place so what is hashed is
exactly what is compared.

## Scope — proven, and NOT proven

**Proven byte-wise, per frame, in order, at every tick** (Arm A, `daemon/eq1_replay_test.go`):

- seq is stamped at enqueue in app order and travels with the right body;
- the pool is a strict FIFO under interleaved draw / rollback / shed;
- the pool bound sheds oldest-first and sheds *exactly the oracle's frames at the oracle's
  tick* — asserted by full-pool digest equality every tick, not by counts;
- a refused frame returns to the **head** with its original enq stamp and is re-offered
  before any younger frame;
- a refusal does not burn `fseq`: each link's wire sub-sequence equals the oracle's own
  per-link accept ordinal;
- `pathID` is the link the oracle placed the frame on.

**NOT proven, and not silently:**

- **Draw order (pull.go S1).** The trace supplies it. `pull.go@'is the adjudicator for S1 and S2'` nominates EQ-1 as S1's
  adjudicator; **it cannot be, by construction** — the Go core has no observable counterpart
  of `_local_ms` to compare against. Arm B measures the *consequence* instead and reports it.
- **`room()`.** Same reason: the oracle's estimator gate is an input here, not an output.
- **S2(a), the in-flight understatement of the pool bound.** A drawn-but-unsent frame is out
  of the Go pool and invisible to the bound. The oracle is single threaded and has no such
  state, so there is nothing to compare against. Bounded by construction at N frames.
- **The AGE limb of the pool bound.** The oracle has no age limb — its bound is bytes only
  (`reserved_composite.py@'while len(s.fifo) * PKT_KB > s.maxq_kb'`). The replay runs `maxAge = 0`. Inventing an oracle age
  limb to match the port would be making the oracle agree with the port. Uncovered.
- **The txstamp field.**
- **Everything downstream of the send**: reorder ring, hold, loss meter, the server.
- **E2b (cap) and E2c (lightning).** Not built in Go, so `sched='Dc'` has no counterpart.
  Only `sched='pull'` is recorded, which is E2a's counterpart.

## Two findings the recorder produced, before any comparison ran

1. **The oracle's `Stage.offer` never refuses under `pull`.** `room()` excludes a link
   *before* it can attempt, so the oracle's `if not placed: break` branch is dead: `refused=0`
   in every trace recorded. The Go core has no such foreknowledge — a link finds out by
   drawing and being refused, then rolling back. So **the rollback path has no oracle
   counterpart at all.** EQ-1 tests it as a *transparency* property instead: the `R` records
   name the links the oracle had excluded when its loop stopped, the replay makes each of them
   draw and be refused, and the emitted stream must come out bit-identical.
2. **The MID rig never stresses the pool.** In `bottleneck='mid'` the local stage runs at
   20× base, so the send-FIFO never backs up: `n5-het-mid` records **0 sheds and 0 room
   exclusions**. `RIG='mid'` is the default of `highn_battery.py` and therefore of the
   `rig-paired` CI gate — so **the datapath's pool bound, its shed order and its rollback are
   unexercised by the existing gate.** The EQ-1 fixtures are mostly `edge` for that reason.

## Round 2 — the four gates that were green while weakened

An independent verify found four, all of the same shape: something this unit *wrote down*
that no code *read*. Each is now executable.

**1. Citations were coordinates into files this unit does not own.** Eighteen `file:line`
citations shipped; ten were wrong on `dev`, because U35 prepended a 52-line import-pin
header to `reserved_composite.py` the same day and everything below it moved by exactly
+52. One (`_local_cap`) was wrong on this branch too. Fixing the ten numbers would have
left the mechanism intact. Citations here are now **anchors** — the source text itself —
and `eq1_citecheck.py` resolves every one, bans the bare form in the files U9 owns, and
carries `--selftest` so a gate that cannot fail is not mistaken for a gate that passed:

```bash
python eq1_citecheck.py --selftest      # both rules must fire on a planted defect
python eq1_citecheck.py                 # 23/23 resolve in the working tree
python eq1_citecheck.py --git-ref dev   # 23/23 resolve on the MERGE TARGET
```

`--git-ref dev` is the check that would have caught round 1, and it prints `dev`'s line
numbers (`:240` here is `:292` there), so the +52 shift is visible instead of silent.

**2. The oracle pin was recorded, declared fatal, and never read.** The header carries the
sha256 of the three oracle files; the recorder's own comment said a mismatched replay is
void. Nothing read the keys, and the committed fixtures were *already* void on `dev`. Both
replays now enforce it (`check_pin` here, `eq1OraclePin` in Arm A) and both negative
controls carry an `oracle-pin` mutation, because an unread check and no check are the same
thing. There is no skip flag. The remedy is mechanical:

```bash
python eq1_record.py --rerecord traces/n2-het-edge.eq1.gz
```

which re-records from the trace's own header parameters and prints every total that moved.
**Measured, all five fixtures, against `dev`'s post-U35 oracle: nothing moved.** The two
sha keys in `M` and the `E` body digest are the *only* differing lines — 37,173 / 129,705 /
72,242 / 151,189 / 93,931 lines compared per trace, every other line identical. So the U35
drift is cosmetic *for these traces*, established rather than assumed — and the pin still
fires, because "cosmetic this time" is not a property a gate can know in advance.

**3. Arm B's gate would have passed Arm B's own retracted v1 defect.** The four gated
invariants (contiguous fseq, no duplicate seq, no invented seq, frame conservation) are all
satisfied by the v1 fake: emitted == enqueued, shed = stale = residual = 0. A defect found
by *reading a reported number* was ungated against recurrence. Arm B now also requires, on
any trace whose own `X` totals say **the oracle shed**, that the free run refused at least
once, shed at least once, and emitted fewer frames than it enqueued. Every term comes from
the trace; the mid-rig trace, where the oracle shed nothing, is exempt because it has
nothing to assert. `TestEQ1FreeRunDetectsV1Fake` re-injects the v1 fake — banked tokens
clocked by `Cd` — and requires the bars to kill it.

**4. The `eq1-trace` job's last step could run zero tests and pass.** `go test -run` that
matches nothing prints a warning and exits 0, so renaming any `TestEQ1*` function emptied
the fresh-trace half of the job while the `go` job's count ratchet stayed satisfied. The
step now counts `=== RUN` lines against a floor of 4 and requires **every freshly recorded
trace to be named in the log** — a run that quietly fell back to the committed fixtures
fails too. The `go` job's floor moves 80 → 81 in the same commit as the new test.

## Files

- `eq1_record.py` — records a trace from the rig. Pins the oracle by explicit path, asserts
  `__file__`, records all three sha256s (ADR-004's amendment / U35: there are two materially
  different `ackclock_sim.py` and two `nsched_model.py`). Does not modify the rig: it wraps
  the pool deque, each local `Stage.offer`, `offer_fn` and `local[0].drain` on the instance.
  Four self-checks abort the recording if the wrap discriminator is unsound.
- `eq1_citecheck.py` — the citation gate. Resolves every `file@'anchor'` citation against
  the working tree or any git ref (`--git-ref dev`), bans bare `file:line` citations in the
  files U9 owns, and `--selftest` proves both rules fire.
- `eq1_selfcheck.py` — (a) **completeness**: an independent minimal replay must reproduce the
  recorded emission sha256, every pool digest and every shed count from the trace alone;
  (b) **teeth**: `--mutate-all` breaks one rule at a time and prints a kill matrix. Every
  mutation must be killed by at least one trace or the run fails. This is the negative control
  for the whole unit — without it, "the digests matched" is not evidence.
- `traces/*.eq1.gz` — committed fixtures, so the Go gate can never degrade to a skip.
- `../../daemon/eq1_replay_test.go` — Arm A, the gate.
- `../../daemon/eq1_free_test.go` — Arm B, the free-running measurement.

## Running

```bash
cd p4-bondagg/sim/eq1
python eq1_record.py --list
python eq1_record.py --scenario n3-het --rig edge --load 1.30 --seed 0 --T 4.0 \
                     --out traces/n3-het-edge.eq1.gz
python eq1_selfcheck.py "traces/*.eq1.gz"
python eq1_selfcheck.py --mutate-all traces/*.eq1.gz
python eq1_citecheck.py --selftest && python eq1_citecheck.py
python eq1_record.py --rerecord traces/n2-het-edge.eq1.gz   # only after a pin failure
# Go side (needs a Go toolchain -> CI):
cd ../../daemon && go test -run TestEQ1 -v ./...
```

`EQ1_TRACE_DIR` overrides the trace directory for the Go tests.

## Pool-bound derivation (no picked number)

The oracle's bound is `while len(fifo)*PKT_KB > maxq_kb` — a frame count wearing byte
clothing, since frames are uniform. The Go bound is over `wireBytes = payload + HdrLen`.
The two coincide **exactly** when `pool_max_bytes = floor(maxq_kb / PKT_KB) * frame_bytes`,
which is what the recorder emits. It is derived from the oracle's own constant, and the
recorder re-checks the two predicates against each other on every tick and aborts on any
disagreement rather than asserting the equivalence in prose.
