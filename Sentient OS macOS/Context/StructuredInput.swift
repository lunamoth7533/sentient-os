// Bounded input snapshots and physical JSONL line positions. Invalid data never means an empty source.
import Foundation

nonisolated struct JSONLine {
    var number: Int
    var object: [String: Any]
}
nonisolated struct JSONLines {
    var lines: [JSONLine]
    var complete: Bool
    var issues: [ImportIssue]
}

nonisolated enum StructuredInput {
    static let maximumBytes = 64 * 1_024 * 1_024
    static func readData(at url: URL, maxBytes: Int = maximumBytes) throws -> Data {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContextError.invalid("Choose a regular file. Symbolic links are not imported.")
        }
        guard (values.fileSize ?? 0) <= maxBytes else {
            throw ContextError.limit("Input exceeds the \(maxBytes / 1_024 / 1_024) MiB limit. Export a smaller session or split the source.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: min(65_536, maxBytes + 1 - data.count)), !part.isEmpty {
            try Task.checkCancellation()
            data.append(part)
            guard data.count <= maxBytes else { throw ContextError.limit("Input grew beyond the import size limit. Retry with a smaller export.") }
        }
        return data
    }

    static func jsonLines(at url: URL, maximumLines: Int = 200_000) throws -> JSONLines {
        let data = try readData(at: url)
        var lines: [JSONLine] = []
        var start = data.startIndex, number = 0
        while start < data.endIndex {
            try Task.checkCancellation()
            number += 1
            guard number <= maximumLines else { throw ContextError.limit("JSONL exceeds \(maximumLines) physical lines. Export a smaller session; no new checkpoint was accepted.") }
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let part = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            if part.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            do {
                guard let value = try JSONSerialization.jsonObject(with: Data(part)) as? [String: Any] else {
                    throw ContextError.invalid("A JSONL record must be an object.")
                }
                lines.append(JSONLine(number: number, object: value))
            } catch {
                let tail = end == data.endIndex && data.last != 10
                return JSONLines(lines: lines, complete: false, issues: [ImportIssue(
                    tail ? "An unfinished final record is waiting for its writer. Retry after the session saves."
                         : "Malformed JSON record. Correct this line in an export copy and retry; later lines have not been accepted.",
                    line: number)])
            }
        }
        return JSONLines(lines: lines, complete: true, issues: [])
    }
}
