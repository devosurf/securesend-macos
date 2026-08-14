import CryptoKit
import Foundation

// A CryptoKit port of packages/crypto: the no-password path only, which is all a
// selection-to-link flow needs. Every constant here mirrors that package and is
// named after it, so a drift in either shows up as a failed round trip.
//
// The one real trap: Web Crypto's AES-GCM returns ciphertext with the 16-byte tag
// already appended, while CryptoKit hands them back as separate fields. They have
// to be concatenated in that order or the browser's decrypt throws.

public enum SecureSendCrypto {
  public static let envelopeVersion = 1
  public static let fragmentTokenVersion: UInt8 = 1
  public static let secretIdBytes = 16
  public static let fragmentKeyBytes = 32
  public static let ivBytes = 12
  public static let aadPrefix = "securesend:v1"

  public struct Sealed {
    public let ciphertext: String
    public let fragmentToken: String
    public let id: String
    public let iv: String
  }

  public static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "the system random source failed")
    return Data(bytes)
  }

  public static func newSecretId() -> String {
    base64url(randomBytes(secretIdBytes))
  }

  /// byte 0 version, byte 1 flags (0 = no password), bytes 2..33 the key.
  public static func encodeFragmentToken(key: Data) -> String {
    var bytes = Data([fragmentTokenVersion, 0])
    bytes.append(key)
    return base64url(bytes)
  }

  /// Seals a note-only envelope the web client can open.
  public static func seal(note: String) throws -> Sealed {
    let id = newSecretId()
    let keyBytes = randomBytes(fragmentKeyBytes)
    let key = SymmetricKey(data: keyBytes)
    let iv = randomBytes(ivBytes)

    // Built by hand rather than through JSONEncoder so the shape stays literally
    // the one envelope.ts writes: a version and the parts that are present.
    let contents: [String: Any] = ["v": envelopeVersion, "note": note]
    let plaintext = try JSONSerialization.data(
      withJSONObject: contents, options: [.sortedKeys]
    )

    let aad = Data("\(aadPrefix):envelope:\(id)".utf8)
    let box = try AES.GCM.seal(
      plaintext,
      using: key,
      nonce: try AES.GCM.Nonce(data: iv),
      authenticating: aad
    )

    return Sealed(
      ciphertext: base64url(box.ciphertext + box.tag),
      fragmentToken: encodeFragmentToken(key: keyBytes),
      id: id,
      iv: base64url(iv)
    )
  }
}
