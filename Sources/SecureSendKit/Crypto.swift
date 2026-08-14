import CryptoKit
import Foundation

// A CryptoKit port of packages/crypto. Every constant here mirrors that package
// and is named after it, so a drift in either shows up as a failed round trip.
//
// The one real trap: Web Crypto's AES-GCM returns ciphertext with the 16-byte tag
// already appended, while CryptoKit hands them back as separate fields. They have
// to be concatenated in that order on the way out and split apart on the way in,
// or the two implementations cannot read each other.

public enum SecureSendCrypto {
  public static let envelopeVersion = 1
  public static let fragmentTokenVersion: UInt8 = 1
  public static let secretIdBytes = 16
  public static let secretIdLength = 22
  public static let fragmentKeyBytes = 32
  public static let fragmentSaltBytes = 16
  public static let ivBytes = 12
  public static let tagBytes = 16
  public static let aadPrefix = "securesend:v1"

  private static let passwordFlag: UInt8 = 0x01
  private static let keyOffset = 2
  private static let plainTokenBytes = keyOffset + fragmentKeyBytes
  private static let passwordTokenBytes = plainTokenBytes + fragmentSaltBytes

  public struct Sealed {
    public let ciphertext: String
    public let fragmentToken: String
    public let id: String
    public let iv: String
  }

  // MARK: - base64url

