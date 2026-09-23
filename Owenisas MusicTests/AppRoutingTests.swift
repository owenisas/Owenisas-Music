import Foundation
import Testing
@testable import Owenisas_Music

// `owenisas://` links that aren't share hand-offs.
struct AppRoutingTests {

    @Test("Widget link opens the full player")
    func nowPlayingRoute() {
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://nowplaying")!) == .showNowPlaying)
        #expect(IncomingShareURL.action(for: URL(string: "owenisas:nowplaying")!) == .showNowPlaying)
    }

    @Test("Unknown routes and other schemes are ignored")
    func unknownIgnored() {
        #expect(IncomingShareURL.action(for: URL(string: "owenisas://settings")!) == .ignore)
        #expect(IncomingShareURL.action(for: URL(string: "https://nowplaying")!) == .ignore)
    }
}
