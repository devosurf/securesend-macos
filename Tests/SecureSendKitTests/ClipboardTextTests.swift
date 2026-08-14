import Foundation
import Testing

@testable import SecureSendKit

// What lands on the clipboard, which has to be what the web hands over for the
// same envelope. The web's version is apps/web/src/reveal/parts.ts `allOf`, and
// the two being one sentence apart is how a recipient ends up pasting something
// different depending on which door they came through.

@Suite("What goes on the clipboard")
struct ClipboardTextTests {
  @Test("a note alone is the note, untouched")
  func noteOnly() {
    #expect(
      SecureSendCrypto.Opened(credentials: nil, files: [], note: "hunter2").clipboardText
        == "hunter2"
    )
  }

  /// Labelled, because what lands on a clipboard is usually pasted into a chat
  /// where the label is the only thing telling the two apart.
  @Test("credentials are labelled, one per line")
  func credentialsOnly() {
    let opened = SecureSendCrypto.Opened(
      credentials: SecureSendCrypto.Credentials(password: "s3cr3t", username: "root"),
      files: [],
      note: nil
    )

    #expect(opened.clipboardText == "username: root\npassword: s3cr3t")
  }

  @Test("a note comes first, then the pair, separated by a blank line")
  func both() {
    let opened = SecureSendCrypto.Opened(
      credentials: SecureSendCrypto.Credentials(password: "s3cr3t", username: "root"),
      files: [],
      note: "the staging box"
    )

    #expect(opened.clipboardText == "the staging box\n\nusername: root\npassword: s3cr3t")
  }

  /// Files go to the disk. A filename on a clipboard would be a name with no
  /// file behind it, so an envelope of only files leaves the clipboard alone.
  @Test("files alone put nothing on the clipboard")
  func filesOnly() {
    let opened = SecureSendCrypto.Opened(
      credentials: nil,
      files: [
        SecureSendCrypto.OpenedFile(
          bytes: Data("alone".utf8), name: "solo.txt", size: 5, type: "text/plain"
        )
      ],
      note: nil
    )

    #expect(opened.clipboardText == nil)
  }

  /// An empty note is a note. The sender typed nothing and meant it, and the web
  /// puts the same nothing on the clipboard.
  @Test("an empty note is still a note")
  func emptyNote() {
    #expect(
      SecureSendCrypto.Opened(credentials: nil, files: [], note: "").clipboardText == ""
    )
  }

  @Test("every openable fixture agrees with what the web would copy", arguments: Fixtures.withoutPassword)
  func matchesFixtures(fixture: Fixture) throws {
    let opened = try SecureSendCrypto.open(stored: fixture.storedEnvelope, token: fixture.token)

    var blocks: [String] = []
    if let note = fixture.expect.note {
      blocks.append(note)
    }
    if let pair = fixture.expect.credentials {
      blocks.append("username: \(pair.username)\npassword: \(pair.password)")
    }

    #expect(opened.clipboardText == (blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")))
  }
}
