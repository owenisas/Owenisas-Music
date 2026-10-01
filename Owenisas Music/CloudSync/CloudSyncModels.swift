import Foundation

// MARK: - Constants

enum CloudSyncConstants {
    static let containerIdentifier = "iCloud.com.Owenisas-Music"
    /// `<container>/Documents/Songs/<folder>/` mirrors `Documents/Songs/<folder>/`.
    static let songsFolderName = "Songs"
    /// `<container>/Documents/.library/<deviceID>.json`, one file per device.
    static let libraryFolderName = ".library"

    /// Timestamp for values that existed before sync first saw them. Any
    /// real edit on any device beats it.
    static let unknownDate = Date(timeIntervalSince1970: 0)

    static let enabledDefaultsKey = "cloudSync.enabled"
    static let deviceIDDefaultsKey = "cloudSync.deviceID"

    /// Debounce for library edits (likes, playlists, plays, new songs).
    static let changeDebounce: TimeInterval = 2
    /// Resume positions are saved every ~15 s while a long track plays.
    static let positionDebounce: TimeInterval = 30
    /// Safety net rescan while the app is open (hidden `.library` files may
    /// not be reported by the metadata query).
    static let periodicInterval: TimeInterval = 90
    /// Folders removed because another device deleted the song are kept
    /// aside this long before they are purged.
    static let holdingPeriod: TimeInterval = 14 * 24 * 60 * 60
    /// DataManager purges images under this size as failed downloads, so
    /// never pull them back down.
    static let minimumImageBytes: Int64 = 5_000
    /// Whole-folder copies (upload or import) per pass; the rest follow in
    /// the next pass so status and the UI stay responsive.
    static let folderOperationsPerPass = 20
}

// MARK: - File rules

enum CloudSyncFiles {
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    private static let excludedSuffixes = [
        ".tmp", ".temp", ".part", ".partial", ".download", ".crdownload",
        ".nosync", ".icloud", ".cloudtmp", "~",
    ]

    /// Files that belong to a song and are mirrored. Hidden files, temp and
    /// partial downloads, and the downloader's debug log are not.
    static func isSyncable(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let lower = name.lowercased()
        if lower.hasPrefix("download-debug") { return false }
        if excludedSuffixes.contains(where: { lower.hasSuffix($0) }) { return false }
        return true
    }

    static func isAudio(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Legacy iCloud placeholder name `.song.m4a.icloud` → `song.m4a`.
    static func placeholderTarget(_ name: String) -> String? {
        let suffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
        let target = String(name.dropFirst().dropLast(suffix.count))
        return target.isEmpty ? nil : target
    }

    /// Identity of a song folder: its name as DataManager stores the song id.
    static func folderKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSongFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
    }

    /// Audio last, so a device importing a half-uploaded folder waits for
    /// the audio instead of indexing a song without its cover and lyrics.
    static func uploadOrder(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let l = isAudio(lhs) ? 1 : 0
            let r = isAudio(rhs) ? 1 : 0
            return l != r ? l < r : lhs < rhs
        }
    }
}

// MARK: - JSON

enum CloudSyncCoding {
    /// Dates are stored as raw `Date` doubles so timestamps round-trip
    /// exactly and last-writer-wins comparisons stay stable.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

// MARK: - Per-device library file (<container>/Documents/.library/<deviceID>.json)

/// One song's library data as one device knows it.
struct CloudSongRecord: Codable, Equatable {
    var favorited: Bool = false
    /// Last-writer-wins stamp for `favorited`.
    var favoritedAt: Date = CloudSyncConstants.unknownDate
    /// Plays on *this* device only. Totals are the sum over devices.
    var playCount: Int = 0
    var lastPlayed: Date?
    var position: Double = 0
    var positionAt: Date = CloudSyncConstants.unknownDate
    /// When the song was added on this device; nil while it isn't here.
    /// A newer add than a deletion tombstone keeps the song alive.
    var addedAt: Date?
}

extension CloudSongRecord {
    private enum CodingKeys: String, CodingKey {
        case favorited, favoritedAt, playCount, lastPlayed, position, positionAt, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorited = (try? c.decodeIfPresent(Bool.self, forKey: .favorited)) ?? false
        favoritedAt = (try? c.decodeIfPresent(Date.self, forKey: .favoritedAt)) ?? CloudSyncConstants.unknownDate
        playCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .playCount)) ?? 0)
        lastPlayed = try? c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        let decodedPosition = (try? c.decodeIfPresent(Double.self, forKey: .position)) ?? 0
        position = decodedPosition.isFinite ? max(0, decodedPosition) : 0
        positionAt = (try? c.decodeIfPresent(Date.self, forKey: .positionAt)) ?? CloudSyncConstants.unknownDate
        addedAt = try? c.decodeIfPresent(Date.self, forKey: .addedAt)
    }
}

