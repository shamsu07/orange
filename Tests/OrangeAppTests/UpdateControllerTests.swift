import XCTest
@testable import Orange

final class UpdateControllerTests: XCTestCase {
    @MainActor func testStartupIsIdempotentAndDoesNotInvokeUserCheck() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.start()
        updates.start()
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.userCheckCount, 0)
        XCTAssertTrue(updates.canCheckForUpdates)
    }

    @MainActor func testAvailabilityCreatesVisibleUpdateActionAndUserExplicitlyOpensIt() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.start()
        driver.emit(UpdateDriverState(canCheck: true, automaticallyChecks: true, availableVersion: "0.2.0"))
        XCTAssertEqual(updates.availableVersion, "0.2.0")
        XCTAssertEqual(updates.buttonTitle, "Update to 0.2.0…")
        XCTAssertEqual(driver.userCheckCount, 0, "A scheduled reminder only changes UI state.")
        updates.checkForUpdates()
        XCTAssertEqual(driver.userCheckCount, 1)
    }

    @MainActor func testBusyWorkBlocksUserCheckWithoutStartingDownload() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.isBusy = { true }
        updates.start()
        updates.checkForUpdates()
        XCTAssertEqual(driver.userCheckCount, 0)
        XCTAssertTrue(updates.errorMessage?.contains("current operations") == true)
    }

    @MainActor func testInstallationWaitsForWorkAndResumesExactlyOnceFromStateChange() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        var busy = true
        updates.isBusy = { busy }
        updates.start()
        var installations = 0
        XCTAssertTrue(driver.deferInstallation?({ installations += 1 }) == true)
        XCTAssertTrue(updates.installationWaitingForWork)
        updates.workStateDidChange()
        XCTAssertEqual(installations, 0)
        busy = false
        updates.workStateDidChange()
        updates.workStateDidChange()
        XCTAssertEqual(installations, 1)
        XCTAssertFalse(updates.installationWaitingForWork)
    }

    @MainActor func testIdleInstallationContinuesWithSparkleWithoutTakingOwnership() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.start()
        XCTAssertFalse(driver.deferInstallation?({ XCTFail("Sparkle owns immediate installation.") }) ?? true)
        XCTAssertFalse(updates.installationWaitingForWork)
    }

    @MainActor func testDisabledOrUnstartedUpdaterCannotBeInvoked() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.checkForUpdates()
        updates.setAutomaticallyChecks(false)
        XCTAssertEqual(driver.userCheckCount, 0)
        XCTAssertEqual(driver.changedAutomaticChecks, [])
        updates.start()
        driver.emit(UpdateDriverState(canCheck: false))
        updates.checkForUpdates()
        XCTAssertEqual(driver.userCheckCount, 0)
    }

    @MainActor func testUserCanDisableAutomaticChecksWithoutDisablingManualChecks() {
        let driver = FakeUpdateDriver()
        let updates = UpdateController(driver: driver)
        updates.start()
        updates.setAutomaticallyChecks(false)
        XCTAssertEqual(driver.changedAutomaticChecks, [false])
        XCTAssertFalse(updates.automaticallyChecks)
        updates.checkForUpdates()
        XCTAssertEqual(driver.userCheckCount, 1)
    }

    @MainActor func testStartupFailureIsVisibleAndDoesNotPretendCheckingWorks() {
        let driver = FakeUpdateDriver()
        driver.startError = NSError(domain: "fixture.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configuration failed"])
        let updates = UpdateController(driver: driver)
        updates.start()
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertEqual(updates.errorMessage, "Configuration failed")
        updates.checkForUpdates()
        XCTAssertEqual(driver.userCheckCount, 0)
    }
}

@MainActor private final class FakeUpdateDriver: UpdateDriver {
    var onChange: ((UpdateDriverState) -> Void)?
    var deferInstallation: ((@escaping () -> Void) -> Bool)?
    var startCount = 0
    var userCheckCount = 0
    var changedAutomaticChecks: [Bool] = []
    var startError: Error?
    var state = UpdateDriverState(canCheck: true, automaticallyChecks: true)

    func start() throws {
        startCount += 1
        if let startError { throw startError }
        emit(state)
    }
    func checkForUpdates() { userCheckCount += 1 }
    func setAutomaticallyChecks(_ enabled: Bool) {
        changedAutomaticChecks.append(enabled)
        state.automaticallyChecks = enabled
        emit(state)
    }
    func emit(_ state: UpdateDriverState) { self.state = state; onChange?(state) }
}
