import Foundation
import Testing
import SwiftData
import UIKit
@testable import Owenisas_Music

// meta.json sidecar: parsing, and DataManager's folder sync using it.

struct SongFolderMetadataParseTests {
    @Test("Valid meta.json parses; unknown keys are ignored")
    func parsesValid() throws {
        let json = #"{"title":"Me at the zoo","artist":"jawed","videoId":"jNQXAC9IVRw","duration":19,"source":"youtube","extra":1}"#
        let meta = try #require(SongFolderMetadata.parse(Data(json.utf8)))
        #expect(meta == SongFolderMetadata(title: "Me at the zoo", artist: "jawed", videoId: "jNQXAC9IVRw", duration: 19, source: "youtube"))
    }

    @Test("Missing or blank title, or garbage, is nil")
    func rejectsBad() {
        #expect(SongFolderMetadata.parse(Data(#"{"artist":"x"}"#.utf8)) == nil)
        #expect(SongFolderMetadata.parse(Data(#"{"title":"   "}"#.utf8)) == nil)
        #expect(SongFolderMetadata.parse(Data("not json".utf8)) == nil)
    }

    @Test("Loose values are tolerated")
    func tolerant() throws {
        let meta = try #require(SongFolderMetadata.parse(Data(#"{"title":" Song ","artist":"","duration":"213.5"}"#.utf8)))
        #expect(meta.title == "Song")
        #expect(meta.artist == nil)
        #expect(meta.duration == 213.5)
        let negative = try #require(SongFolderMetadata.parse(Data(#"{"title":"S","duration":-3}"#.utf8)))
        #expect(negative.duration == nil)
    }

    @Test("Write then read round-trips")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = SongFolderMetadata(title: "Título", artist: "Artista", album: "Álbum", videoId: "abcdefghijk", duration: 200, source: "youtube")
        try meta.write(to: dir)
        #expect(SongFolderMetadata.read(from: dir) == meta)
    }
}

@MainActor
struct SongFolderSyncTests {
    private var songsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Songs")
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: SongData.self, AlbumData.self, PlaylistData.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    @discardableResult
    private func makeFolder(_ name: String, meta: SongFolderMetadata? = nil, extraFiles: [String] = []) throws -> URL {
        let folder = songsFolder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(repeating: 7, count: 40_000))
            .write(to: folder.appendingPathComponent("\(name).m4a"))
        if let meta { try meta.write(to: folder) }
        for file in extraFiles {
            try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nx\n".utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    private func uniqueVideoLikeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
    }

