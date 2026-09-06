#!/usr/bin/env python3
"""Exercise actual CommandRunModel code with artificial capture, retrieval, and model boundaries."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[2] / 'Sentient OS macOS'
source = (root / 'Notch Magic/CommandRunModel.swift').read_text().replace('UserDefaults.standard', 'AuditDefaults.shared')
source += '\n' + (root / 'Cloud/AgentStatus.swift').read_text()
stubs = r'''
import Observation
nonisolated enum AgentMode: String { case computer; var label: String { "Computer" }; var promptPhrase: String { "computer use" } }
nonisolated enum VaultGenerator { static var vaultRoot: URL { URL(fileURLWithPath: "/synthetic-vault") } }
nonisolated enum CustomInstructions { static let sidekick = "" }
nonisolated enum CustomProvider { static let computerUsePromptRules = "" }
nonisolated func Log(_ message: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { "synthetic error" }
nonisolated final class AuditDefaults: @unchecked Sendable { static let shared = AuditDefaults(); func integer(forKey: String) -> Int { 1024 } }
@MainActor enum Analytics { static func signal(_ name: String, parameters: [String:String], floatValue: Double) {} }
@MainActor enum ExecutorScoreboard {
 enum Outcome { case fired, failed, refused }
 static func record(method: String, source: String, outcome: Outcome, durationS: Double, statusPresent: Bool, errorClass: String?) { Fixture.shared.board.append(outcome) }
}
@MainActor final class Fixture {
 static let shared = Fixture()
 var privateVisible = false { didSet { if oldValue != privateVisible { privateGeneration += 1 } } }
 var privateGeneration: UInt64 = 0, grabCalls = 0, codexCalls = 0
 var onGrab: (() -> Void)?, onCodex: (() -> Void)?
 var discarded: [URL] = [], images: [String] = [], prompt = "", response = "STATUS: DONE — Synthetic success", board: [ExecutorScoreboard.Outcome] = []
 let shot = URL(fileURLWithPath: "/synthetic-capture.jpg")
 func reset() { privateVisible = false; grabCalls = 0; codexCalls = 0; onGrab = nil; onCodex = nil; discarded = []; images = []; prompt = ""; response = "STATUS: DONE — Synthetic success"; board = []; RetrievalControl.shared.reset() }
}
@MainActor enum ScreenCapture {
 struct ProtectionState: Equatable { let generation: UInt64; let visible: Bool }
 static var hasVisibleContextWindow: Bool { Fixture.shared.privateVisible }
 static var protectionState: ProtectionState { ProtectionState(generation: Fixture.shared.privateGeneration, visible: hasVisibleContextWindow) }
 static func canAttach(since initial: ProtectionState) -> Bool { !initial.visible && protectionState == initial }
 static func grab() async -> [URL] { Fixture.shared.grabCalls += 1; Fixture.shared.onGrab?(); return [Fixture.shared.shot] }
 static func discard(_ urls: [URL]) { Fixture.shared.discarded.append(contentsOf: urls) }
}
nonisolated final class RetrievalGate: @unchecked Sendable {
 private let lock = NSLock(); private var entered = false; private let semaphore = DispatchSemaphore(value: 0)
 var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
 func block() { lock.lock(); entered = true; lock.unlock(); precondition(semaphore.wait(timeout: .now() + 10) == .success, "Synthetic retrieval gate timed out") }
 func resume() { semaphore.signal() }
}
nonisolated final class RetrievalControl: @unchecked Sendable {
 static let shared = RetrievalControl(); private let lock = NSLock(); private var active: RetrievalGate?; private var sharedOnly = true
 private var configured = [ImportSource(id: "shared", contextEnabled: true, shareEnabled: true), ImportSource(id: "private", contextEnabled: true, shareEnabled: false)]
 private var failReads = false
 private var retrievals = 0
 func reset() { lock.lock(); active = nil; sharedOnly = true; configured = [ImportSource(id: "shared", contextEnabled: true, shareEnabled: true), ImportSource(id: "private", contextEnabled: true, shareEnabled: false)]; failReads = false; retrievals = 0; lock.unlock() }
 func changeSources(_ values: [ImportSource]) { lock.lock(); configured = values; lock.unlock() }
 func failSourceReads() { lock.lock(); failReads = true; lock.unlock() }
 func sources() throws -> [ImportSource] { lock.lock(); defer { lock.unlock() }; if failReads { throw CocoaError(.fileReadNoPermission) }; return configured }
 func set(_ gate: RetrievalGate) { lock.lock(); active = gate; lock.unlock() }
 func retrieve(shared: Bool, sourceIDs: Set<String>) { lock.lock(); sharedOnly = sharedOnly && shared && sourceIDs == ["shared"]; retrievals += 1; let gate = active; lock.unlock(); gate?.block() }
 var usedSharedOnly: Bool { lock.lock(); defer { lock.unlock() }; return sharedOnly }
 var retrievalCount: Int { lock.lock(); defer { lock.unlock() }; return retrievals }
}
nonisolated enum ContextAudience { case shared, local }
nonisolated struct ContextQuery { let text: String; var sourceIDs: Set<String> = []; let tokenBudget: Int }
nonisolated struct ContextResult { let text: String }
nonisolated struct ImportSource: Equatable, Sendable { let id: String; let contextEnabled: Bool; let shareEnabled: Bool }
nonisolated struct EvidenceStore: Sendable { func sources() throws -> [ImportSource] { try RetrievalControl.shared.sources() } }
nonisolated enum ContextPaths { static func openStore() throws -> EvidenceStore { EvidenceStore() } }
nonisolated enum ContextRetriever {
 static let maximumBudget = 32768
 static func retrieve(store: EvidenceStore, query: ContextQuery, audience: ContextAudience) throws -> ContextResult { RetrievalControl.shared.retrieve(shared: audience == .shared, sourceIDs: query.sourceIDs); return ContextResult(text: "Synthetic explicitly shared evidence [citation]") }
}
@MainActor final class CodexCLI {
 static let shared = CodexCLI()
 func runAgentCommand(_ prompt: String, imagePaths: [String], onLine: @escaping @Sendable (String)->Void) async throws -> String {
  Fixture.shared.codexCalls += 1; Fixture.shared.prompt = prompt; Fixture.shared.images = imagePaths; Fixture.shared.onCodex?(); return Fixture.shared.response
 }
}
extension CommandRunModel { func awaitTestRun() async { await task?.value } }
@MainActor func auditCommands() async -> Int32 {
 let f = Fixture.shared; var failures = 0
 func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label)"); if !condition { failures += 1 } }
 f.reset(); let capture = CommandRunModel(); var captureOutcome: CommandRunModel.Outcome?
 capture.onFinished = { captureOutcome = $0 }; f.onGrab = { capture.stop() }; capture.start("Synthetic task", mode: .computer); await capture.awaitTestRun()
 check(!capture.isRunning && captureOutcome == .stopped && f.codexCalls == 0 && f.discarded.contains(f.shot), "cancel during capture releases command and discards shots")
 f.reset(); let retrieval = CommandRunModel(); var retrievalOutcome: CommandRunModel.Outcome?; let gate = RetrievalGate()
 retrieval.onFinished = { retrievalOutcome = $0 }; RetrievalControl.shared.set(gate); retrieval.start("Synthetic task", mode: .computer)
 while !gate.hasEntered { await Task.yield() }; retrieval.stop(); gate.resume(); await retrieval.awaitTestRun()
 check(!retrieval.isRunning && retrievalOutcome == .stopped && f.codexCalls == 0 && f.discarded.contains(f.shot), "cancel during retrieval releases command and discards shots")
 f.reset(); f.privateVisible = true; let visible = CommandRunModel(); visible.start("Synthetic task", mode: .computer); await visible.awaitTestRun()
 check(f.grabCalls == 0 && f.images.isEmpty, "visible private context suppresses automatic acquisition")
 f.reset(); let duringCapture = CommandRunModel(); f.onGrab = { f.privateVisible = true }; duringCapture.start("Synthetic task", mode: .computer); await duringCapture.awaitTestRun()
 check(f.images.isEmpty && f.discarded.contains(f.shot) && !f.prompt.contains("Attached is a screenshot"), "context appearing during capture suppresses attachment and screen prompt")
 f.reset(); let duringRetrieval = CommandRunModel(); let privacyGate = RetrievalGate(); RetrievalControl.shared.set(privacyGate)
 duringRetrieval.start("Synthetic task", mode: .computer); while !privacyGate.hasEntered { await Task.yield() }; f.privateVisible = true; privacyGate.resume(); await duringRetrieval.awaitTestRun()
 check(f.images.isEmpty && f.discarded.contains(f.shot) && !f.prompt.contains("Attached is a screenshot"), "context appearing during retrieval suppresses stale screenshot attachment")
 f.reset(); let briefCapture = CommandRunModel(); f.onGrab = { f.privateVisible = true; f.privateVisible = false }
 briefCapture.start("Synthetic task", mode: .computer); await briefCapture.awaitTestRun()
 check(f.images.isEmpty && f.discarded.contains(f.shot), "private window opened then closed during capture invalidates its frames")
 f.reset(); let briefRetrieval = CommandRunModel(); let briefGate = RetrievalGate(); RetrievalControl.shared.set(briefGate)
 briefRetrieval.start("Synthetic task", mode: .computer); while !briefGate.hasEntered { await Task.yield() }; f.privateVisible = true; f.privateVisible = false; briefGate.resume(); await briefRetrieval.awaitTestRun()
 check(f.images.isEmpty && f.discarded.contains(f.shot), "private window opened then closed during retrieval invalidates old frames")
 for change in 0..<4 {
  f.reset(); let changed = CommandRunModel(); let changedGate = RetrievalGate(); RetrievalControl.shared.set(changedGate)
  changed.start("Synthetic task", mode: .computer); while !changedGate.hasEntered { await Task.yield() }
  switch change {
  case 0: RetrievalControl.shared.changeSources([ImportSource(id: "shared", contextEnabled: true, shareEnabled: false)])
  case 1: RetrievalControl.shared.changeSources([ImportSource(id: "shared", contextEnabled: false, shareEnabled: true)])
  case 2: RetrievalControl.shared.changeSources([])
  default: RetrievalControl.shared.failSourceReads()
  }
  changedGate.resume(); await changed.awaitTestRun()
  check(f.codexCalls == 1 && !f.prompt.contains("Synthetic explicitly shared evidence"), "source permission change or validation failure excludes pending context \(change)")
 }
 f.reset(); f.response = "I tried something, without a completion status."; let unknown = CommandRunModel(); var unknownOutcome: CommandRunModel.Outcome?
 unknown.onFinished = { unknownOutcome = $0 }; unknown.start("Synthetic task", mode: .computer); await unknown.awaitTestRun()
 check(unknownOutcome == .failed && !f.board.contains(.fired), "missing completion sentinel never becomes confirmed success")
 f.reset(); let cancelledReply = CommandRunModel(); var replyOutcome: CommandRunModel.Outcome?; cancelledReply.onFinished = { replyOutcome = $0 }; f.onCodex = { cancelledReply.stop() }
 cancelledReply.start("Synthetic task", mode: .computer); await cancelledReply.awaitTestRun()
 check(replyOutcome == .stopped && !f.board.contains(.fired), "late reply after cancellation never becomes success")
 f.reset(); f.response = "STATUS: COULD_NOT — Synthetic refusal"; let refused = CommandRunModel(); var refusedOutcome: CommandRunModel.Outcome?
 refused.onFinished = { refusedOutcome = $0 }; refused.start("Synthetic task", mode: .computer); await refused.awaitTestRun()
 check(refusedOutcome == .failed && f.board == [.refused], "explicit refusal remains a failed outcome")
 f.reset(); let success = CommandRunModel(); var successOutcome: CommandRunModel.Outcome?; success.onFinished = { successOutcome = $0 }
 success.start("Synthetic task", mode: .computer); await success.awaitTestRun()
 check(successOutcome == .success && f.images == [f.shot.path] && f.prompt.contains("Synthetic explicitly shared evidence") && RetrievalControl.shared.usedSharedOnly, "normal command retains screenshots and shared-only cited context")
 f.reset(); RetrievalControl.shared.changeSources([ImportSource(id: "private", contextEnabled: true, shareEnabled: false)])
 let noSharing = CommandRunModel(); noSharing.start("Synthetic task", mode: .computer); await noSharing.awaitTestRun()
 check(f.codexCalls == 1 && RetrievalControl.shared.retrievalCount == 0 && !f.prompt.contains("Synthetic explicitly shared evidence"), "no shared sources skips retrieval without an unscoped empty filter")
 return failures == 0 ? 0 : 1
}
Task { exit(await auditCommands()) }; dispatchMain()
'''
command = [os.environ.get('SWIFT_BIN', '/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'), '-swift-version', '5', '-target', 'arm64-apple-macos15.0', '-sdk', os.environ.get('SDKROOT', '/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk'), '-']
raise SystemExit(subprocess.run(command, input=source+stubs, text=True, timeout=120).returncode)
