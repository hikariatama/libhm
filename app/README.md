# libhm

A native macOS photo map for Apple Photos. Browse the density map, select a location, and open the photographs taken there.

## Using the app

The app and Photos extension follow the system's preferred language, supporting Russian and English with English fallback. Controls, errors, accessibility labels, privacy descriptions, dates, and numbers are localized. Album names and saved project names are kept as supplied by Photos.

In the standalone app, choose **?** in the floating panel or **Help → Use in Apple Photos…** for an in-app guide to creating and pinning a Photos project. The help button is hidden inside Photos. The guide includes extension setup troubleshooting and an **Open Photos** button; pinning instructions adapt to macOS 26+ and older versions.

- The viewer follows the Photos arrangement inside the project: back and a zoom slider on the left, date/count centered above the image, information on the right. Photo information opens in a system popover. Photos owns its separate host toolbar; the public project-extension API does not expose a toolbar replacement. Loading, denied access, and empty/error states use system progress indicators and unavailable-content views; filters use a grouped system form.
- Gallery thumbnails fill their cells with centered crops, preserving aspect ratio.
- The gallery follows the free map area between the measured left panel, right controls, and top/bottom edges, with 12 points of overlap beneath the bordering interface. Resizing the window, collapsing the gallery, or hiding the legend updates this area without moving the camera. Click a heat spot to pin a selection within 28 screen points; choose **Back to map area** to resume following the map.
- Click a thumbnail to mark its location. Double-click or press Space to open it. Use the arrow keys for previous/next, Escape or Space to return to the map, I for information, +/− to zoom, and 0 to fit. Keyboard input uses an AppKit responder inside the Photos remote view, with gallery focus restored on return. System modifier shortcuts and focused slider/text controls keep their native bindings.
- In the viewer, use the zoom slider/buttons, double-click, or pinch to zoom. Drag an enlarged image to pan; **0** restores the full image. Opening/closing, photo changes, and zoom have short transitions; Reduce Motion disables them.
- Filter the map and gallery by date, album, and favorites. Date ranges include the entire final day; **Reset filters** clears all filters.
- Search for a place, use **Show all photos** to fit the matching photographs, or switch between the standard map and satellite imagery.
- The map fills the window. Search, filters, export, and photos live in a floating left panel, fixed at 340 points wide; map appearance and zoom controls sit on the right. Collapse the panel to the search field when needed. Photos fade to transparency over 24 points at the top and bottom of the scrolling gallery. Map camera and map style are remembered.
- Panels use native Liquid Glass on macOS 26 and later, with system material on macOS 14–15. Appearance follows the system theme.
- The export menu copies the current map or saves it as PNG, including the active heatmap and selected photo marker.

MapKit can limit the widest world view, so libraries spanning opposite sides of the globe may require panning between regions.

Photos without valid coordinates count toward library totals but do not appear on the map. Live Photos use their still image. Videos and editing the Photos library are outside the current scope.

## Build and run

Run the commands below from this `app/` directory. Requires macOS 14+, Xcode with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```shell
./scripts/build-run.sh
```

The script creates a universal Release app for Apple Silicon and Intel. Build products stay outside iCloud in `~/Library/Developer/Xcode/DerivedData/PhotoAtlas`. Override that directory with `PHOTO_ATLAS_DERIVED_DATA`. Pass `--build-only` to skip launching.

The project in `PhotoAtlas.xcodeproj` is generated from `project.yml`. Open the `PhotoAtlas` scheme in Xcode for development. Local ad-hoc builds can require renewed Photos permission when their code signature changes.

## Package a DMG

After building Release, run:

```shell
./scripts/package-dmg.sh
```

This creates `dist/libhm.dmg` using the supplied banner in `Packaging/banner@2x.png`, preserved without artwork changes. The embedded lossless TIFF includes 654 × 422 px at 72 dpi and the original 1308 × 844 px at 144 dpi. The window is 654 × 444 pt including its 22 pt title bar; image dimensions and icon positions remain relative to the 654 × 422 pt content area. A rendered composition preview, rather than a Finder screenshot, is saved in `dist/dmg-preview/installer-preview.png`.