  private static let alphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  )

  private static let values: [Character: UInt32] = {
    var table: [Character: UInt32] = [:]
    for (index, character) in alphabet.enumerated() {
      table[character] = UInt32(index)
    }
    return table
  }()

  public static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Unpadded base64url in, or a throw. Strict on everything the encoder could not
  /// have produced, because this reads the fragment token: a string that decodes
  /// loosely here is a damaged link quietly becoming a plausible key.
  ///
  /// Nothing it throws ever quotes the input.
  public static func base64urlDecode(_ input: String) throws -> Data {
    // A base64url block is 2, 3 or 4 characters. One leftover character is junk.
    if input.count % 4 == 1 {
      throw Base64urlFailure.incomplete
    }

    var decoded = Data()
    decoded.reserveCapacity(input.count * 3 / 4)
    var buffer: UInt32 = 0
    var bufferedBits = 0

    for character in input {
      guard let value = values[character] else {
        throw Base64urlFailure.unexpectedCharacter
      }

      buffer = (buffer << 6) | value
      bufferedBits += 6

      if bufferedBits >= 8 {
        bufferedBits -= 8
        decoded.append(UInt8((buffer >> UInt32(bufferedBits)) & 0xff))
      }
    }

    // The encoder leaves the bits past the last whole byte at zero. Anything else
    // is a corrupted final character, and must not decode to a plausible key.
    guard buffer & ((1 << UInt32(bufferedBits)) - 1) == 0 else {
      throw Base64urlFailure.trailingBits
    }

    return decoded
  }

  public enum Base64urlFailure: Error, Sendable {
    case incomplete
    case trailingBits
    case unexpectedCharacter
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

  /// Whether this could be an id we generated. Strict on purpose: it decodes with
  /// the same reader the fragment token uses, so a string that survives here is one
  /// `newSecretId` could have produced, down to the unused bits in the last
  /// character. Everything else is a typo or a truncated link.
  public static func isSecretId(_ value: String) -> Bool {
    guard value.count == secretIdLength else {
      return false
    }
    return (try? base64urlDecode(value)) != nil
  }

  // MARK: - The fragment token

  /// Everything the recipient needs and the server must never have:
  ///
  ///     byte 0        version
  ///     byte 1        flags, bit 0 set when a password protects the envelope
  ///     bytes 2..33   the 256-bit key
  ///     bytes 34..49  the 128-bit KDF salt, present only with that flag
  ///
  /// A password token always carries its salt and a plain one never does, so the
  /// two cannot be mixed up by construction.
  public enum FragmentToken: Sendable, Equatable {
    case plain(key: Data)
    case passwordProtected(key: Data, salt: Data)

    public var key: Data {
      switch self {
      case .plain(let key): return key
      case .passwordProtected(let key, _): return key
      }
    }

    public var needsPassword: Bool {
      if case .passwordProtected = self { return true }
      return false
    }
  }

  /// `incomplete` is the recipient-facing state for a link that arrived without a
  /// usable key: nothing to request, nothing destroyed, a fix to teach. Decoding
  /// reports it rather than throwing, because it is an ordinary thing for a link
  /// to survive a chat client badly.
  public enum FragmentTokenResult: Sendable, Equatable {
    case ok(FragmentToken)
    case incomplete
  }

  /// byte 0 version, byte 1 flags (0 = no password), bytes 2..33 the key.
  public static func encodeFragmentToken(key: Data) -> String {
    var bytes = Data([fragmentTokenVersion, 0])
    bytes.append(key)
    return base64url(bytes)
  }

  /// Reads a fragment token, or says the link is incomplete. Every check is a way
  /// a real link gets damaged: truncated by a chat client, re-wrapped, a character
  /// dropped. What it cannot see is a substitution inside the key, because the
  /// format carries no checksum; that one fails at decryption instead, which is
  /// still closed.
  public static func decodeFragmentToken(_ encoded: String) -> FragmentTokenResult {
    guard let bytes = try? base64urlDecode(encoded), bytes.count > keyOffset else {
      return .incomplete
    }

    let version = bytes[bytes.startIndex]
    let flags = bytes[bytes.startIndex + 1]

    guard version == fragmentTokenVersion, flags == 0 || flags == passwordFlag else {
      return .incomplete
    }

    let needsPassword = flags == passwordFlag
    guard bytes.count == (needsPassword ? passwordTokenBytes : plainTokenBytes) else {
      return .incomplete
    }

    // Re-based, because a Data sliced out of another does not start at zero and a
    // CryptoKit key built from one that does not is a silently wrong key.
    let key = Data(bytes[(bytes.startIndex + keyOffset)..<(bytes.startIndex + plainTokenBytes)])

    return .ok(
      needsPassword
        ? .passwordProtected(key: key, salt: Data(bytes[(bytes.startIndex + plainTokenBytes)...]))
        : .plain(key: key)
    )
  }

  // MARK: - Sealing

  /// Seals a note-only envelope the web client can open.
  public static func seal(note: String) throws -> Sealed {
    let id = newSecretId()
    let keyBytes = randomBytes(fragmentKeyBytes)
    let key = SymmetricKey(data: keyBytes)
    let iv = randomBytes(ivBytes)

    // Built by hand rather than through JSONEncoder so the shape stays literally
    // the one envelope.ts writes: a version and the parts that are present.
    let contents: [String: Any] = ["note": note, "v": envelopeVersion]
    let plaintext = try JSONSerialization.data(
      withJSONObject: contents, options: [.sortedKeys]
    )

    let box = try AES.GCM.seal(
      plaintext,
      using: key,
      nonce: try AES.GCM.Nonce(data: iv),
      authenticating: envelopeAad(id: id)
    )

    return Sealed(
      ciphertext: base64url(box.ciphertext + box.tag),
      fragmentToken: encodeFragmentToken(key: keyBytes),
      id: id,
      iv: base64url(iv)
    )
  }

  // MARK: - Additional data

  /// Every ciphertext is bound to the row it belongs to, and an attachment also to
  /// its position. The envelope and its attachments share one data key, so this is
  /// the only thing stopping a ciphertext from being served under another id, at
  /// another index, or in place of the envelope itself.
  static func envelopeAad(id: String) -> Data {
    Data("\(aadPrefix):envelope:\(id)".utf8)
  }

  static func attachmentAad(id: String, index: Int) -> Data {
    Data("\(aadPrefix):attachment:\(id):\(index)".utf8)
  }
}
