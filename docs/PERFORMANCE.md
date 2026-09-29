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

The Home ranking performance case uses the same 160,000-call fixture and must
derive the recent-seven and recent-thirty projections from one bounded
thirty-day aggregate. Its provisional Release p95 gate is 500 ms. Period
switching is excluded from database timing because both Top 10 sets must already
be present in the compact presentation cache; a switch that emits a SQLite or
source-index observer event is a functional failure, not merely a regression.

## Evidence still required for a release

Before a 1.0 release, record all three 20-sample startup reports on the release commit and run the large-query suite. Separately use Instruments on the release build to inspect app launch, Hangs, Time Profiler, and main-thread blocking, and manually exercise a destination change to measure interaction response. Those steps are required because app markers cannot establish rendered-pixel timing or diagnose a busy versus blocked main thread.

Keep only privacy-reviewed aggregate evidence. Record any regression, the exact source commit, environment, and whether the run was cold, cached, indexed, or unindexed; never relabel a smoke result as a release gate.

## Interaction latency work in progress — 1.4.0

The current `codex/home-ranking-periods-1.4.0` tree is uncommitted. These are
**synthetic optimized-test microbenchmarks**, not input-to-painted-frame or
Release-candidate measurements. On a MacBookPro18,3, macOS 26.5.1, Xcode 26.6,
`swift test -c release --filter InteractionPerformanceTests` queried every
Agent's companion Skills and every Skill's reverse Agent links twenty times.
The fixture contains no personal names, paths, sessions, or evaluations.

| Eligible resources / canonical relations | Before median / p95 / max | After median / p95 / max |
| --- | ---: | ---: |
| 91 / 141 | 1.95 / 1.99 / 2.19 ms | 0.23 / 0.24 / 0.25 ms |
| 192 / 95 | 4.48 / 4.59 / 4.60 ms | 0.14 / 0.14 / 0.14 ms |
| 1,000 / 4,000 | 391.31 / 394.40 / 405.03 ms | 8.56 / 9.15 / 9.41 ms |

The comparison isolates the relationship-lookup implementation. It does not
time fixture construction, SwiftUI layout, AX-tree retrieval, SQLite, or pixels.
Folder rows now use lazy stacks, unchanged segmented-control props avoid
intrinsic-size invalidation, and a warm library presentation no longer emits
transient loading; these UI changes still need a frozen optimized native
interaction trace. The Debug validation host's synthetic 1,000-capability
fixture (500 Agents, 500 Skills, 4,000 explicit relations) was also exercised
through the folder's three tabs, scrolling, and a Skill detail; only visible
rows appeared in the accessibility tree. This is functional/AX evidence, not a
latency sample. The proposed ≤100 ms ordinary-input p95, ≤250 ms
representative content-settled p95, ≤500 ms stress p95, and MainActor stall
gate remain **unmeasured**. No installation or release acceptance follows from
this table.

A separate twenty-sample optimized test with 1,000 and 5,000 synthetic saved
evaluations found first JSON decode costs of about 75 ms and 386 ms,
respectively. Subsequent reads through a store-owned, byte-validated decode
cache have p95 below 0.01 ms in this fixture. The cold decode has **not** become
cheap: detail metadata creation now defers it until the user requests evidence,
and that first decode runs off the main actor before evidence rows are published.
Cross-store edits, removals, and failed writes have focused regression tests.

The opt-in Release query suite passed on the same machine (20 samples per
large-query case): the 160,000-call Home dual-period aggregate had p95
181.30 ms; the 200,000-row quota query had p95 239.97 ms; and the
1,000,000-row quota pressure case had p95 2,291.47 ms. These are database
query durations, not UI input-response measurements. The million-row case is
a pressure fixture, not the ordinary 200,000-row quota gate.

Warm library navigation suppresses the full presentation query and transient
loading state, but still performs one database identity read to reject stale
cached results after a writer advances the store. It therefore must not yet be
described as a zero-SQLite navigation path; the latency cost and any safe
generation-based replacement remain to be measured in the native harness.

## Release-equivalent root-view interaction harness

The opt-in interaction harness builds the real `DirectorRootView` in Release
optimization mode with a dedicated `DIRECTOR_INTERACTION_PERFORMANCE` compile
condition. It injects a disposable, synthetic `interactionStress` database by
default and supports the smaller `representative` fixture through a strict
runner option. A separate `interactionRepresentative` fixture exercises a
medium folder scale without changing the original `representative` fixture:
it contains exactly 47 global Agents and 44 global Skills, and 19 project
Agents and 173 project Skills, three derived folders (Global, Self Training, and one
project), explicit companion declarations, unknown/zero evidence boundaries,
and two plugin-provided global Skills. Both fixtures use disposable data and
in-memory preferences.
It never opens the production container or reads source
roots, sessions, credentials, or the installed app's database. The build
script fails closed unless the bundle has both the dedicated diagnostic
`CFBundleIdentifier` and `DirectorInteractionPerformanceMode=true`; the
runtime also requires the private `CODEX_DIRECTOR_INTERACTION_PERFORMANCE_RUNTIME=1`
gate and refuses to fall back to normal bootstrap.

