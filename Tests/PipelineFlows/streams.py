#!/usr/bin/env python3
"""Exercise actual CLI stream accumulation, return selection, and final-status parsing."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2] / "Sentient OS macOS"
source = (root / "Cloud/CodexCLI.swift").read_text()


def section(start: str, end: str) -> str:
    """Fail visibly if the production source shape changes; never substitute an old copy."""
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Review the stream harness extraction boundary: {start}")
    lower = source.index(start)
    upper = source.index(end, lower)
    return source[lower:upper]


helpers = section("    struct ExecResult: Sendable {", "\n    /// Full inherited environment")
helpers += section("    private final class LineSink: @unchecked Sendable {", "\n    /// Thread-safe handle")
helpers += section("    private final class ProcHolder: @unchecked Sendable {", "\n    /// Streaming sibling")
stream_start = "    private static func executeStreaming("
if source.count(stream_start) != 1 or not source.rstrip().endswith("\n}"):
    raise RuntimeError("Review the production executeStreaming extraction boundary")
# executeStreaming is the final declaration in CodexCLI; omit only the actor's closing brace.
streaming = source[source.index(stream_start):source.rfind("\n}")]
agent_method = section("    func runAgentCommand(", "\n    /// Emit a structured codex failure")
selection = re.findall(r"(?m)^\s*(return out\.stdout[^\n]*)$", agent_method)
if len(selection) != 1:
    raise RuntimeError("Review the production runAgentCommand output-selection expression")

boundary = '''
import Foundation
import os
actor CodexCLI {
    enum CLIError: Error { case launchFailed(String), timedOut(after: TimeInterval), unexpectedExit(Int32) }
    // The only environment boundary is inert: no user config, credentials, or GUI state is inherited.
    private static func richEnvironment(binDir: String) -> [String: String] { [:] }
'''
boundary += helpers + streaming
boundary += '''
    static func representativeReply(_ code: String) async throws -> String {
        let out = try await executeStreaming(binary: __PYTHON__, args: ["-I", "-S", "-c", code], timeout: 5, onLine: { _ in })
        guard out.status == 0 else { throw CLIError.unexpectedExit(out.status) }
        __RETURN_SELECTION__
    }
}
'''.replace("__PYTHON__", json.dumps(sys.executable, ensure_ascii=False)).replace("__RETURN_SELECTION__", selection[0])

harness = r'''
@MainActor func auditStreams() async throws -> Int32 {
    let cases: [(String, String, String, String)] = [
        ("DONE with later stderr usage", "Task completed.\nSTATUS: DONE — Synthetic action\n", "codex\nSTATUS: DONE — Synthetic action\ntokens used\n1,234\n", "done"),
        ("refusal with later stderr usage", "STATUS: COULD_NOT — Synthetic refusal\n", "tokens used\n99\n", "couldNot"),
        ("empty stdout never recovers earlier status", "", "codex\nSTATUS: DONE — Earlier statement\ntokens used\n42\n", "none"),
        ("unconfirmed stdout excludes stderr status", "Attempt was not confirmed.\n", "codex\nSTATUS: DONE — Earlier statement\ntokens used\n42\n", "none"),
        ("DONE without final newline", "STATUS: DONE — Synthetic action", "tokens used\n7\n", "done")
    ]
    var failures = 0
    for (label, stdout, stderr, expected) in cases {
        let encoded = try JSONSerialization.data(withJSONObject: [stdout, stderr])
        let base64 = encoded.base64EncodedString()
        // This child writes artificial output to separate real pipes; it never invokes Codex.
        let code = "import sys,json,base64; a=json.loads(base64.b64decode('" + base64 + "')); sys.stdout.write(a[0]); sys.stdout.flush(); sys.stderr.write(a[1]); sys.stderr.flush()"
        let reply = try await CodexCLI.representativeReply(code)
        let outcome: String
        switch AgentStatus.parse(reply) {
        case .done: outcome = "done"
        case .couldNot: outcome = "couldNot"
        case .none: outcome = "none"
        }
        let passed = outcome == expected
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(label): \(outcome)")
    }
    return failures == 0 ? 0 : 1
}
Task {
    do { exit(try await auditStreams()) }
    catch { print("FAIL synthetic stream boundary: \(error)"); exit(1) }
}
dispatchMain()
'''
command = [os.environ.get("SWIFT_BIN", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"), "-swift-version", "5", "-target", "arm64-apple-macos15.0", "-sdk", os.environ.get("SDKROOT", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"), "-"]
parser = (root / "Cloud/AgentStatus.swift").read_text()
raise SystemExit(subprocess.run(command, input=boundary + parser + harness, text=True, timeout=120).returncode)
