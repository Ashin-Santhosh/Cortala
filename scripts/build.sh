#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
CONFIGURATION="${1:-release}"
swift build "${SWIFT_OPTIONS[@]}" -c "$CONFIGURATION"
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" -c "$CONFIGURATION" --show-bin-path)"
APP="$PROJECT_ROOT/dist/JustWhisper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/JustWhisper" "$APP/Contents/MacOS/JustWhisper"
# SwiftPM may embed an absolute toolchain search path under the build directory.
# The release uses system Swift libraries; keep only portable/system rpaths.
python3 - "$APP/Contents/MacOS/JustWhisper" <<'PY'
import re, subprocess, sys
executable = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', executable], text=True)
paths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', commands)
for path in paths:
    if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
        subprocess.run(['install_name_tool', '-delete_rpath', path, executable], check=True)
PY
cp "$PROJECT_ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
ICON_PATH="$("$PROJECT_ROOT/scripts/build-icon.sh")"
cp "$ICON_PATH" "$APP/Contents/Resources/JustWhisper.icns"
# FluidAudio's resource bundle serves only the unused LuxTts frontend.
# The offline diarizer loads the separately verified user-selected CoreML assets.
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
ditto "$PROJECT_ROOT/ThirdPartyNotices" "$APP/Contents/Resources/ThirdPartyNotices"
mkdir -p "$APP/Contents/Resources/CLI"
cp "$PROJECT_ROOT/tools/justwisper.py" "$APP/Contents/Resources/CLI/justwisper.py"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
