import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Reading this model never changes the user's login items. Registration changes
/// happen only when a user-facing control explicitly calls setEnabled(_:).
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published var error: String?
    @Published private(set) var diagnostics: String?
    @Published private(set) var status: SMAppService.Status = .notRegistered

    private let service: any LoginItemService
    private let bundleLocation: String
    private var lastRequestedEnabled: Bool?

    init() {
        service = SystemLoginItemService()
        bundleLocation = Bundle.main.bundleURL.path
        refresh()
    }

    init(service: any LoginItemService, bundleLocation: String) {
        self.service = service
        self.bundleLocation = bundleLocation
        refresh()
    }

    /// A persistent session notice; it never implies that registration succeeded.
    var registrationMessage: String? {
        if error != nil {
            if lastRequestedEnabled == false && enabled {
                return "Orange still starts at login. Open Orange Settings to retry turning this off."
            }
            return "Orange is ready. Launch at login wasn't updated; you can retry in Orange Settings."
        }
        if requiresApproval {
            return "Orange is ready. Approve Orange in Login Items Settings to start it automatically when you log in."
        }
        return nil
    }

    func refresh() {
        status = service.status
        switch status {
        case .enabled:
            enabled = true
            requiresApproval = false
        case .requiresApproval:
            enabled = false
            requiresApproval = true
        case .notRegistered, .notFound:
            enabled = false
            requiresApproval = false
        @unknown default:
            enabled = false
            requiresApproval = false
        }
        if let requested = lastRequestedEnabled, reachedRequestedState(requested) {
            error = nil
        }
    }

    func setEnabled(_ value: Bool) {
        error = nil
        diagnostics = nil
        lastRequestedEnabled = value
        refresh()
        do {
            if value {
                switch status {
                case .enabled, .requiresApproval:
                    // A pending registration needs the user's approval in Settings,
                    // rather than another registration attempt or a forced prompt.
                    break
                case .notRegistered, .notFound:
                    // .notFound describes the current lookup, not a requirement
                    // to reopen an already-installed app. Let registration decide.
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else {
                switch status {
                case .enabled, .requiresApproval: try service.unregister()
                case .notRegistered, .notFound: break
                @unknown default:
                    try service.unregister()
                }
            }
        } catch {
            refresh()
            let failure = error as NSError
            diagnostics = "Operation: \(value ? "enable" : "disable") launch at login\nError: \(failure.domain) (\(failure.code))\nStatus: \(statusName)\nApp: \(bundleLocation)"
            if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                diagnostics? += "\nUnderlying error: \(underlying.domain) (\(underlying.code))"
            }
            // macOS can report launch denied while its actual status is pending
            // approval. Keep that pending state truthful and separate from errors.
            if !reachedRequestedState(value) {
                self.error = "Launch at login couldn't be \(value ? "enabled" : "disabled"). \(failure.localizedDescription) Retry in Orange Settings, or manage Orange in System Settings → General → Login Items."
            }
            return
        }
        refresh()
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }

    func retry() { setEnabled(lastRequestedEnabled ?? true) }

    func clearError() {
        error = nil
        diagnostics = nil
    }

    private func reachedRequestedState(_ enabled: Bool) -> Bool {
        enabled ? (status == .enabled || status == .requiresApproval)
            : (status == .notRegistered || status == .notFound)
    }

    private var statusName: String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
