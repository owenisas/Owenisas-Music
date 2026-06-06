import SwiftUI

struct SettingsView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @AppStorage("preferredLyricsLanguage") private var preferredLyricsLanguage = ""
    @State private var showSleepTimerPicker = false
    @State private var customMinutes: String = ""

    var body: some View {
        List {
            // Playback Section
            Section {
                // Crossfade
                Toggle(isOn: $player.crossfadeEnabled) {
                    Label {
                        Text("Crossfade")
                    } icon: {
                        Image(systemName: "arrow.right.arrow.left")
                            .foregroundStyle(.green)
                    }
                }
                .tint(.green)

                if player.crossfadeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Duration")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(player.crossfadeDuration))s")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        Slider(value: $player.crossfadeDuration, in: 1...8, step: 1)
                            .tint(.green)
                    }
                }
            } header: {
                Text("Playback")
            }

            // Sleep Timer Section
            Section {
                Button {
                    showSleepTimerPicker = true
                } label: {
                    HStack {
                        Label {
                            Text("Sleep Timer")
                        } icon: {
                            Image(systemName: "moon.fill")
                                .foregroundStyle(.indigo)
                        }
                        .foregroundStyle(.primary)

                        Spacer()

                        if player.sleepTimerActive {
                            Text(player.sleepTimerRemainingFormatted)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                        } else {
                            Text("Off")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if player.sleepTimerActive {
                    Button(role: .destructive) {
                        player.cancelSleepTimer()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Cancel Timer")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("Sleep Timer")
            }

            // Audio Section
            Section {
                HStack {
                    Label {
                        Text("Audio Quality")
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("High")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio")
            }

            // Storage Section
            Section {
                HStack {
                    Label {
                        Text("Storage Used")
                    } icon: {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(storageUsed)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Button {
                    ImageCache.shared.clear()
                } label: {
                    Label {
                        Text("Clear Image Cache")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Storage")
            }

            // About Section
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("2.0.0")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSleepTimerPicker) {
            sleepTimerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sleep Timer Sheet
    private var sleepTimerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ForEach(SleepTimerPreset.allCases, id: \.self) { preset in
                    Button {
                        player.setSleepTimer(minutes: preset.minutes)
                        showSleepTimerPicker = false
                    } label: {
                        HStack {
                            Text(preset.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "moon.zzz")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                // End of track option
                Button {
                    player.setSleepTimerEndOfTrack()
                    showSleepTimerPicker = false
                } label: {
                    HStack {
                        Text("End of Current Track")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSleepTimerPicker = false }
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - Helpers
    private var storageUsed: String {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return "—" }
        let songsFolder = docs.appendingPathComponent("Songs")
        guard let enumerator = fm.enumerator(at: songsFolder, includingPropertiesForKeys: [.fileSizeKey]) else { return "—" }

        var totalSize: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
}

// MARK: - Sleep Timer Presets
enum SleepTimerPreset: CaseIterable {
    case fifteenMin
    case thirtyMin
    case fortyFiveMin
    case oneHour
    case twoHours

    var minutes: Int {
        switch self {
        case .fifteenMin: return 15
        case .thirtyMin: return 30
        case .fortyFiveMin: return 45
        case .oneHour: return 60
        case .twoHours: return 120
        }
    }

    var label: String {
        switch self {
        case .fifteenMin: return "15 minutes"
        case .thirtyMin: return "30 minutes"
        case .fortyFiveMin: return "45 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        }
    }
}
