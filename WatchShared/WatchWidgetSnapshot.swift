import Foundation

enum WatchWidgetDestination: String, CaseIterable, Codable {
    case phone, watch, downloads
    var url: URL { URL(string: "owenisas-watch://" + rawValue)! }
    init?(url: URL) {
        guard url.scheme == "owenisas-watch", url.path.isEmpty,
              url.query == nil, url.fragment == nil, let host = url.host else { return nil }
        self.init(rawValue: host)
    }
}

struct WatchWidgetPlayback: Codable, Equatable {
    var title: String
    var isPlaying: Bool
    var capturedAt: Date
}

struct WatchWidgetSnapshot: Codable, Equatable {
    var phone: WatchWidgetPlayback?
    var local: WatchWidgetPlayback?
    var phoneReachable = false
    var offlineCount = 0
    static let freshness: TimeInterval = 300
    func canControl(_ destination: WatchWidgetDestination, at date: Date) -> Bool {
        let playback: WatchWidgetPlayback?
        switch destination {
        case .phone:
            guard phoneReachable else { return false }
            playback = phone
        case .watch: playback = local
        case .downloads: return false
        }
        guard let playback else { return false }
        return date.timeIntervalSince(playback.capturedAt) <= Self.freshness
    }
    func isRelevant(_ destination: WatchWidgetDestination, at date: Date) -> Bool {
        guard canControl(destination, at: date) else { return false }
        return (destination == .phone ? phone : local)?.isPlaying == true
    }
    func nextExpiry(after date: Date) -> Date {
        [phone, local].compactMap { $0?.capturedAt.addingTimeInterval(Self.freshness + 1) }
            .filter { $0 > date }.min() ?? date.addingTimeInterval(Self.freshness + 1)
    }
    func title(for destination: WatchWidgetDestination, at date: Date) -> String {
        switch destination {
        case .phone:
            guard phoneReachable else { return "iPhone unavailable" }
            guard let phone, date.timeIntervalSince(phone.capturedAt) <= Self.freshness else { return "Open iPhone app" }
            return phone.title
        case .watch:
            guard let local, date.timeIntervalSince(local.capturedAt) <= Self.freshness else {
                return offlineCount > 0 ? "\(offlineCount) downloaded songs" : "No downloads"
            }
            return local.title
        case .downloads: return offlineCount > 0 ? "\(offlineCount) downloaded songs" : "No downloads"
        }
    }
}
