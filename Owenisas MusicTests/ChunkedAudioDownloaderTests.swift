#if !APP_STORE
import Foundation
import Testing
@testable import Owenisas_Music

/// Serves a fake googlevideo resource through URLProtocol so the chunked
/// downloader's Range handling can be exercised without the network.
final class StubAudioProtocol: URLProtocol {
    enum Reply {
        case range          // honour the Range header with a 206
        case status(Int)    // empty body with this status
        case whole          // 200 with the whole body, ignoring Range
        case fail(URLError.Code)
        case hang           // never answer
    }

    private static let lock = NSLock()
    private static var _body = Data()
    private static var _script: (Int, URLRequest) -> Reply = { _, _ in .range }
    private static var _ranges: [String] = []

    static func configure(body: Data, script: @escaping (Int, URLRequest) -> Reply) {
        lock.withLock {
            _body = body
            _script = script
            _ranges = []
        }
    }

    static var ranges: [String] { lock.withLock { _ranges } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (index, body, reply): (Int, Data, Reply) = Self.lock.withLock {
            Self._ranges.append(request.value(forHTTPHeaderField: "Range") ?? "")
            let index = Self._ranges.count - 1
            return (index, Self._body, Self._script(index, request))
        }
        let url = request.url!
        switch reply {
        case .hang:
            return
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .whole:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .range:
            let header = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
            let spec = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
            let start = Int(spec.first ?? "0") ?? 0
            let requestedEnd = spec.count > 1 ? (Int(spec[1]) ?? body.count - 1) : body.count - 1
            guard start < body.count else {
                let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let end = min(requestedEnd, body.count - 1)
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                "Content-Length": "\(slice.count)",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: slice)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ChunkedAudioDownloaderTests {
    private let url = URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback?id=1")!

    private func makeDownloader(firstByteTimeout: TimeInterval = 2, backgrounded: Bool = false) -> ChunkedAudioDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAudioProtocol.self]
        config.timeoutIntervalForRequest = 5
        var settings = ChunkedAudioDownloader.Config()
        settings.firstChunkSize = 1_000
        settings.chunkSize = 4_000
        settings.minChunkSize = 1_000
        settings.firstByteTimeout = firstByteTimeout
        settings.retryDelay = 0.01
        return ChunkedAudioDownloader(session: URLSession(configuration: config), userAgent: "test",
                                      config: settings, log: { _ in }, wasBackgrounded: { backgrounded })
    }

    /// 30 KB that starts like an MP4 (`....ftyp`).
    private func m4aBody(size: Int = 30_000) -> Data {
        var data = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)
        data += Data((0..<(size - data.count)).map { UInt8($0 % 251) })
        return data
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString).m4a")
    }

    @Test("Sequential 206 chunks reassemble the exact file")
    func happyPath() async throws {
        let body = m4aBody()
        StubAudioProtocol.configure(body: body) { _, _ in .range }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        var lastProgress: (Int64, Int64?) = (0, nil)
        let size = try await makeDownloader().download(from: url, to: dest) { lastProgress = ($0, $1) }
        #expect(size == Int64(body.count))
        #expect(try Data(contentsOf: dest) == body)
        #expect(lastProgress.0 == Int64(body.count) && lastProgress.1 == Int64(body.count))
        #expect(StubAudioProtocol.ranges.first == "bytes=0-999")
    }

    @Test("200 after the first chunk restarts cleanly instead of appending")
    func twoHundredMidStream() async throws {
        let body = m4aBody()
        StubAudioProtocol.configure(body: body) { index, _ in index == 0 ? .range : .whole }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        let size = try await makeDownloader().download(from: url, to: dest) { _, _ in }
        #expect(size == Int64(body.count))
        #expect(try Data(contentsOf: dest) == body)
    }

    @Test("403 fails fast without retrying the URL")
    func forbidden() async throws {
        StubAudioProtocol.configure(body: m4aBody()) { _, _ in .status(403) }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        await #expect(throws: AudioDownloadError.blocked(status: 403)) {
            try await makeDownloader().download(from: url, to: dest) { _, _ in }
        }
        #expect(StubAudioProtocol.ranges.count == 1)
    }

    @Test("A mid-stream network error retries once from the same byte offset")
    func retryFromOffset() async throws {
        let body = m4aBody()
        StubAudioProtocol.configure(body: body) { index, _ in index == 2 ? .fail(.networkConnectionLost) : .range }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        _ = try await makeDownloader().download(from: url, to: dest) { _, _ in }
        #expect(try Data(contentsOf: dest) == body)
        let ranges = StubAudioProtocol.ranges
        #expect(ranges[2] == ranges[3], "retry must resume at the failed offset: \(ranges)")
        #expect(ranges[2] == "bytes=5000-8999")
    }

    @Test("A second failure at the same offset gives up with a network error")
    func retryOnlyOnce() async throws {
        StubAudioProtocol.configure(body: m4aBody()) { index, _ in index >= 1 ? .fail(.networkConnectionLost) : .range }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        await #expect(throws: AudioDownloadError.self) {
            try await makeDownloader().download(from: url, to: dest) { _, _ in }
        }
        #expect(StubAudioProtocol.ranges.count == 3)
    }

    @Test("Connection lost after the app was backgrounded is reported as such")
    func backgroundedInterruption() async throws {
        StubAudioProtocol.configure(body: m4aBody()) { index, _ in index >= 1 ? .fail(.networkConnectionLost) : .range }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        await #expect(throws: AudioDownloadError.backgrounded) {
            try await makeDownloader(backgrounded: true).download(from: url, to: dest) { _, _ in }
        }
    }

    @Test("No bytes on the first chunk within the window is a stall")
    func stall() async throws {
        StubAudioProtocol.configure(body: m4aBody()) { _, _ in .hang }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        let started = Date()
        await #expect(throws: AudioDownloadError.stalled) {
            try await makeDownloader(firstByteTimeout: 0.3).download(from: url, to: dest) { _, _ in }
        }
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(StubAudioProtocol.ranges.count == 1)
    }

    @Test("WebM and tiny files are rejected with specific errors")
    func rejectsUnplayable() async throws {
        let webm = Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(repeating: 1, count: 29_996)
        StubAudioProtocol.configure(body: webm) { _, _ in .range }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: AudioDownloadError.unsupportedFormat) {
            try await makeDownloader().download(from: url, to: dest) { _, _ in }
        }

        StubAudioProtocol.configure(body: m4aBody(size: 5_000)) { _, _ in .range }
        await #expect(throws: AudioDownloadError.tooSmall(bytes: 5_000)) {
            try await makeDownloader().download(from: url, to: dest) { _, _ in }
        }
    }

    @Test("Offline on the first chunk fails immediately")
    func offline() async throws {
        StubAudioProtocol.configure(body: m4aBody()) { _, _ in .fail(.notConnectedToInternet) }
        let dest = tempURL()
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: AudioDownloadError.offline) {
            try await makeDownloader().download(from: url, to: dest) { _, _ in }
        }
    }
}
#endif
