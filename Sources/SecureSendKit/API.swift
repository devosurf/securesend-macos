import Foundation

// The one network call this app makes: POST /api/secrets, exactly the request the
// web client sends. Nothing but ciphertext, an iv, an id and an expiry leaves the
// machine. The key stays in the fragment token, which never touches the request.

public enum SecureSendAPI {
  public static let origin = "https://securesend.dev"

  /// The presets the API accepts. A right-click has no screen to choose on, so the
  /// app picks the same default the web app starts from.
  public enum Expiry: String, Sendable {
    case oneHour = "1h"
    case oneDay = "24h"
    case threeDays = "72h"
  }

  public enum Failure: LocalizedError, Sendable {
    /// The link was real and there is nothing left to take. The status is what
    /// the instance knows about the corpse, when it sent one.
    case alreadyGone(SecretStatus?)
    case idTaken
    /// No row was ever stored under that id, which is also what a probe gets.
    case nothingThere
    case offline(String)
    case refused(Int, String)
    case timedOut

    public var errorDescription: String? {
      switch self {
      case .alreadyGone(let status):
        return status.map(Self.gone) ?? "That link has already been used."
      case .idTaken:
        return "SecureSend could not pick a free id. Try again."
      case .nothingThere:
        return "There is nothing at that link."
      case .offline(let detail):
        return "SecureSend could not reach securesend.dev: \(detail)"
      case .refused(let status, let detail):
        return "securesend.dev refused the secret (\(status)): \(detail)"
      case .timedOut:
        return "SecureSend timed out reaching securesend.dev."
      }
    }

    /// One sentence for a link that is past saving, in the recipient's terms.
    /// `used` and never `opened`: this instance watched ciphertext go out, and
    /// whether the other end could decrypt it is a claim only that screen can make.
    private static func gone(_ status: SecretStatus) -> String {
      switch status.state {
      case .used:
        return "That link was already opened\(when(status.usedAt))."
      case .burned:
        return "The sender destroyed that link\(when(status.burnedAt))."
      case .expired:
        return "That link expired\(when(status.expiresAt))."
      case .sealed, .unrecognised:
        // Sealed here means somebody else won the row between the two calls.
        return "That link is no longer available."
      }
    }

    private static func when(_ date: Date?) -> String {
      guard let date else { return "" }

      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .full
      return " \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
  }

  /// Blocks until the link exists or the deadline passes.
  ///
  /// It has to block: a Service writes its result to the pasteboard before the
  /// method returns, and the host reads the pasteboard the moment it does. There
  /// is no callback to hand a late answer to. The wait is bounded so an unreachable
  /// server cannot wedge the app, and URLSession answers on its own queue, so
  /// waiting here does not deadlock the completion.
  public static func createLink(
    note: String,
    expiry: Expiry = .oneDay,
    timeout: TimeInterval = 10
  ) throws -> String {
    // One retry, because the only expected rejection is an id collision and the
    // fix for it is a fresh id, which costs nothing: nothing has been shared yet.
    for attempt in 0..<2 {
      do {
        return try attemptCreate(note: note, expiry: expiry, timeout: timeout)
      } catch Failure.idTaken where attempt == 0 {
        continue
      }
    }
    throw Failure.idTaken
  }

  /// The same call for files, which does not block and must not.
  ///
  /// Nothing is waiting on a pasteboard here: the Finder Service answers the host
  /// nothing and puts the link on the general clipboard when there is one. So this
  /// is the ordinary async call, and the main thread stays free to draw a menu bar
  /// and open a panel while ten megabytes go up.
  ///
  /// The deadline is longer than the note path's for the same reason.
  public static func createLink(
    files: [SecureSendCrypto.FileToSeal],
    expiry: Expiry = .oneDay,
    timeout: TimeInterval = 60
  ) async throws -> String {
    for attempt in 0..<2 {
      do {
        return try await attemptCreate(files: files, expiry: expiry, timeout: timeout)
      } catch Failure.idTaken where attempt == 0 {
        continue
      }
    }
    throw Failure.idTaken
  }

  // MARK: - Inside

  private final class Box: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
  }

  /// One sealed envelope and the link it will be, prepared together.
  ///
  /// The id and the key are both chosen locally, so the link is known before the
  /// request is made and the response only confirms the row landed. The fragment
  /// is in here and never in `body`, which is the whole reason the two are built
  /// in one place and carried as one value.
  private struct Attempt {
    let body: Data
    let link: String
  }

  private static func prepare(
    note: String?,
    files: [SecureSendCrypto.FileToSeal],
    expiry: Expiry
  ) throws -> Attempt {
    let sealed = try SecureSendCrypto.seal(note: note, files: files)

    return Attempt(
      body: try JSONSerialization.data(
        withJSONObject: [
          "attachments": sealed.attachments.map {
            ["ciphertext": $0.ciphertext, "index": $0.index, "iv": $0.iv]
          },
          "envelope": ["ciphertext": sealed.ciphertext, "iv": sealed.iv],
          "expiry": expiry.rawValue,
          "id": sealed.id,
        ],
        options: [.sortedKeys]
      ),
      link: "\(origin)/s/\(sealed.id)#\(sealed.fragmentToken)"
    )
  }

  private static func post(_ attempt: Attempt, timeout: TimeInterval) -> URLRequest {
    guard let url = URL(string: "\(origin)/api/secrets") else {
      preconditionFailure("the api origin is not a url")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = attempt.body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    return request
  }

  /// The answer, read the same way whichever call made it.
  private static func link(
    from http: HTTPURLResponse,
    data: Data?,
    attempt: Attempt
  ) throws -> String {
    if http.statusCode == 409 {
      throw Failure.idTaken
    }
    guard http.statusCode == 201 else {
      throw Failure.refused(http.statusCode, data.map { detail($0) } ?? "")
    }

    return attempt.link
  }

  private static func attemptCreate(
    note: String,
    expiry: Expiry,
    timeout: TimeInterval
  ) throws -> String {
    let attempt = try prepare(note: note, files: [], expiry: expiry)

    let box = Box()
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: post(attempt, timeout: timeout)) { data, response, error in
      box.data = data
      box.response = response
      box.error = error
      done.signal()
    }.resume()

    guard done.wait(timeout: .now() + timeout + 1) == .success else {
      throw Failure.timedOut
    }
    if let error = box.error {
      throw Failure.offline(error.localizedDescription)
    }
    guard let http = box.response as? HTTPURLResponse else {
      throw Failure.offline("no response")
    }

    return try link(from: http, data: box.data, attempt: attempt)
  }

  private static func attemptCreate(
    files: [SecureSendCrypto.FileToSeal],
    expiry: Expiry,
    timeout: TimeInterval
  ) async throws -> String {
    let attempt = try prepare(note: nil, files: files, expiry: expiry)
    let (data, http) = try await send(post(attempt, timeout: timeout))

    return try link(from: http, data: data, attempt: attempt)
  }
}
