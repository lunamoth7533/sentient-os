// Retained graph regressions using the real vault loader and graph builder over synthetic folders.
import Foundation

enum VaultGenerator { static var vaultRoot = URL(fileURLWithPath: "/unused-test-vault") }
// The same small seeded RNG used by Orb.swift; only that view's cosmetic dependency is isolated.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
// Rendering and log output are inert; the model and simulation remain the production code.
enum SkyRenderer { static func makeDust() -> [Int] { [] } }
func Log(_ message: String) {}
struct GraphFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw GraphFailure(description: message) }
}

@main struct KnowledgeGraphTests {
    @MainActor static func main() async throws {
        var failures = 0
        let tests: [(String, () throws -> Void)] = [
            ("explicit_relative_path", explicitPath),
            ("source_folder_resolution", sourceFolder),
            ("ambiguous_title_abstains", ambiguity),
            ("code_examples_are_not_edges", codeExamples),
            ("symlink_escape_is_excluded", symlinkEscape),
            ("ancestor_path_boundary", ancestorBoundary),
            ("additional_roots_are_scoped", additionalRoots),
            ("root_namespaces_are_unambiguous", rootNamespaces),
            ("additional_root_without_legacy", additionalOnly),
            ("replaced_symlink_is_not_read", replacedSymlink),
            ("valid_link_forms", validLinkForms),
            ("comments_are_not_edges", comments),
            ("preserves_node_metadata", nodeMetadata)
        ]
        for (name, test) in tests {
            do { try test(); Swift.print("PASS \(name)") }
            catch { failures += 1; Swift.print("FAIL \(name): \(error)") }
        }
        let asyncTests: [(String, @MainActor () async throws -> Void)] = [
            ("projection_ready_refreshes_sky", projectionReadyRefresh),
            ("same_paths_refresh_edited_edges", editedEdgesRefresh),
            ("older_load_cannot_replace_newer", outOfOrderLoad),
            ("cancelled_load_cannot_publish", cancelledLoad),
            ("refresh_remaps_highlight_by_url", refreshHighlight),
            ("missing_vault_clears_previous_graph", missingVault)
        ]
        for (name, test) in asyncTests {
            do { try await test(); Swift.print("PASS \(name)") }
            catch { failures += 1; Swift.print("FAIL \(name): \(error)") }
        }
        Swift.print("Knowledge graph: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
    static func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        VaultGenerator.vaultRoot = canonical
        return canonical
    }
    static func edgeSet(_ graph: SkyGraph) -> Set<Set<URL>> {
        Set(graph.edges.map { Set([graph.nodes[$0.a].url, graph.nodes[$0.b].url]) })
    }
    static func explicitPath() throws {
        let root = try fixture(["A/Plan.md": "# A plan", "B/Plan.md": "# B plan"])
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KnowledgeVault.load()!
        try expect(vault.resolve("A/Plan") == root.appendingPathComponent("A/Plan.md"), "Root-relative link did not resolve exact file")
        try expect(vault.resolve("B/Plan.md#Next|label") == root.appendingPathComponent("B/Plan.md"), "Extension, heading and alias lost exact target")
    }
    static func sourceFolder() throws {
        let root = try fixture(["A/Plan.md": "# A plan", "B/Plan.md": "# B plan",
                                "A/Index.md": "# A index\n[[Plan]]", "B/Index.md": "# B index\n[[Plan]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SkyGraph.build(from: KnowledgeVault.load()!)
        let expected: Set<Set<URL>> = [
            [root.appendingPathComponent("A/Index.md"), root.appendingPathComponent("A/Plan.md")],
            [root.appendingPathComponent("B/Index.md"), root.appendingPathComponent("B/Plan.md")]
        ]
        try expect(edgeSet(graph) == expected, "Same-title notes in different folders were fused")
    }
    static func ambiguity() throws {
        let root = try fixture(["A/Plan.md": "# A", "B/Plan.md": "# B", "Index.md": "# Index\n[[Plan]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KnowledgeVault.load()!
        try expect(vault.resolve("Plan") == nil, "Ambiguous title arbitrarily selected a note")
        try expect(SkyGraph.build(from: vault).edges.isEmpty, "Ambiguous link invented a graph edge")
    }
    static func codeExamples() throws {
        let root = try fixture(["Target.md": "# Target", "Example.md": """
        # Example
        Mentioning Target in prose creates no relationship.
        ```markdown
        [[Target]]
        ```
        ~~~
        [[Target]]
        ~~~
        Inline `[[Target]]` and ``code ` [[Target]]`` are examples.
        \\[[Target]] is escaped syntax.
            [[Target]]
        """])
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(SkyGraph.build(from: KnowledgeVault.load()!).edges.isEmpty, "Code or escaped wikilink examples became real edges")
    }
    static func symlinkEscape() throws {
        let root = try fixture(["Inside.md": "# Inside"])
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try fixture(["Secret.md": "# Synthetic outside file"])
        defer { try? FileManager.default.removeItem(at: outside) }
        VaultGenerator.vaultRoot = root
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.md"), withDestinationURL: outside.appendingPathComponent("Secret.md"))
        let vault = KnowledgeVault.load()!
        try expect(vault.allNotes.count == 1, "Symlink entries imported files outside the allowed root")
        try expect(vault.resolve("Escape") == nil && vault.resolve("outside/Secret") == nil, "Symlink target remained navigable")
    }
    static func ancestorBoundary() throws {
        let root = try fixture(["Inside.md": "# Inside"])
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KnowledgeVault.load()!
        let outside = URL(fileURLWithPath: root.path + "-outside/Folder/Note.md")
        try expect(vault.ancestors(of: outside).isEmpty, "Path-prefix sibling was treated as a child root")
    }
    static func additionalRoots() throws {
        let root = try fixture(["Shared.md": "# Primary shared", "OnlyPrimary.md": "# Primary only",
                                "Project/Index.md": "# Primary index\n[[Shared]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = try fixture(["Shared.md": "# Imported shared", "Project/Index.md": "# Imported index\n[[Shared]]\n[[OnlyPrimary]]"])
        defer { try? FileManager.default.removeItem(at: extra) }
        let vault = KnowledgeVault.load(root: root, additionalRoots: [extra])!
        let importedIndex = extra.appendingPathComponent("Project/Index.md")
        let importedShared = extra.appendingPathComponent("Shared.md")
        try expect(vault.resolve("OnlyPrimary", from: importedIndex) == nil, "Bare title crossed an explicit root boundary")
        try expect(vault.resolve("../Shared", from: importedIndex) == importedShared, "Source-relative import link did not resolve")
        try expect(vault.resolve("../../OnlyPrimary", from: importedIndex) == nil, "Relative link escaped imported root")
        try expect(vault.resolve(extra.lastPathComponent + "/Shared", from: root.appendingPathComponent("OnlyPrimary.md")) == importedShared,
                   "Explicit namespace did not reach imported note")
        try expect(vault.isReadOnly(importedIndex) && !vault.isReadOnly(root.appendingPathComponent("Shared.md")), "Read-only mount policy was lost")
        try expect(vault.ancestors(of: importedIndex) == [extra.appendingPathComponent("Project", isDirectory: true), extra],
                   "Imported ancestors did not expand the mounted folder")
        let graph = SkyGraph.build(from: vault)
        try expect(graph.nodes.count == 5 && graph.edges.count == 2, "Imported nodes or scoped edges were lost/fused")
        let importedDomain = graph.nodes.first(where: { $0.url == importedIndex })!.domain
        try expect(graph.domains[importedDomain] == extra.lastPathComponent, "Imported root did not receive its own domain")
    }
    static func rootNamespaces() throws {
        let base = try fixture(["Legacy/Imports/Primary.md": "# Primary", "Imports/Note.md": "# One", "Other/Imports/Note.md": "# Two"])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Legacy", isDirectory: true)
        let first = base.appendingPathComponent("Imports", isDirectory: true)
        let second = base.appendingPathComponent("Other/Imports", isDirectory: true)
        let vault = KnowledgeVault.load(root: root, additionalRoots: [second, first, first, root, root.appendingPathComponent("Imports")])!
        try expect(vault.allNotes.count == 3, "Overlapping or duplicate roots duplicated nodes")
        try expect(vault.resolve("Imports (2)/Note") == first.appendingPathComponent("Note.md"), "First colliding namespace was not deterministic")
        try expect(vault.resolve("Imports (3)/Note") == second.appendingPathComponent("Note.md"), "Second colliding namespace was not distinct")
        try expect(Set(SkyGraph.build(from: vault).domains) == ["Imports", "Imports (2)", "Imports (3)"], "Distinct roots merged graph domains")
    }
    static func additionalOnly() throws {
        let extra = try fixture(["Imported.md": "# Imported"])
        defer { try? FileManager.default.removeItem(at: extra) }
        let absent = extra.deletingLastPathComponent().appendingPathComponent("absent-\(UUID().uuidString)")
        let vault = KnowledgeVault.load(root: absent, additionalRoots: [extra])
        try expect(vault?.allNotes.count == 1 && vault?.readme == nil, "Imported projection required a legacy vault to exist")
        try expect(!FileManager.default.fileExists(atPath: absent.path), "Read-only load created a legacy vault")
    }
    static func replacedSymlink() throws {
        let root = try fixture(["Inside.md": "# Inside"])
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KnowledgeVault.load()!
        let outside = try fixture(["Target.md": "# Outside"])
        defer { try? FileManager.default.removeItem(at: outside) }
        let inside = root.appendingPathComponent("Inside.md")
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside.appendingPathComponent("Target.md"))
        try expect(vault.resolve("Inside") == nil && !vault.isReadableNote(inside), "File replaced by an outside symlink remained readable")
        try expect(vault.isReadOnly(inside), "Outside symlink received writable affordances")
        try expect(SkyGraph.build(from: vault).nodes.isEmpty, "Graph read a note replaced with an outside symlink")
    }
    static func validLinkForms() throws {
        let root = try fixture(["A/Plan.md": "# Plan", "B/Other.md": "# Other",
                                "A/Index.md": "# Index\n[[Plan|alias]] [[Plan#heading]] [[./Plan.md]] [[../B/Other]] [[Index]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SkyGraph.build(from: KnowledgeVault.load()!)
        try expect(graph.edges.count == 2, "Valid local/path links were missed or duplicate/self links were added")
        let index = graph.nodes.first(where: { $0.url == root.appendingPathComponent("A/Index.md") })!
        try expect(index.degree == 2, "Degree did not match deduplicated valid links")
    }
    static func comments() throws {
        let root = try fixture(["Target.md": "# Target", "Ta rget.md": "# Other target",
                                "Comment.md": "# Comment\n<!-- [[Target]] -->\n<!--\n[[Target]]\n-->\n[[Ta<!-- comment -->rget]]\n[[Ta`example`rget]]"])
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(SkyGraph.build(from: KnowledgeVault.load()!).edges.isEmpty, "HTML comment examples became graph edges")
    }
    static func nodeMetadata() throws {
        let root = try fixture(["README.md": "# Overview\n[[Project/Note]]", "Project/Note.md": "# Note\nSynthetic preview"])
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = SkyGraph.build(from: KnowledgeVault.load()!)
        try expect(graph.nodes.count == 2 && graph.domains == ["Project"], "Node/domain metadata changed")
        try expect(graph.rootIndex != nil && graph.nodes[graph.rootIndex!].title == "Overview", "Pinned overview lost its identity")
        try expect(graph.nodes.first(where: { !$0.isRoot })?.preview == "Synthetic preview", "Hover preview changed")
    }

    @MainActor static func projectionReadyRefresh() async throws {
        let base = try fixture(["Legacy/README.md": "# Overview", "Legacy/Project/Note.md": "# Existing",
                                "Imported/Source/Project.md": "# Project\n[[Session]]",
                                "Imported/Source/Session.md": "# Session"])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Legacy", isDirectory: true)
        let extra = base.appendingPathComponent("Imported", isDirectory: true)
        let initial = KnowledgeVault.load(root: root)!
        let ready = KnowledgeVault.load(root: root, additionalRoots: [extra])!
        let model = NightSkyModel()
        await model.load(vault: initial)
        model.camera.pan = CGPoint(x: 12, y: 24)
        model.camera.zoom = 1.7
        let oldPositions = Dictionary(uniqueKeysWithValues: zip(model.graph!.nodes.map(\.url), model.sim!.pos))
        // Exercise the identity SwiftUI's .task uses, including the unchanged primary root.
        if initial.revision != ready.revision { await model.load(vault: ready) }
        try expect(model.graph?.nodes.count == 4 && model.graph?.edges.count == 1,
                   "Projection-ready snapshot left the sky on its initial legacy nodes")
        try expect(model.graph?.domains.contains("Imported") == true, "New root did not reach the displayed graph")
        try expect(model.camera.pan == CGPoint(x: 12, y: 24) && model.camera.zoom == 1.7, "Refresh moved the user's camera")
        for (index, node) in model.graph!.nodes.enumerated() {
            if let prior = oldPositions[node.url] {
                try expect(model.sim!.pos[index] == prior, "Refresh reset an existing star's position")
            }
        }
        let removed = KnowledgeVault.load(root: root)!
        if ready.revision != removed.revision { await model.load(vault: removed) }
        try expect(model.graph?.nodes.count == 2 && model.graph?.domains.contains("Imported") == false,
                   "Removed projection remained visible in the sky")
    }

    @MainActor static func editedEdgesRefresh() async throws {
        let root = try fixture(["Index.md": "# Index\n[[Target]]", "Target.md": "# Target"])
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = KnowledgeVault.load(root: root)!
        let model = NightSkyModel()
        await model.load(vault: initial)
        try "# Changed index\nThe explicit link was removed.".write(to: root.appendingPathComponent("Index.md"), atomically: true, encoding: .utf8)
        let edited = KnowledgeVault.load(root: root)!
        if initial.revision != edited.revision { await model.load(vault: edited) }
        try expect(model.graph?.edges.isEmpty == true && model.graph?.nodes.contains(where: { $0.preview == "The explicit link was removed." }) == true,
                   "A same-path content edit did not refresh previews and edges")
    }

    @MainActor static func outOfOrderLoad() async throws {
        let base = try fixture(["Old/Old.md": "# Old", "New/New.md": "# New"])
        defer { try? FileManager.default.removeItem(at: base) }
        let old = KnowledgeVault.load(root: base.appendingPathComponent("Old"))!
        let latest = KnowledgeVault.load(root: base.appendingPathComponent("New"))!
        let gate = GraphBuildGate()
        let model = NightSkyModel { vault in
            let built = SkyGraph.build(from: vault)
            if vault.root == old.root { await gate.suspend() }
            return built
        }
        let older = Task { await model.load(vault: old) }
        await gate.waitUntilSuspended()
        await model.load(vault: latest)
        await gate.release()
        await older.value
        try expect(model.graph?.nodes.map(\.title) == ["New"], "Slow older graph overwrote the latest snapshot")
    }

    @MainActor static func cancelledLoad() async throws {
        let base = try fixture(["Old/Old.md": "# Old", "New/New.md": "# New"])
        defer { try? FileManager.default.removeItem(at: base) }
        let initial = KnowledgeVault.load(root: base.appendingPathComponent("Old"))!
        let replacement = KnowledgeVault.load(root: base.appendingPathComponent("New"))!
        let gate = GraphBuildGate()
        let model = NightSkyModel { vault in
            let built = SkyGraph.build(from: vault)
            if vault.root == replacement.root { await gate.suspend() }
            return built
        }
        await model.load(vault: initial)
        let pending = Task { await model.load(vault: replacement) }
        await gate.waitUntilSuspended()
        pending.cancel()
        await gate.release()
        await pending.value
        try expect(model.graph?.nodes.map(\.title) == ["Old"], "Cancelled refresh still published its result")
    }

    @MainActor static func refreshHighlight() async throws {
        let root = try fixture(["B.md": "# B", "C.md": "# C"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NightSkyModel()
        await model.load(vault: KnowledgeVault.load(root: root))
        let highlighted = root.appendingPathComponent("C.md")
        model.highlight(highlighted)
        try "# A".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        await model.load(vault: KnowledgeVault.load(root: root))
        let index = model.highlightIndex
        try expect(index != nil && model.nodeURL(index!) == highlighted, "Refresh moved an existing highlight to a different note")
        try FileManager.default.removeItem(at: highlighted)
        await model.load(vault: KnowledgeVault.load(root: root))
        try expect(model.highlightIndex == nil, "Removed note retained a stale highlight index")
    }

    @MainActor static func missingVault() async throws {
        let root = try fixture(["Note.md": "# Note"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NightSkyModel()
        await model.load(vault: KnowledgeVault.load(root: root))
        await model.load(vault: nil)
        try expect(model.graph == nil && model.sim == nil && model.glow.isEmpty, "Unavailable vault retained its previously displayed notes")
        let preview = NightSkyModel.preview()
        let count = preview.graph?.nodes.count
        await preview.load(vault: nil)
        try expect(preview.graph?.nodes.count == count, "Nil-vault preview lost its intentional mock sky")
    }
}

/// Deterministic scheduling barrier: no sleep, live I/O, or substituted graph output.
actor GraphBuildGate {
    private var resumeBuild: CheckedContinuation<Void, Never>?
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        await withCheckedContinuation { continuation in
            resumeBuild = continuation
            started = true
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitUntilSuspended() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { resumeBuild?.resume(); resumeBuild = nil }
}
