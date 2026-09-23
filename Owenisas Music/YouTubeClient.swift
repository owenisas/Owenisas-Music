// YouTubeClient.swift
// On-device YouTube resolver (no JS solver, no proxy): warm the watch page for
// a per-video visitorData, POST youtubei/v1/player with the VISIONOS → IOS
// client chain, pick AAC audio, and probe the stream with the same
// cookie-free Safari-UA request the downloader uses.
// Recipe and history: docs/youtube-iphone-download.md.
//
// Compiled into the TestFlight / Debug build only. Excluded from the App Store
// build via the #if !APP_STORE guard below.

#if !APP_STORE
import Foundation

struct VideoInfo {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let coverUrl: String
    let audioUrl: String
    let audioMimeType: String
    let captionTracks: [CaptionTrack]
    /// The video's original (spoken/uploaded) language, from its caption tracks.
    let language: String?
}

struct YouTubeFetchError: Error, LocalizedError {
    enum Kind: Equatable {
        case offline
        case unavailable
        case blocked
        case unsupportedFormat
        case network
        case other
    }

    let kind: Kind
    let message: String

    init(_ kind: Kind = .other, message: String) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - Captions

struct CaptionTrack: Equatable {
    let languageCode: String
    let vssId: String
    let baseUrl: String
    let isAuto: Bool
}

enum CaptionTrackPicker {
    /// `captions.playerCaptionsTracklistRenderer.captionTracks` from a player
    /// response. Watch-page URLs carrying `exp=xpe` answer 200 with an empty
    /// body without a PO token, so they are dropped here.
    static func tracks(fromPlayer json: [String: Any]) -> [CaptionTrack] {
        guard let captions = json["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let raw = renderer["captionTracks"] as? [[String: Any]] else { return [] }
        return raw.compactMap { track in
            guard let base = track["baseUrl"] as? String, !base.isEmpty,
                  !base.contains("exp=xpe") else { return nil }
            let vssId = (track["vssId"] as? String) ?? ""
            let isAuto = (track["kind"] as? String) == "asr" || vssId.hasPrefix("a.")
            var code = ((track["languageCode"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty {
                // vssId looks like ".en", "a.en" or ".en.nP7-2PuUl7o".
                let parts = vssId.split(separator: ".", omittingEmptySubsequences: true)
                code = String((isAuto ? parts.dropFirst().first : parts.first) ?? "")
            }
            guard !code.isEmpty else { return nil }
            return CaptionTrack(languageCode: code, vssId: vssId, baseUrl: base, isAuto: isAuto)
        }
    }

    /// Auto-generated (ASR) tracks exist only in the spoken language, so they
    /// are the best signal; otherwise the first uploaded track.
    static func originalLanguage(of tracks: [CaptionTrack]) -> String? {
        tracks.first(where: { $0.isAuto })?.languageCode
            ?? tracks.first(where: { !$0.isAuto })?.languageCode
    }

    /// At most one file per wanted language: the original language, then
    /// English. Uploaded tracks beat auto-generated ones; an exact language
    /// code beats a regional variant.
    static func select(from tracks: [CaptionTrack], originalLanguage: String?) -> [(lang: String, url: String)] {
        var wanted: [String] = []
        if let originalLanguage, !originalLanguage.isEmpty { wanted.append(originalLanguage) }
        if !wanted.contains(where: { baseCode($0) == "en" }) { wanted.append("en") }

        var picked: [(lang: String, url: String)] = []
        var used = Set<String>()
        for lang in wanted {
            guard let track = bestTrack(for: lang, in: tracks),
                  used.insert(track.baseUrl).inserted,
                  !picked.contains(where: { $0.lang == track.languageCode }) else { continue }
            picked.append((track.languageCode, vttURL(from: track.baseUrl)))
        }
        return picked
    }

    static func bestTrack(for lang: String, in tracks: [CaptionTrack]) -> CaptionTrack? {
        let wanted = lang.lowercased()
        let manual = tracks.filter { !$0.isAuto }
        let auto = tracks.filter { $0.isAuto }
        return manual.first { $0.languageCode.lowercased() == wanted }
            ?? manual.first { baseCode($0.languageCode) == baseCode(wanted) }
            ?? auto.first { $0.languageCode.lowercased() == wanted }
            ?? auto.first { baseCode($0.languageCode) == baseCode(wanted) }
    }

    /// timedtext base URL with `fmt=vtt` (replacing srv3/json3 if present).
    static func vttURL(from baseUrl: String) -> String {
        if let range = baseUrl.range(of: "fmt=[^&]*", options: .regularExpression) {
            return baseUrl.replacingCharacters(in: range, with: "fmt=vtt")
        }
        return baseUrl + (baseUrl.contains("?") ? "&" : "?") + "fmt=vtt"
    }

    private static func baseCode(_ code: String) -> String {
        String(code.lowercased().split(separator: "-").first ?? "")
    }
}

// MARK: - Audio format choice

enum YouTubeAudioFormatPicker {
    enum Failure: Error, Equatable {
        case noAudio
        case onlyNonAAC
        case onlyCiphered
    }

    struct Choice: Equatable {
        let url: String
        let mimeType: String
        let bitrate: Int
    }

    /// AVAudioPlayer plays AAC-in-MP4 only. `audio/mp4` alone is not enough
    /// (ec-3 / ac-3 also ship as audio/mp4), so require an `mp4a` codec.
    static func isAAC(mimeType: String) -> Bool {
        let mime = mimeType.lowercased()
        return mime.hasPrefix("audio/mp4") && mime.contains("mp4a")
    }

    static func pick(from formats: [[String: Any]]) -> Result<Choice, Failure> {
        let audio = formats.filter { (($0["mimeType"] as? String) ?? "").lowercased().hasPrefix("audio/") }
        guard !audio.isEmpty else { return .failure(.noAudio) }
        let aac = audio.filter { isAAC(mimeType: ($0["mimeType"] as? String) ?? "") }
        guard !aac.isEmpty else { return .failure(.onlyNonAAC) }
        // No JS solver: a signatureCipher-only format cannot be fetched.
        let direct = aac.filter { !((($0["url"] as? String) ?? "").isEmpty) }
        guard !direct.isEmpty else { return .failure(.onlyCiphered) }

        let ranked = direct.sorted { lhs, rhs in
            let lDefault = isDefaultTrack(lhs), rDefault = isDefaultTrack(rhs)
            if lDefault != rDefault { return lDefault }
            let lDrc = (lhs["isDrc"] as? Bool) == true, rDrc = (rhs["isDrc"] as? Bool) == true
            if lDrc != rDrc { return !lDrc }
            return bitrate(lhs) > bitrate(rhs)
        }
        let best = ranked[0]
        return .success(Choice(
            url: best["url"] as? String ?? "",
            mimeType: best["mimeType"] as? String ?? "",
            bitrate: bitrate(best)
        ))
    }

    private static func isDefaultTrack(_ format: [String: Any]) -> Bool {
        guard let track = format["audioTrack"] as? [String: Any] else { return true }
        return (track["audioIsDefault"] as? Bool) ?? true
    }

    private static func bitrate(_ format: [String: Any]) -> Int {
        let b = int(format["bitrate"])
        return b > 0 ? b : int(format["averageBitrate"])
    }

    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        return 0
    }
}

// MARK: - Resolve failures

enum ResolveFailure: Error, Equatable {
    case notPlayable(status: String, reason: String)
    case noStreamingData
    case audio(YouTubeAudioFormatPicker.Failure)
    case probeHTTP(Int)
    case probeFailed(String)
    case http(Int)
    case offline
    case network(String)
    case badResponse
}

// MARK: - Client

final class YouTubeClient {
    static let shared = YouTubeClient()

    /// The UA VISIONOS URLs are minted for. The downloader must fetch
    /// googlevideo with this exact UA (see docs/youtube-iphone-download.md).
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Cookie-free, same contract as the downloader session. Used to probe
    /// whether a googlevideo URL will actually yield bytes on device.
    private let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// A single innertube attempt configuration.
    private struct ClientProfile {
        let name: String
        let version: String
        let clientNumber: String
        let userAgent: String
    }

    /// VISIONOS serves the overwhelming majority of videos directly (plain
    /// `url`, no cipher, no `n`). IOS unlocks a few titles VISIONOS refuses.
    /// TVHTML5_SIMPLY_EMBEDDED_PLAYER was dropped 2026-09-22: it answers
    /// HTTP 404 for every video.
    private static let chain: [ClientProfile] = [
        ClientProfile(name: "VISIONOS", version: "1.02", clientNumber: "101", userAgent: safariUserAgent),
        ClientProfile(name: "IOS", version: "20.10.4", clientNumber: "5",
                      userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"),
    ]

    /// Resolves a playable AAC audio stream:
    ///   1. GET /watch?v=<id> for a per-video visitorData
    ///   2. POST /youtubei/v1/player per client in `chain` until one returns
    ///      a direct AAC URL whose first KB can be fetched cookie-free
    /// Throws a `YouTubeFetchError` with a user-facing reason.
    func resolveAudio(videoId: String, log: ((String) -> Void)? = nil) async throws -> (info: VideoInfo, client: String) {
        let visitorData = await warmWatchPage(videoId: videoId)
        var failures: [(client: String, failure: ResolveFailure)] = []

        for profile in Self.chain {
            try Task.checkCancellation()
            let payload: [String: Any]
            do {
                payload = try await postPlayer(videoId: videoId, profile: profile, visitorData: visitorData)
            } catch let failure as ResolveFailure {
                log?("\(profile.name): \(Self.describe(failure))")
                failures.append((profile.name, failure))
                continue
            }
            switch Self.parsePlayer(payload, videoId: videoId) {
            case .success(let info):
                // A player OK is not enough: on-device googlevideo URLs have
                // stalled for minutes with 0 bytes. Probe the first kilobyte
                // with the downloader's own request shape first.
                let probe = await probeStream(info.audioUrl)
                if case .ok = probe {
                    log?("\(profile.name): stream probe ok (\(info.audioMimeType))")
                    return (info, profile.name)
                }
                try Task.checkCancellation()
                let failure: ResolveFailure
                switch probe {
                case .http(let code): failure = .probeHTTP(code)
                case .failed(let reason): failure = reason == "offline" ? .offline : .probeFailed(reason)
                case .ok: continue
                }
                log?("\(profile.name): \(Self.describe(failure))")
                failures.append((profile.name, failure))
            case .failure(let failure):
                log?("\(profile.name): \(Self.describe(failure))")
                failures.append((profile.name, failure))
            }
        }
        throw Self.summarize(failures.map(\.failure))
    }

    /// Caption tracks and basic details without requiring or probing audio.
    /// Used to add lyrics to songs that are already in the library.
    func fetchCaptionInfo(videoId: String) async throws -> (title: String, author: String?, duration: Double?, tracks: [CaptionTrack], language: String?) {
        let visitorData = await warmWatchPage(videoId: videoId)
        var failures: [ResolveFailure] = []
        for profile in Self.chain {
            try Task.checkCancellation()
            do {
                let payload = try await postPlayer(videoId: videoId, profile: profile, visitorData: visitorData)
                let tracks = CaptionTrackPicker.tracks(fromPlayer: payload)
                let details = (payload["videoDetails"] as? [String: Any]) ?? [:]
                if tracks.isEmpty, details.isEmpty { failures.append(.noStreamingData); continue }
                return (
                    (details["title"] as? String) ?? videoId,
                    details["author"] as? String,
                    (details["lengthSeconds"] as? String).flatMap(Double.init),
                    tracks,
                    CaptionTrackPicker.originalLanguage(of: tracks)
                )
            } catch let failure as ResolveFailure {
                failures.append(failure)
            }
        }
        throw Self.summarize(failures)
    }

    // MARK: - Pure helpers (unit-tested)

    static func parsePlayer(_ json: [String: Any], videoId: String) -> Result<VideoInfo, ResolveFailure> {
        // Only a non-OK playabilityStatus is an error. A successful response
        // still carries playabilityStatus, with status == "OK".
        if let status = json["playabilityStatus"] as? [String: Any],
           let state = status["status"] as? String, state != "OK" {
            let reason = (status["reason"] as? String)
                ?? ((status["errorScreen"] as? [String: Any]).flatMap { Self.firstText(in: $0) })
                ?? state
            return .failure(.notPlayable(status: state, reason: reason))
        }
        guard let streamingData = json["streamingData"] as? [String: Any] else {
            return .failure(.noStreamingData)
        }
        let formats = (streamingData["formats"] as? [[String: Any]]) ?? []
        let adaptive = (streamingData["adaptiveFormats"] as? [[String: Any]]) ?? []
        let choice: YouTubeAudioFormatPicker.Choice
        switch YouTubeAudioFormatPicker.pick(from: adaptive + formats) {
        case .success(let c): choice = c
        case .failure(let f): return .failure(.audio(f))
        }

        let details = (json["videoDetails"] as? [String: Any]) ?? [:]
        let title = ((details["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (details["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = (details["lengthSeconds"] as? String).flatMap(Double.init)
        let thumbnails = (details["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let cover = thumbnails?.compactMap { $0["url"] as? String }.last ?? ""
        let tracks = CaptionTrackPicker.tracks(fromPlayer: json)

        return .success(VideoInfo(
            id: videoId,
            title: title.isEmpty ? videoId : title,
            artist: (author?.isEmpty ?? true) ? nil : author,
            album: nil,
            duration: (length ?? 0) > 0 ? length : nil,
            coverUrl: cover,
            audioUrl: choice.url,
            audioMimeType: choice.mimeType,
            captionTracks: tracks,
            language: CaptionTrackPicker.originalLanguage(of: tracks)
        ))
    }

    /// One user-facing error from every client's failure, most specific first.
    static func summarize(_ failures: [ResolveFailure]) -> YouTubeFetchError {
        if !failures.isEmpty, failures.allSatisfy({ $0 == .offline }) {
            return YouTubeFetchError(.offline, message: "You're offline. Connect to the internet and tap Retry.")
        }
        for failure in failures {
            if case .notPlayable(_, let reason) = failure {
                return YouTubeFetchError(.unavailable, message: "YouTube says: \(reason)")
            }
        }
        for failure in failures {
            if case .probeHTTP(let code) = failure, code == 401 || code == 403 {
                return YouTubeFetchError(.blocked, message: "YouTube refused the audio stream (HTTP \(code)). The video may be region-locked or protected. Try again later or try another upload of the song.")
            }
        }
        if failures.contains(.audio(.onlyNonAAC)) {
            return YouTubeFetchError(.unsupportedFormat, message: "This video only offers WebM/Opus audio, which the player can't play.")
        }
        if failures.contains(.audio(.onlyCiphered)) {
            return YouTubeFetchError(.blocked, message: "YouTube only offered protected audio for this video, which can't be downloaded on the phone.")
        }
        for failure in failures {
            switch failure {
            case .probeFailed(let reason):
                return YouTubeFetchError(.network, message: "Couldn't reach YouTube's audio server (\(reason)). Check your connection and tap Retry.")
            case .network(let reason):
                return YouTubeFetchError(.network, message: "Couldn't reach YouTube (\(reason)). Check your connection and tap Retry.")
            case .offline:
                return YouTubeFetchError(.offline, message: "You're offline. Connect to the internet and tap Retry.")
            default:
                continue
            }
        }
        if let code = failures.compactMap({ failure -> Int? in
            if case .http(let c) = failure { return c } else { return nil }
        }).first {
            return YouTubeFetchError(.other, message: "YouTube's player API answered HTTP \(code). Try again later.")
        }
        return YouTubeFetchError(.other, message: "YouTube didn't return a downloadable audio stream for this video.")
    }

    static func describe(_ failure: ResolveFailure) -> String {
        switch failure {
        case .notPlayable(let status, let reason): return "not playable (\(status)): \(reason)"
        case .noStreamingData: return "no streamingData"
        case .audio(.noAudio): return "no audio formats"
        case .audio(.onlyNonAAC): return "only non-AAC (WebM/Opus) audio"
        case .audio(.onlyCiphered): return "only signatureCipher audio"
        case .probeHTTP(let code): return "stream probe HTTP \(code)"
        case .probeFailed(let reason): return "stream probe failed: \(reason)"
        case .http(let code): return "player HTTP \(code)"
        case .offline: return "offline"
        case .network(let reason): return "network: \(reason)"
        case .badResponse: return "unreadable player response"
        }
    }

    // MARK: - Network

    /// GET the watch page to seed cookies and harvest the per-video
    /// `visitorData` embedded in the page's ytcfg. An innertube call made
    /// without a visitor id bound to a real watch session is often answered
    /// with LOGIN_REQUIRED.
    private func warmWatchPage(videoId: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&hl=en") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        guard let (data, _) = try? await session.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let visitorData = Self.extractVisitorData(fromHTML: html)
        NSLog("OWENISAS_RESOLVE: warm ok bytes=%d visitorData=%d", html.utf8.count, visitorData?.count ?? 0)
        return visitorData
    }

    enum ProbeResult: Equatable {
        case ok
        case http(Int)
        case failed(String)
    }

    /// GET the first kilobyte of a googlevideo URL with no cookies and the
    /// Safari UA, exactly like the downloader.
    private func probeStream(_ urlString: String) async -> ProbeResult {
        guard let url = URL(string: urlString) else { return .failed("bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await probeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("no HTTP response") }
            NSLog("OWENISAS_RESOLVE: probe HTTP %d bytes=%d", http.statusCode, data.count)
            if (200..<300).contains(http.statusCode), !data.isEmpty { return .ok }
            return .http(http.statusCode)
        } catch let error as URLError where Self.isOffline(error) {
            return .failed("offline")
        } catch {
            NSLog("OWENISAS_RESOLVE: probe error %@", error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    /// POST /youtubei/v1/player for one client profile.
    private func postPlayer(videoId: String, profile: ClientProfile, visitorData: String?) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw ResolveFailure.badResponse
        }

        let client: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": profile.version,
            "hl": "en",
            "gl": "US",
            "timeZone": "UTC",
            "utcOffsetMinutes": 0,
            "userAgent": profile.userAgent,
        ]
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/watch?v=\(videoId)", forHTTPHeaderField: "Referer")
        req.setValue(profile.clientNumber, forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue(profile.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw Self.isOffline(error) ? ResolveFailure.offline : ResolveFailure.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        NSLog("OWENISAS_RESOLVE: player %@ http=%d bytes=%d", profile.name, code, data.count)
        guard (200..<300).contains(code) else { throw ResolveFailure.http(code) }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResolveFailure.badResponse
        }
        return payload
    }

    static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }

    /// Pull `"visitorData":"<value>"` out of the watch page's inline ytcfg.
    static func extractVisitorData(fromHTML html: String) -> String? {
        let needle = "\"visitorData\":\""
        var searchStart = html.startIndex
        while let hit = html.range(of: needle, range: searchStart..<html.endIndex) {
            let valueStart = hit.upperBound
            guard valueStart < html.endIndex,
                  let valueEnd = html[valueStart...].firstIndex(of: "\"") else { return nil }
            let value = String(html[valueStart..<valueEnd])
            // The first occurrence can be an empty placeholder; keep scanning.
            if value.count > 40 { return value }
            searchStart = valueEnd
        }
        return nil
    }

    private static func firstText(in node: [String: Any]) -> String? {
        if let simple = node["simpleText"] as? String { return simple }
        if let runs = node["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        for value in node.values {
            if let dict = value as? [String: Any], let text = firstText(in: dict) { return text }
        }
        return nil
    }
}
#endif
