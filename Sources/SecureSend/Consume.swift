import AppKit
import SecureSendKit

// Turning a link on the clipboard back into a secret.
//
// The order below is the whole design, and every step exists to keep the one
// irreversible act honest:
//
//   1. find a url        without reading the clipboard
//   2. read it as a link this build's origin, and an id of the right shape
//   3. read the fragment a password link goes to the browser and stops here
//   4. ask the api       GET, destroys nothing, so a dead link costs no press
//   5. ask the person    one sentence, naming what is about to be destroyed
//   6. reveal            the burn
//   7. open and save     the bytes now exist nowhere else
//
// Steps 4 and 5 are why 6 is defensible. A hotkey that went straight from a
// clipboard to a reveal would destroy a secret somebody meant to open on their
// phone, and no amount of wording afterwards would give it back.

@MainActor
enum Consume {
  static func fromClipboard() {
    Task { await run() }
  }

  private static func run() async {
    guard let text = await Clipboard.url() else {
      refuse("There is no link on the clipboard.")
      return
    }

    switch SecureSendLink.read(text) {
    case .notALink:
      refuse("There is no SecureSend link on the clipboard.")

    case .incomplete:
      // The key lives after the `#`, and chat clients drop it. Nothing was
      // requested and nothing was destroyed, so this is a fix to teach.
      tell(
        "That link is missing its key.",
        "Everything after the # is what opens it. Ask the sender to send the whole link.",
        style: .warning
      )

    case .link(let id, let fragment):
      await consume(id: id, fragment: fragment)
    }
  }

  private static func consume(id: String, fragment: String) async {
    guard case .ok(let token) = SecureSendCrypto.decodeFragmentToken(fragment) else {
      tell(
        "That link is missing its key.",
        "The part after the # is damaged. Ask the sender to send the whole link.",
        style: .warning
      )
      return
    }

    // A password is composed into the key in the recipient's own browser, and
    // that page already knows how to ask for one, how to let a wrong answer be
    // tried again, and how to say what opening costs. Nothing is destroyed by
    // opening it: the page reveals on a press, not on arrival.
    if token.needsPassword {
      // Rebuilt from the two checked parts rather than reused from the clipboard,
      // which may still carry the newline a chat client left on the front of it.
      // See SecureSendLink.url.
      guard let url = SecureSendLink.url(id: id, fragment: fragment) else {
        tell("SecureSend could not open that link.", "Open it in your browser.", style: .warning)
        return
      }

      log("consume", "handoff", "password link")
      NSWorkspace.shared.open(url)
      StatusUI.shared.flash("arrow.up.forward.app.fill")
      return
    }

    let status: SecureSendAPI.SecretStatus
    do {
      status = try await SecureSendAPI.status(id: id)
    } catch {
      log("consume", "FAIL", "status: \(short(error))")
      tell("SecureSend could not check that link.", error.localizedDescription, style: .warning)
      return
    }

    guard status.state.isOpenable else {
      // Nothing is sent at a link that is already spent, so the reveal that would
      // have told us this the expensive way never happens.
      log("consume", "dead", "state=\(status.state)")
      tell(
        "That link is already gone.",
        SecureSendAPI.Failure.alreadyGone(status).localizedDescription,
        style: .warning
      )
      return
    }

    guard confirm() else {
      log("consume", "cancelled")
      return
    }

    await take(id: id, token: token)
  }

  /// The one sentence standing in front of the burn.
  private static func confirm() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Open this secret and destroy the link?"
    alert.informativeText = """
      A SecureSend link opens once. Opening it here uses it up, so nobody else \
      will be able to open it, including you, on any other device.

      The note goes on your clipboard. Any files go to your Downloads folder.
      """

    let open = alert.addButton(withTitle: "Open and Destroy")
    open.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")

