import SwiftUI
import AppKit

struct ImportedSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = ContextLibrary.shared
    @State private var detected: [ImportSource] = []
    @State private var showAdd = false
    @State private var removing: ImportSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported sources").font(.title2.bold())
                    Text("Keep source attribution, corrections, and permissions with your local context.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("Add file or folder…") { showAdd = true }
                Menu("Add detected source") {
                    ForEach(suggestions) { source in
                        Button(source.label) { _ = library.add(source) }
                    }
                    if suggestions.isEmpty { Text("No new sources detected") }
                }
                .disabled(suggestions.isEmpty || library.store == nil)
                Spacer()
                if library.isImporting {
                    ProgressView().controlSize(.small)
                    Button(library.isCancelling ? "Stopping…" : "Cancel import") { library.cancelImport() }
                        .disabled(library.isCancelling)
                } else {
                    Button("Import enabled sources") { Task { await library.importEnabled() } }
                        .disabled(library.store == nil || !library.sources.contains(where: \.enabled))
                }
            }
            if let error = library.lastError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    if library.store == nil { Button("Retry opening") { library.retryOpen() } }
                    else { Button("Dismiss") { library.lastError = nil } }
                }
            }
            Text("Collection controls future imports. Context controls use of saved evidence. Sharing is off until you enable it for a source; health and personal metrics stay local until then.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            if library.sources.isEmpty {
                ContentUnavailableView("No imported sources", systemImage: "tray.and.arrow.down",
                    description: Text("Add a supported session folder, Markdown file, Lattice Workbench export, or personal metrics CSV. Adding a source does not import it yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(library.sources) { source in
                            ImportedSourceRow(source: source, status: library.statuses[source.id] ?? ImportStatus(),
                                library: library, onRemove: { removing = source })
                            Divider()
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 550, idealHeight: 680)
        .task { library.refresh(); detected = SourceDiscovery.available() }
        .sheet(isPresented: $showAdd) { AddImportedSourceView(library: library) }
        .confirmationDialog("Remove this imported source?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove source and imported evidence", role: .destructive) {
                    if let removing { _ = library.remove(removing) }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("This removes Sentient's saved evidence and source configuration. The original files remain where they are.") }
    }

    private var suggestions: [ImportSource] {
        detected.filter { candidate in !library.sources.contains { $0.kind == candidate.kind && $0.path == candidate.path } }
    }
}

private struct ImportedSourceRow: View {
    let source: ImportSource
    let status: ImportStatus
    let library: ContextLibrary
    let onRemove: () -> Void
    @State private var editProject = ""
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.label).font(.headline)
                    Text(source.kind.label).font(.caption).foregroundStyle(.secondary)
                    Text(source.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Button(["partial", "failed", "cancelled"].contains(status.state) ? "Retry import" : "Import") {
                    Task { await library.importSource(source.id) }
                }.disabled(library.isImporting || !source.enabled)
                Button("Remove", role: .destructive, action: onRemove)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Collect future changes", isOn: permission(\.enabled))
                Toggle("Use saved evidence in context", isOn: permission(\.contextEnabled))
                Toggle("Share redacted excerpts with connected or cloud models", isOn: permission(\.shareEnabled))
            }.toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Label(status.state.capitalized, systemImage: statusIcon).foregroundStyle(statusColor)
                Text("\(status.records) records · \(status.files) files")
                if let date = status.attemptedAt { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
            }.font(.caption).foregroundStyle(.secondary)
            Text(status.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("Source details", isExpanded: $showDetails) {
                HStack {
                    TextField("Project label (used when the source has none)", text: $editProject)
                    Button("Save project") {
                        guard var updated = library.sources.first(where: { $0.id == source.id }) else { return }
                        updated.project = editProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editProject
                        _ = library.save(updated)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                }.padding(.top, 6)
            }
        }
        .onAppear { editProject = source.project ?? "" }
        .onChange(of: source.project) { _, value in editProject = value ?? "" }
    }
    private func permission(_ keyPath: WritableKeyPath<ImportSource, Bool>) -> Binding<Bool> {
        Binding(get: { source[keyPath: keyPath] }, set: { value in
            guard var current = library.sources.first(where: { $0.id == source.id }) else { return }
            current[keyPath: keyPath] = value
            _ = library.save(current)
        })
    }
    private var statusIcon: String {
        switch status.state {
        case "complete": "checkmark.circle"
        case "running": "arrow.triangle.2.circlepath"
        case "failed", "partial": "exclamationmark.triangle"
        case "cancelled": "pause.circle"
        default: "circle.dotted"
        }
    }
    private var statusColor: Color { ["failed", "partial"].contains(status.state) ? .orange : .secondary }
}

private struct AddImportedSourceView: View {
    let library: ContextLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ImportSourceKind = .lattice
    @State private var selectedURL: URL?
    @State private var label = ""
    @State private var project = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add an imported source").font(.title2.bold())
            Form {
                Picker("Format", selection: $kind) {
                    ForEach(ImportSourceKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Display name (optional)", text: $label)
                TextField("Project label (optional)", text: $project)
                HStack {
                    Text(selectedURL?.path ?? "Choose a source location").font(.callout).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Choose…", action: chooseLocation)
                }
            }
            Text(formatHelp).font(.callout).foregroundStyle(.secondary)
            Text("Adding enables local collection and context. Sharing stays off. Use Import when you are ready to read the selected files.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = library.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add source") {
                    guard let selectedURL else { return }
                    let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let scope = project.trimmingCharacters(in: .whitespacesAndNewlines)
                    let source = ImportSource(kind: kind, path: selectedURL.standardizedFileURL.path,
                        label: name.isEmpty ? nil : name, shareEnabled: false, project: scope.isEmpty ? nil : scope)
                    if library.add(source) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(selectedURL == nil || library.store == nil)
            }
        }
        .padding(24).frame(width: 570)
        .onChange(of: kind) { _, _ in selectedURL = nil }
    }
    private var formatHelp: String {
        switch kind {
        case .lattice: "In Lattice: Work → choose one project → Approved Agent Context → Export JSON capsule. Personal metrics require an explicitly selected snapshot copy; Lattice has no native metrics JSON export. Choose a copy outside live app storage."
        case .metricsCSV: "Choose UTF-8 CSV with the documented id, metric, value, unit, date, timezone, updated_at, deleted, source columns. Personal metrics stay local until sharing is explicitly enabled."
        case .markdown: "Choose a Markdown file or folder. Generated Sentient knowledge is excluded so summaries do not become their own evidence."
        case .codex: "Choose a Codex rollout JSONL file or a session folder. User statements, assistant reports, and tool evidence retain their separate roles."
        case .claudeCode: "Choose a Claude Code project/session JSONL file or folder."
        case .hermes: "Choose a Hermes state.db or exported session JSON, or its source folder."
        case .openClaw: "Choose an OpenClaw agent session JSONL, supported SQLite archive, or agent session folder."
        }
    }
    private func chooseLocation() {
        // NSOpenPanel permits one file OR directory in the same desktop picker; no source is read here.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = kind != .lattice && kind != .metricsCSV
        panel.allowsMultipleSelection = false; panel.prompt = "Choose source"
        panel.message = kind == .lattice ? "Choose an exported Workbench capsule or a personal snapshot copy outside live app storage." : "Choose one file or source folder for \(kind.label)."
        panel.begin { response in
            guard response == .OK else { return }
            selectedURL = panel.url
        }
    }
}
