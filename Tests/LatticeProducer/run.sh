#!/bin/bash
# Compile unchanged Lattice producer sources, then run the existing Sentient app in headless mode.
set -euo pipefail
umask 077
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
lattice_root="${LATTICE_ROOT:-$(dirname "$repo_root")/Lattice}"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
sentient_binary="${SENTIENT_BINARY:-$repo_root/.build/baseline/Build/Products/Debug/Sentient OS.app/Contents/MacOS/Sentient OS}"
python_binary="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
if [[ ! -x "$sentient_binary" ]]; then
    echo 'An existing Debug Sentient binary is required; this harness does not build or launch the GUI.' >&2
    exit 2
fi
mkdir -p "$repo_root/.build"
build_dir="$(mktemp -d "$repo_root/.build/lattice-producer.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
core="$lattice_root/Packages/LatticeCore/Sources/LatticeCore"
"$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -sdk "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    -target arm64-apple-macos15.0 -swift-version 5 -parse-as-library \
    "$core/RDWorkspace.swift" "$core/ActivityTimeline.swift" \
    "$core/Markdown/NoteParsing.swift" "$core/Persistence/ContentDigest.swift" \
    "$repo_root/Tests/LatticeProducer/ProduceCapsule.swift" -o "$build_dir/produce-capsule"
"$build_dir/produce-capsule" "$build_dir/native-capsule.json"
"$python_binary" "$repo_root/Tests/LatticeProducer/verify.py" "$sentient_binary" "$build_dir"
