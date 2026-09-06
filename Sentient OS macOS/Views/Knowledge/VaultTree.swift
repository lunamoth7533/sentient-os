//
//  VaultTree.swift
//  Sentient OS macOS
//
//  Data layer for the Knowledge reader. Scans the on-disk markdown vault
//  (~/Sentient OS - Knowledge Base/) into a browsable tree, indexes every note title so
//  [[wikilinks]] can be resolved to files, and reads a note for display (strips the leading
//  YAML frontmatter block and promotes the first `# H1` to the title). Pure value types + one
//  synchronous loader — the view (KnowledgeView) owns all UI state.
//
//  Key types: VaultNode (a folder or a note) · KnowledgeVault (.load() / .resolve() /
//  .ancestors(of:) / .read()). Doc: Documentation/Knowledge Viewer.md
//

import Foundation

/// One node in the vault tree — a folder (with `children`) or a markdown note (a leaf).
struct VaultNode: Identifiable, Hashable {
    let url: URL
    let name: String        // folder name, or the note's filename without ".md"
    let isFolder: Bool
    var children: [VaultNode]

    var id: URL { url }

    // Equality is the synthesized full-value one — `children` included. SwiftUI decides whether to
    // re-render by comparing old vs new values with ==, so a URL-only equality here made the sidebar
    // ignore a reloaded tree whose top-level URLs hadn't changed (a note deleted inside a folder
    // stayed visible until relaunch). The tree is tiny; recursive comparison is nothing.
}

/// A loaded snapshot of the vault: the tree (README pulled out and offered as the pinned
/// "Overview"), a flat note list (search + counts), and scoped path/title indexes for wikilinks.
/// Rebuilt each time the Knowledge window opens — the vault is small and read on demand.
struct KnowledgeVault {
    let root: URL
    // A scan can change mounted roots, note bodies, or links without changing any existing URL.
    // Keep its identity stable across value copies and distinct from every subsequent scan.
    let revision = UUID()
    let nodes: [VaultNode]           // top-level entries (folders first, then notes), README removed
    let allNotes: [VaultNode]        // every note, flattened, alphabetical (includes README)
    let titleIndex: [String: URL]    // unambiguous lowercased filename stems only
    let readme: URL?                 // the root README, shown pinned as "Overview"
    private let mounts: [Mount]
    private let paths: [URL: [String: [URL]]]
    private let titles: [URL: [String: [URL]]]
    private let noteRoots: [URL: URL]

    private struct Mount {
        let root: URL
        let namespace: String?       // nil = editable legacy root; explicit extra roots are read-only
    }

    /// Scan `VaultGenerator.vaultRoot` into a tree. Returns nil if the vault folder doesn't exist
    /// yet (no knowledge base has been built). Cheap — only enumerates directory entries; note
    /// bodies are read lazily on selection via `read(_:)`.
    static func load(root: URL = VaultGenerator.vaultRoot, additionalRoots: [URL] = []) -> KnowledgeVault? {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var mounts: [Mount] = []
        var paths: [URL: [String: [URL]]] = [:]
        var titles: [URL: [String: [URL]]] = [:]
        var noteRoots: [URL: URL] = [:]
        var index: [String: [URL]] = [:]
        var flat: [VaultNode] = []

        func directory(_ url: URL) -> Bool {
            guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        func scan(_ dir: URL, mount: Mount) -> [VaultNode] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            var folders: [VaultNode] = []
            var notes: [VaultNode] = []
            for entry in items {
                let url = entry.standardizedFileURL
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }   // .obsidian, .DS_Store, dotfiles (belt + suspenders)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]),
                      values.isSymbolicLink != true,
                      contains(url, in: mount.root),
                      url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { continue }
                let isFolder = values.isDirectory == true
                if isFolder {
                    // Show ALL subfolders, including empty ones — so a folder the user just created
                    // in the viewer (empty until they add notes) appears in the tree.
                    folders.append(VaultNode(url: url, name: name, isFolder: true, children: scan(url, mount: mount)))
                } else if values.isRegularFile == true && url.pathExtension.lowercased() == "md" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    index[stem.lowercased(), default: []].append(url)
                    titles[mount.root, default: [:]][stem.lowercased(), default: []].append(url)
                    let relative = String(url.path.dropFirst(mount.root.path.count + 1))
                    paths[mount.root, default: [:]][String(relative.dropLast(3)).lowercased(), default: []].append(url)
                    noteRoots[url] = mount.root
                    let node = VaultNode(url: url, name: stem, isFolder: false, children: [])
                    notes.append(node)
                    flat.append(node)
                }
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            notes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders + notes   // folders first, then notes — like Finder / Obsidian
        }

