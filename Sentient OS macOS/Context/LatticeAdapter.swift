import Foundation

nonisolated enum LatticeAdapter {
    static func parse(url: URL, source: ImportSource) throws -> [ImportDocument] {
        let data = try StructuredInput.readData(at: url)
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if let schema = header.schema {
                guard schema == "lattice.context-capsule.v1" else {
                    throw ContextError.invalid("Unsupported Lattice schema. Select an exported context-capsule v1 JSON file.")
                }
                guard data.count <= 1_048_576 else { throw ContextError.limit("A Lattice context capsule must be at most 1 MiB.") }
                let capsule = try JSONDecoder().decode(Capsule.self, from: data)
                return [try capsule.document(url: url)]
            }
            guard header.version == 1 else {
                throw ContextError.invalid("Select a Lattice context capsule or an explicitly chosen version 1 personal snapshot copy.")
            }
            let snapshot = try JSONDecoder().decode(PersonalSnapshot.self, from: data)
            guard snapshot.records.count <= MetricImportSupport.maximumRecords else {
                throw ContextError.limit("A personal snapshot copy must contain at most 50,000 records.")
            }
            let records = try snapshot.records.sorted { $0.key < $1.key }.map { id, record in
                try Task.checkCancellation()
                return try record.evidence(dictionaryID: id, url: url, source: source)
            }
            return [ImportDocument(id: url.standardizedFileURL.path, records: records)]
        } catch let error as ContextError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Decoding diagnostics can quote source values; expose only the structural failure.
            throw ContextError.invalid("Malformed Lattice JSON. Check the documented field types and required fields; no records were imported.")
        }
    }

    private struct Header: Decodable { let schema: String?; let version: Int? }
    private struct Project: Decodable {
        let id: String; let name: String; let repository: String?; let aliases: [String]
    }
    private struct Provenance: Decodable { let capsuleID: String; let generatedAt: String }
    private struct Event: Decodable {
        let id: String; let projectID: String; let threadID: String?; let occurredAt: String
        let kind: String; let status: String; let source: String; let title: String; let summary: String
        let evidence: [String]; let metadata: [String: String]; let capsuleProvenance: Provenance?
    }
    private struct Release: Decodable {
        let id: String; let projectID: String; let version: String; let build: String; let commitSHA: String
        let occurredAt: String; let processingStatus: String; let source: String
        let testingGroup: String?; let ciStatus: String?; let localTestSummary: String?; let deliveryID: String?
        let blockers: [String]; let workarounds: [String]; let openLoops: [String]; let capsuleProvenance: Provenance?
        private enum CodingKeys: String, CodingKey {
            case id, projectID, version, build, commitSHA, occurredAt, processingStatus, source
            case testingGroup, ciStatus, localTestSummary, deliveryID, blockers, workarounds, openLoops, capsuleProvenance
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); projectID = try c.decode(String.self, forKey: .projectID)
            version = try c.decode(String.self, forKey: .version); build = try c.decode(String.self, forKey: .build)
            commitSHA = try c.decode(String.self, forKey: .commitSHA); occurredAt = try c.decode(String.self, forKey: .occurredAt)
            processingStatus = try c.decode(String.self, forKey: .processingStatus)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? "Release"
            testingGroup = try c.decodeIfPresent(String.self, forKey: .testingGroup)
            ciStatus = try c.decodeIfPresent(String.self, forKey: .ciStatus)
            localTestSummary = try c.decodeIfPresent(String.self, forKey: .localTestSummary)
            deliveryID = try c.decodeIfPresent(String.self, forKey: .deliveryID)
            blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
            workarounds = try c.decodeIfPresent([String].self, forKey: .workarounds) ?? []
            openLoops = try c.decodeIfPresent([String].self, forKey: .openLoops) ?? []
            capsuleProvenance = try c.decodeIfPresent(Provenance.self, forKey: .capsuleProvenance)
        }
    }
    private struct Capsule: Decodable {
        let schema: String; let id: String; let generatedAt: String; let project: Project
        let provider: String; let goal: String; let events: [Event]; let releases: [Release]; let redactions: [String]

        func document(url: URL) throws -> ImportDocument {
            try identifier(id); try identifier(project.id)
            try bounded(project.name, 512); try bounded(project.repository, 2_048)
            for alias in project.aliases { try bounded(alias, 512) }
            try bounded(goal, 8_192)
            let generated = try MetricImportSupport.instant(generatedAt)
            guard ["lattice", "claude", "codex", "kimi", "hermes", "human", "other"].contains(provider) else {
                throw ContextError.invalid("Unsupported provider in Lattice capsule.")
            }
            guard events.count <= 500, releases.count <= 25 else { throw ContextError.limit("Lattice capsules allow at most 500 events and 25 releases.") }
            for note in redactions { try bounded(note, 2_048) }
            let revision = EvidenceDates.string(generated)
            let prefix = "project:\(component(project.id))"
            // Capsule IDs identify context snapshots; native Lattice does not use them to order equal-time edits.
            let common = ["schema": schema, "revisionTimestamp": revision, "revision": "", "capsuleID": id]
            var contextAttributes = common
            contextAttributes["projectName"] = project.name
            var contextLines = ["Project: \(project.name)", "Current goal: \(goal)"]
            contextLines += redactions.map { "Declared omission: \($0)" }
            var result = [EvidenceRecord(id: "\(prefix):context:\(component(id))", text: contextLines.joined(separator: "\n"),
                role: .summary, kind: "lattice_context", project: project.id, timestamp: generatedAt,
                provider: provider, application: "Lattice", locator: url.path, attributes: contextAttributes)]
            var eventIDs = Set<String>()
            for event in events {
                try Task.checkCancellation()
                try identifier(event.id)
                if let thread = event.threadID { try identifier(thread) }
                guard event.projectID == project.id, eventIDs.insert(event.id).inserted else {
                    throw ContextError.invalid("Lattice events must have unique IDs and stay within the capsule project.")
                }
                guard ["agent_session", "build", "test", "continuous_integration", "research", "decision", "open_loop", "release", "custom"].contains(event.kind),
                      ["planned", "running", "succeeded", "failed", "blocked", "cancelled", "informational"].contains(event.status) else {
                    throw ContextError.invalid("Unsupported event kind or status in Lattice capsule.")
                }
                _ = try MetricImportSupport.instant(event.occurredAt)
                try bounded(event.source, 512); try bounded(event.title, 512); try bounded(event.summary, 8_192)
                for evidence in event.evidence { try bounded(evidence, 2_048) }
                guard event.metadata.count <= 64 else { throw ContextError.limit("Lattice event metadata exceeds 64 entries.") }
                var attributes = common
                attributes["status"] = event.status; attributes["nativeKind"] = event.kind; attributes["source"] = event.source
                for (key, value) in event.metadata {
                    try bounded(key, 128); try bounded(value, 4_096)
                    // Producer metadata cannot override IDs, revision ordering, or trusted attribution fields.
                    attributes["metadata.\(key)"] = value
                }
                try apply(event.capsuleProvenance, to: &attributes)
                result.append(EvidenceRecord(id: "\(prefix):event:\(component(event.id))", text: "\(event.title)\n\(event.summary)",
                    role: .summary, kind: "lattice_\(event.kind)", sessionID: event.threadID, project: project.id,
                    timestamp: event.occurredAt, provider: provider, application: "Lattice", locator: url.path,
                    attributes: attributes, links: event.evidence.map { EvidenceLink(relation: "evidence", target: $0) }))
            }
            var releaseIDs = Set<String>()
            for release in releases {
                try Task.checkCancellation()
                try identifier(release.id)
                guard release.projectID == project.id, releaseIDs.insert(release.id).inserted else {
                    throw ContextError.invalid("Lattice releases must have unique IDs and stay within the capsule project.")
                }
                _ = try MetricImportSupport.instant(release.occurredAt)
                for value in [release.version, release.build, release.commitSHA, release.processingStatus, release.source,
                              release.testingGroup, release.ciStatus, release.deliveryID] { try bounded(value, 512) }
                try bounded(release.localTestSummary, 8_192)
                for value in release.blockers + release.workarounds + release.openLoops { try bounded(value, 8_192) }
                var attributes = common
                attributes["version"] = release.version; attributes["build"] = release.build
                attributes["commitSHA"] = release.commitSHA; attributes["processingStatus"] = release.processingStatus
                attributes["source"] = release.source; attributes["testingGroup"] = release.testingGroup
                attributes["ciStatus"] = release.ciStatus; attributes["deliveryID"] = release.deliveryID
                try apply(release.capsuleProvenance, to: &attributes)
                var lines = ["Release \(release.version) (\(release.build))", "Processing: \(release.processingStatus)"]
                if let ci = release.ciStatus { lines.append("CI: \(ci)") }
                if let local = release.localTestSummary { lines.append("Local tests: \(local)") }
                lines += release.blockers.map { "Blocker: \($0)" }
                lines += release.workarounds.map { "Workaround: \($0)" }
                lines += release.openLoops.map { "Open loop: \($0)" }
                result.append(EvidenceRecord(id: "\(prefix):release:\(component(release.id))", text: lines.joined(separator: "\n"),
                    role: .summary, kind: "lattice_release", project: project.id, timestamp: release.occurredAt,
                    provider: provider, application: "Lattice", locator: url.path, attributes: attributes))
            }
            return ImportDocument(id: url.standardizedFileURL.path, records: result, replaceExisting: false)
        }
    }

    private static func bounded(_ value: String?, _ count: Int) throws {
        guard (value?.count ?? 0) <= count else { throw ContextError.limit("A Lattice capsule field exceeds its native size limit.") }
    }
    private static func identifier(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil else {
            throw ContextError.invalid("Invalid identifier in Lattice capsule.")
        }
    }
    private static func component(_ value: String) -> String {
        value.utf8.map { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95, 126].contains(byte)
                ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
    private static func apply(_ provenance: Provenance?, to attributes: inout [String: String]) throws {
        guard let provenance else { return }
        try identifier(provenance.capsuleID)
        _ = try MetricImportSupport.instant(provenance.generatedAt)
        attributes["originalCapsuleID"] = provenance.capsuleID
        attributes["originalCapsuleGeneratedAt"] = provenance.generatedAt
    }

    private struct PersonalSnapshot: Decodable {
        let version: Int
        let records: [String: PersonalRecord]
        let pending: [String]
    }
    private struct CheckIn: Decodable {
        let day: String; let mood: Int; let energy: Int?; let stress: Int?; let focus: Int?
        let caffeineMg: Double?; let outdoorMinutes: Double?
    }
    private struct PersonalRecord: Decodable {
        let id: String; let day: String; let checkIn: CheckIn?; let metric: String?; let value: Double?
        let updatedAt: Double; let revision: String; let deleted: Bool

        func evidence(dictionaryID: String, url: URL, source: ImportSource) throws -> EvidenceRecord {
            guard id == dictionaryID, MetricImportSupport.isCivilDay(day), updatedAt.isFinite,
                  UUID(uuidString: revision) != nil, !deleted || (checkIn == nil && value == nil) else {
                throw ContextError.invalid("Invalid personal snapshot record identity, day, revision, or deletion marker.")
            }
            let stamp = EvidenceDates.string(Date(timeIntervalSinceReferenceDate: updatedAt))
            _ = try MetricImportSupport.instant(stamp)
            var attributes = ["schema": "lattice.personal-data.v1", "day": day, "timezone": "unknown",
                              "revisionTimestamp": stamp, "revision": revision,
                              "availability": deleted ? "deleted" : "recorded"]
            var lines: [String] = []
            if id == "checkin-\(day)", metric == nil, value == nil {
                attributes["metric"] = "dailyCheckIn"
                if let checkIn {
                    guard checkIn.day == day else { throw ContextError.invalid("Check-in day disagrees with its record.") }
                    let ratings: [(String, Int?)] = [("mood", checkIn.mood), ("energyLevel", checkIn.energy),
                                                    ("stressLevel", checkIn.stress), ("focusQuality", checkIn.focus)]
                    for (name, rating) in ratings {
                        guard let rating else { continue }
                        guard (1...5).contains(rating) else { throw ContextError.invalid("Personal check-in ratings must be between 1 and 5.") }
                        attributes[name] = String(rating); attributes["unit.\(name)"] = "/5"
                        lines.append("\(name): \(rating) /5")
                    }
                    for (name, value, maximum, unit) in [("caffeineMg", checkIn.caffeineMg, 2_000.0, "mg"),
                                                         ("outdoorMinutes", checkIn.outdoorMinutes, 1_440.0, "min")] {
                        guard let value else { continue }
                        guard value.isFinite, (0...maximum).contains(value) else { throw ContextError.invalid("A personal check-in total is outside Lattice's supported range.") }
                        attributes[name] = MetricImportSupport.number(value); attributes["unit.\(name)"] = unit
                        lines.append("\(name): \(MetricImportSupport.number(value)) \(unit)")
                    }
                } else if !deleted { throw ContextError.invalid("A nondeleted check-in requires its recorded fields.") }
            } else if let metric, let unit = MetricImportSupport.latticeAggregateUnits[metric],
                      id == "metric-\(metric)-\(day)", checkIn == nil {
                attributes["metric"] = metric; attributes["unit"] = unit
                if !deleted {
                    guard let value, value.isFinite, value >= 0 else { throw ContextError.invalid("A nondeleted aggregate requires a finite, nonnegative value.") }
                    attributes["value"] = MetricImportSupport.number(value)
                    lines.append("\(metric): \(MetricImportSupport.number(value)) \(unit)")
                }
            } else { throw ContextError.invalid("Unsupported personal metric or invalid native record ID.") }
            let text = deleted ? "" : "Saved Lattice observation for \(day) (timezone unknown).\n" + lines.joined(separator: "\n")
            return EvidenceRecord(id: id, text: text, role: .observation, kind: "personal_metric",
                project: source.project, timestamp: day, provider: "Lattice", application: "Lattice",
                locator: url.path, attributes: attributes, deleted: deleted, sensitive: true)
        }
    }
}

