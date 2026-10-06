#!/bin/bash
# Builds build/PodViz.app.
#   ./build.sh            build only
#   ./build.sh --open     build and (re)launch
#   ./build.sh --install  build, copy to /Applications and launch from there
set -euo pipefail
cd "$(dirname "$0")"

APP=build/PodViz.app
swift build -c release --product PodViz
BIN="$(swift build -c release --show-bin-path)/PodViz"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "Generating icon…"
  mkdir -p build
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o build/AppIcon.icns
  rm -rf "$TMP"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PodViz"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The agent skill ships inside the bundle; ~/.claude/skills and ~/.codex/skills symlink to it.
mkdir -p "$APP/Contents/Resources/Agent-Skill"
cp -R Skill/podviz "$APP/Contents/Resources/Agent-Skill/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  pkill -x PodViz 2>/dev/null || true
  rm -rf /Applications/PodViz.app
  cp -R "$APP" /Applications/
  APP=/Applications/PodViz.app
  echo "Installed to $APP"
  open "$APP"
elif [[ " $* " == *" --open "* ]]; then
  pkill -x PodViz 2>/dev/null || true
  open "$APP"
fi
