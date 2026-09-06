// Content gates used before persistence and again before sharing; imported text is never authority.
import Foundation

nonisolated enum ContextAudience: String, Codable, Sendable { case local, shared }

nonisolated enum EvidencePrivacy {
    private static let secrets = [
        #"(?s)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?(?:-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|$)"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}"#,
        #"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)(?:\\*[\"'])?\s*[=:]\s*(?:\\*[\"'])?[^\s\"']{8,}"#,
        #"\b\d{3}-\d{2}-\d{4}\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Secrets are rejected as a whole record, including metadata. No content-bearing tombstone is kept.
    static func sanitize(_ value: EvidenceRecord) -> EvidenceRecord? {
        if value.attributes["origin"]?.lowercased() == "sentient" { return nil }
        guard let data = try? JSONEncoder().encode(value), let all = String(data: data, encoding: .utf8) else { return nil }
        // Encoding adds backslashes around quoted command arguments. Inspect native strings as
        // well as the encoded structure so dotenv, shell and nested tool JSON cannot evade filtering.
        let fields = [value.id, value.text, value.kind, value.sessionID, value.project, value.timestamp,
                      value.provider, value.model, value.application, value.locator].compactMap { $0 }
            + value.attributes.flatMap { [$0.key, $0.value, $0.key + "=" + $0.value] }
            + value.links.flatMap { [$0.relation, $0.target] }
        guard !containsSecret(all), !fields.contains(where: containsSecret) else { return nil }
        var result = value
        if result.deleted { result.text = ""; result.attributes = result.attributes.filter { ["revisionTimestamp", "revision", "day", "metric"].contains($0.key) }; result.links = [] }
        if result.text.utf8.count > 65_536 {
            result.attributes["originalTextBytes"] = String(result.text.utf8.count)
            result.attributes["textTruncated"] = "true"
            result.text = utf8Prefix(result.text, bytes: 65_536)
        }
        return result
    }

    static func sharingText(_ value: String) -> String {
        var text = value
        // Recheck older stored text at the output boundary. Withhold an entire credential-bearing
        // line, and entire PEM blocks, so a quoted secret containing spaces cannot leak a suffix.
        if let pem = secrets.first {
            text = pem.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[secret removed]")
        }
        text = text.components(separatedBy: "\n").map { containsSecret($0) ? "[secret removed]" : $0 }.joined(separator: "\n")
        for (pattern, replacement) in [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email removed]"),
            (#"(?<!\d)(?:\+?\d{1,3}[- .])?(?:\(\d{3}\)|\d{3})[- .]\d{3}[- .]\d{4}(?!\d)"#, "[phone removed]"),
            // A space is part of a valid path. Its unquoted endpoint is ambiguous, so remove the
            // rest of that line. Also recognize JSON-escaped slashes in native tool arguments.
            (#"\\*/(?:Users|Volumes)\\*/[^\r\n]*"#, "[local path removed]")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        }
        return text
    }

    private static func containsSecret(_ text: String) -> Bool {
        secrets.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        if text.utf8.count <= bytes { return text }
        var data = Data(text.utf8.prefix(bytes))
        while !data.isEmpty {
            if let value = String(data: data, encoding: .utf8) { return value }
            data.removeLast()
        }
        return ""
    }
}
