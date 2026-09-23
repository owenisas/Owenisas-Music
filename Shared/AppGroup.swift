import Foundation

/// Shared container used by the app, the share extension and the widget.
enum AppGroup {
    static let identifier = "group.com.Owenisas-Music"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
