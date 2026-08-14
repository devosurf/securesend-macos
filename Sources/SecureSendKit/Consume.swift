import Foundation

// The two calls that consume a link, in the order they have to happen.
//
//   status  GET  /api/secrets/:id          reads, destroys nothing
//   reveal  POST /api/secrets/:id/reveal   destroys, exactly once
//
// The status call is why the app can say what a link is before it offers to open
// it. It is the route preview bots land on, so asking is free and safe; the
// reveal is the one action in the product that cannot be taken back, and it only
// ever runs after somebody has read a sentence saying so.
//
// Both are async, unlike `createLink`. Nothing here is a Service, so nothing here
// has to block a pasteboard round trip: the answer lands in a panel.

extension SecureSendAPI {
  /// The four a row can be in, plus the one this build does not recognise. A
  /// client that crashed on a state added later would be a client that destroys
  /// nothing and explains nothing, so an unknown state is a state.
  public enum SecretState: Sendable, Equatable {
    case sealed
    case used
    case burned
    case expired
    case unrecognised(String)

    init(rawValue: String) {
      switch rawValue {
      case "sealed": self = .sealed
      case "used": self = .used
      case "burned": self = .burned
      case "expired": self = .expired
      default: self = .unrecognised(rawValue)
      }
    }

    /// Whether there is anything left to take. Only `sealed` is openable, and an
    /// unrecognised state is deliberately not: this build cannot say what it means.
    public var isOpenable: Bool { self == .sealed }
  }

  /// What the api says about a secret without touching it.
  ///
  /// One absence is load-bearing: nothing here says whether a password protects
  /// the envelope. The instance does not know. The flag rides the fragment
  /// precisely so it cannot.
  public struct SecretStatus: Sendable, Equatable, Decodable {
    public let burnedAt: Date?
    /// Who burned it, when somebody did.
    public let burnReason: String?
    public let createdAt: Date?
    public let expiresAt: Date?
    public let id: String
    public let state: SecretState
    public let usedAt: Date?

    private enum Key: String, CodingKey {
      case burnedAt, burnReason, createdAt, expiresAt, id, state, usedAt
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Key.self)

      burnedAt = Self.date(try container.decodeIfPresent(String.self, forKey: .burnedAt))
      burnReason = try container.decodeIfPresent(String.self, forKey: .burnReason)
      createdAt = Self.date(try container.decodeIfPresent(String.self, forKey: .createdAt))
      expiresAt = Self.date(try container.decodeIfPresent(String.self, forKey: .expiresAt))
      id = try container.decode(String.self, forKey: .id)
      state = SecretState(rawValue: try container.decode(String.self, forKey: .state))
      usedAt = Self.date(try container.decodeIfPresent(String.self, forKey: .usedAt))
    }

    /// Timestamps are decoration on every screen that shows one, so a stamp this
    /// cannot read costs a phrase rather than the whole answer.
    private static func date(_ text: String?) -> Date? {
      guard let text else { return nil }

      let withFraction = ISO8601DateFormatter()
      withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

      return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
  }

  /// Asks what is at a link. Destroys nothing, and there is no path from here to
  /// a write.
  public static func status(id: String, timeout: TimeInterval = 10) async throws -> SecretStatus {
    let (data, http) = try await send(
      request("/api/secrets/\(id)", method: "GET", timeout: timeout)
    )

    switch http.statusCode {
    case 200:
      return try decode(SecretStatus.self, from: data)
    case 404:
      throw Failure.nothingThere
    default:
      throw Failure.refused(http.statusCode, detail(data))
    }
  }

  /// Takes the secret. This is the destructive one: on success the instance no
  /// longer holds what it just handed over, so whatever comes back has to be
  /// opened and saved, not dropped on an error path.
  ///
  /// It sends no body. The route refuses one rather than ignoring it, because a
  /// client that could post a password would eventually be written as though
  /// something on the server checked it.
  public static func reveal(
    id: String,
    timeout: TimeInterval = 10
  ) async throws -> SecureSendCrypto.StoredEnvelope {
    let (data, http) = try await send(
      request("/api/secrets/\(id)/reveal", method: "POST", timeout: timeout)
    )

    switch http.statusCode {
    case 200:
      let released = try decode(Released.self, from: data)
      return SecureSendCrypto.StoredEnvelope(
        attachments: released.attachments.map {
          SecureSendCrypto.AttachmentCiphertext(
            ciphertext: $0.ciphertext, index: $0.index, iv: $0.iv
          )
        },
        envelope: SecureSendCrypto.Ciphertext(
          ciphertext: released.envelope.ciphertext, iv: released.envelope.iv
        ),
        id: released.id
      )
    case 404:
      throw Failure.nothingThere
    case 410:
      // The body is the same status shape the sealed page renders from, so the
      // dead end is worded off one thing rather than two.
      throw Failure.alreadyGone(try? decode(SecretStatus.self, from: data))
    default:
      throw Failure.refused(http.statusCode, detail(data))
    }
  }

  // MARK: - Inside

  private struct Released: Decodable {
    struct Attachment: Decodable {
      let ciphertext: String
      let index: Int
      let iv: String
    }

    struct Envelope: Decodable {
      let ciphertext: String
      let iv: String
    }

    let attachments: [Attachment]
    let envelope: Envelope
    let id: String
  }

  private static func request(
    _ path: String,
    method: String,
    timeout: TimeInterval
  ) -> URLRequest {
    // The origin is a constant this build controls and the id has already been
    // checked against the id format, so there is nothing here a url can trip on.
    guard let url = URL(string: "\(origin)\(path)") else {
      preconditionFailure("the api origin is not a url")
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  /// Internal rather than private because the async create posts through it too:
  /// one place turns a url error into one of ours, so an offline machine reads
  /// the same whichever call was making.
  static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw Failure.timedOut
    } catch {
      throw Failure.offline(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw Failure.offline("no response")
    }
    return (data, http)
  }

  private static func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw Failure.refused(200, "securesend.dev sent something this build cannot read")
    }
  }

  /// The api's own words for a refusal, which never carry any part of a secret.
  static func detail(_ data: Data) -> String {
    struct Refusal: Decodable { let error: String }

    return (try? JSONDecoder().decode(Refusal.self, from: data))?.error
      ?? String(decoding: data, as: UTF8.self)
  }
}
