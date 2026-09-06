#!/bin/bash
# Build the real vault, graph, model and simulation, without launching the app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sentient-graph-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -sdk "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    -target arm64-apple-macos15.0 -swift-version 5 -enable-bare-slash-regex -parse-as-library \
    "$repo_root/Sentient OS macOS/Views/Knowledge/VaultTree.swift" \
    "$repo_root/Sentient OS macOS/Views/Knowledge/Graph/SkyGraph.swift" \
    "$repo_root/Sentient OS macOS/Views/Knowledge/Graph/SkySimulation.swift" \
    "$repo_root/Sentient OS macOS/Views/Knowledge/Graph/NightSkyModel.swift" \
    "$repo_root/Tests/KnowledgeGraph/KnowledgeGraphTests.swift" -o "$build_dir/graph-tests"
"$build_dir/graph-tests"
