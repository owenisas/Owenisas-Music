import SwiftUI

struct RootView: View {
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var offline: OfflineLibrary
    @EnvironmentObject private var player: WatchLocalPlayer
    @EnvironmentObject private var router: WatchRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $router.path) {
            List {
                nowPlayingRows

                Section("On iPhone") {
                    if phone.isActivated && !phone.isReachable {
                        PhoneUnavailableView(message: phone.companionAppInstalled
                            ? "Open Owenisas Music on your iPhone and keep it nearby."
                            : "Install Owenisas Music on your iPhone.")
                    }
                    NavigationLink(value: WatchRoute.songs(.liked, title: "Liked Songs")) {
                        MenuRow(title: "Liked Songs", systemImage: "heart.fill")
                    }
                    NavigationLink(value: WatchRoute.playlists) {
                        MenuRow(title: "Playlists", systemImage: "music.note.list")
                    }
                    NavigationLink(value: WatchRoute.songs(.recentlyAdded, title: "Recently Added")) {
                        MenuRow(title: "Recently Added", systemImage: "clock.fill")
                    }
                }

                Section("On This Watch") {
                    NavigationLink(value: WatchRoute.offline) {
                        MenuRow(
                            title: "Downloaded",
                            systemImage: "applewatch",
                            detail: offline.index.tracks.isEmpty
                                ? nil
                                : "\(offline.index.tracks.count) songs · \(WatchStorage.format(offline.index.usedBytes))"
                        )
                    }
                }
            }
            .navigationTitle("Music")
            .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
            .navigationDestination(for: WatchRoute.self, destination: destination)
        }
        .task { WatchWidgetBridge.shared.start() }
        .onOpenURL { url in
            guard let target = WatchWidgetDestination(url: url) else { return }
            switch target {
            case .phone: router.path = [.phoneNowPlaying]
            case .watch: router.path = [player.hasTrack ? .watchNowPlaying : .offline]
            case .downloads: router.path = [.offline]
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            offline.refreshFreeSpace()
            Task { await phone.refresh() }
        }
    }

    @ViewBuilder
    private var nowPlayingRows: some View {
        if let track = player.current {
            NavigationLink(value: WatchRoute.watchNowPlaying) {
                NowPlayingRowView(songID: track.id, title: track.title, subtitle: "On Watch", isPlaying: player.isPlaying)
            }
        }
        if phone.isReachable, let state = phone.nowPlaying, state.hasSong {
            NavigationLink(value: WatchRoute.phoneNowPlaying) {
                NowPlayingRowView(songID: state.songID, title: state.title, subtitle: "iPhone", isPlaying: state.isPlaying)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .songs(let list, let title):
            SongListScreen(list: list, title: title)
        case .playlists:
            PlaylistsScreen()
        case .phoneNowPlaying:
            PhoneNowPlayingScreen()
        case .watchNowPlaying:
            WatchNowPlayingScreen()
        case .offline:
            OfflineScreen()
        case .offlineCollection(let list):
            OfflineCollectionScreen(list: list)
        case .storage:
            StorageScreen()
        }
    }
}

struct MenuRow: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.owenisasGreen)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

#Preview("Root") {
    RootView()
        .environmentObject(PhoneLink.preview())
        .environmentObject(OfflineLibrary.preview())
        .environmentObject(WatchLocalPlayer.preview())
        .environmentObject(WatchRouter())
        .tint(.owenisasGreen)
}

#Preview("Root — iPhone away") {
    RootView()
        .environmentObject(PhoneLink.preview(nowPlaying: nil, reachable: false))
        .environmentObject(OfflineLibrary.preview(WatchOfflineIndex()))
        .environmentObject(WatchLocalPlayer.preview())
        .environmentObject(WatchRouter())
        .tint(.owenisasGreen)
}
