#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
derived_path="${PHOTO_ATLAS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/PhotoAtlas}"
mkdir -p "$derived_path"
derived_path="$(cd "$derived_path" && pwd)"
source_path="$derived_path/Source"
mkdir -p "$source_path"
for folder in Sources Config Tests; do
  rsync -a --delete "$folder/" "$source_path/$folder/"
done
cp project.yml "$source_path/project.yml"
cd "$source_path"
xcodegen generate
xcodebuild -project PhotoAtlas.xcodeproj -scheme PhotoAtlas -configuration Release \
  -derivedDataPath "$derived_path" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
app_path="$derived_path/Build/Products/Release/libhm.app"
codesign --verify --deep --strict "$app_path"
if [[ "${1:-}" != "--build-only" ]]; then
  /usr/bin/open -a "$app_path" --args "$@"
fi
