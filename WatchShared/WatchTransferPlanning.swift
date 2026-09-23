import Foundation

/// What a "Download to Watch" will actually send.
struct WatchTransferPlan: Equatable {
    /// Songs to request, in list order.
    var toTransfer: [WatchSongItem] = []
    /// Already stored on the watch.
    var alreadyOnWatch: [String] = []
    /// Already on its way for another download.
    var inFlight: [String] = []
    /// Don't fit the storage budget.
    var overBudget: [WatchSongItem] = []
    /// No usable audio file on the phone.
    var unavailable: [String] = []

    var bytesToTransfer: Int64 { toTransfer.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var bytesOverBudget: Int64 { overBudget.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var fitsEntirely: Bool { overBudget.isEmpty }
    var hasWork: Bool { !toTransfer.isEmpty }
}

enum WatchTransferPlanner {
    /// Plan a download on the watch. Walks the list in order and takes every
    /// song that still fits the budget (a later, smaller song can still fit
    /// after a big one didn't).
    static func plan(
        manifest songs: [WatchSongItem],
        onWatch: Set<String>,
        inFlight: Set<String>,
        budgetBytes: Int64
    ) -> WatchTransferPlan {
        var plan = WatchTransferPlan()
        var remaining = max(0, budgetBytes)
        var seen = Set<String>()
        for song in songs where seen.insert(song.id).inserted {
            if onWatch.contains(song.id) {
                plan.alreadyOnWatch.append(song.id)
            } else if inFlight.contains(song.id) {
                plan.inFlight.append(song.id)
            } else if let bytes = song.bytes, bytes > 0 {
                if bytes <= remaining {
                    plan.toTransfer.append(song)
                    remaining -= bytes
                } else {
                    plan.overBudget.append(song)
                }
            } else {
                plan.unavailable.append(song.id)
            }
        }
        return plan
    }

    /// Phone side: split requested ids into ones to hand to `transferFile`
    /// now, ones already transferring, and ones that can't be sent.
    /// Order is preserved and duplicates are dropped.
    static func queue(
        requested: [String],
        available: Set<String>,
        outstanding: Set<String>
    ) -> WatchTransferAck {
        var ack = WatchTransferAck(queued: [], alreadyQueued: [], unavailable: [])
        var seen = Set<String>()
        for id in requested where seen.insert(id).inserted {
            if outstanding.contains(id) {
                ack.alreadyQueued.append(id)
            } else if available.contains(id) {
                ack.queued.append(id)
            } else {
                ack.unavailable.append(id)
            }
        }
        return ack
    }
}
