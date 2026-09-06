---
name: "swift-direct-toolchain"
description: "xcrun fails with arm64e mismatch, swift test or xcodebuild needed, XCTest bundle won't load — build and test Swift projects via direct Xcode binaries."
---

# Swift direct toolchain (broken system xcrun)

On this Mac `/usr/bin/xcrun` (and anything shelling through it, including `/usr/bin/git`) fails with `unable to load libxcrun ... incompatible architecture (have 'arm64', need 'arm64e')`. Run one plain command first; when it fails with exactly that error, use this procedure instead of retrying the shim.

## Steps

1. Substitute the working shims: use `/opt/homebrew/bin/git` for git and `/opt/homebrew/bin/xcodegen` for project generation. Check: `git log` and `xcodegen generate` succeed.
2. Export the toolchain roots once per shell:
   ```bash
   XB=/Applications/Xcode-beta.app/Contents/Developer
   export DEVELOPER_DIR=$XB
   export SDKROOT=$XB/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
   export PATH=$XB/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
   ```
   Check: `$XB/usr/bin/xcodebuild -version` prints Xcode 27.x.
3. Build apps with `$XB/usr/bin/xcodebuild` directly (never an `/usr/bin/xcrun`-resolved `xcodebuild`); ignore the libxcrun stderr noise it still prints. For Mac Catalyst, if the run sits at 0% CPU after linking, verify `Build/Products/Debug-maccatalyst/*.app` exists and is fresh, then kill xcodebuild — the artifacts are complete.
4. For SwiftPM packages, run `swift test --package-path <pkg> --scratch-path <scratch>` to build. The Swift Testing helper will fail to dlopen XCTest (`Library not loaded: @rpath/XCTest.framework`); run the built XCTest bundle directly instead:
   ```bash
   env DYLD_FRAMEWORK_PATH=$XB/Platforms/MacOSX.platform/Developer/Library/Frameworks \
       DYLD_LIBRARY_PATH=$XB/Platforms/MacOSX.platform/Developer/usr/lib \
       $XB/usr/bin/xctest <scratch>/debug/<Package>PackageTests.xctest
   ```
   Check: `Test Suite 'All tests' passed` with a test count.
5. For hosted simulator tests, list devices with `$XB/usr/bin/simctl list devices available`, pass `-destination "platform=iOS Simulator,id=<udid>"`, `rm -rf` the `-resultBundlePath` before each run (xcodebuild refuses to overwrite it), and read results with `$XB/usr/bin/xcresulttool get test-results summary --path <bundle>`. On the iOS 26.5 runtime, HealthKit catalog tests can fail environmentally; create a fresh iOS 27 simulator (`$XB/usr/bin/simctl create <name> com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0`) and rerun there before diagnosing code.
6. When Codex already solved the same tooling problem, mine its transcripts for the proven command instead of re-deriving it:
   ```bash
   jq -r '.. | strings' ~/.codex/sessions/<YYYY/MM/DD>/rollout-*.jsonl | grep -F "<binary or flag>" | sort -u
   ```
   Check: the recovered command references real paths under $XB.
