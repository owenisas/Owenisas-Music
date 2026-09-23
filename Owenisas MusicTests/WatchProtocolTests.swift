import Foundation
import Testing
@testable import Owenisas_Music

// Watch ↔ phone wire protocol (WatchShared/): envelopes, payload round trips,
// versioning. Round trips go through a binary property list, the format
// WatchConnectivity requires for dictionaries.
struct WatchProtocolTests {

    /// Encode → property list → decode, like a WatchConnectivity hop.
    private func hop(_ dictionary: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func roundTrip<T: Codable & Equatable>(_ kind: WatchMessageKind, _ value: T) throws -> T {
        let received = try hop(try WatchEnvelope.encode(kind, value))
        let envelope = try WatchEnvelope(received)
        #expect(envelope.kind == kind)
        #expect(envelope.version == WatchProtocol.version)
        return try envelope.decode(T.self)
    }

    private let song = WatchSongItem(
        id: "Artist - Song (Live) [abc]", title: "Song", artist: "Artist",
        duration: 201.5, isFavorited: true, bytes: 4_200_000, hasArtwork: true
    )

    // MARK: Payload round trips

    @Test("Now playing survives the trip, including dates")
    func nowPlayingRoundTrip() throws {
        let state = WatchNowPlaying(
            songID: "id-1", title: "Title", artist: "Artist", isPlaying: true, isFavorited: false,
            duration: 240, elapsed: 12.5, rate: 1.25, capturedAt: Date(timeIntervalSince1970: 1_790_000_000.5),
            queueIndex: 3, queueCount: 9
        )
        #expect(try roundTrip(.nowPlaying, state) == state)
        #expect(try roundTrip(.nowPlaying, WatchNowPlaying.idle(at: Date(timeIntervalSince1970: 5))).hasSong == false)
    }

    @Test("Commands round-trip with their arguments")
    func commandRoundTrip() throws {
        let commands: [WatchCommand] = [
            WatchCommand(action: .togglePlayPause),
            .seek(to: 93.25),
            .toggleFavorite(songID: "x"),
            .playSong("song/with:odd chars", in: .playlist("P-1")),
            WatchCommand(action: .refresh),
        ]
        for command in commands {
            #expect(try roundTrip(.command, command) == command)
        }
    }

    @Test("Library, artwork and transfer payloads round-trip")
    func libraryPayloadsRoundTrip() throws {
        let page = WatchPage(offset: 20, total: 41, items: [song], title: "Liked Songs")
        #expect(try roundTrip(.songPage, page) == page)

        let playlists = WatchPage(offset: 0, total: 1, items: [WatchPlaylistItem(id: "p", title: "Mix", songCount: 3, artworkSongID: nil)], title: nil)
        #expect(try roundTrip(.playlistPage, playlists) == playlists)

        let art = WatchArtwork(songID: "s", maxPixel: 80, jpeg: Data([0xFF, 0xD8, 0xFF]))
        #expect(try roundTrip(.artwork, art) == art)

        let manifest = WatchDownloadManifest(list: .liked, title: "Liked Songs", songs: [song], totalSongsInList: 300)
        #expect(try roundTrip(.downloadManifest, manifest) == manifest)

        let ack = WatchTransferAck(queued: ["a"], alreadyQueued: ["b"], unavailable: ["c"])
        #expect(try roundTrip(.transferRequest, ack) == ack)

        let meta = WatchFileMetadata(songID: "s", title: "T", artist: "A", duration: 3, bytes: 10, fileExtension: "m4a", list: .playlist("p"))
        #expect(try roundTrip(.file, meta) == meta)

        let failure = WatchTransferFailure(songID: "s", reason: "Timed out")
        #expect(try roundTrip(.transferFailed, failure) == failure)
    }

    @Test("List references encode as stable strings")
    func listRefCoding() throws {
        let refs: [WatchListRef] = [.liked, .recentlyAdded, .playlist("ABC-123"), .playlist("has:colon")]
        for ref in refs {
            #expect(WatchListRef(rawValue: ref.rawValue) == ref)
            let data = try JSONEncoder().encode(ref)
            #expect(try JSONDecoder().decode(WatchListRef.self, from: data) == ref)
        }
        #expect(String(decoding: try JSONEncoder().encode(WatchListRef.liked), as: UTF8.self) == "\"liked\"")
        #expect(WatchListRef(rawValue: "playlist:") == nil)
        #expect(WatchListRef(rawValue: "albums") == nil)
        #expect(WatchListRef.recentlyAdded.isDownloadable == false)
        #expect(WatchListRef.liked.isDownloadable)
    }

    // MARK: Envelope validation and versioning

    @Test("Same version and a newer peer that still supports us are compatible")
    func compatibility() {
        #expect(WatchProtocol.isCompatible(peerVersion: 1, peerMinimum: 1, ourVersion: 1, ourMinimum: 1))
        // Peer v3 still understands v1 → fine.
        #expect(WatchProtocol.isCompatible(peerVersion: 3, peerMinimum: 1, ourVersion: 1, ourMinimum: 1))
        // Peer v3 dropped v1 → incompatible.
        #expect(!WatchProtocol.isCompatible(peerVersion: 3, peerMinimum: 2, ourVersion: 1, ourMinimum: 1))
        // Old peer v1 while we require ≥ 2 → incompatible.
        #expect(!WatchProtocol.isCompatible(peerVersion: 1, peerMinimum: 1, ourVersion: 2, ourMinimum: 2))
    }

    @Test("An incompatible envelope is rejected with both versions")
    func incompatibleEnvelopeRejected() throws {
        let message = try WatchEnvelope.encode(.command, WatchCommand(action: .next), version: 9, minimumVersion: 5)
        #expect(throws: WatchCodingError.incompatible(peerVersion: 9, peerMinimum: 5)) {
            try WatchEnvelope(message)
        }
    }

