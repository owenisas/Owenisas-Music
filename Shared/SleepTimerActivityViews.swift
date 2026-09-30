#if !SHARE_EXTENSION
import SwiftUI

/// Shared native views. The widget uses these directly; render tests use the
/// same layouts with a static clock, not screenshots of a separate mockup.
struct SleepTimerActivityView: View {
    let state: SleepTimerPresentation
    let startedAt: Date
    var compact = false
    var staticClock = false
    var snapshotDate: Date?

    private let mint = Color(red: 0.62, green: 0.96, blue: 0.79)

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            HStack(alignment: .center, spacing: 12) {
                SleepTimerMoonMark(size: compact ? 36 : 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SLEEP TIMER")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(mint)
                    Text(state.title)
                        .font(.system(size: compact ? 14 : 16, weight: .semibold))
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                SleepTimerCountdown(state: state, staticClock: staticClock, snapshotDate: snapshotDate ?? startedAt)
                    .font(.system(size: compact ? 20 : 28, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(mint)
                    .frame(maxWidth: state.endOfTrack ? 82 : 100, alignment: .trailing)
            }
            if let end = state.endDate, end > startedAt {
                Group {
                    if staticClock {
                        // A SwiftUI-only style can be flattened by ImageRenderer.
                        // Runtime keeps the system's autonomous date-driven progress.
                        ProgressView(value: min(1, max(0, end.timeIntervalSince(snapshotDate ?? startedAt) / end.timeIntervalSince(startedAt))))
                            .progressViewStyle(SleepTimerSnapshotProgressStyle(tint: mint))
                    } else {
                        ProgressView(timerInterval: startedAt...end, countsDown: true) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                    }
                }
                .progressViewStyle(.linear)
                .tint(mint)
                .accessibilityLabel("Time remaining")
            }
            HStack(spacing: 8) {
                Label(state.isPlaying ? "Drift off. We'll pause your music." : "Music paused. Timer is still running.", systemImage: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                Spacer(minLength: 2)
                if !compact {
                    Button(intent: ExtendSleepTimerIntent()) {
                        Text("+15 min")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(mint.opacity(0.14), in: Capsule())
                    }
                    .tint(mint)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Extend sleep timer by 15 minutes")
                    Button(intent: CancelSleepTimerIntent()) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel sleep timer")
                }
            }
        }
        .foregroundStyle(.white)
    }
}

private struct SleepTimerSnapshotProgressStyle: ProgressViewStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(tint.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
                }
        }
        .frame(height: 4)
    }
}

struct SleepTimerCountdown: View {
    let state: SleepTimerPresentation
    var staticClock = false
    var snapshotDate: Date?

    var body: some View {
        if state.endOfTrack {
            Text("End of\nsong")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Music will stop at the end of this song")
        } else if staticClock {
            let remaining = max(0, Int(ceil((state.endDate ?? snapshotDate ?? .now).timeIntervalSince(snapshotDate ?? .now))))
            Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
        } else if let end = state.endDate, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text("Done")
                .font(.system(size: 13, weight: .medium))
        }
    }
}

struct SleepTimerMoonMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: "moon.zzz.fill")
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.67, green: 0.99, blue: 0.85), Color(red: 0.62, green: 0.69, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
#endif
