<img src="https://github.com/user-attachments/assets/b47fd186-6f59-41f7-a95d-d516bad6e23a" width="200" alt="libhm" />

![vibecoded](https://img.shields.io/badge/vibecoded-545454)
[![open-source](https://img.shields.io/badge/open--source-545454)](LICENSE)
[![release](https://img.shields.io/badge/release-tag--v0.0.1-9b953a)](https://github.com/hikariatama/libhm/releases/tag/v0.0.1)
[![CI](https://github.com/hikariatama/libhm/actions/workflows/ci.yml/badge.svg)](https://github.com/hikariatama/libhm/actions/workflows/ci.yml)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-545454)](LICENSE)

> A native macOS photo map for Apple Photos. Browse a heatmap and open photographs from any place, including inside Photos.

<img src="https://github.com/user-attachments/assets/a105b2fc-adc5-470c-bf3e-eb7db3a320b0" width="100%" alt="libhm screenshot" />

## Download

<table>
  <thead><tr><th>Platform</th><th>Download</th></tr></thead>
  <tbody>
    <tr><td>macOS · Universal</td><td><a href="https://github.com/hikariatama/libhm/releases/download/v0.0.1/libhm-macos-universal.dmg"><img alt="DMG Universal" src="https://img.shields.io/badge/DMG-Universal-9b953a" /></a> <a href="https://github.com/hikariatama/libhm/releases/download/v0.0.1/libhm-macos-universal.zip"><img alt="ZIP Universal" src="https://img.shields.io/badge/ZIP-Universal-545454" /></a></td></tr>
  </tbody>
</table>

CI replaces the draft for this version on rebuild. Before publication, maintainers can download it from [Releases](https://github.com/hikariatama/libhm/releases). Checksums: `SHA256SUMS.txt`.


## Prerequisites

- macOS 14+ and Xcode with Swift 6. Build scripts verify and run XcodeGen 2.46.0.
- Photos access for your System Photo Library.

## Development

```sh
cd app
./scripts/build-run.sh
```

Use `--build-only` to build without launching. The app reads Photos without changing your library.

## Checks

```sh
cd app
../scripts/xcodegen.sh generate
xcodebuild -project PhotoAtlas.xcodeproj -scheme PhotoAtlas \
  -configuration Release -derivedDataPath /tmp/libhm-tests test
```

## Packaging

```sh
cd app
./scripts/package-dmg.sh
```

See [build, extension setup and privacy](app/README.md) and the [landing page](landing/README.md).

## Repository and deployment

The application and static landing share this repository. The root Dockerfile
serves only `landing/`. Keep the deployment mirror on the reviewed `main` commit;
deployment is manual. Development boundaries are in [AGENTS.md](AGENTS.md).

## Release integrity and secret scanning

CI checks Git history and the working tree with checksum-pinned Gitleaks.
For a local scan, install Gitleaks and run `./scripts/check-secrets.sh`.
Reports redact potential secrets; no baseline or secret allowlist is applied.

Builds use a checksum-verified XcodeGen archive and hash-locked Python wheels.
`LIBHM_TOOLS_CACHE` can override the local tool cache. An unexpected cached
archive fails verification; PATH/Homebrew XcodeGen binaries are not used.

GitHub release packages are attested in a separate job and their source commit,
workflow and `main` ref are verified before creating or refreshing a draft.
Only the current `main` commit can produce a release draft. Publish the draft
manually after review. Published releases and their tags cannot be overwritten:
increment `VERSION` and the application's version settings for the next release.
Private drafts may still be rebuilt. Tag-triggered builds do not publish assets.
