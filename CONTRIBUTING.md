# Contributing

Thank you for helping improve Codex Director.

## Before opening a change

- Keep source Agent, Skill, plugin, project, session, and global Codex files read-only.
- Use synthetic capabilities, paths, account states, and screenshots.
- Do not add credentials, cookies, prompts, command arguments, raw outputs, local databases, sessions, capability packages, signing material, or environment files.
- Preserve the distinction between missing, stale, unavailable, observed zero, invocation, completion, and effectiveness.
- Keep UI changes consistent with the project design system and accessibility validation plan.

## Development workflow

1. Create a focused branch from `main`.
2. Add or update tests before production behavior.
3. Run `./scripts/verify.sh`.
4. Run `./scripts/audit-public-release.sh --tracked`.
5. For build or release changes, run `./scripts/build-local-app.sh` and exercise `./scripts/package-release.sh` with a new temporary output path.
6. Open a pull request describing behavior, privacy impact, verification, and screenshots made with synthetic data.

The repository uses squash merges. Force pushes and deletion of `main` are not allowed.

## Media

New media must have known provenance and permission for public distribution. Remove embedded personal metadata and add the retained file to `docs/public-asset-inventory.md`.
