import AppKit
import SecureSendKit

// Check for updates, the menu item.
//
// It asks GitHub for the latest release, compares it to the number in this
// bundle, and says one of three things. It does not download anything and it
// does not replace anything: the answer is a sentence and a link to the release
// page, where the notes and the checksum are.
//
// Nothing here runs on its own. There is no timer and no check on launch,
// because a security tool that phones a server unprompted is a different promise
// from the one the rest of this app makes.

@MainActor
enum Updates {
  /// The number this bundle was built with. `scripts/version.sh` writes it and
  /// the release workflow refuses to build a tag that disagrees with it, so a
  /// running app can trust it as far as the release page.
  static var installed: SecureSendVersion? {
    guard let text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
      return nil
    }
    return SecureSendVersion(text)
  }

  /// One check at a time. Two panels stacked behind each other is a worse answer
  /// than a menu item that ignores the second click.
  private static var checking = false

  static func check() {
    guard !checking else { return }
    checking = true
    Task {
      await run()
      checking = false
    }
  }

  private static func run() async {
    guard let installed else {
      // Only reachable in a bundle nobody released, but saying so is better than
      // comparing against a number that is not there.
      log("updates", "FAIL", "no version in bundle")
      Alerts.tell(
        "SecureSend cannot tell which version it is.",
        """
        This copy has no version number in it, which usually means it was not \
        built by scripts/version.sh. Compare it against the releases page \
        yourself.
        """,
        style: .warning
      )
      return
    }

    let latest: SecureSendUpdates.Release
    do {
      latest = try await SecureSendUpdates.latest()
    } catch {
      log("updates", "FAIL", Alerts.short(error))
      Alerts.tell(
        "SecureSend could not check for updates.",
        "\(error.localizedDescription)\n\nYou have \(installed).",
        style: .warning
      )
      return
    }

    log("updates", "OK", "installed=\(installed)", "latest=\(latest.version)")

    // Not `!=`: a local build ahead of the published release is every machine
    // that ever builds this app, and offering it a downgrade would be nonsense.
    guard latest.version > installed else {
      Alerts.tell(
        "SecureSend is up to date.",
        "You have \(installed), which is the latest release.",
        style: .informational
      )
      return
    }

    offer(latest, installed: installed)
  }

  private static func offer(_ latest: SecureSendUpdates.Release, installed: SecureSendVersion) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "SecureSend \(latest.version) is available."
    alert.informativeText = """
      You have \(installed). The release page has the download and the checksum \
      to check it against.

      Updating means replacing SecureSend in your Applications folder, so quit \
      this copy first.
      """
    alert.addButton(withTitle: "Open Release Page")
    alert.addButton(withTitle: "Later")

    if Alerts.run(alert) == .alertFirstButtonReturn {
      NSWorkspace.shared.open(latest.page)
    }
  }
}
