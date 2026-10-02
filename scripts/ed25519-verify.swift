// Checks a Sparkle EdDSA (ed25519) signature the way the installed app will: against SUPublicEDKey.
//
//   xcrun swift scripts/ed25519-verify.swift <SUPublicEDKey> <file> <sparkle:edSignature>
//
// Exit status: 0 the signature is valid for the file under that key, 1 it is not, 2 the arguments are malformed (wrong
// count, a key that is not the base64 of 32 bytes, a signature that is not the base64 of 64 bytes, an unreadable file).
//
// Used by scripts/make-appcast.sh and the release workflow, so a SPARKLE_PRIVATE_KEY that is not the pair of the public key in
// Resources/Info.plist fails the release instead of every user's update. Sparkle's keys are plain Ed25519: the public key is
// the base64 of its 32 bytes, the signature the base64 of 64 bytes. Only public values come in here; the private key is
// never passed to this script.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[1]), publicKey.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
      let signature = Data(base64Encoded: arguments[3]), signature.count == 64,
      let data = FileManager.default.contents(atPath: arguments[2]) else {
	FileHandle.standardError.write(Data("사용법: ed25519-verify.swift <SUPublicEDKey> <file> <edSignature>\n".utf8))
	exit(2)
}
exit(key.isValidSignature(signature, for: data) ? 0 : 1)
