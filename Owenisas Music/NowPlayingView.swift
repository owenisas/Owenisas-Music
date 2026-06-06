import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var isScrubbing = false
    @State private var activeLyricId: UUID?
    @State private var cachedCoverImage: UIImage?
    @State private var selectedLanguage: String = ""
    @State private var availableLanguages: [(code: String, name: String)] = []
    
    @AppStorage("preferredLyricsLanguage") private var preferredLyricsLanguage: String = ""
    @State private var showLanguagePicker = false
    @State private var localCurrentTime: TimeInterval = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AnimatedNowPlayingBackground(image: cachedCoverImage, imagePath: player.currentSong?.coverImageURL?.path)

                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 16)
                    centerContent(geo: geo)
                    Spacer(minLength: 20)

                    songInfoSection
                        .padding(.horizontal, 28)

                    progressSection
                        .padding(.horizontal, 28)
                        .padding(.top, 16)

                    playbackControls
                        .padding(.top, 28)
                        .padding(.bottom, 4)

                    bottomControls
                        .padding(.horizontal, 36)
                        .padding(.top, 12)
                        .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 16 : 24)
                }
            }
        }
        .onAppear {
            loadLyrics()
            loadCoverImage()
        }
        .onChange(of: player.currentSong) {
            loadLyrics()
            loadCoverImage()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if UIApplication.shared.applicationState == .active {
                localCurrentTime = player.currentTime
                updateActiveLyric(time: localCurrentTime)
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
                        loadLyrics(language: lang.code)
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

    // MARK: - Active lyric computation (O(log n) with binary-ish search, called throttled)
    private func updateActiveLyric(time: TimeInterval) {
        guard !lyrics.isEmpty, showLyrics else { return }

        // Find last line where startTime <= time (binary search would be ideal but
        // for typical lyric counts ~50-150, reversed linear is fine and clearer)
        var newId: UUID? = nil
        for line in lyrics.reversed() {
            if line.startTime <= time {
                newId = line.id
                break
            }
        }
        if newId != activeLyricId {
            activeLyricId = newId
        }
    }

    // MARK: - Cover image (cached, loaded once per song)
    private func loadCoverImage() {
        if let path = player.currentSong?.coverImageURL?.path {
            if let cached = ImageCache.shared.cachedImage(for: path) {
                cachedCoverImage = cached
            } else {
                DispatchQueue.global(qos: .utility).async {
                    let image = ImageCache.shared.image(for: path)
                    DispatchQueue.main.async {
                        if self.player.currentSong?.coverImageURL?.path == path {
                            self.cachedCoverImage = image
                        }
                    }
                }
            }
        } else {
            cachedCoverImage = nil
        }
    }

    // MARK: - Dismiss gesture
    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { v in
                if v.translation.height > 0 { dragOffset = v.translation.height }
            }
            .onEnded { v in
                if v.translation.height > 140 { dismiss() }
                dragOffset = 0
            }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial.opacity(0.4), in: Circle())
                }
                Spacer()

                if !lyrics.isEmpty {
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
                    }

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
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        }
    }

    // MARK: - Center Content
    @ViewBuilder
    private func centerContent(geo: GeometryProxy) -> some View {
        let artSize = min(geo.size.width - 56, geo.size.height * 0.42)

        if showLyrics && !lyrics.isEmpty {
            lyricsView
                .frame(height: artSize)
                .padding(.horizontal, 28)
                .transition(.opacity)
        } else {
            albumArt
                .frame(width: artSize, height: artSize)
                .transition(.opacity)
        }
    }

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
    }

    // MARK: - Song Info
    private var songInfoSection: some View {
        HStack(alignment: .center, spacing: 12) {
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

            Spacer()

            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    player.toggleFavorite()
                }
            } label: {
                Image(systemName: player.currentSong?.isFavorited == true ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(player.currentSong?.isFavorited == true ? .pink : .white.opacity(0.5))
                    .scaleEffect(player.currentSong?.isFavorited == true ? 1.1 : 1.0)
            }

            if let song = player.currentSong {
                ShareLink(item: song.title + " - " + song.artist) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Progress (custom bar)
    private var progressSection: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let progress = player.duration.isFinite && player.duration > 0 && localCurrentTime.isFinite
                    ? min(max(localCurrentTime / player.duration, 0), 1)
                    : 0
                let availableWidth = geo.size.width.isFinite ? max(geo.size.width, 0) : 0
                let fillWidth = availableWidth * CGFloat(progress)

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
                .animation(.easeOut(duration: 0.15), value: isScrubbing)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            isScrubbing = true
                            let availableWidth = geo.size.width.isFinite ? max(geo.size.width, 0) : 0
                            guard availableWidth > 0, player.duration.isFinite else { return }
                            let fraction = max(0, min(v.location.x / availableWidth, 1))
                            player.seek(to: fraction * player.duration)
                        }
                        .onEnded { _ in
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(MusicPlayerManager.formatTime(localCurrentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("-" + MusicPlayerManager.formatTime(max(player.duration - localCurrentTime, 0)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
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
            }
            .frame(width: 56, height: 56)

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
            }
            .frame(width: 56, height: 56)

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

    private var bottomControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? .green : .white.opacity(0.4))
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(player.repeatMode.isActive ? .green : .white.opacity(0.4))
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Button { player.cyclePlaybackRate() } label: {
                Text(speedLabel)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(player.playbackRate == 1.0 ? .white.opacity(0.4) : .green)
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("Playback speed \(speedLabel)")

            Spacer()

            Button { showSleepTimer = true } label: {
                Image(systemName: player.sleepTimerActive ? "moon.fill" : "moon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(player.sleepTimerActive ? .indigo : .white.opacity(0.4))
                    .frame(width: 32, height: 32)
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerSheetView()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Lyrics (optimized: pre-computed active ID, no per-line computation)
    private var lyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lyrics) { line in
                        let isActive = line.id == activeLyricId
                        Text(line.text)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(isActive ? .white : .white.opacity(0.25))
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
            .onChange(of: activeLyricId) { _, newId in
                guard let id = newId else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Helpers
    private func loadLyrics(language: String? = nil) {
        guard let song = player.currentSong else {
            lyrics = []
            availableLanguages = []
            activeLyricId = nil
            return
        }

        // Discover available languages
        availableLanguages = song.availableSubtitleLanguages

        // Pick which language to load
        let langToLoad: String
        if let language = language {
            langToLoad = language
        } else if !selectedLanguage.isEmpty,
                  availableLanguages.contains(where: { $0.code == selectedLanguage }) {
            langToLoad = selectedLanguage
        } else if !preferredLyricsLanguage.isEmpty,
                  availableLanguages.contains(where: { $0.code == preferredLyricsLanguage }) {
            langToLoad = preferredLyricsLanguage
        } else if availableLanguages.contains(where: { $0.code == "lyrics" }) {
            langToLoad = "lyrics"
        } else if let first = availableLanguages.first {
            langToLoad = first.code
        } else {
            // Fallback: try the legacy single subtitle file
            if let subtitleURL = song.subtitleFileURL {
                lyrics = LyricsParser.parseVTT(fileURL: subtitleURL)
            } else {
                lyrics = []
            }
            activeLyricId = nil
            return
        }

        selectedLanguage = langToLoad
        if let url = song.subtitleFileURL(for: langToLoad) {
            lyrics = LyricsParser.parseVTT(fileURL: url)
        } else if let subtitleURL = song.subtitleFileURL {
            lyrics = LyricsParser.parseVTT(fileURL: subtitleURL)
        } else {
            lyrics = []
        }
        activeLyricId = nil
    }
}
