import Foundation
import Testing
@testable import Owenisas_Music

// Paged, size-bounded library lists for the watch.
struct WatchLibraryPagingTests {

    private let numbers = Array(0..<47)

    @Test("Pages walk the list in order and stop at the end")
    func walksAllPages() {
        var seen: [Int] = []
        var offset: Int? = 0
        var pages = 0
        while let current = offset {
            let page = WatchPaging.page(of: numbers, offset: current, limit: 20) { $0 }
            seen += page.items
            offset = page.nextOffset
            pages += 1
        }
        #expect(seen == numbers)
        #expect(pages == 3)
    }

    @Test("Limits are clamped to 1…maxPageSize")
    func limitClamped() {
        #expect(WatchPaging.page(of: numbers, offset: 0, limit: 500) { $0 }.items.count == WatchLimits.maxPageSize)
        #expect(WatchPaging.page(of: numbers, offset: 0, limit: 0) { $0 }.items.count == 1)
        #expect(WatchPaging.page(of: numbers, offset: 0, limit: -3) { $0 }.items.count == 1)
    }

    @Test("Out-of-range offsets give an empty last page, negative offsets start at 0")
    func offsetsClamped() {
        let past = WatchPaging.page(of: numbers, offset: 999, limit: 10) { $0 }
        #expect(past.items.isEmpty)
        #expect(past.offset == numbers.count)
        #expect(past.nextOffset == nil)

        let negative = WatchPaging.page(of: numbers, offset: -5, limit: 3) { $0 }
        #expect(negative.items == [0, 1, 2])
        #expect(negative.offset == 0)
    }

    @Test("Empty lists report zero total and no next page")
    func emptyList() {
        let page = WatchPaging.page(of: [Int](), offset: 0, limit: 20, title: "Liked Songs") { $0 }
        #expect(page.total == 0)
        #expect(page.items.isEmpty)
        #expect(page.nextOffset == nil)
        #expect(page.title == "Liked Songs")
    }

    @Test("Only the page's elements are mapped")
    func mapsOnlyThePage() {
        var mapped = 0
        _ = WatchPaging.page(of: numbers, offset: 10, limit: 5) { value -> Int in
            mapped += 1
            return value
        }
        #expect(mapped == 5)
    }

    // MARK: Manifests

    private func manifest(songs count: Int, titleLength: Int = 10) -> WatchDownloadManifest {
        let songs = (0..<count).map {
            WatchSongItem(
                id: "song-\($0)", title: String(repeating: "t", count: titleLength), artist: "Artist",
                duration: 180, isFavorited: true, bytes: 5_000_000, hasArtwork: true
            )
        }
        return WatchDownloadManifest(list: .liked, title: "Liked Songs", songs: songs, totalSongsInList: count)
    }

    @Test("Manifests are capped to maxDownloadSongs, keeping the first songs")
    func manifestCountCap() {
        let fitted = WatchPaging.fitted(manifest(songs: 450))
        #expect(fitted.songs.count == WatchLimits.maxDownloadSongs)
        #expect(fitted.songs.first?.id == "song-0")
        #expect(fitted.totalSongsInList == 450)
    }

    @Test("Manifests shrink to the longest prefix that fits the byte budget")
    func manifestByteCap() {
        let big = manifest(songs: 150, titleLength: 80)
        let limit = 8_000
        let fitted = WatchPaging.fitted(big, maxBytes: limit)
        #expect(WatchPaging.encodedSize(fitted) <= limit)
        #expect(fitted.songs.count > 0)
        // One more song would not fit.
        var oneMore = fitted
        oneMore.songs = Array(big.songs.prefix(fitted.songs.count + 1))
        #expect(WatchPaging.encodedSize(oneMore) > limit)
        #expect(fitted.songs == Array(big.songs.prefix(fitted.songs.count)))
    }

    @Test("A small manifest is untouched")
    func smallManifestUntouched() {
        let small = manifest(songs: 12)
        #expect(WatchPaging.fitted(small) == small)
    }

    @Test("A realistic worst-case manifest fits a WatchConnectivity message")
    func worstCaseManifestFits() throws {
        let fitted = WatchPaging.fitted(manifest(songs: 200, titleLength: WatchLimits.maxTextLength))
        let message = try WatchEnvelope.encode(.downloadManifest, fitted)
        let data = try PropertyListSerialization.data(fromPropertyList: message, format: .binary, options: 0)
        #expect(data.count < 65_536)
    }

    // MARK: Phone-side item mapping

    @MainActor
    @Test("Library items trim text and only carry sizes in manifests")
    func itemMapping() {
        let song = SongData(
            id: "folder", title: String(repeating: "x", count: 200), artist: "A",
            audioFilePath: "Songs/folder/missing.m4a", coverImagePath: "Songs/folder/cover.jpg",
            duration: 99, isFavorited: true
        )
        let browse = WatchLibraryProvider.item(for: song, includeSize: false)
        #expect(browse.title.count == WatchLimits.maxTextLength)
        #expect(browse.bytes == nil)
        #expect(browse.hasArtwork)
        #expect(browse.isFavorited)
        // The file doesn't exist, so it can't be sent.
        #expect(WatchLibraryProvider.item(for: song, includeSize: true).bytes == nil)
    }
}
