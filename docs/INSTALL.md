# Installation

## Build from source

The most transparent installation path is to clone the repository, run the verification suite, and build the app locally. Follow `BUILDING.md`.

## Install a community build

1. Download the macOS ZIP, `SHA256SUMS.txt`, `BUILD-INFO.json`, and `DEPENDENCIES.json` from the same GitHub Release.
2. Verify the archive checksum with `shasum -a 256 -c SHA256SUMS.txt`.
3. Confirm that `BUILD-INFO.json` says `ad-hoc`, `appleDeveloperID: false`, and `notarizedByApple: false`, and that its source commit matches the release tag.
4. If GitHub CLI is installed, verify provenance with `gh attestation verify <archive> --repo SimuDesign/Codex-Director`.
5. Expand the ZIP and move Codex Director to `/Applications`.
6. Open the application normally.

Community builds are ad-hoc signed, not Developer ID signed, and not notarized. If macOS blocks the first launch and you have verified and trust the source, follow Apple's documented [Open Anyway](https://support.apple.com/en-us/102445) flow in System Settings → Privacy & Security. Do not disable Gatekeeper globally.

## Remove Codex Director

Move the application to Trash. Director-owned local data can be removed separately from the app's Application Support container. Removing Director data does not delete source Agents, Skills, plugins, projects, or Codex sessions.