Build and run a smoke sample (raw JSON stays under `/tmp`):

```bash
./scripts/run-interaction-performance.sh --samples 1 --width 720 --height 480
./scripts/run-interaction-performance.sh --samples 20 --width 1280 --height 800
# Optional representative-size run using the same safety gates:
./scripts/run-interaction-performance.sh --fixture representative --samples 20 --width 1280 --height 800
# Medium folder-scale run (47/44 global, 19/173 project):
./scripts/run-interaction-performance.sh --fixture interactionRepresentative --samples 20 --width 1280 --height 800
```

For the release evidence pair, this convenience runner builds once and reuses
the same verified disposable Release bundle for both viewports (20 samples
each):

```bash
./scripts/run-interaction-performance-both-viewports.sh
# The two-viewport helper also accepts: --fixture representative or
# --fixture interactionRepresentative
```

For an explicit/manual pair, the build root is printed by the first command
and must be passed exactly to both runs; the runner rechecks its path-free
contract, dedicated bundle identity, and ad-hoc signature each time:

```bash
build_output="$(./scripts/build-interaction-performance-harness.sh)"
build_root="$(print -r -- "$build_output" | sed -n 's/^build_root=//p' | tail -1)"
./scripts/run-interaction-performance.sh --reuse-build "$build_root" \
  --samples 20 --width 720 --height 480
./scripts/run-interaction-performance.sh --reuse-build "$build_root" \
  --samples 20 --width 1280 --height 800
[[ "$build_root" == /tmp/codex-director-interaction-perf-build.* && -d "$build_root" && ! -L "$build_root" ]] \
  && /bin/rm -rf -- "$build_root"  # exact disposable build root, after both runs
```

Do not substitute an installed app or a normal production build for
`--reuse-build`; it is intentionally rejected unless the generated contract
stamp and dedicated identity checks pass.

Each sample records privacy-safe stage markers for sidebar navigation, folder
entry, all three folder tabs, thirty-day sort, detail selection, and Settings.
The report includes both aggregate SQLite query counters and an ordered
`stageEvents` array: every individual event keeps its own duration and query
delta, while `durationsMilliseconds` and `queryCountsByStage` remain convenient
sum views. In particular, `identity` is kept as a separate operation so the
known warm-library freshness read is visible; folder tab, sort, and member
actions are expected to remain query-free after the fixture is prepared. No
resource IDs, names, paths, prompts, account values, or file contents are
written to signposts or reports.

Reports use schema version 3 and include privacy-safe `runtimeEnvironment` and
`buildIdentity` fields: operating-system version, architecture, synthetic-data
flag, dedicated diagnostic bundle ID, Release configuration, compilation
condition, and ad-hoc signature type. Four library destinations have separate
stage names and diagnostic-only phase durations/counts for the identity read,
row projection, row-view construction, and layout settlement. They intentionally omit host names,
user names, absolute paths, and source-control identifiers. Validate a report
without opening it in the app with:

```bash
./scripts/validate-interaction-performance-report.sh \
  /tmp/codex-director-interaction-perf/<report>.json \
  --fixture interactionStress --samples 20 --width 1280 --height 800
```

The expected sample count and viewport are mandatory validation inputs. The
validator checks the first `first-entry` sample, subsequent `warm-repeat`
samples, and the complete ordered path through sidebar, four library hops,
folder entry, three tabs, thirty-day sort, optional detail/member actions, and
Settings. A dirty source tree is reported by the runner as
`evidence=exploratory release_gate=false`; its JSON and logs remain available,
but it must not be used as Release evidence. Validation failures retain those
artifacts and write only a privacy-safe validator log.
The validator establishes report structure and privacy only: it always prints
`release_gate=false`, including on a clean candidate, until numeric thresholds,
fixture scale, Instruments, and painted-state evidence are independently accepted.

The runner timeout is bounded and scales with the requested sample count and
viewport: a 20-sample 720-point run receives 285 seconds, while a 20-sample
1280-point run receives 325 seconds; all runs are capped at 600 seconds. This
allows cold startup and Release layout settlement without leaving an
unbounded diagnostic process.

These durations are app/model/layout-settlement markers. They do not claim
input-to-painted-pixel latency: AX automation time, screenshot time, and
display-server presentation are outside the marker chain and must be reported
separately. The harness also records a lightweight main-run-loop longest-turn
probe; it is a scheduling/blocking diagnostic, not a replacement for an
Instruments main-thread trace or painted-state observation.

