import CryptoKit
import Foundation

// Opening an envelope, which is the mirror of packages/crypto's `openEnvelope`.
//
// Nothing here touches the network. By the time anything in this file runs, the
// reveal has already happened and the instance no longer holds what it handed
// over, so a failure in here is a secret that is gone. That is why every check is
// the whole envelope's: an attachment that did not arrive, arrived twice, or came
// back the wrong size fails the open rather than handing over a partial secret
// that reads as a whole one.
//
// The password path is deliberately absent. This app hands password-protected
// links to the browser, so `open` refuses one rather than half-deriving a key.

extension SecureSendCrypto {
  /// base64url, which is how every one of these travels and how the api sends it.
  public struct Ciphertext: Sendable, Equatable {
    public let ciphertext: String
    public let iv: String

    public init(ciphertext: String, iv: String) {
      self.ciphertext = ciphertext
      self.iv = iv
    }
  }

  public struct AttachmentCiphertext: Sendable, Equatable {
    public let ciphertext: String
    public let index: Int
    public let iv: String

    public init(ciphertext: String, index: Int, iv: String) {
      self.ciphertext = ciphertext
      self.index = index
      self.iv = iv
    }
  }

  /// Everything a reveal hands back, and nothing the server may hold. The key is
  /// deliberately not in here.
  public struct StoredEnvelope: Sendable, Equatable {
    public let attachments: [AttachmentCiphertext]
    public let envelope: Ciphertext
    public let id: String

    public init(attachments: [AttachmentCiphertext], envelope: Ciphertext, id: String) {
      self.attachments = attachments
      self.envelope = envelope
      self.id = id
    }
  }

  public struct Credentials: Sendable, Equatable, Codable {
    public let password: String
    public let username: String

    public init(password: String, username: String) {
      self.password = password
      self.username = username
    }
  }

  public struct OpenedFile: Sendable, Equatable {
    public let bytes: Data
    public let name: String
    public let size: Int
    public let type: String

    public init(bytes: Data, name: String, size: Int, type: String) {
      self.bytes = bytes
      self.name = name
      self.size = size
      self.type = type
    }
  }

  public struct Opened: Sendable, Equatable {
    public let credentials: Credentials?
    /// Always present, empty when the envelope carried no files.
    public let files: [OpenedFile]
    public let note: String?

    public init(note: String?, credentials: Credentials?, files: [OpenedFile]) {
      self.credentials = credentials
      self.files = files
      self.note = note
    }

    /// Everything that goes on a clipboard, as one block of text, labelled the way
    /// somebody would say it aloud. `nil` when the secret was only files.
    ///
    /// This is apps/web/src/reveal/parts.ts `allOf`, in Swift. The two have to
    /// agree: a recipient who opens the same link in a browser and in this app
    /// must not end up pasting two different things.
    ///
    /// Files are not in here. They go to the disk, and a filename on a clipboard
    /// would be a name with no file behind it.
    public var clipboardText: String? {
      var blocks: [String] = []

      if let note {
        blocks.append(note)
      }
      if let credentials {
        blocks.append(
          "username: \(credentials.username)\npassword: \(credentials.password)"
        )
      }

      return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
  }

  /// A wrong key, a tampered ciphertext and a ciphertext moved to another id are
  /// one error on purpose. Locally we could tell some of them apart; saying which
  /// would be the verifier the product promised not to build.
  public enum OpenFailure: LocalizedError, Sendable, Equatable {
    case decryptionFailed
    case invalidEnvelope(String)
    case needsPassword

    public var errorDescription: String? {
      switch self {
      case .decryptionFailed:
        return "This secret could not be opened: the link is wrong or the data was changed."
      case .invalidEnvelope(let detail):
        return "This secret opened into something SecureSend does not recognise: \(detail)."
      case .needsPassword:
        return "This link needs a password."
      }
    }
  }

