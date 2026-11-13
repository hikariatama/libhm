# libhm for macOS

A read-only photo map for the System Photo Library, available as a standalone app and a Photos project extension. It supports English and Russian, date/album/favorite filters, place search, a photo viewer and PNG map export.

Requires macOS 14+. Grant full Photos access to browse the library. Photos without coordinates remain in library counts but do not appear on the map. Photos and albums are never edited. Apple Maps uses Apple's network services; visible iCloud images may download on demand.

Copy the application to Applications before enabling the extension. In Photos, use File → Create → Other → libhm; if absent, enable it under Photos Projects in the Manage menu. The standalone Help menu contains setup guidance.

Build and test commands, privacy boundaries and packaging rules are in [AGENTS.md](../AGENTS.md). The generated project comes from `project.yml`; packaging assets and layout are in `Packaging/`.

The DMG does not supply Developer ID signing or notarization. License: [AGPL-3.0-only](../LICENSE).
