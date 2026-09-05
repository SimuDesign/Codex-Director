# Release Process

Codex Director uses source-first GitHub releases without Apple Developer ID signing or notarization.

## Candidate preparation

1. Use a clean checkout of the intended tag commit.
2. Confirm that `v<marketing-version>` matches `MARKETING_VERSION` with `./scripts/validate-release-tag.sh <tag>`.
3. Run `./scripts/audit-public-release.sh --all` against the complete public history.
4. Run `./scripts/verify.sh` and the documented heavy performance gates.
5. Build with `./scripts/build-local-app.sh`; the verifier requires exactly `arm64` and `x86_64`, an ad-hoc signature, and hardened runtime.
6. Package with `./scripts/package-release.sh --output <empty-path> --source-tag <tag>` and retain all four generated files.
7. Review bilingual copy, privacy disclosures, asset inventory, dependency notices, and synthetic screenshots.

## Release artifacts

The tag workflow runs on GitHub's macOS 26 runner and produces:

- `Codex-Director-<version>-macOS-26-unnotarized.zip`
- `SHA256SUMS.txt`
- `BUILD-INFO.json`
- `DEPENDENCIES.json`, identical to the locked `Package.resolved`
- GitHub build-provenance attestations for the three files named by `SHA256SUMS.txt`

All reusable GitHub Actions are pinned to full commit SHAs. The workflow verifies the tag, complete public history, source tests, app bundle, archive paths, checksums, dependency identity, signature status, and universal architectures. It creates a draft prerelease; a maintainer must review the result before publication.

## Version policy

The `v<marketing-version>` tag must match `MARKETING_VERSION`. `CURRENT_PROJECT_VERSION` is a monotonically increasing integer. Public release notes must state the exact signing and notarization status.

The planned public sequence is `0.9.0` prerelease followed by cross-device verification and then `1.0.0`. Do not create either tag until the project version and build number are updated together and all release gates pass.

## Workflow security

- PR and push CI has only `contents: read` and never uses `pull_request_target`.
- The tag job receives `contents: write`, `id-token: write`, `attestations: write`, and `artifact-metadata: write` only for the release job.
- The tag job runs only when the canonical `SimuDesign/Codex-Director` repository is public, preventing the private archive from producing a release.
- No Apple certificate, Developer ID, notarization credential, or personal secret is configured.

After the public repository is created, protect `main`, require the CI check, forbid force pushes and branch deletion, use squash merges, and automatically delete merged feature branches. These are repository settings and are intentionally not applied before the controlled public cutover.

## Prohibited claims

Do not describe an ad-hoc signature, checksum, or GitHub attestation as Apple identity verification, notarization, or malware review.
