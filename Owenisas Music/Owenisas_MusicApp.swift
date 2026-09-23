import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case home
    case search
    case library
    #if !APP_STORE
    case download
    #endif
}

/// The selected tab, settable from outside the view tree (e.g. a shared
/// link switches to Download; see IncomingShares).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selectedTab: AppTab = ProcessInfo.processInfo.arguments.contains("APP_STORE_SCREENSHOT_LIBRARY") ? .library : .home
}

@main
struct Owenisas_MusicApp: App {
    private let player = MusicPlayerManager.shared
    private let dataManager = DataManager.shared
    @ObservedObject private var router = AppRouter.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SongData.self,
            AlbumData.self,
            PlaylistData.self,
        ])
        // groupContainer / cloudKitDatabase: .none — the app now has App Group
        // and iCloud entitlements (widget/share extension, iCloud Drive song
        // mirror). With the defaults, SwiftData would move the store into the
        // App Group (existing installs open an empty library) and switch to
        // CloudKit mode (rejects our unique constraints → crash at launch).
        // The store stays where it always was; library data syncs through
        // LibraryCloudSync instead.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, groupContainer: .none, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Preserve app launch and expose a usable session if persistent storage is
            // unavailable (for example after a partial migration or disk error).
            print("[DataStore] Persistent container unavailable: \(error). Falling back to memory.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create fallback ModelContainer: \(error)")
            }
        }
    }()

    init() {
        // A watch request can wake the app in the background without a
        // window, so onAppear never runs: wire the data layer and the watch
        // link here too (both are idempotent).
        dataManager.configure(with: sharedModelContainer.mainContext)
        // Same for a widget / Control Center / Lock Screen play tap on a cold
        // launch: restore the last queue now so the intent has something to
        // play. (restoreSession runs at most once; UI tests reset first.)
        if !ProcessInfo.processInfo.arguments.contains("UI_TEST_RESET_LIBRARY") {
            player.restoreSession(songs: dataManager.toSongs(dataManager.fetchAllSongs()))
        }
        WatchBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.selectedTab) {
                NavigationStack {
                    ContentView()
                }
                .miniPlayerInset()
                .tag(AppTab.home)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }

                NavigationStack {
                    SearchView()
                }
                .miniPlayerInset()
                .tag(AppTab.search)
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }

                NavigationStack {
                    SongsLibraryView()
                }
                .miniPlayerInset()
                .tag(AppTab.library)
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                    Text("Library")
                }

                #if !APP_STORE
                NavigationStack {
                    DownloadView()
                }
                .miniPlayerInset()
                .tag(AppTab.download)
                .tabItem {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download")
                }
                #endif

            }
            .tint(.green)
            .modifier(FullPlayerCover())
            .onAppear {
                setupAppearance()
                dataManager.configure(with: sharedModelContainer.mainContext)
                if ProcessInfo.processInfo.arguments.contains("UI_TEST_RESET_LIBRARY") {
                    dataManager.resetLibraryForUITests()
                    PlaybackSessionStore.clear()
                }
                createSongsFolderIfNeeded()
                dataManager.syncFromFileSystem()
                // Continue where you left off: rebuild the last queue, paused.
                player.restoreSession(songs: dataManager.toSongs(dataManager.fetchAllSongs()))
                cleanupTemporaryFiles()
                FeatureBootstrap.start()

                // Diagnostic: --ui-test-resolve=<videoId> runs the innertube
                // resolve only and logs which client won.
                #if !APP_STORE
                if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-resolve=") }) {
                    let videoId = String(arg.dropFirst("--ui-test-resolve=".count))
                    Task.detached {
                        NSLog("OWENISAS_RESOLVE: starting videoId=\(videoId)")
                        do {
                            let (info, client) = try await YouTubeClient.shared.resolveAudio(videoId: videoId)
                            NSLog("OWENISAS_RESOLVE: SUCCESS client=\(client) title=\(info.title) url_len=\(info.audioUrl.count)")
                        } catch {
                            NSLog("OWENISAS_RESOLVE: FAILURE %@", error.localizedDescription)
                        }
                    }
                }
                #endif
            }
            .onOpenURL { url in FeatureBootstrap.handle(url: url) }
            .modelContainer(sharedModelContainer)
        }
    }

    private func setupAppearance() {
        // Spotify-style dark tab bar
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        tabBarAppearance.backgroundColor = UIColor.systemBackground
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        // Navigation bar styling
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithDefaultBackground()
        navAppearance.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 30, weight: .bold)
        ]
        navAppearance.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().tintColor = UIColor.systemGreen
    }

    private func createSongsFolderIfNeeded() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let songsFolder = docs.appendingPathComponent("Songs")
        if !fm.fileExists(atPath: songsFolder.path) {
            try? fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        }
    }

    private func cleanupTemporaryFiles() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory
            
            guard let files = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
            
            let expirationDate = Date().addingTimeInterval(-2 * 60 * 60) // 2 hours ago
            
            for file in files {
                // Only clean up files created by our download flow (.vtt, .mp3, .jpg, etc.)
                let ext = file.pathExtension.lowercased()
                guard ["vtt", "mp3", "jpg", "jpeg", "png", "webp", "srv1"].contains(ext) else { continue }
                
                do {
                    let attrs = try fm.attributesOfItem(atPath: file.path)
                    if let creationDate = attrs[.creationDate] as? Date {
                        if creationDate < expirationDate {
                            try fm.removeItem(at: file)
                        }
                    }
                } catch {
                    // Ignore errors for files that can't be deleted
                }
            }
        }
    }
}

/// Presents the full player. Isolated in its own modifier so a player change
/// re-renders only this, not the whole TabView (the App root used to observe
/// the player and rebuild every tab on each song change).
private struct FullPlayerCover: ViewModifier {
    @ObservedObject private var player = MusicPlayerManager.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $player.showFullPlayer) {
            NowPlayingView()
        }
    }
}
