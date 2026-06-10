import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var player = MusicPlayerManager.shared
    @ObservedObject var dataManager = DataManager.shared
    @AppStorage("preferredLyricsLanguage") private var preferredLyricsLanguage = ""
    @State private var showSleepTimerPicker = false
    @State private var customMinutes: String = ""
    @State private var backupDocument: JSONBackupDocument?
    @State private var showBackupExporter = false
    @State private var showBackupImporter = false
    @State private var backupResultMessage = ""
    @State private var showBackupResult = false

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

                // Playback speed
                Picker(selection: $player.playbackRate) {
                    ForEach(MusicPlayerManager.playbackRatePresets, id: \.self) { rate in
                        Text(Self.formatRate(rate)).tag(rate)
                    }
                } label: {
                    Label {
                        Text("Playback Speed")
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .foregroundStyle(.green)
                    }
                }
                .tint(.green)
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

            // Your Activity
            Section {
                NavigationLink {
                    StatsView()
                } label: {
                    Label {
                        Text("Your Stats")
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Your Activity")
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

            // Your Data Section (local-first: everything exportable, nothing locked in)
            Section {
                Button {
                    if let data = dataManager.exportBackupData() {
                        backupDocument = JSONBackupDocument(data: data)
                        showBackupExporter = true
                    } else {
                        backupResultMessage = "Nothing to back up yet."
                        showBackupResult = true
                    }
                } label: {
                    Label {
                        Text("Back Up Library Data")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.green)
                    }
                    .foregroundStyle(.primary)
                }

                Button {
                    showBackupImporter = true
                } label: {
                    Label {
                        Text("Restore from Backup")
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.green)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Your Data")
            } footer: {
                Text("Saves playlists, likes, and play history as a JSON file you own. Audio files already live in Files ▸ On My iPhone ▸ Owenisas Music.")
            }

            // About Section
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("2.1.0")
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
        .fileExporter(
            isPresented: $showBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: backupFilename
        ) { result in
            if case .success = result {
                Haptics.success()
                backupResultMessage = "Backup saved."
                showBackupResult = true
            }
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json]
        ) { result in
            handleBackupImport(result)
        }
        .alert("Library Backup", isPresented: $showBackupResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupResultMessage)
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Owenisas-Music-Backup-\(formatter.string(from: .now))"
    }

    private func handleBackupImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let outcome = dataManager.importBackupData(data) else {
                Haptics.warning()
                backupResultMessage = "Couldn't read that backup file."
                showBackupResult = true
                return
            }
            Haptics.success()
            var parts = ["Restored \(outcome.matchedSongs) of \(outcome.totalSongs) songs' history and likes."]
            if outcome.newPlaylists > 0 {
                parts.append("Recreated \(outcome.newPlaylists) playlist\(outcome.newPlaylists == 1 ? "" : "s").")
            }
            if outcome.matchedSongs < outcome.totalSongs {
                parts.append("Songs not yet downloaded on this device were skipped.")
            }
            backupResultMessage = parts.joined(separator: " ")
        case .failure(let error):
            Haptics.warning()
            backupResultMessage = "Restore failed: \(error.localizedDescription)"
        }
        showBackupResult = true
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
    static func formatRate(_ rate: Float) -> String {
        let trimmed = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate))
            : String(rate).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(trimmed)×"
    }

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