/// Shared validation for civil days and numerical observations. These helpers do not query live sources.
nonisolated enum MetricImportSupport {
    static let maximumRecords = 50_000
    static let latticeAggregateUnits = [
        "steps": "steps", "activeEnergy": "kcal", "exerciseMinutes": "min", "distanceWalking": "km",
        "flightsClimbed": "flights", "restingEnergy": "kcal", "standTime": "min", "heartRate": "bpm",
        "restingHeartRate": "bpm", "hrv": "ms", "respiratoryRate": "br/min", "vo2Max": "ml/kg·min",
        "oxygenSaturation": "%", "walkingHeartRate": "bpm", "bodyMass": "kg", "sleepHours": "hr",
        "mindfulMinutes": "min", "calendarEventCount": "events", "calendarBusyHours": "hr",
        "meetingHours": "hr", "remindersCompleted": "done", "photosTaken": "photos"
    ]
    static func isCivilDay(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2]
    }
    static func instant(_ value: String) throws -> Date {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil,
              isCivilDay(String(value.prefix(10))), let date = EvidenceDates.parse(value), date.timeIntervalSince1970.isFinite else {
            throw ContextError.invalid("A record timestamp must be valid ISO 8601 with an explicit UTC or offset timezone.")
        }
        let bytes = Array(value.utf8)
        let hour = Int(String(decoding: bytes[11...12], as: UTF8.self)) ?? 99
        let minute = Int(String(decoding: bytes[14...15], as: UTF8.self)) ?? 99
        let second = Int(String(decoding: bytes[17...18], as: UTF8.self)) ?? 99
        guard hour < 24, minute < 60, second < 60 else { throw ContextError.invalid("A record timestamp contains an invalid clock time.") }
        return date
    }
    static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(value)
    }
}
