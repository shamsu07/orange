import Foundation

/// Fail closed if a distributor strips signature verification or changes the
/// feed to an insecure transport. The signing key is public; its private half
/// belongs in the maintainer's secret store, never the application or repository.
struct UpdateConfiguration {
    enum ConfigurationError: LocalizedError {
        case invalidFeed, missingKey, insecurePolicy

        var errorDescription: String? {
            switch self {
            case .invalidFeed: return "Updates are unavailable: the app's HTTPS update feed is missing or invalid."
            case .missingKey: return "Updates are unavailable: this build has no valid update verification key."
            case .insecurePolicy: return "Updates are unavailable: this build's update signature policy is incomplete."
            }
        }
    }

    let feedURL: URL
    let publicKey: Data

    init(info: [String: Any]) throws {
        guard let value = info["SUFeedURL"] as? String,
              let components = URLComponents(string: value),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let url = components.url else { throw ConfigurationError.invalidFeed }
        guard let encoded = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32 else {
            throw ConfigurationError.missingKey
        }
        guard info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUEnableSystemProfiling"] as? Bool == false else {
            throw ConfigurationError.insecurePolicy
        }
        feedURL = url
        publicKey = key
    }
}
