//
//  MirrorClient.swift
//  Sentient OS macOS
//
//  The app side of the hosted MCP mirror. Mirrors the local vault to our one
//  persistent backend so the user's ChatGPT/Claude can read it over MCP. Opt-in, opt-out,
//  one-click delete — the Mac's vault is always canonical; the mirror is a disposable copy.
//
//  IDENTITY = ONE PASSWORD, NO ACCOUNTS (Invariant 4):
//   The share URL is mcp.sentient-os.ai/u_<userID>/p_<password>/mcp. The PASSWORD is the one
//   root secret (minted on opt-in, kept in the Keychain); the userID is DERIVED from it (a
//   one-way HKDF) and is a public, non-secret label. Because userID = f(password), the server
//   can verify statelessly that a URL's userID belongs to its password — that binding authorizes
//   reads AND push/delete/stats with no separate credential. Tradeoff: anyone who sees the full
//   share URL can also overwrite/delete the vault (and the server decrypts it for the instant of
//   a request); mitigated by no accounts, the 30-day lease, one-click delete, encryption at rest,
//   and the vault being PII-stripped. Losing the password is a non-event (mint a new one → new
//   URL, re-push; the orphaned cloud copy expires on its 30-day lease).
//
//  ENCRYPTED AT REST: push() encrypts the whole vault zip with AES-256-GCM (key derived from the
//   password via HKDF) BEFORE upload, so the server only ever stores ciphertext. See MirrorCrypto.
//
//  Sync = whole-vault encrypted-blob replace: POST /vault sends the entire vault as one encrypted
//  blob (~KBs of markdown) on any change; DELETE /vault is the one-click delete.
//
//  Doc: Documentation/MCP Mirror Client.md
//

import Foundation
import CryptoKit
import Security

/// The mirror's key schedule + envelope. MUST stay byte-for-byte in sync with the server's
/// `crypto.py` (same salt, info labels, lengths, AAD, and blob layout) or nothing decrypts.
///
///   encKey = HKDF-SHA256(ikm: password-utf8, salt: SALT, info: INFO_KEY, len: 32)   → AES-256 key
///   userID = base64url(HKDF-SHA256(password-utf8, SALT, INFO_UID, 32))[:UID_LEN]     (public label)
///   blob   = [1 byte version=1] + AES-GCM.combined(nonce ‖ ciphertext ‖ tag), AAD = userID
nonisolated enum MirrorCrypto {
    static let salt = Data("sentient-os-mirror-v1".utf8)
    static let infoKey = Data("vault-content-key".utf8)
    static let infoUID = Data("vault-user-id".utf8)
    static let uidLen = 20
    static let version: UInt8 = 1

    private static func hkdf(_ password: String, info: Data, len: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                               salt: salt, info: info, outputByteCount: len)
    }

    /// The public, non-secret vault label — a truncated base64url HKDF of the password.
    static func userID(_ password: String) -> String {
        let raw = hkdf(password, info: infoUID, len: 32).withUnsafeBytes { Data($0) }
        return String(base64url(raw).prefix(uidLen))
    }

    /// Encrypt the vault zip for upload: versioned AES-256-GCM with the userID as AAD.
    static func encrypt(_ plaintext: Data, password: String, uid: String) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: hkdf(password, info: infoKey, len: 32),
                                      authenticating: Data(uid.utf8))
        guard let combined = sealed.combined else { throw MirrorClient.MirrorError.encryptionFailed }
        var out = Data([version])
        out.append(combined)      // nonce(12) ‖ ciphertext ‖ tag(16)
        return out
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

