#!/bin/bash
# Shared project-local compiler caches and repair for duplicate CLT module maps.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p .build/ModuleCache .build/swiftpm-cache .build/swiftpm-config .build/swiftpm-security .build/toolchain
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
SWIFT_OPTIONS=(--disable-sandbox --cache-path "$PROJECT_ROOT/.build/swiftpm-cache" --config-path "$PROJECT_ROOT/.build/swiftpm-config" --security-path "$PROJECT_ROOT/.build/swiftpm-security" --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache")
DEVELOPER_DIR_PATH="$(xcode-select -p)"
# Some upgraded CLT installations retain private SwiftPM interfaces from an older
# compiler. Swift prefers those over the current public interfaces, then fails to
# link Package.swift against the current library. Use a local API view when the
# interface compiler versions disagree; never change the installed toolchain.
MANIFEST_API="$DEVELOPER_DIR_PATH/usr/lib/swift/pm/ManifestAPI"
if python3 - "$MANIFEST_API" "$PROJECT_ROOT/.build/toolchain/swiftpm" <<'PY'
import pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
module = source / 'PackageDescription.swiftmodule'
def compiler_version(path):
    return next((line for line in path.read_text().splitlines() if line.startswith('// swift-compiler-version:')), '')
stale = any(
    public.exists() and compiler_version(private) != compiler_version(public)
    for private in module.glob('*.private.swiftinterface')
    for public in [private.with_name(private.name.replace('.private.swiftinterface', '.swiftinterface'))]
)
if not stale:
    sys.exit(1)
local_api = destination / 'ManifestAPI'
local_module = local_api / 'PackageDescription.swiftmodule'
local_module.mkdir(parents=True, exist_ok=True)
for interface in module.glob('*.swiftinterface'):
    if '.private.' not in interface.name:
        shutil.copy2(interface, local_module / interface.name)
for name in ('libPackageDescription.dylib', 'CompilerPluginSupport.swiftmodule'):
    link = local_api / name
    if not link.exists():
        link.symlink_to(source / name)
PY
then
    export SWIFTPM_CUSTOM_LIBS_DIR="$PROJECT_ROOT/.build/toolchain/swiftpm"
fi
LEGACY_MAP="$DEVELOPER_DIR_PATH/usr/include/swift/module.modulemap"
BRIDGING_MAP="$DEVELOPER_DIR_PATH/usr/include/swift/bridging.modulemap"
if [[ -f "$LEGACY_MAP" && -f "$BRIDGING_MAP" ]] && grep -q 'module SwiftBridging' "$LEGACY_MAP" && grep -q 'module SwiftBridging' "$BRIDGING_MAP"; then
    # Hide only the duplicate legacy map through a compiler VFS overlay.
    # The installed toolchain remains untouched.
    : > .build/toolchain/empty.modulemap
    python3 - "$LEGACY_MAP" "$PROJECT_ROOT" <<'PY'
import json, pathlib, sys
legacy, root = sys.argv[1:]
out = pathlib.Path(root) / '.build/toolchain/overlay.json'
out.write_text(json.dumps({'version': 0, 'roots': [{'type': 'file', 'name': legacy, 'external-contents': root + '/.build/toolchain/empty.modulemap'}]}))
PY
    SWIFT_OPTIONS+=(-Xswiftc -vfsoverlay -Xswiftc "$PROJECT_ROOT/.build/toolchain/overlay.json")
fi

# SwiftPM evaluates dependency manifests before -Xswiftc build flags apply.
# A local compiler shim gives those evaluations the same duplicate-map repair.
if [[ -f "$PROJECT_ROOT/.build/toolchain/overlay.json" ]]; then
    SWIFT_REAL_COMPILER="$DEVELOPER_DIR_PATH/usr/bin/swiftc"
    cat > "$PROJECT_ROOT/.build/toolchain/swiftc" <<SHIM
#!/bin/bash
exec "$SWIFT_REAL_COMPILER" -vfsoverlay "$PROJECT_ROOT/.build/toolchain/overlay.json" "\$@"
SHIM
    chmod +x "$PROJECT_ROOT/.build/toolchain/swiftc"
    export SWIFT_EXEC="$PROJECT_ROOT/.build/toolchain/swiftc"
fi
