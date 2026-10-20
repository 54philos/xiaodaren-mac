#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PEN_BUILD_DIR:-$SOURCE_DIR/.build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
FLAGS=(-swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" -module-cache-path "$BUILD_DIR/OverlayModuleCache")
# Some Command Line Tools installations contain two identical SwiftBridging
# module maps. Hide the obsolete duplicate in this build only; never edit CLT.
MAP_ROOT="$(xcode-select -p)/usr/include/swift"
if [ -f "$MAP_ROOT/module.modulemap" ] && [ -f "$MAP_ROOT/bridging.modulemap" ] && python3 - "$MAP_ROOT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
def code(name):
    return ''.join(line.strip() for line in (p/name).read_text().splitlines() if not line.strip().startswith('//'))
sys.exit(0 if code('module.modulemap') == code('bridging.modulemap') else 1)
PY
then
    printf '// obsolete duplicate hidden by a local VFS overlay\n' > "$BUILD_DIR/empty.modulemap"
    python3 - "$MAP_ROOT/module.modulemap" "$BUILD_DIR" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[2])
(root/'overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':str(root/'empty.modulemap')}]}))
PY
    FLAGS+=(-vfsoverlay "$BUILD_DIR/overlay.json" -Xcc -ivfsoverlay -Xcc "$BUILD_DIR/overlay.json")
fi
if [ "${1:-build}" = test ]; then
    env -u CPATH xcrun swiftc "${FLAGS[@]}" "$SOURCE_DIR/Sources/PenCore.swift" "$SOURCE_DIR/Tests/CoreTests.swift" -o "$BUILD_DIR/CoreTests"
    shift
    "$BUILD_DIR/CoreTests" "$@"
    exit 0
fi
APP_DIR="${PEN_APP_DIR:-$SOURCE_DIR/dist/点读伙伴.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
env -u CPATH xcrun swiftc "${FLAGS[@]}" -O "$SOURCE_DIR/Sources/PenCore.swift" "$SOURCE_DIR/Sources/PenApp.swift" -o "$APP_DIR/Contents/MacOS/TalkingPen"
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SOURCE_DIR/THIRD_PARTY_LICENSE.txt" "$APP_DIR/Contents/Resources/THIRD_PARTY_LICENSE.txt"
cp "$SOURCE_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$SOURCE_DIR/Assets/BrandMark.png" "$APP_DIR/Contents/Resources/BrandMark.png"
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
