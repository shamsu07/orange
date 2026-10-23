// Verify release signatures against the public key embedded in the packaged app.
// Inputs are public metadata and a local archive path. The private key is never read.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
func fail() -> Never {
    FileHandle.standardError.write(Data("The update signature does not match the app's public key.\n".utf8))
    exit(1)
}
guard arguments.count == 4,
      let publicBytes = Data(base64Encoded: arguments[1]), publicBytes.count == 32,
      let signature = Data(base64Encoded: arguments[2]), signature.count == 64,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe),
      publicKey.isValidSignature(signature, for: archive) else { fail() }
