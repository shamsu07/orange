import Combine
import Foundation

struct UpdateDriverState: Equatable {
    var canCheck = false
    var automaticallyChecks = false
    var lastChecked: Date?
    var availableVersion: String?
    var errorMessage: String?
}

@MainActor
protocol UpdateDriver: AnyObject {
    var onChange: ((UpdateDriverState) -> Void)? { get set }
    var deferInstallation: ((@escaping () -> Void) -> Bool)? { get set }
    func start() throws
    func checkForUpdates()
    func setAutomaticallyChecks(_ enabled: Bool)
}

/// Sparkle owns scheduling, transport, verification and installation. This
/// adapter only exposes gentle reminders and coordinates with Orange's work.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var installationWaitingForWork = false
    var onChange: (() -> Void)?
    var isBusy: () -> Bool = { false }

    private var driver: (any UpdateDriver)?
    private var hasStarted = false
    private var pendingInstallation: (() -> Void)?

    init(bundle: Bundle = .main) {
        do {
            _ = try UpdateConfiguration(info: bundle.infoDictionary ?? [:])
            driver = SparkleUpdateDriver(bundle: bundle)
        } catch {
            errorMessage = error.localizedDescription
        }
        connectDriver()
    }

    init(driver: any UpdateDriver) {
        self.driver = driver
        connectDriver()
    }

    var buttonTitle: String {
        if installationWaitingForWork { return "Update after current work…" }
        if let availableVersion { return "Update to \(availableVersion)…" }
        return "Check for Updates…"
    }

    /// Call after onboarding completes. Starting never opens an Orange window.
    func start() {
        guard !hasStarted, let driver else { return }
        hasStarted = true
        do { try driver.start() }
        catch {
            canCheckForUpdates = false
            errorMessage = error.localizedDescription
            onChange?()
        }
    }

    /// User initiated only. Scheduled reminders are delivered as state changes.
    func checkForUpdates() {
        guard hasStarted, canCheckForUpdates, let driver else { return }
        guard !isBusy() else {
            errorMessage = "Finish or cancel the current operations before updating Orange."
            onChange?()
            return
        }
        errorMessage = nil
        driver.checkForUpdates()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard hasStarted else { return }
        driver?.setAutomaticallyChecks(enabled)
    }

    /// Event driven: no polling timer runs while a conversion finishes.
    func workStateDidChange() {
        guard !isBusy(), let install = pendingInstallation else { return }
        pendingInstallation = nil
        installationWaitingForWork = false
        onChange?()
        install()
    }

    private func connectDriver() {
        driver?.onChange = { [weak self] state in
            guard let self else { return }
            canCheckForUpdates = state.canCheck
            automaticallyChecks = state.automaticallyChecks
            lastChecked = state.lastChecked
            availableVersion = state.availableVersion
            errorMessage = state.errorMessage
            onChange?()
        }
        driver?.deferInstallation = { [weak self] install in
            guard let self, isBusy() else { return false }
            pendingInstallation = install
            installationWaitingForWork = true
            onChange?()
            return true
        }
    }
}
