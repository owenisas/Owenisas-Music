import SwiftUI

/// Compact share sheet: what was shared, and one or two actions.
struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                content
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Owenisas Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if showsCancel {
                        Button("Cancel") { model.onCancel?() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if showsDone {
                        Button("Done") { model.onDone?() }
                            .accessibilityIdentifier("shareDoneButton")
                    }
                }
            }
        }
        .tint(.green)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading what you shared…")
                    .foregroundStyle(.secondary)
            }
        #if !APP_STORE
        case .link(let link, let kind):
            linkContent(link: link, kind: kind)
        case .notYouTube:
            message(
                title: "Not a YouTube link",
                detail: "Owenisas Music can download songs and playlists from youtube.com, youtu.be and music.youtube.com links. Share one of those, or an audio file."
            )
        case .opening:
            HStack(spacing: 10) {
                ProgressView()
                Text("Opening Owenisas Music…")
                    .foregroundStyle(.secondary)
            }
        case .queued:
            message(
                title: "Added \u{2014} it starts next time you open Owenisas Music",
                detail: "The download is queued in the app."
            )
        #endif
        case .savingAudio(let count):
            HStack(spacing: 10) {
                ProgressView()
                Text(count == 1 ? "Adding the song…" : "Adding \(count) songs…")
                    .foregroundStyle(.secondary)
            }
        case .audioSaved(let count):
            message(
                title: count == 1 ? "Song added" : "\(count) songs added",
                detail: "They'll be in your library next time you open Owenisas Music."
            )
        case .nothingToAdd:
            message(title: "Nothing to add", detail: "Share an audio file to add it to your library.")
        case .failed(let reason):
            message(title: "Couldn't add this", detail: reason)
        }
    }

    #if !APP_STORE
    @ViewBuilder
    private func linkContent(link: String, kind: YouTubeLinkKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Download with Owenisas Music", systemImage: "arrow.down.circle")
                .font(.headline)
            Text(link)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("shareDetectedLink")
        }

        if kind.offersPlaylistChoice {
            Text("This song is part of a playlist.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                actionButton("Just this song", identifier: "shareJustThisSong") { model.onDownload?(.song) }
                actionButton("Whole playlist", identifier: "shareWholePlaylist") { model.onDownload?(.playlist) }
            }
        } else {
            let label: String = {
                if case .playlist = kind { return "Download playlist" }
                return "Download"
            }()
            Button {
                model.onDownload?(nil)
            } label: {
                Text(label)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("shareDownloadButton")
        }
    }

    private func actionButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
    }
    #endif

    private func message(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("shareMessageTitle")
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsCancel: Bool {
        switch model.phase {
        case .loading, .savingAudio: return true
        #if !APP_STORE
        case .link, .opening: return true
        #endif
        default: return false
        }
    }

    private var showsDone: Bool {
        switch model.phase {
        case .audioSaved, .nothingToAdd, .failed: return true
        #if !APP_STORE
        case .notYouTube, .queued: return true
        #endif
        default: return false
        }
    }
}