/// One playlist as one device knows it. The whole record is last-writer-wins.
struct CloudPlaylistRecord: Codable, Equatable {
    var title: String
    /// Full member list in order, including songs not downloaded here yet.
    var songOrder: [String]
    var coverImagePath: String?
    var dateCreated: Date
    var modifiedAt: Date
    var deleted: Bool = false
    /// Set on the tombstone of a duplicate that was folded into another
    /// playlist (same title created independently on two devices).
    var mergedInto: String?
}

extension CloudPlaylistRecord {
    private enum CodingKeys: String, CodingKey {
        case title, songOrder, coverImagePath, dateCreated, modifiedAt, deleted, mergedInto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        songOrder = (try? c.decodeIfPresent([String].self, forKey: .songOrder)) ?? []
        coverImagePath = try? c.decodeIfPresent(String.self, forKey: .coverImagePath)
        dateCreated = (try? c.decodeIfPresent(Date.self, forKey: .dateCreated)) ?? CloudSyncConstants.unknownDate
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? CloudSyncConstants.unknownDate
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        mergedInto = try? c.decodeIfPresent(String.self, forKey: .mergedInto)
    }
}

/// Everything one device publishes. Each device writes only its own file.
struct CloudLibraryFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = CloudLibraryFile.currentVersion
    var deviceID: String
    var deviceName: String?
    var updatedAt: Date
    var songs: [String: CloudSongRecord] = [:]
    var playlists: [String: CloudPlaylistRecord] = [:]
    /// Song id → when the user deleted it on this device.
    var deletedSongs: [String: Date] = [:]
}

extension CloudLibraryFile {
    private enum CodingKeys: String, CodingKey {
        case version, deviceID, deviceName, updatedAt, songs, playlists, deletedSongs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = try? c.decodeIfPresent(String.self, forKey: .deviceName)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? CloudSyncConstants.unknownDate
        songs = (try? c.decodeIfPresent([String: CloudSongRecord].self, forKey: .songs)) ?? [:]
        playlists = (try? c.decodeIfPresent([String: CloudPlaylistRecord].self, forKey: .playlists)) ?? [:]
        deletedSongs = (try? c.decodeIfPresent([String: Date].self, forKey: .deletedSongs)) ?? [:]
    }

    /// Stable bytes for "did anything change since the last publish".
    func contentDigest() -> Data? {
        var copy = self
        copy.updatedAt = CloudSyncConstants.unknownDate
        return try? CloudSyncCoding.encoder().encode(copy)
    }
}

// MARK: - Local sync state (Application Support/CloudSync/state.json)

/// What a playlist looked like on this device right after the last sync
/// pass, so the next pass can tell user edits from sync's own changes.
struct CloudPlaylistLocalMark: Codable, Equatable {
    var title: String
    var coverImagePath: String?
    var songIDs: [String]
}

struct CloudSyncLocalState: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = CloudSyncLocalState.currentVersion
    /// Archived `ubiquityIdentityToken`; a different account resets state.
    var accountFingerprint: Data?
    /// This device's published records (the source of truth for its file).
    var own: CloudLibraryFile
    /// Song id → other devices' play total already folded into SwiftData.
    var appliedOthersPlayCount: [String: Int] = [:]
    var playlistMarks: [String: CloudPlaylistLocalMark] = [:]
    /// Duplicate playlist id → the id it was folded into.
    var playlistAliases: [String: String] = [:]
    /// Last good copy of every other device's file (by device id), so a
    /// file that is briefly unreadable never shrinks merged totals.
    var remoteFiles: [String: CloudLibraryFile] = [:]
    /// Folder key → when this device uploaded it or first saw it in iCloud.
    /// A mirrored folder that vanishes from iCloud is not re-uploaded.
    var mirroredFolders: [String: Date] = [:]
    /// Folder key → deletion time, for container copies still to remove.
    var pendingRemoteDeletes: [String: Date] = [:]
    /// Digest of the own file as last written to iCloud.
    var publishedDigest: Data?

    init(deviceID: String, deviceName: String?, accountFingerprint: Data?) {
        self.accountFingerprint = accountFingerprint
        self.own = CloudLibraryFile(deviceID: deviceID, deviceName: deviceName, updatedAt: CloudSyncConstants.unknownDate)
    }
}

