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

    @Published var showSleepTimer = false
    @Published var selectedTab: AppTab = ProcessInfo.processInfo.arguments.contains("APP_STORE_SCREENSHOT_LIBRARY") ? .library : .home
}

/// No temporary editable store: every launch/retry must open the real library.
@MainActor
final class PersistentLibraryStore: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var failureMessage: String?

    init() { retry() }

    func retry() {
        let schema = Schema([SongData.self, AlbumData.self, PlaylistData.self])
        // Preserve the original local store, without App Group relocation or
        // CloudKit schema restrictions. iCloud uses the separate file mirror.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                        groupContainer: .none, cloudKitDatabase: .none)
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UI_TEST_FAIL_PERSISTENT_STORE") {
                throw NSError(domain: "LibraryStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Persistent storage failure (test)"])
            }
            #endif
            container = try ModelContainer(for: schema, configurations: [config])
            failureMessage = nil
        } catch {
            container = nil
            failureMessage = error.localizedDescription
        }
    }
}

@main
struct Owenisas_MusicApp: App {
    private let player = MusicPlayerManager.shared
    private let dataManager = DataManager.shared
    @ObservedObject private var router = AppRouter.shared

    @StateObject private var libraryStore: PersistentLibraryStore

    init() {
        let store = PersistentLibraryStore()
        _libraryStore = StateObject(wrappedValue: store)
        guard let sharedModelContainer = store.container else { return }
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
            if let sharedModelContainer = libraryStore.container {
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
            .sheet(isPresented: $router.showSleepTimer) {
                SleepTimerSheetView()
            }
            .onAppear {
                setupAppearance()
                dataManager.configure(with: sharedModelContainer.mainContext)
                WatchBridge.shared.start()
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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("UI_TEST_FAIL_PLAYBACK") {
                    let missing = Song(id: "ui-test-missing", title: "Missing audio", artist: "Test",
                                       albumTitle: "Test", audioFileURL: documentsDirectoryURL.appendingPathComponent("ui-test-missing.wav"),
                                       isFavorited: false)
                    player.play(song: missing, in: [missing])
                }
                #endif

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
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("Library unavailable").font(.title2).bold()
                    Text("Your saved library could not be opened. Editing, importing and iCloud sync are paused to protect your data. Nothing has been reset or replaced.")
                    Text("Free up device storage if needed, then retry. If this continues, restart the app or contact support before reinstalling.")
                    Text(libraryStore.failureMessage ?? "Unable to open persistent storage.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry opening library") { libraryStore.retry() }
                        .buttonStyle(.borderedProminent)
                }
                .multilineTextAlignment(.center).padding(30)
            }
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

/// Errors are available from both the mini player and the presented full player.
private struct PlaybackErrorAlert: ViewModifier {
    @ObservedObject private var player = MusicPlayerManager.shared

    func body(content: Content) -> some View {
        content.alert("Playback unavailable", isPresented: Binding(
            get: { player.playbackError != nil },
            set: { presented in
                guard !presented, let dismissedError = player.playbackError else { return }
                // SwiftUI can reset the presentation binding during a view update.
                // Publish afterwards, without clearing a newer playback failure.
                DispatchQueue.main.async {
                    if player.playbackError == dismissedError { player.playbackError = nil }
                }
            }
        )) {
            Button("Retry") { player.resume() }
            Button("Skip track") { player.next() }
            Button("Dismiss", role: .cancel) { player.playbackError = nil }
        } message: {
            Text(player.playbackError ?? "Check your audio output or re-import the audio file.")
        }
    }
}

/// Keep player observation out of the entire tab view.
private struct FullPlayerCover: ViewModifier {
    @ObservedObject private var player = MusicPlayerManager.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $player.showFullPlayer) {
            NowPlayingView().modifier(PlaybackErrorAlert())
        }
        .modifier(PlaybackErrorAlert())
    }
}
