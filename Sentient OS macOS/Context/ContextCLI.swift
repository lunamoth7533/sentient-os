// Headless import/query/MCP modes of the real app binary; no UI, telemetry, model loading, or scheduling.
import Foundation

nonisolated enum ContextCLI {
    static func runIfRequested(_ args: [String]) -> Int32? {
        guard args.contains(where: { ["--context-mcp", "--context-query", "--context-import", "--context-sources"].contains($0) }) else { return nil }
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            let store = try option("--context-store").map { try EvidenceStore(url: URL(fileURLWithPath: $0)) } ?? ContextPaths.openStore()
            if args.contains("--context-mcp") {
                try ContextMCP(store: store, audience: args.contains("--local-context") ? .local : .shared).run()
            } else if let query = option("--context-query") {
                var parameters: [String: Any] = ["query":query]
                for key in ["project", "source", "after", "before"] { if let value = option("--" + key) { parameters[key] = value } }
                if let value = option("--budget") {
                    guard let n = Int(value) else { throw ContextError.invalid("Budget must be an integer.") }; parameters["budget"] = n
                }
                let result = try ContextRetriever.retrieve(store: store, query: ContextMCP.query(parameters), audience: args.contains("--shared") ? .shared : .local)
                FileHandle.standardOutput.write(Data((result.text + "\n").utf8))
            } else if let rawKind = option("--context-import"), let kind = ImportSourceKind(rawValue: rawKind), let path = option("--path") {
                let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
                let source = try store.sources().first { $0.kind == kind && $0.path == canonical }
                    ?? ImportSource(kind: kind, path: canonical, project: option("--project"))
                try store.saveSource(source)
                let status = try StructuredImporter(store: store).run(source: source)
                try ContextProjection.refresh(store: store, root: store.url.deletingLastPathComponent().appendingPathComponent("Imported"))
                FileHandle.standardOutput.write(try JSONEncoder().encode(status)); FileHandle.standardOutput.write(Data([10]))
                return status.state == "complete" ? 0 : 2
            } else if args.contains("--context-sources") {
                FileHandle.standardOutput.write(try JSONEncoder().encode(store.sources())); FileHandle.standardOutput.write(Data([10]))
            } else { throw ContextError.invalid("Use --context-import <kind> --path <file-or-folder>, --context-query <query>, --context-sources, or --context-mcp.") }
            return 0
        } catch {
            FileHandle.standardError.write(Data((StructuredImporter.safeMessage(error) + "\n").utf8)); return 2
        }
    }
}
