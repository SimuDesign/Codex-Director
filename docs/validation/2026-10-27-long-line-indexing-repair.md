# Long-line Indexing Repair Validation — 2026-10-27

Status: build 40 installed after independent source/artifact acceptance;
live replay is still being checked. No runtime-completion claim yet.

## Preflight

The existing public checkout and dirty working tree were retained. Build 39
remained installed. Read-only comparisons showed new parser checkpoints and
registry relations since the earlier directory-open wait; the last successful
full-source timestamp and relationship marker had not yet advanced.

A new short process-stack sample matched to the build-39 dSYM shows the active
worker dominated by `JSONLIncrementalReader.takeLineFromPending` and generic
`firstIndex`. Source inspection confirms that each chunk re-searches all bytes
of the unfinished line. The main thread is not the parsing worker. This
evidence supports a reader-algorithm repair, not a claimed explanation for the
earlier system directory-open wait.

Only synthetic fixtures, aggregate comparisons and function-stack diagnostics
are used. No raw session bodies, commands, outputs, account/thread IDs or
private source paths are added to the repository. Existing user state is not
cleared, migrated or manually corrected.

## Required gates

- Deterministic long-line search-work RED/GREEN and exact-byte/offset checks.
- Bounded windows, compaction, resume, malformed UTF-8 and cancellation.
- Full verification, public privacy audit, universal Release and matching
  source/artifact hashes.
- Independent Quality Engineer source/artifact decision before installation.
- Recoverable deployment, preservation checks and actual live refresh status.

Passing synthetic/build gates must not be described as completed live replay.

## Source and synthetic evidence

- Genuine behavioral RED: 8 reader tests, 7 passed and 1 failed. A synthetic
  512 KiB record caused 135,004,168 inspected bytes where 524,296 were expected.
  Earlier sandbox/cache attempts are not counted as behavioral reproduction.
- Reader GREEN: 10/0; neighboring parsing tests: 96/0; indexing tests: 53/0.
- Root independently compiled the production reader into a synthetic oracle:
  125 cases passed, covering small/large chunks, consecutive empty lines,
  valid/invalid UTF-8, long lines, no final newline, compaction, resume,
  bounded endpoints, exact offsets/line numbers and linear inspected bytes.
- Optimized 8 MiB old/new diagnostic runs retained identical checksums and
  final byte offsets. Author timing was 1,739.100 ms versus 19.389 ms; root
  repeated the pair at 1,822.299 ms versus 14.520 ms. These are diagnostic
  comparisons, not a controlled whole-app performance guarantee or CI limit.
- Source documents the remaining line-proportional memory requirement. The
  change does not claim to solve a previously sampled large memory footprint,
  JSON decoding costs or arbitrary filesystem blocking.

## Integrated gates and deployment

- Full `verify.sh`: **1,270 total tests including 3 existing opt-in skips,
  zero failures**, followed by successful Swift build.
- Untracked-inclusive public audit using a disposable Git index: passed.
  Whitespace checks passed; real staging remained unchanged.
- Frozen source hashes matched. Universal Release: **1.6.0 (40)**, macOS 26+,
  arm64 and x86_64, ad-hoc signature. No Developer ID or notarization claim.
- Independent Quality Engineer approved source/artifact installation gates;
  it did not pre-approve live runtime completion.
- Executable SHA-256:
  `543f180452d888b0707c8ff85d07940faa57700484437afc4d49d053c690978c`.
- The app was normally quit, the previous bundle preserved recoverably in
  Trash, and the staged/installed bundle matched the verified artifact.
  Strict/deep signature verification passed. Before relaunch, folder and
  classification preferences, history, database and existing WAL hashes were
  unchanged; the evaluation preference remained absent.

## Initial installed observation

Native Settings shows parser 1.4.2 and marketing version 1.6.0. All 32
currently unambiguous project-local v5 declared pairs examined by a separate
read-only probe are represented in persisted relationships. Full source-refresh
timestamps and the relationship migration marker are still awaiting completion
of the existing recent replay. No source file, configured root or permission
was changed, and no manual database correction or reset was used.

## Build 40 live blocker and build 41 follow-up

The first installed snapshot must not be interpreted as proof that build 40
advanced checkpoints: those rows may have committed before build 39 exited.
A new matched-dSYM sample shows another interval waiting in the source-root
directory probe's Foundation enumeration/open call, before session replay.
Thus the long-line source/artifact repair passed, but live full-refresh
acceptance remains blocked independently of it.

