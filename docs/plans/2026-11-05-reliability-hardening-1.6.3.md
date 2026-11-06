# Reliability hardening 1.6.3 — implementation plan

## Scope and ownership

Target **1.6.3 (45)** on `codex/reliability-hardening-1.6.3`. Preserve all accepted
1.6.2 quota work already in the working tree. The user authorized implementation
and normal verified local replacement, but no Git publication, Tag or Release.

Product Architect supplies the safety/data contract. Two authorized
`gpt-6-sol` / `xhigh` workers follow the Software Engineer Brief: one owns
capability-package files/tests, the other owns presentation-cache and runtime
inventory files/tests. Quality Engineer remains independent and read-only.
Root owns version/docs, final verification and recoverable installation.
Compiler/test phases wait until both writers freeze shared build inputs.

## 1. Bounded capability-package processing

Use one application policy across export staging, archive readback and restore;
do not change manifest v1 or ZIPFoundation 0.9.20.

| Limit | Default |
| --- | ---: |
| Archive input bytes | 512 MiB |
| Entries, including directories | 20,000 |
| One regular file | 64 MiB |
| Total expanded content, including metadata and links | 512 MiB |
| Each root metadata file | 8 MiB |
| Symlink target bytes | 65,536 |
| Entry path UTF-8 bytes / component depth | 4,096 / 64 |

Exact limits are allowed; excess is rejected. Internal tests inject tiny
budgets rather than creating large archives. Preflight all declarations before
expansion; enforce actual chunk totals, CRC, declared-size agreement and
overflow-safe arithmetic during extraction. Preserve duplicate/path/ancestor
and link containment protections. Reject unsafe local-header symlink sizes
before ZIPFoundation can allocate a declared oversized symlink buffer.

Cancellation must interrupt extraction through the existing cancellation
boundary. Cleanup touches only the operation's owned isolated temporary data,
not source archives, existing destination packages or nonempty user directories.
An over-limit source capability is a blocking preview issue that can be
excluded; an old over-limit ZIP remains unchanged and readable by external
standard ZIP tooling, although Director now rejects it.

Temporary cleanup must be descriptor-anchored, without path-based recursive
deletion. Preserve changed/unverified objects, never traverse a substituted
root or symlink, and remove directories only when empty. Hold the archive file
descriptor across verification and publication so a replacement pathname
cannot publish unverified bytes. Existing-destination replacement must retain
the prior object until identity checks complete and permit guarded rollback.

These guarantees cover root/parent pathname substitutions and symlink escape.
They do not claim immunity to an arbitrary same-UID process continuously
rewriting the inside of the private mode-0700 temporary tree: Darwin has no
inode-conditional unlink primitive. Repeated identity checks cannot establish
that stronger guarantee; this change does not add a general filesystem layer.

## 2. Recoverable link closure

Keep direct relative links to actual regular files/directories strictly inside
the packaged capability. Validate the final staged and readback payload, not
only the original source. Block dangling targets, chains, cycles, symlink
ancestors and targets omitted by filtering. Do not weaken restore's descriptor
and no-follow checks. A synthetic Home export/readback/restore proves supported
links still round-trip; unsupported links must fail before final export.

## 3. Export selection validation

Validate every project selection before discovery or dictionary construction:
empty, unknown and duplicate IDs return `invalidSelection`, even when disabled.
Normal UI selections continue unchanged. Failure is atomic and cleans only
owned temporary work; malformed input never traps or silently selects a
different project.

## 4. Partial runtime retention

Retain old resources only for the independently failed source category. A CLI
MCP failure must preserve its prior resources, provenance and valid relations
as warning/unverified with their old observation times. Plugin-provided MCP
belongs to the plugin source, not automatically to the failed CLI MCP category.
Successful empty categories delete normally; successful categories stay fresh.
Compose with existing plugin-inventory and plugin-package fallback without
resurrecting genuinely removed plugins or manufacturing unsupported tools.

## 5. Cache lifecycle fence

`delete()` reads an existing identity even on an unactivated store, preserves
prior revocations and fences compatibility auto-activation. Repeated delete,
invalidate then delete, absent-file delete and deletion failure all retain the
fence. A truly first empty store may still use its legacy compatibility write;
explicit activation opens the next intended lifecycle and issues fresh permits.
Existing permit revision, identity and AppModel generation guards remain.

This contract covers one shared actor's lifetime, including a newly created
actor reopening and deleting an existing file. It does not introduce a URL-wide
or cross-process transaction/locking guarantee. No persistent sidecar, SQL
migration, source edit, evaluation/folder reset or permission change is added.

## Verification and delivery

1. Reproduce malformed selections, unsupported links, archive budget/cancel
   boundaries, MCP partial failure and cache compatibility resurrection using
   production APIs on synthetic temporary data.
2. Compile after both writer sets are frozen; distinguish compilation failures
   from genuine RED behavioral evidence. Run focused GREEN and neighboring
   regressions, including successful empty categories and normal package links.
3. Independent QA exercises adversarial tiny ZIP headers/budgets, link closure,
   cleanup/cancellation, mixed-category failures and cache lifecycle sequences.
4. Preserve the 1.6.2 daily-quota regressions; run complete `verify.sh`, public
   current/history audit and universal Release verification on frozen inputs.
5. After acceptance, normally quit the old App, retain it recoverably in Trash,
   compare staged/installed bundle/signature/hash, preserve data/preference
   digests before relaunch and perform proportionate installed runtime checks.

All writes in tests use fake Homes, databases and caches. No real restore,
source execution, credential access, OS accessibility-setting change or remote
publication is included.
