import Foundation
import Testing

@testable import SecureSendKit

// Reading what the api says about a secret. This is the answer the confirmation
// panel is built out of, so a shape it cannot read is a panel that either says
// nothing or says the wrong thing before something irreversible.

private func status(_ json: String) throws -> SecureSendAPI.SecretStatus {
  try JSONDecoder().decode(SecureSendAPI.SecretStatus.self, from: Data(json.utf8))
}

@Suite("Reading a secret's status")
struct SecretStatusTests {
  /// Copied off the shape apps/api/src/secrets/state.ts returns.
  private static let sealed = """
    {
      "burnedAt": null,
      "burnReason": null,
      "createdAt": "2026-08-14T09:12:31.482Z",
      "expiresAt": "2026-08-15T09:12:31.482Z",
      "id": "ZFKG_mXqcjqMb5fU3WjV0Q",
      "state": "sealed",
      "usedAt": null
    }
    """

  @Test("a live secret reads as openable")
  func sealed() throws {
    let found = try status(Self.sealed)

    #expect(found.state == .sealed)
    #expect(found.state.isOpenable)
    #expect(found.id == "ZFKG_mXqcjqMb5fU3WjV0Q")
    #expect(found.usedAt == nil)
    #expect(found.burnedAt == nil)
    #expect(found.expiresAt != nil)
  }

  @Test("every dead state reads, and none of them is openable", arguments: [
    "used", "burned", "expired",
  ])
  func deadStates(state: String) throws {
    let found = try status(Self.sealed.replacingOccurrences(of: "\"sealed\"", with: "\"\(state)\""))

    #expect(found.state == SecureSendAPI.SecretState(rawValue: state))
    #expect(found.state.isOpenable == false)
  }

  /// A state added to the api later must not crash this build, and must not be
  /// mistaken for a live one.
  @Test("a state this build does not know is not openable")
  func unrecognisedState() throws {
    let found = try status(
      Self.sealed.replacingOccurrences(of: "\"sealed\"", with: "\"quarantined\"")
    )

    #expect(found.state == .unrecognised("quarantined"))
    #expect(found.state.isOpenable == false)
  }

  /// Postgres hands back fractional seconds and a hand-written fixture might not.
  @Test("timestamps read with or without fractional seconds")
  func timestamps() throws {
    let plain = try status(
      Self.sealed.replacingOccurrences(
        of: "2026-08-14T09:12:31.482Z", with: "2026-08-14T09:12:31Z"
      )
    )

    #expect(plain.createdAt != nil)
    #expect(try status(Self.sealed).createdAt != nil)
  }

  /// A stamp this build cannot read costs a phrase in a sentence, not the answer.
  @Test("an unreadable timestamp does not lose the state")
  func unreadableTimestamp() throws {
    let odd = try status(
      Self.sealed.replacingOccurrences(of: "\"2026-08-14T09:12:31.482Z\"", with: "\"whenever\"")
    )

    #expect(odd.createdAt == nil)
    #expect(odd.state == .sealed)
  }

  @Test("a burn keeps the sender's reason")
  func burnReason() throws {
    let burned = try status(
      Self.sealed
        .replacingOccurrences(of: "\"sealed\"", with: "\"burned\"")
        .replacingOccurrences(of: "\"burnReason\": null", with: "\"burnReason\": \"sender\"")
        .replacingOccurrences(of: "\"burnedAt\": null", with: "\"burnedAt\": \"2026-08-14T10:00:00.000Z\"")
    )

    #expect(burned.state == .burned)
    #expect(burned.burnReason == "sender")
    #expect(burned.burnedAt != nil)
  }

  // MARK: - What the user is told

  /// Each dead end gets its own sentence. `used` and never `opened`: the instance
  /// watched ciphertext go out and cannot claim the other end could read it.
  @Test("a spent link is explained in the recipient's terms")
  func goneSentences() throws {
    let used = SecureSendAPI.Failure.alreadyGone(try status(
      Self.sealed
        .replacingOccurrences(of: "\"sealed\"", with: "\"used\"")
        .replacingOccurrences(of: "\"usedAt\": null", with: "\"usedAt\": \"2026-08-14T10:00:00.000Z\"")
    ))
    #expect(used.errorDescription?.hasPrefix("That link was already opened") == true)
    #expect(used.errorDescription?.contains("ago") == true)

    let burned = SecureSendAPI.Failure.alreadyGone(try status(
      Self.sealed.replacingOccurrences(of: "\"sealed\"", with: "\"burned\"")
    ))
    #expect(burned.errorDescription?.hasPrefix("The sender destroyed that link") == true)

    let expired = SecureSendAPI.Failure.alreadyGone(try status(
      Self.sealed.replacingOccurrences(of: "\"sealed\"", with: "\"expired\"")
    ))
    #expect(expired.errorDescription?.hasPrefix("That link expired") == true)
  }

  /// A 410 whose body this build cannot read still has to say something true.
  @Test("a gone link with no status still gets a sentence")
  func goneWithoutStatus() {
    #expect(
      SecureSendAPI.Failure.alreadyGone(nil).errorDescription == "That link has already been used."
    )
  }

  /// Nothing the user is shown may carry a piece of a link or a key.
  @Test("no dead end quotes the id or anything from the fragment")
  func saysNothingSensitive() throws {
    let sentence = SecureSendAPI.Failure.alreadyGone(try status(Self.sealed)).errorDescription

    #expect(sentence?.contains("ZFKG_mXqcjqMb5fU3WjV0Q") == false)
  }
}
