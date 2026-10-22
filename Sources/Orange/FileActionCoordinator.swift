import AppKit
import OrangeCore

@MainActor protocol AirDropSharing: AnyObject {
    func canShare(_ urls: [URL]) -> Bool
    func begin(_ urls: [URL], completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}

/// The coordinator retains a sharing session until its delegate reports a result.
/// No recipient is selected or file transmitted on behalf of the user.
@MainActor final class FileActionCoordinator {
    var onFeedback: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let pasteboard: NSPasteboard
    private let makeAirDrop: @MainActor () -> (any AirDropSharing)?
    private var sharing: [UUID: any AirDropSharing] = [:]
    private var stopped = false

    init(pasteboard: NSPasteboard = .general,
         makeAirDrop: @escaping @MainActor () -> (any AirDropSharing)? = {
             guard let service = NSSharingService(named: .sendViaAirDrop) else { return nil }
             return SystemAirDropSharing(service: service)
         }) {
        self.pasteboard = pasteboard
        self.makeAirDrop = makeAirDrop
    }

    func copyFiles(_ urls: [URL]) {
        guard !stopped, !urls.isEmpty else { return }
        pasteboard.clearContents()
        if pasteboard.writeObjects(urls as [NSURL]) { onFeedback?(urls.count == 1 ? "File copied" : "\(urls.count) files copied") }
        else { onError?("The files could not be copied to the clipboard.") }
    }

    func copyPaths(_ urls: [URL]) {
        guard !stopped, !urls.isEmpty else { return }
        pasteboard.clearContents()
        if pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) { onFeedback?(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied") }
        else { onError?("The paths could not be copied to the clipboard.") }
    }

    func airDrop(_ urls: [URL]) {
        guard !stopped, !urls.isEmpty else { return }
        guard let service = makeAirDrop(), service.canShare(urls) else {
            onError?("AirDrop is unavailable for these files. Check that AirDrop is enabled on this Mac.")
            return
        }
        let id = UUID()
        sharing[id] = service
        service.begin(urls) { [weak self] result in
            guard let self, self.sharing.removeValue(forKey: id) != nil, !self.stopped else { return }
            switch result {
            case .success: self.onFeedback?("AirDrop finished")
            case .failure(let error):
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError {
                    self.onFeedback?("AirDrop cancelled")
                } else { self.onError?("AirDrop failed. \(error.localizedDescription)") }
            }
        }
    }

    func openTerminal(_ urls: [URL]) {
        guard !stopped, !urls.isEmpty else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            onError?("Terminal could not be found on this Mac."); return
        }
        let directories = Array(Set(urls.map { FileFamily.detect($0) == .folder ? $0 : $0.deletingLastPathComponent() }))
        NSWorkspace.shared.open(directories, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if let error { self.onError?("Terminal could not open this folder. \(error.localizedDescription)") }
                else { self.onFeedback?("Opened in Terminal") }
            }
        }
    }

    func shutdown() {
        stopped = true
        let pending = Array(sharing.values)
        sharing.removeAll()
        for session in pending { session.cancel() }
    }
}

@MainActor private final class SystemAirDropSharing: NSObject, AirDropSharing, NSSharingServiceDelegate {
    private let service: NSSharingService
    private var window: NSWindow?
    private var completion: ((Result<Void, Error>) -> Void)?

    init(service: NSSharingService) {
        self.service = service
        super.init()
        service.delegate = self
    }
    func canShare(_ urls: [URL]) -> Bool { service.canPerform(withItems: urls) }
    func begin(_ urls: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 128),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Orange · AirDrop"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Choose a nearby device in AirDrop.\n\(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")")
        label.frame = NSRect(x: 24, y: 26, width: 312, height: 76)
        label.font = .systemFont(ofSize: 13)
        panel.contentView?.addSubview(label)
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The source window is on screen before AppKit asks the delegate for it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.completion != nil else { return }
            self.service.perform(withItems: urls)
        }
    }
    func cancel() {
        completion = nil
        service.delegate = nil
        window?.close()
        window = nil
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sharingContentScope.pointee = .item
        return window
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(.success(())) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        completion = nil
        window?.close()
        window = nil
        callback?(result)
    }
}
