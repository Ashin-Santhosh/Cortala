#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-env.sh"
TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
TEST_OPTIONS=(--disable-xctest --enable-swift-testing
    -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS"
    -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"
    -Xlinker -F -Xlinker "$TEST_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS")
# CLT 6.2.1 can ship a Foundation cross-import overlay declaration without its
# module. These tests use Testing's core assertions and Foundation directly.
if [[ ! -d "$TEST_FRAMEWORKS/_Testing_Foundation.framework/Modules" ]]; then
    TEST_OPTIONS+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi
swift test "${SWIFT_OPTIONS[@]}" "${TEST_OPTIONS[@]}" "$@"
