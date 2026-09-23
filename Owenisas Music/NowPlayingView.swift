import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoaded = false
    @State private var lyricsReloadToken = 0
    @State private var lyricsSongID: String?
    @State private var isFetchingLyrics = false
    @State private var lyricsLookupFailedFor: String?
    @State private var cachedCoverImage: UIImage?
    @State private var selectedLanguage: String = ""
    @State private var availableLanguages: [(code: String, name: String)] = []

    @AppStorage("preferredLyricsLanguage") private var preferredLyricsLanguage: String = ""
    @State private var showLanguagePicker = false

    private var songID: String? { player.currentSong?.id }
    private var coverPath: String? { player.currentSong?.coverImageURL?.path }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AnimatedNowPlayingBackground(image: cachedCoverImage, imagePath: coverPath)

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 16)
                    centerContent(geo: geo)
                    Spacer(minLength: 20)

                    songInfoSection
                        .padding(.horizontal, 28)

                    NowPlayingProgress(player: player, songID: songID ?? "", isPlaying: player.isPlaying)
                        .padding(.horizontal, 28)
                        .padding(.top, 6)

                    playbackControls
                        .padding(.top, 18)
                        .padding(.bottom, 4)

                    bottomControls
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 12 : 20)
                }
            }
        }
        // Cover art: keyed on the path so a late load for a skipped song
        // can't replace the current one.
        .task(id: coverPath) {
            await loadCoverImage(path: coverPath)
        }
        // Lyrics: parsed off the main thread; reloads on song change, on an
        // explicit language pick, or when new lyric files land on disk.
        .task(id: "\(songID ?? "")|\(lyricsReloadToken)") {
            await loadLyrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .subtitlesChanged)) { note in
            if let path = note.object as? String,
               path == player.currentSong?.songFolderURL?.path {
                lyricsReloadToken += 1
            }
        }
        .gesture(dismissDrag)
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLanguagePicker) {
            NavigationStack {
                List(availableLanguages, id: \.code) { lang in
                    Button {
                        selectedLanguage = lang.code
                        preferredLyricsLanguage = lang.code
                        lyricsReloadToken += 1
                        showLanguagePicker = false
                    } label: {
                        HStack {
                            Text(lang.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if lang.code == selectedLanguage {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                    .fontWeight(.bold)
                            }
                        }
                    }
                }
                .navigationTitle("Select Language")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { showLanguagePicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Cover image (cached, loaded once per song)
    private func loadCoverImage(path: String?) async {
        guard let path else {
            cachedCoverImage = nil
            return
        }
        if let cached = ImageCache.shared.cachedImage(for: path) {
            cachedCoverImage = cached
            return
        }
        // Show the placeholder rather than the previous song's art while loading.
        cachedCoverImage = nil
        let image = await Task.detached(priority: .userInitiated) {
            ImageCache.shared.image(for: path)
        }.value
        guard !Task.isCancelled else { return }
        cachedCoverImage = image
    }

    // MARK: - Dismiss gesture
    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { v in
                guard !isDismissing else { return }
                if v.translation.height > 0 { dragOffset = v.translation.height }
            }
            .onEnded { v in
                if v.translation.height > 140 {
                    // Keep the offset: resetting it here made the content
                    // spring back up while the cover slid down.
                    isDismissing = true
                    dismiss()
                } else {
                    dragOffset = 0
                }
            }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .accessibilityHidden(true)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close player")

                Spacer()

                if player.currentSong != nil {
                    // Always offered: a song without lyrics gets an explicit
                    // empty state instead of a button that silently vanishes.
                    Button { withAnimation(.spring(response: 0.4)) { showLyrics.toggle() } } label: {
                        Image(systemName: showLyrics ? "text.quote" : "quote.bubble")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(showLyrics ? .white : .white.opacity(0.6))
                            .frame(width: 36, height: 36)
                            .background(
                                showLyrics
                                    ? AnyShapeStyle(.white.opacity(0.2))
                                    : AnyShapeStyle(.ultraThinMaterial.opacity(0.4)),
                                in: Circle()
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")

                    // Language picker (only visible when lyrics are showing)
                    if showLyrics && availableLanguages.count > 1 {
                        Button {
                            showLanguagePicker = true
                        } label: {
                            Image(systemName: "globe")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Lyrics language")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
    }

    // MARK: - Center Content
    @ViewBuilder
    private func centerContent(geo: GeometryProxy) -> some View {
        let artSize = min(geo.size.width - 56, geo.size.height * 0.42)

        if showLyrics {
            Group {
                if !lyrics.isEmpty {
                    LyricsPanel(player: player, lyrics: lyrics, isPlaying: player.isPlaying)
                } else if lyricsLoaded {
                    noLyricsView
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(height: artSize)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .transition(.opacity)
        } else {
            albumArt
                .frame(width: artSize, height: artSize)
                .transition(.opacity)
        }
    }

    private var noLyricsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("No lyrics for this song")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            #if APP_STORE
            Text("Add a .vtt lyrics file to the song's folder in Files.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            #else
            if lyricsLookupFailedFor == songID {
                Text("No match found online for this song.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            Button {
                findLyrics()
            } label: {
                HStack(spacing: 6) {
                    if isFetchingLyrics {
                        ProgressView().tint(.black).controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(isFetchingLyrics ? "Searching…" : "Find Lyrics")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(.white, in: Capsule())
            }
            .disabled(isFetchingLyrics)
            .padding(.top, 6)
            #endif
        }
        .padding(.horizontal, 12)
    }

    #if !APP_STORE
    /// Look up lyrics for the current song (YouTube captions when it came from
    /// YouTube, otherwise LRCLIB by title/artist/length). Works for imported
    /// songs too. New files trigger `.subtitlesChanged`, which reloads.
    private func findLyrics() {
        guard let song = player.currentSong, !isFetchingLyrics else { return }
        isFetchingLyrics = true
        Task {
            let found = await LyricsFetcher.fetchMissingLyrics(for: song)
            isFetchingLyrics = false
            if found {
                lyricsLookupFailedFor = nil
                lyricsReloadToken += 1
            } else {
                lyricsLookupFailedFor = song.id
            }
        }
    }
    #endif

    // MARK: - Album Art (uses cached image)
    private var albumArt: some View {
        Group {
            if let uiImage = cachedCoverImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .scaleEffect(player.isPlaying ? 1.0 : 0.88)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: player.isPlaying)
        .accessibilityHidden(true)
    }

    // MARK: - Song Info
    private var songInfoSection: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentSong?.title ?? "Not Playing")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(player.currentSong?.artist ?? "Unknown Artist")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            let isFavorited = player.currentSong?.isFavorited == true
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    player.toggleFavorite()
                }
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(isFavorited ? .pink : .white.opacity(0.5))
                    .scaleEffect(isFavorited ? 1.1 : 1.0)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isFavorited ? "Remove from Liked Songs" : "Add to Liked Songs")

            if let song = player.currentSong {
                ShareLink(item: song.title + " - " + song.artist) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share song")
            }
        }
    }

    // MARK: - Playback Controls
    private var playbackControls: some View {
        HStack(spacing: 0) {
            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous song")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                        .shadow(color: .white.opacity(0.2), radius: 12)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .scaleEffect(player.isPlaying ? 1.0 : 0.96)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: player.isPlaying)
            .accessibilityIdentifier("nowPlayingPlayPause")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next song")

            Spacer()
        }
    }

    // MARK: - Bottom Controls
    @State private var showSleepTimer = false

    private var speedLabel: String {
        let rate = player.playbackRate
        // Trim trailing zeros: 1.0 -> "1×", 1.25 -> "1.25×", 1.5 -> "1.5×"
        let trimmed = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate))
            : String(rate).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(trimmed)×"
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    private var bottomControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? .green : .white.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Up Next queue")

            Spacer()

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.repeatMode.isActive ? .green : .white.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatDescription)

            Spacer()

            Button { player.cyclePlaybackRate() } label: {
                Text(speedLabel)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(player.playbackRate == 1.0 ? .white.opacity(0.4) : .green)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Playback speed \(speedLabel)")

            Spacer()

            Button { showSleepTimer = true } label: {
                Image(systemName: player.sleepTimerActive ? "moon.fill" : "moon")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.sleepTimerActive ? .indigo : .white.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(player.sleepTimerActive ? "On" : "Off")
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheetView()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Lyrics loading
    private func loadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []
            availableLanguages = []
            lyricsLoaded = true
            return
        }
        if lyricsSongID != song.id {
            lyrics = []
            availableLanguages = []
            lyricsSongID = song.id
        }
        lyricsLoaded = false
        let requested = selectedLanguage
        let preferred = preferredLyricsLanguage

        // Folder scan + VTT parse happen off the main thread (they ran on
        // every skip before and stalled the song change).
        let result = await Task.detached(priority: .userInitiated) { () -> (langs: [(code: String, name: String)], chosen: String, lines: [LyricLine]) in
            let langs = song.availableSubtitleLanguages
            let chosen: String
            if !requested.isEmpty, langs.contains(where: { $0.code == requested }) {
                chosen = requested
            } else if !preferred.isEmpty, langs.contains(where: { $0.code == preferred }) {
                chosen = preferred
            } else if langs.contains(where: { $0.code == "lyrics" }) {
                chosen = "lyrics"
            } else {
                chosen = langs.first?.code ?? ""
            }
            let url = (chosen.isEmpty ? nil : song.subtitleFileURL(for: chosen)) ?? song.subtitleFileURL
            let lines = url.map { LyricsParser.parseVTT(fileURL: $0) } ?? []
            return (langs, chosen, lines)
        }.value

        guard !Task.isCancelled, player.currentSong?.id == song.id else { return }
        availableLanguages = result.langs
        if !result.chosen.isEmpty { selectedLanguage = result.chosen }
        lyrics = result.lines
        lyricsLoaded = true
    }
}

// MARK: - Progress bar

/// Scrubbable progress bar. Ticks on its own (not the whole player), shows
/// the drag position while scrubbing and seeks once on release — seeking on
/// every drag sample stuttered the audio.
private struct NowPlayingProgress: View {
    let player: MusicPlayerManager
    let songID: String
    let isPlaying: Bool
    @State private var scrubTime: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !isPlaying || scrubTime != nil)) { _ in
            let duration = player.duration
            let time = scrubTime ?? player.currentTime
            VStack(spacing: -6) {
                bar(time: time, duration: duration)
                HStack {
                    Text(MusicPlayerManager.formatTime(time))
                    Spacer()
                    Text("-" + MusicPlayerManager.formatTime(max(duration - time, 0)))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
            }
        }
        .transaction { $0.animation = nil }
        .id(songID)
        .onChange(of: songID) { scrubTime = nil }
    }

    private func bar(time: TimeInterval, duration: TimeInterval) -> some View {
        let isScrubbing = scrubTime != nil
        return GeometryReader { geo in
            let width = geo.size.width.isFinite ? max(geo.size.width, 0) : 0
            let progress = duration.isFinite && duration > 0 && time.isFinite
                ? min(max(time / duration, 0), 1)
                : 0
            let fillWidth = width * CGFloat(progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: isScrubbing ? 6 : 4)

                Capsule()
                    .fill(.white)
                    .frame(width: max(fillWidth, 0), height: isScrubbing ? 6 : 4)

                if isScrubbing {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(x: max(fillWidth - 7, 0))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard width > 0, duration.isFinite, duration > 0 else { return }
                        let fraction = max(0, min(v.location.x / width, 1))
                        scrubTime = fraction * duration
                    }
                    .onEnded { _ in
                        if let target = scrubTime { player.seek(to: target) }
                        scrubTime = nil
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Song position")
        .accessibilityValue("\(MusicPlayerManager.formatTime(time)) of \(MusicPlayerManager.formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 10
            let target = direction == .increment ? player.currentTime + step : player.currentTime - step
            player.seek(to: max(0, min(target, duration)))
        }
    }
}

// MARK: - Lyrics

/// Synced lyrics. Tracks the active line on its own clock so only this panel
/// re-renders while lyrics are visible.
private struct LyricsPanel: View {
    let player: MusicPlayerManager
    let lyrics: [LyricLine]
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !isPlaying)) { _ in
            let activeId = activeLine(at: player.currentTime)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(lyrics) { line in
                            Text(line.text)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(line.id == activeId ? .white : .white.opacity(0.25))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 40)
                }
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 32)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 32)
                    }
                )
                .onChange(of: activeId) { _, newId in
                    guard let id = newId else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    if let id = activeId { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// Last line whose start time has passed (binary search; lines are sorted).
    private func activeLine(at time: TimeInterval) -> UUID? {
        var lo = 0, hi = lyrics.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics[mid].startTime <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found.map { lyrics[$0].id }
    }
}
