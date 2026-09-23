// Now Playing widget views. They live in Shared/ (compiled into the app and
// the widget, not the share extension) so the app-hosted unit tests can
// render every family with ImageRenderer. The Widget / ControlWidget
// definitions themselves are in OwenisasWidget/.
#if !SHARE_EXTENSION
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artwork: UIImage?

    /// Current state from the App Group, as it should read at `date`.
    static func load(at date: Date = Date(), store: NowPlayingStore = .shared) -> NowPlayingEntry {
        let snapshot = store.load().resolved(at: date)
        return NowPlayingEntry(date: date, snapshot: snapshot, artwork: loadArtwork(snapshot, store: store))
    }

    static func loadArtwork(_ snapshot: NowPlayingSnapshot, store: NowPlayingStore = .shared) -> UIImage? {
        guard snapshot.hasSong, let url = store.artworkURL(named: snapshot.artworkFileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

extension NowPlayingSnapshot {
    /// Gallery / preview content.
    static func preview(isPlaying: Bool = true, isFavorited: Bool = true, at date: Date = Date()) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            songID: "preview",
            title: "Golden Hour Drive",
            artist: "Owenisas",
            isPlaying: isPlaying,
            isFavorited: isFavorited,
            elapsed: 83,
            duration: 214,
            playbackRate: 1,
            updatedAt: date
        )
    }
}

// MARK: - Static rendering

/// ImageRenderer can't draw timer-driven progress views or the Lock Screen
/// accessory backdrop; unit-test renders set this to swap in plain shapes of
/// the same size. Widgets never set it.
private struct NowPlayingStaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var nowPlayingStaticRendering: Bool {
        get { self[NowPlayingStaticRenderingKey.self] }
        set { self[NowPlayingStaticRenderingKey.self] = newValue }
    }
}

// MARK: - Style

enum NowPlayingStyle {
    static let accent = Color.green
    static let liked = Color.pink
    static let base = Color(white: 0.07)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let placeholderFill = Color(white: 0.16)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Root

/// Picks the layout for `family`.
struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .systemSmall:
            NowPlayingSmallView(entry: entry)
        case .accessoryRectangular:
            NowPlayingRectangularView(snapshot: entry.snapshot)
        case .accessoryCircular:
            NowPlayingCircularView(snapshot: entry.snapshot)
        case .accessoryInline:
            NowPlayingInlineView(snapshot: entry.snapshot)
        default:
            NowPlayingMediumView(entry: entry)
        }
    }
}

/// Home Screen background: the cover, blurred and dimmed like the app's
/// mini player, over near-black. Dropped by the system in tinted/clear modes.
struct NowPlayingBackground: View {
    let artwork: UIImage?

    var body: some View {
        ZStack {
            NowPlayingStyle.base
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 28)
                    .overlay(Color.black.opacity(0.62))
            }
        }
    }
}

// MARK: - Building blocks

struct NowPlayingArtworkTile: View {
    let artwork: UIImage?
    let cornerRadius: CGFloat
    var glyphSize: CGFloat = 20

    var body: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                NowPlayingStyle.placeholderFill
                Image(systemName: "music.note")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Linear progress that advances by itself while playing.
struct NowPlayingProgressBar: View {
    let snapshot: NowPlayingSnapshot
    let date: Date
    @Environment(\.nowPlayingStaticRendering) private var renderStatically

    var body: some View {
        Group {
            if renderStatically {
                Capsule()
                    .fill(Color.gray.opacity(0.45))
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(NowPlayingStyle.accent)
                                .frame(width: geo.size.width * snapshot.fractionComplete(at: date))
                        }
                    }
                    .frame(height: 4)
            } else if let interval = snapshot.playbackInterval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: snapshot.fractionComplete(at: date))
            }
        }
        .progressViewStyle(.linear)
        .tint(NowPlayingStyle.accent)
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}

/// Elapsed (live while playing) and total time under the medium progress bar.
struct NowPlayingTimeLabels: View {
    let snapshot: NowPlayingSnapshot
    let date: Date

