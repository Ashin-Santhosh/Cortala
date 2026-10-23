#!/bin/bash
set -euo pipefail
ICON_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_SOURCE="$ICON_PROJECT_ROOT/Assets/JustWisper-icon.png"
ICON_OUTPUT="$ICON_PROJECT_ROOT/.build/Assets/JustWisper.icns"
ICON_WORK="$ICON_PROJECT_ROOT/.build/Assets/JustWisper.iconset"
if [[ ! -f "$ICON_OUTPUT" || "$ICON_SOURCE" -nt "$ICON_OUTPUT" || "${BASH_SOURCE[0]}" -nt "$ICON_OUTPUT" ]]; then
    mkdir -p "$ICON_WORK"
    for ICON_SIZE in 16 32 128 256 512; do
        sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_WORK/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
        ICON_DOUBLE=$((ICON_SIZE * 2))
        sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" --out "$ICON_WORK/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
    done
    if ! iconutil -c icns "$ICON_WORK" -o "$ICON_OUTPUT" 2>"$ICON_PROJECT_ROOT/.build/Assets/iconutil.log"; then
        # Some restricted CLT sessions cannot access iconutil's image service.
        # Modern ICNS entries contain the original scaled PNG bytes verbatim.
        python3 - "$ICON_WORK" "$ICON_OUTPUT" <<'PYICON'
import pathlib, struct, sys
source, output = map(pathlib.Path, sys.argv[1:])
entries = [('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
           ('icp6', 'icon_32x32@2x.png'), ('ic07', 'icon_128x128.png'),
           ('ic08', 'icon_256x256.png'), ('ic09', 'icon_512x512.png'),
           ('ic10', 'icon_512x512@2x.png'), ('ic11', 'icon_16x16@2x.png'),
           ('ic12', 'icon_32x32@2x.png'), ('ic13', 'icon_128x128@2x.png'),
           ('ic14', 'icon_256x256@2x.png')]
chunks = []
for kind, filename in entries:
    data = (source / filename).read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
output.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
PYICON
    fi
fi
printf '%s\n' "$ICON_OUTPUT"
