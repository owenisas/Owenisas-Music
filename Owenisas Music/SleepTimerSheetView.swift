import SwiftUI

struct SleepTimerSheetView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if player.sleepTimerActive {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.indigo)

                        Text("Timer Active")
                            .font(.system(size: 18, weight: .bold))

                        Text(player.sleepTimerRemainingFormatted)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)

                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            dismiss()
                        } label: {
                            Text("Cancel Timer")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        .padding(.top, 8)
                    }
                    .padding(.top, 20)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.indigo)

                        Text("Sleep Timer")
                            .font(.system(size: 18, weight: .bold))

                        Text("Music will stop after the selected time")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }

                if !player.sleepTimerActive {
                    VStack(spacing: 10) {
                        ForEach(SleepTimerPreset.allCases, id: \.self) { preset in
                            Button {
                                player.setSleepTimer(minutes: preset.minutes)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(preset.label)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "moon.zzz")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 13)
                                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        Button {
                            player.setSleepTimerEndOfTrack()
                            dismiss()
                        } label: {
                            HStack {
                                Text("End of Current Track")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 13)
                            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.green)
                }
            }
        }
    }
}
