#!/bin/bash
# Build the Xcode app and launch its isolated local-context workspace, preserving live app state.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
mode="${1:-run}"
case "$mode" in run|--build-only|--verify) ;; *) echo "Usage: $0 [--build-only|--verify]" >&2; exit 2 ;; esac
app_bundle="$repo_root/.build/baseline/Build/Products/Debug/Sentient OS.app"
context_root="$repo_root/.build/context-workspace"
mkdir -p "$context_root"
chmod 700 "$context_root"
if [[ -f "$context_root/context.pid" ]]; then
    prior_pid="$(cat "$context_root/context.pid")"
    if [[ "$prior_pid" =~ ^[0-9]+$ ]] && [[ "$(ps -p "$prior_pid" -o comm= 2>/dev/null || true)" == "$app_bundle/Contents/MacOS/Sentient OS" ]]; then
        kill "$prior_pid" 2>/dev/null || true
    fi
fi
cd "$repo_root"
"$developer_dir/usr/bin/xcodebuild" -project 'Sentient OS macOS.xcodeproj' -scheme 'Sentient OS macOS' \
    -configuration Debug -derivedDataPath .build/baseline CODE_SIGNING_ALLOWED=NO build > .build/context-run-build.log 2>&1
if [[ "$mode" == --build-only ]]; then echo "$app_bundle"; exit 0; fi
/usr/bin/open -n "$app_bundle" --env "SENTIENT_CONTEXT_ROOT=$context_root" \
    --env "SENTIENT_VAULT_ROOT=$repo_root/Tests/Fixtures/ContextEvaluation/vault" --args --context-window
if [[ "$mode" == --verify ]]; then
    for attempt in {1..30}; do
        if [[ -f "$context_root/context.pid" ]] && kill -0 "$(cat "$context_root/context.pid")" 2>/dev/null; then
            echo "Context workspace launched; store: $context_root"; exit 0
        fi
        sleep 0.2
    done
    echo "Build passed, but the context workspace did not report a running process." >&2; exit 1
fi