For native attribution, this host offers `Time Profiler` and `Animation
Hitches`. **Do not use `xctrace --launch` with the temporary diagnostic app's
executable.** On this machine it resolved to the installed production app even
though the supplied path named the disposable harness. The resulting trace
was discarded and the extra process was stopped. A future profiling procedure
must first start the verified synthetic harness directly, prove the live PID's
executable is inside its UUID-scoped temporary bundle, and only then attach
Instruments to that exact PID. Stop if the process identity differs; never
profile an installed app as synthetic evidence. This attach procedure remains
unvalidated and is not a release gate until independently reviewed.

This machine does not provide an Instruments template named `Hangs`; the
`Animation Hitches` and `Time Profiler` traces are the documented replacement,
and neither substitutes for manual painted-state and VoiceOver verification.
Keep traces and aggregate reports outside Git. Twenty-sample results are
release evidence only when run from a clean candidate commit; a smoke run only
proves that the harness and its isolation gates work.

### 2026-09-24 exploratory interaction checkpoint

The dirty `codex/home-ranking-periods-1.4.0` tree was measured with one
ad-hoc-signed, Release-optimized synthetic build, 20 samples at each viewport.
The validated schema-v2 reports contain one first-entry and 19 warm-repeat
samples per viewport, the complete ordered stage events, and no source-index
request or folder-action SQLite query. Hardware was MacBookPro18,3, macOS
26.5.1, arm64, 2× display scale. The fixture had 1,000 eligible capabilities
and 4,000 declared relations. These are **app marker through forced layout
settlement**, not painted-frame or ordinary click-response times; raw reports
and the sampling trace remain outside Git. For the 19 warm samples, p95 equals
the observed maximum:

| Repeated event | 720×480 median / p95=max | 1280×800 median / p95=max |
| --- | ---: | ---: |
| Custom Agent library entry | 754.8 / 967.1 ms | 754.7 / 767.9 ms |
| Custom Skill library entry | 808.5 / 926.3 ms | 811.9 / 903.8 ms |
| Global folder entry | 433.8 / 474.2 ms | 432.9 / 437.4 ms |
| Global Agent tab | 516.1 / 520.9 ms | 516.0 / 520.0 ms |
| Global Skill tab | 490.2 / 497.6 ms | 489.5 / 497.5 ms |
| Global 30-day sort | 255.7 / 260.7 ms | 255.5 / 258.1 ms |
| Folder membership add | 43.2 / 57.7 ms | 43.0 / 44.5 ms |
| Longest main-run-loop turn per sample | 229.0 / 500.4 ms | 462.6 / 497.4 ms |

The existing 14-resource `representative` fixture was also run for 20 samples
at each viewport using one separate frozen synthetic Release build. Warm
Custom Agent / Custom Skill library-entry p95 was 159.2 / 136.5 ms at 720×480
and 158.5 / 133.6 ms at 1280×800. Global Agent / Skill tab p95 was 32.1 /
45.9 ms and 33.0 / 45.4 ms respectively; membership-add p95 stayed below
23 ms. The longest main-run-loop turn p95 was 106.7 / 118.5 ms. This small
fixture is **not** the planned roughly 47-Agent / 44-Skill representative
inventory and must not be presented as that gate.

The new `interactionRepresentative` fixture was then measured on the same
dirty branch, again with one synthetic Release build reused for 20 samples at
each viewport. Its report inventory verifies 47 global Agents / 44 global
Skills, 19 project Agents / 173 project Skills, three derived folders, explicit
relations, and unknown/zero boundaries. The validator passed both reports,
but only as exploratory evidence. Warm-repeat app-marker-through-layout
settlement measurements were:

| Repeated event | 720×480 median / p95=max | 1280×800 median / p95=max |
| --- | ---: | ---: |
| Custom Agent library entry | 555.7 / 573.0 ms | 556.6 / 570.9 ms |
| Custom Skill library entry | 731.3 / 739.5 ms | 729.1 / 736.6 ms |
| Global folder entry | 95.1 / 138.2 ms | 96.0 / 128.9 ms |
| Global Agent tab | 96.5 / 101.4 ms | 97.9 / 100.9 ms |
| Global Skill tab | 93.1 / 98.1 ms | 94.1 / 100.9 ms |
| Global 30-day sort | 35.8 / 44.4 ms | 35.4 / 57.3 ms |
| Folder membership add | 17.9 / 19.8 ms | 17.6 / 20.0 ms |
| Longest main-run-loop turn per sample | 176.0 / 182.0 ms | 175.0 / 488.0 ms |

