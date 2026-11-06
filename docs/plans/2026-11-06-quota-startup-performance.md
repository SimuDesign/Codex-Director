# Quota History and Cached Startup Performance Plan

**Goal** Reduce the wait when opening Quota History and isolate the stages that contribute to slow cached launches.

**Approach** Compare Release synthetic runs on this Mac. Keep the existing window-local history session, bounded query, cache identity checks and quota display.

1. Capture cached launch markers from process birth through app initialization, root appearance, cached presentation and startup readiness. Retain diagnostics from failed timing runs. Compare individual samples and keep cache-hit and zero aggregate-query checks.
2. Reduce redundant work on the main thread when entering Quota History. Reuse one Home projection per route update in `Sources/DirectorUI/AppShell/DirectorRootView.swift` and observe the controller once in `Sources/DirectorUI/Home/QuotaHistoryView.swift`. Preserve the chart, daily records, scroll restoration, period selection and accessibility labels.
3. Use the launch stage timings to decide whether to change production startup or the test harness. Check that a slow services factory cannot delay cached content, and exercise cache identity, recovery and refresh coordination.
4. Run quota history, startup and refresh regression tests. Rebuild the Release interaction harness and compare 20 rounds at 720 × 480 and 1280 × 800 with the 1.7.2 baseline. Compare first feedback, correct content and all three period changes. Run a cached launch smoke test against the existing 700 ms gate. Treat physical input, frame pacing and the clean-tree release gate as separate measurements.

The 10-sample startup baseline had a 675 ms median and a 2,452 ms maximum. The slowest launch spent 1,302 ms before the app-init marker. After the root appeared, the median interval to cached presentation was about 213 ms. The startup change therefore mounts the existing Home header while there is no presentation, then mounts the full dashboard when cache, indexed data or the terminal startup state is available. It does not alter process launch, cache or database validation.

## Verification

- The serial Release comparison captured all 80 paint samples per build and viewport. At 720 × 480, entry feedback p95 improved from 94.8 to 84.7 ms and correct content from 104.4 to 101.2 ms. At 1280 × 800, feedback moved from 101.5 to 106.9 ms and correct content from 110.2 to 112.5 ms. Period changes had a p95 of 28.4–43.7 ms after the change.
- The first startup retries included a watchdog timeout with the process idle in AppKit and no window or cache marker recorded. The successful diagnostic rerun used launch-only arguments that ignored saved window state. It recorded 10 of 10 cache hits, zero startup aggregation queries, a 465 ms median and a 516 ms maximum to cached presentation. The baseline used the default window launch arguments, so this is a smoke comparison rather than a clean-tree release benchmark.
- The Release 1-million-row query fixture passed with a p95 of 267 ms on new read-only connections and 264 ms on a reused connection. The operating system page cache was left in place.
- The full project verifier ran 1,376 tests with four configured skips and zero failures. The universal Release bundle passed signature and metadata verification. In the synthetic Release UI, both history entry points, 60-day selection and retention, scrolling, and opening and closing the data details were verified.
