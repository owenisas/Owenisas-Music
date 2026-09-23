import Foundation

/// Storage rules for music kept on the watch.
enum WatchStorage {
    static let megabyte: Int64 = 1_000_000
    static let gigabyte: Int64 = 1_000_000_000

    /// Limits the user can pick for downloaded music.
    static let capOptions: [Int64] = [
        500 * megabyte, 1 * gigabyte, 2 * gigabyte, 4 * gigabyte, 8 * gigabyte,
    ]
    static let defaultCap: Int64 = 2 * gigabyte
    /// Always leave this much free for watchOS itself.
    static let reserveBytes: Int64 = 500 * megabyte
    /// Warn once downloads use this share of the limit.
    static let nearlyFullFraction = 0.9

    /// Bytes a new download may still use: under the user's limit (counting
    /// transfers still on their way) and never eating into the reserve.
    /// `freeBytes` is nil when the volume can't be queried.
    static func budget(capBytes: Int64, committedBytes: Int64, freeBytes: Int64?) -> Int64 {
        let underCap = capBytes - committedBytes
        let underFree = freeBytes.map { $0 - reserveBytes } ?? Int64.max
        return max(0, min(underCap, underFree))
    }

    static func fraction(used: Int64, cap: Int64) -> Double {
        guard cap > 0 else { return 1 }
        return min(max(Double(used) / Double(cap), 0), 1)
    }

    enum Level: Equatable {
        case ok, nearlyFull, full
    }

    static func level(committedBytes: Int64, capBytes: Int64, freeBytes: Int64?) -> Level {
        if budget(capBytes: capBytes, committedBytes: committedBytes, freeBytes: freeBytes) <= 0 {
            return .full
        }
        return fraction(used: committedBytes, cap: capBytes) >= nearlyFullFraction ? .nearlyFull : .ok
    }

    /// Nearest allowed cap (a stored value from an older build may not be an option).
    static func normalizedCap(_ value: Int64) -> Int64 {
        guard value > 0 else { return defaultCap }
        return capOptions.min { abs($0 - value) < abs($1 - value) } ?? defaultCap
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return formatter.string(fromByteCount: max(0, bytes))
    }
}

/// File names for audio stored on the watch. Song ids are folder names on
/// the phone (any characters, any length), so the file name is a stable
/// hash — never a path the phone controls.
enum WatchFileNaming {
    static func fileName(songID: String, fileExtension: String) -> String {
        "t-" + hash(songID) + "." + sanitizedExtension(fileExtension)
    }

    /// 64-bit FNV-1a over UTF-8, as 16 hex digits. Deterministic across
    /// launches and platforms (unlike `Hasher`).
    static func hash(_ string: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    static let playableExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac", "mp4"]

    static func sanitizedExtension(_ ext: String) -> String {
        let cleaned = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return playableExtensions.contains(cleaned) ? cleaned : "m4a"
    }
}
