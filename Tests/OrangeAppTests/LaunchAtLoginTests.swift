import XCTest
import ServiceManagement
@testable import Orange

final class LaunchAtLoginTests: XCTestCase {
    @MainActor func testReadingStatusNeverRegistersOrUnregisters() async {
        let service = FakeLoginService(status: .notRegistered)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        login.refresh()
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }
    @MainActor func testNotFoundAttemptsRegistrationInsteadOfReopenError() async {
        let service = FakeLoginService(status: .notFound)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        login.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(login.enabled)
        XCTAssertNil(login.error)
    }
    @MainActor func testRegistrationFailureDoesNotBlockSetupOrPretendEnabled() async {
        let service = FakeLoginService(status: .notFound)
        service.registrationError = NSError(domain: "fixture.login", code: 42)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        var completed = false
        OrangeSetup.finish(login: login, launchAtLogin: true) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertFalse(login.enabled)
        XCTAssertNotNil(login.error)
        XCTAssertTrue(login.diagnostics?.contains("fixture.login (42)") == true)
        XCTAssertTrue(login.registrationMessage?.contains("retry") == true)
        service.registrationError = nil
        login.retry()
        XCTAssertTrue(login.enabled)
        XCTAssertNil(login.error)
        XCTAssertEqual(service.registerCalls, 2)
    }
    @MainActor func testPendingApprovalDoesNotBlockSetupOrRegisterAgain() async {
        let service = FakeLoginService(status: .requiresApproval)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        var completed = false
        OrangeSetup.finish(login: login, launchAtLogin: true) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertTrue(login.requiresApproval)
        XCTAssertFalse(login.enabled)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertNotNil(login.registrationMessage)
    }
    @MainActor func testApprovalReportedAlongsideErrorIsPendingRatherThanFailure() async {
        let service = FakeLoginService(status: .notRegistered)
        service.registrationStatus = .requiresApproval
        service.registrationError = NSError(domain: "fixture.login", code: 1)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        login.setEnabled(true)
        XCTAssertTrue(login.requiresApproval)
        XCTAssertNil(login.error)
    }
    @MainActor func testFailedUnregisterKeepsActualEnabledState() async {
        let service = FakeLoginService(status: .enabled)
        service.unregistrationError = NSError(domain: "fixture.login", code: 7)
        let login = LaunchAtLogin(service: service, bundleLocation: "/fixture/Orange.app")
        login.setEnabled(false)
        XCTAssertTrue(login.enabled)
        XCTAssertNotNil(login.error)
        XCTAssertTrue(login.registrationMessage?.contains("still starts") == true)
    }
}

@MainActor private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    init(status: SMAppService.Status) { self.status = status }
    func register() throws {
        registerCalls += 1
        if registrationError == nil || registrationStatus == .requiresApproval { status = registrationStatus }
        if let registrationError { throw registrationError }
    }
    func unregister() throws {
        unregisterCalls += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
    func openLoginItemsSettings() {}
}
