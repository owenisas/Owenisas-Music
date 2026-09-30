import ActivityKit
import Combine
import UIKit

/// One activity per active sleep timer. Track playback stays in system Now Playing.
@MainActor
final class SleepTimerActivityBridge: ObservableObject {
    static let shared = SleepTimerActivityBridge()
    @Published private(set) var status: String?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var refreshing = false
    private var refreshAgain = false
    private var lastState: SleepTimerPresentation?

    func start() {
        guard !started else { return }
        started = true
        let player = MusicPlayerManager.shared
        Publishers.MergeMany(
            player.$sleepTimerActive.map { _ in () }.eraseToAnyPublisher(),
            player.$sleepTimerEndDate.map { _ in () }.eraseToAnyPublisher(),
            player.$sleepTimerEndOfTrack.map { _ in () }.eraseToAnyPublisher(),
            player.$currentSong.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        .store(in: &cancellables)
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            await publishCurrentState()
        } while refreshAgain
        refreshing = false
    }

    private func publishCurrentState() async {
        let player = MusicPlayerManager.shared
        let state = SleepTimerPresentation.make(
            active: player.sleepTimerActive,
            endDate: player.sleepTimerEndDate,
            endOfTrack: player.sleepTimerEndOfTrack,
            title: player.currentSong?.title ?? "",
            artist: player.currentSong?.artist ?? "",
            isPlaying: player.isPlaying
        )
        let activities = Activity<SleepTimerActivityAttributes>.activities
        guard let state else {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
            lastState = nil
            status = nil
            return
        }
        let content = ActivityContent(state: state, staleDate: state.endDate)
        if let activity = activities.first {
            for duplicate in activities.dropFirst() { await duplicate.end(nil, dismissalPolicy: .immediate) }
            if lastState != state { await activity.update(content) }
            lastState = state
            status = nil
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "Live Activities are disabled. Your sleep timer still works."
            return
        }
        // ActivityKit only permits a local start while the app is foreground.
        // Background intents still set the timer; retry when the app becomes active.
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            _ = try Activity.request(attributes: SleepTimerActivityAttributes(startedAt: .now), content: content, pushType: nil)
            lastState = state
            status = nil
        } catch {
            status = "Could not show the sleep timer on your Lock Screen. Your timer still works."
        }
    }
}
