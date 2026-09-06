import Foundation
import Observation

/// UI ownership for the local evidence store. Parsing and projection work run off the main actor.
@MainActor @Observable
final class ContextLibrary {
    static let shared = ContextLibrary()

    private(set) var store: EvidenceStore?
    private(set) var sources: [ImportSource] = []
    private(set) var statuses: [String: ImportStatus] = [:]
    private(set) var isImporting = false
    private(set) var isCancelling = false
    private(set) var importingSourceID: String?
    private(set) var projectionReady = false
    var lastError: String?

    @ObservationIgnored private var importTask: Task<Bool, Never>?
    @ObservationIgnored private var workerTask: Task<ImportStatus, Error>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var activeSourceIDs = Set<String>()
    @ObservationIgnored private var importingAllEnabled = false
    @ObservationIgnored private var projectionTask: Task<Bool, Never>?
    @ObservationIgnored private var projectionGeneration: UInt64 = 0

    init(store: EvidenceStore? = nil) {
        if let store { self.store = store }
        else {
            do { self.store = try ContextPaths.openStore() }
            catch { lastError = StructuredImporter.safeMessage(error) }
        }
        refresh()
    }

    func refresh() {
        guard let store else { return }
        do {
            let nextSources = try store.sources()
            let nextStatuses = try Dictionary(uniqueKeysWithValues: nextSources.map { ($0.id, try store.status($0.id)) })
            sources = nextSources; statuses = nextStatuses
        } catch { lastError = StructuredImporter.safeMessage(error) }
    }

    func retryOpen() {
        guard store == nil else { refresh(); return }
        do { store = try ContextPaths.openStore(); lastError = nil; refresh() }
        catch { lastError = StructuredImporter.safeMessage(error) }
    }

    /// Adding a source saves configuration only. Importing is a separate explicit action.
    @discardableResult func add(_ source: ImportSource) -> Bool {
        guard let store else { return unavailable() }
        do {
            guard try store.source(source.id) == nil else { throw ContextError.invalid("This source is already configured.") }
            try store.saveSource(source)
            invalidateProjection()
            lastError = nil; refresh(); notifyChange()
            Task { await publishProjection() }
            return true
        } catch { lastError = StructuredImporter.safeMessage(error); return false }
    }

    @discardableResult func save(_ source: ImportSource) -> Bool {
        guard let store else { return unavailable() }
        do {
            guard let existing = try store.source(source.id) else { throw ContextError.unavailable("This source was removed. Refresh the source list.") }
            guard source.path == existing.path, source.kind == existing.kind else {
                throw ContextError.invalid("Add a new source to change its location or format.")
            }
            if activeSourceIDs.contains(source.id), source != existing { cancelImport() }
            try store.saveSource(source)
            invalidateProjection()
            lastError = nil; refresh(); notifyChange()
            Task { await publishProjection() }
            return true
        } catch { lastError = StructuredImporter.safeMessage(error); refresh(); return false }
    }

    /// Deletes only Sentient's configuration and imported evidence, never the original source files.
    @discardableResult func remove(_ source: ImportSource) -> Bool {
        guard let store else { return unavailable() }
        do {
            if activeSourceIDs.contains(source.id) { cancelImport() }
            try store.removeSource(source.id)
            invalidateProjection()
            lastError = nil; refresh(); notifyChange()
            Task { await publishProjection() }
            return true
        } catch { lastError = StructuredImporter.safeMessage(error); return false }
    }

    @discardableResult func importSource(_ id: String) async -> Bool {
        if let task = importTask { return await task.value }
        return await start(sourceIDs: [id], allEnabled: false)
    }

    /// Analyze Now and scheduled callers await real completion, including a batch already underway.
    /// If a single-source import is underway, finish it before checking the whole enabled set.
    @discardableResult func importEnabled() async -> Bool {
        if let task = importTask {
            let wasFullBatch = importingAllEnabled
            let succeeded = await task.value
            if wasFullBatch || !succeeded || Task.isCancelled { return succeeded && !Task.isCancelled }
        }
        refresh()
        guard store != nil else { return unavailable() }
        return await start(sourceIDs: sources.filter(\.enabled).map(\.id), allEnabled: true)
    }

    func cancelImport() {
        guard isImporting else { return }
        isCancelling = true
        importTask?.cancel()
        workerTask?.cancel()
    }

