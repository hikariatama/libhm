"""Read-only artifact checks shared by local packaging and macOS CI."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from ds_store import DSStore


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


image, source, layout_path, banner, artwork_verifier = map(Path, sys.argv[1:])
layout = json.loads(layout_path.read_text())
with tempfile.TemporaryDirectory(prefix="libhm-dmg-check-", dir="/tmp") as temporary:
    mount = Path(temporary)
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)],
                   check=True, stdout=subprocess.DEVNULL)
    try:
        payload = mount / "libhm.app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(payload)], check=True)
        require((mount / "Applications").is_symlink(), "Applications must be a live symlink")
        require(os.readlink(mount / "Applications") == "/Applications", "Wrong Applications target")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            origin_x, origin_y = layout["window_origin"]
            width = layout["content_width"]
            frame_height = layout["content_height"] + layout["title_bar_height"]
            require(window["WindowBounds"] ==
                    f"{{{{{origin_x}, {origin_y}}}, {{{width}, {frame_height}}}}}", "Incorrect full window frame")
            for key in ("ContainerShowSidebar", "ShowSidebar", "ShowToolbar", "ShowTabView", "ShowPathbar", "ShowStatusBar"):
                require(window[key] is False, f"Unexpected Finder chrome: {key}")
            view = store["."]["icvp"]
            require(store["."]["icvl"] == (b"type", b"icnv"), "Default view must be icons")
            require(view["backgroundType"] == 2 and view["backgroundImageAlias"], "Missing background image")
            require(view["iconSize"] == layout["icon_size"], "Incorrect icon size")
            require(view["textSize"] == layout["text_size"] and view["labelOnBottom"], "Incorrect labels")
            require(view["arrangeBy"] == "none", "Finder must preserve fixed positions")
            require(view["scrollPositionX"] == view["scrollPositionY"] == 0, "Content must not be scrolled")
            require(view["gridOffsetX"] == view["gridOffsetY"] == 0, "Unexpected coordinate offset")
            for name, point in layout["icon_locations"].items():
                require(store[name]["Iloc"] == tuple(point), f"Incorrect content coordinates: {name}")
        files = {p.relative_to(source): p for p in source.rglob("*") if p.is_file()}
        require(set(files) == {p.relative_to(payload) for p in payload.rglob("*") if p.is_file()},
                "App payload file list differs")
        for relative, path in files.items():
            require(digest(path) == digest(payload / relative), f"Changed app payload: {relative}")
        subprocess.run(["swift", str(artwork_verifier), str(banner), str(mount / ".background.tiff"),
                        str(layout_path)], check=True)
        print(f"Finder layout and {len(files)} unchanged app files verified.")
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
print(f"SHA-256: {digest(image)}")
