import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// Mirrors the player's now-playing state into the App Group for the
/// widgets and the Control Center control, and runs the playback intents
/// those surfaces trigger (see Shared/PlaybackIntents.swift).
///
/// Writes happen on song change, play/pause, favourite, speed change and
/// seeks (caught by a cheap drift check) — never per progress tick. Bursts
/// are coalesced and widget reloads are rate-limited. Artwork work runs on a
/// background queue. All other state is main-thread only.
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()

    private let store: NowPlayingStore
    private let ioQueue = DispatchQueue(label: "com.Owenisas-Music.now-playing", qos: .utility)
    private var scheduler = NowPlayingReloadScheduler()
    private var pendingFlush: DispatchWorkItem?
    /// Last snapshot handed to the widgets (main thread).
    private var lastPublished: NowPlayingSnapshot?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// How often to compare the real position with the published projection.
    static let driftCheckInterval: TimeInterval = 5

    init(store: NowPlayingStore = .shared) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        guard !started else { return }
        started = true

        let player = MusicPlayerManager.shared
        // @Published fires in willSet, so these only *signal*; the flush reads
        // the settled player state later.
        Publishers.MergeMany(
            player.$currentSong.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            player.$duration.map { _ in () }.eraseToAnyPublisher(),
            player.$playbackRate.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.playerDidChange() }
        .store(in: &cancellables)

        // Seeks don't publish anything; a periodic comparison catches them
        // (and anything else missed) without per-tick widget writes.
        Timer.publish(every: Self.driftCheckInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkDrift() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.flushPendingNow() }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.publishTerminated() }
            .store(in: &cancellables)
    }

    // MARK: - Intents (app process)

    /// Runs a widget / Control Center / Shortcuts command, then publishes the
    /// result before returning so the system's post-intent widget reload
    /// already sees it.
    @MainActor
    func perform(_ command: PlaybackCommand) async {
        start()
        let player = MusicPlayerManager.shared
        if player.currentSong == nil {
            // Launched in the background by the intent: give the app a
            // moment to restore its session before giving up.
            for _ in 0..<15 where player.currentSong == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        switch command {
        case .play:
            if !player.isPlaying { player.togglePlayPause() }
        case .pause: player.pause()
        case .likeCurrent:
            if player.currentSong?.isFavorited == false { player.toggleFavorite() }
        case .togglePlayPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .toggleFavorite: player.toggleFavorite()
        }
        await publishNow()
    }

    // MARK: - Scheduling

    private func playerDidChange() {
        let now = Date()
        guard let fireDate = scheduler.noteChange(at: now) else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush(force: false) }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fireDate.timeIntervalSince(now)), execute: work)
    }

    private func checkDrift() {
        guard pendingFlush == nil, let last = lastPublished, last.hasSong else { return }
        if makeSnapshot(at: Date()).needsWidgetReload(comparedTo: last) {
            playerDidChange()
        }
    }

    private func flushPendingNow() {
        guard let work = pendingFlush else { return }
        work.cancel()
        flush(force: false)
    }

    private func flush(force: Bool) {
        pendingFlush?.cancel()
        pendingFlush = nil
        let now = Date()
        let snapshot = makeSnapshot(at: now)
        guard force || snapshot.needsWidgetReload(comparedTo: lastPublished) else {
            scheduler.cancelPending()
            return
        }
        lastPublished = snapshot
        scheduler.didReload(at: now)
        let cover = MusicPlayerManager.shared.currentSong?.coverImageURL
        ioQueue.async { [store] in
            Self.write(snapshot, cover: cover, to: store)
        }
    }

    /// Immediate publish (intents): skips the debounce, waits for the write.
    @MainActor
    private func publishNow() async {
        pendingFlush?.cancel()
        pendingFlush = nil
        let now = Date()
        let snapshot = makeSnapshot(at: now)
        lastPublished = snapshot
        scheduler.didReload(at: now)
        let cover = MusicPlayerManager.shared.currentSong?.coverImageURL
        let store = store
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                Self.write(snapshot, cover: cover, to: store)
                continuation.resume()
            }
        }
    }

    /// The process is going away: a "playing" record would lie until the
    /// projected end of the track, so record a pause synchronously.
    private func publishTerminated() {
        pendingFlush?.cancel()
        pendingFlush = nil
        var snapshot = makeSnapshot(at: Date())
        snapshot.isPlaying = false
        lastPublished = snapshot
        ioQueue.sync {
            _ = store.save(snapshot)
        }
        Self.reloadWidgets()
    }

    // MARK: - Snapshot

    private func makeSnapshot(at date: Date) -> NowPlayingSnapshot {
        let player = MusicPlayerManager.shared
        guard let song = player.currentSong else { return .notPlaying(at: date) }
        return NowPlayingSnapshot(
            songID: song.id,
            title: song.title,
            artist: song.artist,
            isPlaying: player.isPlaying,
            isFavorited: song.isFavorited,
            elapsed: player.currentTime,
            duration: player.duration,
            playbackRate: Double(player.playbackRate),
            updatedAt: date,
            artworkFileName: song.coverImageURL == nil ? nil : NowPlayingStore.artworkFileName(forSongID: song.id)
        )
    }

    /// I/O queue: artwork first, so the widget never reads a record whose image isn't there yet.
    private static func write(_ snapshot: NowPlayingSnapshot, cover: URL?, to store: NowPlayingStore) {
        var snapshot = snapshot
        if let name = snapshot.artworkFileName {
            if let cover, let destination = store.artworkURL(named: name),
               NowPlayingArtwork.ensureThumbnail(from: cover, at: destination) {
                NowPlayingArtwork.prune(directory: store.artworkDirectory, keeping: name)
            } else {
                snapshot.artworkFileName = nil
            }
        }
        store.save(snapshot)
        reloadWidgets()
    }

    private static func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingWidgetKind.nowPlaying)
        ControlCenter.shared.reloadControls(ofKind: NowPlayingWidgetKind.playPauseControl)
    }
}

