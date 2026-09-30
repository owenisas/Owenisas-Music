import XCTest
@testable import Owenisas_Music

@MainActor
final class LibrarySearchPerformanceTests: XCTestCase {
    private func song(_ id: String, title: String, artist: String, album: String = "Album") -> SongData {
        SongData(id: id, title: title, artist: artist, albumTitle: album, audioFilePath: "unused.wav")
    }

    func testSnapshotMatchesExistingSearchAndPreservesSongOrder() {
        let songs = [song("a", title: "Echo", artist: "Zulu"), song("b", title: "Other", artist: "Echo Artist"), song("c", title: "Other", artist: "Alpha", album: "Echo Album")]
        let playlists = [PlaylistData(id: "p", title: "Echo Mix"), PlaylistData(id: "q", title: "Running")]
        let result = LibrarySearchResults(songs: songs, playlists: playlists, text: "echo")
        XCTAssertEqual(result.songs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(result.artists, ["Echo Artist"])
        XCTAssertEqual(result.playlists.map(\.id), ["p"])
    }

    func testEmptyQueryDoesNotReturnEntireLibrary() {
        let result = LibrarySearchResults(songs: [song("a", title: "Echo", artist: "Echo")], playlists: [], text: "")
        XCTAssertTrue(result.songs.isEmpty)
        XCTAssertTrue(result.artists.isEmpty)
    }

    func testNewSnapshotReflectsMetadataChanges() {
        let item = song("a", title: "Echo", artist: "Artist")
        XCTAssertEqual(LibrarySearchResults(songs: [item], playlists: [], text: "echo").songs.count, 1)
        item.title = "Renamed"
        XCTAssertTrue(LibrarySearchResults(songs: [item], playlists: [], text: "echo").songs.isEmpty)
    }

    func testRepeatedFilteringVersusOneSnapshotBenchmark() {
        let songs = (0..<3000).map { song("\($0)", title: "Echo \($0)", artist: "Artist \($0 % 100)") }
        var oldTimes: [Double] = []
        var newTimes: [Double] = []
        for _ in 0..<7 {
            let start = ProcessInfo.processInfo.systemUptime
            // Existing searchResults evaluates filteredSongs for emptiness, the
            // section condition, and ForEach. Preserve those three full scans.
            var oldCount = 0
            for _ in 0..<3 {
                oldCount += songs.filter { $0.title.localizedCaseInsensitiveContains("echo") || $0.artist.localizedCaseInsensitiveContains("echo") || $0.albumTitle.localizedCaseInsensitiveContains("echo") }.count
            }
            let artists = Set(songs.map(\.artist)).filter { $0.localizedCaseInsensitiveContains("echo") }.sorted()
            oldTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let next = ProcessInfo.processInfo.systemUptime
            let result = LibrarySearchResults(songs: songs, playlists: [], text: "echo")
            newTimes.append((ProcessInfo.processInfo.systemUptime - next) * 1000)
            XCTAssertEqual(result.songs.count * 3, oldCount)
            XCTAssertEqual(result.artists, artists)
        }
        oldTimes.sort(); newTimes.sort()
        print("SEARCH_BENCHMARK repeated_median_ms=\(oldTimes[3]) snapshot_median_ms=\(newTimes[3]) songs=3000 runs=7")
    }
}
