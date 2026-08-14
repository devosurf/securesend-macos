import Foundation
import Testing

@testable import SecureSendKit

// The fragment token, which is the whole key. Everything a chat client does to a
// link on its way through has to come out as `incomplete` rather than as a token
// that decodes to something plausible.

@Suite("Reading a fragment token")
struct FragmentTokenTests {
  /// 34 bytes plain, 50 with a salt: 46 or 67 base64url characters. The fixtures
  /// come from packages/crypto, so this is the two formats agreeing on lengths.
  @Test("the two token lengths are the documented ones")
  func lengths() {
    #expect(Fixtures.named("note-only").fragmentToken.count == 46)
    #expect(Fixtures.named("password-protected").fragmentToken.count == 67)
  }

  @Test("a plain token yields a 32 byte key and no password flag")
  func plain() {
    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(
      Fixtures.named("note-only").fragmentToken
    ) else {
      Issue.record("a token packages/crypto produced did not decode")
      return
    }

    #expect(token.needsPassword == false)
    #expect(token.key.count == SecureSendCrypto.fragmentKeyBytes)
  }

  @Test("a password token yields the key and the salt")
  func passwordProtected() {
    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(
      Fixtures.named("password-protected").fragmentToken
    ) else {
      Issue.record("a token packages/crypto produced did not decode")
      return
    }

    #expect(token.needsPassword)
    #expect(token.key.count == SecureSendCrypto.fragmentKeyBytes)
    guard case .passwordProtected(_, let salt) = token else {
      Issue.record("a flagged token came back without its salt")
      return
    }
    #expect(salt.count == SecureSendCrypto.fragmentSaltBytes)
  }

  @Test("what this app encodes, this app decodes")
  func roundTrip() {
    let key = SecureSendCrypto.randomBytes(SecureSendCrypto.fragmentKeyBytes)
    let encoded = SecureSendCrypto.encodeFragmentToken(key: key)

    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(encoded) else {
      Issue.record("a freshly encoded token did not decode")
      return
    }

    #expect(token.key == key)
    #expect(token.needsPassword == false)
  }

  // Each of these is a real way a link gets damaged on its way to somebody.
  @Test(
    "a damaged token is incomplete rather than a key",
    arguments: [
      ("empty", ""),
      ("truncated", String(Fixtures.named("note-only").fragmentToken.dropLast(4))),
      ("one character too many", "\(Fixtures.named("note-only").fragmentToken)A"),
      ("a character dropped", String(Fixtures.named("note-only").fragmentToken.dropFirst())),
      ("not base64url", "AQ!!vw_nKhD6JUPzjL0NC6RyimjMrKpoIcLEK5y7YwHjklQ"),
      ("standard base64 padding", "AQAvw/nKhD6JUPzjL0NC6RyimjMrKpoIcLEK5y7YwHjklQ=="),
      ("a plain token carrying a salt", "AQAvw_nKhD6JUPzjL0NC6RyimjMrKpoIcLEK5y7YwHjklQAAAAAAAAAAAAAAAAAAAAA"),
    ]
  )
  func damaged(name: String, encoded: String) {
    #expect(
      SecureSendCrypto.decodeFragmentToken(encoded) == .incomplete,
      "\(name) should not decode to a key"
    )
  }

  /// The version and the flags are the two bytes that say how to read the rest.
  /// An unknown value in either is a token from a future this build cannot read.
  @Test("an unknown version or flag byte is incomplete")
  func unknownHeaderBytes() {
    var future = Data([2, 0])
    future.append(SecureSendCrypto.randomBytes(SecureSendCrypto.fragmentKeyBytes))
    #expect(SecureSendCrypto.decodeFragmentToken(SecureSendCrypto.base64url(future)) == .incomplete)

    var flagged = Data([1, 0x02])
    flagged.append(SecureSendCrypto.randomBytes(SecureSendCrypto.fragmentKeyBytes))
    #expect(SecureSendCrypto.decodeFragmentToken(SecureSendCrypto.base64url(flagged)) == .incomplete)
  }

  /// The encoder leaves the bits past the last whole byte at zero, so anything
  /// else is a corrupted final character and must not decode to a plausible key.
  @Test("trailing bits are refused")
  func trailingBits() throws {
    let clean = Fixtures.named("note-only").fragmentToken
    // The last character of a 46 character token carries 4 unused bits. "A" is
    // zero in all six, so a character with a bit set in the unused four is junk.
    let dirty = "\(clean.dropLast())B"
    try #require(dirty != clean)

    #expect(SecureSendCrypto.decodeFragmentToken(dirty) == .incomplete)
  }
}