    return runModal(alert) == .alertFirstButtonReturn
  }

  /// Everything past the point of no return.
  private static func take(id: String, token: SecureSendCrypto.FragmentToken) async {
    let stored: SecureSendCrypto.StoredEnvelope
    do {
      stored = try await SecureSendAPI.reveal(id: id)
    } catch {
      // Nothing was destroyed unless the reveal succeeded, and it did not.
      log("consume", "FAIL", "reveal: \(short(error))")
      tell("That secret was not opened.", error.localizedDescription, style: .warning)
      return
    }

    // From here the instance no longer holds any of this. Every failure below is
    // a secret that is gone, so each one says so rather than reporting an error.
    let opened: SecureSendCrypto.Opened
    do {
      opened = try SecureSendCrypto.open(stored: stored, token: token)
    } catch {
      log("consume", "LOST", "open: \(short(error))")
      tell(
        "The link was used up, but the secret could not be opened.",
        """
        \(error.localizedDescription)

        The link is spent and securesend.dev no longer holds a copy. Ask the \
        sender to send it again.
        """,
        style: .critical
      )
      return
    }

    var saved: [URL] = []
    var saveFailure: String?
    if !opened.files.isEmpty {
      do {
        saved = try Downloads.save(opened.files, into: Downloads.folder())
      } catch {
        saveFailure = error.localizedDescription
      }
    }

    // The clipboard goes last, so a folder this app cannot write to does not also
    // cost the note. An envelope of only files leaves the clipboard alone: a
    // filename on a clipboard is a name with no file behind it.
    if let text = opened.clipboardText {
      Clipboard.replace(with: text)
    }

    report(opened, saved: saved, saveFailure: saveFailure)
  }

  /// What happened, in the recipient's terms. Counts and lengths only: this app
  /// never writes a secret or a link anywhere, including into its own alerts.
  private static func report(
    _ opened: SecureSendCrypto.Opened,
    saved: [URL],
    saveFailure: String?
  ) {
    log(
      "consume",
      saveFailure == nil ? "OK" : "PARTIAL",
      "note=\(opened.note?.count ?? 0)ch",
      "credentials=\(opened.credentials != nil)",
      "files=\(saved.count)/\(opened.files.count)"
    )

    if let saveFailure {
      // Saving stops at the first file it cannot write, so some may have landed
      // and some may not. Claiming either way would be a guess.
      tell(
        "The secret was opened, but its files could not all be saved.",
        """
        \(saveFailure)

        Check your Downloads folder. The link is spent, so anything missing \
        cannot be fetched again.
        """,
        style: .critical
      )
      return
    }

    StatusUI.shared.flash("checkmark.circle.fill")

    // Files land somewhere the person cannot see from here, so that is the one
    // worth a panel and a way to reach them. A note is already under the cursor
    // on the next paste, and a second modal for it would be in the way.
    guard !saved.isEmpty else { return }

    var landed: [String] = []
    if opened.clipboardText != nil {
      landed.append(
        opened.credentials == nil
          ? "The note is on your clipboard."
          : "The note and login are on your clipboard."
      )
    }
    landed.append(
      saved.count == 1
        ? "One file is in your Downloads folder."
        : "\(saved.count) files are in your Downloads folder."
    )

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Secret opened."
    alert.informativeText = landed.joined(separator: "\n")
    alert.addButton(withTitle: "Show in Finder")
    alert.addButton(withTitle: "Done")

    if runModal(alert) == .alertFirstButtonReturn {
      NSWorkspace.shared.activateFileViewerSelecting(saved)
    }
  }

  // MARK: - Saying things

  private static func refuse(_ message: String) {
    log("consume", "none")
    StatusUI.shared.flash("exclamationmark.triangle.fill")
    NSSound.beep()
    tell(message, "Copy a SecureSend link, then try again.", style: .informational)
  }

  private static func tell(_ message: String, _ detail: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    _ = runModal(alert)
  }

  /// The app has no windows and no Dock icon, so it has to come forward on its
  /// own or the panel opens behind whatever the person was looking at.
  private static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.activate()
    return alert.runModal()
  }

  /// An error's own words, never a secret's. Every error that reaches here is one
  /// this app wrote, and none of them quotes a link, an id or any plaintext.
  private static func short(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(type(of: error))"
  }
}
