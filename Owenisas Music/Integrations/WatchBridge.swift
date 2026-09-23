import Combine
import Foundation
import WatchConnectivity

/// Phone side of the Apple Watch app.
///
/// - Pushes now-playing state: `updateApplicationContext` (latest state,
///   delivered even when the watch app isn't running) plus `sendMessage`
///   while the watch app is open.
/// - Answers watch requests (commands, library pages, artwork, download
///   manifests) through `sendMessage` replies.
/// - Sends audio to the watch with `transferFile` for offline playback.
///
/// Wire format: `WatchShared/`.
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var session: WCSession?
    private var cancellables = Set<AnyCancellable>()
    /// Re-sync progress while the watch app is open (phone-side seeks and
    /// clock drift aren't published).
    private var refreshTimer: Timer?
    /// Song ids whose transfer the watch cancelled; their failures are expected.
    private var cancelledTransferIDs = Set<String>()

    private static let refreshInterval: TimeInterval = 10

    func start() {
        guard session == nil, WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        observePlayer()
    }

    // MARK: - Now playing

    private func observePlayer() {
        let player = MusicPlayerManager.shared
        let changes: [AnyPublisher<Void, Never>] = [
            player.$currentSong.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            player.$duration.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$playbackRate.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            // Track changes publish several properties in a row; send once.
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.pushNowPlaying() }
            .store(in: &cancellables)
    }

    /// Current player state for the watch. Main thread.
    static func snapshot(of player: MusicPlayerManager = .shared, at date: Date = Date()) -> WatchNowPlaying {
        guard let song = player.currentSong else { return .idle(at: date) }
        return WatchNowPlaying(
            songID: song.id,
            title: WatchLimits.trimmed(song.title),
            artist: WatchLimits.trimmed(song.artist),
            isPlaying: player.isPlaying,
            isFavorited: song.isFavorited,
            duration: player.duration,
            elapsed: player.currentTime,
            rate: Double(player.playbackRate),
            capturedAt: date,
            queueIndex: player.currentIndex,
            queueCount: player.queue.count
        )
    }

    /// Paired watch with the app installed and an activated session.
    private var watchAppAvailable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    private func pushNowPlaying() {
        guard let session, watchAppAvailable,
              let envelope = try? WatchEnvelope.encode(.nowPlaying, Self.snapshot()) else {
            updateRefreshTimer()
            return
        }
        do {
            try session.updateApplicationContext(envelope)
        } catch {
            NSLog("OWENISAS_WATCH: context update failed: %@", "\(error)")
        }
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        let wanted = (session?.isReachable ?? false) && MusicPlayerManager.shared.isPlaying
        if wanted, refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.pushNowPlaying()
            }
        } else if !wanted {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Requests

    /// Handle one watch request; returns the reply envelope. Main actor
    /// because the player and the library live there.
    @MainActor
    private func handle(_ message: [String: Any]) async -> [String: Any] {
        let envelope: WatchEnvelope
        do {
            envelope = try WatchEnvelope(message)
        } catch WatchCodingError.incompatible {
            return WatchEnvelope.errorReply(.incompatibleVersion, "Update Owenisas Music on your iPhone and Apple Watch.")
        } catch WatchCodingError.unknownKind(let kind) {
            return WatchEnvelope.errorReply(.unsupported, "Unsupported request \(kind). Update Owenisas Music on your iPhone.")
        } catch {
            return WatchEnvelope.errorReply(.badRequest, "Unreadable request.")
        }

        do {
            switch envelope.kind {
            case .command:
                let command = try envelope.decode(WatchCommand.self)
                try perform(command)
                return try WatchEnvelope.encode(.command, Self.snapshot())

            case .songPage:
                let request = try envelope.decode(WatchSongPageRequest.self)
                return try WatchEnvelope.encode(.songPage, WatchLibraryProvider.songPage(request))

            case .playlistPage:
                let request = try envelope.decode(WatchPageRequest.self)
                return try WatchEnvelope.encode(.playlistPage, WatchLibraryProvider.playlistPage(request))

            case .artwork:
                let request = try envelope.decode(WatchArtworkRequest.self)
                return try await artwork(for: request)

            case .downloadManifest:
                let request = try envelope.decode(WatchManifestRequest.self)
                return try WatchEnvelope.encode(.downloadManifest, WatchLibraryProvider.manifest(for: request.list))

            case .transferRequest:
                let request = try envelope.decode(WatchTransferRequest.self)
                return try WatchEnvelope.encode(.transferRequest, startTransfers(request))

            case .cancelTransfers:
                cancelTransfers(try envelope.decode(WatchCancelTransfers.self))
                return try WatchEnvelope.encode(.cancelTransfers, WatchEmpty())

            case .nowPlaying, .file, .transferFailed, .error:
                return WatchEnvelope.errorReply(.unsupported, "Not a watch request.")
            }
        } catch WatchLibraryProvider.Failure.notReady {
            return WatchEnvelope.errorReply(.phoneNotReady, "Open Owenisas Music on your iPhone.")
        } catch WatchLibraryProvider.Failure.notFound {
            return WatchEnvelope.errorReply(.notFound, "That list is no longer on your iPhone.")
        } catch let error as WatchCodingError {
            return WatchEnvelope.errorReply(.badRequest, "Bad request: \(error)")
        } catch {
            return WatchEnvelope.errorReply(.internalError, error.localizedDescription)
        }
    }

    @MainActor
    private func perform(_ command: WatchCommand) throws {
        let player = MusicPlayerManager.shared
        switch command.action {
        case .togglePlayPause:
            player.togglePlayPause()
        case .play:
            if !player.isPlaying { player.togglePlayPause() }
        case .pause:
            if player.isPlaying { player.pause() }
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .seek:
            if let seconds = command.seconds { player.seek(to: seconds) }
        case .toggleFavorite:
            if let id = command.songID, id != player.currentSong?.id {
                player.toggleFavorite(for: id)
            } else {
                player.toggleFavorite()
            }
        case .playSong:
            guard let id = command.songID, let list = command.list else {
                throw WatchCodingError.badPayload("playSong needs songID and list")
            }
            let songs = try WatchLibraryProvider.playerSongs(in: list)
            guard let song = songs.first(where: { $0.id == id }) else {
                throw WatchLibraryProvider.Failure.notFound
            }
            player.play(song: song, in: songs)
        case .refresh:
            break
        }
    }

    @MainActor
    private func artwork(for request: WatchArtworkRequest) async throws -> [String: Any] {
        guard WatchLibraryProvider.isReady else { throw WatchLibraryProvider.Failure.notReady }
        let pixels = WatchArtworkSize.clamped(request.maxPixel)
        let coverPath = WatchLibraryProvider.song(id: request.songID)?.coverImageURL?.path
        // Decode/encode off the main thread.
        let jpeg: Data? = await Task.detached(priority: .utility) {
            coverPath.flatMap { WatchArtworkRenderer.jpeg(coverPath: $0, maxPixel: pixels) }
        }.value
        return try WatchEnvelope.encode(.artwork, WatchArtwork(songID: request.songID, maxPixel: pixels, jpeg: jpeg))
    }

    // MARK: - File transfers

    private func outstandingTransferIDs() -> Set<String> {
        guard let session else { return [] }
        return Set(session.outstandingFileTransfers.compactMap { Self.songID(of: $0) })
    }

    private static func songID(of transfer: WCSessionFileTransfer) -> String? {
        guard let metadata = transfer.file.metadata,
              let envelope = try? WatchEnvelope(metadata), envelope.kind == .file,
              let meta = try? envelope.decode(WatchFileMetadata.self) else { return nil }
        return meta.songID
    }

    @MainActor
    private func startTransfers(_ request: WatchTransferRequest) throws -> WatchTransferAck {
        guard let session, watchAppAvailable else {
            throw WatchLibraryProvider.Failure.notReady
        }
        let songs = try WatchLibraryProvider.songs(in: request.list)
        let requested = Set(request.songIDs)
        var files: [String: (url: URL, meta: WatchFileMetadata)] = [:]
        for song in songs where requested.contains(song.id) && files[song.id] == nil {
            let url = song.audioFileURL
            guard let bytes = WatchAudioFile.transferableSize(at: url) else { continue }
            files[song.id] = (url, WatchFileMetadata(
                songID: song.id,
                title: WatchLimits.trimmed(song.title),
                artist: WatchLimits.trimmed(song.artist),
                duration: song.duration,
                bytes: bytes,
                fileExtension: WatchAudioFile.containerExtension(at: url),
                list: request.list
            ))
        }
        let ack = WatchTransferPlanner.queue(
            requested: request.songIDs,
            available: Set(files.keys),
            outstanding: outstandingTransferIDs()
        )
        for id in ack.queued {
            guard let file = files[id], let metadata = try? WatchEnvelope.encode(.file, file.meta) else { continue }
            cancelledTransferIDs.remove(id)
            session.transferFile(file.url, metadata: metadata)
        }
        NSLog("OWENISAS_WATCH: queued %d transfers (%d already queued, %d unavailable)",
              ack.queued.count, ack.alreadyQueued.count, ack.unavailable.count)
        return ack
    }

    @MainActor
    private func cancelTransfers(_ request: WatchCancelTransfers) {
        guard let session else { return }
        let ids = Set(request.songIDs)
        for transfer in session.outstandingFileTransfers {
            guard let id = Self.songID(of: transfer), ids.contains(id) else { continue }
            cancelledTransferIDs.insert(id)
            transfer.cancel()
        }
    }

    @MainActor
    private func reportTransferFailure(songID: String, error: Error) {
        if cancelledTransferIDs.remove(songID) != nil { return }
        guard let session, watchAppAvailable,
              let userInfo = try? WatchEnvelope.encode(
                .transferFailed,
                WatchTransferFailure(songID: songID, reason: error.localizedDescription)
              ) else { return }
        session.transferUserInfo(userInfo)
    }
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            NSLog("OWENISAS_WATCH: activation failed: %@", "\(error)")
        }
        DispatchQueue.main.async { self.pushNowPlaying() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches: reactivate for the new one.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.pushNowPlaying() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.pushNowPlaying() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            replyHandler(await self.handle(message))
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            _ = await self.handle(message)
        }
    }

    /// Cancellations queued while the phone wasn't reachable.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            _ = await self.handle(userInfo)
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let error, let songID = Self.songID(of: fileTransfer) else { return }
        NSLog("OWENISAS_WATCH: transfer failed for %@: %@", songID, "\(error)")
        Task { @MainActor in
            self.reportTransferFailure(songID: songID, error: error)
        }
    }
}
