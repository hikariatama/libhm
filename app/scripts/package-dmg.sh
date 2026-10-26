#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
project_path="$PWD"
derived_path="${PHOTO_ATLAS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PhotoAtlas}"
app_path="${1:-$derived_path/Build/Products/Release/libhm.app}"
output_path="${2:-$project_path/dist/libhm.dmg}"
app_path="$(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")"
mkdir -p "$(dirname "$output_path")"
output_path="$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")"
codesign --verify --deep --strict "$app_path"

# Keep build tools and mounted-image staging outside iCloud.
venv_path="${LIBHM_DMG_VENV:-$HOME/Library/Caches/libhm-packaging/venv}"
if [[ ! -x "$venv_path/bin/python" ]]; then
  python3 -m venv "$venv_path"
fi
"$venv_path/bin/python" -m pip install --quiet -r Packaging/requirements.txt
staging_path="$(mktemp -d /tmp/libhm-dmg.XXXXXX)"
trap 'rm -rf "$staging_path"' EXIT
swift Packaging/render-background.swift "$app_path" "$project_path/Packaging/layout.json" \
  "$project_path/Packaging/banner@2x.png" "$staging_path/artwork"
"$venv_path/bin/dmgbuild" -s Packaging/dmg-settings.py \
  -D "app=$app_path" -D "artwork=$staging_path/artwork" -D "layout=$project_path/Packaging/layout.json" \
  libhm "$staging_path/libhm.dmg"
hdiutil verify "$staging_path/libhm.dmg"
"$venv_path/bin/python" Packaging/verify-dmg.py "$staging_path/libhm.dmg" "$app_path" \
  "$project_path/Packaging/layout.json" "$project_path/Packaging/banner@2x.png" \
  "$project_path/Packaging/verify-background.swift"
mkdir -p "$project_path/dist/dmg-preview"
cp "$staging_path/artwork/installer-preview.png" "$project_path/dist/dmg-preview/installer-preview.png"
# Replace a previous artifact only after image verification succeeds.
temporary_output="$output_path.partial"
cp "$staging_path/libhm.dmg" "$temporary_output"
mv -f "$temporary_output" "$output_path"
print -r -- "$output_path"