    var body: some View {
        HStack {
            Group {
                if let interval = snapshot.playbackInterval {
                    Text(timerInterval: interval, countsDown: false)
                } else {
                    Text(Self.format(snapshot.elapsed(at: date)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.format(snapshot.duration))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(NowPlayingStyle.secondaryText)
        .accessibilityHidden(true)
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PlayPauseButton: View {
    let isPlaying: Bool
    var size: CGFloat = 22
    var frame: CGFloat = 40

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(NowPlayingStyle.accent)
                .frame(width: frame, height: frame)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .widgetAccentable()
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct SkipButton: View {
    let forward: Bool
    var size: CGFloat = 16
    var frame: CGFloat = 36

    var body: some View {
        Group {
            if forward {
                Button(intent: NextTrackIntent()) { glyph }
            } else {
                Button(intent: PreviousTrackIntent()) { glyph }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Next song" : "Previous song")
    }

    private var glyph: some View {
        Image(systemName: forward ? "forward.fill" : "backward.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(NowPlayingStyle.primaryText.opacity(0.9))
            .frame(width: frame, height: frame)
            .contentShape(Rectangle())
    }
}

struct LikeButton: View {
    let isFavorited: Bool

    var body: some View {
        Button(intent: ToggleFavoriteIntent()) {
            Image(systemName: isFavorited ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFavorited ? NowPlayingStyle.liked : NowPlayingStyle.primaryText.opacity(0.9))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorited ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

// MARK: - Home Screen

struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        let snapshot = entry.snapshot
        if snapshot.hasSong {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    NowPlayingArtworkTile(artwork: entry.artwork, cornerRadius: 10)
                        .frame(width: 54, height: 54)
                    Spacer(minLength: 2)
                    PlayPauseButton(isPlaying: snapshot.isPlaying, size: 22, frame: 36)
                    SkipButton(forward: true, size: 15, frame: 30)
                }
                Spacer(minLength: 6)
                Text(snapshot.title)
                    .font(NowPlayingStyle.rounded(15))
                    .foregroundStyle(NowPlayingStyle.primaryText)
                    .lineLimit(1)
                Text(snapshot.artist)
                    .font(NowPlayingStyle.rounded(12, .medium))
                    .foregroundStyle(NowPlayingStyle.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 1)
                NowPlayingProgressBar(snapshot: snapshot, date: entry.date)
                    .padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "music.note")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(NowPlayingStyle.accent)
                    .widgetAccentable()
                Spacer(minLength: 6)
                Text("Nothing playing")
                    .font(NowPlayingStyle.rounded(16))
                    .foregroundStyle(NowPlayingStyle.primaryText)
                Text("Tap to open")
                    .font(NowPlayingStyle.rounded(12, .medium))
                    .foregroundStyle(NowPlayingStyle.secondaryText)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        let snapshot = entry.snapshot
        HStack(spacing: 14) {
            NowPlayingArtworkTile(artwork: snapshot.hasSong ? entry.artwork : nil, cornerRadius: 12, glyphSize: 34)
                .frame(maxHeight: .infinity)
            if snapshot.hasSong {
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.title)
                        .font(NowPlayingStyle.rounded(17))
                        .foregroundStyle(NowPlayingStyle.primaryText)
                        .lineLimit(2)
                    Text(snapshot.artist)
                        .font(NowPlayingStyle.rounded(13, .medium))
                        .foregroundStyle(NowPlayingStyle.secondaryText)
                        .lineLimit(1)
                        .padding(.top, 2)
                    Spacer(minLength: 4)
                    NowPlayingProgressBar(snapshot: snapshot, date: entry.date)
                    NowPlayingTimeLabels(snapshot: snapshot, date: entry.date)
                        .padding(.top, 4)
                    HStack(spacing: 0) {
                        LikeButton(isFavorited: snapshot.isFavorited)
                        Spacer(minLength: 0)
                        SkipButton(forward: false, size: 17, frame: 38)
                        Spacer(minLength: 0)
                        PlayPauseButton(isPlaying: snapshot.isPlaying, size: 26, frame: 42)
                        Spacer(minLength: 0)
                        SkipButton(forward: true, size: 17, frame: 38)
                    }
                    .padding(.top, 2)
                    .padding(.trailing, -6)
                    .padding(.leading, -6)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing playing")
                        .font(NowPlayingStyle.rounded(17))
                        .foregroundStyle(NowPlayingStyle.primaryText)
                    Text("Tap to open Owenisas Music")
                        .font(NowPlayingStyle.rounded(13, .medium))
                        .foregroundStyle(NowPlayingStyle.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Lock Screen

struct NowPlayingRectangularView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        if snapshot.hasSong {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .widgetAccentable()
                    Text(snapshot.artist)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    NowPlayingProgressBar(snapshot: snapshot, date: snapshot.updatedAt)
                        .padding(.top, 3)
                }
                Spacer(minLength: 0)
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
                .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Label("Owenisas Music", systemImage: "music.note")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Nothing playing")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NowPlayingCircularView: View {
    let snapshot: NowPlayingSnapshot
    @Environment(\.nowPlayingStaticRendering) private var renderStatically

    var body: some View {
        if snapshot.hasSong {
            // On the Lock Screen only a tap on the button's label runs the
            // intent; anything else in the label area launches the app. So the
            // backdrop and ring stay outside and the label is the glyph,
            // stretched over the whole slot.
            ZStack {
                backdrop
                ring
                    .padding(3)
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
                .accessibilityLabel(snapshot.isPlaying ? "Pause \(snapshot.title)" : "Play \(snapshot.title)")
            }
        } else {
            ZStack {
                backdrop
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .bold))
            }
            .accessibilityLabel("Owenisas Music, nothing playing")
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if renderStatically {
            Circle().fill(Color.white.opacity(0.18))
        } else {
            AccessoryWidgetBackground()
        }
    }

    @ViewBuilder
    private var ring: some View {
        if renderStatically {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: snapshot.fractionComplete(at: snapshot.updatedAt))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
        } else if let interval = snapshot.playbackInterval {
            ProgressView(timerInterval: interval, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        } else {
            ProgressView(value: snapshot.fractionComplete(at: snapshot.updatedAt))
                .progressViewStyle(.circular)
                .widgetAccentable()
        }
    }
}

struct NowPlayingInlineView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        if snapshot.hasSong {
            Label(snapshot.title, systemImage: snapshot.isPlaying ? "play.fill" : "pause.fill")
        } else {
            Label("Nothing playing", systemImage: "music.note")
        }
    }
}
#endif
