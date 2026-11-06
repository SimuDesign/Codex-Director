# Reliability hardening validation — 2026-11-05

Target: **1.6.3 (45)**. Status: final independent review, full verification,
universal Release build, recoverable installation and installed runtime checks
passed. Installation resumed after the user manually unlocked the Mac.

## Baseline and scope

Preserve the already accepted 1.6.2 quota correction and its existing working
tree. The five new targets are package budgets, portable link closure, malformed
export selections, failed-category runtime retention and presentation-cache
compatibility writes after deletion. No source capabilities, global config,
credentials, user folders or real restore targets are written by tests.

The audit distinguished risks from observed UI failures. Duplicate project
selections and compatibility cache writes are public API defense gaps; normal
UI selections are unique and production cache writes already use permits.
The MCP finding concerns independent CLI MCP, not plugin-inventory fallback.
No malicious large archive was expanded to exhaust disk.

## Focused implementation evidence

Separate writer edits initially prevented a coherent Swift test build. Those
compilation/source-change failures are not counted as behavioral RED results.
The writers then froze inputs for one coordinated compile window.

A disposable baseline copy retained current tests but restored only the two
affected cache/index production files to their prior implementations. It built
successfully: 15 selected tests produced five expected failing assertions,
covering reopened/absent-file/invalidate-then-delete cache resurrection and
lost CLI-MCP fallback. The live working tree was never reverted.

The initial combined current run executed 154 tests with two failures in the
new dangling-link regression. Indexing 59/59, cache 14/14 and runtime discovery
16/16 passed. The package writer then corrected missing-final-link handling
across macOS temporary-directory aliases by resolving the parent rather than
the final item. The frozen package/restore run passed 60/60 tests. Diagnostic
prints were removed before the final run.

## Additional safety review gates

Independent review identified package extraction publication/cleanup races and
an early whole-archive digest before the size gate. Corrective boundaries must
cover descriptor-anchored publication, identity-safe cleanup through callers,
bounded digest reads and cancellation before a final candidate is accepted.
No full-suite success overrides an unresolved safety finding.

## Earlier candidate verification (superseded)

All 335 build inputs matched their frozen hashes after verification. The full
`scripts/verify.sh` passed: **1,330 tests, three existing opt-in performance
skips, zero failures**, followed by a successful Swift build. The public audit
passed with `--all` using a disposable index, including the tracked history;
the real Git index was not changed.

The Release build passed the project bundle verifier: **1.6.3 (45)**,
`com.peiweitang.CodexDirector`, macOS 26.0, **arm64 + x86_64**, ad-hoc signature.
Executable SHA-256:
`d70f39e851d96b706c53c164b619e7558d9188634aa3ecb1c29671151cd196ec`.

This artifact is not approved for installation. Further independent review
found remaining path-based cleanup callers and archive-object binding gaps.
The next cleanup pass passed 65 focused tests, but its helper still performed
path-based recursive deletion and export publication did not bind the archive
child. The final candidate must remove those gaps and rerun the release gates.

## Final candidate acceptance

The third candidate removes path-based recursive temporary cleanup. It uses
directory descriptors, identity inventories, no-follow child opens and
nonrecursive `unlinkat`; changed/unknown post-inventory objects remain intact.
Restore retains the isolated snapshot descriptor and verifies that object.
Export similarly retains and verifies the archive descriptor, then uses
anchored exclusive/swap publication with identity checks and guarded rollback.

Focused package/restore tests passed **69/69** (34 package, 35 restore), including
snapshot-path, archive-child, quarantine-name and destination replacement
regressions. The independent Quality Engineer issued **passed** against the
frozen final hashes. It performed read-only source/evidence review and did not
write repository or production data.

Fresh full `scripts/verify.sh` passed **1,339 tests, three existing opt-in
performance skips, zero failures**, followed by a successful Swift build. All
335 tracked/untracked build inputs and their membership matched the frozen
snapshot after verification. Universal Release verification passed for
**1.6.3 (45)**, macOS 26.0, arm64 + x86_64 and ad-hoc signature.
The final public tree/history audit also passed with `--all`, using a disposable
index; `git diff --check` passed and the real index remained empty.
Final executable SHA-256:
`c901c0e9aac95514297b6c8fc07d831f05ccd1ff3518e7092afceea85d1ceaf6`.

Accepted limits: no arbitrary same-UID continuous mutation guarantee inside
the private mode-0700 tree; pre-inventory same-UID injection is outside this
contract. Destination ancestor churn beyond bounded final-parent/entry race
tests was not independently exercised. The cache fence remains a shared-actor
lifetime guarantee, not cross-process locking. No OS accessibility settings
were changed, and no cross-device restore was required.

## Installed runtime verification

The old App was normally quit through its application menu. A premature
replacement attempt was safely refused while its process remained alive; no
bundle replacement occurred on that attempt. The subsequent installation
passed complete staged/installed bundle comparison, strict signature checks,
version/identity checks and the final executable hash above. Both architectures
are present. The old 1.6.2 (44) bundle remains uniquely recoverable in Trash.

Before relaunch, hashes of folder membership preferences, evaluations,
classification corrections, the production database and its existing WAL,
and capability-history storage matched before/after installation. No restore
was performed against real source directories.

The installed App launched successfully. Its Settings page displayed 1.6.3.
A manual refresh showed the native loading indicator, completed indexing at
308/308, returned to the ready state and restored the normal refresh button.
Home displayed current quota, the daily series, all three capability counts
and the installed-plugin count. Existing custom-folder members were visible.
After relaunch and manual refresh, normal production indexing can update the
derived database; preservation hashes are intentionally compared before
relaunch rather than against these legitimate updates.

## Verification coverage

- Tiny injectable limits, local/central/header-size mismatch, actual streaming
  size/CRC, mid-extraction and digest cancellation, ownership-safe failure paths.
- Supported link export/readback/restore and unsupported dangling, chained,
  cyclic, filtered-out and symlink-ancestor targets.
- Exact/over-limit boundaries, invalid selections and unchanged source archives.
- MCP/plugin source combinations, successful empty categories and warning
  fallback provenance/relations without plugin resurrection.
- Cache delete/invalidate/absent-file/failure fence, first write and explicit
  activation; shared-actor guarantee only, not cross-process locking.
- Frozen complete Swift verification, public audit, universal Release and
  independent QA before recoverable installation and runtime validation.

No Git commit, push, Tag, Release or OS accessibility-setting change is part of
this validation task.
