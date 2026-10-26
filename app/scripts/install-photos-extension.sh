#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
derived_path="${PHOTO_ATLAS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PhotoAtlas}"
if [[ "${1:-}" != "--no-build" ]]; then
  ./scripts/build-run.sh --build-only
fi
app_path="$derived_path/Build/Products/Release/libhm.app"
extension_path="$app_path/Contents/PlugIns/HeatmapProject.appex"
codesign --verify --deep --strict "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
pluginkit -a "$extension_path"
pluginkit -e use -i com.hikariatama.PhotoAtlas.HeatmapProject
pluginkit -m -v -i com.hikariatama.PhotoAtlas.HeatmapProject
