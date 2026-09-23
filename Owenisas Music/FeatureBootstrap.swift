import Foundation

/// Starts the app's background integrations once, at launch.
enum FeatureBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        LibraryCloudSync.shared.start()
        NowPlayingBridge.shared.start()
        WatchBridge.shared.start()
        IncomingShares.shared.start()
    }

    /// `owenisas://…` links (share extension hand-off, Shortcuts).
    static func handle(url: URL) {
        IncomingShares.shared.handle(url: url)
    }
}
