#!/bin/bash
# Real mirror/archive/projection behavior with synthetic stores and an in-memory transport.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sentient-mirror-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app_sources="$repo_root/Sentient OS macOS"
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -sdk "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    -target arm64-apple-macos15.0 -swift-version 5 -default-isolation MainActor -parse-as-library \
    "$app_sources/Cloud/MirrorClient.swift" "$app_sources/Cloud/MirrorArchive.swift" \
    "$app_sources/Context/ContextTypes.swift" "$app_sources/Context/EvidencePrivacy.swift" \
    "$app_sources/Context/EvidenceStore.swift" "$app_sources/Context/ContextRetrieval.swift" \
    "$app_sources/Context/ContextProjection.swift" \
    "$repo_root/Tests/MirrorReliability/MirrorReliabilityTests.swift" -o "$build_dir/mirror-tests"
"$build_dir/mirror-tests" "$@"
