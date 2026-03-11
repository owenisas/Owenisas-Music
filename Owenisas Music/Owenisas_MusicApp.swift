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
            fatalError("Could not create ModelContainer: \(error)")
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
                    SongsLibraryView()
                }
                .tabItem {
                    Image(systemName: "music.note.list")
                    Text("Library")
                }

                NavigationStack {
                    DownloadView()
                }
                .tabItem {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download")
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
                createSongsFolderIfNeeded()
                dataManager.syncFromFileSystem()
                cleanupTemporaryFiles()
            }
            .modelContainer(sharedModelContainer)
        }
    }

    private func setupAppearance() {
        // Modern translucent tab bar
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        // Navigation bar styling
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithDefaultBackground()
        navAppearance.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 32, weight: .bold)
        ]
        navAppearance.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
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
            guard let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            
            guard let files = try? fm.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: [.creationDateKey]) else { return }
            
            let expirationDate = Date().addingTimeInterval(-2 * 60 * 60) // 2 hours ago
            
            for file in files {
                do {
                    let attrs = try fm.attributesOfItem(atPath: file.path)
                    if let creationDate = attrs[.creationDate] as? Date {
                        if creationDate < expirationDate {
                            try fm.removeItem(at: file)
                        }
                    }
                } catch {
                    // Ignore errors for system files that can't be deleted
                }
            }
        }
    }
}
