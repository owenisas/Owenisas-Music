import Foundation

var assertionCount = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !condition() { fatalError(message) }
}
let now = Date(timeIntervalSince1970: 1000)
let phone = WatchWidgetPlayback(title: "Phone track", isPlaying: true, capturedAt: now)
let local = WatchWidgetPlayback(title: "Offline track", isPlaying: false, capturedAt: now)
var snapshot = WatchWidgetSnapshot(phone: phone, local: local, phoneReachable: true, offlineCount: 2)
expect(snapshot.title(for: .phone, at: now) == "Phone track", "phone routing")
expect(snapshot.canControl(.phone, at: now), "fresh phone controls")
expect(snapshot.isRelevant(.phone, at: now), "live phone session relevance")
expect(!snapshot.isRelevant(.watch, at: now), "paused Watch is not promoted")
expect(snapshot.nextExpiry(after: now) == now.addingTimeInterval(301), "expiry entry scheduled")
expect(!snapshot.canControl(.phone, at: now.addingTimeInterval(301)), "stale phone controls disabled")
expect(snapshot.title(for: .watch, at: now) == "Offline track", "watch routing")
expect(snapshot.title(for: .phone, at: now.addingTimeInterval(301)) == "Open iPhone app", "expired phone metadata")
snapshot.phoneReachable = false
expect(snapshot.title(for: .phone, at: now) == "iPhone unavailable", "unreachable phone")
expect(snapshot.title(for: .watch, at: now) == "Offline track", "offline remains independent")
snapshot.local = nil
expect(snapshot.title(for: .watch, at: now) == "2 downloaded songs", "cleared local state")
for destination in WatchWidgetDestination.allCases {
    expect(WatchWidgetDestination(url: destination.url) == destination, "route roundtrip")
}
expect(WatchWidgetDestination(url: URL(string: "https://phone")!) == nil, "reject other scheme")
expect(WatchWidgetDestination(url: URL(string: "owenisas-watch://unknown")!) == nil, "reject unknown route")
let liked = PlaylistWidgetItem(id: "liked", title: "Liked Songs", songCount: 1)
let playlist = PlaylistWidgetItem(id: "playlist:a/b", title: "Running", songCount: 3)
let catalog = PlaylistWidgetCatalog(items: [liked, playlist], capturedAt: now)
expect(catalog.item(id: nil) == liked, "default liked")
expect(catalog.item(id: playlist.id) == playlist, "stable playlist identity")
expect(catalog.item(id: "deleted") == nil, "deleted playlist must not silently fall back")
let encoded = try JSONEncoder().encode(catalog)
let decoded = try JSONDecoder().decode(PlaylistWidgetCatalog.self, from: encoded)
expect(decoded == catalog, "catalog roundtrip")
print("PASS: \(assertionCount) widget routing, stale state, selection and persistence assertions")
