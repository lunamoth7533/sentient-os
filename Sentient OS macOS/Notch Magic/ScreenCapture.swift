//
//  ScreenCapture.swift
//  Sentient OS macOS
//
//  Grabs a still of EVERY display at the moment the user invokes a command, so computer use SEES
//  exactly what they're looking at — "finish this form", "reply to this", "complete this" all resolve
//  against the real pixels, on whichever screen they're on. The frames are attached to the codex
//  prompt (`codex exec -i <file>...` — the flag is variadic).
//
//  Uses `/usr/sbin/screencapture` (no shutter sound, JPEG), one invocation per display so the order is
//  guaranteed by its own contract (`-D 1` IS the main display) — the prompt tells codex the first frame
//  is the main screen. Rides Sentient's own Screen Recording grant (one grant covers all displays); no
//  grant → returns [] and the command runs text-only (never prompts here). The files are short-lived
//  temps: the caller passes their paths to codex, then calls `discard`. Note: the screens go to the
//  user's OWN codex/OpenAI (the same trust boundary computer use already crosses).
//  Doc: Documentation/Notch Magic/.
//
//  Key methods: grab() -> [URL] · discard(_:).
//

import AppKit
import SwiftUI

@MainActor
enum ScreenCapture {
    nonisolated struct ProtectionState: Equatable, Sendable {
        let generation: UInt64
        let visible: Bool
    }

    private static let contextViews = NSHashTable<NSView>.weakObjects()
    private static var protectionGeneration: UInt64 = 0

    static var hasVisibleContextWindow: Bool {
        contextViews.allObjects.contains { $0.window?.isVisible == true }
    }
    static var protectionState: ProtectionState {
        ProtectionState(generation: protectionGeneration, visible: hasVisibleContextWindow)
    }
    static func canAttach(since initial: ProtectionState) -> Bool {
        !initial.visible && protectionState == initial
    }
    fileprivate static func register(_ view: NSView) { contextViews.add(view) }
    fileprivate static func protectionChanged() { protectionGeneration &+= 1 }

    /// Inject only acquisition and permission boundaries in synthetic tests; the capture loop and
    /// cleanup are the production implementation. The normal caller always uses the live values.
    @MainActor struct Dependencies {
        var permission: @MainActor () -> Bool
        var protection: @MainActor () -> ProtectionState
        var displayCount: @MainActor () -> Int
        var directory: URL
        var capture: @MainActor (URL, Int) async -> Bool

        static var live: Dependencies {
            Dependencies(permission: { Permissions.hasScreenRecording() },
                         protection: { ScreenCapture.protectionState },
                         displayCount: { NSScreen.screens.count },
                         directory: FileManager.default.temporaryDirectory,
                         capture: { url, display in
                             await runCapture(["-x", "-t", "jpg", "-D", "\(display)", url.path])
                         })
        }
    }

    /// Capture every display to temp JPEGs for computer-use context — the MAIN display always first
    /// (`screencapture -D 1` is the main display by its own contract; a per-display failure just drops
    /// that frame). Empty = no Screen Recording grant or nothing captured (the command then runs
    /// without screenshots). Never prompts.
    static func grab() async -> [URL] { await grab(using: .live) }

    static func grab(using dependencies: Dependencies) async -> [URL] {
        let initial = dependencies.protection()
        guard !Task.isCancelled, !initial.visible else { return [] }
        guard dependencies.permission() else {
            Log("📸 screenshot skipped — no Screen Recording grant")
            return []
        }
        let tag = UUID().uuidString
        var shots: [URL] = []
        for display in 1...max(dependencies.displayCount(), 1) {
            guard !Task.isCancelled, dependencies.protection() == initial, dependencies.permission() else {
                discard(shots)
                return []
            }
            let url = dependencies.directory
                .appendingPathComponent("sentient-shot-\(tag)-\(display).jpg")
            //  -x : silent (no camera sound)   -t jpg : compact vs a multi-MB Retina PNG
            let ok = await dependencies.capture(url, display)
            // A protected window may have appeared and closed while screencapture was running.
            // Its generation still changes, so no frame from that interval can be attached.
            guard !Task.isCancelled, dependencies.protection() == initial, dependencies.permission() else {
                discard(shots + [url])
                return []
            }
            if ok, FileManager.default.fileExists(atPath: url.path) {
                shots.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard !shots.isEmpty else {
            Log("📸 screenshot capture failed")
            return []
        }
        let kb = shots.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) / 1024) }
        Log("📸 \(shots.count) display screenshot\(shots.count == 1 ? "" : "s") captured (\(kb) KB)")   // sizes only — never the pixels
        return shots
    }

    /// Delete the temp frames once codex has consumed them (safe on empty).
    static func discard(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Run `screencapture` off the main actor; true iff it exited cleanly. A 5s watchdog kills a
    /// wedged capture (house rule: no un-watchdogged Process) — the run start awaits this, so a hang
    /// here would freeze the command where STOP can't reach; on timeout the command just runs text-only.
    private static func runCapture(_ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let watchdog = DispatchWorkItem { [weak p] in p?.terminate() }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
                    p.waitUntilExit()
                    watchdog.cancel()
                    cont.resume(returning: p.terminationStatus == 0)
                } catch {
                    Log("📸 screencapture launch failed — \(error.localizedDescription)")
                    cont.resume(returning: false)
                }
            }
        }
    }
}

/// Marks the entire containing window as private while showing imported source evidence. Window
/// events are observed synchronously so opening and closing it during an awaited capture is retained.
@MainActor
struct ContextCaptureProtection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ContextCaptureProtectionView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}

@MainActor
final class ContextCaptureProtectionView: NSView {
    private var visibilityObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ScreenCapture.register(self)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObservation = nil
        NotificationCenter.default.removeObserver(self)
        ScreenCapture.protectionChanged()
        guard let window else { return }
        visibilityObservation = window.observe(\.isVisible, options: [.old, .new]) { _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated { ScreenCapture.protectionChanged() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didExposeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        ScreenCapture.protectionChanged()
    }
}
