#!/usr/bin/env python3
"""Exercise current pipeline code using synthetic dependencies and temporary data."""
from pathlib import Path
import os
SOURCE_ROOT = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
import subprocess
source = (SOURCE_ROOT / 'Scheduling/OvernightScheduler.swift').read_text().split('/// Persistent scheduler log')[0]
assert 'private func ud(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }' in source, 'Update the synthetic preference seam before running this harness.'
source = source.replace('private func ud(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }', 'private func ud(_ key: String) -> Bool { Audit.shared.gmail && key.contains("gmail") }')
stubs = r'''
import Observation
@MainActor final class Audit {
 static let shared = Audit()
 var imported = true, importOK = true, device = false, deviceError = false, gmail = false, cloudOK = true, proactiveOK = true, cancelAtImport = false
 var events: [String] = []
 func reset() { imported = true; importOK = true; device = false; deviceError = false; gmail = false; cloudOK = true; proactiveOK = true; cancelAtImport = false; events = [] }
}
nonisolated func Log(_ message: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { "synthetic error" }
struct AuditError: Error {}
@MainActor enum Analytics { enum Tier { case core }; static func signal(_ event: String, parameters: [String:String] = [:], tier: Tier? = nil) { Audit.shared.events.append(event) } }
@MainActor enum CodexAuth { static let knowledgeBaseOnly = false }
@MainActor enum LoginItem { static let isEnabled = true; static func enable() {} }
@MainActor enum WakeHelperInstaller { static func isInstalledAndCurrent() -> Bool { true }; static func installAsync() async -> Bool { true } }
@MainActor final class WakeHelperClient {
 static let shared = WakeHelperClient(); let isReady = true
 enum Health { case ready, disabled, notSetUp }
 func healthProbe() async -> Health { .ready }
 func cancelWake() async -> Bool { true }; func cancelAllWakes() async -> Bool { true }; func armWake(at: Date) async -> Bool { true }
 func beginAwake(timeout: Int) async -> Bool { Audit.shared.events.append("begin"); return true }
 func heartbeat() async -> Bool { true }
 func endAwake() async -> Bool { Audit.shared.events.append("end"); return true }
}
@MainActor enum Permissions { static func hasFullDiskAccess() -> Bool { true } }
@MainActor enum SourceSelection { static func current(fdaGranted: Bool) -> [RunSource] { Audit.shared.device ? [RunSource()] : [] } }
protocol Connector {}
struct FakeConnector: Connector {}
struct RunSource { let label = "Synthetic"; @MainActor static func connectors(from: [RunSource]) -> [any Connector] { from.isEmpty ? [] : [FakeConnector()] } }
@MainActor enum ModelBackend { static let connectorsAvailable = true }
@MainActor enum ModelLocator { static func resolve() -> String? { Audit.shared.device ? "synthetic" : nil } }
@MainActor enum PowerState { static let lowPowerMode = false, thermalLabel = "normal"; static func onACPower() -> Bool { true }; static func overnightBlockReason() -> String? { nil } }
struct RunProgress: Sendable { var total = 0, done = 0, survivors = 0, junk = 0, failed = 0; var errorMessage: String?; var cancelled = false }
@MainActor struct IterativeRun {
 enum Mode { case auto }; let modelPath: String
 func run(_ connectors: [any Connector], mode: Mode, onProgress: (RunProgress)->Void) async -> RunProgress { Audit.shared.events.append("device"); return RunProgress(errorMessage: Audit.shared.deviceError ? "Synthetic storage failure" : nil) }
}
@MainActor enum GmailConnect { static func runIterative(_ progress: (Int)->Void) async throws { Audit.shared.events.append("gmail"); if !Audit.shared.cloudOK { throw AuditError() } } }
@MainActor enum CalendarConnect { static func runIterative(_ progress: (Int)->Void) async throws { Audit.shared.events.append("calendar") } }
@MainActor final class ContextLibrary {
 static let shared = ContextLibrary()
 struct Source { let enabled = true }
 var sources: [Source] { Audit.shared.imported ? [Source()] : [] }
 var lastError: String? { "Synthetic import failure" }
 func refresh() {}
 func importEnabled() async -> Bool { Audit.shared.events.append("import"); if Audit.shared.cancelAtImport { withUnsafeCurrentTask { $0?.cancel() } }; return Audit.shared.importOK }
}
struct CycleFailure: Sendable { let message: String; let kind: OvernightCaution.Kind? = nil }
enum ProactiveCyclePhase: Sendable { case knowledgeBase(String), deciding, researching(Int), done(Int), failed(CycleFailure) }
enum OvernightCaution { enum Kind: Sendable { case example }; @MainActor static func record(_ kind: Kind?) {}; static func classify(_ error: Error) async -> Kind? { nil } }
@MainActor final class ProactiveCycle {
 static let shared = ProactiveCycle()
 func run(scheduled: Bool, progress: @escaping @Sendable (ProactiveCyclePhase)->Void) async -> CycleFailure? { Audit.shared.events.append("proactive"); return Audit.shared.proactiveOK ? nil : CycleFailure(message: "Synthetic tail failure") }
}
@MainActor final class SchedulerLog { func line(_ line: String) {} }
extension OvernightScheduler { func auditRun() async { await runProcessing(log: SchedulerLog()) } }
@MainActor func audit() async -> Int32 {
 let a = Audit.shared
 var failures = 0
 func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label): \(a.events)"); if !condition { failures += 1 } }
 a.reset(); await OvernightScheduler().auditRun()
 check(a.events.contains("import") && !a.events.contains("proactive") && a.events.contains("Scheduler.overnightCompleted"), "imported-only runs without model or cloud")
 a.reset(); a.device = true; a.importOK = false; await OvernightScheduler().auditRun()
 check(a.events.contains("import") && !a.events.contains("device") && !a.events.contains("proactive") && !a.events.contains("Scheduler.overnightCompleted") && a.events.contains("end"), "import failure stops tail and releases awake")
 a.reset(); a.device = true; a.deviceError = true; await OvernightScheduler().auditRun()
 check(!a.events.contains("proactive") && !a.events.contains("Scheduler.overnightCompleted") && a.events.contains("end"), "device error stops success and releases awake")
 a.reset(); a.gmail = true; a.cloudOK = false; await OvernightScheduler().auditRun()
 check(!a.events.contains("proactive") && !a.events.contains("Scheduler.overnightCompleted") && a.events.contains("end"), "cloud failure stops success and releases awake")
 a.reset(); a.device = true; a.proactiveOK = false; await OvernightScheduler().auditRun()
 check(!a.events.contains("Scheduler.overnightCompleted") && a.events.contains("end"), "tail failure is not reported as completed")
 a.reset(); a.device = true; await OvernightScheduler().auditRun()
 let sequence = a.events.filter { ["import", "device", "proactive", "end", "Scheduler.overnightCompleted"].contains($0) }
 check(sequence == ["import", "device", "proactive", "end", "Scheduler.overnightCompleted"], "successful legacy run imports first and completes after cleanup")
 a.reset(); a.device = true; a.cancelAtImport = true
 let cancelled = Task { await OvernightScheduler().auditRun() }; await cancelled.value
 check(!a.events.contains("device") && !a.events.contains("proactive") && !a.events.contains("Scheduler.overnightCompleted") && a.events.contains("end"), "cancellation stops later legs and releases awake")
 return failures == 0 ? 0 : 1
}
Task { exit(await audit()) }; dispatchMain()
'''
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),'-swift-version','5','-target','arm64-apple-macos15.0','-sdk',os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'),'-']
result = subprocess.run(command, input=source+'\n'+stubs, text=True, timeout=120)
raise SystemExit(result.returncode)