Packaging requires macOS, Python 3, and Swift. The script installs pinned `dmgbuild` dependencies into `~/Library/Caches/libhm-packaging/venv`; temporary mounted-image staging stays outside iCloud. `LIBHM_DMG_VENV` overrides the tools directory. Optional arguments select an existing app and output path: `./scripts/package-dmg.sh /path/to/libhm.app /path/to/libhm.dmg`. It verifies the image checksum, mounts the result read-only, checks the deep/strict app signature and payload hashes, verifies Finder layout, and compares the decoded Retina background pixels with the supplied PNG before replacing the output. Packaging preserves the app's existing signature and does not notarize it.

`Packaging/layout.json` is the shared geometry configuration for local builds and macOS CI: 140 pt icons, 12 pt labels below the icons, app center (197,195), and Applications center (473,195). Icon positions are fixed; sidebar, toolbar, tabs, path bar, and status bar are hidden. Title-bar compensation affects the full window height only, without adding pixels to the artwork or shifting icon coordinates.

CI uses the same entry point after building or signing `libhm.app`; no Finder session or UI scripting is required:

```shell
./scripts/package-dmg.sh "$RELEASE_APP_PATH/libhm.app" "$RUNNER_TEMP/libhm.dmg"
```

The packaging assets, geometry, and pinned dependency versions are stored in the repository. The command returns a failure on an invalid artifact; upload the resulting DMG only after it succeeds. CI configuration is documented here; no remote CI run or artifact upload has been performed.

## Photos project extension (PoC)

The app embeds a `com.apple.photo-project` extension. Install or refresh its registration with:

```shell
./scripts/install-photos-extension.sh
```

Quit the standalone app before rebuilding its installed bundle. Use `--no-build` to register an already built app. The extension uses the same `PHOTO_ATLAS_DERIVED_DATA` override as the build script.

In Photos, choose **File → Create → Other → libhm**, then select **Heatmap**. A successful creation stores a persistent project named **Heatmap**, which Photos can list in its sidebar. This is a project entry, not a replacement for the built-in Map item. Any initial photo selection does not restrict the map.

For an app delivered in a DMG, copy **libhm.app** to **Applications** before using its extension. A recommended first-run sequence is to open the app once and grant full Photos access, then create the project from Photos. The containing app does not have to remain running. If libhm is missing from the Create menu, use **File → Create → Manage** and enable it under **Photos Projects**, then reopen Photos if needed. A project must be created once before it appears in the sidebar; it is not added automatically by installation.

The repository currently produces local ad-hoc signed builds. A distributable DMG still needs Developer ID signing and notarization; packaging the current app in a DMG does not supply either. A clean DMG installation on a fresh macOS profile has not been verified.

The extension always reads the **entire System Photo Library** through full PhotoKit authorization. There is no source picker or selected-photos mode. Photos still uses its normal project creation flow, but the initial selection and project membership do not limit the heatmap or gallery. Older project source settings are ignored. No photo assets are edited.

Photos uses a separate transparent blue `mappin.and.ellipse` icon for the project extension. The standalone app uses the supplied libhm PNG icon. The floating-panel wordmark uses the supplied vector SVG, with dark lettering in the light appearance and the original lettering in the dark appearance. The project-type picker also uses that SF Symbol. The extension excludes the app's asset catalog so its icon metadata cannot overwrite `HeatmapProjectGlyph.icns`.

PhotoKit changes trigger a debounced background metadata/albums refresh while the project is open. New photos, edits, and deletions use the same refresh path; reopening reads the current library. Videos and hidden photos are excluded by the default PhotoKit image fetch. Locationless photos are included in metadata and filtering but not the map.

**Runtime verification:** the final full-library-only extension reopened an existing sidebar project after restarting Photos and showed 6,496 geolocated photos with loaded thumbnails. Double-click, arrow navigation, and Escape back to the map passed. The source picker is absent. Universal Release build, deep/strict signature verification, and all 18 current Release tests passed. Tests cover new-photo refresh with pinned selection, selected-photo deletion, denied-access retry, and stale-load rejection. Actual delivery of a newly imported photo has not been manually exercised.

