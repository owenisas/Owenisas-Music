import Foundation

/// An actual timer deadline, never a fabricated track-end projection.
struct SleepTimerPresentation: Codable, Hashable {
    var title: String
    var artist: String
    var endDate: Date?
    var endOfTrack: Bool
    var isPlaying: Bool

    static func make(active: Bool, endDate: Date?, endOfTrack: Bool, title: String, artist: String, isPlaying: Bool, at date: Date = .now) -> Self? {
        guard active, endOfTrack || (endDate.map { $0 > date } ?? false) else { return nil }
        return Self(
            title: title.isEmpty ? "Your music" : title,
            artist: artist.isEmpty ? "Owenisas Music" : artist,
            endDate: endOfTrack ? nil : endDate,
            endOfTrack: endOfTrack,
            isPlaying: isPlaying
        )
    }
}

#if !SHARE_EXTENSION && canImport(ActivityKit)
import ActivityKit

struct SleepTimerActivityAttributes: ActivityAttributes {
    typealias ContentState = SleepTimerPresentation
    var startedAt: Date
}
#endif
