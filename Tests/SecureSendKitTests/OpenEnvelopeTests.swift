import Foundation
import Testing

@testable import SecureSendKit

// Opening an envelope, against ciphertext packages/crypto produced.

@Suite("Opening an envelope")
struct OpenEnvelopeTests {
  // The password fixture is left out on purpose: it has its own refusal test.
  @Test(
    "every fixture opens to exactly what the sender sealed",
    arguments: Fixtures.withoutPassword
  )
  func opensEveryFixture(fixture: Fixture) throws {
    let opened = try SecureSendCrypto.open(stored: fixture.storedEnvelope, token: fixture.token)

    #expect(opened.note == fixture.expect.note)
    #expect(opened.credentials == fixture.expect.credentials)
    #expect(opened.files.count == fixture.expect.files.count)

    for (got, want) in zip(opened.files, fixture.expect.files) {
      #expect(got.name == want.name)
      #expect(got.type == want.type)
      #expect(got.size == want.size)
      #expect(got.bytes == Data(base64Encoded: want.base64))
      // The declared size is the decrypted length, never a number taken on trust.
      #expect(got.bytes.count == want.size)
    }
  }

  @Test("a tampered ciphertext is refused")
  func refusesTampering() throws {
    let fixture = Fixtures.named("note-only")
    var bytes = try SecureSendCrypto.base64urlDecode(fixture.stored.envelope.ciphertext)
    bytes[0] ^= 0x01

    let tampered = SecureSendCrypto.StoredEnvelope(
      attachments: [],
      envelope: SecureSendCrypto.Ciphertext(
        ciphertext: SecureSendCrypto.base64url(bytes), iv: fixture.stored.envelope.iv
      ),
      id: fixture.stored.id
    )

    #expect(throws: SecureSendCrypto.OpenFailure.decryptionFailed) {
      try SecureSendCrypto.open(stored: tampered, token: fixture.token)
    }
  }

  /// The id is the envelope's additional data, so a ciphertext served under another
  /// id must not open. This is the check that a stolen row cannot be replayed.
  @Test("a ciphertext moved to another id is refused")
  func refusesMovedCiphertext() throws {
    let fixture = Fixtures.named("note-only")
    let moved = SecureSendCrypto.StoredEnvelope(
      attachments: [],
      envelope: fixture.storedEnvelope.envelope,
      id: Fixtures.named("credentials-only").stored.id
    )

    #expect(throws: SecureSendCrypto.OpenFailure.decryptionFailed) {
      try SecureSendCrypto.open(stored: moved, token: fixture.token)
    }
  }

  @Test("another envelope's key is refused")
  func refusesWrongKey() throws {
    let fixture = Fixtures.named("note-only")

    #expect(throws: SecureSendCrypto.OpenFailure.decryptionFailed) {
      try SecureSendCrypto.open(
        stored: fixture.storedEnvelope, token: Fixtures.named("files").token
      )
    }
  }

  /// An envelope opens as one thing. Attachments that do not match what the
  /// envelope declares fail the whole open rather than handing over a partial
  /// secret that reads as a whole one.
  @Test("a missing attachment fails the whole envelope")
  func refusesMissingAttachment() throws {
    let fixture = Fixtures.named("files")
    let short = SecureSendCrypto.StoredEnvelope(
      attachments: Array(fixture.storedEnvelope.attachments.dropLast()),
      envelope: fixture.storedEnvelope.envelope,
      id: fixture.stored.id
    )

    #expect(throws: SecureSendCrypto.OpenFailure.self) {
      try SecureSendCrypto.open(stored: short, token: fixture.token)
    }
  }

  @Test("two attachments claiming one index fail the whole envelope")
  func refusesDuplicateIndex() throws {
    let fixture = Fixtures.named("files")
    let first = fixture.storedEnvelope.attachments[0]
    let doubled = SecureSendCrypto.StoredEnvelope(
      attachments: [first, first],
      envelope: fixture.storedEnvelope.envelope,
      id: fixture.stored.id
    )

    #expect(throws: SecureSendCrypto.OpenFailure.self) {
      try SecureSendCrypto.open(stored: doubled, token: fixture.token)
    }
  }

  /// Attachments arrive in whatever order the wire hands them over. They are
  /// matched by index, so a shuffled list has to open to the same files.
  @Test("attachments are matched by index, not by position")
  func matchesAttachmentsByIndex() throws {
    let fixture = Fixtures.named("files")
    let shuffled = SecureSendCrypto.StoredEnvelope(
      attachments: fixture.storedEnvelope.attachments.reversed(),
      envelope: fixture.storedEnvelope.envelope,
      id: fixture.stored.id
    )

    let opened = try SecureSendCrypto.open(stored: shuffled, token: fixture.token)

    #expect(opened.files.map(\.name) == ["first.txt", "second.bin"])
  }

  /// The app hands password links to the browser rather than prompting, so this
  /// path has to refuse loudly instead of quietly failing to decrypt.
  @Test("a password-protected envelope is refused rather than attempted")
  func refusesPasswordProtected() throws {
    let fixture = Fixtures.named("password-protected")
    try #require(fixture.password != nil)
    try #require(fixture.token.needsPassword)

    #expect(throws: SecureSendCrypto.OpenFailure.needsPassword) {
      try SecureSendCrypto.open(stored: fixture.storedEnvelope, token: fixture.token)
    }
  }

  /// What this app seals still has to be what this app can open, so a change to
  /// one half cannot pass by breaking both.
  @Test("what the app seals, the app opens")
  func sealsAndOpens() throws {
    let sealed = try SecureSendCrypto.seal(note: "round trip")
    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(sealed.fragmentToken) else {
      Issue.record("a freshly sealed fragment token did not decode")
      return
    }

    let opened = try SecureSendCrypto.open(
      stored: SecureSendCrypto.StoredEnvelope(
        attachments: [],
        envelope: SecureSendCrypto.Ciphertext(
          ciphertext: sealed.ciphertext, iv: sealed.iv
        ),
        id: sealed.id
      ),
      token: token
    )

    #expect(opened.note == "round trip")
    #expect(opened.credentials == nil)
    #expect(opened.files.isEmpty)
  }
}
