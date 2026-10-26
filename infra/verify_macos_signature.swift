import Foundation
import CryptoKit

// Check that the archive is signed by the public key actually embedded in the app.
let args = CommandLine.arguments
guard args.count == 4, let publicBytes = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let data = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: data) else { exit(1) }
