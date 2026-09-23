import SwiftUI
import WatchKit

@main
struct OwenisasWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var phone = PhoneLink.shared
    @StateObject private var offline = OfflineLibrary.shared
    @StateObject private var player = WatchLocalPlayer.shared
    @StateObject private var router = WatchRouter()

    init() {
        // Load the offline index before files can arrive.
        _ = OfflineLibrary.shared
        PhoneLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(phone)
                .environmentObject(offline)
                .environmentObject(player)
                .environmentObject(router)
                .tint(.owenisasGreen)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        _ = OfflineLibrary.shared
        PhoneLink.shared.activate()
    }

    /// WatchConnectivity wakes the app in the background to deliver the
    /// phone's state and audio files.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                _ = OfflineLibrary.shared
                PhoneLink.shared.hold(connectivityTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
