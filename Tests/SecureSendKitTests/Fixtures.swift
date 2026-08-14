import Foundation
import Testing

@testable import SecureSendKit

// The envelopes in Fixtures/envelopes.json were sealed by packages/crypto, not by
// this app. Opening them is the only check here that can catch the two drifting
// apart; everything else in these tests is this implementation against itself.
//
// scripts/make-fixtures.ts regenerates the file. See its header.

struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
  struct File: Decodable, Sendable {
    let base64: String
    let name: String
    let size: Int
    let type: String
  }

  struct Expected: Decodable, Sendable {
    let credentials: SecureSendCrypto.Credentials?
    let files: [File]
    let note: String?
  }

  struct Stored: Decodable, Sendable {
    struct Attachment: Decodable, Sendable {
      let ciphertext: String
      let index: Int
      let iv: String
    }

    struct Envelope: Decodable, Sendable {
      let ciphertext: String
      let iv: String
    }

    let attachments: [Attachment]
    let envelope: Envelope
    let id: String
  }

  let expect: Expected
  let fragmentToken: String
  let name: String
  /// Present only on the one envelope sealed behind a password.
  let password: String?
  let stored: Stored

  /// So a failure names the envelope rather than printing its ciphertext.
  var testDescription: String { name }
}

extension Fixture {
  /// The same shape a reveal hands back, so a test opens exactly what the app would.
  var storedEnvelope: SecureSendCrypto.StoredEnvelope {
    SecureSendCrypto.StoredEnvelope(
      attachments: stored.attachments.map {
        SecureSendCrypto.AttachmentCiphertext(
          ciphertext: $0.ciphertext, index: $0.index, iv: $0.iv
        )
      },
      envelope: SecureSendCrypto.Ciphertext(
        ciphertext: stored.envelope.ciphertext, iv: stored.envelope.iv
      ),
      id: stored.id
    )
  }

  var token: SecureSendCrypto.FragmentToken {
    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(fragmentToken) else {
      preconditionFailure("the fixture's own fragment token does not decode")
    }
    return token
  }
}

enum Fixtures {
  static let all: [Fixture] = {
    guard let url = Bundle.module.url(forResource: "envelopes", withExtension: "json") else {
      preconditionFailure("envelopes.json is not in the test bundle")
    }
    struct File: Decodable { let fixtures: [Fixture] }
    // A throw here is a broken checkout, not a test failure worth reporting nicely.
    // swiftlint:disable:next force_try
    let file = try! JSONDecoder().decode(File.self, from: try! Data(contentsOf: url))
    return file.fixtures
  }()

  /// Everything this app can open on its own. A password link goes to the browser.
  static let withoutPassword: [Fixture] = all.filter { $0.password == nil }

  static func named(_ name: String) -> Fixture {
    guard let found = all.first(where: { $0.name == name }) else {
      preconditionFailure("no fixture named \(name)")
    }
    return found
  }
}
