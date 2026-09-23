#if !APP_STORE
import Foundation
import Testing
@testable import Owenisas_Music

// Pure downloader logic: link classification, progress math, Range handling,
// format/caption picking, playlist page parsing, resolve error summaries.

struct YouTubeLinkClassifierTests {
    private let id = "jNQXAC9IVRw"

    @Test("Plain video links")
    func videoLinks() {
        for link in [
            "https://www.youtube.com/watch?v=\(id)",
            "https://youtu.be/\(id)?si=abcdef",
            "https://www.youtube.com/shorts/\(id)",
            "https://m.youtube.com/watch?v=\(id)&feature=share",
            "https://music.youtube.com/watch?v=\(id)",
            "youtube.com/watch?v=\(id)",
            "Check this out https://youtu.be/\(id) !",
            "https://www.youtube.com/embed/\(id)",
        ] {
            #expect(YouTubeLinkClassifier.classify(link) == .video(id: id), "\(link)")
        }
    }

    @Test("Video inside a normal playlist asks; RD mixes don't")
    func videoInPlaylist() {
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=\(id)&list=PLabc123_-x")
                == .videoInPlaylist(videoId: id, playlistId: "PLabc123_-x", isMix: false))
        #expect(YouTubeLinkClassifier.classify("https://youtu.be/\(id)?list=PLabc")
                == .videoInPlaylist(videoId: id, playlistId: "PLabc", isMix: false))
        #expect(YouTubeLinkClassifier.classify("https://music.youtube.com/watch?v=\(id)&list=OLAK5uy_abc")
                == .videoInPlaylist(videoId: id, playlistId: "OLAK5uy_abc", isMix: false))
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=\(id)&list=RD\(id)&start_radio=1")
                == .videoInPlaylist(videoId: id, playlistId: "RD\(id)", isMix: true))
        #expect(YouTubeLinkClassifier.classify("https://music.youtube.com/watch?v=\(id)&list=RDMM\(id)")
                == .videoInPlaylist(videoId: id, playlistId: "RDMM\(id)", isMix: true))
        #expect(YouTubeLinkClassifier.classify("https://music.youtube.com/watch?v=\(id)&list=RDAMVM\(id)")
                == .videoInPlaylist(videoId: id, playlistId: "RDAMVM\(id)", isMix: true))
    }

    @Test("Playlist pages are playlists")
    func playlists() {
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/playlist?list=PLabc") == .playlist(id: "PLabc"))
        #expect(YouTubeLinkClassifier.classify("https://music.youtube.com/playlist?list=OLAK5uy_x") == .playlist(id: "OLAK5uy_x"))
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/playlist?list=RDCLAK5uy_x") == .playlist(id: "RDCLAK5uy_x"))
    }

    @Test("Non-YouTube or malformed links are invalid")
    func invalid() {
        #expect(YouTubeLinkClassifier.classify("https://example.com/watch?v=\(id)") == .invalid)
        #expect(YouTubeLinkClassifier.classify("https://www.youtube.com/watch?v=short") == .invalid)
        #expect(YouTubeLinkClassifier.classify("not a link") == .invalid)
        #expect(YouTubeLinkClassifier.classify("https://notyoutube.com/watch?v=\(id)") == .invalid)
    }

    @Test("Video ID shape")
    func videoIDShape() {
        #expect(YouTubeLinkClassifier.isVideoID(id))
        #expect(!YouTubeLinkClassifier.isVideoID("Rick Astley"))
        #expect(!YouTubeLinkClassifier.isVideoID("jNQXAC9IVR"))
        #expect(!YouTubeLinkClassifier.isVideoID("jNQXAC9IV.w"))
    }
}

struct DownloadProgressMathTests {
    @Test("Overall = (index + trackFraction) / count")
    func formula() {
        #expect(DownloadProgressMath.overall(index: 0, count: 1, trackFraction: 0.5) == 0.5)
        #expect(DownloadProgressMath.overall(index: 2, count: 4, trackFraction: 0.5) == 0.625)
        #expect(DownloadProgressMath.overall(index: 3, count: 4, trackFraction: 1) == 1)
        #expect(DownloadProgressMath.overall(index: 0, count: 0, trackFraction: 1) == 0)
        #expect(DownloadProgressMath.overall(index: 1, count: 2, trackFraction: 7) == 1)
        #expect(DownloadProgressMath.overall(index: 1, count: 2, trackFraction: .nan) == 0.5)
    }