    private func start(sourceIDs: [String], allEnabled: Bool) async -> Bool {
        if let task = importTask { return await task.value }
        guard let store else { return unavailable() }
        guard !Task.isCancelled else { return false }
        guard !sourceIDs.isEmpty else { return true }
        let id = UUID()
        operationID = id; activeSourceIDs = Set(sourceIDs); importingAllEnabled = allEnabled
        isImporting = true; isCancelling = false; lastError = nil
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let success = await self.perform(sourceIDs: sourceIDs, store: store, operation: id)
            if self.operationID == id {
                self.workerTask = nil; self.importTask = nil; self.operationID = nil
                self.activeSourceIDs = []; self.importingSourceID = nil
                self.isImporting = false; self.isCancelling = false; self.importingAllEnabled = false
                self.refresh()
            }
            return success
        }
        importTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func perform(sourceIDs: [String], store: EvidenceStore, operation: UUID) async -> Bool {
        var failures: [String] = []
        for id in sourceIDs {
            guard !Task.isCancelled, operationID == operation else { break }
            do {
                guard let source = try store.source(id), source.enabled else {
                    failures.append("A selected source was removed or collection was stopped.")
                    continue
                }
                importingSourceID = id
                invalidateProjection(); notifyChange()
                let progress: @Sendable (ImportStatus) -> Void = { [weak self] status in
                    guard let library = self else { return }
                    Task { @MainActor in
                        guard library.operationID == operation, library.importingSourceID == id,
                              library.sources.first(where: { $0.id == id }) == source else { return }
                        library.statuses[id] = status
                    }
                }
                // StructuredImporter is synchronous and can enumerate/read many files. A detached
                // worker keeps that prefix off MainActor; cancellation is explicitly forwarded.
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    guard try store.source(id) == source else { throw ContextError.unavailable("Source settings changed. Retry the current source.") }
                    return try StructuredImporter(store: store, excludedRoots: [ContextPaths.root]).run(source: source, progress: progress)
                }
                workerTask = worker
                let status = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                workerTask = nil
                if try store.source(id) == source {
                    statuses[id] = status
                    if status.state != "complete" { failures.append("\(source.label): \(status.message)") }
                } else { failures.append("Source settings changed during import. Retry the current settings.") }
                refresh()
                if !(await publishProjection()) { failures.append("Imported records were saved, but their local summaries could not be refreshed.") }
            } catch is CancellationError {
                failures.append("Import cancelled. Completed files remain saved.")
                break
            } catch { failures.append(StructuredImporter.safeMessage(error)) }
        }
        // A cancelled or throwing importer may already have committed complete files. Publish that
        // durable state too; a failed refresh leaves projections unavailable instead of showing stale files.
        if !projectionReady {
            refresh()
            if !(await publishProjection()) { failures.append("Saved records are available, but their local summaries could not be refreshed.") }
        }
        if Task.isCancelled, failures.isEmpty { failures.append("Import cancelled. Completed files remain saved.") }
        if !failures.isEmpty { lastError = failures.prefix(5).joined(separator: "\n") }
        return failures.isEmpty && !Task.isCancelled
    }

    /// Rebuild on a knowledge window's first load before it mounts any generated files.
    @discardableResult func refreshProjection() async -> Bool {
        invalidateProjection(); notifyChange()
        return await publishProjection()
    }

    private func invalidateProjection() {
        projectionGeneration &+= 1
        projectionReady = false
    }

    /// Serializes derived-file replacement. Only the current request can expose its generated files.
    @discardableResult private func publishProjection() async -> Bool {
        guard let store else { return false }
        let previous = projectionTask
        let generation = projectionGeneration
        let task = Task { [weak self] () -> Bool in
            if let previous { _ = await previous.value }
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try ContextProjection.refresh(store: store, root: store.url.deletingLastPathComponent().appendingPathComponent("Imported", isDirectory: true))
                    return nil
                }
                catch { return StructuredImporter.safeMessage(error) }
            }.value
            guard let self else { return false }
            guard self.projectionGeneration == generation else { return false }
            if let failure { self.lastError = failure }
            self.projectionReady = failure == nil
            self.notifyChange()
            return self.projectionReady
        }
        projectionTask = task
        return await task.value
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Notification.Name("SentientContextChanged"), object: nil)
    }
    private func unavailable() -> Bool {
        lastError = "The local context store is unavailable. Retry opening it before changing sources."
        return false
    }
}
