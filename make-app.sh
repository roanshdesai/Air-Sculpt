#!/bin/zsh
# Builds AirSculpt in release mode and wraps it into a proper AirSculpt.app
# bundle (nicer camera-permission attribution and a real Dock presence than
# running the bare executable via `swift run`).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="AirSculpt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AirSculpt "$APP/Contents/MacOS/AirSculpt"
cp Sources/AirSculpt/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so TCC (camera permission) treats the app as a stable identity.
codesign --force --sign - "$APP"

echo "Built $PWD/$APP — launch with: open $APP"
