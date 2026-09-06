// Retained synthetic mirror tests. Never launch the app, read the Keychain, or open a network socket.
import Foundation
import CryptoKit

nonisolated enum Analytics { static func signal(_ name: String) {} }
actor VaultGenerator { static var vaultRoot: URL { fatalError("Live vault access in a mirror test") } }

nonisolated struct TestFailure: Error, CustomStringConvertible { let description: String }
nonisolated func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

actor Transport {
    struct Call: Sendable { var method: String; var body: Data?; var path: String }
    var calls: [Call] = []
    var remote: Data?
    var pauseNext = false
    var suspended: CheckedContinuation<Void, Never>?
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var rejectDelete = false
    var rejectPostAfterAccept = false
    var activeMutations = 0
    var peakMutations = 0

    func pauseUpload() { pauseNext = true }
    func failDeletes() { rejectDelete = true }
    func allowDeletes() { rejectDelete = false }
    func failAcceptedPost() { rejectPostAfterAccept = true }
    func waitForUpload() async {
        if suspended != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func resumeUpload() { suspended?.resume(); suspended = nil }
    func send(_ request: URLRequest, _ body: Data?) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        calls.append(Call(method: method, body: body, path: request.url!.path))
        if method != "GET" { activeMutations += 1; peakMutations = max(peakMutations, activeMutations) }
        defer { if method != "GET" { activeMutations -= 1 } }
        if method == "POST" {
            if pauseNext {
                pauseNext = false
                await withCheckedContinuation { continuation in
                    suspended = continuation
                    let waiting = arrivals; arrivals.removeAll()
                    waiting.forEach { $0.resume() }
                }
            }
            // A server may accept the request even when the client's Task is now cancelled.
            remote = body
            if rejectPostAfterAccept { throw TestFailure(description: "Synthetic connection lost after acceptance") }
        } else if method == "DELETE", !rejectDelete { remote = nil }
        let status = method == "DELETE" && rejectDelete ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data("{}".utf8), response)
    }
}

nonisolated final class Credentials: @unchecked Sendable {
    private let lock = NSLock()
    private var password = "synthetic-mirror-password"
    private var pending: [String] = []
    private var denyPasswordWrite = false
    private var reads = 0
    private var denyRead = false
    private var denyPendingRead = false
    func read() -> String { lock.withLock { reads += 1; return password } }
    func readAvailable() -> String? { lock.withLock { reads += 1; return denyRead ? nil : password } }
    func write(_ value: String) -> Bool {
        lock.withLock { if denyPasswordWrite { return false }; password = value; return true }
    }
    func readPending() -> [String] { lock.withLock { reads += 1; return pending } }
    func readPendingAvailable() -> [String]? { lock.withLock { reads += 1; return denyPendingRead ? nil : pending } }
    func writePending(_ value: [String]) -> Bool { lock.withLock { pending = value; return true } }
    func failPasswordWrite() { lock.withLock { denyPasswordWrite = true } }
    func readCount() -> Int { lock.withLock { reads } }
    func failReads() { lock.withLock { denyRead = true } }
    func allowReads() { lock.withLock { denyRead = false } }
    func failPendingReads() { lock.withLock { denyPendingRead = true } }
}

