import CryptoKit
import Foundation

// Run from the repository root. Only the public verification key is printed.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).resolvingSymlinksInPath()
let directory = root.appendingPathComponent(".orange-secrets", isDirectory: true)
let file = directory.appendingPathComponent("sparkle-ed25519.key")
do {
    guard directory.resolvingSymlinksInPath().path == directory.path else {
        throw CocoaError(.fileWriteInvalidFileName)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let key: Curve25519.Signing.PrivateKey
    if FileManager.default.fileExists(atPath: file.path) {
        guard file.resolvingSymlinksInPath().deletingLastPathComponent() == directory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let encoded = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    } else {
        key = Curve25519.Signing.PrivateKey()
        let data = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    fputs("Could not prepare the local update signing key: \(error.localizedDescription)\n", stderr)
    exit(1)
}
