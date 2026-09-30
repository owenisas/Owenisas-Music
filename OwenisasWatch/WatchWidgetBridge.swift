import Combine
import Foundation
import WidgetKit

@MainActor
final class WatchWidgetBridge {
    static let shared = WatchWidgetBridge()
    private var observers: [AnyCancellable] = []
    private var last: WatchWidgetSnapshot?

    func start() {
        guard observers.isEmpty else { return }
        let phone = PhoneLink.shared
        let player = WatchLocalPlayer.shared
        let library = OfflineLibrary.shared
        // Published values arrive before the property changes. Coalesce on the
        // main queue, then read settled state; do not reload for elapsed seconds.
        Publishers.MergeMany([
            phone.$nowPlaying.map { _ in () }.eraseToAnyPublisher(),
            phone.$isReachable.map { _ in () }.eraseToAnyPublisher(),
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$index.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            library.$index.map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.publish() }
        .store(in: &observers)
        publish()
    }

    private func publish() {
        let phone = PhoneLink.shared
        let player = WatchLocalPlayer.shared
        let state = phone.nowPlaying
        let value = WatchWidgetSnapshot(
            phone: state.flatMap { $0.hasSong ? WatchWidgetPlayback(title: $0.title, isPlaying: $0.isPlaying, capturedAt: $0.capturedAt) : nil },
            local: player.current.map { WatchWidgetPlayback(title: $0.title, isPlaying: player.isPlaying, capturedAt: Date()) },
            phoneReachable: phone.isReachable,
            offlineCount: OfflineLibrary.shared.index.tracks.count
        )
        guard value != last else { return }
        do {
            try WatchWidgetStore.save(value)
            last = value
            WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetStore.phoneKind)
            WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetStore.offlineKind)
        } catch {
            NSLog("Watch widget snapshot unavailable: %@", error.localizedDescription)
        }
    }
}
