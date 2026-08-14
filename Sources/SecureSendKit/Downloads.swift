import Foundation

// Attachments, out of the envelope and onto the recipient's disk.
//
// There is nothing to fetch. The bytes were decrypted a moment ago and the
// instance no longer has them, so this is the last place they exist and a failure
// here loses the secret. That is why it never overwrites and never gives up on a
// name: the file has to land somewhere, and it must not be on top of something
// the recipient already had.
//
// A filename comes out of the envelope, so it comes from whoever sealed it, and
// opening a link from a stranger is the normal case for this product. The name is
// treated as hostile text whose only say is what a file inside the chosen folder
// is called.

public enum Downloads {
  /// What a file is called when the sender's name reduces to nothing usable.
  public static let unnamed = "secret file"

  /// The longest a single filename may be, in bytes, on both apfs and hfs+.
  private static let maxNameBytes = 255

  /// Both, because a name sealed on Windows carries the other one and neither may
  /// be read as a step up a directory tree.
  private static let separators = CharacterSet(charactersIn: "/\\")

  /// The last component of whatever the sender wrote, with nothing in it that a
  /// filesystem reads as structure.
  ///
  /// It cannot return a name that escapes a folder: everything up to and
  /// including the last separator is dropped before anything else happens.
  public static func safeName(_ raw: String) -> String {
    guard
      let last = raw.components(separatedBy: separators).last(where: { !$0.isEmpty })
    else {
      return unnamed
    }

    let cleaned = last
      .components(separatedBy: .controlCharacters).joined()
      .trimmingCharacters(in: .whitespaces)

    // A name that is only dots is `.`, `..`, or something that reads as one at a
    // glance. None of them is a filename worth keeping.
    guard !cleaned.isEmpty, cleaned.contains(where: { $0 != "." }) else {
      return unnamed
    }

    return truncated(cleaned)
  }

  /// Saves every file into the folder, and answers where each one landed.
  ///
  /// Nothing already in the folder is touched. A name that is taken gets a
  /// counter, and the counter goes before the extension so a `.pdf` stays a
  /// `.pdf` and opens in what the recipient expects.
  @discardableResult
  public static func save(
    _ files: [SecureSendCrypto.OpenedFile],
    into folder: URL
  ) throws -> [URL] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    return try files.map { file in
      try write(file.bytes, named: safeName(file.name), into: folder)
    }
  }

  /// The folder the app saves into. Downloads if there is one, and the home
  /// folder if this account somehow has none.
  public static func folder() -> URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
  }

  // MARK: - Inside

  /// Cut to what a filesystem takes, on a character boundary. A name long enough
  /// to need this is already not a name anybody typed.
  private static func truncated(_ name: String) -> String {
    guard name.utf8.count > maxNameBytes else {
      return name
    }

    var cut = name
    while cut.utf8.count > maxNameBytes {
      cut.removeLast()
    }
    return cut
  }

  /// Writes without ever overwriting, retrying under a new name until it lands.
  ///
  /// The refusal to overwrite is the filesystem's, not a check followed by a
  /// write: something else creating the file in between those two would be a
  /// recipient's own file quietly replaced by a stranger's.
  private static func write(_ bytes: Data, named name: String, into folder: URL) throws -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension

    // Bounded so a folder that refuses every write fails with the filesystem's
    // own error rather than spinning. Nobody has 9999 files of one name.
    for attempt in 1...9999 {
      let candidate = attempt == 1 ? name : suffixed(base: base, ext: ext, attempt)
      let url = folder.appendingPathComponent(candidate)

      do {
        try bytes.write(to: url, options: .withoutOverwriting)
        return url
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
      {
        continue
      }
    }

    throw CocoaError(.fileWriteFileExists)
  }

  private static func suffixed(base: String, ext: String, _ attempt: Int) -> String {
    // `deletingPathExtension` leaves an empty base for a name that is only an
    // extension, and a bare counter is a worse name than the sender's.
    let stem = base.isEmpty ? unnamed : base
    return ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
  }
}
