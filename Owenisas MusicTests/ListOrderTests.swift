import Foundation
import Testing
@testable import Owenisas_Music

// Frozen list order (Recently/Most Played, playlist drag-to-reorder).
struct ListOrderTests {

    private func song(_ id: String) -> SongData {
        SongData(id: id, title: id, audioFilePath: "Songs/\(id)/\(id).mp3")
    }

    @Test("Remembered order wins over the live sort")
    func rememberedOrderWins() {
        let live = [song("c"), song("a"), song("b")] // e.g. c was just played
        let result = live.ordered(like: ["a", "b", "c"])
        #expect(result.map(\.id) == ["a", "b", "c"])
    }

    @Test("Songs not in the remembered order keep their live order at the end")
    func unknownSongsAppendInLiveOrder() {
        let live = [song("new2"), song("b"), song("new1"), song("a")]
        let result = live.ordered(like: ["a", "b"])
        #expect(result.map(\.id) == ["a", "b", "new2", "new1"])
    }

    @Test("Stale ids in the remembered order are ignored")
    func staleIdsIgnored() {
        let live = [song("b"), song("a")]
        let result = live.ordered(like: ["gone", "a", "b"])
        #expect(result.map(\.id) == ["a", "b"])
    }

    @Test("No remembered order leaves the live order untouched")
    func nilOrderIsIdentity() {
        let live = [song("b"), song("a")]
        #expect(live.ordered(like: nil).map(\.id) == ["b", "a"])
    }
}
