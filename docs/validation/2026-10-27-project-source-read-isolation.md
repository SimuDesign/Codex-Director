# Project Source Read Isolation Validation — 2026-10-27

Status: final build 42 source/artifact accepted and recoverably installed;
live normal/manual refresh completed with project-source degradation retained.

## Observed fault

Build 41 candidate 2 passed full verification (1,280 total tests, 3 existing
skips, zero failures), independent source/artifact acceptance and recoverable
installation. Installed bundle/signature/architecture/hash checks passed;
folder/classification preferences, history, database and existing WAL hashes
were unchanged before relaunch. Evaluation preference remained absent.

Fixed-field source diagnostics then localized the next real wait to a
configured historical project after earlier roots completed. Matched-dSYM
sampling shows the kernel directory-open operation still waiting even with
nonblocking flags. A separate read-only CLI open of the same source also took
over sixteen minutes to return. Metadata was readable, but evidence does not
establish a permission, cloud-placeholder or provider cause. The configured
source is not removed and no permission is changed to bypass it.

The long-line and process-exit fixes are retained. A bounded project-read
boundary is required so unavailable project storage cannot prevent available
source/session/quota refresh. Architecture is approved in the matching
2026-10-27 project-source isolation plan; Software Engineer implements and
Quality Engineer independently verifies it.

## Required evidence

- Actual-worker bounds across passes; per-root single flight; no queue growth.
- Timeout/busy/cancel qualification, retained cache/history, complete empty
  semantics, late-result discard and true slot recovery.
- Project discovery, physical mapping and companion parsing inside the same
  persistent gate; globals/session/runtime progress outside those slots.
- No source/config writes, new permissions, schema/manifest/parser changes,
  path/content logs or Git publication.
- Focused and full verification, privacy audit, universal Release, independent
  acceptance, recoverable install and actual refreshed runtime metadata.

Synthetic/build evidence alone cannot establish live completion. The gate
does not terminate an arbitrary kernel read or guarantee deadlines for all
filesystem operations.

## Focused implementation evidence

- Gate: 8/0; scanner: 57/0; indexing: 58/0; companion/history neighbors: 55/0.
- Timeout/cancelled workers retain their actual slot and lexical-path admission
  until completion. Busy calls do not enqueue another job. Absolute admission
  deadlines are also checked by worker completion, not only timer scheduling.
- Legacy synchronous scanner remains compatible; the production coordinator
  uses the asynchronous isolated route and the same gate across phases/passes.
- Physical identity is not guessed for incomplete project/global namespaces.
  A separately validated closed plugin-package namespace retains proved alias
  merging; positive and adversarial package cases passed. Missing projects
  cannot manufacture global uniqueness or duplicate proved same-package aliases.

## Independent blocker and remediation

The first build-42 candidate passed 1,297 total tests including 3 existing skips
with zero failures, but independent Quality Engineer identified a real missing
regression: filtering an unavailable project out of MissingSourceRule followed
by replacing findings erased an applicable old missing-source finding.
That candidate was not installed and its passing suite did not override the
finding.

A compiled behavioral RED reproduced the disappearance: **1 test, 1 failure**.
The corrected case passed 1/0 and also verifies that a later complete empty
inventory legitimately deletes the endpoint and its finding. Only prior
`rule.missing-source` findings with a still-present resource endpoint in an
unavailable project are retained. Other rules use their established replacement
semantics; manual evaluations/decisions and schema remain unchanged. The final
indexing suite passed 58/0 and neighboring IntegrityRules 12/0.

## Final release gates and installation

- Fresh full `verify.sh`: **1,297 total tests including 3 existing opt-in skips,
  zero failures**, followed by successful Swift build.
- Public untracked-inclusive audit, source hash verification, whitespace and
  real-staging checks passed. No Git publication or Tag/Release action.
- Independent Quality Engineer approved the final source/artifact gate.
- Release: **1.6.0 (42)**, macOS 26+, universal arm64/x86_64, ad-hoc signature;
  no Developer ID/notarization claim.
- Executable SHA-256:
  `cefcecdaeb94f397e64e768f8ff2e4b2b865db7241a41560bbdca0480c27ada4`.
- The prior App was normally quit and retained in uniquely named Trash. Staged
  and installed bundle comparison and strict/deep signatures matched. Before
  relaunch, folder/classification preferences, history, database and WAL hashes
  were unchanged; the evaluation preference remained absent.

## Installed runtime observation

The installed App completed an explicit manual refresh and restored the idle,
clickable refresh button. Read-only metadata advanced both successful source
and index timestamps while retaining relationship marker v3; recent parser
checkpoints also advanced. A separately checked current account reading matched
the displayed weekly allowance, and plugin inventory became available again.
All 32 currently unambiguous local v5 pairs checked remain represented. Native
plugin Skill counts and verified parent-to-Skill links did not double.

**Project storage is still degraded.** In this observed pass the two outstanding
project slots caused project scopes to be unavailable/busy; all project rows
were qualified unavailable and their existing inventory/relations were retained.
This is not evidence that their latest source contents were freshly verified.
Global, runtime, session and quota work completed instead of waiting for those
reads. The gate bounds worker count and caller waiting, not the kernel's I/O
duration. It does not establish the system cause, repair that storage, or reparse
unchanged deliberately deferred old archives. No permission, source config or
project selection was altered.

The second manual pass also completed and advanced source/index metadata and
recent checkpoints again. Short read-only samples after both passes show
exactly two project-read workers waiting in kernel `open`, an idle main loop
and no old runtime-wait queue; repeated refresh did not accumulate more blocked
workers. Independent Quality Engineer's final decision is **passed with the
documented project-storage degradation**. This is acceptance of bounded,
truthful fallback and available-domain refresh, not acceptance that all project
source files are currently readable or up to date. Accessibility system
settings were not changed; no new visual/VoiceOver matrix is claimed.

## Later same-day recovery observation

The earlier degraded observation above remains an accurate record of those
passes. A later read-only check of the same installed build 42 found that the
outstanding project workers had returned and a subsequent normal pass had
successfully read **42 of 45 configured projects**. The remaining three roots
returned `not found` from metadata inspection and had no cached capability
resources; they were not treated as successful empty directories or removed
from user configuration.

An additional explicit manual refresh completed and restored the idle refresh
button at local 11:00 on 2026-10-27. Both successful source/index timestamps
advanced to `1793070008.62392`; all 42 available projects were freshly scanned.
Their inventory contained 38 Agents, 39 Skills and 13 instruction resources.
Global Agent inventory remained 21, native plugin Skill inventory remained 97,
and runtime plugin inventory remained 20. Relationship marker v3 was retained.
These are observed inventory counts, not claims of capability effectiveness or
exhaustive historical invocation accuracy.

A short read-only installed-process sample after this refresh contained no
project-source-read or obsolete runtime-wait queue labels; the process was
idle at the observation. The installed executable still matched the accepted
build-42 SHA-256 above. No production source/configuration, permissions or
database values were manually changed. No new binary or scheduling-order
change was required for this recovery. The cause of the original storage wait
remains unestablished; the bounded fallback remains necessary for recurrence.