    @Test("A playlist's phases never move the bar backwards")
    func monotonicAcrossPlaylist() {
        let count = 5
        var values: [Double] = []
        for index in 0..<count {
            var fractions = [DownloadProgressMath.resolvedFraction, DownloadProgressMath.coverFraction]
            fractions += stride(from: 0.0, through: 1.0, by: 0.1).map { DownloadProgressMath.audioFraction($0) }
            fractions += [DownloadProgressMath.audioDoneFraction, DownloadProgressMath.lyricsFraction, 1]
            values += fractions.map { DownloadProgressMath.overall(index: index, count: count, trackFraction: $0) }
        }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1)
    }

    @Test("Audio bytes map into the 0.15-0.9 track phase")
    func audioPhase() {
        #expect(DownloadProgressMath.audioFraction(0) == 0.15)
        #expect(abs(DownloadProgressMath.audioFraction(1) - 0.9) < 1e-9)
        #expect(DownloadProgressMath.audioFraction(-1) == 0.15)
    }
}

struct RangeResponseTests {
    @Test("Content-Range parsing")
    func parse() throws {
        let full = try #require(RangeResponse.parseContentRange("bytes 0-1023/4567"))
        #expect(full.start == 0 && full.end == 1023 && full.total == 4567)
        let unknownTotal = try #require(RangeResponse.parseContentRange("bytes 1024-2047/*"))
        #expect(unknownTotal.start == 1024 && unknownTotal.total == nil)
        #expect(RangeResponse.parseContentRange("items 0-1/2") == nil)
        #expect(RangeResponse.parseContentRange("bytes 10-5/20") == nil)
    }

    @Test("200 is accepted only at offset 0; later it restarts the file")
    func twoHundred() {
        #expect(RangeResponse.classify(status: 200, contentRange: nil, requestedOffset: 0) == .whole(restart: false))
        #expect(RangeResponse.classify(status: 200, contentRange: nil, requestedOffset: 524_288) == .whole(restart: true))
    }

    @Test("206 must start where we asked")
    func partial() {
        #expect(RangeResponse.classify(status: 206, contentRange: "bytes 100-199/1000", requestedOffset: 100) == .partial(total: 1000))
        #expect(RangeResponse.classify(status: 206, contentRange: "bytes 0-99/1000", requestedOffset: 100) == .rangeMismatch(expected: 100, got: 0))
        #expect(RangeResponse.classify(status: 206, contentRange: nil, requestedOffset: 0) == .partial(total: nil))
    }

    @Test("Blocked, retryable and odd statuses")
    func statuses() {
        #expect(RangeResponse.classify(status: 403, contentRange: nil, requestedOffset: 0) == .blocked(403))
        #expect(RangeResponse.classify(status: 401, contentRange: nil, requestedOffset: 5) == .blocked(401))
        #expect(RangeResponse.classify(status: 503, contentRange: nil, requestedOffset: 5) == .retryable(503))
        #expect(RangeResponse.classify(status: 429, contentRange: nil, requestedOffset: 5) == .retryable(429))
        #expect(RangeResponse.classify(status: 416, contentRange: nil, requestedOffset: 5) == .endOfStream)
        #expect(RangeResponse.classify(status: 416, contentRange: nil, requestedOffset: 0) == .unexpected(416))
        #expect(RangeResponse.classify(status: 302, contentRange: nil, requestedOffset: 0) == .unexpected(302))
    }
}

struct YouTubeAudioFormatPickerTests {
    private func format(_ mime: String, _ bitrate: Int, url: Bool = true, extra: [String: Any] = [:]) -> [String: Any] {
        var f: [String: Any] = ["mimeType": mime, "bitrate": bitrate]
        if url { f["url"] = "https://example.invalid/\(bitrate)" } else { f["signatureCipher"] = "s=abc&url=x" }
        for (k, v) in extra { f[k] = v }
        return f
    }

    @Test("Highest-bitrate AAC wins; ec-3 in audio/mp4 and Opus never do")
    func picksAAC() throws {
        let formats = [
            format("audio/mp4; codecs=\"mp4a.40.5\"", 50_000),
            format("audio/mp4; codecs=\"mp4a.40.2\"", 130_000),
            format("audio/webm; codecs=\"opus\"", 160_000),
            format("audio/mp4; codecs=\"ec-3\"", 384_000),
            format("audio/mp4; codecs=\"ac-3\"", 384_000),
            format("video/mp4; codecs=\"avc1.4d401f\"", 900_000),
        ]
        let choice = try YouTubeAudioFormatPicker.pick(from: formats).get()
        #expect(choice.bitrate == 130_000)
        #expect(YouTubeAudioFormatPicker.isAAC(mimeType: "audio/mp4; codecs=\"mp4a.40.2\""))
        #expect(!YouTubeAudioFormatPicker.isAAC(mimeType: "audio/mp4; codecs=\"ec-3\""))
    }

