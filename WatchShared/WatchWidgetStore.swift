import Foundation

/// This suite must be enabled on both the Watch app and its widget extension.
/// It is local to the Watch; the iPhone's NowPlayingStore is never read here.
enum WatchWidgetStore {
    static let group = "group.com.Owenisas-Music"
    static let phoneKind = "OwenisasWatchPhone"
    static let offlineKind = "OwenisasWatchOffline"
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("watch-widget.json")
    }
    static func load() -> WatchWidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WatchWidgetSnapshot.self, from: data) else {
            return WatchWidgetSnapshot()
        }
        return value
    }
    static func save(_ value: WatchWidgetSnapshot) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