Folder actions remained SQLite-free after preparation. The library hops still
read only database identity for freshness, but their layout-settlement p95 is
far above the proposed 250 ms representative target. The run-loop probe also
exceeds 100 ms, without enough native attribution to label it a data-loading
block. Neither report measures input-to-painted-pixel latency. This fixture
closes the data-scale evidence gap; it does **not** pass the interaction gate.

On the same uncommitted tree, `./scripts/verify.sh` passed its public audit,
contract suites, complete Swift tests and Debug build; the separate
`./scripts/audit-public-release.sh --all` and dual-architecture local Release
build also passed (`1.4.0 (27)`, arm64/x86_64, ad-hoc signature). Independent
quality review remains **blocked** on library latency, main-thread attribution,
painted-state/VoiceOver evidence and a clean candidate run. The successful
build was not installed or published.

The hot-process stack sample attributed substantial time to SwiftUI/AppKit
layout and native list-row construction, not a demonstrated source-index wait.
AppKit also emitted `NSTableView` reentrancy warnings under the harness's rapid
programmatic navigation; whether those occur in normal paced interaction is
unverified. These exploratory numbers do not satisfy the proposed stress or
main-thread gates. A clean candidate commit, representative-size native
samples, Instruments attribution, actual painted-state and VoiceOver checks,
and independent acceptance are still required. Do not install or publish this
performance work on the strength of these measurements.

### 2026-09-25 four-library warm-navigation checkpoint

The synthetic representative fixture and one frozen Release diagnostic bundle
were used for 1 first-entry plus 30 warm switches at each viewport. Stage
markers were split by destination and instrumented for identity-read duration,
row-projection builds, and row-view construction. Before changing production
behavior, warm-cache visits still republished two unchanged library properties
and the unchanged query status; the view also republished its language on
appearance. A regression test now rejects those redundant publications. The
production change suppresses only equal-value publications; it keeps the
bounded database identity read and all existing invalidation checks. The
localizer now resolves its bundle once per language change rather than on
every string lookup.

| Destination | 1280×800 before p50 / p95 | 1280×800 after p50 / p95 | 720×480 before p50 / p95 | 720×480 after p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| Custom Agent | 523 / 543 ms | 480 / 490 ms | 521 / 532 ms | 479 / 505 ms |
| Custom Skill | 685 / 694 ms | 577 / 582 ms | 684 / 694 ms | 577 / 587 ms |
| Installed Skill | 175 / 189 ms | 165 / 175 ms | 174 / 185 ms | 164 / 168 ms |
| Installed Plugins | 91 / 93 ms | 85 / 91 ms | 91 / 94 ms | 85 / 89 ms |

The custom Agent and Skill row-view construction counts fell from 264/852 to
132/426 per visit (two builds per row rather than four). Each warm visit still
made exactly one identity read, typically under 3 ms; row projection remained
cached. The remaining delay sits in SwiftUI/AppKit list construction and layout
settlement, with a longest observed run-loop turn of about 464 ms. These are
app-marker-to-layout timings, **not** first painted frames. The dirty-tree
reports are exploratory and live only in `/tmp`; neither the 250 ms target nor
native paint/VoiceOver acceptance is met. No installation or publication is
authorized by this checkpoint alone.

The complete `./scripts/verify.sh` and `./scripts/audit-public-release.sh --all`
passed after this change. A normal local Release build produced `1.4.0 (27)`
with arm64 and x86_64 slices and a valid ad-hoc signature. It was not installed:
the representative interaction target, true first-paint measurement, and
independent accessibility/performance acceptance remain open.

### 2026-09-26 isolated library-renderer experiment

Task 4's diagnostic-only prototype compares a view-based AppKit `NSTableView`
with a SwiftUI `List(selection:)` using the **same immutable synthetic rows**:
project headings, two-line capability text and usage labels. It does not read
the user's inventory or alter the four production destinations. A fresh
Release-optimized `swift test` process measured root replacement through
AppKit layout and display submission, with one first sample and 30 warm
samples per renderer at each viewport. Values are milliseconds:

| Synthetic capabilities | Viewport | List first / warm p50 / p95 | AppKit first / warm p50 / p95 |
| ---: | --- | ---: | ---: |
| 283 | 720×480 | 109 / 56 / 60 | 31 / 21 / 26 |
| 283 | 1280×800 | 81 / 80 / 100 | 33 / 29 / 31 |
| 1,000 | 720×480 | 114 / 125 / 142 | 29 / 26 / 29 |
| 1,000 | 1280×800 | 171 / 191 / 208 | 32 / 29 / 35 |