    @Test("A newer compatible peer's extra fields are ignored")
    func forwardCompatibleFields() throws {
        let json = #"{"action":"seek","seconds":12,"futureField":{"nested":true}}"#
        let message: [String: Any] = [
            WatchMessageKey.version: 2, WatchMessageKey.minimumVersion: 1,
            WatchMessageKey.kind: "cmd", WatchMessageKey.body: Data(json.utf8),
        ]
        let envelope = try WatchEnvelope(try hop(message))
        #expect(envelope.version == 2)
        #expect(try envelope.decode(WatchCommand.self) == .seek(to: 12))
    }

    @Test("Unknown kinds, missing keys and bad payloads are distinct errors")
    func malformedMessages() throws {
        #expect(throws: WatchCodingError.notAnEnvelope) { try WatchEnvelope(["k": "cmd"]) }
        let unknown: [String: Any] = ["v": 1, "mv": 1, "k": "teleport", "b": Data("{}".utf8)]
        #expect(throws: WatchCodingError.unknownKind("teleport")) { try WatchEnvelope(unknown) }

        let bad = try WatchEnvelope(["v": 1, "mv": 1, "k": "cmd", "b": Data(#"{"action":"explode"}"#.utf8)])
        #expect(throws: WatchCodingError.self) { try bad.decode(WatchCommand.self) }
    }

    @Test("A missing minimum version defaults to the sender's version")
    func missingMinimumVersion() throws {
        let envelope = try WatchEnvelope(["v": 1, "k": "np", "b": try WatchCoding.encoder().encode(WatchNowPlaying.idle())])
        #expect(envelope.minimumVersion == 1)
    }

    @Test("Replies: success decodes, error replies surface the remote failure")
    func replies() throws {
        let ok = try hop(try WatchEnvelope.encode(.command, WatchNowPlaying.idle(at: Date(timeIntervalSince1970: 0))))
        #expect(try WatchEnvelope.decodeReply(ok, expecting: .command, as: WatchNowPlaying.self).hasSong == false)

        let failure = try hop(WatchEnvelope.errorReply(.phoneNotReady, "Open the app"))
        #expect(throws: WatchCodingError.remote(WatchErrorReply(code: .phoneNotReady, message: "Open the app"))) {
            try WatchEnvelope.decodeReply(failure, expecting: .command, as: WatchNowPlaying.self)
        }

        let wrongKind = try WatchEnvelope.encode(.artwork, WatchArtwork(songID: "s", maxPixel: 80, jpeg: nil))
        #expect(throws: WatchCodingError.unexpectedKind(expected: .command, got: .artwork)) {
            try WatchEnvelope.decodeReply(wrongKind, expecting: .command, as: WatchNowPlaying.self)
        }
    }

    @Test("Unknown error codes from a newer peer fall back to internalError")
    func unknownErrorCode() throws {
        let data = Data(#"{"code":"solarFlare","message":"?"}"#.utf8)
        let reply = try WatchCoding.decoder().decode(WatchErrorReply.self, from: data)
        #expect(reply.code == .internalError)
        #expect(reply.message == "?")
    }

    // MARK: Now playing extrapolation

    @Test("Progress extrapolates while playing, at the playback rate, clamped")
    func elapsedExtrapolation() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var state = WatchNowPlaying(
            songID: "s", title: "", artist: "", isPlaying: true, isFavorited: false,
            duration: 100, elapsed: 10, rate: 1.5, capturedAt: t0, queueIndex: 0, queueCount: 1
        )
        #expect(state.elapsed(at: t0.addingTimeInterval(10)) == 25)
        #expect(state.elapsed(at: t0.addingTimeInterval(1_000)) == 100)
        // Watch clock slightly behind the phone: no rewinding.
        #expect(state.elapsed(at: t0.addingTimeInterval(-5)) == 10)
        #expect(state.progress(at: t0) == 0.1)

        state.isPlaying = false
        #expect(state.elapsed(at: t0.addingTimeInterval(60)) == 10)
    }

    @Test("Older updates don't replace newer ones")
    func newestWins() {
        let older = WatchNowPlaying.idle(at: Date(timeIntervalSince1970: 10))
        let newer = WatchNowPlaying.idle(at: Date(timeIntervalSince1970: 20))
        #expect(newer.isNewer(than: older))
        #expect(!older.isNewer(than: newer))
        #expect(older.isNewer(than: nil))
    }

    @Test("Every message stays well under the WatchConnectivity size limit")
    func payloadSizes() throws {
        let longText = String(repeating: "界", count: 500)
        // Song ids are folder names: at most 255 bytes on APFS.
        let longestID = String(repeating: "界", count: 85)
        let item = WatchSongItem(
            id: longestID, title: WatchLimits.trimmed(longText), artist: WatchLimits.trimmed(longText),
            duration: 1, isFavorited: false, bytes: 1, hasArtwork: true
        )
        let page = WatchPage(offset: 0, total: 1_000, items: Array(repeating: item, count: WatchLimits.maxPageSize), title: nil)
        let data = try PropertyListSerialization.data(fromPropertyList: try WatchEnvelope.encode(.songPage, page), format: .binary, options: 0)
        #expect(data.count < 65_536)
        #expect(WatchLimits.trimmed(longText).count == WatchLimits.maxTextLength)
        #expect(WatchLimits.trimmed("short") == "short")
    }
}
