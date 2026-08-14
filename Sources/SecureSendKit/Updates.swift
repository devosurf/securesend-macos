import Foundation

// Is there a newer build than this one?
//
// The whole mechanism, and it is deliberately small: ask GitHub what the latest
// release is, and hand back the number. Nothing downloads itself and nothing
// replaces itself. The app has no updater, it has a question it can ask.
//
// It is asked only when somebody clicks the menu item. A check on a timer would
// mean this app talks to a server on its own schedule, which is the one thing it
// promises nowhere else in the product, and GitHub would see an address every
// time. A button is a person deciding to be seen.

/// A release number, which is three plain numbers and nothing else.
public struct SecureSendVersion: Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  /// Accepts `1.2.3` and `v1.2.3`. Anything else is refused rather than guessed
  /// at: a tag carrying a suffix, a word or a fourth field is not something this
  /// app can rank, and ranking it wrong points somebody at a downgrade.
  public init?(_ text: String) {
    var body = Substring(text)
    if body.hasPrefix("v") {
      body = body.dropFirst()
    }

    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let major = Self.number(parts[0]),
      let minor = Self.number(parts[1]),
      let patch = Self.number(parts[2])
    else {
      return nil
    }

    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Deliberately stricter than `Int.init`, which takes a leading sign, a plus,
  /// and digits from any script.
  private static func number(_ part: Substring) -> Int? {
    guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(part)
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public enum SecureSendUpdates {
  /// `releases/latest` and not the tag list, because it already skips drafts and
  /// prereleases. Whatever it names is something a person is meant to install.
  static let endpoint = URL(
    string: "https://api.github.com/repos/devosurf/securesend-macos/releases/latest"
  )!

  /// Where a person goes when the app cannot work the answer out itself.
  public static let releasesPage = URL(
    string: "https://github.com/devosurf/securesend-macos/releases/latest"
  )!

  public struct Release: Sendable {
    public let version: SecureSendVersion
    /// The release's own page, notes and checksums included, rather than the dmg
    /// itself. What to install is worth a look before it downloads.
    public let page: URL
  }

  public enum Failure: LocalizedError, Sendable {
    case offline(String)
    case refused(Int)
    case unreadable

    public var errorDescription: String? {
      switch self {
      case .offline(let detail):
        return "SecureSend could not reach GitHub: \(detail)"
      case .refused(let status):
        return "GitHub answered \(status) instead of naming the latest release."
      case .unreadable:
        return "GitHub named a release this app cannot compare against its own version."
      }
    }
  }

  private struct Payload: Decodable {
    let tagName: String
    let htmlUrl: String
  }

  public static func latest(timeout: TimeInterval = 10) async throws -> Release {
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = timeout
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw Failure.offline(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw Failure.offline("no response")
    }
    guard http.statusCode == 200 else {
      throw Failure.refused(http.statusCode)
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let payload = try? decoder.decode(Payload.self, from: data),
      let version = SecureSendVersion(payload.tagName),
      let page = URL(string: payload.htmlUrl)
    else {
      throw Failure.unreadable
    }

    return Release(version: version, page: page)
  }
}
