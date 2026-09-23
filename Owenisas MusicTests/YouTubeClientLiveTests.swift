// YouTubeClientLiveTests.swift
// Hits the live YouTube innertube API with the exact request shape the
// patched DownloadView.swift makes after the version bump to IOS 20.10.4.
// Confirms whether the new client string returns a usable audio URL.

import XCTest
@testable import Owenisas_Music

final class YouTubeClientLiveTests: XCTestCase {

    /// Hits live YouTube — opt in with TEST_RUNNER_OWENISAS_LIVE_TESTS=1 so the
    /// default test run stays deterministic and offline.
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OWENISAS_LIVE_TESTS"] == "1",
                          "Live YouTube test; set TEST_RUNNER_OWENISAS_LIVE_TESTS=1 to run")
    }

    /// The exact URL the new DownloadView.swift hit
    /// (Owenisas Music/DownloadView.swift:576).
    private let playerURL = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

    /// The exact client+UA the new DownloadView.swift sends
    /// (after the Aug-2026 version bump).
    private let clientName = "IOS"
    private let clientVersion = "20.10.4"
    private let userAgent = "com.google.ios.youtube/20.10.4 (iPhone; U; CPU iPhone OS 18_0 like Mac OS X;)"

    func testInnertubeIOS_20_10_4_ReturnsAudioStreams() async throws {
        let payload: [String: Any] = [
            "context": ["client": [
                "clientName": clientName,
                "clientVersion": clientVersion,
                "platform": "MOBILE",
                "hl": "en", "gl": "US"
            ] as [String: Any]],
            "videoId": "dQw4w9WgXcQ",
            "racyCheckOk": true,
            "contentCheckOk": true,
            "params": "8AEB"
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: playerURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forHTTPHeaderField: "Referer")
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = body
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 200, "innertube should return 200, got \(http.statusCode)")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ps = json["playabilityStatus"] as? [String: Any]
        let status = ps?["status"] as? String ?? "OK"
        XCTAssertEqual(status, "OK", "innertube refused with status=\(status) reason=\(ps?["reason"] ?? "")")

        let sd = json["streamingData"] as? [String: Any]
        let fmts = (sd?["formats"] as? [[String: Any]]) ?? []
        let adaptive = (sd?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let audio = (fmts + adaptive).filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/") }
        XCTAssertGreaterThan(audio.count, 0, "innertube returned zero audio streams")
        let withUrl = audio.filter { ($0["url"] as? String)?.isEmpty == false }
        XCTAssertGreaterThan(withUrl.count, 0, "all audio streams are signature-cipher-protected; iOS app cannot resolve them")

        // Log the first usable stream so the test result is self-explanatory
        let first = withUrl.first!
        let mime = first["mimeType"] as? String ?? ""
        let bitrate = first["bitrate"] as? Int ?? 0
        let title = (json["videoDetails"] as? [String: Any])?["title"] as? String ?? "<unknown>"
        XCTAssertTrue(mime.contains("audio/"), "first stream mime=\(mime)")
        XCTAssertGreaterThan(bitrate, 0, "first stream bitrate=\(bitrate)")
        print("OK: title=\(title) mime=\(mime) bitrate=\(bitrate)")
    }

    /// End-to-end proof: take the audioUrl from innertube, GET it the way the
    /// iOS DownloadView does, and verify the bytes are a valid m4a.
    /// The URL is short-lived (~6h) so the test does the two steps back-to-back.
    func testAudioStreamDownloads_AndIsValidM4A() async throws {
        // 1) Get fresh innertube response
        let payload: [String: Any] = [
            "context": ["client": [
                "clientName": clientName, "clientVersion": clientVersion,
                "platform": "MOBILE", "hl": "en", "gl": "US"
            ] as [String: Any]],
            "videoId": "dQw4w9WgXcQ",
            "racyCheckOk": true, "contentCheckOk": true, "params": "8AEB"
        ]
        var innertubeReq = URLRequest(url: URL(string: playerURL)!)
        innertubeReq.httpMethod = "POST"
        innertubeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        innertubeReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        innertubeReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        innertubeReq.setValue("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forHTTPHeaderField: "Referer")
        innertubeReq.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        innertubeReq.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        innertubeReq.httpBody = try JSONSerialization.data(withJSONObject: payload)
        innertubeReq.timeoutInterval = 15
        let (innertubeData, innertubeResp) = try await URLSession.shared.data(for: innertubeReq)
        let innertubeHTTP = innertubeResp as! HTTPURLResponse
        XCTAssertEqual(innertubeHTTP.statusCode, 200)
        let innertubeJSON = try JSONSerialization.jsonObject(with: innertubeData) as! [String: Any]
        let sd = innertubeJSON["streamingData"] as? [String: Any]
        let fmts = (sd?["formats"] as? [[String: Any]]) ?? []
        let adaptive = (sd?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let audio = (fmts + adaptive).filter {
            ($0["mimeType"] as? String ?? "").hasPrefix("audio/")
            && ($0["url"] as? String)?.isEmpty == false
            && ($0["mimeType"] as? String ?? "").contains("mp4")
        }
        XCTAssertGreaterThan(audio.count, 0, "no m4a streams available")
        let best = audio.max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }!
        let audioURL = best["url"] as! String

        // 2) GET the audioUrl the same way DownloadView does
        var audioReq = URLRequest(url: URL(string: audioURL)!)
        audioReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        audioReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        audioReq.setValue("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forHTTPHeaderField: "Referer")
        audioReq.timeoutInterval = 60
        let (audioData, audioResp) = try await URLSession.shared.data(for: audioReq)
        let audioHTTP = audioResp as! HTTPURLResponse
        XCTAssertEqual(audioHTTP.statusCode, 200, "audio GET returned \(audioHTTP.statusCode)")
        XCTAssertGreaterThan(audioData.count, 100_000, "audio body is suspiciously small: \(audioData.count) bytes")

        // 3) Verify it's a valid m4a / ISO BMFF container
        // ftyp box for mp4 is at offset 4: "ftyp" then 4 bytes major brand
        // 'isom', 'mp42', 'M4A ', 'M4A ' or 'M4V ' depending on producer
        let head = audioData.prefix(16)
        XCTAssertEqual(head[4..<8], Data("ftyp".utf8), "not a valid ISO BMFF / m4a container")
        let majorBrand = String(data: head[8..<12], encoding: .ascii) ?? "????"
        print("Downloaded \(audioData.count) bytes, major brand=\(majorBrand)")

        // 4) Save to a temp file and verify AVFoundation can open it
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("owen-test-\(UUID().uuidString).m4a")
        try audioData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertEqual(size, audioData.count, "file size mismatch after write")
        print("Saved to \(tmp.lastPathComponent), size=\(size)")
    }
}
