import XCTest
import Sparkle
@testable import Orange

final class SparkleUpdateDriverTests: XCTestCase {
    @MainActor func testUpToDateAndUserCancellationAreNotSettingsFailures() {
        for code in [SUError.noUpdateError, .installationCanceledError] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue),
                                userInfo: [NSLocalizedDescriptionKey: "Normal update session completion"])
            XCTAssertNil(SparkleUpdateDriver.presentedError(error))
        }
    }

    @MainActor func testSignatureAndTransportFailuresRemainVisible() {
        for error in [
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Signature invalid"]),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot connect"]),
            NSError(domain: "another.provider", code: Int(SUError.noUpdateError.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Provider failure"])
        ] {
            XCTAssertEqual(SparkleUpdateDriver.presentedError(error), error.localizedDescription)
        }
    }
}
