import ActivityKit
import SwiftUI
import WidgetKit

struct SleepTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepTimerActivityAttributes.self) { context in
            SleepTimerActivityView(state: context.state, startedAt: context.attributes.startedAt)
                .padding(18)
                .activityBackgroundTint(Color(red: 0.035, green: 0.045, blue: 0.065))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "owenisas://sleeptimer"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SleepTimerMoonMark(size: 34)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepTimerCountdown(state: context.state)
                        .font(.system(size: 23, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0.62, green: 0.96, blue: 0.79))
                        .frame(width: 96, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SLEEP TIMER")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(context.state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Label(context.state.isPlaying ? "Pause music when time is up" : "Music paused", systemImage: context.state.isPlaying ? "waveform" : "pause.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button(intent: ExtendSleepTimerIntent()) {
                            Text("+15 min")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Extend sleep timer by 15 minutes")
                        Button(intent: CancelSleepTimerIntent()) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel sleep timer")
                    }
                    .padding(.top, 8)
                }
            } compactLeading: {
                Image(systemName: "moon.fill")
                    .foregroundStyle(Color(red: 0.62, green: 0.96, blue: 0.79))
                    .accessibilityLabel("Sleep timer")
            } compactTrailing: {
                SleepTimerCountdown(state: context.state)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: context.state.endOfTrack ? 40 : 48)
            } minimal: {
                Image(systemName: "moon.fill")
                    .foregroundStyle(Color(red: 0.62, green: 0.96, blue: 0.79))
            }
            .keylineTint(Color(red: 0.62, green: 0.96, blue: 0.79))
            .widgetURL(URL(string: "owenisas://sleeptimer"))
        }
    }
}
