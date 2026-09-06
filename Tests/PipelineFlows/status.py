#!/usr/bin/env python3
"""Exercise the production final-status parser using synthetic responses only."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[2] / "Sentient OS macOS"
source = (root / "Cloud/AgentStatus.swift").read_text()
harness = r'''
let cases: [(String, String, String)] = [
 ("STATUS: NOT_DONE — waiting for approval", "none", "negative status token"),
 ("> STATUS: DONE — an earlier task\nI have not performed this task.", "none", "quoted earlier completion"),
 ("STATUS: DONE — an earlier attempt\nThe operation subsequently failed.", "none", "earlier completion followed by failure"),
 ("The quoted example is `STATUS: DONE — finished`", "none", "inline quoted marker"),
 ("> STATUS: DONE — quoted example", "none", "last-line block quote"),
 ("```\nSTATUS: DONE — quoted example\n```", "none", "closed fenced example"),
 ("```\nSTATUS: DONE — quoted example", "none", "unclosed fenced example"),
 ("STATUS: DONEISH — not the sentinel", "none", "status prefix extension"),
 ("STATUS: DONE OR STATUS: COULD_NOT — echo", "none", "echoed alternatives"),
 ("STATUS: COULD_NOT — waiting for approval, nothing was done", "couldNot", "refusal reason containing done"),
 ("Done working.\nSTATUS: DONE — Finished the synthetic task.\n\n", "done", "exact final completion"),
 ("STATUS: DONE", "done", "exact completion without reason"),
 ("STATUS: COULD_NOT", "couldNot", "exact refusal without reason"),
 ("status: done — Finished.", "done", "case-insensitive exact final token"),
 ("COULD NOT finish because the artificial service is unavailable", "couldNot", "legacy refusal remains safe"),
 ("", "none", "empty reply"),
 ("STATUS: UNKNOWN — no claim", "none", "unknown outcome")
]
var failures = 0
for (reply, expected, label) in cases {
 let outcome: String
 switch AgentStatus.parse(reply) { case .done: outcome = "done"; case .couldNot: outcome = "couldNot"; case .none: outcome = "none" }
 let passed = outcome == expected
 print("\(passed ? "PASS" : "FAIL") \(label)")
 if !passed { failures += 1 }
}
if case .couldNot(let reason) = AgentStatus.parse("STATUS: COULD_NOT — Waiting for approval.") {
 let passed = reason == "Waiting for approval"
 print("\(passed ? "PASS" : "FAIL") refusal reason is preserved")
 if !passed { failures += 1 }
} else { print("FAIL refusal reason is preserved"); failures += 1 }
exit(failures == 0 ? 0 : 1)
'''
command = [os.environ.get("SWIFT_BIN", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"), "-swift-version", "5", "-target", "arm64-apple-macos15.0", "-sdk", os.environ.get("SDKROOT", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"), "-"]
raise SystemExit(subprocess.run(command, input=source + harness, text=True, timeout=120).returncode)
