// MediaIntents is SDK 27-only. Preserve the library-aware App Shortcuts
// on stable EAS SDK 26 builds, without linking a framework they do not ship.
#if canImport(MediaIntents)
import AppIntents
import MediaIntents

@available(iOS 27.0, *)
enum LibraryAudioSelection: Equatable {
    case song(String), playlist(String), resume
}

@available(iOS 27.0, *)
extension SiriLibraryService {
    /// This SDK exposes only unspecified, text and URL criteria, not artist,
    /// genre or mood fields. Match text locally without inventing catalog data.
    func resolveAudioSearch(_ search: AudioSearch) async throws -> LibraryAudioSelection {
        switch search.criteria {
        case .unspecified: return .resume
        case .searchQuery(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SiriLibraryError.unsupportedSearch }
            let songs = try await songs().filter { Self.matches(text, in: $0.title + " " + $0.artist + " " + $0.albumTitle) }
            let lists = try await playlists().filter { Self.matches(text, in: $0.title) }
            let results = songs.map { LibraryAudioSelection.song($0.id) } + lists.map { .playlist($0.id) }
            guard let result = results.first else { throw SiriLibraryError.songNotFound }
            guard results.count == 1 else { throw SiriLibraryError.ambiguousContent }
            return result
        case .url:
            // Do not stream/download or treat arbitrary URLs as local identities.
            throw SiriLibraryError.unsupportedSearch
        @unknown default: throw SiriLibraryError.unsupportedSearch
        }
    }
}

/// Availability keeps the existing Shortcuts actions usable on iOS 18.4.
@available(iOS 27.0, *)
struct PlayLibraryAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Library Audio"
    static let description = IntentDescription("Resolve an iOS 27 audio search against the local iPhone library.")
    @Parameter(title: "Audio Search") var audioEntity: AudioSearch

    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingBridge.shared.start()
        let service = SiriLibraryService.live
        switch try await service.resolveAudioSearch(audioEntity) {
        case .song(let id): try await service.playSong(id: id)
        case .playlist(let id): try await service.playPlaylist(id: id)
        case .resume: try await service.play()
        }
        return .result()
    }
}
#endif
