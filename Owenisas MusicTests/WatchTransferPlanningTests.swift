import Foundation
import Testing
@testable import Owenisas_Music

// Deciding which songs a "Download to Watch" sends.
struct WatchTransferPlanningTests {

    private func song(_ id: String, _ megabytes: Int64?) -> WatchSongItem {
        WatchSongItem(
            id: id, title: id, artist: "A", duration: 200, isFavorited: false,
            bytes: megabytes.map { $0 * WatchStorage.megabyte }, hasArtwork: false
        )
    }

    @Test("Everything fits: all songs planned in list order")
    func allFit() {
        let songs = [song("a", 5), song("b", 6), song("c", 7)]
        let plan = WatchTransferPlanner.plan(manifest: songs, onWatch: [], inFlight: [], budgetBytes: 100 * WatchStorage.megabyte)
        #expect(plan.toTransfer.map(\.id) == ["a", "b", "c"])
        #expect(plan.bytesToTransfer == 18 * WatchStorage.megabyte)
        #expect(plan.fitsEntirely)
        #expect(plan.hasWork)
    }

    @Test("Songs already stored or on their way are skipped")
    func skipsPresentAndInFlight() {
        let songs = [song("a", 5), song("b", 5), song("c", 5)]
        let plan = WatchTransferPlanner.plan(manifest: songs, onWatch: ["a"], inFlight: ["c"], budgetBytes: .max)
        #expect(plan.toTransfer.map(\.id) == ["b"])
        #expect(plan.alreadyOnWatch == ["a"])
        #expect(plan.inFlight == ["c"])
    }

    @Test("Over budget: keeps taking later songs that still fit")
    func budgetGreedyInOrder() {
        let songs = [song("a", 40), song("big", 70), song("b", 30), song("c", 40)]
        let plan = WatchTransferPlanner.plan(manifest: songs, onWatch: [], inFlight: [], budgetBytes: 100 * WatchStorage.megabyte)
        #expect(plan.toTransfer.map(\.id) == ["a", "b"])
        #expect(plan.overBudget.map(\.id) == ["big", "c"])
        #expect(plan.bytesToTransfer <= 100 * WatchStorage.megabyte)
        #expect(plan.bytesOverBudget == 110 * WatchStorage.megabyte)
        #expect(!plan.fitsEntirely)
    }

    @Test("A song exactly filling the budget fits")
    func exactFit() {
        let plan = WatchTransferPlanner.plan(manifest: [song("a", 10)], onWatch: [], inFlight: [], budgetBytes: 10 * WatchStorage.megabyte)
        #expect(plan.toTransfer.map(\.id) == ["a"])
    }

    @Test("Zero or negative budget plans nothing")
    func noBudget() {
        let songs = [song("a", 1)]
        #expect(WatchTransferPlanner.plan(manifest: songs, onWatch: [], inFlight: [], budgetBytes: 0).toTransfer.isEmpty)
        let negative = WatchTransferPlanner.plan(manifest: songs, onWatch: [], inFlight: [], budgetBytes: -50)
        #expect(negative.overBudget.map(\.id) == ["a"])
        #expect(!negative.hasWork)
    }

    @Test("Songs without a usable file are reported, not sent")
    func unavailableSongs() {
        let songs = [song("ok", 3), song("webm", nil), song("empty", 0)]
        let plan = WatchTransferPlanner.plan(manifest: songs, onWatch: [], inFlight: [], budgetBytes: .max)
        #expect(plan.toTransfer.map(\.id) == ["ok"])
        #expect(plan.unavailable == ["webm", "empty"])
    }

    @Test("Duplicate ids in a manifest are planned once")
    func duplicates() {
        let plan = WatchTransferPlanner.plan(manifest: [song("a", 5), song("a", 5)], onWatch: [], inFlight: [], budgetBytes: .max)
        #expect(plan.toTransfer.map(\.id) == ["a"])
    }

    // MARK: Phone-side queue

    @Test("Phone queues available songs once, skipping outstanding transfers")
    func phoneQueue() {
        let ack = WatchTransferPlanner.queue(
            requested: ["a", "b", "a", "gone", "c"],
            available: ["a", "b", "c"],
            outstanding: ["b"]
        )
        #expect(ack.queued == ["a", "c"])
        #expect(ack.alreadyQueued == ["b"])
        #expect(ack.unavailable == ["gone"])
    }

    @Test("An empty request queues nothing")
    func emptyQueue() {
        let ack = WatchTransferPlanner.queue(requested: [], available: ["a"], outstanding: [])
        #expect(ack == WatchTransferAck(queued: [], alreadyQueued: [], unavailable: []))
    }
}
