# Performance

Codex Director keeps performance evidence reproducible, synthetic, and separate from private user data. A passing build is not performance evidence, and a single launch is not a release result.

## Startup scenarios and gates

Run each scenario from a clean checkout with a Release harness and 20 samples:

```bash
./scripts/run-startup-performance.sh --scenario cachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedNoIndex --samples 20
```

The release verifier rejects missing, duplicate, failed, or unsupported samples. It applies these p95 gates:

| Scenario | Evidence point | Gate |
| --- | --- | ---: |
| `cachedIndexed` | process birth to verified cached presentation payload | ≤ 700 ms |
| `uncachedIndexed` | process birth to startup-ready after the synthetic indexed database loads | ≤ 1,800 ms |
| `uncachedNoIndex` | process birth to the first root view marker | ≤ 1,800 ms |

The cached scenario additionally requires every sample to show a cache hit and zero startup aggregation queries after the observer is ready. Runs with fewer than 20 samples automatically use smoke mode: they validate the harness and threshold plumbing, but are not release evidence.

Each result directory contains only aggregate `startup-summary.txt`, `verification.txt`, and `environment.txt` files. The environment record includes the source commit, hardware model, memory, macOS, Xcode, and Swift versions. Do not commit raw app metrics or any report made from private source data.

A 20-sample release run refuses a dirty checkout so its evidence maps to one exact commit. Short smoke runs may use a dirty tree, but `environment.txt` records that state explicitly.

The process-birth bridge combines OS wall-clock process information with the harness monotonic clock and records its uncertainty. It does not prove when pixels were presented. The automated runner also does not synthesize input or claim a MainActor stall trace.

## Large-query checks

The opt-in Release suite uses disposable databases under `/tmp`:

```bash
CODEX_DIRECTOR_RUN_HEAVY_PERF=1 swift test -c release --disable-sandbox \
  --scratch-path /tmp/codex-director-query-performance-run \
  --filter QueryPerformanceTests
```

The suite covers a 200,000-row quota history with a 500 ms p95 gate, a 1,000,000-row quota pressure fixture, and 160,000 calls across 1,500 sessions including one 27,000-call session. It verifies correctness while printing aggregate timings only. Ordinary `./scripts/verify.sh` runs skip these expensive fixtures.

## Evidence still required for a release

Before a 1.0 release, record all three 20-sample startup reports on the release commit and run the large-query suite. Separately use Instruments on the release build to inspect app launch, Hangs, Time Profiler, and main-thread blocking, and manually exercise a destination change to measure interaction response. Those steps are required because app markers cannot establish rendered-pixel timing or diagnose a busy versus blocked main thread.

Keep only privacy-reviewed aggregate evidence. Record any regression, the exact source commit, environment, and whether the run was cold, cached, indexed, or unindexed; never relabel a smoke result as a release gate.
