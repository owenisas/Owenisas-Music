import Foundation

/// Paging for library lists sent to the watch: small pages, bounded payloads.
enum WatchPaging {
    static func clampedLimit(_ requested: Int) -> Int {
        min(max(requested, 1), WatchLimits.maxPageSize)
    }

    /// One page of `source`, mapped to wire items. Only the page's elements
    /// are mapped, so per-item work (file sizes, strings) stays bounded.
    static func page<Source, Item>(
        of source: [Source],
        offset: Int,
        limit: Int,
        title: String? = nil,
        map: (Source) -> Item
    ) -> WatchPage<Item> {
        let total = source.count
        let start = min(max(offset, 0), total)
        let end = min(start + clampedLimit(limit), total)
        let items = source[start..<end].map(map)
        return WatchPage(offset: start, total: total, items: items, title: title)
    }

    /// Encoded JSON size of a payload.
    static func encodedSize<T: Encodable>(_ value: T) -> Int {
        (try? WatchCoding.encoder().encode(value).count) ?? Int.max
    }

    /// Cap a manifest to `maxSongs` and to the largest prefix whose encoding
    /// fits `maxBytes`. The first songs of a list are the ones people expect.
    static func fitted(
        _ manifest: WatchDownloadManifest,
        maxSongs: Int = WatchLimits.maxDownloadSongs,
        maxBytes: Int = WatchLimits.maxPayloadBytes
    ) -> WatchDownloadManifest {
        var result = manifest
        if result.songs.count > maxSongs {
            result.songs = Array(result.songs.prefix(maxSongs))
        }
        guard encodedSize(result) > maxBytes else { return result }
        // Binary search for the longest prefix that fits.
        let all = result.songs
        var low = 0
        var high = all.count
        while low < high {
            let mid = (low + high + 1) / 2
            var candidate = result
            candidate.songs = Array(all.prefix(mid))
            if encodedSize(candidate) <= maxBytes {
                low = mid
            } else {
                high = mid - 1
            }
        }
        result.songs = Array(all.prefix(low))
        return result
    }
}
