# Startup performance harness

This is a test-only app scaffold. It uses the real `DirectorStartupController`
and `DirectorRootView` with a `DirectorAppModel` whose classification and
evaluation stores are in-memory. It does not use `UIValidationSession`,
production preferences, or a production database path.

The harness reads only the validated, size-capped manifest at:

`/tmp/codex-director-startup-perf/current-manifest.json`

The manifest binds the complete fixture configuration and expected database
identity/index metadata with a SHA-256 value digest. It also carries aggregate
row counts and the initial cache fingerprint for the one-time CLI preflight;
the running app does not rescan those large tables as part of timing. For a
cached scenario, both restored and verified model states require nonempty Home
and quota payloads; the first such state records `cache_visible` once. That
marker means model payload availability, not a presented pixel. An uncached
manifest with an existing cache file fails closed; the sample runner is
responsible for removing only that validated synthetic file between uncached
samples.

The app records monotonic app markers such as `app_init`, `root_appeared`,
`cache_visible`, and `startup_ready`, plus aggregate Core query/source phase
counters when those observer callbacks are available. OS process birth is not
inferred from `app_init`; this harness captures only a wall-clock
`proc_pidinfo` birth-to-init bridge to its monotonic clock, including the
observed bridge uncertainty. If the OS API or clocks are inconsistent, it
records unsupported/uncertain; it does not claim a pure monotonic birth time.
No input events are synthesized by this
harness. A passive local monitor returns real events unchanged and records
only `input_to_selection` and the next matching `input_to_window_update` for
the harness window (no characters, key codes, or content). These markers do
not prove a presented pixel frame; Root must drive and observe destination
content separately. Terminal application termination waits for the recorder's
flush acknowledgement.

The harness has a standalone XcodeGen spec and build script. It links the
local `DirectorCore`/`DirectorUI` products with Release `-O`, uses an explicit
bundle identifier, and is never added to the production scheme. Its synthetic
scan root/configuration intentionally differs from production discovery; that
limitation must remain explicit in any measurement report.

Run the complete synthetic fixture, launch, aggregation and verification flow
from the repository root:

```bash
./scripts/run-startup-performance.sh --scenario cachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedNoIndex --samples 20
```

Runs with fewer than 20 samples are smoke checks only. See
`docs/PERFORMANCE.md` for the release thresholds and the separate evidence
required for input response, MainActor stalls and presented pixels.
