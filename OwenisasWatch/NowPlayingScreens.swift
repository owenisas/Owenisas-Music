import SwiftUI

/// Remote control for the iPhone's player. The Digital Crown changes the
/// iPhone's volume (`WKInterfaceVolumeControl`, companion origin).
struct PhoneNowPlayingScreen: View {
    @EnvironmentObject private var phone: PhoneLink
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let state = phone.nowPlaying, state.hasSong {
                controls(for: state)
            } else if phone.isActivated && !phone.isReachable {
                PhoneUnavailableView()
            } else {
                EmptyStateView(
                    systemImage: "music.note",
                    title: "Nothing Playing",
                    message: "Pick a song from your library."
                )
            }
        }
        .overlay(alignment: .bottom) { ErrorToast(message: $errorMessage) }
        .navigationTitle("iPhone")
        .containerBackground(for: .navigation) {
            ArtworkBackdrop(songID: phone.nowPlaying?.songID)
        }
        .task { await phone.refresh() }
    }

    private func controls(for state: WatchNowPlaying) -> some View {
        VStack(spacing: 4) {
            TrackHeader(songID: state.songID, title: state.title, artist: state.artist)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                PlaybackProgressView(elapsed: state.elapsed(at: context.date), duration: state.duration)
            }

            TransportControls(
                isPlaying: state.isPlaying,
                previous: { send(WatchCommand(action: .previous)) },
                playPause: { send(WatchCommand(action: .togglePlayPause)) },
                next: { send(WatchCommand(action: .next)) }
            )

            HStack {
                Button {
                    send(.toggleFavorite(songID: state.songID))
                } label: {
                    Image(systemName: state.isFavorited ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundStyle(state.isFavorited ? Color.owenisasGreen : .primary)
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.isFavorited ? "Unlike" : "Like")

                Spacer()

                CrownVolumeControl(target: .iPhone)
                    .frame(width: 36, height: 30)
                    .accessibilityLabel("iPhone volume. Turn the Digital Crown.")
            }
        }
    }

    private func send(_ command: WatchCommand) {
        Task {
            do {
                try await phone.send(command)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Player for music downloaded to the watch (Bluetooth headphones).
struct WatchNowPlayingScreen: View {
    @EnvironmentObject private var player: WatchLocalPlayer

    var body: some View {
        Group {
            if let track = player.current {
                VStack(spacing: 4) {
                    TrackHeader(songID: track.id, title: track.title, artist: track.artist)

                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        PlaybackProgressView(elapsed: player.currentTime, duration: player.duration)
                    }

                    TransportControls(
                        isPlaying: player.isPlaying,
                        isBusy: player.isActivating,
                        previous: { Task { await player.previous() } },
                        playPause: { Task { await player.togglePlayPause() } },
                        next: { Task { await player.next() } }
                    )

                    HStack {
                        Text("\(player.index + 1) of \(player.queue.count)")
                            .font(.system(.caption2, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        CrownVolumeControl(target: .watch)
                            .frame(width: 36, height: 30)
                            .accessibilityLabel("Volume. Turn the Digital Crown.")
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "applewatch",
                    title: "Nothing Playing",
                    message: "Play downloaded music from On This Watch."
                )
            }
        }
        .overlay(alignment: .bottom) { ErrorToast(message: $player.problem) }
        .navigationTitle("On Watch")
        .containerBackground(for: .navigation) {
            ArtworkBackdrop(songID: player.current?.id)
        }
    }
}

struct TrackHeader: View {
    let songID: String?
    let title: String
    let artist: String

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(songID: songID, size: 38, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(artist)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Short-lived message at the bottom of a screen.
struct ErrorToast: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture { self.message = nil }
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.message = nil
                }
                .transition(.opacity)
        }
    }
}

#Preview("iPhone remote") {
    NavigationStack {
        PhoneNowPlayingScreen()
    }
    .environmentObject(PhoneLink.preview())
    .tint(.owenisasGreen)
}

#Preview("iPhone unreachable") {
    NavigationStack {
        PhoneNowPlayingScreen()
    }
    .environmentObject(PhoneLink.preview(nowPlaying: nil, reachable: false))
}

#Preview("On watch") {
    NavigationStack {
        WatchNowPlayingScreen()
    }
    .environmentObject(WatchLocalPlayer.preview())
    .tint(.owenisasGreen)
}
