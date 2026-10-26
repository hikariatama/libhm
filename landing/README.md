# libhm website

Static page: `index.html`, `style.css`, `main.js`, `photos.js`, `assets/`, and `photos/`. No build step.

```shell
python3 -m http.server 4290 --directory landing
```

The window on the page is the app's layout running on a real map: MapLibre GL with OpenFreeMap vector tiles, recolored toward Apple Maps in dark appearance. The heatmap follows the app's renderer (`app/Sources/PhotoAtlas/HeatmapShader.swift`): an 18 pt Gaussian kernel fixed in screen space, the same logarithmic color scale, and a 52% opacity cap. Map search, selection, gallery, viewer, and keyboard shortcuts work. A cursor plays through the main path until the visitor clicks, scrolls, or types inside the window.

The sample library is 118 Unsplash photos placed around Lisbon, Sintra, and Cascais; the locations and dates are assigned for the demo. Credits are in `photos/CREDITS.md`. `photos/` holds 1000 px images for the viewer, and `photos/thumbs/` holds 400 px square crops for the gallery.

External requests: MapLibre from unpkg and tiles, fonts, and sprites from tiles.openfreemap.org.

The Download button links to `libhm.dmg` next to `index.html`. The DMG is not committed; copy it in when deploying:

```shell
cp app/dist/libhm.dmg landing/libhm.dmg
```

`assets/wordmark-dark.svg` is a copy of the app's wordmark from `app/Sources/PhotoAtlas/BrandAssets.xcassets`; `assets/avx.svg` comes from the Room 237 site.