The AppKit candidate realizes fewer than 30 visible table rows for the
1,000-capability fixture, and focused tests verify nonselectable headings,
single-row selection, an action-bearing context menu, native table AX role,
row labels and scrolling to the end. Light/Dark synthetic captures were
visually inspected locally. These tests do **not** establish complete
production visual parity, keyboard/Shift behavior, actual VoiceOver reading,
Increase Contrast, Reduce Motion, side-Sheet behavior, memory/CPU, scroll
smoothness, or compositor first paint. The simplified AppKit row lacks the
production outline, badges, folder controls and filter/header composition;
the 283-row microbenchmark is not the full 66-Agent/217-Skill navigation path.
The smaller layout-submit timings therefore indicate a promising renderer
direction, **not** a passed 250 ms first-content gate or permission to migrate.

The proposed, inactive design-system amendment names the parity requirements.
The production `List(selection:)` remains unchanged. No app installation or
GitHub publication follows from this experiment; a full-page prototype,
actual native input-to-paint measurement and independent accessibility/design
approval are the next decision gates.

The opt-in comparison's four focused contract tests passed. The ordinary
`./scripts/verify.sh` completed with 898 Swift tests, three skipped and zero
failures; `./scripts/audit-public-release.sh --all` and `git diff --check`
also passed. These checks validate diagnostic isolation and source hygiene,
not the still-open production renderer or first-paint acceptance gates.

### 2026-09-26 complete-library diagnostic checkpoint

The next experiment reuses the **actual library header, summary cards, filter
ribbon, group outline and capability rows** inside a diagnostic-only AppKit
table. It is selected only in the isolated `DIRECTOR_INTERACTION_PERFORMANCE`
bundle with `CODEX_DIRECTOR_LIBRARY_RENDERER=appkit`; ordinary builds continue
to compile only the existing SwiftUI `List(selection:)`. The temporary bundle
reads a disposable synthetic fixture, never the installed app or user data.
The two modes were run sequentially on a MacBookPro18,3 (macOS 26.5.1, Xcode
26.6) from a dirty `024fae9` worktree. Each paired result uses one frozen
Release-optimized build, one first entry and 29 warm repeats. These numbers
are **sidebar marker to native layout settlement**, not click-to-first-paint.
Warm p50 / p95 are milliseconds:

| Fixture / actual viewport | Destination | SwiftUI List | Full-page AppKit prototype |
| --- | --- | ---: | ---: |
| 283 resources / 1280×800 | Custom Agent | 485 / 500 | 236 / 247 |
| 283 resources / 1280×800 | Custom Skill | 583 / 606 | 287 / 295 |
| 283 resources / 1280×800 | Installed Skill | 165 / 179 | 202 / 208 |
| 283 resources / 1280×800 | Installed Plugins | 86 / 91 | 135 / 141 |
| 283 resources / 720×480 | Custom Agent | 331 / 338 | 112 / 122 |
| 283 resources / 720×480 | Custom Skill | 405 / 412 | 135 / 138 |
| 283 resources / 720×480 | Installed Skill | 144 / 149 | 108 / 110 |
| 283 resources / 720×480 | Installed Plugins | 87 / 96 | 111 / 115 |
| 1,000 resources / 1280×800 | Custom Agent | 564 / 586 | 293 / 299 |
| 1,000 resources / 1280×800 | Custom Skill | 615 / 622 | 327 / 335 |

The first-entry values follow the same mixed pattern. For the representative
1280 viewport they were 592→315 ms (Custom Agent), 580→295 ms (Custom Skill),
163→203 ms (Installed Skill), and 90→140 ms (Installed Plugins). The stress
fixture's installed destinations have no comparable inventory, so its table
reports only the two populated custom libraries. Every one of the 116 warm
representative 1280 library visits still performed exactly one bounded
presentation-identity read; the renderer experiment does not change freshness
or indexing. No AppKit reentrancy warnings appeared in the three prototype
logs examined.

An initial 720 run was invalid: the diagnostic window stayed at its default
size because a view update could occur before window attachment. The harness
now sets content size on attachment and logs the actual size; only the rerun
whose log states `interaction_window_content_size=720x480` is in the table.
Composited synthetic screenshots show the representative 1280 page's
gutter, grouping and controls are close, **but not identical**. At 720×480
the prototype content starts roughly 7–8 pt farther right and lower than the
SwiftUI page, leaving the first group below the initial viewport when the
List shows its top edge. This visual mismatch is an explicit failed parity
check, not a minor screenshot artifact. A focused test confirms the full-page prototype keeps headings
unselectable, routes single-row selection and its folder-menu action.

