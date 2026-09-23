import Foundation
import Testing
@testable import Owenisas_Music

// Watch storage limit math and on-watch file naming.
struct WatchStorageTests {

    private let MB = WatchStorage.megabyte
    private let GB = WatchStorage.gigabyte

    @Test("Budget is what's left under the limit")
    func budgetUnderCap() {
        #expect(WatchStorage.budget(capBytes: 2 * GB, committedBytes: 500 * MB, freeBytes: 20 * GB) == 1_500 * MB)
    }

    @Test("Budget never eats into the free-space reserve")
    func budgetUnderFreeSpace() {
        // 800 MB free − 500 MB reserve = 300 MB, even though the limit allows more.
        #expect(WatchStorage.budget(capBytes: 8 * GB, committedBytes: 0, freeBytes: 800 * MB) == 300 * MB)
        #expect(WatchStorage.budget(capBytes: 8 * GB, committedBytes: 0, freeBytes: 100 * MB) == 0)
    }

    @Test("Budget is zero at or over the limit, and ignores unknown free space")
    func budgetEdges() {
        #expect(WatchStorage.budget(capBytes: 1 * GB, committedBytes: 1 * GB, freeBytes: nil) == 0)
        #expect(WatchStorage.budget(capBytes: 1 * GB, committedBytes: 3 * GB, freeBytes: nil) == 0)
        #expect(WatchStorage.budget(capBytes: 1 * GB, committedBytes: 0, freeBytes: nil) == 1 * GB)
    }

    @Test("Level: ok, nearly full at 90%, full when nothing fits")
    func levels() {
        #expect(WatchStorage.level(committedBytes: 1 * GB, capBytes: 2 * GB, freeBytes: 10 * GB) == .ok)
        #expect(WatchStorage.level(committedBytes: 1_850 * MB, capBytes: 2 * GB, freeBytes: 10 * GB) == .nearlyFull)
        #expect(WatchStorage.level(committedBytes: 2 * GB, capBytes: 2 * GB, freeBytes: 10 * GB) == .full)
        // Watch itself is out of space even though the limit isn't reached.
        #expect(WatchStorage.level(committedBytes: 0, capBytes: 2 * GB, freeBytes: 400 * MB) == .full)
    }

    @Test("Fraction is clamped to 0…1")
    func fraction() {
        #expect(WatchStorage.fraction(used: 1 * GB, cap: 2 * GB) == 0.5)
        #expect(WatchStorage.fraction(used: 5 * GB, cap: 2 * GB) == 1)
        #expect(WatchStorage.fraction(used: 0, cap: 0) == 1)
    }

    @Test("Stored limits snap to an offered option")
    func normalizedCap() {
        #expect(WatchStorage.normalizedCap(2 * GB) == 2 * GB)
        #expect(WatchStorage.normalizedCap(3_100 * MB) == 4 * GB)
        #expect(WatchStorage.normalizedCap(100 * GB) == 8 * GB)
        #expect(WatchStorage.normalizedCap(0) == WatchStorage.defaultCap)
        #expect(WatchStorage.capOptions.contains(WatchStorage.defaultCap))
    }

    @Test("Sizes format as file sizes")
    func formatting() {
        #expect(!WatchStorage.format(1_500 * MB).isEmpty)
        #expect(WatchStorage.format(-5) == WatchStorage.format(0))
    }

    // MARK: File naming

    @Test("FNV-1a hash matches reference values and is stable")
    func hashReference() {
        #expect(WatchFileNaming.hash("") == "cbf29ce484222325")
        #expect(WatchFileNaming.hash("a") == "af63dc4c8601ec8c")
        #expect(WatchFileNaming.hash("foobar") == "85944171f73967e8")
        #expect(WatchFileNaming.hash("same") == WatchFileNaming.hash("same"))
    }

    @Test("File names are safe whatever the song id is")
    func fileNamesAreSafe() {
        let ids = ["../../etc/passwd", "Artist - Song (Live) [x]", "界 / ✦", String(repeating: "z", count: 400)]
        for id in ids {
            let name = WatchFileNaming.fileName(songID: id, fileExtension: "mp3")
            #expect(!name.contains("/"))
            #expect(name.hasSuffix(".mp3"))
            #expect(name.count == "t-".count + 16 + ".mp3".count)
        }
        #expect(WatchFileNaming.fileName(songID: "a", fileExtension: "m4a") != WatchFileNaming.fileName(songID: "b", fileExtension: "m4a"))
    }

    @Test("Extensions are sanitized to playable types")
    func extensions() {
        #expect(WatchFileNaming.sanitizedExtension("MP3") == "mp3")
        #expect(WatchFileNaming.sanitizedExtension("flac") == "flac")
        #expect(WatchFileNaming.sanitizedExtension("../sh") == "m4a")
        #expect(WatchFileNaming.sanitizedExtension("webm") == "m4a")
        #expect(WatchFileNaming.sanitizedExtension("") == "m4a")
    }
}
