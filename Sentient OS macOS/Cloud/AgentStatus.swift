//
//  AgentStatus.swift
//  Sentient OS macOS
//
//  The `STATUS: DONE — …` / `STATUS: COULD_NOT — …` sentinel that every app-authored codex
//  wrapper prompt demands as its final line. ONE parser for both
//  consumers — ProactiveExecutor (the card fire channels) and CommandRunModel (Sidekick / the
//  command bar) — so their honesty semantics can never drift.
//
//  Why exact final-line matching: `codex exec`'s human-readable output ECHOES the prompt
//  (a `user` section), and the wrapper's own instruction line contains BOTH sentinel forms — a
//  naive whole-output `contains("STATUS: COULD_NOT")` reads the echo and misreports every run as
//  refused (field-found 2026-07-17; it was live in the executor's computer channel). Scanning
//  earlier lines can also find quoted examples or previous attempts. Only an unquoted final
//  line with an exact status token counts. Negative tokens such as NOT_DONE are unconfirmed.
//
//  Key method: AgentStatus.parse(_:) — works on a bare final message (the connector channels'
//  `env.result`) AND on codex's full human-readable output (`runAgentCommand`).
//

import Foundation

nonisolated enum AgentStatus {
    case done                      // STATUS: DONE — the agent claims it completed the task
    case couldNot(reason: String)  // STATUS: COULD_NOT — it cleanly gave up (reason may be empty)
    case none                      // no sentinel in the reply (legacy prompt / the model forgot)

    /// An exact, unquoted final sentinel is required for confirmed completion. Earlier status
    /// lines and fenced examples are source material, including when the final sentinel is absent.
    static func parse(_ reply: String) -> AgentStatus {
        let lines = reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var fence: (character: Character, count: Int)?
        for line in lines.dropLast() {
            guard let first = line.first, first == "`" || first == "~" else { continue }
            let count = line.prefix { $0 == first }.count
            guard count >= 3 else { continue }
            if let opened = fence {
                if first == opened.character, count >= opened.count { fence = nil }
            } else { fence = (first, count) }
        }
        if fence == nil, let line = lines.last,
           line.range(of: #"^STATUS:[ \t]+(DONE|COULD_NOT)(?:[ \t]*[—–:-][ \t]*.*)?[ \t]*$"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            let upper = line.uppercased()
            guard !(upper.contains("STATUS: DONE") && upper.contains("STATUS: COULD_NOT")) else { return .none }
            let payload = line.dropFirst("STATUS:".count).trimmingCharacters(in: .whitespaces)
            if payload.uppercased().hasPrefix("DONE") { return .done }
            return .couldNot(reason: String(payload.dropFirst("COULD_NOT".count).trimmingCharacters(in: trimSet).prefix(300)))
        }
        // Legacy form (pre-sentinel wrappers): a bare final message that OPENS with "COULD NOT".
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("COULD NOT") {
            return .couldNot(reason: String(String(trimmed.dropFirst("COULD NOT".count))
                .trimmingCharacters(in: trimSet).prefix(300)))
        }
        return .none
    }

    /// Strips the sentinel's separators/backticks around the reason (em/en dashes, colons, ticks).
    private static let trimSet = CharacterSet(charactersIn: " `—–:-.\n\t")
}