// MARK: - Reload scheduling (pure, unit-tested)

/// Coalesces bursts of player changes into one widget write and keeps
/// reloads at least `minimumInterval` apart.
///
/// A song change fires several publishers in a row (song, duration, play
/// state); the first opens a short window, the rest ride along, and the
/// flush reads the settled state at the end of it.
struct NowPlayingReloadScheduler {
    var debounce: TimeInterval = 0.3
    var minimumInterval: TimeInterval = 1.0
    private(set) var lastReload: Date?
    private(set) var pendingFireDate: Date?

    /// Records a change at `now`. Returns when to flush, or nil when a flush
    /// is already pending (it will pick this change up).
    mutating func noteChange(at now: Date) -> Date? {
        guard pendingFireDate == nil else { return nil }
        var fire = now.addingTimeInterval(debounce)
        if let lastReload {
            fire = max(fire, lastReload.addingTimeInterval(minimumInterval))
        }
        pendingFireDate = fire
        return fire
    }

    /// A flush wrote and reloaded at `date`.
    mutating func didReload(at date: Date) {
        pendingFireDate = nil
        lastReload = date
    }

    /// A flush found nothing new to publish.
    mutating func cancelPending() {
        pendingFireDate = nil
    }
}

// MARK: - Artwork

/// Small JPEG copies of cover art in the App Group, one per song id.
enum NowPlayingArtwork {
    static let maxPixelSize = 300
    /// Recent covers kept besides the current one, so skipping back and
    /// forth doesn't re-encode.
    static let keepRecent = 4

    /// Makes sure `destination` holds a thumbnail of `source` no older than
    /// it. Returns false when the cover can't be read.
    @discardableResult
    static func ensureThumbnail(from source: URL, at destination: URL, maxPixelSize: Int = maxPixelSize) -> Bool {
        let fm = FileManager.default
        if let artDate = modificationDate(of: destination) {
            let coverDate = modificationDate(of: source) ?? .distantPast
            if artDate >= coverDate {
                // Fresh: bump it so pruning treats it as recently used.
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                return true
            }
        }
        guard let data = thumbnailJPEG(from: source, maxPixelSize: maxPixelSize) else { return false }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Downsampled JPEG of an image file, longest side ≤ `maxPixelSize`.
    static func thumbnailJPEG(from source: URL, maxPixelSize: Int = maxPixelSize) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        var thumbnail: CGImage?
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) {
            thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        }
        if thumbnail == nil, let image = UIImage(contentsOfFile: source.path) {
            // Formats ImageIO can't thumbnail: redraw via UIKit.
            thumbnail = redraw(image, maxPixelSize: maxPixelSize)
        }
        guard let cgImage = thumbnail else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Deletes all but `current` and the `keepRecent` most recently used covers.
    static func prune(directory: URL?, keeping current: String, keepRecent: Int = keepRecent) {
        guard let directory else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let others = files
            .filter { $0.lastPathComponent != current }
            .sorted { (modificationDate(of: $0) ?? .distantPast) > (modificationDate(of: $1) ?? .distantPast) }
        for stale in others.dropFirst(max(0, keepRecent)) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func redraw(_ image: UIImage, maxPixelSize: Int) -> CGImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixelSize) / max(pixelWidth, pixelHeight))
        let size = CGSize(width: max(1, (pixelWidth * scale).rounded()), height: max(1, (pixelHeight * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Uncached (URL resource values can be served stale from the URL's cache).
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