  /// Opens one envelope, or throws. Nothing here touches the network or any storage.
  public static func open(stored: StoredEnvelope, token: FragmentToken) throws -> Opened {
    guard case .plain(let keyBytes) = token else {
      throw OpenFailure.needsPassword
    }

    let key = SymmetricKey(data: keyBytes)
    let contents = try readContents(
      try decrypt(key: key, sealed: stored.envelope, aad: envelopeAad(id: stored.id))
    )

    var byIndex: [Int: AttachmentCiphertext] = [:]
    for attachment in stored.attachments {
      byIndex[attachment.index] = attachment
    }
    guard byIndex.count == stored.attachments.count else {
      throw OpenFailure.invalidEnvelope("two attachments claim one index")
    }
    // Counts and sizes come out of the decrypted envelope, so they stay out of
    // these messages: an error that gets logged must carry no part of a secret.
    guard byIndex.count == contents.files.count else {
      throw OpenFailure.invalidEnvelope(
        "the attachments do not match what the envelope declares"
      )
    }

    let files = try contents.files.enumerated().map { index, meta -> OpenedFile in
      guard let attachment = byIndex[index] else {
        throw OpenFailure.invalidEnvelope("attachment \(index) is missing")
      }

      let bytes = try decrypt(
        key: key,
        sealed: Ciphertext(ciphertext: attachment.ciphertext, iv: attachment.iv),
        aad: attachmentAad(id: stored.id, index: index)
      )
      guard bytes.count == meta.size else {
        throw OpenFailure.invalidEnvelope(
          "attachment \(index) is not the size the envelope declares"
        )
      }

      return OpenedFile(bytes: bytes, name: meta.name, size: meta.size, type: meta.type)
    }

    return Opened(note: contents.note, credentials: contents.credentials, files: files)
  }

  // MARK: - Inside

  private struct EnvelopeFile {
    let name: String
    let size: Int
    let type: String
  }

  private struct EnvelopeContents {
    let credentials: Credentials?
    let files: [EnvelopeFile]
    let note: String?
  }

  /// Every way this can fail is the same failure, including unreadable base64url.
  private static func decrypt(key: SymmetricKey, sealed: Ciphertext, aad: Data) throws -> Data {
    guard
      let iv = try? base64urlDecode(sealed.iv),
      let combined = try? base64urlDecode(sealed.ciphertext),
      combined.count >= tagBytes,
      let nonce = try? AES.GCM.Nonce(data: iv)
    else {
      throw OpenFailure.decryptionFailed
    }

    // Web Crypto appends the tag to the ciphertext; CryptoKit wants them apart.
    let split = combined.index(combined.endIndex, offsetBy: -tagBytes)
    guard
      let box = try? AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: combined[..<split],
        tag: combined[split...]
      ),
      let plaintext = try? AES.GCM.open(box, using: key, authenticating: aad)
    else {
      throw OpenFailure.decryptionFailed
    }

    return plaintext
  }

  /// JSON that is not a number and not a boolean, which is what every string field
  /// in an envelope has to be. A `null` is a present field of the wrong type, and
  /// is refused rather than read as absent.
  private static func string(_ value: Any) throws -> String {
    guard let text = value as? String else {
      throw OpenFailure.invalidEnvelope("a field that has to be text is not")
    }
    return text
  }

  /// An integer, and not a boolean wearing one. JSON has one number type, so the
  /// check is that what arrived is whole and not negative.
  private static func size(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    guard let whole = value as? Int, Double(whole) == number.doubleValue, whole >= 0 else {
      return nil
    }
    return whole
  }

  private static func readContents(_ plaintext: Data) throws -> EnvelopeContents {
    // A JSON syntax error quotes the text around the break, and that text is the
    // decrypted secret, so nothing this throws carries the parser's own message.
    guard let parsed = try? JSONSerialization.jsonObject(with: plaintext) else {
      throw OpenFailure.invalidEnvelope("the envelope is not json")
    }
    guard let object = parsed as? [String: Any] else {
      throw OpenFailure.invalidEnvelope("the envelope is not an object")
    }
    guard let version = object["v"] as? Int, version == envelopeVersion else {
      throw OpenFailure.invalidEnvelope("not a version \(envelopeVersion) envelope")
    }

    let note = try object["note"].map(string)

    let credentials = try object["credentials"].map { value -> Credentials in
      guard let pair = value as? [String: Any] else {
        throw OpenFailure.invalidEnvelope("the credentials are not a pair of strings")
      }
      guard let username = pair["username"], let password = pair["password"] else {
        throw OpenFailure.invalidEnvelope("the credentials are not a pair of strings")
      }
      return Credentials(password: try string(password), username: try string(username))
    }

    let files = try object["files"].map { value -> [EnvelopeFile] in
      guard let list = value as? [Any] else {
        throw OpenFailure.invalidEnvelope("the file list is not file metadata")
      }
      return try list.map { entry in
        guard
          let file = entry as? [String: Any],
          let name = file["name"], let type = file["type"],
          let declared = file["size"].flatMap(size)
        else {
          throw OpenFailure.invalidEnvelope("the file list is not file metadata")
        }
        return EnvelopeFile(
          name: try string(name), size: declared, type: try string(type)
        )
      }
    }

    guard note != nil || credentials != nil || files != nil else {
      throw OpenFailure.invalidEnvelope("the envelope has no parts")
    }

    return EnvelopeContents(credentials: credentials, files: files ?? [], note: note)
  }
}
