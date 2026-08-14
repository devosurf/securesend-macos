import AppKit
import SecureSendKit

// SecureSend, as a macOS menu bar app. Every way in is permission-free: no
// Accessibility grant, no TCC prompt of any kind. That is a product decision, not
// an accident. A global hotkey that replaces a selection can only work by faking
// command-C and command-V, which needs Accessibility, so selection replacement
// stays the right-click's job and the keyboard path goes through the clipboard.
//
//   1. right-click > Services > "Replace with SecureSend link"
//   2. right-click > Services > "Copy as SecureSend link", for hosts that will
//      not take a replacement
//   3. the menu bar item > Generate from clipboard, when there is no live selection
//
// Nothing here ever logs the link. The link contains the fragment token, and the
// fragment token contains the key: writing one to a log file would undo the whole
// product. Lengths and hosts only.

private let logURL = URL(
  fileURLWithPath: NSString(string: "~/Library/Logs/securesend.log").expandingTildeInPath
)

private func log(_ fields: String...) {
  let stamp = ISO8601DateFormatter().string(from: Date())
  let host = NSWorkspace.shared.frontmostApplication.map {
    "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "?"))"
  } ?? "unknown"
  let line = ([stamp, host] + fields).joined(separator: "\t") + "\n"
  guard let data = line.data(using: .utf8) else { return }
  if let handle = try? FileHandle(forWritingTo: logURL) {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
  } else {
    try? data.write(to: logURL)
  }
}

/// A right-click has no screen to choose an expiry on, so the app picks one.
private let defaultExpiry = SecureSendAPI.Expiry.oneDay

// MARK: - Menu bar presence

@MainActor
final class StatusUI {
  static let shared = StatusUI()
  private var statusItem: NSStatusItem?
  private var restore: Task<Void, Never>?

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = markImage(edge: 17)
    item.button?.toolTip = "SecureSend"

    let menu = NSMenu()
    let generate = menu.addItem(
      withTitle: "Generate from clipboard",
      action: #selector(AppActions.generateFromClipboard),
      keyEquivalent: ""
    )
    generate.target = AppActions.shared
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Or select text anywhere, then right-click", action: nil, keyEquivalent: ""
    ).isEnabled = false
    menu.addItem(.separator())
    let reveal = menu.addItem(
      withTitle: "Reveal log in Finder", action: #selector(AppActions.revealLog), keyEquivalent: ""
    )
    reveal.target = AppActions.shared
    menu.addItem(
      withTitle: "Quit SecureSend",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    item.menu = menu
    statusItem = item
  }

  /// Momentary confirmation, so nothing needs a notification permission.
  func flash(_ symbol: String) {
    guard let button = statusItem?.button else { return }
    restore?.cancel()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    restore = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      self?.statusItem?.button?.image = markImage(edge: 17)
    }
  }
}

// MARK: - Shared work

/// Whether a selection is worth sealing. An empty or whitespace-only selection is
/// a misfire, not a secret, and turning it into a link would burn a real row.
private func usableSecret(_ text: String?) -> String? {
  guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return nil
  }
  return text
}

@MainActor
final class AppActions: NSObject {
  static let shared = AppActions()

  @objc func generateFromClipboard() {
    let general = NSPasteboard.general
    guard let text = usableSecret(general.string(forType: .string)) else {
      log("menu", "FAIL", "clipboard empty")
      StatusUI.shared.flash("exclamationmark.triangle.fill")
      NSSound.beep()
      return
    }

    do {
      let link = try SecureSendAPI.createLink(note: text, expiry: defaultExpiry)
      general.clearContents()
      general.setString(link, forType: .string)
      log("menu", "OK", "in=\(text.count)ch")
      StatusUI.shared.flash("checkmark.circle.fill")
    } catch {
      log("menu", "FAIL", error.localizedDescription)
      StatusUI.shared.flash("exclamationmark.triangle.fill")
      NSSound.beep()
    }
  }

  @objc func revealLog() {
    NSWorkspace.shared.activateFileViewerSelecting([logURL])
  }
}

// MARK: - The service

/// AppKit delivers service requests on the main thread, which is what makes the
/// main-actor isolation here honest rather than a way to quiet the compiler.
@MainActor
final class ServiceProvider: NSObject {
  /// Replaces the selection. The host reads the pasteboard the instant this
  /// returns, so the network call has to finish first; `createLink` bounds its own
  /// wait so an unreachable server cannot wedge the app.
  @objc func replaceSelection(
    _ pboard: NSPasteboard,
    userData: String?,
    error errorOut: AutoreleasingUnsafeMutablePointer<NSString>?
  ) {
    guard let text = usableSecret(pboard.string(forType: .string)) else {
      log("replace", "FAIL", "empty selection")
      errorOut?.pointee = "Select the secret first." as NSString
      return
    }

    do {
      let link = try SecureSendAPI.createLink(note: text, expiry: defaultExpiry)
      pboard.clearContents()
      pboard.setString(link, forType: .string)
      log("replace", "OK", "in=\(text.count)ch")
      StatusUI.shared.flash("checkmark.circle.fill")
    } catch {
      // The selection is left exactly as it was: a failed send must never eat the
      // only copy of the thing somebody was trying to send.
      log("replace", "FAIL", error.localizedDescription)
      errorOut?.pointee = (error.localizedDescription as NSString)
      StatusUI.shared.flash("exclamationmark.triangle.fill")
    }
  }

  /// The universal fallback, for hosts that will not take a replacement and for
  /// selections that are not editable in the first place.
  @objc func copyToClipboard(
    _ pboard: NSPasteboard,
    userData: String?,
    error errorOut: AutoreleasingUnsafeMutablePointer<NSString>?
  ) {
    guard let text = usableSecret(pboard.string(forType: .string)) else {
      log("clipboard", "FAIL", "empty selection")
      errorOut?.pointee = "Select the secret first." as NSString
      return
    }

    do {
      let link = try SecureSendAPI.createLink(note: text, expiry: defaultExpiry)
      let general = NSPasteboard.general
      general.clearContents()
      general.setString(link, forType: .string)
      log("clipboard", "OK", "in=\(text.count)ch")
      StatusUI.shared.flash("checkmark.circle.fill")
    } catch {
      log("clipboard", "FAIL", error.localizedDescription)
      errorOut?.pointee = (error.localizedDescription as NSString)
      StatusUI.shared.flash("exclamationmark.triangle.fill")
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    StatusUI.shared.install()
    log("boot", "pid=\(ProcessInfo.processInfo.processIdentifier)")
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let provider = ServiceProvider()
app.servicesProvider = provider
NSUpdateDynamicServices()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
