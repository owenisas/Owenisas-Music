import Foundation

// Wire protocol between the iPhone app and the Watch app (WatchConnectivity).
// Both targets compile this folder, so there is exactly one definition.
//
// Every WatchConnectivity dictionary (message, reply, application context,
// user info, file metadata) is an envelope:
//
//   "v"   Int     sender's protocol version
//   "mv"  Int     oldest peer version the sender still understands
//   "k"   String  message kind (`WatchMessageKind`)
//   "b"   Data    JSON-encoded Codable payload for that kind
//
// Within one version, payloads only gain optional fields (JSONDecoder ignores
// unknown keys, so an older peer keeps working). A breaking change bumps
// `version`, and `minimumPeerVersion` when the old shape is dropped.

enum WatchProtocol {
    static let version = 1
    static let minimumPeerVersion = 1

    /// Whether we can talk to a peer that speaks `peerVersion` and still
    /// understands versions back to `peerMinimum`.
    static func isCompatible(
        peerVersion: Int,
        peerMinimum: Int,
        ourVersion: Int = version,
        ourMinimum: Int = minimumPeerVersion
    ) -> Bool {
        peerVersion >= ourMinimum && peerMinimum <= ourVersion
    }
}

enum WatchMessageKey {
    static let version = "v"
    static let minimumVersion = "mv"
    static let kind = "k"
    static let body = "b"
}

enum WatchMessageKind: String, CaseIterable, Codable {
    // Watch → phone, sendMessage with reply. A successful reply uses the
    // same kind; a failure replies with `.error` (`WatchErrorReply`).
    /// `WatchCommand` → `WatchNowPlaying`
    case command = "cmd"
    /// `WatchSongPageRequest` → `WatchPage<WatchSongItem>`
    case songPage = "songs"
    /// `WatchPageRequest` → `WatchPage<WatchPlaylistItem>`
    case playlistPage = "lists"
    /// `WatchArtworkRequest` → `WatchArtwork`
    case artwork = "art"
    /// `WatchManifestRequest` → `WatchDownloadManifest`
    case downloadManifest = "manifest"
    /// `WatchTransferRequest` → `WatchTransferAck`
    case transferRequest = "xfer"
    /// `WatchCancelTransfers` (message when reachable, else user info) → `WatchEmpty`
    case cancelTransfers = "cancel"

    // Phone → watch.
    /// `WatchNowPlaying` (application context + live message)
    case nowPlaying = "np"
    /// `WatchFileMetadata` (metadata of `transferFile`)
    case file = "file"
    /// `WatchTransferFailure` (user info)
    case transferFailed = "xfail"

    /// `WatchErrorReply`
    case error = "err"
}

/// Empty payload for acknowledgements.
struct WatchEmpty: Codable, Equatable {}

/// A failure the other side reports in a reply.
struct WatchErrorReply: Codable, Equatable, Error {
    enum Code: String, Codable {
        /// The iPhone app is running but its library isn't loaded (launched
        /// in the background) — the user should open it.
        case phoneNotReady
        case notFound
        case incompatibleVersion
        case unsupported
        case badRequest
        case internalError
    }

    var code: Code
    var message: String

    init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case code, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A newer peer may send a code we don't know yet.
        let raw = try c.decode(String.self, forKey: .code)
        code = Code(rawValue: raw) ?? .internalError
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

enum WatchCodingError: Error, Equatable {
    /// Not one of our envelopes (missing keys / wrong types).
    case notAnEnvelope
    /// A kind this build doesn't know (newer peer).
    case unknownKind(String)
    case incompatible(peerVersion: Int, peerMinimum: Int)
    case unexpectedKind(expected: WatchMessageKind, got: WatchMessageKind)
    case badPayload(String)
    /// The peer replied with an error.
    case remote(WatchErrorReply)
}

enum WatchCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

struct WatchEnvelope {
    let kind: WatchMessageKind
    let version: Int
    let minimumVersion: Int
    let body: Data

    /// Build a WatchConnectivity dictionary for `payload`.
    static func encode<T: Encodable>(
        _ kind: WatchMessageKind,
        _ payload: T,
        version: Int = WatchProtocol.version,
        minimumVersion: Int = WatchProtocol.minimumPeerVersion
    ) throws -> [String: Any] {
        let body = try WatchCoding.encoder().encode(payload)
        return [
            WatchMessageKey.version: version,
            WatchMessageKey.minimumVersion: minimumVersion,
            WatchMessageKey.kind: kind.rawValue,
            WatchMessageKey.body: body,
        ]
    }

    /// Error reply dictionary (never throws — used on failure paths).
    static func errorReply(_ code: WatchErrorReply.Code, _ message: String) -> [String: Any] {
        (try? encode(.error, WatchErrorReply(code: code, message: message))) ?? [
            WatchMessageKey.version: WatchProtocol.version,
            WatchMessageKey.minimumVersion: WatchProtocol.minimumPeerVersion,
            WatchMessageKey.kind: WatchMessageKind.error.rawValue,
            WatchMessageKey.body: Data("{\"code\":\"internalError\",\"message\":\"\"}".utf8),
        ]
    }

    /// Parse and validate an incoming dictionary (version compatibility and
    /// known kind). Throws `WatchCodingError`.
    init(_ dictionary: [String: Any]) throws {
        guard let version = (dictionary[WatchMessageKey.version] as? NSNumber)?.intValue,
              let rawKind = dictionary[WatchMessageKey.kind] as? String,
              let body = dictionary[WatchMessageKey.body] as? Data else {
            throw WatchCodingError.notAnEnvelope
        }
        let minimum = (dictionary[WatchMessageKey.minimumVersion] as? NSNumber)?.intValue ?? version
        guard WatchProtocol.isCompatible(peerVersion: version, peerMinimum: minimum) else {
            throw WatchCodingError.incompatible(peerVersion: version, peerMinimum: minimum)
        }
        guard let kind = WatchMessageKind(rawValue: rawKind) else {
            throw WatchCodingError.unknownKind(rawKind)
        }
        self.kind = kind
        self.version = version
        self.minimumVersion = minimum
        self.body = body
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try WatchCoding.decoder().decode(T.self, from: body)
        } catch {
            throw WatchCodingError.badPayload("\(T.self): \(error)")
        }
    }

    /// Decode a reply to a `kind` request. An `.error` reply becomes
    /// `WatchCodingError.remote`.
    static func decodeReply<T: Decodable>(
        _ dictionary: [String: Any],
        expecting kind: WatchMessageKind,
        as type: T.Type
    ) throws -> T {
        let envelope = try WatchEnvelope(dictionary)
        if envelope.kind == .error {
            throw WatchCodingError.remote(try envelope.decode(WatchErrorReply.self))
        }
        guard envelope.kind == kind else {
            throw WatchCodingError.unexpectedKind(expected: kind, got: envelope.kind)
        }
        return try envelope.decode(T.self)
    }
}
