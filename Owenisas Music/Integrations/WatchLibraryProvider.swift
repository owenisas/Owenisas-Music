import Foundation
import SwiftData
import UIKit

/// Answers the watch's library questions from the phone's SwiftData store.
/// Read-only: it never changes the library.
@MainActor
enum WatchLibraryProvider {
    enum Failure: Error {
        /// The library isn't loaded yet (app launched in the background).
        case notReady
        case notFound
    }

    private static var context: ModelContext? { DataManager.shared.modelContext }

    static var isReady: Bool { context != nil }

    // MARK: Lists

    /// Songs of a list in the order the phone shows them.
    static func songs(in list: WatchListRef) throws -> [SongData] {
        guard isReady else { throw Failure.notReady }
        let dm = DataManager.shared
        switch list {
        case .liked:
            return dm.fetchAllSongs().filter(\.isFavorited)
        case .recentlyAdded:
            return Array(dm.fetchAllSongs().prefix(WatchLimits.maxRecentlyAdded))
        case .playlist(let id):
            guard let playlist = dm.fetchAllPlaylists().first(where: { $0.id == id }) else {
                throw Failure.notFound
            }
            return playlist.orderedSongs
        }
    }

    static func title(of list: WatchListRef) -> String {
        switch list {
        case .liked: return "Liked Songs"
        case .recentlyAdded: return "Recently Added"
        case .playlist(let id):
            return DataManager.shared.fetchAllPlaylists().first { $0.id == id }?.title ?? "Playlist"
        }
    }

    static func songPage(_ request: WatchSongPageRequest) throws -> WatchPage<WatchSongItem> {
        let songs = try songs(in: request.list)
        return WatchPaging.page(
            of: songs, offset: request.offset, limit: request.limit,
            title: WatchLimits.trimmed(title(of: request.list))
        ) { item(for: $0, includeSize: false) }
    }

    static func playlistPage(_ request: WatchPageRequest) throws -> WatchPage<WatchPlaylistItem> {
        guard isReady else { throw Failure.notReady }
        let playlists = DataManager.shared.fetchAllPlaylists()
        return WatchPaging.page(of: playlists, offset: request.offset, limit: request.limit, title: "Playlists") { playlist in
            let ordered = playlist.orderedSongs
            return WatchPlaylistItem(
                id: playlist.id,
                title: WatchLimits.trimmed(playlist.title),
                songCount: ordered.count,
                artworkSongID: ordered.first(where: { $0.coverImagePath?.isEmpty == false })?.id
            )
        }
    }

    /// Songs with file sizes for planning a download. Unplayable files are
    /// listed with `bytes == nil` so the watch can say why they're skipped.
    static func manifest(for list: WatchListRef) throws -> WatchDownloadManifest {
        guard list.isDownloadable else { throw Failure.notFound }
        let songs = try songs(in: list)
        let capped = songs.prefix(WatchLimits.maxDownloadSongs)
        let manifest = WatchDownloadManifest(
            list: list,
            title: WatchLimits.trimmed(title(of: list)),
            songs: capped.map { item(for: $0, includeSize: true) },
            totalSongsInList: songs.count
        )
        return WatchPaging.fitted(manifest)
    }

    static func item(for song: SongData, includeSize: Bool) -> WatchSongItem {
        WatchSongItem(
            id: song.id,
            title: WatchLimits.trimmed(song.title),
            artist: WatchLimits.trimmed(song.artist),
            duration: song.duration,
            isFavorited: song.isFavorited,
            bytes: includeSize ? WatchAudioFile.transferableSize(at: song.audioFileURL) : nil,
            hasArtwork: song.coverImagePath?.isEmpty == false
        )
    }

    static func song(id: String) -> SongData? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<SongData>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    /// Player-ready songs of a list.
    static func playerSongs(in list: WatchListRef) throws -> [Song] {
        DataManager.shared.toSongs(try songs(in: list))
    }
}

/// Audio files the watch can receive.
enum WatchAudioFile {
    /// Size of a file worth sending, or nil when it's missing or a format the
    /// watch can't play (e.g. WebM/Opus saved as .m4a).
    static func transferableSize(at url: URL) -> Int64? {
        guard PlayableLocalAudio.isPlayable(at: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    /// Extension matching the real container (downloads can carry m4a data
    /// under .mp3), so the watch's AVAudioPlayer gets the right hint.
    static func containerExtension(at url: URL) -> String {
        let head: Data = {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 16)) ?? Data()
        }()
        switch PlayableLocalAudio.container(of: head) {
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .flac: return "flac"
        case .aiff: return "aiff"
        case .unplayable: return WatchFileNaming.sanitizedExtension(url.pathExtension)
        }
    }
}

/// Small JPEG thumbnails for the watch.
enum WatchArtworkRenderer {
    static func jpeg(coverPath: String, maxPixel: Int) -> Data? {
        let pixels = CGFloat(WatchArtworkSize.clamped(maxPixel))
        // Reuse the app's downsampled thumbnail cache (pointSize × 3 px).
        guard let source = ImageCache.shared.thumbnail(for: coverPath, pointSize: pixels / 3) else { return nil }
        let size = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, pixels / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}
