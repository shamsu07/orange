import Combine
import Foundation
import Sparkle

@MainActor
// Sparkle's standard user driver invokes its delegate on the main thread, but
// this Objective-C protocol is not yet annotated with Swift actor isolation.
final class SparkleUpdateDriver: NSObject, UpdateDriver, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var onChange: ((UpdateDriverState) -> Void)?
    var deferInstallation: ((@escaping () -> Void) -> Bool)?
    private let bundle: Bundle
    private var updater: SPUUpdater!
    private var userDriver: SPUStandardUserDriver!
    private var observations: Set<AnyCancellable> = []
    private var state = UpdateDriverState()

    init(bundle: Bundle) {
        self.bundle = bundle
        super.init()
        userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
    }

    func start() throws {
        try updater.start()
        updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(updater.publisher(for: \.automaticallyChecksForUpdates), updater.publisher(for: \.lastUpdateCheckDate))
            .sink { [weak self] canCheck, automatic, lastCheck in
                guard let self else { return }
                state.canCheck = canCheck
                state.automaticallyChecks = automatic
                state.lastChecked = lastCheck
                publish()
            }
            .store(in: &observations)
    }

    func checkForUpdates() { updater.checkForUpdates() }
    func setAutomaticallyChecks(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Finder gestures must never summon update windows, including near launch.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state updateState: SPUUserUpdateState) {
        state.availableVersion = update.displayVersionString
        state.errorMessage = nil
        publish()
    }

    func standardUserDriverWillFinishUpdateSession() {
        state.availableVersion = nil
        publish()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state.availableVersion = item.displayVersionString
        state.errorMessage = nil
        publish()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        state.availableVersion = nil
        state.errorMessage = nil
        publish()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        state.errorMessage = error.localizedDescription
        publish()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferInstallation?(installHandler) ?? false
    }

    private func publish() { onChange?(state) }
}
