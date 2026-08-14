import Foundation
import Testing

@testable import SecureSendKit

// The comparison behind Check for updates. Getting it wrong is quiet in both
// directions: too eager and it nags about a version that is already installed,
// too lax and it never mentions the release carrying a fix.

@Suite("Reading a version")
struct VersionParsingTests {
  @Test(
    "the shapes a release tag and a bundle actually carry",
    arguments: [
      ("0.2.0", 0, 2, 0),
      ("v0.2.0", 0, 2, 0),
      ("1.0.0", 1, 0, 0),
      ("10.20.30", 10, 20, 30),
      ("0.0.1", 0, 0, 1),
    ]
  )
  func parses(text: String, major: Int, minor: Int, patch: Int) throws {
    let version = try #require(SecureSendVersion(text))

    #expect(version.major == major)
    #expect(version.minor == minor)
    #expect(version.patch == patch)
  }

  /// Anything that is not three plain numbers is a tag this app cannot rank, and
  /// a guess at one risks pointing somebody at a downgrade. `releases/latest`
  /// already skips drafts and prereleases, so refusing them here costs nothing.
  @Test(
    "anything it cannot rank is refused rather than guessed at",
    arguments: [
      "", "v", "1", "1.2", "1.2.3.4", "1.2.x", "1.2.-3", "1.2.3-beta", "1.2.3+7",
      "one.two.three", "v1.2.3 ", " 1.2.3", "1..3", "latest",
    ]
  )
  func refuses(text: String) {
    #expect(SecureSendVersion(text) == nil)
  }

  @Test("it reads back the way a person would write it")
  func describes() throws {
    #expect(try #require(SecureSendVersion("v1.2.3")).description == "1.2.3")
  }
}

@Suite("Ranking two versions")
struct VersionOrderingTests {
  @Test(
    "each field outranks the ones after it",
    arguments: [
      ("0.2.0", "0.3.0"),
      ("0.2.0", "0.2.1"),
      ("0.9.9", "1.0.0"),
      ("1.0.0", "1.0.1"),
      ("0.2.9", "0.10.0"),
      ("2.0.0", "10.0.0"),
    ]
  )
  func ascends(lower: String, higher: String) throws {
    let low = try #require(SecureSendVersion(lower))
    let high = try #require(SecureSendVersion(higher))

    #expect(low < high)
    #expect(!(high < low))
  }

  /// The case that runs every time somebody clicks the item and is already
  /// current. It must not read as "newer", or the app nags forever.
  @Test("the same number is not an update")
  func equal() throws {
    let installed = try #require(SecureSendVersion("0.2.0"))
    let latest = try #require(SecureSendVersion("v0.2.0"))

    #expect(latest == installed)
    #expect(!(latest > installed))
  }

  /// A local build running ahead of the published release, which is every
  /// development machine including this one. It is not an update either.
  @Test("a build ahead of the release is not offered a downgrade")
  func ahead() throws {
    let installed = try #require(SecureSendVersion("0.3.0"))
    let latest = try #require(SecureSendVersion("0.2.0"))

    #expect(!(latest > installed))
  }
}
