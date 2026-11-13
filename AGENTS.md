# Working on libhm

## Build and check

- The native macOS app and Photos project extension are in `app/`; the static website is in `landing/`.
- Use macOS 14+, Swift 6 and the checksum-pinned XcodeGen wrapper. Generate the project from `app/project.yml`; do not hand-edit generated Xcode settings.
- Build with `cd app && ./scripts/build-run.sh --build-only`. Use an isolated `PHOTO_ATLAS_DERIVED_DATA` directory; the build stages sources outside File Provider storage.
- Run `../scripts/xcodegen.sh generate`, then `xcodebuild -project PhotoAtlas.xcodeproj -scheme PhotoAtlas -configuration Release -derivedDataPath /tmp/libhm-tests CODE_SIGN_IDENTITY=- test` from `app/`.
- Package with `app/scripts/package-dmg.sh`; it checks payload hashes, deep/strict signatures, image checksum, layout and source artwork. Packaging is not notarization.
- Run `scripts/check-secrets.sh` before publication. Keep pinned tool hashes and hash-locked packaging dependencies.
- Builds and tests must not install or launch applications, register the Photos extension or change privacy permissions. Use synthetic/sample-library fixtures for isolated UI checks.

## Behavior and privacy

- Read the System Photo Library without editing assets, albums, favorites or coordinates. Full-library PhotoKit access applies to both the standalone app and the extension.
- Keep PhotoKit indexing, scene construction and shader compilation off the main thread. Reject stale metadata, image callbacks and cancelled scene results.
- Preserve date-line handling, summed coincident coordinates, map selection and gallery scroll position across refreshes and layout changes.
- Preserve the shared heatmap kernel/color scale between Metal, fallback rendering and export. Reuse collection-view cells and keep decoded-image caches bounded.
- Keep English/Russian UI and accessibility localization, system appearance and Reduce Motion support. Do not translate user-provided album or project names.
- Diagnostics must not log photo identifiers, images or coordinates. Apple Maps requests and on-demand iCloud thumbnail downloads are separate from local indexing.
- Preserve bundle identifiers, extension identifiers and saved project compatibility. Installation/registration requires a separately authorized action.
- Preserve packaging artwork and geometry from `app/Packaging/`; do not compensate for Finder differences by silently altering source art.
- When changing landing dependencies, update integrity attributes and both CSP policies. Preserve photo credits and resource licenses.

## Repository and releases

- Keep current development instructions in this file; do not add a documentation archive or a `docs/` directory.
- Keep README files concise and user-facing. Preserve licenses, third-party notices and asset attribution.
- Use synthetic fixtures. Never commit credentials, account data, private profiles, databases, local diagnostics, dependencies or build products.
- Keep one commit per version on `main`, named `vX.Y.Z`, with the matching version tag. Do not invent versions for repository maintenance.
- Published history, tags and assets may be replaced only with explicit owner authorization. Report source checks, builds, publication and deployed behavior separately.
- Keep deployment mirrors on the same reviewed source commit. A Git push does not authorize deployment or installation.
