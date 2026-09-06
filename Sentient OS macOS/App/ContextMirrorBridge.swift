// Production-only notification bridge. Isolated context test windows never activate live sharing.
import Foundation

@MainActor @Observable
final class ContextMirrorBridge {
    @ObservationIgnored private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("SentientContextChanged"), object: nil, queue: .main) { _ in
            Task { @MainActor in await Self.refreshRemote() }
        }
    }
    static func refreshRemote() async {
        do {
            try await MirrorClient.shared.contextChanged()
            if await MirrorClient.shared.isEnabled { VaultActivity.shared.markChanged() }
        } catch {
            ContextLibrary.shared.lastError = "Local context is updated, but the remote mirror could not be refreshed or removed. Its previous shared copy may still be available. Check the connection and retry sharing."
        }
    }
}