    @Test("Failure reasons")
    func failures() {
        #expect(throws: YouTubeAudioFormatPicker.Failure.onlyNonAAC) {
            try YouTubeAudioFormatPicker.pick(from: [format("audio/webm; codecs=\"opus\"", 1)]).get()
        }
        #expect(throws: YouTubeAudioFormatPicker.Failure.onlyCiphered) {
            try YouTubeAudioFormatPicker.pick(from: [format("audio/mp4; codecs=\"mp4a.40.2\"", 1, url: false)]).get()
        }
        #expect(throws: YouTubeAudioFormatPicker.Failure.noAudio) {
            try YouTubeAudioFormatPicker.pick(from: []).get()
        }
    }

    @Test("Default audio track and non-DRC preferred")
    func preferences() throws {
        let dubbed = format("audio/mp4; codecs=\"mp4a.40.2\"", 140_000, extra: ["audioTrack": ["audioIsDefault": false]])
        let original = format("audio/mp4; codecs=\"mp4a.40.2\"", 130_000, extra: ["audioTrack": ["audioIsDefault": true]])
        #expect(try YouTubeAudioFormatPicker.pick(from: [dubbed, original]).get().bitrate == 130_000)

        let drc = format("audio/mp4; codecs=\"mp4a.40.2\"", 131_000, extra: ["isDrc": true])
        let plain = format("audio/mp4; codecs=\"mp4a.40.2\"", 130_000)
        #expect(try YouTubeAudioFormatPicker.pick(from: [drc, plain]).get().bitrate == 130_000)
    }
}

struct CaptionTrackPickerTests {
    private func track(_ vss: String, _ lang: String, asr: Bool = false, url: String? = nil) -> [String: Any] {
        var t: [String: Any] = [
            "vssId": vss,
            "languageCode": lang,
            "baseUrl": url ?? "https://www.youtube.com/api/timedtext?v=x&lang=\(lang)&vss=\(vss)",
        ]
        if asr { t["kind"] = "asr" }
        return t
    }

    private func player(_ tracks: [[String: Any]]) -> [String: Any] {
        ["captions": ["playerCaptionsTracklistRenderer": ["captionTracks": tracks]]]
    }

    @Test("Uploaded track beats auto-generated; exp=xpe is skipped")
    func manualBeatsAuto() throws {
        let json = player([
            track("a.en", "en", asr: true),
            track(".en", "en"),
            track(".de-DE", "de-DE"),
            track(".ja", "ja", url: "https://www.youtube.com/api/timedtext?v=x&exp=xpe&lang=ja"),
        ])
        let tracks = CaptionTrackPicker.tracks(fromPlayer: json)
        #expect(tracks.count == 3)
        #expect(!tracks.contains { $0.languageCode == "ja" })
        #expect(CaptionTrackPicker.originalLanguage(of: tracks) == "en")

        let picked = CaptionTrackPicker.select(from: tracks, originalLanguage: "en")
        #expect(picked.count == 1)
        let first = try #require(picked.first)
        #expect(first.lang == "en")
        #expect(first.url.contains("vss=.en"))
        #expect(first.url.hasSuffix("fmt=vtt"))
    }

    @Test("Original language then English, one file each")
    func originalPlusEnglish() {
        let json = player([
            track(".en.nP7-2PuUl7o", "en"),
            track(".en-US.njLg", "en-US"),
            track(".ja", "ja"),
            track(".es", "es"),
            track("a.es", "es", asr: true),
        ])
        let tracks = CaptionTrackPicker.tracks(fromPlayer: json)
        #expect(CaptionTrackPicker.originalLanguage(of: tracks) == "es")
        let picked = CaptionTrackPicker.select(from: tracks, originalLanguage: "es")
        #expect(picked.map(\.lang) == ["es", "en"])
        #expect(picked[0].url.contains("vss=.es"))
    }

    @Test("Auto-generated is used only when nothing uploaded exists")
    func autoFallback() {
        let tracks = CaptionTrackPicker.tracks(fromPlayer: player([track("a.ja", "ja", asr: true)]))
        let picked = CaptionTrackPicker.select(from: tracks, originalLanguage: CaptionTrackPicker.originalLanguage(of: tracks))
        #expect(picked.map(\.lang) == ["ja"])
    }

