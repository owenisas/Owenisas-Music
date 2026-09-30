import Foundation
import Testing
@testable import Owenisas_Music

struct SleepTimerActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func expiredTimerHasNoActivity() {
        #expect(SleepTimerPresentation.make(active: true, endDate: now, endOfTrack: false, title: "Song", artist: "Artist", isPlaying: true, at: now) == nil)
    }

    @Test func inactiveTimerHasNoActivity() {
        #expect(SleepTimerPresentation.make(active: false, endDate: now.addingTimeInterval(60), endOfTrack: false, title: "Song", artist: "Artist", isPlaying: true, at: now) == nil)
    }

    @Test func timedActivityKeepsExactDeadlineAndMetadata() throws {
        let end = now.addingTimeInterval(1_800)
        let state = try #require(SleepTimerPresentation.make(active: true, endDate: end, endOfTrack: false, title: "Song", artist: "Artist", isPlaying: false, at: now))
        #expect(state.endDate == end)
        #expect(state.title == "Song")
        #expect(!state.isPlaying)
        #expect(!state.endOfTrack)
    }

    @Test func endOfTrackDoesNotInventDeadline() throws {
        let state = try #require(SleepTimerPresentation.make(active: true, endDate: nil, endOfTrack: true, title: "", artist: "", isPlaying: false, at: now))
        #expect(state.endDate == nil)
        #expect(state.title == "Your music")
        #expect(state.artist == "Owenisas Music")
        #expect(state.endOfTrack)
    }

    @MainActor @Test func sleepTimerURLRequestsPresentationWithoutASong() throws {
        let router = AppRouter.shared
        let originalTab = router.selectedTab
        let originalPresentation = router.showSleepTimer
        router.showSleepTimer = false
        var requestedPresentation = false
        let observation = router.objectWillChange.sink { requestedPresentation = true }
        defer {
            observation.cancel()
            router.showSleepTimer = originalPresentation
        }
        FeatureBootstrap.handle(url: try #require(URL(string: "owenisas://sleeptimer")))
        #expect(requestedPresentation)
        #expect(router.showSleepTimer)
        #expect(router.selectedTab == originalTab)
    }

    @Test func invalidActiveTimerHasNoActivity() {
        #expect(SleepTimerPresentation.make(active: true, endDate: nil, endOfTrack: false, title: "", artist: "", isPlaying: false, at: now) == nil)
    }
}
