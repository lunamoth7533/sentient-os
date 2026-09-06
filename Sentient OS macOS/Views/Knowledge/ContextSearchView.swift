import SwiftUI
import AppKit

struct ContextSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = ContextLibrary.shared
    @State private var text = ""
    @State private var project = ""
    @State private var sourceID = ""
    @State private var filterDates = false
    @State private var after = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var before = Date()
    @State private var budget = 4_096
    @State private var includeGraph = false
    @State private var result: ContextResult?
    @State private var evidence: [String: StoredEvidence] = [:]
    @State private var selectedEvidence: StoredEvidence?
    @State private var error: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Search imported context").font(.title2.bold())
                    Text("Local evidence with inspectable citations. This search does not call a model.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Search a decision, constraint, or unfinished task", text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.store == nil)
                if isSearching { ProgressView().controlSize(.small) }
            }
            HStack {
                TextField("Exact project (optional)", text: $project).textFieldStyle(.roundedBorder)
                Picker("Source", selection: $sourceID) {
                    Text("All permitted sources").tag("")
                    ForEach(library.sources) { Text($0.label).tag($0.id) }
                }.frame(maxWidth: 340)
            }
            HStack {
                Stepper("Context budget: \(budget)", value: $budget, in: 128...ContextRetriever.maximumBudget, step: 128)
                Spacer()
                Toggle("Include recorded relationships", isOn: $includeGraph)
                Toggle("Filter by time", isOn: $filterDates)
            }.font(.callout)
            if filterDates {
                HStack {
                    DatePicker("From", selection: $after)
                    DatePicker("Through", selection: $before)
                }
                Text("Time filters omit civil dates and records with no exact timestamp. Clear this filter to include them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let storeError = library.lastError, library.store == nil {
                Text(storeError).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            if let result {
                HStack {
                    Text("\(result.citations.count) citations · \(result.omitted) matches omitted").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy context") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(result.text, forType: .string)
                    }
                }
                HSplitView {
                    ScrollView {
                        Text(result.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12)
                    }.frame(minWidth: 360)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(result.citations, id: \.id) { citation in
                                Button {
                                    if let item = evidence[citation.id] { selectedEvidence = item }
                                    else { error = "This evidence changed. Search again to inspect its current record." }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("[\(citation.id.prefix(12))]").font(.system(.caption, design: .monospaced))
                                        Text(evidence[citation.id]?.source.label ?? "Source evidence").font(.callout)
                                        Text(citation.timestamp ?? "Date unknown").font(.caption).foregroundStyle(.secondary)
                                        Text(citation.locator).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).padding(.vertical, 4)
                            }
                        }.padding(.leading, 12)
                    }.frame(minWidth: 210, idealWidth: 255, maxWidth: 330)
                }
            } else {
                ContentUnavailableView("Find the evidence behind your context", systemImage: "text.magnifyingglass",
                    description: Text("Search imported records, then select a citation to inspect its role, source, metadata, and original locator."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24).frame(minWidth: 820, idealWidth: 940, minHeight: 600, idealHeight: 720)
        .task { library.refresh() }
        .sheet(item: $selectedEvidence) { ContextEvidenceDetail(item: $0) }
        .onDisappear { invalidate() }
        .onChange(of: text) { _, _ in invalidate() }
        .onChange(of: project) { _, _ in invalidate() }
        .onChange(of: sourceID) { _, _ in invalidate() }
        .onChange(of: filterDates) { _, _ in invalidate() }
        .onChange(of: after) { _, _ in invalidate() }
        .onChange(of: before) { _, _ in invalidate() }
        .onChange(of: budget) { _, _ in invalidate() }
        .onChange(of: includeGraph) { _, _ in invalidate() }
        .onChange(of: library.sources) { _, _ in invalidate() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SentientContextChanged"))) { _ in
            library.refresh(); invalidate()
        }
    }

    private func invalidate() {
        searchTask?.cancel(); searchTask = nil; searchID = UUID()
        result = nil; evidence = [:]; selectedEvidence = nil; isSearching = false; copied = false
    }

    private func search() {
        invalidate(); error = nil
        guard let store = library.store else { error = "The local context store is unavailable. Open Imported Sources to retry."; return }
        guard !filterDates || after <= before else { error = "Choose a start time before the end time."; return }
        let token = UUID(); searchID = token; isSearching = true
        let scope = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ContextQuery(text: text, project: scope.isEmpty ? nil : scope,
            sourceIDs: sourceID.isEmpty ? [] : [sourceID], after: filterDates ? after : nil,
            before: filterDates ? before : nil, tokenBudget: budget, includeGraph: includeGraph)
        searchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { () throws -> ContextSearchSnapshot in
                try Task.checkCancellation()
                let result = try ContextRetriever.retrieve(store: store, query: query, audience: .local)
                let selected = try result.citations.compactMap { try store.evidence(citation: $0, audience: .local) }
                try Task.checkCancellation()
                return ContextSearchSnapshot(result: result, evidence: Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) }))
            }
            do {
                let snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, searchID == token else { return }
                result = snapshot.result; evidence = snapshot.evidence; isSearching = false
            } catch is CancellationError {
                if searchID == token { isSearching = false }
            } catch {
                guard searchID == token else { return }
                self.error = StructuredImporter.safeMessage(error); isSearching = false
            }
        }
    }
}

nonisolated private struct ContextSearchSnapshot: Sendable {
    let result: ContextResult
    let evidence: [String: StoredEvidence]
}

private struct ContextEvidenceDetail: View {
    let item: StoredEvidence
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Source evidence").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(item.record.role.attribution).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        detail("Source", item.source.label)
                        detail("Format", item.source.kind.label)
                        detail("Record ID", item.record.id)
                        detail("Project", item.record.project ?? "Unknown")
                        detail("Session", item.record.sessionID ?? "Not recorded")
                        detail("Timestamp", item.record.timestamp ?? "Unknown")
                        detail("Provider", item.record.provider ?? "Unknown")
                        detail("Model", item.record.model ?? "Not recorded")
                        detail("Locator", item.record.locator)
                        detail("Privacy", item.record.sensitive ? "Sensitive source material" : "Source permissions apply")
                    }
                    Divider()
                    Text(item.record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !item.record.attributes.isEmpty {
                        Divider()
                        Text("Recorded metadata").font(.headline)
                        ForEach(item.record.attributes.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption.bold())
                                Text(item.record.attributes[key] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    if !item.record.links.isEmpty {
                        Divider()
                        Text("Recorded relationships").font(.headline)
                        ForEach(Array(item.record.links.enumerated()), id: \.offset) { _, link in
                            Text("\(link.relation): \(link.target)").font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            Button("Show source location in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.source.path)])
            }
        }.padding(24).frame(width: 680, height: 620)
    }
    @ViewBuilder private func detail(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