    @Test("fmt is forced to vtt")
    func vttFormat() {
        #expect(CaptionTrackPicker.vttURL(from: "https://x/api/timedtext?v=1&fmt=srv3&lang=en") == "https://x/api/timedtext?v=1&fmt=vtt&lang=en")
        #expect(CaptionTrackPicker.vttURL(from: "https://x/api/timedtext?v=1") == "https://x/api/timedtext?v=1&fmt=vtt")
    }

    @Test("parsePlayer carries captions and language through")
    func parsePlayerCaptions() throws {
        var json = player([track(".en", "en"), track("a.en", "en", asr: true)])
        json["playabilityStatus"] = ["status": "OK"]
        json["streamingData"] = ["adaptiveFormats": [
            ["mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 130_000, "url": "https://example.invalid/a"],
        ]]
        json["videoDetails"] = ["title": "Me at the zoo", "author": "jawed", "lengthSeconds": "19",
                                "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/a.jpg"], ["url": "https://i.ytimg.com/b.jpg"]]]]
        let info = try YouTubeClient.parsePlayer(json, videoId: "jNQXAC9IVRw").get()
        #expect(info.captionTracks.count == 2)
        #expect(info.language == "en")
        #expect(info.duration == 19)
        #expect(info.coverUrl == "https://i.ytimg.com/b.jpg")
        #expect(info.artist == "jawed")
    }

    @Test("parsePlayer surfaces the playability reason")
    func parsePlayerRefusal() {
        let json: [String: Any] = ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm your age"]]
        guard case .failure(let failure) = YouTubeClient.parsePlayer(json, videoId: "x") else {
            Issue.record("expected failure")
            return
        }
        #expect(failure == .notPlayable(status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age"))
    }
}

struct ResolveFailureSummaryTests {
    @Test("Most specific reason wins")
    func summaries() {
        #expect(YouTubeClient.summarize([.offline, .offline]).kind == .offline)
        let unavailable = YouTubeClient.summarize([.notPlayable(status: "ERROR", reason: "Video unavailable"), .probeHTTP(403)])
        #expect(unavailable.kind == .unavailable)
        #expect(unavailable.message.contains("Video unavailable"))
        #expect(YouTubeClient.summarize([.probeHTTP(403), .http(404)]).kind == .blocked)
        #expect(YouTubeClient.summarize([.audio(.onlyNonAAC), .http(404)]).kind == .unsupportedFormat)
        #expect(YouTubeClient.summarize([.probeFailed("timed out"), .http(404)]).kind == .network)
        #expect(YouTubeClient.summarize([]).kind == .other)
    }
}

struct PlaylistPageParserTests {
    @Test("Playlist title comes from metadata, not the first 'title' key")
    func titleFromMetadata() {
        let data: [String: Any] = [
            "contents": ["twoColumnBrowseResultsRenderer": ["title": ["runs": [["text": "Some video title"]]]]],
            "header": ["playlistHeaderRenderer": ["title": ["simpleText": "Header Title"]]],
            "metadata": ["playlistMetadataRenderer": ["title": "Road Trip"]],
        ]
        #expect(PlaylistPageParser.title(fromInitialData: data) == "Road Trip")
    }

    @Test("Title falls back through the header renderers")
    func titleFallbacks() {
        #expect(PlaylistPageParser.title(fromInitialData: ["header": ["playlistHeaderRenderer": ["title": ["simpleText": "Header Title"]]]]) == "Header Title")
        #expect(PlaylistPageParser.title(fromInitialData: ["header": ["pageHeaderRenderer": ["pageTitle": "Page Title"]]]) == "Page Title")
        let viewModel: [String: Any] = ["header": ["pageHeaderRenderer": ["content": ["pageHeaderViewModel": ["title": ["dynamicTextViewModel": ["text": ["content": "VM Title"]]]]]]]]
        #expect(PlaylistPageParser.title(fromInitialData: viewModel) == "VM Title")
        #expect(PlaylistPageParser.title(fromInitialData: ["microformat": ["microformatDataRenderer": ["title": "Micro"]]]) == "Micro")
        #expect(PlaylistPageParser.title(fromInitialData: [:]) == nil)
    }