Build 41 will replace only directory enumeration with descriptor-backed POSIX
operations and add low-volume root begin/probe-end/end diagnostics containing
only fixed phases/kinds and 1-based ordinal/total. It must preserve errors,
symlink boundaries, filenames, descriptor cleanup and file timestamp behavior.
No permission workaround or arbitrary filesystem timeout claim is permitted.
Fresh full verification, Release, public audit and independent review are
required before any replacement of build 40.

## Build 41 focused evidence

- Directory/logging contract RED: 8 selected tests with 2 failing cases
  (9 assertions). Separate behavioral regressions reproduced a directory base
  URL without a directory hint resolving a child at the wrong level and a
  non-file URL being incorrectly interpreted as a local path. Both were fixed
  before freezing the candidate.
- Focused directory/logging GREEN: 10/0. Scanner/history neighbors: 107/0.
- Root independently compiled the final frozen filesystem implementation:
  37 synthetic checks passed for directory-hint/trailing-slash combinations,
  hidden/Unicode/reserved-character names, child-parent fidelity, symlink
  read/status distinctions and typed non-file/missing/regular-file failures.
- Descriptor and pathname identity are verified across enumeration; races
  return incomplete coverage rather than an empty success. File size/mtime
  calculation and parser 1.4.2 remain unchanged.
- Full verification, Release and independent artifact acceptance are pending
  for this candidate; build 40's results do not prove build 41.

## First build-41 candidate: full run blocked, not installed

Directory-focused source review, public audit, frozen-source comparison and
universal Release passed, but the full verification run did not complete.
A read-only XCTest sample shows its remaining runtime-command queue waiting
in Foundation `Process.waitUntilExit`; the owned test process had no direct
child when checked. The buffered log cannot prove the exact active test.
This is not attributed to the directory repair and is not a passing run.

After confirming the exact executable and parent identity, root terminated
only this owned stalled XCTest. The original full log and stack sample remain
available locally. No production process, permission or data was changed.
The build-41 candidate was not installed. A bounded runtime exit-notification
repair and fresh full/build/audit/independent gates are required before install.

## Build 41 candidate 2: integrated source/artifact acceptance

The runtime client now registers termination notification before launch and
joins confirmed exit with stdout/stderr completion. It has no separate
`waitUntilExit` queue. Lifecycle locking arbitrates normal exit, watchdog,
output cap and launch failure without calling Process methods under that lock.
Stderr content remains discarded. Termination is cooperative; no new global
SIGCHLD/waitpid handling, process-group kill or hard-kill guarantee was added.

- Final focused runtime tests: 9/0; ten stress repetitions: 90/0; adjacent
  runtime/plugin/locator tests: 37/0. The old-source standalone stress attempt
  passed and did not reproduce the hang; it is not an assertion RED claim.
  The genuine RED evidence remains the stalled first-full-run stack.
- Root independently compiled the production runtime client: 12 synthetic
  early-pipe-close cases retained the confirmed exit code and waited until
  child termination. Quality Engineer also checked early-pipe-close timeout
  behavior separately.
- Fresh full verification: **1,280 total tests including 3 existing opt-in
  skips, zero failures**, followed by successful Swift build. The first
  candidate's stopped verification is not counted as a passing run.
- Untracked-inclusive public audit, whitespace/staging checks, frozen-source
  hash verification and universal Release passed. Independent Quality
  Engineer approved candidate 2 for recoverable installation.
- Final candidate executable SHA-256:
  `1e51fe855a0e7c4eedbbcb48c76636fe0000a41a6f0c7af34b32009b92242c69`.
  This supersedes the uninstalled first build-41 candidate's artifact.

Installation and live refresh/backfill outcomes are recorded separately below;
these source/artifact results do not establish a completed source refresh.

## Build 41 installed runtime outcome

Candidate 2 was recoverably installed after independent acceptance; the
installed executable hash matched the final candidate above, both architectures
and strict/deep signature verification passed, and the prelaunch preservation
hashes matched. The previous bundle remains recoverable in Trash.

The directory wait eventually returned and the normal source pass completed.
Read-only comparisons show parser 1.4.2 checkpoints advancing from 14 to 302,
both successful source/index metadata timestamps advancing, and the relationship
marker becoming `capability-companions.v3`. All 32 currently unambiguous v5
local pairs examined remain represented. This establishes a real completed
pass, not a claim that unchanged deferred old archives or unavailable sources
were all reparsed.

The independent directory open's delay exceeded sixteen minutes. This remaining
reliability problem motivates the bounded project-source repair in
`2026-10-27-project-source-read-isolation.md`; no specific system permission or
provider cause is asserted. Build 42's separate validation record must prove
that future unavailable projects cannot block available-source refresh.