This is **not a renderer acceptance**. The AppKit baseline is slower for the
small installed destinations, and the representative 1280 Custom Skill p95
still exceeds the proposed 250 ms *layout-settlement* threshold. The table
uses fixed row/header heights and has not passed long translated text, loading
and error states, keyboard/Shift behavior, actual VoiceOver reading order,
Increase Contrast, Reduce Motion, memory, scroll smoothness, side-Sheet focus,
or input-to-first-correct-paint measurement. The release gate stays open; no
four-page migration, installation, push or publication follows from this
experiment. A later selective renderer proposal needs a Product Designer/UI
Designer contract decision and independent quality review before production.
The six focused renderer tests, complete `./scripts/verify.sh`, public
`--all` audit, and `git diff --check` passed for this diagnostic checkpoint.

### 2026-09-26 selective-renderer follow-up

The next synthetic pass corrected the prototype table's implicit inset by
using AppKit's plain style and the full Director page gutter. The hosted hero
title had been compressed by its existing `minimumScaleFactor` despite both
renderers receiving the same 1052 pt content width at 1280; the diagnostic
path now holds that scale at 1. It also calibrates the fixed header and group
rows separately for 720 and 1280. Composited Dark/Chinese screenshots at both
sizes show much closer first-screen alignment, but they do not establish all
appearance, localization, long-text or accessibility parity.

On one subsequent frozen Release diagnostic build with 283 synthetic resources,
one first visit plus 29 warm visits per viewport, the warm **sidebar marker to
layout settlement** p95 values were:

| Viewport | Custom Agent List → AppKit | Custom Skill List → AppKit | Installed Skill List → AppKit | Installed Plugins List → AppKit |
| --- | ---: | ---: | ---: | ---: |
| 1280×800 | 478 → 227 ms | 576 → 277 ms | 167 → 196 ms | 89 → 129 ms |
| 720×480 | 321 → 125 ms | 402 → 142 ms | 146 → 116 ms | 85 → 119 ms |

The separate 1,000-resource, 1280×800 run gave Custom Agent 550 → 288 ms
and Custom Skill 604 → 317 ms p95 on the same marker. A single 1280 Custom
Skill-stage resident-memory observation was about 243 MB for List and 196 MB
for AppKit; this is a spot check, not a memory distribution or leak test. The
longest main-run-loop-turn p95 across whole warm samples was 445 → 232 ms at
1280 and 287 → 106 ms at 720, still above the proposed 100 ms input-feedback
gate and not a direct input-acknowledgement measurement. The
rapid synthetic stress run logged native-table reentrancy warnings in the
SwiftUI baseline and none in the diagnostic AppKit mode; normal paced user
interaction has not been attributed. The focused renderer suite now passes
seven tests, including actual up/down key events that skip nonselectable
headings and expose visible rows through the table accessibility API.

**Decision: continue the candidate only for Custom Agent and Custom Skill.**
The two installed destinations stay on the production List, and all four
destinations still use that List in ordinary builds. The 277 ms representative
Custom Skill marker is above the provisional 250 ms threshold even before
true painted-state measurement. Fixed-height localization and error states,
selection/side-Sheet focus, scrolling, VoiceOver speech order, Increase
Contrast, Reduce Motion, click-to-first-correct-frame, repeatable memory and
an independent design/quality ruling remain open. This follow-up does not
authorize a renderer migration, application installation or GitHub push.

### 2026-09-27 painted-frame, long-text and focus checkpoint

**Decision: blocked; diagnostic candidate only.** No production renderer was
changed, no application was installed and no GitHub operation was performed.
The existing dirty worktree, source capabilities and folder memberships were
preserved. This is a root-task verification checkpoint, not independent
acceptance of any newly written diagnostic tooling.

The frozen diagnostic binary was `codex-director-interaction-perf-build.dDL1ZK`
with executable SHA-256
`9a216a8819859bdb0394d57662caa914a9520d3bb2fa40280717f03c603a0a91`.
All launches used the dedicated InteractionPerformance bundle, its two runtime
gates, a new synthetic temporary database and in-memory preferences. The
representative directory contains 283 synthetic resources. No production
database, account process or capability source was used for this checkpoint.

The first ScreenCaptureKit collector retained images backed by the stream's
finite pixel-buffer pool, exhausting it after three frames. The review-only
collector now copies each image into separately owned pixels. Its timestamp
reader also accepts the bridged numeric attachment rather than assuming an
unsigned Swift cast. Earlier zero-frame / `-1` results are invalid measurements,
not fast or slow page entries.

Window-only, 60 Hz requested capture now produces post-input frames. Offline
OCR excludes the sidebar so its permanently visible destination name cannot
count as the new page's heading. The following are **individual observations**,
not a p95 distribution, not a controlled before/after comparison and not
proof that every element in the viewport has finished drawing:

| AppKit diagnostic, 1280×800, zh/Dark | Destination heading | Visible first resource name |
| --- | ---: | ---: |
| Custom Skill, normal text | 323 ms | not checked in this sample |
| Custom Agent, normal text | 312 ms | 312 ms |
| Custom Skill, long text | 444 ms | not checked in this sample |

