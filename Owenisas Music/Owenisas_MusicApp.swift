import SwiftUI
import SwiftData

@main
struct Owenisas_MusicApp: App {
    @ObservedObject private var player = MusicPlayerManager.shared
    @ObservedObject private var dataManager = DataManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SongData.self,
            AlbumData.self,
            PlaylistData.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Preserve app launch and expose a usable session if persistent storage is
            // unavailable (for example after a partial migration or disk error).
            print("[DataStore] Persistent container unavailable: \(error). Falling back to memory.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create fallback ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ContentView()
                }
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }

                NavigationStack {
                    SearchView()
                }
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }

                NavigationStack {
                    SongsLibraryView()
                }
                .tabItem {
                    Image(systemName: "books.vertical.fill")
                    Text("Library")
                }

            }
            .tint(.green)
            .overlay(alignment: .bottom) {
                // Position mini player just above the tab bar
                if player.showMiniPlayer {
                    MiniPlayerView()
                        .padding(.bottom, 50) // standard tab bar height
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                NowPlayingView()
            }
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
            }
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
