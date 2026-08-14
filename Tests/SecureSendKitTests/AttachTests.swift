import Foundation
import Testing

@testable import SecureSendKit

// What comes off the disk, and what is refused before anything is read.
//
// The order is the thing under test as much as the caps are. A file past a cap
// has to be refused from what the filesystem already knows, because reading and
// encrypting forty megabytes and then saying no is the wrong way round.

@Suite("Attaching files")
struct AttachTests {
  // MARK: - What comes off the disk

  @Test("a file arrives with its bytes, its name and its type")
  func reads() throws {
    try inTemporaryFolder { folder in
      let files = try Attach.read([try write("notes.txt", "hello", into: folder)])

      #expect(files.count == 1)
      #expect(files[0].name == "notes.txt")
      #expect(files[0].bytes == Data("hello".utf8))
      #expect(files[0].type == "text/plain")
    }
  }

  /// The web client sends `File.type`, which is empty when the browser has no
  /// name for the file. An unknown extension has to land in the same place.
  @Test("a file the system cannot name has no type rather than a made up one")
  func unknownType() throws {
    try inTemporaryFolder { folder in
      let files = try Attach.read([try write("blob.zzqq", "x", into: folder)])

      #expect(files[0].type == "")
    }
  }

  /// Position is meaning: an attachment is bound to its index, so the order the
  /// caller passed has to be the order that comes back.
  @Test("the order given is the order kept")
  func keepsOrder() throws {
    try inTemporaryFolder { folder in
      let files = try Attach.read([
        try write("a.txt", "1", into: folder),
        try write("b.txt", "2", into: folder),
        try write("c.txt", "3", into: folder),
      ])

      #expect(files.map(\.name) == ["a.txt", "b.txt", "c.txt"])
    }
  }

  // MARK: - What is refused

  @Test("nothing selected is its own refusal")
  func nothing() {
    #expect(throws: Attach.Failure.nothingToSend) { try Attach.read([]) }
  }

  @Test("a folder is refused rather than read as a file")
  func folder() throws {
    try inTemporaryFolder { folder in
      let inside = folder.appendingPathComponent("papers")
      try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

      #expect(throws: Attach.Failure.notAFile) { try Attach.read([inside]) }
    }
  }

  /// Not `notAFile`: a url that is gone is a different thing from a folder, and
  /// telling somebody their file is a folder would send them looking for one.
  @Test("a file that is not there comes back as the filesystem's own reason")
  func missing() throws {
    try inTemporaryFolder { folder in
      let gone = folder.appendingPathComponent("nope.txt")

      guard case .unreadable? = failure(from: { try Attach.read([gone]) }) else {
        Issue.record("a missing file has to read as unreadable")
        return
      }
    }
  }

  @Test("one file past the count is refused, and says how many there were")
  func tooMany() throws {
    try inTemporaryFolder { folder in
      let urls = try (0...Attach.maxAttachments).map {
        try write("f\($0).txt", "x", into: folder)
      }

      #expect(throws: Attach.Failure.tooMany(count: Attach.maxAttachments + 1)) {
        try Attach.read(urls)
      }
    }
  }

  /// The cap is on the whole secret, so it has to be checked from what the
  /// filesystem says before a single byte is read. A sparse file is the check:
  /// it weighs ten megabytes and costs nothing to make, and reading it is exactly
  /// the work this must not do.
  @Test("a file past the total is refused without being read")
  func tooBig() throws {
    try inTemporaryFolder { folder in
      let big = try sparse("big.bin", bytes: Attach.maxTotalBytes, into: folder)

      #expect(throws: Attach.Failure.tooBig(bytes: Attach.maxTotalBytes)) {
        try Attach.read([big])
      }
    }
  }

  /// The case a per-file limit waves through, and the reason the instance caps a
  /// total rather than a file.
  @Test("two files that each fit and together do not are refused")
  func tooBigTogether() throws {
    try inTemporaryFolder { folder in
      let half = Attach.maxTotalBytes / 2
      let urls = [
        try sparse("a.bin", bytes: half, into: folder),
        try sparse("b.bin", bytes: half, into: folder),
      ]

      #expect(throws: Attach.Failure.tooBig(bytes: half * 2)) { try Attach.read(urls) }
    }
  }

  /// The other side of the same boundary: everything the instance would store,
  /// down to the last byte this build believes it will take.
  @Test("a file that exactly fits is read")
  func exactlyFits() throws {
    try inTemporaryFolder { folder in
      let fits = Attach.maxTotalBytes - Attach.scaffoldingBytes
      let files = try Attach.read([try sparse("edge.bin", bytes: fits, into: folder)])

      #expect(files[0].bytes.count == fits)
    }
  }
}

// MARK: - Fixtures

private func write(_ name: String, _ body: String, into folder: URL) throws -> URL {
  let url = folder.appendingPathComponent(name)
  try Data(body.utf8).write(to: url)
  return url
}

/// A file that weighs what it says and occupies nothing, so the tests that must
/// not read one can prove it by being instant.
private func sparse(_ name: String, bytes: Int, into folder: URL) throws -> URL {
  let url = folder.appendingPathComponent(name)
  try Data().write(to: url)

  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.truncate(atOffset: UInt64(bytes))

  return url
}

/// The error a call threw, for the cases where the case matters and its payload
/// is the system's own words.
private func failure(from body: () throws -> [SecureSendCrypto.FileToSeal]) -> Attach.Failure? {
  do {
    _ = try body()
    return nil
  } catch let error as Attach.Failure {
    return error
  } catch {
    return nil
  }
}

private func inTemporaryFolder(_ body: (URL) throws -> Void) throws {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("securesend-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }

  try body(folder)
}
