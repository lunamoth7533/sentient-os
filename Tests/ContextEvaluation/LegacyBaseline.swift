// Capture the pre-change default model context using the real KnowledgeVault loader.
// The hosted get_structure contract returns the README and file tree; it has no query parameter.
import Foundation

enum VaultGenerator { static var vaultRoot: URL { URL(fileURLWithPath: CommandLine.arguments[1]) } }

@main struct LegacyBaseline {
    static func main() throws {
        let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let fixture = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let budget = fixture["budget"] as! Int
        var outputs: [[String: Any]] = []
        for query in fixture["queries"] as! [[String: Any]] {
            let start = DispatchTime.now().uptimeNanoseconds
            let vault = KnowledgeVault.load()!
            let readme = try String(contentsOf: vault.readme!, encoding: .utf8)
            let tree = vault.allNotes.map { $0.url.path.replacingOccurrences(of: vault.root.path + "/", with: "") }.sorted().joined(separator: "\n")
            let context = String(decoding: Data((readme + "\n" + tree).utf8.prefix(budget)), as: UTF8.self)
            outputs.append(["id": query["id"]!, "query": query["query"]!, "context": context,
                            "latencyMS": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                            "retrievedEvidenceIDs": [String](), "bytes": context.utf8.count])
        }
        let result: [String: Any] = ["policy": "Existing get_structure default: README plus tree. No query-aware retrieval exists. A model's subsequent whole-file choices are not evaluated.", "budget": budget, "outputs": outputs]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
    }
}
