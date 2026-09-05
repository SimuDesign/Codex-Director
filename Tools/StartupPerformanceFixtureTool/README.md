# Startup fixture tool

The tool is a standalone SwiftPM executable depending on the local
`DirectorCore` and `DirectorUI` products. It creates one synthetic fixture
under the fixed disposable root `/tmp/codex-director-startup-perf`.
`DatabaseStore` creates/migrates the schema and validates all DTO writes; the
tool never copies production SQL, launches an app, reads preferences, or opens
the real database. Indexed fixtures contain 200,000 quota rows, 160,000 calls,
1,500 sessions, and one 27,000-call session. Output is aggregate-only.

The supported scenarios are:

- `cachedIndexed`: indexed synthetic DB plus a small valid presentation cache
- `uncachedIndexed`: indexed synthetic DB without a presentation cache
- `uncachedNoIndex`: migrated schema only, no indexed facts/completion marker,
  and two small synthetic source sentinels for detecting accidental scanning

Prepare a new fixture with:

```text
./scripts/prepare-startup-perf-fixture.sh cachedIndexed
```

Run the expensive, aggregate-only preflight against the current manifest after
fixture creation (before timing launches):

```text
./scripts/prepare-startup-perf-fixture.sh --preflight cachedIndexed <fixture-uuid>
```

Preflight reopens the database through the real read-only `DatabaseStore`,
checks the full manifest value digest, identity, index timestamps, aggregate
row counts, and the initial cache fingerprint. Runtime launches only repeat
the cheap identity/metadata/cache-payload checks. For uncached samples, the
runner must remove only the validated direct-child `presentation.json` inside
the selected UUID fixture before each sample; an existing file is rejected by
the manifest validator rather than silently accepted.

An optional UUID may be supplied for reproducible orchestration. Existing
fixture directories are never reused. The manifest validator and tool reject
non-UUID roots, symlink escapes, unexpected child names, and cache/scenario
mismatches. The script never derives paths from `HOME` or `CODEX_HOME`.

`cachedIndexed` writes a real `StartupPresentationSnapshot` projection through
`PresentationSnapshotStore`, including Home and quota data, the actual current
classification fingerprint, and the database identity/window. All scenarios
publish the same validated cache URL; uncached cases intentionally leave only
the file absent so the production cache factory path is identical.

## Metrics summarizer

The standalone metrics summarizer reads only already-written harness metrics and
never opens the database, cache, manifest, source directory, or user paths:

```text
swift Tools/StartupPerformanceFixtureTool/summarize-startup-metrics.swift \
  --scenario cachedIndexed \
  /tmp/codex-director-startup-perf/<fixture-uuid>/metrics
```

Pass one to three explicit metrics directories (the complete argument list is
`--scenario <label> <directory>...`). Each path must be a direct UUID fixture
under the fixed disposable root. The root, fixture, metrics directory, and
metric JSON files must be owned by the current user; metric JSON files must be
regular single-link files no larger than 2 MiB. A JSON `processID` must match
its filename UUID. Duplicate process IDs across supplied directories are
reported and excluded from aggregation. The scenario label is required and is
never inferred from filenames, directory order, or launch order.

The report contains only aggregate counts. Root/cache/startup use the first
marker for each process (later window appearances are not extra launches),
while the two passive input markers use every recorded event. Median is the
usual middle-value average for even samples; p95 uses nearest-rank. Each
distribution reports median/p95/max. Root/cache/startup use the first marker;
input markers use every event. It also reports three independent per-sample
distributions: process-birth wall-clock bridge plus the first root marker,
bridge plus the first cache marker, and bridge plus the first startup marker.
These are timing bridges, not pixel-rendering claims; the elapsed markers all
share the app-init origin and are never summed with one another. The Recorder's
bridge uncertainty milliseconds are reported as their own distribution.
Missing bridge or markers, malformed/duplicate files, failures,
unsupported/uncertain clock bridges, and absent observer counters are reported
explicitly rather than treated as zero. Query/source counters, cache hits, and
directory/identity counter columns are separate. For
`cachedIndexed`, the zero-aggregation gate covers all supplied valid samples
with connected observers; it does not claim a chronological first-ten subset
because recorder UUIDs provide no launch order.
