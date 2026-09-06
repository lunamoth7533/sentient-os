#!/bin/bash
# Compile the same context sources as the app, then execute XCTest explicitly.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
export SDKROOT="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export DYLD_FRAMEWORK_PATH="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib"
swift_bin="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
cd "$repo_root"
"$swift_bin" build --build-tests --scratch-path .build/context-tests
test_bundle="$repo_root/.build/context-tests/out/Products/Debug/ContextTests.xctest"
if [[ ! -d "$test_bundle" ]]; then
    test_bundle="$repo_root/.build/context-tests/arm64-apple-macosx/debug/SentientContextPackageTests.xctest"
fi
"$developer_dir/usr/bin/xctest" "$test_bundle"
