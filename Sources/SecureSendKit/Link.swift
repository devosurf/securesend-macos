import Foundation

// Recognising one of our links in a piece of text.
//
// This is the gate in front of the only action in the product that destroys
// something, so it errs towards not recognising. A string it refuses costs
// somebody one beep; a string it wrongly accepts sends a reveal at an id that
// belongs to a stranger, and that reveal cannot be taken back.
//
// It matches this build's own origin and nothing else. A self-hosted instance
// serves its own links, and guessing that some other host speaks our api is how
// an app ends up posting a reveal at somebody's intranet.

public enum SecureSendLink {
  public enum Result: Sendable, Equatable {
    case link(id: String, fragment: String)
    /// One of ours, arrived without a usable key: nothing to request, nothing
    /// destroyed, a fix to teach.
    case incomplete
    /// Not one of ours at all.
    case notALink
  }

  /// Reads the text as a link, or says why it is not one.
  ///
  /// The fragment is carried across verbatim. Whether it is a key is the fragment
  /// token decoder's question, not this one's.
  public static func read(_ text: String) -> Result {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // A url this cannot even parse is not worth the four checks below.
    guard
      let components = URLComponents(string: trimmed),
      let origin = URLComponents(string: SecureSendAPI.origin)
    else {
      return .notALink
    }

    guard
      components.scheme == origin.scheme,
      components.host == origin.host,
      components.port == origin.port,
      components.user == nil,
      components.password == nil
    else {
      return .notALink
    }

    // Exactly /s/<id>. A nested path is a different page, not a link with extra
    // on the end, and an id has one shape.
    let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
    guard
      path.count == 2, path[0] == "s",
      case let id = String(path[1]),
      SecureSendCrypto.isSecretId(id)
    else {
      return .notALink
    }

    // `fragment` is nil with no `#` at all and empty with a bare one. Both are the
    // same thing to a recipient: a link that arrived without its key.
    guard let fragment = components.fragment, !fragment.isEmpty else {
      return .incomplete
    }

    return .link(id: id, fragment: fragment)
  }
}
