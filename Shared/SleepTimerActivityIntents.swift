#if !SHARE_EXTENSION
import AppIntents
import Foundation

struct CancelSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Sleep Timer"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        MusicPlayerManager.shared.cancelSleepTimer()
        await SleepTimerActivityBridge.shared.refresh()
        #endif
        return .result()
    }
}

struct ExtendSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 15 Minutes"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let player = MusicPlayerManager.shared
        let remaining = max(0, player.sleepTimerEndDate?.timeIntervalSinceNow ?? 0)
        player.setSleepTimer(minutes: Int(ceil(remaining / 60)) + 15)
        await SleepTimerActivityBridge.shared.refresh()
        #endif
        return .result()
    }
}
#endif