Timestamp origin is native mouse-event dispatch, using the capture attachment's
display timestamp and Mach timebase. The capture helper adds image-copy and
recording overhead; that overhead has not been independently quantified.
Sidebar-color feedback detection was inconsistent and is not accepted as a
100 ms input-acknowledgement measurement. Complete-viewport readiness and the
required thirty warm samples per configuration remain open. The favorable
marker-to-layout numbers above must not be relabeled as painted-frame values.

Settled window-only screenshots additionally checked zh/Dark at 1280×800 and
en/Light at the compact requested 720×480 viewport, including a scrolled compact
ledger. Long synthetic names retain their full AX label/help while truncating
visually; long purposes occupy at most two lines. The inspected visible rows
did not overlap their metadata, separators or following rows. This limited
matrix does not establish all localization, appearance or accessibility modes.
Review artifacts are named `long-appkit-1280-settled.png` and
`long-appkit-720-en-light-scrolled.png` in the local `native-review` evidence
directory; they contain synthetic data only.

The focus comparison opened a resource by pointer in both the AppKit candidate
and the existing SwiftUI List. In both, the focused AX element initially stayed
in the underlying list; Tab then reached the sidebar rather than the detail.
Escape closed the detail and preserved the underlying directory. The machine's
keyboard-navigation preference was `AppleKeyboardUIMode=0`, so this observation
does **not** prove that all-controls Tab traversal fails. Automatic detail
focus, source-row return and full keyboard-navigation behavior remain unverified;
the observed behavior is shared, not established as a renderer regression.

A separate AX activation check on the compact AppKit Skill row exposed one
button labeled with the full resource name but identified as `folder.badge.plus`;
activating it opened the folder-membership menu. Clicking the resource title
opened detail. The primary detail action and membership action need distinct,
correct accessibility activation semantics before migration. The SwiftUI List
row activation opened detail in the baseline comparison. This AX finding is
not a substitute for actual VoiceOver activation evidence.

VoiceOver was temporarily enabled against the synthetic window. Its scripting
interface did not return `content of last phrase` (error `-1728` after startup),
and no caption output was available. Actual spoken reading order and activation
therefore remain **unverified**, not passed from AX inspection. No scripting
authorization or caption preference was changed. The system VoiceOver toggle
was visibly restored to Off, and read-only checks confirmed both
`voiceOverOnOffKey=0` and the original `AppleKeyboardUIMode=0` afterward. All
diagnostic application instances were closed.

Next gate: resolve the candidate's accessibility action distinction, specify
and verify detail focus with full keyboard navigation, then obtain actual
VoiceOver output and controlled repeated input-to-complete-content samples.
Keep ordinary builds on the native List until those gates and independent
acceptance pass.

Supporting checks: `DIRECTOR_INTERACTION_PERFORMANCE=1 swift test --filter
LibraryRendererComparisonTests` executed seven XCTest methods with zero
failures. The two opt-in measurement/snapshot methods returned without enabling
their optional workloads; the five functional methods exercised synthetic row
identity, virtualization, selection, heading exclusion, folder routing and
arrow navigation. They do not validate VoiceOver speech, detail focus or
compositor latency.

### 2026-09-28 shared SwiftUI List slimming checkpoint

**Decision: limited candidate benefit; not approved for installation.** Ordinary
builds still use the native SwiftUI List. The experimental AppKit renderer was
not enabled. This checkpoint changes only shared library rendering: group-row
IDs and outline boundaries are materialized with the existing cached group
projection, and localized row strings are lazily cached in memory rather than
formatted on every body evaluation. No row views are retained or eagerly
formatted offscreen. Directory changes clear the text cache; full row values,
language, time zone, the selected 7/30-day period and readiness state invalidate
an individual entry. Unknown counts remain distinct from explicit zero.
Source capabilities, folder memberships, index/SQLite behavior, refresh
scheduling, version and installed application were not changed.

The frozen baseline is `codex-director-interaction-perf-build.dDL1ZK`, described
above. The candidate is `codex-director-interaction-perf-build.zjKFrR`, executable
SHA-256 `e3ccd069163e4aedb7f5df75b791af59bf0572159da9d31695faf62254687771`.
Both are isolated, Release-optimized, ad-hoc-signed diagnostic bundles with
in-memory preferences and synthetic databases. The source base is `b10c323`
plus the existing dirty working tree and this rendering slice; neither binary
is a clean release candidate. Hardware is `MacBookPro18,3`, arm64, macOS 26.5.1
(25F80), Xcode 26.6 (17F113). Display scale was not recorded. This is root-task
implementation verification, not independent quality acceptance.

