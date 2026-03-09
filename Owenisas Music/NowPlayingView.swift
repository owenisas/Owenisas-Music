import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Blurred background from cover art
            backgroundLayer

            VStack(spacing: 0) {
                // Drag handle
                capsuleHandle
                    .padding(.top, 12)

                Spacer().frame(height: 24)

                // Album Art or Lyrics
                if showLyrics {
                    lyricsView
                        .padding(.horizontal, 24)
                } else {
                    albumArt
                        .padding(.horizontal, 40)
                }

                Spacer().frame(height: 32)

                // Song info
                songInfo

                Spacer().frame(height: 24)

                // Progress bar
                progressSection

                Spacer().frame(height: 24)

                // Playback controls
                playbackControls

                Spacer().frame(height: 20)

                // Bottom Controls
                bottomControls

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            loadLyrics()
        }
        .onChange(of: player.currentSong) { _ in
            loadLyrics()
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 120 {
                        dismiss()
                    }
                    dragOffset = 0
                }
        )
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
        .animation(.easeInOut, value: showLyrics)
    }

    @State private var showLyrics = false
    @State private var lyrics: [LyricLine] = []

    private func loadLyrics() {
        if let song = player.currentSong, let subtitleURL = song.subtitleFileURL {
            lyrics = LyricsParser.parseVTT(fileURL: subtitleURL)
        } else {
            lyrics = []
        }
    }

    // MARK: - Background
    private var backgroundLayer: some View {
        ZStack {
            if let song = player.currentSong,
               let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 60)
                    .overlay(Color.black.opacity(0.55))
            } else {
                LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Drag Handle
    private var capsuleHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 40, height: 5)
    }

    // MARK: - Album Art
    private var albumArt: some View {
        Group {
            if let song = player.currentSong,
               let uiImage = UIImage(contentsOfFile: song.coverImageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.gray.opacity(0.4), .gray.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: player.isPlaying)
        .scaleEffect(player.isPlaying ? 1.0 : 0.9)
    }

    // MARK: - Song Info
    private var songInfo: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(player.currentSong?.title ?? "Not Playing")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(player.currentSong?.artist ?? "")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()

            if !lyrics.isEmpty {
                Button(action: { showLyrics.toggle() }) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.title2)
                        .foregroundStyle(showLyrics ? .white : .white.opacity(0.5))
                        .padding(10)
                        .background(showLyrics ? .white.opacity(0.2) : .clear)
                        .clipShape(Circle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lyrics View
    private var lyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if lyrics.isEmpty {
                        Text("No lyrics available")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 40)
                    } else {
                        ForEach(lyrics) { line in
                            let isActive = player.currentTime >= line.startTime && player.currentTime < (line.endTime + 0.5)
                            Text(line.text)
                                .font(.title2.bold())
                                .foregroundStyle(isActive ? .white : .white.opacity(0.4))
                                .scaleEffect(isActive ? 1.05 : 1.0, anchor: .leading)
                                .animation(.spring(), value: isActive)
                                .id(line.id)
                        }
                    }
                }
                .padding(.vertical, 40)
            }
            .frame(height: 360)
            .onChange(of: player.currentTime) { time in
                if let activeLine = lyrics.last(where: { time >= $0.startTime }) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        proxy.scrollTo(activeLine.id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Progress
    private var progressSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .tint(.white)

            HStack {
                Text(MusicPlayerManager.formatTime(player.currentTime))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(MusicPlayerManager.formatTime(player.duration))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Playback Controls
    private var playbackControls: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 68, height: 68)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Bottom Controls (Shuffle & Repeat)
    private var bottomControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.body.bold())
                    .foregroundStyle(player.isShuffled ? .green : .white.opacity(0.5))
            }

            Spacer()

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.body.bold())
                    .foregroundStyle(player.repeatMode.isActive ? .green : .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
    }
}
