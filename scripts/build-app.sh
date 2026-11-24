#!/bin/zsh
# Builds a Release copy of Volumist at dist/Volumist.app.
# Pass --install to also copy it into /Applications (replacing an older copy).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

xcodebuild \
  -project Volumist.xcodeproj \
  -scheme Volumist \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

rm -rf dist/Volumist.app
mkdir -p dist
ditto build/DerivedData/Build/Products/Release/Volumist.app dist/Volumist.app
codesign --verify --deep --strict dist/Volumist.app
echo "Built $ROOT/dist/Volumist.app"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Volumist || true
  rm -rf /Applications/Volumist.app
  ditto dist/Volumist.app /Applications/Volumist.app
  echo "Installed /Applications/Volumist.app"
fi
