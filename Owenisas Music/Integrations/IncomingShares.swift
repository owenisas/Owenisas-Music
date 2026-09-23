import Foundation
import UIKit

/// Links and files handed over by the share extension (App Group inbox, see
/// `SharedInbox`) or by `owenisas://` URLs (share extension hand-off,
/// Shortcuts):
///
/// - `owenisas://download` (also `import`, `inbox`): drain the inbox now.
/// - `owenisas://download?url=<link>[&choice=song|playlist]` (personal
///   builds): queue that link, then drain. The link may be percent-encoded
///   or not.
///
/// Draining runs at launch and on every activation. Shared audio files are
/// imported into the library in both builds; in personal builds queued links
/// go to the Download tab, which downloads them one at a time, in order.
final class IncomingShares {
    static let shared = IncomingShares()

    private var activationObserver: NSObjectProtocol?

    func start() {
        onMain { self.startOnMain() }
    }

    func handle(url: URL) {
        let action = IncomingShareURL.action(for: url)
        onMain { self.perform(action) }
    }

    /// Call sites (FeatureBootstrap, onOpenURL) are on the main thread.
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    @MainActor
    private func startOnMain() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { IncomingShares.shared.drain() }
        }
        SharedInbox.shared?.sweepAbandonedCopies()
        drain()
    }

    @MainActor
    private func perform(_ action: IncomingShareURL.Action) {
        switch action {
        case .drain:
            drain()
        #if !APP_STORE
        case .download(let link, let choice):
            if let inbox = SharedInbox.shared {
                do {
                    try inbox.enqueue(link: link, choice: choice)
                } catch {
                    DownloadDebugLog.write("Incoming link couldn't be queued in the App Group: \(error.localizedDescription)")
                    queueDirectly(link: link, choice: choice)
                }
            } else {
                queueDirectly(link: link, choice: choice)
            }
            drain()
        #endif
        case .showNowPlaying:
            // Widget tap: bring up the player (nothing to show if the queue is empty).
            let player = MusicPlayerManager.shared
            if player.currentSong != nil { player.showFullPlayer = true }
        case .ignore:
            break
        }
    }

    @MainActor
    func drain() {
        guard let inbox = SharedInbox.shared else { return }
        importAudio(from: inbox)
        #if !APP_STORE
        deliverLinks(from: inbox)
        #endif
    }

    /// Imports each shared audio file, then removes it from the inbox. A file
    /// whose copy failed (for example, the phone is full) stays for the next
    /// activation; one with an unsupported type is dropped.
    @MainActor
    private func importAudio(from inbox: SharedInbox) {
        let files = inbox.pendingAudioFiles()
        guard !files.isEmpty else { return }
        let dataManager = DataManager.shared
        var imported = 0
        for file in files {
            let supported = DataManager.importableAudioExtensions.contains(file.pathExtension.lowercased())
            let result = supported ? dataManager.importAudioFiles(from: [file]) : (imported: 0, skipped: 1)
            imported += result.imported
            if result.imported > 0 || !supported {
                inbox.removeAudio(file)
            }
        }
        print("[IncomingShares] Imported \(imported) of \(files.count) shared audio file(s)")
    }

    #if !APP_STORE
    @MainActor
    private func deliverLinks(from inbox: SharedInbox) {
        let pending = inbox.pendingLinks()
        guard !pending.isEmpty else { return }
        if DownloadRequestCenter.shared.accept(pending) > 0 {
            AppRouter.shared.selectedTab = .download
        }
    }

    /// No App Group container (misconfigured signing): queue in memory only.
    @MainActor
    private func queueDirectly(link: String, choice: SharedInbox.LinkRequest.Choice?) {
        let request = SharedInbox.LinkRequest(id: UUID(), link: link, choice: choice, createdAt: Date())
        if DownloadRequestCenter.shared.accept([request]) > 0 {
            AppRouter.shared.selectedTab = .download
        }
    }
    #endif
}

/// Parses `owenisas://` URLs. Pure, for tests.
enum IncomingShareURL {
    enum Action: Equatable {
        case drain
        #if !APP_STORE
        case download(link: String, choice: SharedInbox.LinkRequest.Choice?)
        #endif
        /// `owenisas://nowplaying` (widget tap): open the full player.
        case showNowPlaying
        case ignore
    }

    static let scheme = "owenisas"
    static let drainRoutes: Set<String> = ["download", "import", "inbox"]

    static func action(for url: URL) -> Action {
        guard url.scheme?.lowercased() == scheme else { return .ignore }
        // `owenisas://download` has a host; `owenisas:download` only a path.
        let host = (url.host ?? "").lowercased()
        let route = host.isEmpty ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() : host
        if route == "nowplaying" { return .showNowPlaying }
        guard drainRoutes.contains(route) else { return .ignore }
        #if !APP_STORE
        if route == "download", let (link, choice) = linkParameter(of: url) {
            return .download(link: link, choice: choice)
        }
        #endif
        return .drain
    }

    #if !APP_STORE
    /// `url=` takes the rest of the query (up to a trailing `&choice=`), so
    /// an unencoded link keeps its own `&list=…`.
    static func linkParameter(of url: URL) -> (String, SharedInbox.LinkRequest.Choice?)? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }
        var choice: SharedInbox.LinkRequest.Choice?
        var remainder = query
        if let range = remainder.range(of: "&choice=", options: [.caseInsensitive, .backwards]) {
            let value = remainder[range.upperBound...].split(separator: "&").first.map(String.init) ?? ""
            choice = SharedInbox.LinkRequest.Choice(rawValue: value.lowercased())
            remainder = String(remainder[..<range.lowerBound])
        } else if remainder.lowercased().hasPrefix("choice=") {
            let parts = remainder.split(separator: "&", maxSplits: 1).map(String.init)
            choice = SharedInbox.LinkRequest.Choice(rawValue: String(parts[0].dropFirst("choice=".count)).lowercased())
            remainder = parts.count > 1 ? parts[1] : ""
        }
        guard let range = remainder.range(of: "url=", options: .caseInsensitive),
              range.lowerBound == remainder.startIndex || remainder[remainder.index(before: range.lowerBound)] == "&" else {
            return nil
        }
        let raw = String(remainder[range.upperBound...])
        let decoded = (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return (decoded, choice)
    }
    #endif
}
