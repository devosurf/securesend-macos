import Foundation
import Testing

@testable import SecureSendKit

// Sealing, checked by opening. `Tests/.../Fixtures` proves this build can read
// what packages/crypto wrote; this proves what this build writes is the same
// shape, using the reader that already agrees with the web one.
//
// The binding tests are the ones that matter. Every ciphertext is tied to its id
// and every attachment to its position, and that tie is the only thing stopping a
// ciphertext from being served under another id or at another index.

private func file(_ name: String, _ body: String, type: String = "text/plain")
  -> SecureSendCrypto.FileToSeal
{
  SecureSendCrypto.FileToSeal(bytes: Data(body.utf8), name: name, type: type)
}

/// A sealed envelope read back the way a reveal hands one over.
private func opened(_ sealed: SecureSendCrypto.Sealed, id: String? = nil) throws
  -> SecureSendCrypto.Opened
{
  guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(sealed.fragmentToken) else {
    throw SecureSendCrypto.OpenFailure.decryptionFailed
  }

  return try SecureSendCrypto.open(
    stored: SecureSendCrypto.StoredEnvelope(
      attachments: sealed.attachments,
      envelope: SecureSendCrypto.Ciphertext(ciphertext: sealed.ciphertext, iv: sealed.iv),
      id: id ?? sealed.id
    ),
    token: token
  )
}

@Suite("Sealing an envelope")
struct SealTests {
  @Test("a note comes back as the note, byte for byte")
  func note() throws {
    let secret = "  hunter2\nwith a trailing space \n"

    #expect(try opened(SecureSendCrypto.seal(note: secret)).note == secret)
  }

  @Test("a note alone carries no attachments")
  func noFiles() throws {
    let sealed = try SecureSendCrypto.seal(note: "x")

    #expect(sealed.attachments.isEmpty)
    #expect(try opened(sealed).files.isEmpty)
  }

  @Test("an envelope with nothing in it is refused rather than sealed")
  func nothing() {
    #expect(throws: SecureSendCrypto.SealFailure.nothingToSeal) {
      try SecureSendCrypto.seal()
    }
  }

  @Test("files come back with their bytes, names, sizes and types")
  func files() throws {
    let sealed = try SecureSendCrypto.seal(
      files: [
        file("notes.txt", "hello"),
        file("blob.bin", "\u{0}\u{1}binary", type: ""),
      ]
    )

    #expect(sealed.attachments.map(\.index) == [0, 1])

    let out = try opened(sealed)
    #expect(out.note == nil)
    #expect(out.files.map(\.name) == ["notes.txt", "blob.bin"])
    #expect(out.files.map(\.type) == ["text/plain", ""])
    #expect(out.files[0].bytes == Data("hello".utf8))
    #expect(out.files[0].size == 5)
    #expect(out.files[1].bytes == Data("\u{0}\u{1}binary".utf8))
  }

  @Test("a note and files travel in one envelope")
  func both() throws {
    let out = try opened(
      try SecureSendCrypto.seal(note: "the password is inside", files: [file("k.pem", "key")])
    )

    #expect(out.note == "the password is inside")
    #expect(out.files.map(\.name) == ["k.pem"])
  }

  /// Every ciphertext gets its own IV. Two files with identical bytes must not
  /// produce identical ciphertext, or the wire says which files match.
  @Test("two identical files do not seal to identical ciphertext")
  func freshIvs() throws {
    let sealed = try SecureSendCrypto.seal(files: [file("a", "same"), file("b", "same")])

    #expect(sealed.attachments[0].iv != sealed.attachments[1].iv)
    #expect(sealed.attachments[0].ciphertext != sealed.attachments[1].ciphertext)
  }

  // MARK: - What the binding stops

  @Test("an envelope served under another id does not open")
  func boundToItsId() throws {
    let sealed = try SecureSendCrypto.seal(note: "x")

    #expect(throws: SecureSendCrypto.OpenFailure.decryptionFailed) {
      try opened(sealed, id: SecureSendCrypto.newSecretId())
    }
  }

  @Test("an attachment moved to another position does not open")
  func boundToItsIndex() throws {
    let sealed = try SecureSendCrypto.seal(
      files: [file("first.txt", "one"), file("second.txt", "two")]
    )

    let swapped = SecureSendCrypto.Sealed(
      attachments: [
        SecureSendCrypto.AttachmentCiphertext(
          ciphertext: sealed.attachments[1].ciphertext, index: 0, iv: sealed.attachments[1].iv
        ),
        SecureSendCrypto.AttachmentCiphertext(
          ciphertext: sealed.attachments[0].ciphertext, index: 1, iv: sealed.attachments[0].iv
        ),
      ],
      ciphertext: sealed.ciphertext,
      fragmentToken: sealed.fragmentToken,
      id: sealed.id,
      iv: sealed.iv
    )

    #expect(throws: SecureSendCrypto.OpenFailure.decryptionFailed) { try opened(swapped) }
  }
}
