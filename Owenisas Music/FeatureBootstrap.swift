import Foundation

/// Starts the app's background integrations once, at launch.
enum FeatureBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        LibraryCloudSync.shared.start()
        NowPlayingBridge.shared.start()
        Task { @MainActor in
            SleepTimerActivityBridge.shared.start()
            PlaylistWidgetPublisher.shared.start()
        }
        WatchBridge.shared.start()
        IncomingShares.shared.start()
    }

    /// `owenisas://…` links (share extension hand-off, Shortcuts).
    @MainActor
    static func handle(url: URL) {
        if url.scheme?.lowercased() == "owenisas", url.host?.lowercased() == "sleeptimer" {
            AppRouter.shared.showSleepTimer = true
            return
        }
        IncomingShares.shared.handle(url: url)
    }
}
