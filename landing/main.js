// libhm website: the app window running on a real map with sample photos.
// The heatmap follows app/Sources/PhotoAtlas/HeatmapShader.swift: an 18 pt Gaussian (sigma 6 pt)
// fixed in screen space, the same log color scale and the 52% opacity cap.
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const stage = $("stage"), win = $("window"), heat = $("heat"), panel = $("panel"), gallery = $("gallery");
  const hctx = heat.getContext("2d");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Sample library: Unsplash photos placed around Lisbon, Sintra and Cascais.

  function mulberry32(seed) {
    return () => {
      seed = (seed + 0x6d2b79f5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const rand = mulberry32(237);
  const gauss = () => {
    let u = 0;
    while (!u) u = rand();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand());
  };

  const SPOTS = {
    alfama: { lat: 38.7116, lon: -9.13, sigma: 75, day: [2024, 5, 10], hours: [15, 20] },
    comercio: { lat: 38.7077, lon: -9.1365, sigma: 22, day: [2024, 5, 10], hours: [10, 14] },
    tram: { line: [[38.7107, -9.142], [38.71, -9.138], [38.7098, -9.1335], [38.7118, -9.1305], [38.716, -9.131]], sigma: 14, day: [2024, 5, 11], hours: [9, 13] },
    belem: { lat: 38.6916, lon: -9.216, sigma: 18, day: [2024, 5, 12], hours: [10, 13] },
    bridge: { lat: 38.7005, lon: -9.1745, sigma: 110, day: [2024, 5, 12], hours: [17, 21] },
    pena: { lat: 38.7876, lon: -9.3906, sigma: 22, day: [2023, 9, 2], hours: [11, 15] },
    cascais: { lat: 38.6966, lon: -9.421, sigma: 160, day: [2023, 9, 3], hours: [12, 19] },
  };

  const PLACES = [
    { name: "Lisbon", sub: "Portugal", bounds: [[-9.147, 38.7055], [-9.1255, 38.7175]] },
    { name: "Alfama", sub: "Lisbon, Portugal", center: [-9.1305, 38.7116], zoom: 16 },
    { name: "Praça do Comércio", sub: "Lisbon, Portugal", center: [-9.1365, 38.7077], zoom: 16.5 },
    { name: "Belém Tower", sub: "Lisbon, Portugal", center: [-9.216, 38.6916], zoom: 16.5 },
    { name: "Ponte 25 de Abril", sub: "Lisbon, Portugal", center: [-9.1748, 38.6995], zoom: 14.5 },
    { name: "Sintra", sub: "Portugal", center: [-9.3906, 38.7876], zoom: 14 },
    { name: "Cascais", sub: "Portugal", center: [-9.421, 38.6966], zoom: 14 },
  ];
  const CITY = PLACES[0].bounds;

  const photos = PHOTOS.map((src) => {
    const spot = SPOTS[src.s];
    let lat, lon;
    if (spot.line) {
      const i = Math.floor(rand() * (spot.line.length - 1)), t = rand();
      const [a, b] = [spot.line[i], spot.line[i + 1]];
      lat = a[0] + (b[0] - a[0]) * t;
      lon = a[1] + (b[1] - a[1]) * t;
    } else {
      lat = spot.lat;
      lon = spot.lon;
    }
    lat += (gauss() * spot.sigma) / 111320;
    lon += (gauss() * spot.sigma) / (111320 * Math.cos((lat * Math.PI) / 180));
    const [y, m, d] = spot.day, [h0, h1] = spot.hours;
    const date = new Date(y, m - 1, d, h0 + Math.floor(rand() * (h1 - h0)), Math.floor(rand() * 60), Math.floor(rand() * 60));
    return { ...src, lat, lon, date, fav: rand() < 0.14 };
  });
  photos.sort((a, b) => a.date - b.date);
  photos.forEach((p, i) => { p.name = `IMG_${4120 + i * 3}.HEIC`; });
  photos.reverse();
  photos.forEach((p, i) => {
    p.id = i;
    const m = maplibregl.MercatorCoordinate.fromLngLat([p.lon, p.lat]);
    p.mx = m.x;
    p.my = m.y;
  });

  // Map

  const panelOpen = () => !panel.classList.contains("collapsed");
  // On phones the panel is a bottom sheet (see style.css); otherwise it floats on the left.
  const sheet = () => panel.offsetLeft < 20 && panel.offsetTop > win.clientHeight * 0.3;
  function padding() {
    if (sheet()) return { top: 70, bottom: win.clientHeight - panel.offsetTop + 20, left: 30, right: 64 };
    const left = panelOpen() ? panel.offsetLeft + panel.offsetWidth + 44 : 40;
    return { top: 70, bottom: 50, left, right: 90 };
  }

  const map = new maplibregl.Map({
    container: "map",
    style: "https://tiles.openfreemap.org/styles/dark",
    bounds: CITY,
    fitBoundsOptions: { padding: padding() },
    attributionControl: false,
    dragRotate: false,
    pitchWithRotate: false,
    touchPitch: false,
    maxZoom: 18,
    minZoom: 4,
    renderWorldCopies: false,
    fadeDuration: 0,
  });
  map.touchZoomRotate.disableRotation();
  map.keyboard.disableRotation();

  // Closer to Apple Maps in dark appearance than the stock OpenFreeMap colors.
  const PAINT = {
    background: { "background-color": "#232325" },
    landuse_residential: { "fill-color": "#262628" },
    landcover_wood: { "fill-color": "#1f2a22" },
    landuse_park: { "fill-color": "#1f2a22" },
    water: { "fill-color": "#17222e" },
    waterway: { "line-color": "#17222e" },
    building: { "fill-color": "#2c2c2f" },
    highway_path: { "line-color": "#2c2c2e" },
    highway_minor: { "line-color": "#36363a" },
    highway_major_casing: { "line-color": "#2a2a2d" },
    highway_major_inner: { "line-color": "#424246" },
    highway_major_subtle: { "line-color": "#3c3c40" },
    highway_motorway_casing: { "line-color": "#3a3328" },
    highway_motorway_inner: { "line-color": "#5e5340" },
    highway_motorway_subtle: { "line-color": "#4a4233" },
    railway: { "line-color": "#323235" },
    railway_dashline: { "line-color": "#232325" },
    railway_transit: { "line-color": "#323235" },
    railway_transit_dashline: { "line-color": "#232325" },
    railway_minor: { "line-color": "#323235" },
    railway_minor_dashline: { "line-color": "#232325" },
    aeroway_area: { "fill-color": "#2a2a2c" },
    "aeroway-area": { "fill-color": "#2a2a2c" },
    "aeroway-runway": { "line-color": "#3a3a3c" },
    water_name: { "text-color": "#4d6680" },
    highway_name_other: { "text-color": "#7c7c80" },
  };
  map.on("styleimagemissing", (e) => {
    if (!map.hasImage(e.id)) map.addImage(e.id, { width: 1, height: 1, data: new Uint8Array(4) });
  });
  map.on("style.load", () => {
    for (const [id, paint] of Object.entries(PAINT)) {
      if (!map.getLayer(id)) continue;
      for (const [key, value] of Object.entries(paint)) map.setPaintProperty(id, key, value);
    }
    for (const layer of map.getStyle().layers) {
      // The style's sprite has no wood pattern; a flat fill is closer to Apple Maps anyway.
      if (layer.paint?.["fill-pattern"]) map.setPaintProperty(layer.id, "fill-pattern", undefined);
      if (layer.id.startsWith("place_")) {
        map.setPaintProperty(layer.id, "text-color", "#9a9a9f");
        map.setPaintProperty(layer.id, "text-halo-color", "rgb(20 20 22 / 80%)");
      }
    }
  });

  let showHeatmap = true;
  let selection = null; // { lng, lat, mx, my, r } with r in Mercator units
  let marked = null;
  let areaList = [];

  const worldSize = () => 512 * 2 ** map.getZoom();

  // Density field: scatter -> separable Gaussian -> colorize, limited to the area around the points.
  const FIELD = 0.5;
  const SIGMA = 6 * FIELD;
  const R = Math.ceil(SIGMA * 3.5);
  const kernel = Float32Array.from({ length: 2 * R + 1 }, (_, i) => Math.exp(-((i - R) ** 2) / (2 * SIGMA * SIGMA)));
  const stops = [0, 0.24, 0.42, 0.61, 0.8, 1];
  const colors = [[0.6, 0.3, 0.88], [0.65, 0.38, 0.92], [0.36, 0.83, 0.85], [1, 0.89, 0.46], [0.98, 0.54, 0.76], [0.98, 0.54, 0.76]];
  const fieldCanvas = document.createElement("canvas");
  const fctx = fieldCanvas.getContext("2d");
  let field = null;
  let W = 0, H = 0, dpr = 1;

  function sizeHeat() {
    W = win.clientWidth;
    H = win.clientHeight;
    dpr = Math.min(2, devicePixelRatio || 1);
    heat.width = Math.round(W * dpr);
    heat.height = Math.round(H * dpr);
  }

  function drawDensity() {
    const iw = Math.ceil(W * FIELD), ih = Math.ceil(H * FIELD), fw = iw + 2 * R, fh = ih + 2 * R;
    if (!field || field.fw !== fw || field.fh !== fh) {
      field = { fw, fh, imp: new Float32Array(fw * fh), tmp: new Float32Array(fw * fh) };
      fieldCanvas.width = iw;
      fieldCanvas.height = ih;
      field.img = fctx.createImageData(iw, ih);
    }
    const { imp, tmp, img } = field;
    let x0 = fw, y0 = fh, x1 = -1, y1 = -1;
    imp.fill(0);
    for (const p of photos) {
      const pt = map.project([p.lon, p.lat]);
      const fx = pt.x * FIELD + R - 0.5, fy = pt.y * FIELD + R - 0.5;
      if (fx < -1 || fy < -1 || fx >= fw || fy >= fh) continue;
      const cx = Math.floor(fx), cy = Math.floor(fy), ax = fx - cx, ay = fy - cy;
      for (let y = 0; y < 2; y++) for (let x = 0; x < 2; x++) {
        const px = cx + x, py = cy + y;
        if (px < 0 || py < 0 || px >= fw || py >= fh) continue;
        imp[py * fw + px] += (x ? ax : 1 - ax) * (y ? ay : 1 - ay);
        if (px < x0) x0 = px;
        if (px > x1) x1 = px;
        if (py < y0) y0 = py;
        if (py > y1) y1 = py;
      }
    }
    const data = img.data;
    data.fill(0);
    if (x1 >= 0) {
      const bx0 = Math.max(R, x0 - R), bx1 = Math.min(fw - R - 1, x1 + R);
      const by0 = Math.max(R, y0 - R), by1 = Math.min(fh - R - 1, y1 + R);
      const ty0 = Math.max(0, by0 - R), ty1 = Math.min(fh - 1, by1 + R);
      for (let y = ty0; y <= ty1; y++) {
        const row = y * fw;
        for (let x = bx0; x <= bx1; x++) {
          let v = 0;
          for (let d = -R; d <= R; d++) v += imp[row + x + d] * kernel[d + R];
          tmp[row + x] = v;
        }
      }
      const logMax = Math.log(41);
      for (let y = by0; y <= by1; y++) {
        for (let x = bx0; x <= bx1; x++) {
          let v = 0;
          for (let d = -R; d <= R; d++) v += tmp[(y + d) * fw + x] * kernel[d + R];
          if (v <= 0.003) continue;
          const t = Math.min(1, Math.log(1 + v) / logMax);
          let i = 0;
          while (i < 4 && t >= stops[i + 1]) i++;
          const f = (t - stops[i]) / (stops[i + 1] - stops[i]), a = colors[i], b = colors[i + 1];
          const o = ((y - R) * iw + (x - R)) * 4;
          data[o] = 255 * (a[0] + (b[0] - a[0]) * f);
          data[o + 1] = 255 * (a[1] + (b[1] - a[1]) * f);
          data[o + 2] = 255 * (a[2] + (b[2] - a[2]) * f);
          data[o + 3] = 255 * Math.min(0.52, v * 0.85);
        }
      }
      for (let y = ty0; y <= ty1; y++) tmp.fill(0, y * fw + bx0, y * fw + bx1 + 1);
    }
    fctx.putImageData(img, 0, 0);
    hctx.imageSmoothingEnabled = true;
    hctx.drawImage(fieldCanvas, 0, 0, iw / FIELD, ih / FIELD);
  }

  function drawOverlays() {
    if (selection) {
      const c = map.project([selection.lng, selection.lat]), r = selection.r * worldSize();
      hctx.beginPath();
      hctx.arc(c.x, c.y, r, 0, Math.PI * 2);
      hctx.fillStyle = "rgb(10 132 255 / 8%)";
      hctx.fill();
      hctx.lineWidth = 2;
      hctx.strokeStyle = "#0a84ff";
      hctx.stroke();
    }
    if (marked) {
      const c = map.project([marked.lon, marked.lat]);
      hctx.save();
      hctx.shadowColor = "rgb(0 0 0 / 45%)";
      hctx.shadowBlur = 6;
      hctx.beginPath();
      hctx.arc(c.x, c.y, 7, 0, Math.PI * 2);
      hctx.fillStyle = "#0a84ff";
      hctx.fill();
      hctx.restore();
      hctx.lineWidth = 2;
      hctx.strokeStyle = "#fff";
      hctx.stroke();
    }
  }

  function drawHeat() {
    hctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    hctx.clearRect(0, 0, W, H);
    if (showHeatmap) drawDensity();
    drawOverlays();
  }

  map.on("render", drawHeat);
  map.on("move", () => {
    updateArea();
    scheduleGallery();
  });

  // Area and gallery

  const dayFormat = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" });
  const fullFormat = new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", second: "2-digit" });
  const num = new Intl.NumberFormat("en-US");

  function freeRect() {
    const controls = win.querySelector(".controls");
    if (sheet()) return { x0: 0, x1: W, y0: 0, y1: panel.offsetTop };
    return { x0: panelOpen() ? panel.offsetLeft + panel.offsetWidth : 0, x1: controls.offsetLeft, y0: 0, y1: H };
  }

  function updateArea() {
    if (selection) {
      const r2 = selection.r ** 2;
      areaList = photos.filter((p) => (p.mx - selection.mx) ** 2 + (p.my - selection.my) ** 2 <= r2);
    } else {
      const a = freeRect();
      areaList = photos.filter((p) => {
        const pt = map.project([p.lon, p.lat]);
        return pt.x >= a.x0 && pt.x <= a.x1 && pt.y >= a.y0 && pt.y <= a.y1;
      });
    }
    $("area-count").textContent = num.format(areaList.length);
    $("area-title").textContent = selection ? "Selected location" : "In this area";
    $("back-to-area").hidden = !selection;
  }

  let galleryTimer = 0, galleryKey = "";
  function scheduleGallery() {
    clearTimeout(galleryTimer);
    galleryTimer = setTimeout(renderGallery, 100);
  }

  function renderGallery() {
    const key = areaList.map((p) => p.id).join(",");
    if (key === galleryKey) return;
    galleryKey = key;
    gallery.scrollTop = 0;
    if (!areaList.length) {
      gallery.innerHTML = '<div class="empty"><b>No photos here</b>Move the map or adjust your filters.</div>';
      return;
    }
    const totals = new Map();
    for (const p of areaList) totals.set(p.date.toDateString(), (totals.get(p.date.toDateString()) || 0) + 1);
    let html = "", current = "";
    for (const p of areaList) {
      const k = p.date.toDateString();
      if (k !== current) {
        if (current) html += "</div>";
        current = k;
        html += `<div class="day"><b>${dayFormat.format(p.date)}</b><span>${num.format(totals.get(k))}</span></div><div class="tiles">`;
      }
      html += `<button class="tile${marked === p ? " selected" : ""}" data-id="${p.id}" aria-label="Photo, ${fullFormat.format(p.date)}"><img src="photos/thumbs/${p.f}.jpg" alt="" loading="lazy" decoding="async"></button>`;
    }
    gallery.innerHTML = html + "</div>";
  }

  const tileFor = (p) => gallery.querySelector(`.tile[data-id="${p.id}"]`);

  function markPhoto(p) {
    marked = p;
    for (const el of gallery.querySelectorAll(".tile.selected")) el.classList.remove("selected");
    tileFor(p)?.classList.add("selected");
    map.triggerRepaint();
  }

  function selectAt(point) {
    const ll = map.unproject(point), m = maplibregl.MercatorCoordinate.fromLngLat(ll);
    const r = 28 / worldSize();
    if (!photos.some((p) => (p.mx - m.x) ** 2 + (p.my - m.y) ** 2 <= r * r)) return false;
    selection = { lng: ll.lng, lat: ll.lat, mx: m.x, my: m.y, r };
    marked = null;
    updateArea();
    renderGallery();
    map.triggerRepaint();
    return true;
  }

  function clearSelection() {
    selection = null;
    updateArea();
    renderGallery();
    map.triggerRepaint();
  }

  map.on("click", (e) => selectAt(e.point));
  gallery.addEventListener("click", (e) => {
    const tile = e.target.closest(".tile");
    if (tile) markPhoto(photos[+tile.dataset.id]);
  });
  gallery.addEventListener("dblclick", (e) => {
    const tile = e.target.closest(".tile");
    if (tile) openViewer(photos[+tile.dataset.id]);
  });
  gallery.addEventListener("keydown", (e) => {
    const tile = e.target.closest(".tile");
    if (tile && (e.key === " " || e.key === "Enter")) {
      e.preventDefault();
      markPhoto(photos[+tile.dataset.id]);
      openViewer(photos[+tile.dataset.id]);
    }
  });
  $("back-to-area").addEventListener("click", clearSelection);
  $("toggle-gallery").addEventListener("click", () => {
    panel.classList.toggle("collapsed");
    $("toggle-gallery").setAttribute("aria-label", panelOpen() ? "Collapse photo gallery" : "Show photo gallery");
    updateArea();
    galleryKey = "";
    renderGallery();
  });

  // Map controls

  function areaCenter() {
    const a = freeRect();
    return map.unproject([(a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2]);
  }
  const allBounds = () => photos.reduce((b, p) => b.extend([p.lon, p.lat]), new maplibregl.LngLatBounds([photos[0].lon, photos[0].lat], [photos[0].lon, photos[0].lat]));
  const ms = (d) => (reduced ? 0 : d);

  $("zoom-in").addEventListener("click", () => map.easeTo({ zoom: map.getZoom() + 1, around: areaCenter(), duration: ms(300) }));
  $("zoom-out").addEventListener("click", () => map.easeTo({ zoom: map.getZoom() - 1, around: areaCenter(), duration: ms(300) }));
  $("fit").addEventListener("click", () => map.fitBounds(allBounds(), { padding: padding(), duration: ms(700) }));

  const menu = $("map-menu"), menuBtn = $("map-menu-btn");
  function closeMenu() {
    menu.hidden = true;
    menuBtn.setAttribute("aria-expanded", "false");
  }
  menuBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
    menuBtn.setAttribute("aria-expanded", String(!menu.hidden));
    if (!menu.hidden) menu.querySelector("button").focus();
  });
  menu.addEventListener("click", (e) => {
    const item = e.target.closest("button");
    if (!item) return;
    showHeatmap = !showHeatmap;
    item.setAttribute("aria-checked", String(showHeatmap));
    $("legend").hidden = !showHeatmap;
    closeMenu();
    map.triggerRepaint();
  });
  document.addEventListener("click", (e) => {
    if (!menu.hidden && !menu.contains(e.target)) closeMenu();
  });

  // Place search

  const searchInput = $("search-input"), results = $("search-results");
  const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
  let matches = [], active = 0;

  function showResults() {
    const q = fold(searchInput.value.trim());
    if (!q) {
      results.hidden = true;
      return;
    }
    matches = PLACES.filter((p) => fold(p.name + " " + p.sub).includes(q));
    active = 0;
    results.innerHTML = matches.length
      ? matches.map((p, i) => `<button role="option" data-i="${i}" aria-selected="${i === 0}">${p.name}<span>${p.sub}</span></button>`).join("")
      : '<div class="none">No places found</div>';
    results.hidden = false;
  }

  function goTo(place) {
    results.hidden = true;
    searchInput.value = "";
    searchInput.blur();
    clearSelection();
    if (place.bounds) map.fitBounds(place.bounds, { padding: padding(), duration: ms(900) });
    else {
      const a = freeRect();
      map.flyTo({ center: place.center, zoom: place.zoom, offset: [(a.x0 + a.x1) / 2 - W / 2, (a.y0 + a.y1) / 2 - H / 2], duration: ms(1100) });
    }
  }

  searchInput.addEventListener("input", showResults);
  searchInput.addEventListener("keydown", (e) => {
    if (results.hidden) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      active = (active + (e.key === "ArrowDown" ? 1 : -1) + matches.length) % Math.max(1, matches.length);
      results.querySelectorAll("button").forEach((b, i) => b.setAttribute("aria-selected", String(i === active)));
    } else if (e.key === "Enter" && matches[active]) {
      goTo(matches[active]);
    } else if (e.key === "Escape") {
      results.hidden = true;
    }
  });
  results.addEventListener("mousedown", (e) => {
    const b = e.target.closest("button");
    if (b) {
      e.preventDefault();
      goTo(matches[+b.dataset.i]);
    }
  });
  searchInput.addEventListener("blur", () => setTimeout(() => { results.hidden = true; }, 100));

  // Viewer

  const viewer = $("viewer"), viewerStage = $("viewer-stage"), viewerPhoto = $("viewer-photo");
  const zoomInput = $("viewer-zoom"), info = $("viewer-info");
  const view = { list: [], index: 0, zoom: 1, px: 0, py: 0 };

  function layoutPhoto(instant) {
    const p = view.list[view.index];
    const sw = viewerStage.clientWidth - 32, sh = viewerStage.clientHeight - 32;
    const fit = Math.min(sw / p.w, sh / p.h), w = p.w * fit, h = p.h * fit;
    const maxX = Math.max(0, (w * view.zoom - sw) / 2), maxY = Math.max(0, (h * view.zoom - sh) / 2);
    view.px = Math.max(-maxX, Math.min(maxX, view.px));
    view.py = Math.max(-maxY, Math.min(maxY, view.py));
    viewerPhoto.classList.toggle("instant", !!instant);
    viewerPhoto.style.width = `${w}px`;
    viewerPhoto.style.height = `${h}px`;
    viewerPhoto.style.transform = `translate(-50%, -50%) translate(${view.px}px, ${view.py}px) scale(${view.zoom})`;
    viewerStage.classList.toggle("zoomed", view.zoom > 1.01);
    zoomInput.value = view.zoom;
  }

  function showPhoto() {
    const p = view.list[view.index];
    view.zoom = 1;
    view.px = view.py = 0;
    viewerPhoto.classList.add("loading");
    viewerPhoto.onload = () => viewerPhoto.classList.remove("loading");
    viewerPhoto.src = `photos/${p.f}.jpg`;
    if (viewerPhoto.complete) viewerPhoto.classList.remove("loading");
    $("viewer-date").textContent = fullFormat.format(p.date);
    $("viewer-pos").textContent = `${num.format(view.index + 1)} of ${num.format(view.list.length)}`;
    $("viewer-fav").hidden = !p.fav;
    info.innerHTML = `<dt>Name</dt><dd>${p.name}</dd><dt>Date</dt><dd>${fullFormat.format(p.date)}</dd><dt>Size</dt><dd>${p.w} × ${p.h}</dd><dt>Location</dt><dd>${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}</dd>`;
    layoutPhoto(true);
    if (marked !== p) markPhoto(p);
    const next = view.list[view.index + 1];
    if (next) new Image().src = `photos/${next.f}.jpg`;
  }

  function openViewer(p) {
    view.list = areaList.includes(p) ? areaList : [p];
    view.index = view.list.indexOf(p);
    viewer.hidden = false;
    info.hidden = true;
    $("viewer-info-btn").setAttribute("aria-expanded", "false");
    showPhoto();
    $("viewer-back").focus({ preventScroll: true });
  }

  function closeViewer() {
    if (viewer.hidden) return;
    viewer.hidden = true;
    const tile = tileFor(view.list[view.index]);
    if (tile) {
      tile.focus({ preventScroll: true });
      tile.scrollIntoView({ block: "nearest" });
    }
  }

  function setZoom(z, instant) {
    view.zoom = Math.min(8, Math.max(1, z));
    if (view.zoom === 1) view.px = view.py = 0;
    layoutPhoto(instant);
  }

  function step(delta) {
    const next = view.index + delta;
    if (next < 0 || next >= view.list.length) return;
    view.index = next;
    showPhoto();
  }

  $("viewer-back").addEventListener("click", closeViewer);
  $("viewer-info-btn").addEventListener("click", () => {
    info.hidden = !info.hidden;
    $("viewer-info-btn").setAttribute("aria-expanded", String(!info.hidden));
  });
  zoomInput.addEventListener("input", () => setZoom(+zoomInput.value, true));
  viewerStage.addEventListener("dblclick", () => setZoom(view.zoom > 1.01 ? 1 : 2.5));

  let photoDrag = null;
  viewerStage.addEventListener("pointerdown", (e) => {
    if (view.zoom <= 1.01) return;
    viewerStage.setPointerCapture(e.pointerId);
    photoDrag = { x: e.clientX, y: e.clientY };
  });
  viewerStage.addEventListener("pointermove", (e) => {
    if (!photoDrag) return;
    view.px += e.clientX - photoDrag.x;
    view.py += e.clientY - photoDrag.y;
    photoDrag = { x: e.clientX, y: e.clientY };
    layoutPhoto(true);
  });
  viewerStage.addEventListener("pointerup", () => { photoDrag = null; });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !menu.hidden) {
      closeMenu();
      menuBtn.focus();
      return;
    }
    if (viewer.hidden || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target === zoomInput && e.key.startsWith("Arrow")) return;
    const keys = {
      Escape: closeViewer, " ": closeViewer,
      ArrowLeft: () => step(-1), ArrowRight: () => step(1),
      "+": () => setZoom(view.zoom * 1.5), "=": () => setZoom(view.zoom * 1.5), "-": () => setZoom(view.zoom / 1.5),
      0: () => setZoom(1), i: () => $("viewer-info-btn").click(),
    };
    const action = keys[e.key];
    if (!action) return;
    if (e.key === " " && e.target.tagName === "BUTTON" && e.target !== $("viewer-back")) return;
    e.preventDefault();
    action();
  });

  // Demo: a cursor walks through the main path until the visitor takes over.

  const cursor = $("cursor");
  const CANCELLED = Symbol("cancelled");
  let run = 0, at = null, demoOn = false;
  const running = new Set();

  const pause = (r, ms) => new Promise((res, rej) => setTimeout(() => (r === run ? res() : rej(CANCELLED)), ms));
  const inStage = (x, y) => {
    const w = win.getBoundingClientRect(), s = stage.getBoundingClientRect();
    return { x: w.left - s.left + x, y: w.top - s.top + y };
  };
  const ofElement = (el, ax = 0.5, ay = 0.5) => {
    const b = el.getBoundingClientRect(), s = stage.getBoundingClientRect();
    return { x: b.left - s.left + b.width * ax, y: b.top - s.top + b.height * ay };
  };
  const place = (p) => `translate(${p.x}px, ${p.y}px)`;

  async function move(r, to) {
    const from = at || to;
    at = to;
    const duration = Math.min(1200, Math.max(450, Math.hypot(to.x - from.x, to.y - from.y) * 1.6));
    const a = cursor.animate([{ transform: place(from) }, { transform: place(to) }], { duration, easing: "cubic-bezier(.45,0,.2,1)", fill: "forwards" });
    running.add(a);
    await a.finished.catch(() => {});
    running.delete(a);
    if (r !== run) throw CANCELLED;
  }

  async function click(r, el) {
    cursor.classList.remove("click");
    void cursor.offsetWidth;
    cursor.classList.add("click");
    el?.classList.add("pressed");
    await pause(r, 160);
    el?.classList.remove("pressed");
  }

  const settle = (r) => new Promise((res, rej) => {
    const done = () => (r === run ? res() : rej(CANCELLED));
    if (!map.isMoving()) setTimeout(done, 50);
    else map.once("moveend", done);
  });

  function spotPoint(name) {
    const s = SPOTS[name];
    const pt = map.project([s.lon, s.lat]);
    return { pt, stagePt: inStage(pt.x, pt.y) };
  }

  function resetScene() {
    closeViewer();
    closeMenu();
    marked = null;
    if (!panelOpen()) panel.classList.remove("collapsed");
    map.fitBounds(CITY, { padding: padding(), duration: 0 });
    clearSelection();
  }

  async function demo(r) {
    resetScene();
    at = inStage(W * 0.72, H * 0.7);
    cursor.style.transform = place(at);
    cursor.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300, fill: "forwards" });
    await pause(r, 1200);

    // Pick the busiest spot in the city.
    let s = spotPoint("comercio");
    await move(r, s.stagePt);
    await click(r);
    selectAt(s.pt);
    await pause(r, 1500);

    // Mark a photo, then open it.
    const tile = gallery.querySelectorAll(".tile")[1] || gallery.querySelector(".tile");
    if (tile) {
      await move(r, ofElement(tile));
      await click(r);
      markPhoto(photos[+tile.dataset.id]);
      await pause(r, 600);
      await click(r);
      await click(r);
      openViewer(photos[+tile.dataset.id]);
      await pause(r, 1600);
      step(1);
      await pause(r, 1400);
      step(1);
      await pause(r, 1500);
      const back = $("viewer-back");
      await move(r, ofElement(back));
      await click(r, back);
      closeViewer();
      await pause(r, 700);
    }

    // Back to the map area, then show every photo.
    const link = $("back-to-area");
    await move(r, ofElement(link, 0.3));
    await click(r, link);
    clearSelection();
    await pause(r, 700);
    const fit = $("fit");
    await move(r, ofElement(fit));
    await click(r, fit);
    map.fitBounds(allBounds(), { padding: padding(), duration: 1400 });
    await settle(r);
    await pause(r, 1000);

    // Select Sintra.
    s = spotPoint("pena");
    await move(r, s.stagePt);
    await click(r);
    selectAt(s.pt);
    await pause(r, 2600);

    await move(r, ofElement(link, 0.3));
    await click(r, link);
    clearSelection();
    map.fitBounds(CITY, { padding: padding(), duration: 1600 });
    await settle(r);
    await pause(r, 1800);
  }

  async function loop() {
    const r = ++run;
    demoOn = true;
    try {
      for (;;) await demo(r);
    } catch (e) {
      if (e !== CANCELLED) throw e;
    }
  }

  // The visitor takes over for good: restarting would move the map out from under them.
  function stopDemo() {
    if (!demoOn) return;
    demoOn = false;
    run++;
    for (const a of running) a.cancel();
    running.clear();
    cursor.getAnimations().forEach((a) => a.cancel());
    cursor.style.opacity = "0";
  }

  for (const type of ["pointerdown", "wheel", "touchstart"]) win.addEventListener(type, (e) => e.isTrusted && stopDemo(), { passive: true, capture: true });
  win.addEventListener("keydown", (e) => e.isTrusted && stopDemo(), true);

  // Start

  new ResizeObserver(() => {
    const before = W + "x" + H;
    sizeHeat();
    if (before === W + "x" + H) return;
    map.resize();
    updateArea();
    renderGallery();
    if (!viewer.hidden) layoutPhoto(true);
  }).observe(win);

  sizeHeat();
  updateArea();
  renderGallery();
  map.once("load", () => {
    map.fitBounds(CITY, { padding: padding(), duration: 0 });
    updateArea();
    renderGallery();
    if (!reduced) setTimeout(() => run || loop(), 600);
  });
})();
