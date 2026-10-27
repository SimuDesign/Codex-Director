# Codex update compatibility repair — 1.6.0 (39)

Status: **in progress; not a passing quality, backfill or installation claim**.

Scope and ownership are defined in the
[implementation plan](../plans/2026-10-26-codex-update-compatibility-repair.md).
Preserve existing uncommitted 1.6 work; do not publish or edit user capability,
session or configuration files. No OS accessibility setting changes are part
of this backend-only compatibility repair.

## Diagnosis boundary

Read-only checks against the installed Codex runtime established that current
account allowance and installed-plugin responses remain readable through the
existing Director readers. Inventory IDs matched an independent read-only scan
of the approved roots. Indexed quota snapshots matched the already-checkpointed
source segment; newer source-tail observations are not evidence of parsing loss.

Two bounded defects were accepted for repair: structured `item_completed`
failure states were ignored, and supported v5 package registries were rejected
by the legacy entries-only scanner while explicit native Agent identifiers
were not consumed by companion resolution. This does not establish that all
capability call totals are wrong. Role-less child activities remain unknown
unless supported identity evidence exists; this repair does not guess roles.

Only synthetic fixtures and aggregate-only live comparisons may be included
in evidence. No real commands, outputs, prompts, paths, source documents,
thread/account identifiers or production database copies enter the repository.

## Delivery gates

- Independent software-engineering owners implement disjoint parsing/indexing
  and registry/grouping targets. Root owns integration, version/docs and deploy.
- Separate RED/GREEN focused logs; append, duplicate, conflict, unsupported
  schema, source-race, cancellation and deferred-old-archive coverage.
- Full Swift/script verification; untracked-inclusive public audit through a
  disposable index; whitespace and runtime-artifact checks.
- Universal Release, license/signature/identity/version/hash verification.
- Independent read-only Quality Engineer acceptance before recoverable install.
- Source-only comparison after repair, followed by truthful installed refresh
  and bounded recent backfill status. No clearing or manual SQL corrections.

## Evidence

- Version-contract fixtures: 11 passed. Audit-script fixtures: 15 passed.
  Release-contract fixtures: 18 passed. Performance-script fixtures: 46 passed.
  These are script contracts, not a new controlled performance measurement.
- Independent old-module blackbox RED reproduced the actual state error:
  parser 1.4.1 produced one completed call where the synthetic structured
  completion declared failure. Root independently reran the identical public
  API probe against the new module: parser 1.4.2 produced one failed call,
  retaining the count of one despite a later generic output. Logs:
  `/tmp/codex-director-item-completion/ROOT-RED-blackbox.log` and
  `/tmp/codex-director-item-completion/root-independent-green-blackbox.log`.
  The author's earlier RED log contains compilation/sandbox attempts and is
  not presented as passing behavioral reproduction.
- Registry author's first focused pass was 71/0. Integration review then
  required explicit schema-version handling, conflicting package-ID rejection,
  retained legacy resource identity and legacy declaration support. The second
  isolated Discovery/Grouping harness passed 75/0; it is not the complete
  application package. Further independent review added canonical legacy-name
  resolution, explicit unknown-kind rejection, declared package aliases and
  primary-registry failure precedence before final integration.
- An initial reviewer preflight selected a different checkout and was
  discarded; it performed no writes and supplies no acceptance evidence.
  Subsequent review explicitly confirmed the public checkout/branch. Review
  remains independent and read-only. Registry remediation after two rounds uses
  `gpt-5.6-sol / xhigh` following the Software Engineer Brief; it is not claimed
  to be the fixed native Software Engineer preset.

## Integrated candidate review (not accepted for installation)

The first verification attempt was invalidated by a final alias-normalization
edit during compilation; Swift rejected the changed test input. The concurrent
Release was cancelled (exit 130). Neither is passing evidence. The next frozen
candidate completed full verification with **1,258 total tests including 3
existing opt-in skips, zero failures**, public audit and universal Release.
An aggregate-only live comparison recovered all unambiguous local declared
pairs without changing the resource-ID set or manufacturing new capabilities.

