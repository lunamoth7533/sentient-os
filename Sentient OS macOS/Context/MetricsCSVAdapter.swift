import Foundation

nonisolated enum MetricsCSVAdapter {
    private static let header = ["id", "metric", "value", "unit", "date", "timezone", "updated_at", "deleted", "source"]

    static func parse(url: URL, source: ImportSource) throws -> [ImportDocument] {
        let data = try StructuredInput.readData(at: url)
        let rows = try parseRows(data)
        guard rows.first == header else {
            throw ContextError.invalid("Metrics CSV requires the exact header: \(header.joined(separator: ",")).")
        }
        var seen = Set<String>()
        let records = try rows.dropFirst().enumerated().map { index, row -> EvidenceRecord in
            try Task.checkCancellation()
            guard row.count == header.count else { throw ContextError.invalid("Metrics CSV row \(index + 2) must contain exactly nine columns.") }
            let id = row[0], metric = row[1], unit = row[3], date = row[4], zone = row[5]
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 512,
                  !metric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted else { throw ContextError.invalid("Metrics CSV requires a unique nonempty ID, metric, and unit for every row.") }
            guard MetricImportSupport.isCivilDay(date) || (try? MetricImportSupport.instant(date)) != nil else {
                throw ContextError.invalid("Metrics CSV dates must be real civil dates or timestamps with explicit offsets.")
            }
            guard zone.isEmpty || TimeZone(identifier: zone) != nil else { throw ContextError.invalid("Metrics CSV contains an unknown timezone identifier.") }
            _ = try MetricImportSupport.instant(row[6])
            guard row[7] == "true" || row[7] == "false" else { throw ContextError.invalid("Metrics CSV deleted values must be true or false.") }
            let deleted = row[7] == "true"
            let value: Double?
            if row[2].isEmpty { value = nil }
            else {
                guard let parsed = Double(row[2]), parsed.isFinite else { throw ContextError.invalid("Metrics CSV values must be finite numbers or empty.") }
                value = parsed
            }
            guard !deleted || value == nil else { throw ContextError.invalid("A deleted CSV row must have an empty value.") }
            var attributes = ["schema": "sentient.metrics-csv.v1", "metric": metric, "unit": unit,
                              "date": date, "timezone": zone.isEmpty ? "unknown" : zone,
                              "revisionTimestamp": row[6], "revision": "",
                              "availability": deleted ? "deleted" : (value == nil ? "unknown" : "recorded")]
            if let value { attributes["value"] = MetricImportSupport.number(value) }
            let observation = value.map { "\(MetricImportSupport.number($0)) \(unit)" } ?? "unrecorded (unknown)"
            return EvidenceRecord(id: id, text: deleted ? "" : "\(metric): \(observation) on \(date).",
                role: .observation, kind: "personal_metric", project: source.project, timestamp: date,
                provider: row[8].isEmpty ? nil : row[8], application: "Metrics CSV", locator: url.path,
                attributes: attributes, deleted: deleted, sensitive: true)
        }
        return [ImportDocument(id: url.standardizedFileURL.path, records: records)]
    }

    /// An RFC 4180 state machine: quoted fields may contain commas, CR/LF and escaped quotes.
    /// Rejects incomplete files atomically, so a truncated write cannot delete prior observations.
    private static func parseRows(_ data: Data) throws -> [[String]] {
        var bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw ContextError.invalid("Metrics CSV must be valid UTF-8.") }
        enum State { case beginning, unquoted, quoted, closedQuote }
        var state = State.beginning, index = 0
        var field: [UInt8] = [], row: [String] = [], rows: [[String]] = []
        var rowStarted = false
        func finishField() throws {
            let value = String(decoding: field, as: UTF8.self)
            guard value.count <= 8_192 else { throw ContextError.limit("A metrics CSV field exceeds 8,192 characters.") }
            row.append(value); field.removeAll(keepingCapacity: true); state = .beginning
            guard row.count <= header.count else { throw ContextError.invalid("Metrics CSV contains extra columns.") }
        }
        func finishRow() throws {
            try finishField()
            rows.append(row); row.removeAll(keepingCapacity: true); rowStarted = false
            guard rows.count <= MetricImportSupport.maximumRecords + 1 else { throw ContextError.limit("Metrics CSV allows at most 50,000 records.") }
        }
        while index < bytes.count {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            if state == .quoted {
                if byte == 34 { state = .closedQuote } else { field.append(byte) }
            } else if state == .closedQuote, byte == 34 {
                field.append(34); state = .quoted
            } else if byte == 44 {
                try finishField(); rowStarted = true
            } else if byte == 10 || byte == 13 {
                try finishRow()
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
            } else {
                guard state != .closedQuote else { throw ContextError.invalid("Only a delimiter or newline may follow a closing CSV quote.") }
                if byte == 34 {
                    guard state == .beginning else { throw ContextError.invalid("Quotes inside a CSV field must be escaped and the field must be quoted.") }
                    state = .quoted
                } else { field.append(byte); state = .unquoted }
                rowStarted = true
            }
            guard field.count <= 32_768 else { throw ContextError.limit("A metrics CSV field exceeds its size limit.") }
            index += 1
        }
        guard state != .quoted else { throw ContextError.invalid("Metrics CSV ends inside an unfinished quoted field.") }
        if rowStarted || !row.isEmpty || !field.isEmpty { try finishRow() }
        return rows
    }
}
