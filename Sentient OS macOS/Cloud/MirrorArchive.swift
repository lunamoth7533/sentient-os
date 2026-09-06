// Builds a private, disposable mirror archive without writing imported evidence into the legacy vault.
import Foundation
import CryptoKit
import Darwin

nonisolated enum MirrorArchive {
    struct Package: Sendable {
        let directory: URL
        let zip: URL
        let sharedDigest: String
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Budget { var files = 0; var bytes = 0 }
    private static let maxFiles = 5_000
    private static let maxBytes = 200 * 1_024 * 1_024

    static func digest(_ notes: [String: String]) -> String {
        var hash = SHA256()
        for path in notes.keys.sorted() {
            for value in [path, notes[path]!] {
                let bytes = Data(value.utf8)
                hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func create(vaultRoot: URL, sharedNotes: [String: String]) throws -> Package {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("sentient-mirror-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let contents = directory.appendingPathComponent("contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var budget = Budget()
            // Open each descendant relative to a held directory descriptor, never following a link.
            // Checking a URL and later copying it by path leaves a symlink replacement race.
            let root = open(vaultRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if root >= 0 {
                defer { close(root) }
                try copyDirectory(root, to: contents, depth: 0, budget: &budget)
            } else if errno != ENOENT { throw MirrorClient.MirrorError.zipFailed("The vault cannot be read safely. Check folder access and remove symbolic links.") }
            else if sharedNotes.isEmpty { throw MirrorClient.MirrorError.noVault }

            for path in sharedNotes.keys.sorted() {
                try Task.checkCancellation()
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
                      path.hasSuffix(".md") else { throw MirrorClient.MirrorError.zipFailed("An imported note has an invalid relative path.") }
                let target = contents.appendingPathComponent("Imported/" + path)
                guard !fm.fileExists(atPath: target.path) else {
                    throw MirrorClient.MirrorError.zipFailed("An existing legacy note conflicts with an imported note. Move the conflicting note out of Imported and retry; the legacy vault has been preserved.")
                }
                let bytes = Data(sharedNotes[path]!.utf8)
                try charge(bytes.count, budget: &budget)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bytes.write(to: target, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
            guard budget.files > 0 else { throw MirrorClient.MirrorError.noVault }
            let zip = directory.appendingPathComponent("vault.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = contents
            process.arguments = ["-r", "-X", "-q", zip.path, "."]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { throw MirrorClient.MirrorError.zipFailed("Couldn't launch the system zip utility.") }
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw MirrorClient.MirrorError.zipFailed("The system zip utility failed. Retry after checking free disk space.") }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
            return Package(directory: directory, zip: zip, sharedDigest: digest(sharedNotes))
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    private static func charge(_ bytes: Int, budget: inout Budget) throws {
        guard budget.files < maxFiles, bytes <= maxBytes - budget.bytes else {
            throw MirrorClient.MirrorError.zipFailed("The mirror supports at most 5,000 files and 200 MB of uncompressed content. Reduce shared content and retry.")
        }
        budget.files += 1; budget.bytes += bytes
    }

    private static func copyDirectory(_ fd: Int32, to target: URL, depth: Int, budget: inout Budget) throws {
        guard depth < 64 else { throw MirrorClient.MirrorError.zipFailed("The vault has too many nested folders.") }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw readFailure() }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw readFailure() }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw readFailure() }
        defer { closedir(directory) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw readFailure() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".DS_Store" { continue }
            let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard child >= 0 else { throw readFailure() }
            defer { close(child) }
            var info = stat()
            guard fstat(child, &info) == 0 else { throw readFailure() }
            let output = target.appendingPathComponent(name)
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try copyDirectory(child, to: output, depth: depth + 1, budget: &budget)
            } else if type == mode_t(S_IFREG) {
                guard info.st_size >= 0, info.st_size <= maxBytes - budget.bytes else { throw readFailure() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    try Task.checkCancellation()
                    let count = read(child, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0, count <= maxBytes - budget.bytes - bytes.count else { throw readFailure() }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                var after = stat()
                guard fstat(child, &after) == 0, unchanged(info, after), bytes.count == info.st_size else { throw readFailure() }
                try charge(bytes.count, budget: &budget)
                try bytes.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } else { throw readFailure() }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, unchanged(before, after) else { throw readFailure() }
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func readFailure() -> MirrorClient.MirrorError {
        .zipFailed("A vault item is unreadable, changed while packaging, or is a symbolic link or unsupported file. Check the vault and retry; no partial archive was uploaded.")
    }
}