extension CloudSyncLocalState {
    private enum CodingKeys: String, CodingKey {
        case version, accountFingerprint, own, appliedOthersPlayCount, playlistMarks, playlistAliases
        case remoteFiles, mirroredFolders, pendingRemoteDeletes, publishedDigest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        accountFingerprint = try? c.decodeIfPresent(Data.self, forKey: .accountFingerprint)
        own = try c.decode(CloudLibraryFile.self, forKey: .own)
        appliedOthersPlayCount = (try? c.decodeIfPresent([String: Int].self, forKey: .appliedOthersPlayCount)) ?? [:]
        playlistMarks = (try? c.decodeIfPresent([String: CloudPlaylistLocalMark].self, forKey: .playlistMarks)) ?? [:]
        playlistAliases = (try? c.decodeIfPresent([String: String].self, forKey: .playlistAliases)) ?? [:]
        remoteFiles = (try? c.decodeIfPresent([String: CloudLibraryFile].self, forKey: .remoteFiles)) ?? [:]
        mirroredFolders = (try? c.decodeIfPresent([String: Date].self, forKey: .mirroredFolders)) ?? [:]
        pendingRemoteDeletes = (try? c.decodeIfPresent([String: Date].self, forKey: .pendingRemoteDeletes)) ?? [:]
        publishedDigest = try? c.decodeIfPresent(Data.self, forKey: .publishedDigest)
    }
}

// MARK: - User-facing transfer failures

/// File copies into the ubiquity container can succeed before Apple's
/// background upload fails. Keep those asynchronous failures visible too.
enum CloudSyncFailure {
    static func message(for error: Error) -> String {
        var current = error as NSError
        // Prefer the underlying cause, bounded for malformed error chains.
        for _ in 0..<8 {
            if let message = knownMessage(for: current) { return message }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return "iCloud sync failed: \(current.localizedDescription)"
    }

    private static func knownMessage(for error: NSError) -> String? {
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSUbiquitousFileNotUploadedDueToQuotaError:
                return "iCloud storage is full. Free up iCloud space or increase your storage plan to resume sync. Your local songs are still on this device."
            case NSFileWriteOutOfSpaceError:
                return "Your device storage is full. Free up space on this device to resume sync."
            case NSUbiquitousFileUbiquityServerNotAvailable:
                return "iCloud is unavailable right now. Sync will retry automatically."
            case NSUbiquitousFileUnavailableError:
                return "An iCloud file is unavailable right now. Sync will retry automatically."
            default: break
            }
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "iCloud sync needs an internet connection. Check your connection; sync will retry automatically."
            case NSURLErrorTimedOut:
                return "The iCloud transfer timed out. Check your connection; sync will retry automatically."
            default: break
            }
        }
        return nil
    }
}

// MARK: - Status shown in Settings

enum CloudSyncStatus: Equatable {
    case off
    case unavailable
    case checking
    case upToDate
    case syncing(uploading: Int, downloading: Int)
    case failed(String)

    var text: String {
        switch self {
        case .off:
            return "Off"
        case .unavailable:
            return "iCloud unavailable — sign in to iCloud"
        case .checking:
            return "Checking iCloud…"
        case .upToDate:
            return "Up to date"
        case let .syncing(uploading, downloading):
            var parts: [String] = []
            if uploading > 0 { parts.append("Uploading \(uploading) song\(uploading == 1 ? "" : "s")") }
            if downloading > 0 { parts.append("Downloading \(downloading)") }
            return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
        case let .failed(message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "icloud.slash"
        case .unavailable: return "exclamationmark.icloud"
        case .checking: return "icloud"
        case .upToDate: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }
}
