import Foundation
import Testing
@testable import Owenisas_Music

// MARK: - Now Playing snapshot
// The record the app writes into the App Group for the widgets: encoding,
// tolerant decoding, progress projection and the "does the widget need a
// reload" rules.

struct NowPlayingSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        isPlaying: Bool = true,
        elapsed: TimeInterval = 30,
        duration: TimeInterval = 120,
        rate: Double = 1,
        at date: Date? = nil
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            songID: "Daft Punk - Voyager",
            title: "Voyager",
            artist: "Daft Punk",
            isPlaying: isPlaying,
            isFavorited: true,
            elapsed: elapsed,
            duration: duration,
            playbackRate: rate,
            updatedAt: date ?? t0,
            artworkFileName: "art-1.jpg"
        )
    }

    private func tempStore() -> NowPlayingStore {
        NowPlayingStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingTests-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: Encoding

    @Test func roundTripsThroughJSON() throws {
        let snapshot = sample()
        let data = try NowPlayingStore.encoder.encode(snapshot)
        let decoded = try NowPlayingStore.decoder.decode(NowPlayingSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.version == NowPlayingSnapshot.currentVersion)
    }

    @Test func notPlayingRoundTrips() throws {
        let snapshot = NowPlayingSnapshot.notPlaying(at: t0)
        let data = try NowPlayingStore.encoder.encode(snapshot)
        let decoded = try NowPlayingStore.decoder.decode(NowPlayingSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(!decoded.hasSong)
        #expect(decoded.artworkFileName == nil)
    }

    @Test func decodesOlderPayloadWithMissingKeys() throws {
        let json = #"{"songID":"a","title":"T","artist":"A","isPlaying":true,"updatedAt":1800000000}"#
        let decoded = try NowPlayingStore.decoder.decode(NowPlayingSnapshot.self, from: Data(json.utf8))
        #expect(decoded.songID == "a")
        #expect(decoded.isPlaying)
        #expect(decoded.isFavorited == false)
        #expect(decoded.elapsed == 0)
        #expect(decoded.duration == 0)
        #expect(decoded.playbackRate == 1)
        #expect(decoded.artworkFileName == nil)
        #expect(decoded.updatedAt == t0)
    }

    @Test func ignoresUnknownKeysFromNewerWriters() throws {
        let json = #"{"version":9,"songID":"a","title":"T","artist":"A","isPlaying":false,"updatedAt":1800000000,"lyricsLine":"la la"}"#
        let decoded = try NowPlayingStore.decoder.decode(NowPlayingSnapshot.self, from: Data(json.utf8))
        #expect(decoded.version == 9)
        #expect(decoded.title == "T")
    }

    // MARK: Store

    @Test func storeSavesAndLoads() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory!) }
        #expect(!store.load().hasSong, "missing file reads as not playing")

        let snapshot = sample()
        #expect(store.save(snapshot))
        #expect(store.load() == snapshot)

        #expect(store.save(.notPlaying(at: t0)))
        #expect(!store.load().hasSong)
    }

    @Test func corruptFileLoadsAsNotPlaying() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory!) }
        try FileManager.default.createDirectory(at: store.directory!, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.snapshotURL!)
        #expect(!store.load().hasSong)
    }

    @Test func storeWithoutAppGroupIsANoOp() {
        let store = NowPlayingStore(directory: nil)
        #expect(!store.save(sample()))
        #expect(!store.load().hasSong)
        #expect(store.artworkURL(named: "art-1.jpg") == nil)
    }

    @Test func artworkFileNamesAreStableAndFileSafe() {
        let a = NowPlayingStore.artworkFileName(forSongID: "AC/DC - Back In Black 🎸")
        #expect(a == NowPlayingStore.artworkFileName(forSongID: "AC/DC - Back In Black 🎸"))
        #expect(a != NowPlayingStore.artworkFileName(forSongID: "AC/DC - Back In Black"))
        #expect(a.hasPrefix("art-") && a.hasSuffix(".jpg"))
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        #expect(a.allSatisfy { allowed.contains($0) })
    }

    // MARK: Progress

    @Test func projectsElapsedWhilePlaying() {
        let snapshot = sample(elapsed: 30, duration: 120)
        #expect(snapshot.elapsed(at: t0) == 30)
        #expect(snapshot.elapsed(at: t0.addingTimeInterval(10)) == 40)
        #expect(snapshot.elapsed(at: t0.addingTimeInterval(500)) == 120, "clamped to the track")
        #expect(abs(snapshot.fractionComplete(at: t0.addingTimeInterval(30)) - 0.5) < 0.0001)
    }

    @Test func projectionFollowsPlaybackSpeed() {
        let snapshot = sample(elapsed: 30, duration: 120, rate: 2)
        #expect(snapshot.elapsed(at: t0.addingTimeInterval(10)) == 50)
        let interval = snapshot.playbackInterval
        #expect(interval?.lowerBound == t0.addingTimeInterval(-15))
        #expect(interval?.upperBound == t0.addingTimeInterval(45))
    }

    @Test func pausedSnapshotDoesNotAdvance() {
        let snapshot = sample(isPlaying: false, elapsed: 30)
        #expect(snapshot.elapsed(at: t0.addingTimeInterval(60)) == 30)
        #expect(snapshot.playbackInterval == nil)
        #expect(snapshot.projectedEndDate == nil)
    }

    @Test func invalidNumbersAreSafe() {
        let snapshot = sample(elapsed: .nan, duration: .infinity, rate: 0)
        #expect(snapshot.effectiveRate == 1)
        #expect(snapshot.clampedElapsed == 0)
        #expect(snapshot.playbackInterval == nil)
        #expect(snapshot.fractionComplete(at: t0) == 0)
    }

    @Test func staleSnapshotPastTheEndResolvesToPaused() {
        let snapshot = sample(elapsed: 100, duration: 120)
        #expect(snapshot.resolved(at: t0.addingTimeInterval(5)) == snapshot)
        let late = snapshot.resolved(at: t0.addingTimeInterval(60))
        #expect(!late.isPlaying)
        #expect(late.elapsed == 120)
        #expect(late.songID == snapshot.songID)
    }

    // MARK: Reload rules

    @Test func firstPublishAlwaysReloads() {
        #expect(sample().needsWidgetReload(comparedTo: nil))
    }

    @Test func ordinaryProgressDoesNotReload() {
        let first = sample(elapsed: 30)
        let tenSecondsLater = sample(elapsed: 40.3, at: t0.addingTimeInterval(10))
        #expect(!tenSecondsLater.needsWidgetReload(comparedTo: first))
    }

    @Test func visibleChangesReload() {
        let base = sample()
        var other = base
        other.isPlaying = false
        #expect(other.needsWidgetReload(comparedTo: base), "play/pause")

        other = base
        other.songID = "next"
        #expect(other.needsWidgetReload(comparedTo: base), "song change")

        other = base
        other.isFavorited = false
        #expect(other.needsWidgetReload(comparedTo: base), "like")

        other = base
        other.artworkFileName = nil
        #expect(other.needsWidgetReload(comparedTo: base), "artwork")

        other = base
        other.playbackRate = 1.5
        #expect(other.needsWidgetReload(comparedTo: base), "speed")

        #expect(NowPlayingSnapshot.notPlaying(at: t0).needsWidgetReload(comparedTo: base), "stopped")
    }

    @Test func seekBeyondToleranceReloads() {
        let first = sample(elapsed: 30)
        let seeked = sample(elapsed: 90, at: t0.addingTimeInterval(5))
        #expect(seeked.needsWidgetReload(comparedTo: first))
    }

    @Test func notPlayingTwiceDoesNotReload() {
        let a = NowPlayingSnapshot.notPlaying(at: t0)
        let b = NowPlayingSnapshot.notPlaying(at: t0.addingTimeInterval(30))
        #expect(!b.needsWidgetReload(comparedTo: a))
    }
}
