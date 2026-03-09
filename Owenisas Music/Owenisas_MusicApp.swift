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
            ZStack(alignment: .bottom) {
                TabView {
                    NavigationView {
                        ContentView()
                    }
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }

                    NavigationView {
                        SongsLibraryView()
                    }
                    .tabItem {
                        Image(systemName: "music.note.list")
                        Text("Library")
                    }

                    NavigationView {
                        DownloadView()
                    }
                    .tabItem {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                }
                .tint(.green)

                // Global Mini Player (above tab bar)
                VStack(spacing: 0) {
                    Spacer()
                    MiniPlayerView()
                        .padding(.bottom, 50) // tab bar height
                }
                .ignoresSafeArea(.keyboard)
            }
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                NowPlayingView()
            }
            .onAppear {
                setupAppearance()
                dataManager.configure(with: sharedModelContainer.mainContext)
                createSongsFolderIfNeeded()
                dataManager.syncFromFileSystem()
            }
            .modelContainer(sharedModelContainer)
        }
    }

    private func setupAppearance() {
        // Dark-tinted tab bar
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    private func createSongsFolderIfNeeded() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let songsFolder = docs.appendingPathComponent("Songs")
        if !fm.fileExists(atPath: songsFolder.path) {
            try? fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        }
    }
}