Despite those passing runs, the independent reviewer correctly blocked that
candidate on concrete synthetic counterexamples:

1. Same-size source replacement could advance a checkpoint without replacing
   stale calls.
2. A terminal-only append could regress existing session metadata/status.
3. An alias exactly at the 16 MiB window's complete-line boundary was skipped.
4. Contradictory registry kind/identity/reference fields could be silently
   selected by a nil-coalescing expression.

The candidate was **not installed**. Both software-engineering owners are
responsible for remediation of their disjoint targets, preserving true
incremental appends and existing user data. The following acceptance runs
supersede that candidate's evidence. Independent focused review results did
not overrule the identified failures. Historical validation records for builds
36 and 37 remain unchanged and do not prove this new source snapshot.

## Build 38 acceptance and runtime follow-up

After remediation, full verification passed **1,263 total tests including 3
existing skips, zero failures**. Public audit, universal build, matching frozen
source hashes and independent original-counterexample verification passed.
Quality Engineer approved local installation. Build 38 was recoverably installed;
its executable SHA-256 was
`eb0b209fbd9225f3528b255fa534dcc36474de0f2e3a88641817d3449685406b`.
Before relaunch, hashes of folder/classification preferences, independent
history, derived database and its existing WAL matched exactly; the evaluation
preference was absent before and after. No source or configuration was changed.

Native runtime showed parser 1.4.2 and retained cached content but no new
inventory/checkpoint commit. A short read-only stack sample and matched dSYM
identified a synchronous wait in directory type checking:
`ResourceScanner.scan → productionDirectoryRead → attributesOfItem → getxattr`.
This is not evidence that historical replay had started, nor proof of a
particular root or File Provider cause. No permission prompt or system setting
was accepted or changed. The source/artifact acceptance did not establish a
completed live backfill; an additional narrow basic-directory-metadata repair
is required for build 39, with fresh full/build/audit/independent gates.

## Build 39 acceptance and remaining live blocker

The narrow directory-type repair now uses POSIX `lstat/st_mode`, retaining
the two methods' respective symlink behavior and typed error classification.
File size/mtime fingerprint calculation is unchanged. Focused directory tests
passed 4/0 and scanner regressions 53/0. Independent rechecks also passed the
three indexing counterexamples, 26 adjacent indexing tests and 43 registry
tests.

Full `verify.sh` passed **1,267 total tests including 3 existing opt-in skips,
zero failures**. Script contracts, the untracked-inclusive public audit,
frozen-source hash checks and universal Release passed. Quality Engineer
approved the source/artifact installation gate. Release is **1.6.0 (39)**,
macOS 26+, arm64 and x86_64, ad-hoc signed; it is not Developer ID signed or
notarized. Executable SHA-256:
`73ce43ac5419c7b27d590db09a05a0440513d1268dfe63dcd1827a3bb680bbe4`.

Build 39 was recoverably installed after normal application quit. The previous
bundle was retained in Trash. Installed artifact comparison and strict/deep
signature verification passed. Before relaunch, folder/classification
preferences, history, database and existing WAL hashes matched their
pre-install values; the evaluation preference remained absent. No production
source, configuration, permission or index-reset operation was performed.

**Runtime acceptance is not complete.** The application retains cached content
and remains responsive, but source discovery still waits before its inventory
commit. A fresh stack sample proves the directory-type `getxattr` wait was
removed; the remaining wait is inside Foundation directory enumeration's
`open` call. Read-only checkpoint/projection metadata confirms no new parser
1.4.2 checkpoint or relationship-v3 commit. This is not a completed backfill.
The sample does not identify the blocked directory or establish a filesystem,
provider or permission cause. No permission dialog was accepted, no configured
project was removed and no data was cleared to bypass this condition.

Final runtime diagnosis or bounded source-I/O isolation must be addressed
separately from the accepted protocol/registry fixes. An elapsed timeout alone
cannot safely cancel an arbitrary synchronous filesystem call, and skipping
an unavailable root must never turn its retained capabilities into deletions.
No Git publication, Tag or Release was performed.
