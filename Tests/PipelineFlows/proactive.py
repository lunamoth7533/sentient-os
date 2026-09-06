#!/usr/bin/env python3
"""Exercise current pipeline code using synthetic dependencies and temporary data."""
from pathlib import Path
import os
SOURCE_ROOT = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
import subprocess
source = (SOURCE_ROOT / 'Proactive/ProactiveCycle.swift').read_text().replace('UserDefaults.standard', 'AuditDefaults.shared')
stubs = r'''
final class Audit: @unchecked Sendable {
 static let shared = Audit(); var readOK = true, wipeOK = true, empty = false, cancelAtGift = false, cancelAtPush = false; var events: [String] = []
 func reset() { readOK = true; wipeOK = true; empty = false; cancelAtGift = false; cancelAtPush = false; events = [] }
}
struct AuditError: Error {}
nonisolated func Log(_ message: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { "synthetic error" }
final class AuditDefaults: @unchecked Sendable { static let shared = AuditDefaults(); func set(_ value: Any, forKey: String) { Audit.shared.events.append("success-stamp") }; func removeObject(forKey: String) {} }
enum OvernightCaution { enum Kind: Sendable { case example }; static func classify(_ error: Error) async -> Kind? { nil }; static func record(_ kind: Kind?) {}; static func clear() {} }
enum Analytics { enum Tier { case core }; static func signal(_ name: String, parameters: [String:String] = [:], floatValue: Double? = nil, tier: Tier? = nil) {} }
enum PipelineActivity { static func begin() { Audit.shared.events.append("begin") }; static func end() { Audit.shared.events.append("end") } }
struct CycleNoteItem: Sendable {}
struct CloudNote: Sendable { init(_ note: CycleNoteItem) {} }
actor CycleStore {
 static let shared = CycleStore()
 func notes() -> [CycleNoteItem] { (try? readNotes()) ?? [] }
 func readNotes() throws -> [CycleNoteItem] { Audit.shared.events.append("read"); if !Audit.shared.readOK { throw AuditError() }; return Audit.shared.empty ? [] : [CycleNoteItem()] }
 func wipeAllNotes() { try? wipeAllNotesDurably() }
 func wipeNotesDurably(matching snapshots: [CycleNoteItem]) throws { try wipeAllNotesDurably() }
 func wipeAllNotesDurably() throws { try Task.checkCancellation(); Audit.shared.events.append("wipe-attempt"); if !Audit.shared.wipeOK { throw AuditError() }; Audit.shared.events.append("wipe-commit") }
}
enum VaultGenerator { static let vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-proactive-audit-\(UUID().uuidString)"); enum Progress: Sendable { case folding(Int, Int) } }
actor VaultCloud {
 static let shared = VaultCloud()
 func update(notes: [CloudNote], onProgress: @Sendable (VaultGenerator.Progress)->Void, onLine: (@Sendable (String)->Void)?) async throws { Audit.shared.events.append("vault") }
 func create(notes: [CloudNote], onProgress: @Sendable (VaultGenerator.Progress)->Void, onLine: (@Sendable (String)->Void)?) async throws { Audit.shared.events.append("vault") }
 static func pushIfDirty() async { Audit.shared.events.append("push"); if Audit.shared.cancelAtPush { withUnsafeCurrentTask { $0?.cancel() } } }
}
actor GiftLetter {
 static let shared = GiftLetter(); static func latest() -> Int? { nil }; static func clear() {}
 func generate(onLine: (@Sendable (String)->Void)?) async throws { Audit.shared.events.append("gift"); if Audit.shared.cancelAtGift { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() } }
}
enum CodexAuth { static let knowledgeBaseOnly = false }
enum ModelBackend { static let connectorsAvailable = false }
enum CalendarConnect { static func fetchProactiveContext() async -> String? { nil } }
struct ActionItem: Sendable {}
actor Proactive {
 static let shared = Proactive(); enum ProError: Error { case noRecent }; static func clear() {}
 func findActionItems(from notes: [CloudNote], calendarContext: String?, onLine: (@Sendable (String)->Void)?) async throws -> [ActionItem] { Audit.shared.events.append("decide"); return [] }
}
struct ReadyResult: Sendable { let ready: [Int]; let dropped: [Int] }
actor ProactiveResearch {
 static let shared = ProactiveResearch(); static func clear() {}; static func latest() -> ReadyResult? { nil }; static func saveLatest(_ result: ReadyResult) { Audit.shared.events.append("replace-cards") }
 func researchAndPrepare(items: [ActionItem], notes: [CloudNote], calendarContext: String?, onLine: (@Sendable (String)->Void)?) async throws -> ReadyResult { ReadyResult(ready: [], dropped: []) }
}
enum OvernightScheduler { static func noteFirstCycleCompleted() { Audit.shared.events.append("first-cycle") } }
func audit() async -> Int32 {
 let a = Audit.shared
 var failures = 0
 func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label): \(a.events)"); if !condition { failures += 1 } }
 a.reset(); a.readOK = false
 let read = await ProactiveCycle.shared.run(progress: { _ in })
 check(read != nil && !a.events.contains("success-stamp") && !a.events.contains("wipe-attempt"), "strict read failure cannot become empty successful cycle")
 a.reset(); a.wipeOK = false
 let wipe = await ProactiveCycle.shared.run(progress: { _ in })
 check(wipe != nil && !a.events.contains("success-stamp") && !a.events.contains("first-cycle"), "durable wipe failure cannot report success")
 a.reset(); a.cancelAtGift = true
 let giftTask = Task { await ProactiveCycle.shared.run(progress: { _ in }) }; let gift = await giftTask.value
 check(gift != nil && !a.events.contains("decide") && !a.events.contains("wipe-attempt") && !a.events.contains("success-stamp"), "best-effort welcome cancellation stops destructive tail")
 a.reset(); a.cancelAtPush = true
 let pushTask = Task { await ProactiveCycle.shared.run(progress: { _ in }) }; let push = await pushTask.value
 check(push != nil && !a.events.contains("gift") && !a.events.contains("wipe-attempt") && !a.events.contains("success-stamp"), "mirror cancellation stops later work")
 a.reset(); a.empty = true
 let entryTask = Task { withUnsafeCurrentTask { $0?.cancel() }; return await ProactiveCycle.shared.run(progress: { _ in }) }; let entry = await entryTask.value
 check(entry != nil && !a.events.contains("read") && !a.events.contains("success-stamp"), "already cancelled cycle cannot stamp no-op success")
 a.reset(); let success = await ProactiveCycle.shared.run(progress: { _ in })
 check(success == nil && a.events.contains("wipe-commit") && a.events.contains("success-stamp") && a.events.last == "end", "clean cycle finishes after durable wipe")
 return failures == 0 ? 0 : 1
}
Task { exit(await audit()) }; dispatchMain()
'''
stubs = stubs.replace('func removeObject(forKey: String) {}', 'func removeObject(forKey: String) {}; func bool(forKey: String) -> Bool { false }')
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),'-swift-version','5','-target','arm64-apple-macos15.0','-sdk',os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'),'-']
raise SystemExit(subprocess.run(command, input=source+stubs, text=True, timeout=120).returncode)
