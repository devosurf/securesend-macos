import Foundation
import Testing

@testable import SecureSendKit

// Recognising one of our links in a piece of text.
//
// This is the gate in front of everything destructive, so it errs towards not
// recognising: a string this refuses costs somebody one beep, and a string it
// wrongly accepts sends a reveal at a stranger's id.

private let token = Fixtures.named("note-only").fragmentToken
private let id = "ZFKG_mXqcjqMb5fU3WjV0Q"
private let good = "https://securesend.dev/s/\(id)#\(token)"

@Suite("Reading a link")
struct LinkTests {
  @Test("a link is read into its id and its fragment")
  func reads() {
    #expect(SecureSendLink.read(good) == .link(id: id, fragment: token))
  }

  /// What comes off a clipboard has been through a chat client, an email client
  /// and somebody's selection, so surrounding whitespace is the normal case.
  @Test(
    "surrounding whitespace does not stop it",
    arguments: ["  \(good)", "\(good)\n", "\n\t \(good) \n"]
  )
  func trims(text: String) {
    #expect(SecureSendLink.read(text) == .link(id: id, fragment: token))
  }

  /// A host is case-insensitive and a link that came back through a mail client
  /// may well have been touched. An id is not: base64url is case-sensitive, and
  /// the refusal test below covers that side.
  @Test(
    "the scheme and host are read case-insensitively",
    arguments: [
      "https://SecureSend.dev/s/\(id)#\(token)",
      "https://SECURESEND.DEV/s/\(id)#\(token)",
      "HTTPS://securesend.dev/s/\(id)#\(token)",
    ]
  )
  func hostCase(text: String) {
    #expect(SecureSendLink.read(text) == .link(id: id, fragment: token))
  }

  @Test("an id with its case changed is a different id, and is refused")
  func idCase() {
    let flipped = "zfkg_MxQCJQmB5Fu3wJv0q"
    #expect(flipped != id)
    #expect(SecureSendLink.read("https://securesend.dev/s/\(flipped)#\(token)") != .link(id: id, fragment: token))
  }

  @Test("a link without its fragment is incomplete, not openable")
  func withoutFragment() {
    #expect(SecureSendLink.read("https://securesend.dev/s/\(id)") == .incomplete)
    #expect(SecureSendLink.read("https://securesend.dev/s/\(id)#") == .incomplete)
  }

  // Every one of these is something that must never reach a reveal.
  @Test(
    "anything that is not one of our links is refused",
    arguments: [
      ("empty", ""),
      ("prose", "hello there"),
      ("a bare word", "securesend"),
      ("another host", "https://securesend.example/s/\(id)#\(token)"),
      ("a lookalike host", "https://securesend.dev.evil.example/s/\(id)#\(token)"),
      ("a subdomain", "https://www.securesend.dev/s/\(id)#\(token)"),
      ("plain http", "http://securesend.dev/s/\(id)#\(token)"),
      ("another path", "https://securesend.dev/new#\(token)"),
      ("a nested path", "https://securesend.dev/s/\(id)/extra#\(token)"),
      ("no path at all", "https://securesend.dev#\(token)"),
      ("an id one character short", "https://securesend.dev/s/\(String(id.dropLast()))#\(token)"),
      ("an id one character long", "https://securesend.dev/s/\(id)A#\(token)"),
      ("an id that is not base64url", "https://securesend.dev/s/ZFKG!mXqcjqMb5fU3WjV0Q#\(token)"),
    ]
  )
  func refuses(name: String, text: String) {
    #expect(SecureSendLink.read(text) == .notALink, "\(name) should not read as a link")
  }

  /// The fragment is checked by whoever decodes it, not here. This only has to
  /// carry it across intact, including the characters base64url uses.
  @Test("the fragment is handed over exactly as it arrived")
  func fragmentVerbatim() {
    let odd = "AQ-_aB"
    #expect(
      SecureSendLink.read("https://securesend.dev/s/\(id)#\(odd)")
        == .link(id: id, fragment: odd)
    )
  }

  /// A link the app itself just made has to be one the app can read back.
  @Test("a link this app builds reads back")
  func roundTrip() throws {
    let sealed = try SecureSendCrypto.seal(note: "round trip")
    let built = "\(SecureSendAPI.origin)/s/\(sealed.id)#\(sealed.fragmentToken)"

    #expect(SecureSendLink.read(built) == .link(id: sealed.id, fragment: sealed.fragmentToken))
  }
}