The build script stages Sources, Config, Tests, and the generated Xcode project outside iCloud to avoid file-coordination stalls.

## Tests and diagnostics

```shell
xcodegen generate
xcodebuild -project PhotoAtlas.xcodeproj -scheme PhotoAtlas \
  -configuration Release -derivedDataPath /tmp/photo-atlas-tests test
```

Tests cover spatial queries, wrapping at the date line, coincident points, filters, data changes, stale request generations, date grouping, transparent density rendering, tile seams, pan stability, and 100,000-photo query performance.

For manual UI checks without accessing the Photos library:

```shell
open -n -a '/path/to/libhm.app' --args --sample-library
```

The app labels this mode **Sample library**. Add `--heatmap-reference` for a street-scale fixture with merged clusters and isolated locations. Add `--empty-library`, `--no-locations`, or `--image-error` to exercise those states. `--simulate-denied` tests the permission screen without changing macOS privacy settings.

Launch with `--benchmark` to write aggregate timings for the real library and a repeatable 100,000-record fixture to the sandbox's `Library/Caches/PhotoAtlas/benchmark.json`. The report contains counts and durations, not identifiers, images, or coordinates. Its legacy comparison reproduces the previous full-scan bucket calculation; it does not measure the old app's complete UI or gradient rendering.

For localization QA, launch a fresh sample-library process with `-AppleLanguages '(ru)' -AppleLocale ru_RU` (or English). An unsupported language such as `'(fr)'` falls back to English for the app's strings. MapKit place labels remain controlled by Apple's map service. Add `--slow-library` with `--sample-library` to hold the loading state for 20 seconds; this flag never delays the real library.

## Architecture

PhotoKit metadata is scanned in the background and refreshed when the library changes. The live heatmap uses Metal: a packed spatial tree selects visible point ranges, the GPU accumulates their weights into one padded density field, applies a separable Gaussian, then applies the fixed logarithmic color scale. The 18-point kernel follows continuous camera scale; locations merge and separate before colorization, without switching PNG tile levels. Coincident coordinates are summed once when building the scene. Compensated coordinates preserve street-scale positioning, including the date line.

The surface refreshes at up to 60 frames per second during camera movement and pauses continuous rendering at rest. Scene construction and shader compilation run off the main thread; cancelled scenes cannot replace newer data. Presentation follows MapKit's Core Animation transaction. Density working buffers are capped at approximately 26 MiB, with Retina-resolution final composition. Sparse locations are violet, merging density passes through cyan and yellow, and dense centers are pink; opacity is capped at 52%. The prior cached-tile renderer remains a fallback when Metal is unavailable. PNG export uses the CPU Gaussian renderer with the same kernel and color scale.

The gallery uses reusable `NSCollectionView` cells and `PHCachingImageManager` preheating. Background gallery results and image callbacks reject stale requests. The decoded-image cache has a 96 MiB budget; fallback tiles have a separate 96 MiB budget and are unused during Metal rendering. Working GPU buffers, presentation drawables, spatial metadata, and system MapKit/PhotoKit memory are additional.

## Privacy

The app reads Apple Photos without changing assets, favorites, albums, or coordinates. Indexing happens on the Mac. Apple Maps and place search use Apple's network services. Visible thumbnails and opened images may download automatically from iCloud; the app does not download the entire library or upload photos to another service.

## License

AGPL-3.0-only. See [LICENSE](../LICENSE).

Map diagnostics are opt-in: launch the standalone executable with `--heatmap-diagnostics` to log Metal frame/backpressure/drawable counters, alignment error, and MapKit loading/rendering callbacks under the `com.hikariatama.PhotoAtlas` subsystem. No photo IDs or coordinates are logged. MapKit manages its own resource requests; detailed VectorKit timeout/TLS messages remain available in the system log.
