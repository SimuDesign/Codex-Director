# Building

## Requirements

- macOS 26 or later
- Xcode 26 with the macOS 26 SDK
- Swift 6
- XcodeGen
- Git
- ripgrep (`rg`), used by privacy and source-contract checks

ZIPFoundation is resolved through Swift Package Manager at the exact version recorded by `Package.resolved`.

## Verify

```bash
./scripts/verify.sh
```

This runs the public-release, version, workflow, license, dependency, and media contract checks; scans tracked content; executes the Swift test suite; and builds the Swift package using isolated caches under `/tmp`.

## Build the application

```bash
./scripts/build-local-app.sh
```

The script performs a stripped Release build from the checked-in Xcode project, reads bundle version expectations from `project.yml`, and checks bundle identity, resources, embedded personal Home paths, third-party notices, the ad-hoc hardened-runtime signature, and exact `arm64` plus `x86_64` coverage. It does not install the app.

## Build release artifacts locally

After a successful Release build, create the same verified artifact set used by GitHub Actions:

```bash
./scripts/package-release.sh --output /tmp/codex-director-release
```

The output contains the unnotarized universal app ZIP, `SHA256SUMS.txt`, `BUILD-INFO.json`, and `DEPENDENCIES.json`. The packager refuses to replace an existing output directory, verifies the source app before packaging, extracts the completed archive into a temporary directory, and verifies it again before publishing the output directory.

When `project.yml` changes, regenerate the checked-in project with `xcodegen generate --spec project.yml` from a checkout directory named `Codex Director`, then review the project diff before committing it.

## Heavy performance tests

Startup and large-query performance checks are opt-in. They use synthetic data and disposable `/tmp` roots, and never inspect a developer's Codex data:

```bash
./scripts/run-startup-performance.sh --scenario cachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedIndexed --samples 20
./scripts/run-startup-performance.sh --scenario uncachedNoIndex --samples 20

CODEX_DIRECTOR_RUN_HEAVY_PERF=1 swift test -c release --disable-sandbox \
  --scratch-path /tmp/codex-director-query-performance-run \
  --filter QueryPerformanceTests
```

Use fewer than 20 startup samples only to verify the harness plumbing; the report is then explicitly marked as a smoke run. See [Performance](PERFORMANCE.md) for measurement semantics, thresholds, and evidence that still requires Instruments or manual interaction.
