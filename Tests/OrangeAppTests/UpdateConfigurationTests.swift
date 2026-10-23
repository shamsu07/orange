import XCTest
@testable import Orange

final class UpdateConfigurationTests: XCTestCase {
    func testAcceptsHTTPSFeedWithPublicKeyAndStrictSignaturePolicy() throws {
        let configuration = try UpdateConfiguration(info: validInfo())
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://shamsu07.github.io/orange/appcast.xml")
        XCTAssertEqual(configuration.publicKey.count, 32)
    }

    func testRejectsInsecureAndCredentialBearingFeeds() {
        for feed in ["http://example.com/feed.xml", "file:///fixture/feed.xml", "https://", "https:///feed.xml", "https://name:password@example.com/feed.xml", "https://example.com/feed.xml#fragment", "invalid"] {
            var info = validInfo()
            info["SUFeedURL"] = feed
            XCTAssertThrowsError(try UpdateConfiguration(info: info), feed)
        }
    }

    func testRejectsMissingAndMalformedSigningKeys() {
        for key: String? in [nil, "placeholder", Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = validInfo()
            info["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration(info: info))
        }
    }

    func testRejectsDisabledSignatureVerificationOrAutomaticInstallation() {
        for setting in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            var info = validInfo()
            info[setting] = false
            XCTAssertThrowsError(try UpdateConfiguration(info: info), setting)
        }
        for setting in ["SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"] {
            var info = validInfo()
            info[setting] = true
            XCTAssertThrowsError(try UpdateConfiguration(info: info), setting)
        }
        var info = validInfo()
        info["SUSignedFeedFailureExpirationInterval"] = 1_728_000
        XCTAssertThrowsError(try UpdateConfiguration(info: info), "Signature failures must never expire into unsigned feed acceptance.")
    }

    private func validInfo() -> [String: Any] {
        [
            "SUFeedURL": "https://shamsu07.github.io/orange/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUAllowsAutomaticUpdates": false,
            "SUEnableSystemProfiling": false
        ]
    }
}
