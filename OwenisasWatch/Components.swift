import SwiftUI
import WatchKit

/// Brand green (matches the iPhone app's `.tint(.green)`).
extension Color {
    static let owenisasGreen = Color.green
}

// MARK: - Navigation

enum WatchRoute: Hashable {
    case songs(WatchListRef, title: String)
    case playlists
    case phoneNowPlaying
    case watchNowPlaying
    case offline
    case offlineCollection(WatchListRef)
    case storage
}

@MainActor
final class WatchRouter: ObservableObject {
    @Published var path: [WatchRoute] = []

    func show(_ route: WatchRoute) {
        if path.last != route { path.append(route) }
    }
}

// MARK: - Artwork

/// Cover thumbnail with a placeholder; loads from the watch cache or phone.
struct ArtworkView: View {
    let songID: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.owenisasGreen.opacity(0.25))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.owenisasGreen)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: songID) {
            guard let songID else {
                image = nil
                return
            }
            image = ArtworkStore.shared.cachedImage(songID: songID)
            if image == nil {
                image = await ArtworkStore.shared.image(songID: songID)
            }
        }
    }
}

/// Blurred cover behind a screen (watchOS 10 container background).
struct ArtworkBackdrop: View {
    let songID: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.owenisasGreen.opacity(0.55), .black],
                startPoint: .top, endPoint: .bottom
            )
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 18)
                    .overlay(Color.black.opacity(0.5))
            }
        }
        .task(id: songID) {
            guard let songID else {
                image = nil
                return
            }
            image = await ArtworkStore.shared.image(songID: songID)
        }
    }
}

// MARK: - Empty / unreachable states

struct PhoneUnavailableView: View {
    var message: String = "Open Owenisas Music on your iPhone."
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.title2)
                .foregroundStyle(Color.owenisasGreen)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", action: retry)
                    .tint(.owenisasGreen)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.owenisasGreen)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

struct SongRowView: View {
    let songID: String
    let title: String
    let artist: String
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(songID: songID, size: 32, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                Text(artist)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.footnote)
                    .foregroundStyle(Color.owenisasGreen)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Now Playing" entry on the root list.
struct NowPlayingRowView: View {
    let songID: String?
    let title: String
    let subtitle: String
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(songID: songID, size: 36, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.footnote)
                .foregroundStyle(Color.owenisasGreen)
                .accessibilityLabel(isPlaying ? "Playing" : "Paused")
        }
    }
}

// MARK: - Transport

struct TransportControls: View {
    let isPlaying: Bool
    var isBusy = false
    let previous: () -> Void
    let playPause: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: previous) {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .accessibilityLabel("Previous")

            Button(action: playPause) {
                ZStack {
                    Circle()
                        .fill(Color.owenisasGreen)
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 50, height: 50)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .primaryHandGesture()

            Button(action: next) {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
    }
}

struct PlaybackProgressView: View {
    let elapsed: Double
    let duration: Double

    var body: some View {
        VStack(spacing: 2) {
            ProgressView(value: duration > 0 ? min(elapsed / duration, 1) : 0)
                .tint(.owenisasGreen)
            HStack {
                Text(formatTime(elapsed))
                Spacer()
                Text("-" + formatTime(max(0, duration - elapsed)))
            }
            .font(.system(.caption2, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(formatTime(elapsed)) of \(formatTime(duration))")
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

extension View {
    /// Double-tap (Apple Watch Series 9 / Ultra 2 and later) triggers play/pause.
    @ViewBuilder
    func primaryHandGesture() -> some View {
        if #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
    }
}

// MARK: - Digital Crown volume

/// The system volume indicator. Focused, it takes Digital Crown input:
/// `.companion` changes the iPhone's volume, `.local` the watch's own
/// (Bluetooth) output.
struct CrownVolumeControl: WKInterfaceObjectRepresentable {
    enum Target {
        case iPhone
        case watch
    }

    let target: Target

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: target == .iPhone ? .companion : .local)
        control.setTintColor(.green)
        // Focus after the screen settles so the Crown drives volume, not scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak control] in
            control?.focus()
        }
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {}
}
