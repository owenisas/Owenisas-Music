import Foundation
import WatchConnectivity
import WatchKit

/// Watch side of WatchConnectivity: the iPhone's now-playing state, requests
/// to the phone, and incoming audio files.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    enum LinkError: LocalizedError, Equatable {
        case notReachable
        case phoneNotReady
        case timedOut
        case incompatible
        case notFound
        case other(String)

        var errorDescription: String? {
            switch self {
            case .notReachable: return "Open Owenisas Music on your iPhone and keep it nearby."
            case .phoneNotReady: return "Open Owenisas Music on your iPhone."
            case .timedOut: return "Your iPhone didn't answer. Open Owenisas Music on your iPhone."
            case .incompatible: return "Update Owenisas Music on your iPhone and Apple Watch."
            case .notFound: return "That list is no longer on your iPhone."
            case .other(let message): return message
            }
        }

        /// Opening the phone app is the fix.
        var needsPhoneApp: Bool {
            switch self {
            case .notReachable, .phoneNotReady, .timedOut: return true
            default: return false
            }
        }
    }

    @Published private(set) var nowPlaying: WatchNowPlaying?
    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false
    @Published private(set) var companionAppInstalled = true

    private let session: WCSession?
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private static let requestTimeout: TimeInterval = 15

    /// Canned data for SwiftUI previews (no session).
    private var previewSongs: [WatchListRef: [WatchSongItem]]?
    private var previewPlaylists: [WatchPlaylistItem]?

    private override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    private init(preview nowPlaying: WatchNowPlaying?, songs: [WatchListRef: [WatchSongItem]], playlists: [WatchPlaylistItem], reachable: Bool) {
        session = nil
        super.init()
        self.nowPlaying = nowPlaying
        self.previewSongs = songs
        self.previewPlaylists = playlists
        self.isReachable = reachable
        self.isActivated = true
    }

    static func preview(
        nowPlaying: WatchNowPlaying? = PreviewFixtures.nowPlaying,
        reachable: Bool = true
    ) -> PhoneLink {
        PhoneLink(
            preview: nowPlaying,
            songs: [.liked: PreviewFixtures.songs, .recentlyAdded: PreviewFixtures.songs, .playlist("p1"): PreviewFixtures.songs],
            playlists: PreviewFixtures.playlists,
            reachable: reachable
        )
    }

    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: - Requests

    private func request<Body: Encodable, Reply: Decodable>(
        _ kind: WatchMessageKind,
        _ body: Body,
        as type: Reply.Type
    ) async throws -> Reply {
        guard let session, session.activationState == .activated else { throw LinkError.notReachable }
        guard session.isReachable else { throw LinkError.notReachable }
        let message = try WatchEnvelope.encode(kind, body)
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            session.sendMessage(message, replyHandler: { once.resume(returning: $0) }, errorHandler: { error in
                once.resume(throwing: Self.linkError(from: error))
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) {
                once.resume(throwing: LinkError.timedOut)
            }
        }
        do {
            return try WatchEnvelope.decodeReply(reply, expecting: kind, as: Reply.self)
        } catch WatchCodingError.remote(let failure) {
            switch failure.code {
            case .phoneNotReady: throw LinkError.phoneNotReady
            case .incompatibleVersion, .unsupported: throw LinkError.incompatible
            case .notFound: throw LinkError.notFound
            case .badRequest, .internalError: throw LinkError.other(failure.message)
            }
        } catch WatchCodingError.incompatible {
            throw LinkError.incompatible
        }
    }

    private nonisolated static func linkError(from error: Error) -> LinkError {
        let code = (error as? WCError)?.code
        switch code {
        case .notReachable?, .companionAppNotInstalled?, .deviceNotPaired?, .sessionNotActivated?:
            return .notReachable
        case .messageReplyTimedOut?, .messageReplyFailed?, .transferTimedOut?:
            return .timedOut
        default:
            return .other(error.localizedDescription)
        }
    }

    /// Send a player command; the reply carries the phone's new state.
    func send(_ command: WatchCommand) async throws {
        if previewSongs != nil { return }
        applyOptimistically(command)
        do {
            let state = try await request(.command, command, as: WatchNowPlaying.self)
            accept(state, force: true)
        } catch {
            // Undo the optimistic change by asking again (best effort).
            if let fresh = try? await request(.command, WatchCommand(action: .refresh), as: WatchNowPlaying.self) {
                accept(fresh, force: true)
            }
            throw error
        }
    }

    /// Play `song` within `list` on the phone; shows it right away.
    func play(_ song: WatchSongItem, in list: WatchListRef) async throws {
        guard previewSongs == nil else { return }
        let previous = nowPlaying
        nowPlaying = WatchNowPlaying(
            songID: song.id, title: song.title, artist: song.artist,
            isPlaying: true, isFavorited: song.isFavorited,
            duration: song.duration, elapsed: 0, rate: previous?.rate ?? 1,
            capturedAt: Date(), queueIndex: 0, queueCount: 0
        )
        try await send(.playSong(song.id, in: list))
    }

    /// Pull the phone's state (e.g. when the app becomes active).
    func refresh() async {
        guard let state = try? await request(.command, WatchCommand(action: .refresh), as: WatchNowPlaying.self) else { return }
        accept(state, force: true)
    }

    func songPage(_ list: WatchListRef, offset: Int) async throws -> WatchPage<WatchSongItem> {
        if let songs = previewSongs?[list] {
            return WatchPaging.page(of: songs, offset: offset, limit: WatchLimits.defaultPageSize) { $0 }
        }
        return try await request(
            .songPage,
            WatchSongPageRequest(list: list, offset: offset, limit: WatchLimits.defaultPageSize),
            as: WatchPage<WatchSongItem>.self
        )
    }

    func playlistPage(offset: Int) async throws -> WatchPage<WatchPlaylistItem> {
        if let playlists = previewPlaylists {
            return WatchPaging.page(of: playlists, offset: offset, limit: WatchLimits.defaultPageSize) { $0 }
        }
        return try await request(
            .playlistPage,
            WatchPageRequest(offset: offset, limit: WatchLimits.defaultPageSize),
            as: WatchPage<WatchPlaylistItem>.self
        )
    }

    func artwork(songID: String, maxPixel: Int) async throws -> WatchArtwork {
        try await request(.artwork, WatchArtworkRequest(songID: songID, maxPixel: maxPixel), as: WatchArtwork.self)
    }

    func manifest(for list: WatchListRef) async throws -> WatchDownloadManifest {
        if let songs = previewSongs?[list] {
            let sized = songs.map { song -> WatchSongItem in
                var copy = song
                copy.bytes = 6_000_000
                return copy
            }
            return WatchDownloadManifest(list: list, title: "Preview", songs: sized, totalSongsInList: sized.count)
        }
        return try await request(.downloadManifest, WatchManifestRequest(list: list), as: WatchDownloadManifest.self)
    }

    func requestTransfers(_ list: WatchListRef, songIDs: [String]) async throws -> WatchTransferAck {
        if previewSongs != nil { return WatchTransferAck(queued: songIDs, alreadyQueued: [], unavailable: []) }
        return try await request(.transferRequest, WatchTransferRequest(list: list, songIDs: songIDs), as: WatchTransferAck.self)
    }

    /// Stop transfers nobody wants any more. Uses a live message when the
    /// phone is reachable, otherwise queues it for later delivery.
    func cancelTransfers(_ songIDs: [String]) {
        guard !songIDs.isEmpty, let session, session.activationState == .activated,
              let payload = try? WatchEnvelope.encode(.cancelTransfers, WatchCancelTransfers(songIDs: songIDs)) else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { _ in }, errorHandler: { _ in
                session.transferUserInfo(payload)
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    // MARK: - State

    private func applyOptimistically(_ command: WatchCommand) {
        guard var state = nowPlaying, state.hasSong else { return }
        let now = Date()
        switch command.action {
        case .togglePlayPause:
            state.elapsed = state.elapsed(at: now)
            state.isPlaying.toggle()
        case .play:
            state.elapsed = state.elapsed(at: now)
            state.isPlaying = true
        case .pause:
            state.elapsed = state.elapsed(at: now)
            state.isPlaying = false
        case .seek:
            state.elapsed = command.seconds ?? state.elapsed
        case .toggleFavorite:
            guard command.songID == nil || command.songID == state.songID else { return }
            state.isFavorited.toggle()
        case .next, .previous, .playSong, .refresh:
            return
        }
        state.capturedAt = now
        nowPlaying = state
    }

    private func accept(_ state: WatchNowPlaying, force: Bool = false) {
        guard force || state.isNewer(than: nowPlaying) else { return }
        nowPlaying = state
    }

    private func refreshSessionState() {
        guard let session else { return }
        isActivated = session.activationState == .activated
        isReachable = session.isReachable
        companionAppInstalled = session.isCompanionAppInstalled
        WatchWidgetBridge.shared.start()
    }

    nonisolated private func receive(_ dictionary: [String: Any]) {
        guard let envelope = try? WatchEnvelope(dictionary) else { return }
        switch envelope.kind {
        case .nowPlaying:
            guard let state = try? envelope.decode(WatchNowPlaying.self) else { return }
            Task { @MainActor in self.accept(state) }
        case .transferFailed:
            guard let failure = try? envelope.decode(WatchTransferFailure.self) else { return }
            Task { @MainActor in OfflineLibrary.shared.markFailed(failure) }
        default:
            break
        }
    }

    // MARK: - Background refresh

    /// Keep a WatchConnectivity background task alive until pending content
    /// (context, files, user info) has been delivered.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        activate()
        completeBackgroundTasksIfIdle()
        // Never keep a task past the system's patience.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.completeBackgroundTasks()
        }
    }

    private func completeBackgroundTasksIfIdle() {
        guard let session, session.activationState == .activated, !session.hasContentPending else { return }
        completeBackgroundTasks()
    }

    private func completeBackgroundTasks() {
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }
    }
}

// MARK: - WCSessionDelegate

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { receive(context) }
        Task { @MainActor in
            self.refreshSessionState()
            self.completeBackgroundTasksIfIdle()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshSessionState()
            if session.isReachable { await self.refresh() }
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshSessionState() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
        Task { @MainActor in self.completeBackgroundTasksIfIdle() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        receive(message)
        replyHandler((try? WatchEnvelope.encode(.nowPlaying, WatchEmpty())) ?? [:])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(userInfo)
        Task { @MainActor in self.completeBackgroundTasksIfIdle() }
    }

    /// The file is deleted when this returns, so it's moved synchronously.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let track = OfflineLibrary.ingest(fileAt: file.fileURL, metadata: file.metadata)
        Task { @MainActor in
            if let track { OfflineLibrary.shared.recordArrival(track) }
            self.completeBackgroundTasksIfIdle()
        }
    }
}

/// Resumes a continuation at most once (reply, error or timeout — whichever
/// comes first).
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
