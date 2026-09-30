import Foundation
import SwiftData

/// Errors are deliberately distinct so Siri does not report success for a silent player.
enum SiriLibraryError: Error, LocalizedError, Equatable {
    case libraryUnavailable, songNotFound, playlistNotFound, emptyPlaylist
    case audioUnavailable, noCurrentSong, playbackFailed, invalidTimerDuration
    case ambiguousContent, unsupportedSearch

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable: "Your library is not available. Open Owenisas Music and retry."
        case .songNotFound: "That song is no longer in your library."
        case .playlistNotFound: "That playlist is no longer in your library."
        case .emptyPlaylist: "That playlist is empty."
        case .audioUnavailable: "The audio is missing, empty, or unsupported. Import or download it on your iPhone first."
        case .noCurrentSong: "There is no current song. Choose a song or playlist first."
        case .playbackFailed: "Playback could not start. Check your audio output and retry."
        case .invalidTimerDuration: "Choose a sleep timer between 1 and 1440 minutes."
        case .ambiguousContent: "More than one item matches. Choose the song or playlist in Shortcuts."
        case .unsupportedSearch: "This request is not supported. Choose a song or playlist from your library."
        }
    }
}

/// Uses the app's existing persistent context, never a second or temporary library.
/// AudioPlaybackIntent guarantees execution in the iPhone app process, not on Watch.
@MainActor
final class SiriLibraryService {
    static let live = SiriLibraryService(context: { DataManager.shared.modelContext }, player: .shared)
    private let contextProvider: () -> ModelContext?
    private let player: MusicPlayerManager
    private let readinessDelay: Duration

    init(context: @escaping () -> ModelContext?, player: MusicPlayerManager, readinessDelay: Duration = .milliseconds(100)) {
        self.contextProvider = context
        self.player = player
        self.readinessDelay = readinessDelay
    }

    private func readyContext() async throws -> ModelContext {
        for attempt in 0..<20 {
            try Task.checkCancellation()
            if let context = contextProvider() { return context }
            if attempt < 19 { try await Task.sleep(for: readinessDelay) }
        }
        throw SiriLibraryError.libraryUnavailable
    }

    func songs() async throws -> [SongData] {
        let context = try await readyContext()
        return try context.fetch(FetchDescriptor<SongData>()).sorted {
            let a = Self.normalized($0.title + " " + $0.artist), b = Self.normalized($1.title + " " + $1.artist)
            return a == b ? $0.id < $1.id : a < b
        }
    }

    func playlists() async throws -> [PlaylistData] {
        let context = try await readyContext()
        return try context.fetch(FetchDescriptor<PlaylistData>()).sorted {
            let a = Self.normalized($0.title), b = Self.normalized($1.title)
            return a == b ? $0.id < $1.id : a < b
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func matches(_ query: String, in text: String) -> Bool {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace)
        let text = normalized(text)
        return tokens.allSatisfy { text.contains($0) }
    }

    func playSong(id: String) async throws {
        guard let model = try await songs().first(where: { $0.id == id }) else { throw SiriLibraryError.songNotFound }
        guard PlayableLocalAudio.isPlayable(at: model.audioFileURL) else { throw SiriLibraryError.audioUnavailable }
        let song = Song.from(model)
        player.play(song: song, in: [song])
        guard player.isPlaying, player.currentSong?.id == id else { throw SiriLibraryError.playbackFailed }
    }

    /// Unavailable tracks are omitted and their count is returned for an honest dialog.
    @discardableResult
    func playPlaylist(id: String) async throws -> Int {
        guard let playlist = try await playlists().first(where: { $0.id == id }) else { throw SiriLibraryError.playlistNotFound }
        let ordered = playlist.orderedSongs
        guard !ordered.isEmpty else { throw SiriLibraryError.emptyPlaylist }
        let available = ordered.filter { PlayableLocalAudio.isPlayable(at: $0.audioFileURL) }.map(Song.from)
        guard let first = available.first else { throw SiriLibraryError.audioUnavailable }
        player.play(song: first, in: available)
        guard player.isPlaying else { throw SiriLibraryError.playbackFailed }
        return ordered.count - available.count
    }

    func play() async throws {
        _ = try await readyContext()
        guard let current = player.currentSong else { throw SiriLibraryError.noCurrentSong }
        guard PlayableLocalAudio.isPlayable(at: current.audioFileURL) else { throw SiriLibraryError.audioUnavailable }
        if !player.isPlaying { player.togglePlayPause() }
        guard player.isPlaying else { throw SiriLibraryError.playbackFailed }
    }

    func pause() { player.pause() }

    func likeCurrent() async throws {
        let context = try await readyContext()
        guard let current = player.currentSong else { throw SiriLibraryError.noCurrentSong }
        let id = current.id
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == id })
        guard let model = try context.fetch(descriptor).first else { throw SiriLibraryError.songNotFound }
        let wasFavorited = model.isFavorited
        model.isFavorited = true
        do { try context.save() }
        catch { model.isFavorited = wasFavorited; throw error }
        // This method updates player queues only; unlike toggleFavorite(), it does
        // not emit SongFavoriteToggled and cannot undo the persistent like.
        if !current.isFavorited { player.toggleFavorite(for: id) }
        NotificationCenter.default.post(name: .libraryFavoriteChanged, object: self,
                                        userInfo: ["id": id, "isFavorited": true])
    }

    func setSleepTimer(minutes: Int) throws {
        guard (1...1440).contains(minutes) else { throw SiriLibraryError.invalidTimerDuration }
        guard player.currentSong != nil else { throw SiriLibraryError.noCurrentSong }
        player.setSleepTimer(minutes: minutes)
    }

    func cancelSleepTimer() { player.cancelSleepTimer() }
}
