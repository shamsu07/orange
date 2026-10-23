import Foundation

enum AppVersion {
    /// Release automation changes Info.plist; every user-visible version follows it.
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