    @Test("Entries keep order and titles; continuation token is found")
    func entriesAndContinuation() {
        let contents: [[String: Any]] = [
            ["playlistVideoRenderer": ["videoId": "aaaaaaaaaaa", "title": ["runs": [["text": "First"]]]]],
            ["playlistVideoRenderer": ["videoId": "bbbbbbbbbbb", "title": ["simpleText": "[Private video]"]]],
            ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "TOKEN"]]]],
        ]
        #expect(PlaylistPageParser.entries(from: contents) == [
            PlaylistEntry(videoId: "aaaaaaaaaaa", title: "First"),
            PlaylistEntry(videoId: "bbbbbbbbbbb", title: "[Private video]"),
        ])
        #expect(PlaylistPageParser.continuationToken(from: contents) == "TOKEN")

        let browse: [String: Any] = ["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": contents]]]]
        #expect(PlaylistPageParser.entries(from: PlaylistPageParser.continuationContents(fromBrowse: browse)).map(\.videoId)
                == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    @Test("2026 lockupViewModel layout: entries, titles, continuation token, context")
    func lockupLayout() throws {
        func lockup(_ id: String, _ title: String, type: String = "LOCKUP_CONTENT_TYPE_VIDEO") -> [String: Any] {
            ["lockupViewModel": [
                "contentId": id,
                "contentType": type,
                "metadata": ["lockupMetadataViewModel": ["title": ["content": title]]],
                "rendererContext": ["commandContext": ["onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": id]]]]],
            ]]
        }
        let continuation: [String: Any] = ["continuationItemViewModel": [
            "trigger": "CONTINUATION_TRIGGER_ON_ITEM_SHOWN",
            "continuationCommand": ["innertubeCommand": ["continuationCommand": ["token": "NEXT", "request": "CONTINUATION_REQUEST_TYPE_BROWSE"]]],
        ]]
        let items: [[String: Any]] = [lockup("aaaaaaaaaaa", "Artist - One (Official Video)"), lockup("bbbbbbbbbbb", "Two"),
                                      lockup("PLxyz", "A nested playlist", type: "LOCKUP_CONTENT_TYPE_PLAYLIST"), continuation]
        let initial: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": ["title": "Top 500 Songs"]],
            "header": ["pageHeaderRenderer": ["pageTitle": "Top 500 Songs"]],
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [
                ["itemSectionRenderer": ["contents": items]],
            ]]]]]]]],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: initial), encoding: .utf8)!
        let html = """
        <script>ytcfg.set('EMERGENCY_BASE_URL', '\\/error_204');ytcfg.set({"CLIENT_CANARY_STATE":"none"});</script>
        <script>ytcfg.set({"INNERTUBE_API_KEY":"KEY123","INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"2.20260922.01.00"}}});</script>
        <script>var ytInitialData = \(json);</script>
        """
        let page = try #require(PlaylistPageParser.firstPage(fromHTML: html))
        #expect(page.title == "Top 500 Songs")
        #expect(page.entries == [
            PlaylistEntry(videoId: "aaaaaaaaaaa", title: "Artist - One (Official Video)"),
            PlaylistEntry(videoId: "bbbbbbbbbbb", title: "Two"),
        ])
        #expect(page.continuation == "NEXT")
        #expect(page.apiKey == "KEY123")
        let client = try #require(page.context?["client"] as? [String: Any])
        #expect(client["clientVersion"] as? String == "2.20260922.01.00")

        let browse: [String: Any] = ["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [lockup("ccccccccccc", "Three"), continuation]]]]]
        let more = PlaylistPageParser.continuationContents(fromBrowse: browse)
        #expect(PlaylistPageParser.entries(from: more).map(\.videoId) == ["ccccccccccc"])
        #expect(PlaylistPageParser.continuationToken(from: more) == "NEXT")
    }

    @Test("First page parses from HTML")
    func firstPageFromHTML() throws {
        let initial: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": ["title": "Mix Tape"]],
            "contents": ["playlistVideoListRenderer": ["contents": [
                ["playlistVideoRenderer": ["videoId": "aaaaaaaaaaa", "title": ["runs": [["text": "One"]]]]],
            ]]],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: initial), encoding: .utf8)!
        let html = "<script>var ytInitialData = \(json);</script><script>ytcfg.set({\"INNERTUBE_API_KEY\":\"KEY123\"});</script>"
        let page = try #require(PlaylistPageParser.firstPage(fromHTML: html))
        #expect(page.title == "Mix Tape")
        #expect(page.entries.map(\.videoId) == ["aaaaaaaaaaa"])
        #expect(page.apiKey == "KEY123")
    }
}

struct DownloadDebugLogTests {
    @Test("Log file rotates once it would pass the size cap")
    func rotation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("download-debug.log")
        let rotated = dir.appendingPathComponent("download-debug.1.log")
        for i in 0..<20 {
            DownloadDebugLog.append("line \(i) " + String(repeating: "x", count: 20) + "\n", to: file, rotatedTo: rotated, maxBytes: 100)
        }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
        #expect(size.intValue <= 100)
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }
}
#endif
