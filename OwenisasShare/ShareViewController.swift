import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Share-sheet entry point.
///
/// - Audio files (both builds): copied into the App Group inbox; the app
///   imports them the next time it becomes active.
/// - Personal builds: a YouTube / YouTube Music link (URL, or text with the
///   link in it) is appended to the inbox queue, then the app is opened with
///   `owenisas://download` so the download starts right away. If iOS won't
///   open it from here, the link stays queued for the next launch.
///
/// No network access here; the app does all downloading.
final class ShareViewController: UIViewController {
    private let model = ShareSheetModel()
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        model.onDone = { [weak self] in self?.complete() }
        model.onCancel = { [weak self] in self?.cancel() }
        #if !APP_STORE
        model.onDownload = { [weak self] choice in self?.queueAndOpen(choice: choice) }
        #endif

        let host = UIHostingController(rootView: ShareSheetView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { await loadSharedItems() }
    }

    // MARK: - Reading the shared items

    private var providers: [NSItemProvider] {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return items.flatMap { $0.attachments ?? [] }
    }

    private func loadSharedItems() async {
        let providers = self.providers
        let audio = providers.compactMap { provider -> (NSItemProvider, String)? in
            guard let type = Self.audioType(of: provider) else { return nil }
            return (provider, type)
        }
        if !audio.isEmpty {
            await saveAudio(audio)
            return
        }

        #if !APP_STORE
        var texts: [String] = []
        for provider in providers {
            if let text = await Self.loadText(from: provider) { texts.append(text) }
        }
        let captions = extensionContext?.inputItems.compactMap { ($0 as? NSExtensionItem)?.attributedContentText?.string } ?? []
        texts.append(contentsOf: captions)
        for text in texts {
            if let link = YouTubeLinkClassifier.firstLink(in: text) {
                model.phase = .link(link, YouTubeLinkClassifier.classify(link))
                return
            }
        }
        model.phase = texts.isEmpty ? .nothingToAdd : .notYouTube
        #else
        model.phase = .nothingToAdd
        #endif
    }

    /// The first registered type that is audio (not a generic file URL).
    private static func audioType(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .audio) ?? false
        }
    }

    // MARK: - Audio files

    private func saveAudio(_ items: [(NSItemProvider, String)]) async {
        guard let inbox = SharedInbox.shared else {
            model.phase = .failed("Owenisas Music's shared storage isn't available. Open the app once, then try again.")
            return
        }
        model.phase = .savingAudio(items.count)
        var saved = 0
        var lastError: Error?
        for (provider, type) in items {
            do {
                try await Self.copyFile(from: provider, type: type, into: inbox)
                saved += 1
            } catch {
                lastError = error
            }
        }
        guard saved > 0 else {
            model.phase = .failed("The file couldn't be copied (\(lastError?.localizedDescription ?? "unknown error")).")
            return
        }
        #if !APP_STORE
        // Personal builds: open the app so the import happens now.
        if let url = URL(string: "owenisas://import") {
            model.phase = .savingAudio(saved)
            openHostApp(url) { [weak self] opened in
                guard let self else { return }
                if opened {
                    self.complete()
                } else {
                    self.model.phase = .audioSaved(saved)
                }
            }
            return
        }
        #endif
        model.phase = .audioSaved(saved)
    }

    /// The provider's temporary file only lives for the completion handler,
    /// so the copy happens inside it.
    private static func copyFile(from provider: NSItemProvider, type: String, into inbox: SharedInbox) async throws {
        let suggestedName = provider.suggestedName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try inbox.addAudio(copying: url, suggestedName: suggestedName)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    #if !APP_STORE
    // MARK: - Links

    /// A URL item, else plain text.
    private static func loadText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
            if let url = item as? URL { return url.absoluteString }
            if let data = item as? Data {
                if let url = URL(dataRepresentation: data, relativeTo: nil) { return url.absoluteString }
                if let text = String(data: data, encoding: .utf8) { return text }
            }
            if let text = item as? String { return text }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
            if let text = item as? String { return text }
            if let data = item as? Data { return String(data: data, encoding: .utf8) }
            if let url = item as? URL { return url.absoluteString }
        }
        return nil
    }

    private func queueAndOpen(choice: SharedInbox.LinkRequest.Choice?) {
        guard case .link(let link, _) = model.phase else { return }
        guard let inbox = SharedInbox.shared else {
            model.phase = .failed("Owenisas Music's shared storage isn't available. Copy the link and paste it in the Download tab instead.")
            return
        }
        do {
            try inbox.enqueue(link: link, choice: choice)
        } catch {
            model.phase = .failed("The link couldn't be handed to Owenisas Music (\(error.localizedDescription)).")
            return
        }
        model.phase = .opening
        guard let url = URL(string: "owenisas://download") else { return }
        openHostApp(url) { [weak self] opened in
            guard let self else { return }
            if opened {
                self.complete()
            } else {
                self.model.phase = .queued
                Self.remindIfAllowed()
            }
        }
    }

    /// Share extensions have no supported way to open their app
    /// (`NSExtensionContext.open` only works for Today widgets). What works on
    /// iOS 18 and 26: find the UIApplication in the responder chain and call
    /// the non-deprecated `open(_:options:completionHandler:)` (the old
    /// `openURL:` selector is a no-op since iOS 18). Personal builds only.
    /// Reports false if there is no application object, iOS refuses, or
    /// nothing answers within 3 s.
    private func openHostApp(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        var finished = false
        let finish: @MainActor (Bool) -> Void = { opened in
            guard !finished else { return }
            finished = true
            NSLog("OWENISAS_SHARE: open %@ -> %@", url.absoluteString, opened ? "opened" : "not opened")
            completion(opened)
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { opened in
                    Task { @MainActor in finish(opened) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { finish(false) }
                }
                return
            }
            responder = current.next
        }
        finish(false)
    }

    /// The link is queued but the app didn't open: a local notification (only
    /// if the user already allowed them) gives a tap target that opens it.
    private static func remindIfAllowed() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                let content = UNMutableNotificationContent()
                content.title = "Download queued"
                content.body = "Open Owenisas Music to start it."
                let request = UNNotificationRequest(identifier: "share-queued", content: content, trigger: nil)
                center.add(request)
            default:
                break
            }
        }
    }
    #endif

    // MARK: - Finishing

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
