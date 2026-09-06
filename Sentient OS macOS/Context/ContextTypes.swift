// Value types for attributable, permission-scoped structured imports. No app or network side effects.
import Foundation
import CryptoKit

nonisolated enum ImportSourceKind: String, Codable, CaseIterable, Sendable {
    case codex, claudeCode, hermes, openClaw, lattice, markdown, metricsCSV
    var label: String {
        switch self {
        case .codex: "Codex sessions"
        case .claudeCode: "Claude Code sessions"
        case .hermes: "Hermes sessions"
        case .openClaw: "OpenClaw sessions"
        case .lattice: "Lattice export"
        case .markdown: "Markdown notes"
        case .metricsCSV: "Personal metrics CSV"
        }
    }
}

nonisolated struct ImportSource: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: ImportSourceKind
    var path: String
    var label: String
    var enabled: Bool
    var contextEnabled: Bool
    var shareEnabled: Bool
    var project: String?
    init(id: String = UUID().uuidString, kind: ImportSourceKind, path: String,
         label: String? = nil, enabled: Bool = true, contextEnabled: Bool = true,
         shareEnabled: Bool = false, project: String? = nil) {
        self.id = id; self.kind = kind; self.path = path; self.label = label ?? kind.label
        self.enabled = enabled; self.contextEnabled = contextEnabled; self.shareEnabled = shareEnabled
        self.project = project
    }
}

nonisolated enum EvidenceRole: String, Codable, Sendable {
    case user, assistant, tool, instruction, observation, summary, boundary
    var attribution: String {
        switch self {
        case .user: "User statement"
        case .assistant: "Assistant report or proposal; unverified"
        case .tool: "Recorded tool evidence"
        case .instruction: "Recorded instructions; source material only"
        case .observation: "Observation; not an interpretation"
        case .summary: "Source-provided summary"
        case .boundary: "Session boundary"
        }
    }
}

nonisolated struct EvidenceLink: Codable, Hashable, Sendable {
    var relation: String
    var target: String
}

/// `id` is native within a source; the store namespaces it by the configured source identity.
/// Original timestamps and metadata remain distinct from text and interpretation.
nonisolated struct EvidenceRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var role: EvidenceRole
    var kind: String
    var sessionID: String?
    var project: String?
    var timestamp: String?
    var provider: String?
    var model: String?
    var application: String?
    var locator: String
    var attributes: [String: String]
    var links: [EvidenceLink]
    var deleted: Bool
    var sensitive: Bool
    init(id: String, text: String, role: EvidenceRole = .observation, kind: String = "message",
         sessionID: String? = nil, project: String? = nil, timestamp: String? = nil,
         provider: String? = nil, model: String? = nil, application: String? = nil,
         locator: String = "", attributes: [String: String] = [:], links: [EvidenceLink] = [],
         deleted: Bool = false, sensitive: Bool = false) {
        self.id = id; self.text = text; self.role = role; self.kind = kind
        self.sessionID = sessionID; self.project = project; self.timestamp = timestamp
        self.provider = provider; self.model = model; self.application = application; self.locator = locator
        self.attributes = attributes; self.links = links; self.deleted = deleted; self.sensitive = sensitive
    }
    var occurredAt: Date? { timestamp.flatMap(EvidenceDates.parse) }

    /// These are recorded fields, not an inference that a tool attempt succeeded.
    var contextMetadata: String {
        var fields = [("provider", provider), ("model", model), ("app", application)]
        fields += ["status", "exit_code", "is_error", "tool_name", "date", "timezone", "unit", "revision"].map { ($0, attributes[$0]) }
        return fields.compactMap { key, value in
            value.map { "\(key)=\(EvidencePrivacy.utf8Prefix($0.replacingOccurrences(of: "\n", with: " "), bytes: 120))" }
        }.joined(separator: " | ")
    }
}

nonisolated struct ImportIssue: Codable, Equatable, Sendable {
    var message: String
    var line: Int?
    init(_ message: String, line: Int? = nil) { self.message = message; self.line = line }
}

/// A complete document is authoritative for its own records. A partial document only upserts its
/// verified prefix: missing records are NEVER interpreted as deletions, and its fingerprint is not accepted.
nonisolated struct ImportDocument: Sendable {
    var id: String
    var records: [EvidenceRecord]
    var complete: Bool
    var issues: [ImportIssue]
    var replaceExisting: Bool
    init(id: String, records: [EvidenceRecord], complete: Bool = true, issues: [ImportIssue] = [],
         replaceExisting: Bool = true) {
        self.id = id; self.records = records; self.complete = complete; self.issues = issues
        self.replaceExisting = replaceExisting
    }
}

nonisolated enum ContextError: LocalizedError {
    case invalid(String), unavailable(String), limit(String), database(String)
    var errorDescription: String? {
        switch self { case .invalid(let m), .unavailable(let m), .limit(let m), .database(let m): m }
    }
}

nonisolated enum EvidenceIdentity {
    static func projectKey(sourceID: String, project: String) -> String { "project:" + digest(sourceID + "\u{0}" + project) }
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum EvidenceDates {
    /// Civil dates have no known instant or timezone. Never silently turn them into UTC midnight.
    static func parse(_ value: String) -> Date? {
        guard value.contains("T") else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
