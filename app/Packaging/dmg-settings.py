from pathlib import Path
import json
import subprocess

app = Path(defines["app"]).resolve()
artwork = Path(defines["artwork"]).resolve()
layout = json.loads(Path(defines["layout"]).read_text())
format = "UDZO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
# SetFile's hidden-extension flag adds FinderInfo to the signed bundle and
# fails strict signature verification. Leave the bundle's metadata untouched.
hide_extensions = []
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(artwork / "background.png")
# Finder stores the full frame; artwork and icon positions use content coordinates.
# Apply the title-bar compensation only to the frame, never to the image or icons.
window_rect = (tuple(layout["window_origin"]),
    (layout["content_width"], layout["content_height"] + layout["title_bar_height"]))
icon_locations = {name: tuple(point) for name, point in layout["icon_locations"].items()}
icon_size = layout["icon_size"]
text_size = layout["text_size"]
label_pos = "bottom"
default_view = "icon-view"
arrange_by = None
grid_spacing = 64
grid_offset = (0, 0)
scroll_position = (0, 0)
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False


def create_hook(mount_point, options):
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(Path(mount_point) / app.name)],
        check=True,
    )