Six sequential runs used the same 283-resource fixture (66 Agents, 217 Skills),
one first entry and 30 warm visits per destination. No build or test workload
ran concurrently with these six samples; ordinary user/background processes
were not stopped or controlled. The wide comparison was repeated in reversed
order (baseline → candidate → candidate → baseline). The earlier
`round2-before-1280` pilot overlapped compilation and is excluded. Accepted
exploratory reports are `round2-{before,after}-idle-1280`,
`round2-{before,after}-repeat-1280` and `round2-{before,after}-idle-720` under the
local interaction-performance evidence directory.

**App-marker to layout settlement, milliseconds, not input-to-painted-content:**

| Destination | 1280×800 p50 before → after | 1280×800 p95 before → after | Reversed-order wide p95 before → after | 720×480 p50 before → after | 720×480 p95 before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Custom Agent | 436 → 435 | 471 → 486 | 470 → 481 | 298 → 288 | 316 → 302 |
| Custom Skill | 535 → 506 | 572 → 524 | 583 → 538 | 372 → 334 | 387 → 352 |
| Installed Skill | 161 → 159 | 166 → 170 | 175 → 169 | 137 → 133 | 146 → 142 |
| Installed Plugins | 80 → 81 | 85 → 86 | 89 → 91 | 81 → 82 | 86 → 92 |

Wide first-entry times were 555/549/161/91 ms before and 530/522/166/83 ms
after, in the table's destination order. Compact first entry was
386/392/130/75 ms before and 389/372/130/84 ms after. Wide warm maxima were
489/577/168/88 ms before and 495/541/172/88 ms after; the reversed run maxima
were 478/652/178/95 ms before and 486/539/172/91 ms after. Compact maxima were
325/390/147/89 ms before and 302/353/144/109 ms after. First entry is one
observation per run, not a distribution.

The Skill improvement is repeatable but modest (about 8–9% in layout p95).
Agent wide medians are essentially unchanged, with slightly worse p95; the
plugin tail is also higher. Those differences are not established as either
noise or a regression. The retain-without-worsening gate therefore remains
open; this slice stays an uninstalled candidate, not a declared four-page fix.
Warm visits still perform one bounded identity read, no full library query,
no source indexing and no account request. They still build 132 Agent row
bodies (occasionally 198) and 426 Skill row bodies; caching text does not
remove native List construction/layout. In the first baseline wide run, median
identity reads were 0.27/0.70/0.52/0.33 ms, while initial layout dominated.
The repeated candidate's longest whole-sample main-run-loop turn reached
443 ms; this is not proof of a data-loading block or a painted-frame value.
Rapid harness runs continue to emit native-table reentrancy warnings; no
attribution to normally paced user interaction is claimed.

Checks: the corrected full Swift suite executed 907 tests with 3 skipped and
zero failures, including seven new row-rendering/cache tests. The first full
run's one failure was a new fixture that incorrectly equated category-level
30-day readiness with browse-level readiness; it now tests both independently.
All 46 performance-script checks and the public audit (`--all`) passed. The
candidate diagnostic Release build and signature/runtime-gate checks passed.
`./scripts/verify.sh` also passed its audit fixtures, version/release/performance
contracts, public source/license/dependency/media checks, the full Swift suite
and the SwiftPM debug build. No ordinary dual-architecture release acceptance
or installed-bundle validation is claimed for this candidate.
True first-frame, memory, full accessibility/focus and independent acceptance
gates remain open; the prior AppKit accessibility findings are not fixed here.

Next: isolate expensive row-view/modifier construction on the existing List
before another renderer decision. Any further simplification must preserve the
outline grammar, localized text, selection and folder/detail actions, and be
measured separately. Do not ship a layout-only speed claim as input latency.

#### Subsequent user-authorized local installation

After the checkpoint above, the user explicitly requested replacement of the
installed App. A fresh ordinary Release build (1.4.0, build 27) passed the
project bundle verifier: production bundle identity, macOS 26 minimum,
arm64/x86_64, hardened-runtime ad-hoc signature, dependency notice and packaged
privacy/content checks. No interaction-performance compile condition or runtime
mode was enabled. The previous App was moved recoverably to Trash, the new
bundle was installed and relaunched, and a full bundle comparison plus executable
SHA-256 verified installation identity:
`a0a81dfb50d687fb0cf1b9f0913b4127df06207777f2332b63fe596b6e5b77a4`.

Startup, the existing custom folder membership and content presentation in all
four capability destinations were checked without taking screenshots of real
capability data. No preference reset, source-data cleanup or GitHub operation
was performed. This is a user-requested local trial, **not** performance or
independent release acceptance; the timing and accessibility gates above remain
open. Native UI automation duration is not reported as navigation latency.
