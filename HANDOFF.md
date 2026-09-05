# Development Handoff

Codex Director is a privacy-first, read-only inventory and observability tool for personal Codex capabilities.

## Product boundaries

- Treat Agent, Skill, plugin, project, usage evidence, and manual evaluation as distinct concepts.
- Do not equate file presence, invocation count, or command completion with capability effectiveness.
- Do not modify source capability files, Codex sessions, global Codex configuration, or plugin packages.
- Keep prompts, command arguments, raw outputs, credentials, cookies, and session content out of persistence, logs, screenshots, fixtures, and issues.
- Use synthetic paths and data in tests and documentation.
- Keep missing, stale, unavailable, and observed-zero states distinct.

## Engineering boundaries

- Preserve stable identifiers, bilingual resources, shared refresh coordination, and cached startup behavior.
- Use the database only for Director-owned projections, classifications, and evaluations; source files remain authoritative for capability content.
- Keep capability export compatible with manifest v1 unless a separately approved migration is provided.
- Test changes before replacing any installed local application.
- Do not commit or push unrelated working-tree changes.

## Public-release boundaries

- Run `./scripts/verify.sh` before proposing a merge.
- Run `./scripts/audit-public-release.sh --all` on a clean public-history candidate.
- Do not publish Developer ID or notarization claims for ad-hoc signed builds.
- Keep release artifacts, local databases, sessions, capability packages, signing material, and environment files out of Git.
- Review new media for provenance, privacy, metadata, and licensing; register retained media in `docs/public-asset-inventory.md`.

See `CONTRIBUTING.md`, `PRIVACY.md`, and `docs/ARCHITECTURE.md` for the public contribution contract.