nonisolated final class Fixture: @unchecked Sendable {
    let root: URL
    let vault: URL
    let store: EvidenceStore
    let defaults: UserDefaults
    let suite: String
    let transport = Transport()
    let credentials = Credentials()
    let password = "synthetic-mirror-password"
    let sharedSource = "shared-test-source"

    init(enabled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-mirror-test-\(UUID())", isDirectory: true)
        vault = root.appendingPathComponent("Legacy", isDirectory: true)
        suite = "sentient-mirror-test.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(enabled, forKey: "mcp.mirror.enabled")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("# Existing portrait\nOriginal legacy content.\n".utf8).write(to: vault.appendingPathComponent("README.md"))
        store = try EvidenceStore(url: root.appendingPathComponent("Context/evidence.sqlite"))
        try addSource(id: sharedSource, share: true, text: "Decision: retain the synthetic shared apricot.")
        try addSource(id: "local-test-source", share: false, text: "LOCAL_ONLY_PLUM must stay local.")
    }
    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func addSource(id: String, share: Bool, text: String) throws {
        let source = ImportSource(id: id, kind: .markdown, path: "/synthetic/\(id).md", shareEnabled: share)
        try store.saveSource(source)
        try store.commit(sourceID: id, fileID: "file", fingerprint: "1", documents: [ImportDocument(id: "document", records: [
            EvidenceRecord(id: "record", text: text, role: .user, sessionID: "synthetic session", project: "synthetic project")
        ])])
    }
    func setSharing(_ allowed: Bool) throws {
        var source = try store.source(sharedSource)!
        source.shareEnabled = allowed
        try store.saveSource(source)
    }
    func client(sharedNotes: (@Sendable () throws -> [String: String])? = nil) -> MirrorClient {
        MirrorClient(dependencies: .init(defaults: defaults,
            readPassword: { [self] in credentials.readAvailable() }, setPassword: { [self] in credentials.write($0) }, deleteLegacyPassword: {},
            vaultRoot: { [self] in vault },
            sharedNotes: sharedNotes ?? { [self] in try ContextProjection.notes(store: store, audience: .shared) },
            transport: { [self] request, body in try await transport.send(request, body) },
            readPendingPasswords: { [self] in credentials.readPendingAvailable() },
            setPendingPasswords: { [self] in credentials.writePending($0) }))
    }
    func unpack(_ blob: Data, password current: String? = nil) throws -> [String: String] {
        let password = current ?? password
        try expect(blob.first == 1, "Encryption envelope version changed")
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
            salt: Data("sentient-os-mirror-v1".utf8), info: Data("vault-content-key".utf8), outputByteCount: 32)
        let zip = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst()), using: key,
                                   authenticating: Data(MirrorCrypto.userID(password).utf8))
        let target = root.appendingPathComponent("unpacked-\(UUID())")
        let file = root.appendingPathComponent("test-\(UUID()).zip")
        try zip.write(to: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", file.path, "-d", target.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Encrypted body did not contain a valid root-relative zip")
        var files: [String: String] = [:]
        let base = target.standardizedFileURL.path + "/"
        for case let entry as URL in FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(entry.standardizedFileURL.path.dropFirst(base.count))] = try String(contentsOf: entry, encoding: .utf8)
            }
        }
        return files
    }
}