        var top: [VaultNode] = []
        if directory(root) {
            let mount = Mount(root: root, namespace: nil)
            mounts.append(mount)
            top = scan(root, mount: mount)
        }
        let readme = top.first { !$0.isFolder && $0.name.caseInsensitiveCompare("README") == .orderedSame }?.url
        top.removeAll { !$0.isFolder && $0.name.caseInsensitiveCompare("README") == .orderedSame }
        var names = Set(top.map { $0.name.lowercased() })
        // Explicit roots stay outside the writable legacy vault. Skip overlap (including a parent
        // of the primary root) so no note is duplicated or assigned to two graph domains.
        for supplied in additionalRoots.sorted(by: { $0.path < $1.path }) {
            guard directory(supplied) else { continue }
            let extra = supplied.resolvingSymlinksInPath().standardizedFileURL
            guard !contains(extra, in: root), !contains(root, in: extra),
                  !mounts.contains(where: { contains(extra, in: $0.root) || contains($0.root, in: extra) }) else { continue }
            let base = extra.lastPathComponent
            var namespace = base, suffix = 2
            while names.contains(namespace.lowercased()) { namespace = "\(base) (\(suffix))"; suffix += 1 }
            names.insert(namespace.lowercased())
            let mount = Mount(root: extra, namespace: namespace)
            mounts.append(mount)
            top.append(VaultNode(url: extra, name: namespace, isFolder: true, children: scan(extra, mount: mount)))
        }
        guard !mounts.isEmpty else { return nil }
        top.sort {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        flat.sort {
            let compare = $0.name.localizedStandardCompare($1.name)
            return compare == .orderedSame ? $0.url.path < $1.url.path : compare == .orderedAscending
        }

        return KnowledgeVault(root: root, nodes: top, allNotes: flat,
                              titleIndex: index.compactMapValues { $0.count == 1 ? $0.first : nil }, readme: readme,
                              mounts: mounts, paths: paths, titles: titles, noteRoots: noteRoots)
    }

    /// Prefer an explicit path, then the source folder, then an unambiguous title in the same root.
    /// Extra roots require their namespace for cross-root links; a bare title cannot jump roots.
    func resolve(_ wikilink: String, from source: URL? = nil) -> URL? {
        var target = wikilink.components(separatedBy: "|").first ?? ""
        target = target.components(separatedBy: "#").first ?? ""
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("://") else { return nil }
        if target.lowercased().hasSuffix(".md") { target = String(target.dropLast(3)) }
        let source = source?.standardizedFileURL
        if let source, !isReadableNote(source) { return nil }
        let scope = source.flatMap { noteRoots[$0] } ?? root

        func one(_ urls: [URL]?) -> URL? {
            guard let urls, urls.count == 1, let url = urls.first, isReadableNote(url) else { return nil }
            return url
        }
        func at(_ path: String, under directory: URL, scope: URL) -> URL? {
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard Self.contains(url, in: scope) else { return nil }
            let relative = String(url.path.dropFirst(scope.path.count + 1)).lowercased()
            return one(paths[scope]?[relative])
        }
        if target.contains("/") {
            // A namespace is an explicit request to cross roots, and remains deterministic even
            // when primary and imported folders originally shared the same basename.
            for mount in mounts {
                if let name = mount.namespace, target.lowercased().hasPrefix(name.lowercased() + "/") {
                    return at(String(target.dropFirst(name.count + 1)), under: mount.root, scope: mount.root)
                }
            }
            if !target.hasPrefix("."), let exact = at(target, under: scope, scope: scope) { return exact }
            if let source { return at(target, under: source.deletingLastPathComponent(), scope: scope) }
            return nil
        }
        if let source, let local = at(target, under: source.deletingLastPathComponent(), scope: scope) { return local }
        return one(titles[scope]?[target.lowercased()])
    }

    /// Used before graph reads and navigation, including files replaced since the snapshot loaded.
    func isReadableNote(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let scope = noteRoots[url], Self.contains(url, in: scope),
              url == url.resolvingSymlinksInPath().standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    /// The reader can use this for edit/create/delete affordances on mounted projection folders.
    func isReadOnly(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return url.standardizedFileURL != resolved.standardizedFileURL || !Self.contains(resolved, in: root)
    }

    /// Mounted roots each get their own domain; primary notes retain their existing top folder.
    func domainName(of note: URL) -> String? {
        guard let scope = noteRoots[note], let mount = mounts.first(where: { $0.root == scope }) else { return nil }
        if let namespace = mount.namespace { return namespace }
        let components = note.path.dropFirst(scope.path.count + 1).split(separator: "/")
        return components.count > 1 ? String(components[0]) : nil
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path, rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// The folder URLs from the vault root down to (but excluding) `note` — so the sidebar tree
    /// can expand to reveal a note we jumped to via a wikilink.
    func ancestors(of note: URL) -> [URL] {
        var result: [URL] = []
        let note = note.standardizedFileURL
        guard let scope = noteRoots[note], isReadableNote(note) else { return result }
        var dir = note.deletingLastPathComponent()
        while Self.contains(dir, in: scope) && dir != scope {
            result.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        if scope != root { result.append(scope) }
        return result
    }

    /// Read a note for display: strip a leading `---…---` YAML frontmatter block, and promote the
    /// first `# H1` to the returned title (so the body doesn't repeat it). Falls back to the
    /// filename for the title and an empty body on a read failure.
    static func read(_ url: URL) -> (title: String, markdown: String) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var text = raw

        // Strip a leading frontmatter fence: the file opens with "---" and we drop through the
        // matching closing "---".
        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let close = lines.dropFirst().firstIndex(of: "---") {
                text = lines[(close + 1)...].joined(separator: "\n")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var title = url.deletingPathExtension().lastPathComponent
        var bodyLines = text.components(separatedBy: "\n")
        if let first = bodyLines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            bodyLines.removeFirst()
        }
        return (title, bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
