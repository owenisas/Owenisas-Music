import SwiftUI

// MARK: - Download to Watch

struct PendingDownload: Identifiable {
    let manifest: WatchDownloadManifest
    let plan: WatchTransferPlan
    var id: String { manifest.list.rawValue }
}

/// "Download to Watch" rows for a list: start, progress, retry, remove.
struct DownloadControl: View {
    let list: WatchListRef
    let title: String

    @EnvironmentObject private var offline: OfflineLibrary
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var player: WatchLocalPlayer
    @State private var pending: PendingDownload?
    @State private var isPreparing = false
    @State private var message: String?
    @State private var confirmRemove = false

    // Several List rows; the sheet and dialog hang off the first row of each
    // state (a modifier on a multi-row Group would attach to every row).
    @ViewBuilder
    var body: some View {
        switch offline.state(for: list) {
        case .notDownloaded:
            presenting(
                Button(action: prepare) {
                    ActionLabel(title: "Download to Watch", systemImage: "arrow.down.circle.fill", busy: isPreparing)
                }
                .disabled(isPreparing)
            )

        case .downloading(let progress):
            presenting(DownloadProgressView(progress: progress))
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Text("Cancel Download")
            }

        case .downloaded(let progress):
            presenting(
                NavigationLink(value: WatchRoute.offlineCollection(list)) {
                    ActionLabel(
                        title: "On Watch · \(WatchStorage.format(progress.receivedBytes))",
                        systemImage: "checkmark.circle.fill"
                    )
                }
            )
            Button(action: prepare) {
                ActionLabel(title: "Get New Songs", systemImage: "arrow.triangle.2.circlepath", busy: isPreparing)
            }
            .disabled(isPreparing)

        case .incomplete(let progress):
            presenting(VStack(alignment: .leading, spacing: 2) {
                Label(
                    progress.failed == 1 ? "1 song didn't download" : "\(progress.failed) songs didn't download",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.yellow)
                Text("\(progress.received) of \(progress.total) on this watch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            })
            Button(action: prepare) {
                ActionLabel(title: "Try Again", systemImage: "arrow.clockwise", busy: isPreparing)
            }
            .disabled(isPreparing)
        }

        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func presenting<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $pending) { download in
                DownloadConfirmView(
                    download: download,
                    budgetBytes: offline.budgetBytes,
                    capBytes: offline.capBytes
                ) {
                    start(download)
                }
            }
            .confirmationDialog("Remove \(title) from this watch?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive, action: remove)
            }
    }

    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        message = nil
        Task {
            defer { isPreparing = false }
            do {
                let manifest = try await phone.manifest(for: list)
                let plan = offline.plan(for: manifest)
                if plan.hasWork || !plan.overBudget.isEmpty {
                    pending = PendingDownload(manifest: manifest, plan: plan)
                } else if !plan.alreadyOnWatch.isEmpty || !plan.inFlight.isEmpty {
                    // Everything is already here (e.g. via another playlist).
                    try await offline.startDownload(manifest, plan: plan, phone: phone)
                    message = "Everything is on your watch."
                } else if !plan.unavailable.isEmpty {
                    message = "These songs can't play on Apple Watch."
                } else {
                    message = "No songs to download."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func start(_ download: PendingDownload) {
        Task {
            do {
                try await offline.startDownload(download.manifest, plan: download.plan, phone: phone)
                ArtworkStore.shared.prefetch(download.plan.toTransfer.map(\.id))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func remove() {
        let before = Set(offline.index.tracks.keys)
        offline.remove(list, phone: phone)
        player.forget(before.subtracting(offline.index.tracks.keys))
    }
}

struct ActionLabel: View {
    let title: String
    let systemImage: String
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.owenisasGreen)
            }
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
    }
}

struct DownloadProgressView: View {
    let progress: WatchOfflineProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Downloading", systemImage: "arrow.down.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.owenisasGreen)
            ProgressView(value: progress.fraction)
                .tint(.owenisasGreen)
            Text("\(progress.received) of \(progress.total) · \(WatchStorage.format(progress.receivedBytes)) of \(WatchStorage.format(progress.totalBytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Keep your watch near your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Size check before a download starts.
struct DownloadConfirmView: View {
    let download: PendingDownload
    let budgetBytes: Int64
    let capBytes: Int64
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var plan: WatchTransferPlan { download.plan }
    private var manifest: WatchDownloadManifest { download.manifest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(manifest.title)
                    .font(.headline)
                    .lineLimit(2)

                if plan.hasWork {
                    Text(songCount(plan.toTransfer.count) + " · " + WatchStorage.format(plan.bytesToTransfer))
                        .font(.body.weight(.semibold))
                }

                let alreadyHere = plan.alreadyOnWatch.count + plan.inFlight.count
                if alreadyHere > 0 {
                    note("\(songCount(alreadyHere)) already on this watch.")
                }
                if !plan.overBudget.isEmpty {
                    Label(
                        "\(songCount(plan.overBudget.count)) won't fit the \(WatchStorage.format(capBytes)) limit.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    note("Change the limit in On This Watch › Storage.")
                }
                if !plan.unavailable.isEmpty {
                    note("\(songCount(plan.unavailable.count)) can't play on Apple Watch and will be skipped.")
                }
                if manifest.totalSongsInList > manifest.songs.count {
                    note("Only the first \(manifest.songs.count) of \(manifest.totalSongsInList) songs can be downloaded.")
                }
                if plan.hasWork {
                    note("\(WatchStorage.format(max(0, budgetBytes - plan.bytesToTransfer))) left for music afterwards.")
                }

                Button {
                    confirm()
                    dismiss()
                } label: {
                    Text(plan.hasWork ? "Download" : "Nothing Fits")
                        .frame(maxWidth: .infinity)
                }
                .tint(.owenisasGreen)
                .disabled(!plan.hasWork)
                .padding(.top, 4)
            }
        }
        .navigationTitle("Download")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
}

// MARK: - On This Watch

struct OfflineScreen: View {
    @EnvironmentObject private var offline: OfflineLibrary

    var body: some View {
        List {
            Section {
                StorageSummaryView()
                NavigationLink(value: WatchRoute.storage) {
                    Label("Storage", systemImage: "internaldrive")
                }
            }

            Section("Downloads") {
                if offline.index.collections.isEmpty {
                    EmptyStateView(
                        systemImage: "arrow.down.circle",
                        title: "No Downloads",
                        message: "Open Liked Songs or a playlist and tap Download to Watch."
                    )
                } else {
                    ForEach(offline.index.collections) { collection in
                        NavigationLink(value: WatchRoute.offlineCollection(collection.list)) {
                            CollectionRowView(collection: collection, state: offline.state(for: collection.list))
                        }
                    }
                }
            }
        }
        .navigationTitle("On This Watch")
        .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
        .onAppear { offline.refreshFreeSpace() }
    }
}

struct CollectionRowView: View {
    let collection: WatchOfflineCollection
    let state: WatchOfflineState

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(songID: collection.songIDs.first, size: 32, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 0)
            OfflineBadge(state: state)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state {
        case .notDownloaded:
            EmptyView()
        case .downloading(let p):
            ProgressView(value: p.fraction)
                .tint(.owenisasGreen)
        case .downloaded(let p), .incomplete(let p):
            Text("\(p.received) songs · \(WatchStorage.format(p.receivedBytes))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct StorageSummaryView: View {
    @EnvironmentObject private var offline: OfflineLibrary

    var body: some View {
        let committed = offline.index.committedBytes
        VStack(alignment: .leading, spacing: 4) {
            Gauge(value: WatchStorage.fraction(used: committed, cap: offline.capBytes)) {
                Text("Music")
            }
            .gaugeStyle(.linearCapacity)
            .tint(gaugeTint)
            Text("\(WatchStorage.format(committed)) of \(WatchStorage.format(offline.capBytes))")
                .font(.footnote.weight(.semibold))
            if let free = offline.freeBytes {
                Text("\(WatchStorage.format(free)) free on this watch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            switch offline.storageLevel {
            case .ok:
                EmptyView()
            case .nearlyFull:
                Text("Almost at your limit.")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            case .full:
                Text("Full. Remove music or raise the limit.")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var gaugeTint: Color {
        offline.storageLevel == .ok ? .owenisasGreen : .yellow
    }
}

struct StorageScreen: View {
    @EnvironmentObject private var offline: OfflineLibrary
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var player: WatchLocalPlayer
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            Section {
                StorageSummaryView()
            }

            Section {
                Picker("Limit for Music", selection: $offline.capBytes) {
                    ForEach(WatchStorage.capOptions, id: \.self) { option in
                        Text(WatchStorage.format(option)).tag(option)
                    }
                }
            } footer: {
                Text("Downloads stop at this limit. Lowering it doesn't remove music.")
            }

            if !offline.index.collections.isEmpty {
                Section {
                    Button(role: .destructive) {
                        confirmRemoveAll = true
                    } label: {
                        Label("Remove All Music", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
        .onAppear { offline.refreshFreeSpace() }
        .confirmationDialog("Remove all music from this watch?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                player.stop()
                offline.removeAll(phone: phone)
            }
        }
    }
}

/// A downloaded list: play it on the watch or remove it.
struct OfflineCollectionScreen: View {
    let list: WatchListRef

    @EnvironmentObject private var offline: OfflineLibrary
    @EnvironmentObject private var phone: PhoneLink
    @EnvironmentObject private var player: WatchLocalPlayer
    @EnvironmentObject private var router: WatchRouter
    @State private var confirmRemove = false

    var body: some View {
        let tracks = offline.tracks(in: list)
        let state = offline.state(for: list)
        List {
            if case .downloading(let progress) = state {
                DownloadProgressView(progress: progress)
            }

            if tracks.isEmpty {
                if case .notDownloaded = state {
                    EmptyStateView(systemImage: "arrow.down.circle", title: "Not on This Watch")
                } else if case .downloading = state {
                    EmptyView()
                } else {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Nothing Downloaded", message: "Open the list under On iPhone and tap Try Again.")
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        play(tracks, startAt: 0, shuffled: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        play(tracks, startAt: 0, shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Shuffle")
                }
                .buttonStyle(.bordered)
                .tint(.owenisasGreen)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
                    Button {
                        play(tracks, startAt: position, shuffled: false)
                    } label: {
                        SongRowView(
                            songID: track.id,
                            title: track.title,
                            artist: track.artist,
                            trailingSystemImage: player.current?.id == track.id ? "speaker.wave.2.fill" : nil
                        )
                    }
                }
            }

            if case .incomplete(let progress) = state {
                Text(progress.failed == 1 ? "1 song didn't download." : "\(progress.failed) songs didn't download.")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
            }

            if offline.index.collection(list) != nil {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove from Watch", systemImage: "trash")
                }
            }
        }
        .navigationTitle(offline.index.collection(list)?.title ?? "On Watch")
        .containerBackground(Color.owenisasGreen.gradient, for: .navigation)
        .confirmationDialog("Remove from this watch?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let before = Set(offline.index.tracks.keys)
                offline.remove(list, phone: phone)
                player.forget(before.subtracting(offline.index.tracks.keys))
                if !router.path.isEmpty { router.path.removeLast() }
            }
        }
    }

    private func play(_ tracks: [WatchOfflineTrack], startAt: Int, shuffled: Bool) {
        router.show(.watchNowPlaying)
        Task { await player.play(tracks, startAt: startAt, shuffled: shuffled) }
    }
}

#Preview("On This Watch") {
    NavigationStack {
        OfflineScreen()
    }
    .environmentObject(OfflineLibrary.preview())
    .tint(.owenisasGreen)
}

#Preview("Downloaded list") {
    NavigationStack {
        OfflineCollectionScreen(list: .liked)
    }
    .environmentObject(OfflineLibrary.preview())
    .environmentObject(PhoneLink.preview())
    .environmentObject(WatchLocalPlayer.preview())
    .environmentObject(WatchRouter())
    .tint(.owenisasGreen)
}

#Preview("Download size check") {
    let manifest = WatchDownloadManifest(
        list: .playlist("p1"), title: "Night Drive",
        songs: PreviewFixtures.songs.map { var s = $0; s.bytes = 7_500_000; return s },
        totalSongsInList: 240
    )
    let plan = WatchTransferPlanner.plan(manifest: manifest.songs, onWatch: ["s1"], inFlight: [], budgetBytes: 30_000_000)
    return DownloadConfirmView(
        download: PendingDownload(manifest: manifest, plan: plan),
        budgetBytes: 30_000_000,
        capBytes: WatchStorage.defaultCap
    ) {}
}

#Preview("Storage") {
    NavigationStack {
        StorageScreen()
    }
    .environmentObject(OfflineLibrary.preview())
    .environmentObject(PhoneLink.preview())
    .environmentObject(WatchLocalPlayer.preview())
}
