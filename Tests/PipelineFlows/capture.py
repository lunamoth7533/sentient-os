#!/usr/bin/env python3
"""Exercise the real capture loop and window marker without screen recording or live files."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[2] / "Sentient OS macOS"
source = (root / "Notch Magic/ScreenCapture.swift").read_text()
harness = r'''
@MainActor enum Permissions { static func hasScreenRecording() -> Bool { false } }
nonisolated func Log(_ message: String) {}
@MainActor final class CaptureFixture {
 let directory: URL
 var permitted = true, visible = false
 var generation: UInt64 = 0
 var calls: [Int] = []
 var afterCapture: ((Int) -> Void)?
 var failedDisplay: Int?
 init() throws {
  directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-capture-regression-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 }
 func reset() throws {
  try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).forEach { try FileManager.default.removeItem(at: $0) }
  permitted = true; visible = false; generation = 0; calls = []; afterCapture = nil; failedDisplay = nil
 }
 var files: [URL] { (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] }
 var dependencies: ScreenCapture.Dependencies {
  .init(permission: { self.permitted },
        protection: { .init(generation: self.generation, visible: self.visible) },
        displayCount: { 2 }, directory: directory,
        capture: { url, display in
         self.calls.append(display)
         try! Data("artificial frame, no screen pixels".utf8).write(to: url)
         self.afterCapture?(display)
         return self.failedDisplay != display
        })
 }
}
@MainActor func auditCapture() async throws -> Int32 {
 let f = try CaptureFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
 var failures = 0
 func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label)"); if !condition { failures += 1 } }
 f.visible = true
 let protected = await ScreenCapture.grab(using: f.dependencies)
 check(protected.isEmpty && f.calls.isEmpty && f.files.isEmpty, "private window suppresses acquisition")
 try f.reset(); f.permitted = false
 let denied = await ScreenCapture.grab(using: f.dependencies)
 check(denied.isEmpty && f.calls.isEmpty && f.files.isEmpty, "missing grant suppresses acquisition")
 try f.reset(); f.afterCapture = { _ in f.visible = true; f.generation += 1 }
 let appeared = await ScreenCapture.grab(using: f.dependencies)
 check(appeared.isEmpty && f.calls == [1] && f.files.isEmpty, "private window during capture drops current frame and remaining displays")
 try f.reset(); f.afterCapture = { display in if display == 2 { f.generation += 2 } }
 let transient = await ScreenCapture.grab(using: f.dependencies)
 check(transient.isEmpty && f.calls == [1, 2] && f.files.isEmpty, "brief private window drops all frames even after it closes")
 try f.reset(); var pending: Task<[URL], Never>?
 f.afterCapture = { _ in pending?.cancel() }
 pending = Task { await ScreenCapture.grab(using: f.dependencies) }
 let cancelled = await pending!.value
 check(cancelled.isEmpty && f.calls == [1] && f.files.isEmpty, "cancellation drops current frame and stops acquisition")
 try f.reset(); f.afterCapture = { display in if display == 2 { f.permitted = false } }
 let revoked = await ScreenCapture.grab(using: f.dependencies)
 check(revoked.isEmpty && f.calls == [1, 2] && f.files.isEmpty, "grant revocation discards current and earlier frames")
 try f.reset()
 let healthy = await ScreenCapture.grab(using: f.dependencies)
 check(healthy.count == 2 && f.calls == [1, 2] && f.files.count == 2, "ordinary acquisition returns both display files")
 ScreenCapture.discard(healthy)
 check(f.files.isEmpty, "caller discard removes synthetic files")
 try f.reset(); f.failedDisplay = 1
 let partial = await ScreenCapture.grab(using: f.dependencies)
 check(partial.count == 1 && f.calls == [1, 2] && f.files.count == 1, "failed display is cleaned without losing another valid frame")
 ScreenCapture.discard(partial)
 try f.reset()
 let beforeStart = Task { await ScreenCapture.grab(using: f.dependencies) }; beforeStart.cancel()
 let neverStarted = await beforeStart.value
 check(neverStarted.isEmpty && f.calls.isEmpty && f.files.isEmpty, "cancel before entry acquires nothing")

 // The window is artificial, transparent, and far offscreen. It contains no imported data and
 // never invokes capture. This checks AppKit's actual order-in/order-out observation synchronously.
 let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 16, height: 16), styleMask: .borderless, backing: .buffered, defer: false)
 window.isReleasedWhenClosed = false; window.alphaValue = 0
 let marker = ContextCaptureProtectionView(frame: .zero); window.contentView = marker
 let initial = ScreenCapture.protectionState
 check(!initial.visible, "attached hidden marker permits capture")
 window.orderFront(nil)
 check(ScreenCapture.hasVisibleContextWindow && !ScreenCapture.canAttach(since: initial), "actual window ordering activates privacy protection")
 window.orderOut(nil)
 check(!ScreenCapture.hasVisibleContextWindow && !ScreenCapture.canAttach(since: initial), "opening then hiding retains capture invalidation")
 let hidden = ScreenCapture.protectionState
 window.orderFront(nil); window.orderOut(nil)
 check(!ScreenCapture.hasVisibleContextWindow && !ScreenCapture.canAttach(since: hidden), "brief native window visibility is recorded without awaiting")
 window.close()
 let closed = ScreenCapture.protectionState
 window.orderFront(nil); window.orderOut(nil)
 check(!ScreenCapture.hasVisibleContextWindow && !ScreenCapture.canAttach(since: closed), "reused closed window retains visibility observation")
 window.close(); window.contentView = nil
 return failures == 0 ? 0 : 1
}
_ = NSApplication.shared
Task {
 do { exit(try await auditCapture()) }
 catch { print("FAIL synthetic capture setup: \(error)"); exit(1) }
}
NSApplication.shared.run()
'''
command = [os.environ.get("SWIFT_BIN", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"), "-swift-version", "5", "-target", "arm64-apple-macos15.0", "-sdk", os.environ.get("SDKROOT", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"), "-"]
raise SystemExit(subprocess.run(command, input=source + harness, text=True, timeout=120).returncode)
