import Foundation
import UniformTypeIdentifiers

// Files off the disk and into an envelope, which is the mirror of `Downloads`.
//
// The order is the whole point of this file. A file is weighed from what the
// filesystem already knows, refused if it is past a cap, and only then read and
// only then encrypted: spending a few seconds on a forty megabyte file and then
// saying no is the wrong way round, and it is the way round you get for free if
// the check lives next to the upload instead of here.
//
// The caps are this build's mirror of the instance's `MAX_ATTACHMENTS` and
// `MAX_TOTAL_BYTES`, the same numbers apps/web keeps for the same reason. The
// instance is the authority. These are here so somebody who right-clicked a disk
// image is told before anything is read, encrypted or uploaded rather than after,
// and a self-hosted instance set lower will still refuse what this lets through,
// in its own words.

public enum Attach {
  /// How many files one envelope carries.
  public static let maxAttachments = 10

  /// The whole secret: the json part plus every file's bytes.
  public static let maxTotalBytes = 10 * 1024 * 1024

  /// What the envelope costs beyond the files themselves: the version, the key
  /// names, the punctuation and the authentication tags. Deliberately generous
  /// and deliberately not exact, because json escaping means the true size of a
  /// file list is not knowable without building it. When this guesses low the
  /// instance refuses the envelope and says so in its own sentence.
  static let scaffoldingBytes = 256

  public enum Failure: LocalizedError, Sendable, Equatable {
    case nothingToSend
    /// A folder, a package, or something the filesystem will not describe.
    case notAFile
    case tooBig(bytes: Int)
    case tooMany(count: Int)
    /// The system's own reason, which is the only one worth printing here. It
    /// names the file, so it belongs in a panel and never in the log.
    case unreadable(reason: String)

    public var errorDescription: String? {
      switch self {
      case .nothingToSend:
        return "Select a file first."
      case .notAFile:
        return "SecureSend sends files, not folders."
      case .tooBig(let bytes):
        return """
          SecureSend takes \(size(maxTotalBytes)) in one link, and that is \(size(bytes)).
          """
      case .tooMany(let count):
        return "SecureSend takes \(maxAttachments) files in one link, and that was \(count)."
      case .unreadable(let reason):
        return "SecureSend could not read that file: \(reason)"
      }
    }

    /// The same refusal with nothing in it that came from a filename, for the log.
    public var label: String {
      switch self {
      case .nothingToSend: return "nothing selected"
      case .notAFile: return "not a file"
      case .tooBig(let bytes): return "too big at \(bytes)b"
      case .tooMany(let count): return "too many at \(count)"
      case .unreadable: return "unreadable"
      }
    }

    /// Binary units, so the cap prints as the 10 MB it is rather than the 10.5 MB
    /// a decimal formatter would make of the same number.
    private func size(_ bytes: Int) -> String {
      Int64(bytes).formatted(.byteCount(style: .memory))
    }
  }

  /// Every file at those urls, ready to seal, or the reason none of them is.
  ///
  /// Nothing is read until everything has been weighed, and the total is checked
  /// twice: once against what the filesystem says and once against the bytes
  /// actually in hand, because a file can grow between the two.
  public static func read(_ urls: [URL]) throws -> [SecureSendCrypto.FileToSeal] {
    guard !urls.isEmpty else {
      throw Failure.nothingToSend
    }
    guard urls.count <= maxAttachments else {
      throw Failure.tooMany(count: urls.count)
    }

    let described = try urls.map(describe)
    try refuseIfOver(described.reduce(0) { $0 + $1.size })

    var files: [SecureSendCrypto.FileToSeal] = []
    files.reserveCapacity(described.count)
    var total = 0

    for file in described {
      let bytes: Data
      do {
        bytes = try Data(contentsOf: file.url)
      } catch {
        throw Failure.unreadable(reason: error.localizedDescription)
      }

      total += bytes.count
      try refuseIfOver(total)
      files.append(
        SecureSendCrypto.FileToSeal(
          bytes: bytes, name: file.url.lastPathComponent, type: file.type
        )
      )
    }

    return files
  }

  // MARK: - Inside

  private struct Described {
    let size: Int
    let type: String
    let url: URL
  }

  /// What the filesystem already knows, which costs nothing to ask and is enough
  /// to refuse on.
  private static func describe(_ url: URL) throws -> Described {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .contentTypeKey, .fileSizeKey, .isRegularFileKey,
      ])
    } catch {
      // Gone, or on a volume that will not answer. Whatever the filesystem says
      // is a better sentence than anything guessed from here.
      throw Failure.unreadable(reason: error.localizedDescription)
    }

    // A folder or a package. The Service is registered for `public.data`, so this
    // is a path macOS should never take, and one that must not end in an attempt
    // to read a directory as though it were a file.
    guard values.isRegularFile == true, let size = values.fileSize else {
      throw Failure.notAFile
    }

    return Described(
      size: size, type: values.contentType?.preferredMIMEType ?? "", url: url
    )
  }

  private static func refuseIfOver(_ bytes: Int) throws {
    guard scaffoldingBytes + bytes <= maxTotalBytes else {
      throw Failure.tooBig(bytes: bytes)
    }
  }
}
