import Foundation

/// What the share sheet shows. Driven by ShareViewController.
@MainActor
final class ShareSheetModel: ObservableObject {
    enum Phase: Equatable {
        /// Reading the shared items.
        case loading
        #if !APP_STORE
        /// A YouTube link, waiting for "Download".
        case link(String, YouTubeLinkKind)
        /// Shared text/URL without a YouTube link in it.
        case notYouTube
        /// Queued; asking iOS to open the app.
        case opening
        /// Queued, but the app couldn't be opened from here.
        case queued
        #endif
        /// Copying shared audio files into the App Group inbox.
        case savingAudio(Int)
        /// Audio files are in the inbox; the app imports them when it opens.
        case audioSaved(Int)
        /// Nothing usable was shared.
        case nothingToAdd
        case failed(String)
    }

    @Published var phase: Phase = .loading

    #if !APP_STORE
    /// Set by the controller: queue the link with this choice and open the app.
    var onDownload: ((SharedInbox.LinkRequest.Choice?) -> Void)?
    #endif
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
}