@main struct MirrorReliabilityTests {
    static func main() async {
        let cases: [(String, () async throws -> Void)] = [
            ("disabled_push", disabledPush),
            ("disabled_context_is_inert", disabledContextIsInert),
            ("shared_projection", sharedProjection),
            ("revoke_during_upload", revokeDuringUpload),
            ("disable_during_upload", disableDuringUpload),
            ("cancelled_upload", cancelledUpload),
            ("disabled_stats", disabledStats),
            ("symlink_boundary", symlinkBoundary),
            ("projection_read_failure", projectionReadFailure),
            ("legacy_collision", legacyCollision),
            ("encryption_contract", encryptionContract),
            ("idle_permission_revocation", idlePermissionRevocation),
            ("local_change_keeps_remote", localChangeKeepsRemote),
            ("revocation_retry_after_restart", revocationRetryAfterRestart),
            ("uncertain_upload_cleanup", uncertainUploadCleanup),
            ("rotate_during_upload", rotateDuringUpload),
            ("failed_rotation_preserves_identity", failedRotationPreservesIdentity),
            ("private_temporary_archive", privateTemporaryArchive),
            ("invalid_imported_path", invalidImportedPath),
            ("imported_only_vault", importedOnlyVault),
            ("unavailable_password_revocation", unavailablePasswordRevocation),
            ("unavailable_password_disable", unavailablePasswordDisable),
            ("repeated_rotation_retries_old_identity", repeatedRotationRetriesOldIdentity),
            ("unreadable_cleanup_queue", unreadableCleanupQueue),
            ("unavailable_password_rotation", unavailablePasswordRotation),
            ("reenable_unavailable_password", reenableUnavailablePassword)
        ]
        let filter = CommandLine.arguments.dropFirst().first
        var failures = 0
        for (name, test) in cases where filter == nil || filter == name {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(failures) mirror regression failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func disabledPush() async throws {
        let f = try Fixture(enabled: false)
        let result = await Task { try await f.client().push() }.result
        let calls = await f.transport.calls
        try expect(calls.isEmpty, "Disabled mirror issued an upload using a retained password")
        if case .success = result { throw TestFailure(description: "Disabled push reported success") }
    }
    static func disabledContextIsInert() async throws {
        let f = try Fixture(enabled: false), client = f.client()
        try expect(await client.isEnabled == false, "New synthetic mirror should start disabled")
        try await client.contextChanged()
        try expect(f.credentials.readCount() == 0, "Disabled context-window activity accessed live credential boundaries")
        try expect(await f.transport.calls.isEmpty, "Disabled context-window activity contacted the mirror")
    }
    static func sharedProjection() async throws {
        let f = try Fixture()
        let before = try Data(contentsOf: f.vault.appendingPathComponent("README.md"))
        try await f.client().push()
        let files = try f.unpack(await f.transport.remote!)
        try expect(files["README.md"] == String(data: before, encoding: .utf8), "Legacy README changed or nested")
        let text = files.values.joined()
        try expect(text.contains("shared apricot"), "Explicitly shared evidence missing from archive")
        try expect(!text.contains("LOCAL_ONLY_PLUM"), "Local-only evidence crossed mirror permission boundary")
        try expect(files.keys.contains { $0.hasPrefix("Imported/") }, "Projection lacks Imported namespace")
        try expect(try FileManager.default.contentsOfDirectory(atPath: f.vault.path) == ["README.md"], "Shared projection was persisted into the legacy vault")
    }
    static func revokeDuringUpload() async throws {
        let f = try Fixture(), client = f.client()
        await f.transport.pauseUpload()
        let push = Task { try await client.push() }
        await f.transport.waitForUpload()
        try f.setSharing(false)
        await f.transport.resumeUpload()
        _ = await push.result
        let calls = await f.transport.calls
        try expect(calls.contains { $0.method == "DELETE" }, "Permission changed during upload without revoking the captured archive")
        if let remote = await f.transport.remote {
            try expect(!f.unpack(remote).values.joined().contains("shared apricot"), "Revoked evidence remains remotely readable")
        }
    }
    static func disableDuringUpload() async throws {
        let f = try Fixture(), client = f.client()
        await f.transport.pauseUpload()
        let push = Task { try await client.push() }
        await f.transport.waitForUpload()
        let disable = Task { await client.disable() }
        while await client.isEnabled { await Task.yield() }
        await f.transport.resumeUpload()
        _ = await push.result; await disable.value
        let remote = await f.transport.remote
        try expect(remote == nil, "A late POST recreated the cloud copy after disable deleted it")
        try expect(f.defaults.object(forKey: "mcp.mirror.lastPush") == nil, "Disabled mirror reports a fresh successful sync")
        try expect(await f.transport.peakMutations == 1, "Network mutations overlapped across actor awaits")
    }
    static func cancelledUpload() async throws {
        let f = try Fixture(), client = f.client()
        await f.transport.pauseUpload()
        let push = Task { try await client.push() }
        await f.transport.waitForUpload(); push.cancel()
        await f.transport.resumeUpload()
        let result = await push.result
        if case .success = result { throw TestFailure(description: "Cancelled push was stamped successful") }
        let remote = await f.transport.remote
        try expect(remote == nil, "Cancelled upload left an uncertain remote copy")
    }
    static func disabledStats() async throws {
        let f = try Fixture(enabled: false)
        _ = await Task { try await f.client().stats() }.result
        let calls = await f.transport.calls
        try expect(calls.isEmpty, "Disabled mirror performed a remote read")
    }
    static func symlinkBoundary() async throws {
        let f = try Fixture()
        let outside = f.root.appendingPathComponent("outside.md")
        try Data("OUTSIDE_ROOT_SECRET".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.vault.appendingPathComponent("escape.md"), withDestinationURL: outside)
        let result = await Task { try await f.client().push() }.result
        if case .success = result { throw TestFailure(description: "Archive followed an outside-root symlink") }
        let calls = await f.transport.calls
        try expect(calls.isEmpty, "Unsafe archive was uploaded")
    }
    static func projectionReadFailure() async throws {
        let f = try Fixture()
        let client = f.client(sharedNotes: { throw TestFailure(description: "Synthetic unavailable evidence store") })
        let result = await Task { try await client.push() }.result
        if case .success = result { throw TestFailure(description: "Unavailable sharing permissions were treated as an empty projection") }
        let calls = await f.transport.calls
        try expect(!calls.contains { $0.method == "POST" }, "Upload proceeded without current permissions")
    }
    static func legacyCollision() async throws {
        let f = try Fixture()
        let relative = try ContextProjection.notes(store: f.store, audience: .shared).keys.sorted()[0]
        let old = f.vault.appendingPathComponent("Imported/" + relative)
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Existing user note must be preserved".utf8).write(to: old)
        let result = await Task { try await f.client().push() }.result
        if case .success = result { throw TestFailure(description: "A colliding legacy path was accepted without an actionable failure") }
        try expect(try String(contentsOf: old, encoding: .utf8) == "Existing user note must be preserved", "Legacy note overwritten")
    }
    static func encryptionContract() async throws {
        let f = try Fixture()
        try await f.client().push()
        let blob = await f.transport.remote!
        try expect(!String(decoding: blob, as: UTF8.self).contains("Original legacy content"), "Transport received plaintext")
        try expect(try f.unpack(blob)["README.md"] != nil, "Existing envelope no longer decrypts")
        try expect(MirrorCrypto.userID(f.password).count == 20, "Public identifier length changed")
    }
    static func idlePermissionRevocation() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        try f.store.removeSource(f.sharedSource)
        try await client.contextChanged()
        try expect(await f.transport.remote == nil, "Idle source removal left old evidence hosted")
        try expect(f.defaults.object(forKey: "mcp.mirror.lastPush") == nil, "Removed remote still has a successful sync stamp")
    }
    static func localChangeKeepsRemote() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        let before = await f.transport.calls.count
        try f.addSource(id: "additional-local", share: false, text: "This new local-only source must not interrupt the mirror.")
        try await client.contextChanged()
        try expect(await f.transport.calls.count == before, "Local-only change needlessly deleted the unchanged shared mirror")
        try expect(f.defaults.object(forKey: "mcp.mirror.lastPush") != nil, "Unchanged shared projection lost its sync stamp")
    }
    static func revocationRetryAfterRestart() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        await f.transport.failDeletes()
        try f.setSharing(false)
        var failed = false
        do { try await client.contextChanged() } catch { failed = true }
        try expect(failed && f.defaults.bool(forKey: "mcp.mirror.removalPending"), "Failed removal was presented as completed")
        try expect(await f.transport.remote != nil, "Synthetic rejection did not preserve the hosted copy")
        try expect(f.credentials.readPending() == [f.password], "Retry credential was not retained at the secure boundary")
        let reopened = f.client()
        await f.transport.allowDeletes()
        try await reopened.contextChanged()
        try expect(await f.transport.remote == nil, "Restart did not retry the pending removal")
        try expect(!f.defaults.bool(forKey: "mcp.mirror.removalPending") && f.credentials.readPending().isEmpty, "Successful retry stayed pending")
    }
    static func uncertainUploadCleanup() async throws {
        let f = try Fixture()
        await f.transport.failAcceptedPost()
        let result = await Task { try await f.client().push() }.result
        if case .success = result { throw TestFailure(description: "Uncertain upload reported success") }
        try expect(await f.transport.remote == nil, "Transport error left the potentially accepted archive hosted")
        try expect(f.defaults.object(forKey: "mcp.mirror.lastPush") == nil, "Uncertain upload stamped successful")
    }
    static func rotateDuringUpload() async throws {
        let f = try Fixture(), client = f.client()
        await f.transport.pauseUpload()
        let push = Task { try await client.push() }
        await f.transport.waitForUpload()
        let rotate = Task { try await client.regenerateToken() }
        while f.credentials.read() == f.password { await Task.yield() }
        await f.transport.resumeUpload()
        _ = await push.result
        _ = try await rotate.value
        let calls = await f.transport.calls
        let firstDelete = calls.firstIndex { $0.method == "DELETE" && $0.path.contains("/p_\(f.password)/") }
        let newPost = calls.firstIndex { $0.method == "POST" && $0.path.contains("/p_\(f.credentials.read())/") }
        try expect(firstDelete != nil && newPost != nil && firstDelete! < newPost!, "New identity uploaded before the captured old identity was removed")
        try expect(try f.unpack(await f.transport.remote!, password: f.credentials.read()).values.joined().contains("shared apricot"), "Rotated identity cannot decrypt the latest projection")
        try expect(f.credentials.readPending().isEmpty, "Successful rotation retained obsolete cleanup credentials")
    }
    static func failedRotationPreservesIdentity() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        let original = await f.transport.remote
        f.credentials.failPasswordWrite()
        let result = await Task { try await client.regenerateToken() }.result
        if case .success = result { throw TestFailure(description: "Failed Keychain write reported a new share identity") }
        try expect(f.credentials.read() == f.password && f.credentials.readPending().isEmpty, "Failed rotation changed the identity or scheduled its deletion")
        try expect(await f.transport.remote == original, "Failed rotation removed the existing cloud copy")
    }
    static func privateTemporaryArchive() throws {
        let f = try Fixture()
        let archive = try MirrorArchive.create(vaultRoot: f.vault, sharedNotes: ContextProjection.notes(store: f.store, audience: .shared))
        defer { archive.remove() }
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.directory.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o700, "Archive staging directory is not private")
        for case let file as URL in FileManager.default.enumerator(at: archive.directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                try expect(mode?.intValue == 0o600, "A temporary plaintext or encrypted archive file has permissive access")
            }
        }
        archive.remove()
        try expect(!FileManager.default.fileExists(atPath: archive.directory.path), "Disposable archive cleanup left plaintext behind")
    }
    static func invalidImportedPath() async throws {
        let f = try Fixture()
        for path in ["../escape.md", "/absolute.md", "folder/../../escape.md", "folder\\escape.md"] {
            var failed = false
            do { let archive = try MirrorArchive.create(vaultRoot: f.vault, sharedNotes: [path: "Synthetic"]); archive.remove() }
            catch { failed = true }
            try expect(failed, "Unsafe imported path was accepted")
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: f.vault.path) == ["README.md"], "Path rejection mutated the legacy vault")
    }
    static func importedOnlyVault() async throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.vault)
        try await f.client().push()
        let files = try f.unpack(await f.transport.remote!)
        try expect(!files.isEmpty && files.keys.allSatisfy { $0.hasPrefix("Imported/") }, "An imported-only mirror requires a fabricated legacy vault")
        try expect(!FileManager.default.fileExists(atPath: f.vault.path), "Mirroring imported context created a legacy vault")
    }
    static func unavailablePasswordRevocation() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        try f.setSharing(false)
        f.credentials.failReads()
        var failed = false
        do { try await client.contextChanged() } catch { failed = true }
        try expect(failed, "Missing credential was presented as successful revocation")
        try expect(f.defaults.object(forKey: "mcp.mirror.lastPush") == nil && f.defaults.bool(forKey: "mcp.mirror.removalPending"), "Unreadable credential retained a successful stamp or lost the pending removal")
        f.credentials.allowReads()
        try await f.client().contextChanged()
        try expect(await f.transport.remote == nil, "Restored credential did not retry the requested revocation")
        try expect(!f.defaults.bool(forKey: "mcp.mirror.removalPending"), "Successful recovered revocation remains pending")
    }
    static func unavailablePasswordDisable() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        f.credentials.failReads()
        await client.disable()
        try expect(await client.isEnabled == false, "Missing credential prevented local opt-out")
        try expect(f.defaults.bool(forKey: "mcp.mirror.removalPending"), "Disable silently lost the remote removal when credentials were unavailable")
        f.credentials.allowReads()
        try await f.client().contextChanged()
        try expect(await f.transport.remote == nil, "Disabled mirror did not recover pending deletion after credentials returned")
    }
    static func repeatedRotationRetriesOldIdentity() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        await f.transport.failDeletes()
        _ = await Task { try await client.regenerateToken() }.result
        let intermediate = f.credentials.read()
        try expect(intermediate != f.password && f.credentials.readPending() == [f.password], "Synthetic first rotation did not retain the old identity for cleanup")
        let firstCount = await f.transport.calls.count
        await f.transport.allowDeletes()
        _ = try await f.client().regenerateToken()
        let retryCalls = await f.transport.calls.dropFirst(firstCount)
        try expect(retryCalls.contains { $0.method == "DELETE" && $0.path.contains("/p_\(f.password)/") }, "Second rotation after restart lost the first identity's pending cleanup credential")
        try expect(retryCalls.contains { $0.method == "DELETE" && $0.path.contains("/p_\(intermediate)/") }, "Second rotation did not remove the intermediate identity")
        try expect(f.credentials.readPending().isEmpty, "Successful repeated rotation retained cleanup work")
    }
    static func unreadableCleanupQueue() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        // Model a crash after persisting cleanup credentials but before updating the defaults flag.
        _ = f.credentials.writePending(["synthetic-older-identity"])
        f.credentials.failPendingReads()
        try f.setSharing(false)
        var failed = false
        do { try await client.contextChanged() } catch { failed = true }
        try expect(failed, "An unreadable cleanup queue was treated as empty")
        try expect(f.credentials.readPending() == ["synthetic-older-identity"], "An inaccessible cleanup identity was overwritten")
        try expect(f.defaults.bool(forKey: "mcp.mirror.removalPending") && f.defaults.object(forKey: "mcp.mirror.lastPush") == nil, "Unverifiable cleanup retained a success stamp or lost its durable pending state")
    }
    static func unavailablePasswordRotation() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        f.credentials.failReads()
        let result = await Task { try await client.regenerateToken() }.result
        if case .success = result { throw TestFailure(description: "Rotation replaced an unreadable primary identity") }
        try expect(f.credentials.read() == f.password, "Rotation overwrote the only old identity before it could be read for cleanup")
        try expect(f.defaults.bool(forKey: "mcp.mirror.removalPending"), "Requested rotation lost its unresolved old-copy removal")
        f.credentials.allowReads()
        try await f.client().contextChanged()
        try expect(await f.transport.remote == nil, "Restored primary key could not complete requested cleanup")
    }
    static func reenableUnavailablePassword() async throws {
        let f = try Fixture(), client = f.client()
        try await client.push()
        f.credentials.failReads()
        await client.disable()
        var failed = false
        do { _ = try await client.enable() } catch { failed = true }
        try expect(failed && f.credentials.read() == f.password, "Re-enable overwrote the unreadable key needed for pending remote cleanup")
        try expect(await client.isEnabled == false, "Failed re-enable changed the local opt-out flag")
        f.credentials.allowReads()
        try await f.client().contextChanged()
        try expect(await f.transport.remote == nil, "Re-enable failure lost the original copy's cleanup credential")
    }
}
