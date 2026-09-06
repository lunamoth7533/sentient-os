// Enumerates explicitly selected sources and commits coherent document snapshots with retryable status.
import Foundation

nonisolated struct StructuredImporter: Sendable {
    let store: EvidenceStore
    var excludedRoots: [URL] = []

    @discardableResult
    func run(source: ImportSource, progress: @Sendable (ImportStatus) -> Void = { _ in }) throws -> ImportStatus {
        guard source.enabled else { throw ContextError.unavailable("Collection is stopped. Enable collection before importing again.") }
        var status = ImportStatus(state: "running", message: "Reading source files…", attemptedAt: Date())
        try store.setStatus(status, sourceID: source.id); progress(status)
        do {
            let files = try Self.files(for: source, excluding: excludedRoots)
            var issues: [String] = []
            for file in files {
                try Task.checkCancellation()
                do {
                    let database = ["sqlite", "db"].contains(file.pathExtension.lowercased())
                    let before = database ? "" : EvidenceIdentity.digest(try StructuredInput.readData(at: file))
                    if !database, try store.isCurrent(sourceID: source.id, fileID: file.path, fingerprint: before) {
                        status.files += 1; continue
                    }
                    let documents: [ImportDocument]
                    switch source.kind {
                    case .codex, .claudeCode, .hermes, .openClaw: documents = try SessionAdapters.parse(url: file, source: source)
                    case .lattice: documents = try LatticeAdapter.parse(url: file, source: source)
                    case .metricsCSV: documents = try MetricsCSVAdapter.parse(url: file, source: source)
                    case .markdown: documents = try Self.markdown(file, source: source)
                    }
                    if !database {
                        let after = EvidenceIdentity.digest(try StructuredInput.readData(at: file))
                        guard before == after else { throw ContextError.unavailable("Source changed while being read. Retry after its writer finishes saving.") }
                    }
                    guard try store.source(source.id) == source else {
                        throw ContextError.unavailable("Source settings changed during import. Retry using the current settings.")
                    }
                    let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                    try store.commit(sourceID: source.id, fileID: file.path, fingerprint: before, documents: documents, expectedSource: source, snapshotDate: modified)
                    for document in documents {
                        for issue in document.issues {
                            issues.append("\(file.lastPathComponent)\(issue.line.map { ":\($0)" } ?? ""): \(issue.message)")
                        }
                        if !document.complete && document.issues.isEmpty { issues.append("\(file.lastPathComponent): incomplete input; retry after the writer finishes.") }
                    }
                    status.files += 1
                } catch is CancellationError { throw CancellationError() }
                catch {
                    issues.append("\(file.lastPathComponent): \(Self.safeMessage(error))")
                }
                status.message = "Read \(status.files) of \(files.count) files"
                status.records = try store.counts(sourceID: source.id)
                progress(status)
            }
            // Missing files mean deletion only after the whole directory was successfully readable.
            if issues.isEmpty { try store.reconcileFiles(sourceID: source.id, retaining: Set(files.map(\.path)), expectedSource: source) }
            status.records = try store.counts(sourceID: source.id)
            status.state = issues.isEmpty ? "complete" : "partial"
            status.message = issues.isEmpty ? "\(status.records) current records · \(status.files) files checked"
                : issues.prefix(5).joined(separator: "\n") + (issues.count > 5 ? "\n\(issues.count - 5) more file issues; narrow the source folder to inspect them." : "")
        } catch is CancellationError {
            status.state = "cancelled"; status.message = "Stopped. Completed files are saved; retry resumes from their checkpoints."
        } catch {
            status.state = "failed"; status.message = Self.safeMessage(error)
        }
        try store.setStatus(status, sourceID: source.id); progress(status)
        return status
    }

    static func safeMessage(_ error: Error) -> String {
        if error is ContextError { return error.localizedDescription }
        return "Could not read this source (\((error as NSError).domain), code \((error as NSError).code)). Check access and retry. Previously saved records have been preserved."
    }

    static func files(for source: ImportSource, excluding roots: [URL] = []) throws -> [URL] {
        let root = URL(fileURLWithPath: source.path).standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, !isGenerated(root, excluded: roots) else {
            throw ContextError.invalid("Sentient's generated knowledge and symbolic links cannot be imported as independent source evidence.")
        }
        let resolvedPath = root.resolvingSymlinksInPath().path
        if source.kind == .lattice, [source.path, resolvedPath].contains(where: { $0.contains("/Application Support/") || $0.contains("/Containers/") }) {
            throw ContextError.invalid("Select a Lattice Workbench export or an explicit personal snapshot copy outside live app storage.")
        }
        if values.isDirectory != true { return [root] }
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ContextError.unavailable("Could not enumerate the selected source folder. Check its access permissions.")
        }
        var result: [URL] = []
        for case let file as URL in iterator {
            try Task.checkCancellation()
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if metadata.isSymbolicLink == true || isGenerated(file, excluded: roots) {
                if metadata.isDirectory == true { iterator.skipDescendants() }
                continue
            }
            guard metadata.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            let eligible: Bool
            switch source.kind {
            case .codex, .claudeCode: eligible = ext == "jsonl"
            case .hermes: eligible = file.lastPathComponent == "state.db" || ext == "json"
            case .openClaw: eligible = file.lastPathComponent == "openclaw-agent.sqlite" || ext == "jsonl"
            case .lattice: eligible = ext == "json"
            case .markdown: eligible = ext == "md"
            case .metricsCSV: eligible = ext == "csv"
            }
            if eligible { result.append(file.standardizedFileURL) }
            guard result.count <= 10_000 else { throw ContextError.limit("This source contains more than 10,000 files. Choose narrower project or session folders.") }
        }
        if let enumerationError { throw enumerationError }
        if source.kind == .hermes, let native = result.first(where: { $0.lastPathComponent == "state.db" }) {
            return [native] // Session JSON mirrors repeat the canonical database's evidence.
        }
        if source.kind == .hermes { result.removeAll { $0.lastPathComponent == "sessions.json" } }
        if source.kind == .openClaw {
            let nativeRoots = result.filter { $0.lastPathComponent == "openclaw-agent.sqlite" }
                .map { $0.deletingLastPathComponent().deletingLastPathComponent().path + "/" }
            result.removeAll { file in
                file.pathExtension == "jsonl" && (nativeRoots.contains { file.path.hasPrefix($0) }
                    || file.path.contains("/trajectory") || file.lastPathComponent.contains(".deleted."))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func isGenerated(_ url: URL, excluded: [URL]) -> Bool {
        let candidates = [url.standardizedFileURL, url.resolvingSymlinksInPath().standardizedFileURL]
        for candidate in candidates {
            if candidate.pathComponents.contains(where: { $0 == "Sentient OS - Knowledge Base" || $0.hasPrefix(".sentientos-vault-staging-") || $0 == "SentientOS" }) { return true }
            if excluded.contains(where: { root in
                let path = root.resolvingSymlinksInPath().standardizedFileURL.path
                return candidate.path == path || candidate.path.hasPrefix(path + "/")
            }) { return true }
        }
        return false
    }

    private static func markdown(_ file: URL, source: ImportSource) throws -> [ImportDocument] {
        let data = try StructuredInput.readData(at: file)
        guard let text = String(data: data, encoding: .utf8) else { throw ContextError.invalid("Markdown must be UTF-8. Export a UTF-8 copy and retry.") }
        if text.contains("<!-- sentient-generated-context -->") { return [ImportDocument(id: file.path, records: [])] }
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return [ImportDocument(id: file.path, records: [EvidenceRecord(id: file.path, text: text,
            role: .observation, kind: "document", project: source.project,
            timestamp: modified.map(EvidenceDates.string), application: "Markdown", locator: file.path,
            attributes: ["timestampMeaning": "file modification time; authorship and factual date unknown"])])]
    }
}

nonisolated enum SourceDiscovery {
    /// Suggestions are metadata-only. Nothing is read until the user adds a source and imports it.
    static func available(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportSource] {
        let candidates: [(ImportSourceKind, String, String)] = [
            (.codex, ".codex/sessions", "Codex CLI and desktop rollouts"),
            (.codex, ".codex/archived_sessions", "Archived Codex rollouts"),
            (.claudeCode, ".claude/projects", "Claude Code project sessions"),
            (.hermes, ".hermes/state.db", "Hermes local session database"),
            (.openClaw, ".openclaw/agents", "OpenClaw agent sessions")
        ]
        return candidates.compactMap { kind, path, label in
            let url = home.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ImportSource(kind: kind, path: url.path, label: label)
        }
    }
}
