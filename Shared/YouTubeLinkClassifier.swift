// Pure link rules shared by the Download tab and the share extension.
// Compiled into the app, the share extension and the widget (Foundation
// only). Personal builds only: the App Store build must carry no YouTube code.

#if !APP_STORE
import Foundation

enum YouTubeLinkKind: Equatable {
    case video(id: String)
    case playlist(id: String)
    /// `watch?v=…&list=…`: ask the user unless it's a radio/mix (`RD…`).
    case videoInPlaylist(videoId: String, playlistId: String, isMix: Bool)
    case invalid

    /// A song that also belongs to a real (non-mix) playlist: the user
    /// picks "Just this song" or "Whole playlist".
    var offersPlaylistChoice: Bool {
        if case .videoInPlaylist(_, _, let isMix) = self { return !isMix }
        return false
    }
}

enum YouTubeLinkClassifier {
    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Radio mixes (`RD…`, `RDMM…`, `RDAMVM…`) are generated per listener;
    /// sharing one song from them must not pull 50 songs.
    static func isMixList(_ id: String) -> Bool {
        id.hasPrefix("RD")
    }

    static func classify(_ raw: String) -> YouTubeLinkKind {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Share sheets sometimes add text around the link.
        if let token = text.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.lowercased().contains("youtu") }) {
            text = String(token)
        }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text), let host = components.host?.lowercased() else {
            return .invalid
        }
        let isYouTube = host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        guard isYouTube else { return .invalid }

        let items = components.queryItems ?? []
        let path = components.path.split(separator: "/").map(String.init)

        var videoId = items.first(where: { $0.name == "v" })?.value
        if host == "youtu.be" {
            videoId = path.first
        } else if path.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(path[0].lowercased()) {
            videoId = path[1]
        }
        if let candidate = videoId, !isVideoID(candidate) { videoId = nil }

        var listId = items.first(where: { $0.name == "list" })?.value?.trimmingCharacters(in: .whitespaces)
        if let candidate = listId,
           candidate.isEmpty || !candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            listId = nil
        }
        let isPlaylistPage = path.first?.lowercased() == "playlist"

        switch (videoId, listId) {
        case (let video?, let list?):
            if isPlaylistPage { return .playlist(id: list) }
            return .videoInPlaylist(videoId: video, playlistId: list, isMix: isMixList(list))
        case (let video?, nil):
            return .video(id: video)
        case (nil, let list?):
            return .playlist(id: list)
        default:
            return .invalid
        }
    }

    /// The first YouTube link in shared text (a bare URL, or a caption with
    /// the link inside it), trimmed of surrounding punctuation. Nil when the
    /// text has no link `classify` accepts.
    static func firstLink(in text: String) -> String? {
        let separators: (Character) -> Bool = { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }
        for token in text.split(whereSeparator: separators) where token.lowercased().contains("youtu") {
            let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}'.,;!"))
            if classify(candidate) != .invalid { return candidate }
        }
        return nil
    }
}
#endif