    @Test("A video-ID folder with meta.json is indexed with its real title and artist")
    func indexesFromMeta() throws {
        let id = uniqueVideoLikeID()
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(id)) }
        try makeFolder(id, meta: SongFolderMetadata(title: "Me at the zoo", artist: "jawed", videoId: id, duration: 19, source: "youtube"))
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncSingleSong(folderName: id)

        let song = try #require(dm.fetchAllSongs().first { $0.id == id })
        #expect(song.title == "Me at the zoo")
        #expect(song.artist == "jawed")
        #expect(song.duration == 19)
    }

    @Test("Full sync also reads meta.json (store-loss recovery)")
    func fullSyncReadsMeta() throws {
        let id = uniqueVideoLikeID()
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(id)) }
        try makeFolder(id, meta: SongFolderMetadata(title: "Recovered", artist: "Somebody"))
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncFromFileSystem()

        let song = try #require(dm.fetchAllSongs().first { $0.id == id })
        #expect(song.title == "Recovered")
        #expect(song.artist == "Somebody")
    }

    @Test("A placeholder row (title = folder name) is repaired from meta.json")
    func repairsPlaceholder() throws {
        let id = uniqueVideoLikeID()
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(id)) }
        try makeFolder(id)
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)
        dm.syncSingleSong(folderName: id)
        #expect(dm.fetchAllSongs().first { $0.id == id }?.title == id)

        try SongFolderMetadata(title: "Real Title", artist: "Real Artist", duration: 120).write(to: songsFolder.appendingPathComponent(id))
        dm.syncSingleSong(folderName: id)

        let song = try #require(dm.fetchAllSongs().first { $0.id == id })
        #expect(song.title == "Real Title")
        #expect(song.artist == "Real Artist")
        #expect(song.duration == 120)
    }

    @Test("User-visible metadata is not overwritten when the row isn't a placeholder")
    func keepsRealRows() throws {
        let id = uniqueVideoLikeID()
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(id)) }
        try makeFolder(id, meta: SongFolderMetadata(title: "From Meta", artist: "Meta Artist"))
        let ctx = try makeContext()
        ctx.insert(SongData(id: id, title: "Edited", artist: "Edited Artist", audioFilePath: "Songs/\(id)/\(id).m4a"))
        try ctx.save()
        let dm = DataManager()
        dm.configure(with: ctx)

        dm.syncSingleSong(folderName: id)

        let song = try #require(dm.fetchAllSongs().first { $0.id == id })
        #expect(song.title == "Edited")
        #expect(song.artist == "Edited Artist")
    }

    @Test("Without meta.json the 'Artist - Title' folder name is still parsed")
    func backwardCompatible() throws {
        let name = "__MetaTestArtist - Title \(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(name)) }
        try makeFolder(name)
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncSingleSong(folderName: name)

        let song = try #require(dm.fetchAllSongs().first { $0.id == name })
        #expect(song.artist == "__MetaTestArtist")
        #expect(song.title.hasPrefix("Title "))
    }

    @Test("Synced lyrics are the default subtitle")
    func prefersLyricsFile() throws {
        let id = uniqueVideoLikeID()
        defer { try? FileManager.default.removeItem(at: songsFolder.appendingPathComponent(id)) }
        try makeFolder(id, extraFiles: ["\(id).en.vtt", "\(id).lyrics.vtt", "\(id).ja.vtt"])
        let dm = DataManager()
        dm.configure(with: try makeContext())

        dm.syncSingleSong(folderName: id)

        let song = try #require(dm.fetchAllSongs().first { $0.id == id })
        #expect(song.subtitleFilePath == "Songs/\(id)/\(id).lyrics.vtt")
    }

    @Test("appendSongsInOrder keeps the given order")
    func playlistOrder() throws {
        let ctx = try makeContext()
        let dm = DataManager()
        dm.configure(with: ctx)
        let songs = (0..<5).map { SongData(id: "order-\($0)", title: "S\($0)", audioFilePath: "Songs/x/\($0).m4a") }
        songs.forEach { ctx.insert($0) }
        try ctx.save()
        let playlist = try #require(dm.createPlaylist(title: "Ordered"))

        dm.appendSongsInOrder([songs[3], songs[0], songs[4]], to: playlist)
        dm.appendSongsInOrder([songs[0], songs[1]], to: playlist)

        #expect(playlist.orderedSongs.map(\.id) == ["order-3", "order-0", "order-4", "order-1"])
    }
}

#if !APP_STORE
@MainActor
struct SongFileSaverTests {
    private func tempFile(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saver-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func info(_ id: String) -> VideoInfo {
        VideoInfo(id: id, title: "Saver Title", artist: "Saver Artist", album: nil, duration: 42,
                  coverUrl: "", audioUrl: "", audioMimeType: "audio/mp4", captionTracks: [], language: nil)
    }

    @Test("Saves audio, meta.json and lyrics; a bad new cover keeps the old one; temps are consumed")
    func saveAndCoverSafety() throws {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
        let folder = SongFileSaver.songsDirectory.appendingPathComponent(id)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioBytes = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(repeating: 3, count: 30_000)

        let firstAudio = try tempFile(audioBytes, ext: "m4a")
        let goodCover = try tempFile(jpeg(), ext: "jpg")
        let saved = try SongFileSaver.save(folderID: id, meta: info(id), cover: goodCover, audio: firstAudio,
                                           subtitles: [("lyrics", "WEBVTT\n\n00:00.000 --> 00:01.000\nhi\n")], log: { _ in })
        #expect(saved.folderID == id)
        let coverURL = folder.appendingPathComponent("\(id).jpg")
        let firstCover = try Data(contentsOf: coverURL)
        #expect(UIImage(data: firstCover) != nil)
        #expect(SongFolderMetadata.read(from: folder)?.videoId == id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).lyrics.vtt").path))
        #expect(!FileManager.default.fileExists(atPath: firstAudio.path))
        #expect(!FileManager.default.fileExists(atPath: goodCover.path))

        // Re-download with a cover that doesn't decode: the old cover stays,
        // the audio is replaced, the bad temp cover is removed.
        let secondAudio = try tempFile(audioBytes + Data([9, 9, 9]), ext: "m4a")
        let badCover = try tempFile(Data(repeating: 0, count: 6_000), ext: "jpg")
        _ = try SongFileSaver.save(folderID: id, meta: info(id), cover: badCover, audio: secondAudio, subtitles: [], log: { _ in })
        #expect(try Data(contentsOf: coverURL) == firstCover)
        #expect(!FileManager.default.fileExists(atPath: badCover.path))
        let savedAudio = try Data(contentsOf: folder.appendingPathComponent("\(id).m4a"))
        #expect(savedAudio.count == audioBytes.count + 3)
    }
}
#endif
