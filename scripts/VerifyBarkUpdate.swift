// Licensed under GPL-3.0. See LICENSE.
import CryptoKit
import Foundation

// Check the finished DMG against the public key already sealed into the app.
// Passing the signing tool a different valid private key must fail packaging.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Expected a disk image, Ed25519 public key and signature.\n", stderr)
    exit(1)
}
let image = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: image) else {
    fputs("Update signature does not match the public key in the app.\n", stderr)
    exit(1)
}
