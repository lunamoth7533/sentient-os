#!/usr/bin/env python3
"""Exercise current pipeline code using synthetic dependencies and temporary data."""
from pathlib import Path
import os
SOURCE_ROOT = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
import subprocess
text = (SOURCE_ROOT / 'Views/ProcessingView.swift').read_text()
methods = text.split('    private func startIfNeeded() async {', 1)[1].split('\n}\n\n/// Thread-safe holder', 1)[0]
methods = '    private func startIfNeeded() async {' + methods
methods = methods.replace('progress: { phase in', 'progress: { [self] phase in').replace('onLine: { line in', 'onLine: { [self] line in')
box = text.split('private nonisolated final class ProgressBox', 1)[1].split('// MARK: - Analyzing title', 1)[0]
box = 'private nonisolated final class ProgressBox' + box
progress = (SOURCE_ROOT / 'Ingestion/IterativeRun.swift').read_text().split('struct RunProgress: Sendable {', 1)[1].split('\nstruct IterativeRun {', 1)[0]
progress = 'struct RunProgress: Sendable {' + progress
wrapper = r'''
import Foundation
nonisolated func withAnimation(_ body: () -> Void) { body() }
nonisolated func Log(_ message: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { "synthetic error" }
struct AuditError: Error {}
enum Verdict: Sendable { case junk, survivor, sensitive }
enum OvernightCaution { enum Kind: Sendable { case example }; static func classify(_ error: Error) async -> Kind? { nil } }
struct CycleFailure: Sendable, Equatable { let message: String; let kind: OvernightCaution.Kind? }
enum ProactiveCyclePhase: Sendable { case knowledgeBase(String), deciding, researching(Int), done(Int), failed(CycleFailure) }
@MainActor final class Audit {
 static let shared = Audit(); var importOK = true, deviceError = false, cloudOK = true, proactiveOK = true; var events: [String] = []
 func reset() { importOK = true; deviceError = false; cloudOK = true; proactiveOK = true; events = [] }
}
@MainActor final class ContextLibrary { static let shared = ContextLibrary(); var lastError: String? { "Synthetic import failure" }; func importEnabled() async -> Bool { Audit.shared.events.append("import"); return Audit.shared.importOK } }
@MainActor enum OvernightScheduler { static var firstCycleCompletedAt: Date? { Date() } }
@MainActor final class Awake { func begin(reason: String) {}; func end() {} }
protocol Connector {}
struct FakeConnector: Connector {}
@MainActor struct IterativeRun {
 enum Mode { case initial, iterative, auto }; let modelPath: String
 func run(_ connectors: [any Connector], mode: Mode, onProgress: @Sendable @escaping (RunProgress)->Void) async -> RunProgress { Audit.shared.events.append("device"); return RunProgress(errorMessage: Audit.shared.deviceError ? "Synthetic device failure" : nil) }
}
@MainActor enum GmailConnect {
 enum Progress: Sendable { case windowStart(Int, String, String), windowDone(Int, String, String?, Int, Int, Int) }
 static func runInitial(onProgress: @Sendable (Progress)->Void) async throws { try await runIterative(onProgress: onProgress) }
 static func runIterative(onProgress: @Sendable (Progress)->Void) async throws { Audit.shared.events.append("gmail"); if !Audit.shared.cloudOK { throw AuditError() } }
}
@MainActor enum CalendarConnect {
 enum Progress: Sendable { case windowStart(Int, Int, String, String), windowDone(Int, Int, String, String?, Int, Int) }
 static func runInitial(onProgress: @Sendable (Progress)->Void) async throws { try await runIterative(onProgress: onProgress) }
 static func runIterative(onProgress: @Sendable (Progress)->Void) async throws { Audit.shared.events.append("calendar"); if !Audit.shared.cloudOK { throw AuditError() } }
}
@MainActor final class ProactiveCycle {
 static let shared = ProactiveCycle()
 func run(progress: @escaping @Sendable (ProactiveCyclePhase)->Void, onLine: (@Sendable (String)->Void)?) async -> CycleFailure? { Audit.shared.events.append("proactive"); return Audit.shared.proactiveOK ? nil : CycleFailure(message: "Synthetic tail failure", kind: nil) }
}
@MainActor final class ProcessingView {
 enum UIState: Equatable { case loadingModel, processing, preparing, completed, failed(CycleFailure) }
 var state: UIState = .loadingModel
 var started = false, paused = false, fullCycle = true, runGmail = false, runCalendar = false, importingContext = false
 var connectors: [any Connector] = []
 let modelPath = "synthetic", mode = IterativeRun.Mode.auto, awake = Awake()
 var runGeneration = 0, progress = RunProgress(), carried = RunProgress()
 var runTask: Task<RunProgress, Never>?, cycleTask: Task<CycleFailure?, Never>?
 var thoughtPending: String?, thoughtTrail: [String] = [], prepStatus = "", prepSubtext: String?
 static func composed(_ base: RunProgress, _ current: RunProgress) -> RunProgress { current }
 static func thought(_ line: String) -> String? { line }
 var hasLegacySources: Bool { !connectors.isEmpty || runGmail || runCalendar }
 func auditRun() async { await startIfNeeded() }
'''
footer = r'''
}
@MainActor func audit() async -> Int32 {
 let a = Audit.shared
 var failures = 0
 func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label): \(a.events)"); if !condition { failures += 1 } }
 a.reset(); let imports = ProcessingView(); await imports.auditRun()
 check(a.events == ["import"] && imports.state == .completed, "imported-only UI avoids cloud tail")
 a.reset(); a.importOK = false; let failedImport = ProcessingView(); failedImport.connectors = [FakeConnector()]; await failedImport.auditRun()
 check(a.events == ["import"] && failedImport.state != .completed, "import failure stops later UI legs")
 a.reset(); a.deviceError = true; let device = ProcessingView(); device.connectors = [FakeConnector()]; device.runGmail = true; await device.auditRun()
 check(a.events == ["import", "device"] && device.state != .completed, "device errorMessage blocks cloud and success")
 a.reset(); a.cloudOK = false; let gmail = ProcessingView(); gmail.runGmail = true; gmail.runCalendar = true; await gmail.auditRun()
 check(a.events == ["import", "gmail"] && gmail.progress.failed > 0 && gmail.progress.errorMessage != nil && gmail.state != .completed, "Gmail failure remains in progress and blocks tail")
 a.reset(); a.cloudOK = false; let calendar = ProcessingView(); calendar.runCalendar = true; await calendar.auditRun()
 check(a.events == ["import", "calendar"] && calendar.progress.failed > 0 && calendar.progress.errorMessage != nil && calendar.state != .completed, "Calendar failure remains in progress and blocks tail")
 a.reset(); let onboarding = ProcessingView(); onboarding.fullCycle = false; onboarding.connectors = [FakeConnector()]; await onboarding.auditRun()
 check(a.events == ["device"] && onboarding.state == .completed, "onboarding does not import or run proactive tail")
 a.reset(); let success = ProcessingView(); success.connectors = [FakeConnector()]; await success.auditRun()
 check(a.events == ["import", "device", "proactive"] && success.state == .completed, "full successful UI imports before legacy analysis")
 return failures == 0 ? 0 : 1
}
Task { exit(await audit()) }; dispatchMain()
'''
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),'-swift-version','5','-target','arm64-apple-macos15.0','-sdk',os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'),'-']
raise SystemExit(subprocess.run(command, input=wrapper+methods+footer+progress+box, text=True, timeout=120).returncode)
