import Foundation
import Testing

@testable import SecureSendKit

// Where an attachment lands.
//
// A filename comes out of the envelope, which means it comes from whoever sealed
// it. Nothing about a decrypted name makes it safe: the sender chose it, and a
// recipient opening a link from a stranger is the normal case for this product.
// So the name is treated as hostile text, and the only thing it may decide is
// what a file inside the chosen folder is called.

private func file(_ name: String, _ body: String = "x") -> SecureSendCrypto.OpenedFile {
  let bytes = Data(body.utf8)
  return SecureSendCrypto.OpenedFile(
    bytes: bytes, name: name, size: bytes.count, type: "text/plain"
  )
}

@Suite("Saving attachments")
struct DownloadsTests {
  // MARK: - The name

  @Test("an ordinary name is left alone", arguments: [
    "notes.txt", "Invoice 2026.pdf", "smörgås.txt", "a.tar.gz", ".bashrc",
  ])
  func ordinary(name: String) {
    #expect(Downloads.safeName(name) == name)
  }

  /// The one that matters. None of these may write outside the chosen folder.
  @Test("a name that tries to leave the folder is reduced to a name", arguments: [
    ("parent", "../secrets.txt", "secrets.txt"),
    ("far above", "../../../../etc/passwd", "passwd"),
    ("absolute", "/etc/passwd", "passwd"),
    ("a home path", "~/.ssh/authorized_keys", "authorized_keys"),
    ("nested", "a/b/c.txt", "c.txt"),
    ("a trailing slash", "folder/", "folder"),
    ("backslashes", "..\\..\\windows\\system32", "windows_system32"),
  ])
  func escaping(name: String, raw: String, want: String) {
    #expect(Downloads.safeName(raw) == want, "\(name) must not escape")
  }

  /// A name that reduces to nothing, or to something the filesystem reads as a
  /// directory, gets this app's own name rather than a guess at the sender's.
  @Test("a name with nothing usable left falls back", arguments: [
    "", " ", ".", "..", "/", "/////", "...", "\u{0}", "\n\t",
  ])
  func fallsBack(raw: String) {
    #expect(Downloads.safeName(raw) == Downloads.unnamed)
  }

  @Test("control characters and separators are stripped, not kept")
  func strips() {
    #expect(Downloads.safeName("a\u{0}b.txt") == "ab.txt")
    #expect(Downloads.safeName("two\nlines.txt") == "twolines.txt")
    #expect(Downloads.safeName("tab\there.txt") == "tabhere.txt")
  }

  /// Filesystems cap a component at 255 bytes, and the cut has to land on a
  /// character boundary or the name is not a string any more.
  @Test("an absurdly long name is cut to something the filesystem takes")
  func truncates() {
    let long = Downloads.safeName(String(repeating: "å", count: 500))

    #expect(long.utf8.count <= 255)
    #expect(long.isEmpty == false)
    // Cut on a character boundary: every å survived whole or not at all.
    #expect(long.allSatisfy { $0 == "å" })
  }

  // MARK: - Landing

  @Test("a file lands with its bytes intact")
  func saves() throws {
    try inTemporaryFolder { folder in
      let saved = try Downloads.save([file("notes.txt", "hello")], into: folder)

      #expect(saved.count == 1)
      #expect(saved[0].lastPathComponent == "notes.txt")
      #expect(try Data(contentsOf: saved[0]) == Data("hello".utf8))
    }
  }

  /// Downloads is somebody's real folder with their real files in it. Nothing
  /// this app does may overwrite one of them.
  @Test("an existing file is never overwritten")
  func neverOverwrites() throws {
    try inTemporaryFolder { folder in
      let taken = folder.appendingPathComponent("notes.txt")
      try Data("theirs".utf8).write(to: taken)

      let saved = try Downloads.save([file("notes.txt", "ours")], into: folder)

      #expect(saved[0].lastPathComponent == "notes 2.txt")
      #expect(try Data(contentsOf: taken) == Data("theirs".utf8))
      #expect(try Data(contentsOf: saved[0]) == Data("ours".utf8))
    }
  }

  @Test("two attachments with one name both land")
  func collidingAttachments() throws {
    try inTemporaryFolder { folder in
      let saved = try Downloads.save(
        [file("same.txt", "first"), file("same.txt", "second")], into: folder
      )

      #expect(saved.map(\.lastPathComponent) == ["same.txt", "same 2.txt"])
      #expect(try Data(contentsOf: saved[0]) == Data("first".utf8))
      #expect(try Data(contentsOf: saved[1]) == Data("second".utf8))
    }
  }

  @Test("the suffix goes before the extension, not after the name")
  func suffixPlacement() throws {
    try inTemporaryFolder { folder in
      let saved = try Downloads.save(
        [file("a.tar.gz", "1"), file("a.tar.gz", "2"), file("a.tar.gz", "3")], into: folder
      )

      #expect(saved.map(\.lastPathComponent) == ["a.tar.gz", "a.tar 2.gz", "a.tar 3.gz"])
    }
  }

  @Test("a file with no extension still gets a suffix")
  func noExtension() throws {
    try inTemporaryFolder { folder in
      let saved = try Downloads.save([file("README", "1"), file("README", "2")], into: folder)

      #expect(saved.map(\.lastPathComponent) == ["README", "README 2"])
    }
  }

  /// The whole point of the name handling, checked at the filesystem rather than
  /// at the string: whatever the sender called it, it is inside the folder.
  @Test("a hostile name still lands inside the folder")
  func staysInside() throws {
    try inTemporaryFolder { folder in
      let saved = try Downloads.save([file("../../escaped.txt", "nope")], into: folder)

      #expect(saved[0].deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
      #expect(saved[0].lastPathComponent == "escaped.txt")
    }
  }
}

private func inTemporaryFolder(_ body: (URL) throws -> Void) throws {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("securesend-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }

  try body(folder)
}
