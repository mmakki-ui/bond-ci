# bond — public CI mirror

**Read-only snapshot. Do not open PRs here.** Development happens in a private repo; this
mirror exists only so GitHub Actions has unlimited minutes to build and test the code.

It carries the sources the workflow builds and runs, and nothing else — no design docs, no
deployment procedures, no operational configuration. Every push is a fresh single-commit
snapshot, so there is no history to mine.

## What CI checks here

| job | what it runs |
|---|---|
| `go` / `go-server` | gofmt, vet, `go test -v`, a minimum test count, `go test -race`, build |
| `crossbuild` | linux/arm64 + armv7 |
| `model` / `eif-model` | the scheduler models |
| `rig-paired` | the two-stage datapath oracle, paired comparisons only |
| `ladder` | a behavioural smoke ladder over the push stack |
| `recon-model` / `recon-ecosim` | the orchestration equivalence models |
