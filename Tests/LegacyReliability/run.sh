#!/bin/bash
# Compiles real production sources into an isolated CLI; no app launch or live stores are used.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_path="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sentient-reliability-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app_sources="$repo_root/Sentient OS macOS"
"$swift_compiler" -sdk "$sdk_path" -target arm64-apple-macos15.0 -swift-version 5 \
    -default-isolation MainActor -parse-as-library -g -o "$build_dir/legacy-reliability" \
    "$repo_root/Tests/LegacyReliability/Stubs.swift" \
    "$app_sources/Sources/DataSource.swift" "$app_sources/Ingestion/ItemKey.swift" \
    "$app_sources/Ingestion/Connector.swift" "$app_sources/Engine/Verdict.swift" \
    "$app_sources/Engine/PIIScan.swift" "$app_sources/Engine/Triage.swift" \
    "$app_sources/Ingestion/CycleStore.swift" "$app_sources/Ingestion/IterativeRun.swift" \
    "$app_sources/Sources/SQLiteDB.swift" \
    "$repo_root/Tests/LegacyReliability/LegacyReliabilityTests.swift"
"$build_dir/legacy-reliability" "$@"