actor MirrorClient {

    static let shared = MirrorClient()

    /// The external boundaries are injectable so regression tests never use live credentials,
    /// defaults, source stores, or network services. The actor owns access to these dependencies.
    nonisolated struct Dependencies: @unchecked Sendable {
        var defaults: UserDefaults
        var readPassword: @Sendable () -> String?
        var setPassword: @Sendable (String) -> Bool
        var deleteLegacyPassword: @Sendable () -> Void
        var vaultRoot: @Sendable () -> URL
        var sharedNotes: @Sendable () throws -> [String: String]
        var transport: @Sendable (URLRequest, Data?) async throws -> (Data, URLResponse)
        var readPendingPasswords: @Sendable () -> [String]? = { [] }
        var setPendingPasswords: @Sendable ([String]) -> Bool = { _ in true }

        static let live = Dependencies(
            defaults: .standard,
            readPassword: { Keychain.read(MirrorClient.passwordKey) },
            setPassword: { Keychain.set(MirrorClient.passwordKey, $0) },
            deleteLegacyPassword: { Keychain.delete(MirrorClient.legacyTokenKey) },
            vaultRoot: { VaultGenerator.vaultRoot },
            sharedNotes: { try ContextProjection.notes(store: ContextPaths.openStore(), audience: .shared) },
            transport: { request, body in
                if let body { return try await URLSession.shared.upload(for: request, from: body) }
                return try await URLSession.shared.data(for: request)
            },
            readPendingPasswords: {
                let result = Keychain.readResult(MirrorClient.pendingPasswordsKey)
                if result.status == errSecItemNotFound { return [] } // A pre-queue installation has no pending identities.
                guard result.status == errSecSuccess, let data = result.value?.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode([String].self, from: data)
            },
            setPendingPasswords: { passwords in
                guard let data = try? JSONEncoder().encode(passwords), let value = String(data: data, encoding: .utf8) else { return false }
                return Keychain.set(MirrorClient.pendingPasswordsKey, value)
            })
    }

    private let dependencies: Dependencies
    private var pendingPasswords: Set<String>
    private var controlGeneration: UInt64 = 0
    private var remoteBusy = false
    private var remoteWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        pendingPasswords = [] // Merely reading isEnabled must not access live Keychain items.
    }

    /// Production mirror. Overridable for local server testing via SENTIENT_MIRROR_BASE — but
    /// DEBUG ONLY: the password rides in the URL path, so in a Release build a same-user process
    /// must NOT be able to redirect the push (and thereby harvest the password + encrypted vault)
    /// merely by launching the app with an env var. Self-tests run the Debug binary, so they keep it.
    static var baseURL: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SENTIENT_MIRROR_BASE"], !override.isEmpty {
            return override
        }
        #endif
        return "https://mcp.sentient-os.ai"
    }

    /// The coached system prompt the user pastes into ChatGPT/Claude/Gemini (custom instructions).
    /// Naming the connector + coaching the get_structure-first habit is what reliably makes the
    /// client load and use the tools — clients lazy-load connector tools behind a search gate
    /// (field lessons in Documentation/MCP Mirror Client.md).
    /// Lives here (the MCP owner) so every surface that offers "Copy System Prompt" shares one copy.
    static let systemPrompt = """
        You have access to the user's personal knowledge base through the Sentient OS MCP: an \
        Obsidian-style vault of markdown notes created just for you, to give you context about their \
        entire life (work, projects, plans, relationships, places, preferences, history…). It was \
        built by Sentient OS privately on their own device from their notes, messages, emails, and files.

        At the start of any conversation where knowing the user could help (that's most of them!), \
        call `get_structure`. It returns the vault's folder and file index, plus the README: a \
        portrait of the user with the most important context. Then call `get_files` to actually \
        read any relevant notes you may want to read.
        """

    struct Stats: Sendable {
        let notesRead24h: Int
        let toolCalls24h: Int
        let lastAccess: Date?
    }

    enum MirrorError: LocalizedError {
        case notEnabled
        case http(Int, String)          // status 0 = no HTTP response at all (proxy / captive portal)
        case zipFailed(String)
        case encryptionFailed           // AES-GCM seal failed — never upload plaintext as a fallback
        case noVault
        case tokenGenerationFailed      // SecRandomCopyBytes failed — never mint a weak/zero key (B3)
        case keychainWriteFailed        // SecItemAdd failed — don't hand out a URL for an unstored key (B3)
        case changedDuringPush
        case remoteRemovalPending

        var errorDescription: String? {
            switch self {
            case .notEnabled:            return "The cloud mirror isn't turned on."
            case .http(0, _):            return "Couldn't reach the mirror server (no HTTP response; proxy or captive portal?)."
            case .http(let c, let b):    return "Mirror server returned HTTP \(c). \(b.prefix(200))"
            case .zipFailed(let m):      return "Couldn't package the vault: \(m)"
            case .encryptionFailed:      return "Couldn't encrypt the vault for upload. Please try again."
            case .noVault:               return "There's no vault on disk to mirror yet."
            case .tokenGenerationFailed: return "Couldn't generate a secure mirror key. Please try again."
            case .keychainWriteFailed:   return "Couldn't save the mirror key to the Keychain. Please try again."
            case .changedDuringPush:     return "Sharing or mirror settings changed during sync. The old copy was removed; retry to sync current content."
            case .remoteRemovalPending:  return "Remote removal is still pending. Check the connection and Keychain access, then retry. The hosted copy may remain readable until removal succeeds or its lease expires."
            }
        }
    }

    // MARK: Enable / disable

    /// Whether mirroring is currently ON. Deliberately INDEPENDENT of the password's existence: the
    /// password (the identity, Invariant 4) is minted once and kept forever so the share link stays
    /// stable across OFF→ON — it's what the user pasted into ChatGPT/Claude, so toggling must never
    /// reroll it. This flag is the on/off the toggle flips, and what gates auto-push.
    var isEnabled: Bool { dependencies.defaults.bool(forKey: Self.enabledKey) }

    /// Opt in: mint the password if absent (idempotent — an existing password is kept, so the
    /// share URL is stable) and flip mirroring ON. Returns the share URL.
    @discardableResult
    func enable() throws -> String {
        try recoverPending()
        let old = dependencies.readPassword()
        try requirePriorIdentity(old)
        if old == nil {
            let password = try Self.mintPassword()                   // throws rather than mint a weak key (B3)
            guard dependencies.setPassword(password) else { throw MirrorError.keychainWriteFailed }
            dependencies.deleteLegacyPassword()                     // sweep any pre-encryption single token
        }
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }   // password didn't read back
        dependencies.defaults.set(true, forKey: Self.enabledKey)
        Task { @MainActor in Analytics.signal("Mirror.enabled") }
        return url
    }

    /// The user-facing MCP connector URL, or nil if no identity exists. The retained identity is
    /// available while disabled so OFF→ON keeps the same link. This is what "Copy MCP Link"
    /// copies and what gets pasted into ChatGPT/Claude. Format: /u_<userID>/p_<password>/mcp.
    var shareURL: String? {
        guard let password = dependencies.readPassword() else { return nil }
        return "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/mcp"
    }

    /// A display-safe version of the share URL: the userID shows (it's public), the PASSWORD is
    /// masked to its first 4 chars. ⚠️ "/mcp" is searched BACKWARDS: the host
    /// "https://mcp.sentient-os.ai" contains "/mcp", and a forward hit inverts the range.
    nonisolated static func maskedURL(_ url: String?) -> String {
        guard let url,
              let pStart = url.range(of: "/p_"),
              let end = url.range(of: "/mcp", options: .backwards),
              pStart.upperBound <= end.lowerBound else { return "mcp.sentient-os.ai/u_…/p_…/mcp" }
        let password = url[pStart.upperBound..<end.lowerBound]
        // Everything up to "/p_" — host + "/u_<userID>" — with the scheme stripped for display.
        let head = url[url.startIndex..<pStart.lowerBound]
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")     // dev SENTIENT_MIRROR_BASE override
        return "\(head)/p_\(password.prefix(4))••••••••/mcp"
    }

    // MARK: Push / delete / stats

    /// Zip the local vault, ENCRYPT it, and replace the mirror with the ciphertext. Renews the
    /// 30-day lease. No-op-safe to call after any vault change (initial gen, daily update, edit).
    func push() async throws {
        guard isEnabled else { throw MirrorError.notEnabled }
        let generation = controlGeneration
        await acquireRemote()
        defer { releaseRemote() }
        try Task.checkCancellation()
        guard isEnabled, generation == controlGeneration else { throw MirrorError.notEnabled }
        try recoverPending()
        let storedPassword = dependencies.readPassword()
        try requirePriorIdentity(storedPassword)
        guard let password = storedPassword else { throw MirrorError.notEnabled }
        for pending in pendingPasswords.sorted() { try await deleteCaptured(password: pending) }

        // A source may change while the HTTP request is in flight. Revoke the captured copy before
        // retrying with fresh permissions; a continuously changing source leaves the mirror empty.
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard isEnabled, generation == controlGeneration, dependencies.readPassword() == password else {
                throw MirrorError.changedDuringPush
            }
            let notes: [String: String]
            do { notes = try dependencies.sharedNotes() }
            catch {
                clearSyncStamp()
                try await deleteCaptured(password: password)
                throw error
            }
            if dependencies.defaults.object(forKey: Self.lastPushKey) != nil,
               MirrorArchive.digest(notes) != dependencies.defaults.string(forKey: Self.sharedDigestKey) {
                clearSyncStamp()
                try await deleteCaptured(password: password)
            }
            let archive = try MirrorArchive.create(vaultRoot: dependencies.vaultRoot(), sharedNotes: notes)
            defer { archive.remove() }
            do {
                if try MirrorArchive.digest(dependencies.sharedNotes()) != archive.sharedDigest { continue }
            } catch {
                clearSyncStamp()
                try await deleteCaptured(password: password)
                throw error
            }
            try Task.checkCancellation()
            guard isEnabled, generation == controlGeneration, dependencies.readPassword() == password else { throw MirrorError.changedDuringPush }
            let blob = try MirrorCrypto.encrypt(try Data(contentsOf: archive.zip), password: password, uid: MirrorCrypto.userID(password))
            guard blob.count <= 60 * 1_024 * 1_024 else { throw MirrorError.zipFailed("The encrypted archive exceeds the mirror's 60 MB upload limit.") }
            try rememberPending(password) // A crash or uncertain upload must leave recoverable cleanup.
            clearSyncStamp()
            var req = Self.vaultRequest(password: password, method: "POST")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            do {
                let (data, response) = try await dependencies.transport(req, blob)
                try Self.check(response, data)
                try Task.checkCancellation()
                guard isEnabled, generation == controlGeneration, dependencies.readPassword() == password else {
                    throw MirrorError.changedDuringPush
                }
                let current = try MirrorArchive.digest(dependencies.sharedNotes())
                if current != archive.sharedDigest {
                    try await deleteCaptured(password: password)
                    continue
                }
                try forgetPending(password)
                dependencies.defaults.set(archive.sharedDigest, forKey: Self.sharedDigestKey)
                dependencies.defaults.set(Date(), forKey: Self.lastPushKey)
                Task { @MainActor in Analytics.signal("Mirror.pushed") }
                return
            } catch {
                // URLSession cancellation is not proof the server rejected the POST. Cleanup runs
                // in an uncancelled task and keeps the mutation gate until it acknowledges deletion.
                try await deleteCaptured(password: password)
                throw error
            }
        }
        clearSyncStamp()
        try await deleteCaptured(password: password)
        throw MirrorError.changedDuringPush
    }

    /// When the mirror last synced (the last successful push) — the Connect-AIs pill's stamp.
    /// nil if never pushed, or since deleted.
    nonisolated static var lastPush: Date? {
        UserDefaults.standard.object(forKey: lastPushKey) as? Date
    }

    /// A durable, truthful UI state: local sharing is off immediately, but remote deletion can fail.
    nonisolated static var remoteRemovalPending: Bool {
        UserDefaults.standard.bool(forKey: removalPendingKey)
    }

    /// Called after persisted source permission/removal changes. Remove a stale hosted projection
    /// promptly; the existing dirty-vault debounce can rebuild it. No request is made for a local-only
    /// change whose current shared projection still matches the last successful upload.
    func contextChanged() async throws {
        guard isEnabled || dependencies.defaults.bool(forKey: Self.removalPendingKey) ||
              dependencies.defaults.object(forKey: Self.lastPushKey) != nil || !pendingPasswords.isEmpty else { return }
        try recoverPending()
        guard dependencies.defaults.object(forKey: Self.lastPushKey) != nil || !pendingPasswords.isEmpty else { return }
        await acquireRemote()
        defer { releaseRemote() }
        for pending in pendingPasswords.sorted() { try await deleteCaptured(password: pending) }
        guard dependencies.defaults.object(forKey: Self.lastPushKey) != nil else { return }
        guard let password = dependencies.readPassword() else {
            clearSyncStamp()
            dependencies.defaults.set(true, forKey: Self.removalPendingKey)
            throw MirrorError.remoteRemovalPending
        }
        do {
            if isEnabled, try MirrorArchive.digest(dependencies.sharedNotes()) == dependencies.defaults.string(forKey: Self.sharedDigestKey) { return }
        } catch {
            clearSyncStamp()
            try await deleteCaptured(password: password)
            throw error
        }
        clearSyncStamp()
        try await deleteCaptured(password: password)
    }

    /// The one-click delete — removes the cloud copy (and its access log). The local vault
    /// is untouched. The password is kept so re-enabling reuses the same share URL.
    func deleteRemote() async throws {
        controlGeneration &+= 1
        let knownRemote = dependencies.defaults.object(forKey: Self.lastPushKey) != nil
        clearSyncStamp()
        try recoverPending()
        if let password = dependencies.readPassword() { try rememberPending(password) }
        else if knownRemote && pendingPasswords.isEmpty {
            dependencies.defaults.set(true, forKey: Self.removalPendingKey)
            throw MirrorError.remoteRemovalPending
        }
        guard !pendingPasswords.isEmpty else { throw MirrorError.notEnabled }
        await acquireRemote()
        defer { releaseRemote() }
        try recoverPending()
        for pending in pendingPasswords.sorted() { try await deleteCaptured(password: pending) }
    }

    /// Opt out: flip mirroring OFF and delete the cloud copy, but KEEP the token so re-enabling
    /// reuses the SAME share URL (it's what the user pasted into ChatGPT/Claude — opting out must
    /// not break those connectors). Best-effort on the network call; the local OFF always sticks.
    func disable() async {
        dependencies.defaults.set(false, forKey: Self.enabledKey)
        Task { @MainActor in Analytics.signal("Mirror.disabled") }
        try? await deleteRemote()
    }

    /// Mint a NEW password — the remediation if a share URL ever leaks. The old identity stays in
    /// the Keychain cleanup queue until deletion succeeds, including across a restart. A failed
    /// removal or re-push throws; the caller must not promise the new URL is already serving data.
    func regenerateToken() async throws -> String {
        // Mint + persist the NEW password BEFORE deleting the old copy — a mint/write failure must
        // never leave the user with no cloud copy AND the old (now-orphaned) identity still active.
        try recoverPending() // A previous rotation may still own cleanup identities after restart.
        let old = dependencies.readPassword()
        try requirePriorIdentity(old)
        let password = try Self.mintPassword()
        let alreadyPending = old.map { pendingPasswords.contains($0) } ?? false
        if let old { try rememberPending(old) } // Persist the old identity until deletion succeeds.
        guard dependencies.setPassword(password) else {
            if let old, !alreadyPending { try? forgetPending(old) }
            throw MirrorError.keychainWriteFailed
        }
        controlGeneration &+= 1
        clearSyncStamp()
        await acquireRemote()
        do {
            for pending in pendingPasswords.sorted() { try await deleteCaptured(password: pending) }
        } catch { releaseRemote(); throw error }
        releaseRemote()
        Task { @MainActor in Analytics.signal("Mirror.regenerated") }
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }
        if isEnabled { try await push() }
        return url
    }

    /// The "your AIs read N notes" numbers for the home screen. nil if not enabled / no vault yet.
    func stats() async throws -> Stats {
        guard isEnabled, let password = dependencies.readPassword() else { throw MirrorError.notEnabled }
        let req = URLRequest(url: URL(string: "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/stats")!)
        let (data, resp) = try await dependencies.transport(req, nil)
        try Self.check(resp, data)
        guard isEnabled, dependencies.readPassword() == password else { throw MirrorError.notEnabled }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let last = (obj["last_access"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Stats(notesRead24h: obj["notes_read_24h"] as? Int ?? 0,
                     toolCalls24h: obj["tool_calls_24h"] as? Int ?? 0,
                     lastAccess: last)
    }

    /// Uninstall's sweep of the mirror identity — the ONE caller that deletes the Keychain password
    /// (+ the legacy token). Everywhere else the password survives by design (the share URL pasted
    /// into the user's connectors must outlive resets and off→on); uninstall is where that virtue
    /// ends. Call AFTER `deleteRemote()` — the cloud DELETE needs the password to authorize.
    nonisolated static func destroyKeychainIdentity() {
        Keychain.delete(passwordKey)
        Keychain.delete(legacyTokenKey)
        Keychain.delete(pendingPasswordsKey)
    }

    // MARK: Helpers

    private static let passwordKey = "mcp.mirror.password"  // Keychain: the root secret (persists)
    private static let legacyTokenKey = "mcp.mirror.token"  // pre-encryption single token — swept on enable
    private static let enabledKey = "mcp.mirror.enabled"    // UserDefaults: the on/off the toggle flips
    private static let lastPushKey = "mcp.mirror.lastPush"  // UserDefaults: last successful push (Date)
    private static let sharedDigestKey = "mcp.mirror.sharedDigest"
    private static let removalPendingKey = "mcp.mirror.removalPending"
    private static let pendingPasswordsKey = "mcp.mirror.pendingDeletions" // Keychain only; never defaults or logs

    private func clearSyncStamp() {
        dependencies.defaults.removeObject(forKey: Self.lastPushKey)
        dependencies.defaults.removeObject(forKey: Self.sharedDigestKey)
    }

    private func rememberPending(_ password: String) throws {
        let retained = pendingPasswords.union([password])
        // Set the durable wake-up signal first. A disabled restart must know to inspect the
        // Keychain queue even if the app quits between these two separate persistence operations.
        dependencies.defaults.set(true, forKey: Self.removalPendingKey)
        guard dependencies.setPendingPasswords(retained.sorted()) else { throw MirrorError.keychainWriteFailed }
        pendingPasswords = retained
    }

    private func requirePriorIdentity(_ password: String?) throws {
        if password == nil && (isEnabled || dependencies.defaults.object(forKey: Self.lastPushKey) != nil ||
                               dependencies.defaults.bool(forKey: Self.removalPendingKey) || !pendingPasswords.isEmpty) {
            clearSyncStamp()
            dependencies.defaults.set(true, forKey: Self.removalPendingKey)
            throw MirrorError.remoteRemovalPending
        }
    }

    private func recoverPending() throws {
        guard let saved = dependencies.readPendingPasswords() else {
            // An absent Keychain item is []. nil means unreadable/corrupt; never overwrite it,
            // even if a prior crash prevented the separate defaults flag from being recorded.
            clearSyncStamp()
            dependencies.defaults.set(true, forKey: Self.removalPendingKey)
            throw MirrorError.remoteRemovalPending
        }
        pendingPasswords.formUnion(saved)
        if dependencies.defaults.bool(forKey: Self.removalPendingKey), pendingPasswords.isEmpty {
            // A removal can be requested while the primary Keychain item is temporarily locked.
            // The durable flag retains that request even though its credential could not be read.
            guard let password = dependencies.readPassword() else { throw MirrorError.remoteRemovalPending }
            try rememberPending(password)
        }
    }

    private func forgetPending(_ password: String) throws {
        let retained = pendingPasswords.subtracting([password])
        guard dependencies.setPendingPasswords(retained.sorted()) else { throw MirrorError.keychainWriteFailed }
        pendingPasswords = retained
        dependencies.defaults.set(!retained.isEmpty, forKey: Self.removalPendingKey)
    }

    private static func vaultRequest(password: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/vault")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        return request
    }

    /// All POST/DELETE requests pass this gate. Actor isolation alone allows requests to overtake
    /// each other at awaits (a late POST can otherwise recreate a just-deleted cloud copy).
    private func acquireRemote() async {
        if !remoteBusy { remoteBusy = true; return }
        await withCheckedContinuation { remoteWaiters.append($0) }
    }
    private func releaseRemote() {
        if remoteWaiters.isEmpty { remoteBusy = false }
        else { remoteWaiters.removeFirst().resume() }
    }

    private func deleteCaptured(password: String) async throws {
        // Even a Keychain write failure should not prevent an already-authorized network removal.
        try? rememberPending(password)
        pendingPasswords.insert(password)
        dependencies.defaults.set(true, forKey: Self.removalPendingKey)
        let transport = dependencies.transport
        let request = Self.vaultRequest(password: password, method: "DELETE")
        do {
            let (data, response) = try await Task.detached { try await transport(request, nil) }.value
            try Self.check(response, data)
            try forgetPending(password)
        } catch { throw MirrorError.remoteRemovalPending }
    }

    /// 18 random bytes → base64url (24 chars, no padding) — inside the server's [16,64] window
    /// and URL-safe, so it drops straight into the path. 144 bits: infeasible to brute-force,
    /// which is what backs both the encryption key and the userID⇄password binding.
    private static func mintPassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        // B3: on failure SecRandomCopyBytes leaves `bytes` all-zero → a predictable identity. Fail
        // loudly instead of ever minting a weak key.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MirrorError.tokenGenerationFailed
        }
        return MirrorCrypto.base64url(Data(bytes))
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        // B4: a non-HTTP response (captive portal / transparent proxy returning something odd) must
        // NOT count as success — that would mark a never-synced vault as synced and clear vaultDirty.
        guard let http = resp as? HTTPURLResponse else { throw MirrorError.http(0, "non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw MirrorError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

}

// MARK: - Keychain (first user: a tiny generic-password helper)

/// Minimal Keychain wrapper for small secrets (the mirror tokens). One service, key = account.
nonisolated enum Keychain {
    private static let service = "ai.sentient-os.app"

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false } // A failed update preserves the old secret.
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ key: String) -> String? {
        readResult(key).value
    }

    /// Preserve the distinction between an absent item and an inaccessible/corrupt cleanup queue.
    static func readResult(_ key: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
