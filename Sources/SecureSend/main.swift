import AppKit
import SecureSendKit

// SecureSend, as a macOS menu bar app. No Accessibility grant and no Input
// Monitoring, ever. That is a product decision, not an accident. A global hotkey
// that replaces a selection can only work by faking command-C and command-V,
// which needs Accessibility, so selection replacement stays the right-click's job
// and the keyboard path goes through the clipboard.
//
// One TCC prompt is reachable, and only one: saving an attachment into Downloads
// is macOS's standard files-and-folders consent, asked at the moment a secret
// with files in it is actually saved. Nothing else here touches a protected
// folder, and no path asks for a permission the person has not just triggered.
//
// Sending:
//   1. right-click > Services > "Replace with SecureSend link"
//   2. right-click > Services > "Copy as SecureSend link", for hosts that will
//      not take a replacement
//   3. control-shift-C, or the menu bar item > Generate from clipboard, when
//      there is no live selection
//
// Receiving, which is the same trip backwards:
//   4. control-shift-V, or the menu bar item > Open link from clipboard
//
// The receiving side never reads the clipboard to find out whether there is a
// link on it, and never opens one without saying first that opening destroys it.
// See Clipboard.swift and Consume.swift.
//
// Nothing here ever logs the link. The link contains the fragment token, and the
// fragment token contains the key: writing one to a log file would undo the whole
// product. Lengths and hosts only. See Log.swift.

/// A right-click has no screen to choose an expiry on, so the app picks one.
let defaultExpiry = SecureSendAPI.Expiry.oneDay

// MARK: - Menu bar presence

@MainActor
final class StatusUI {
  static let shared = StatusUI()
  private var statusItem: NSStatusItem?
  private var restore: Task<Void, Never>?

  /// `held` is what the window server actually gave us, so a shortcut that failed
  /// to register is not advertised next to a menu item that would then be the only
  /// way to reach it.
  func install(held: Set<Shortcut>) {
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
    teach(generate, .generate, held: held)

    // The other direction, the same trip backwards.
    let consume = menu.addItem(
      withTitle: "Open link from clipboard",
      action: #selector(AppActions.consumeFromClipboard),
      keyEquivalent: ""
    )
    consume.target = AppActions.shared
    teach(consume, .consume, held: held)

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Or select text anywhere, then right-click", action: nil, keyEquivalent: ""
    ).isEnabled = false
    menu.addItem(.separator())
    let updates = menu.addItem(
      withTitle: "Check for updates…",
      action: #selector(AppActions.checkForUpdates),
      keyEquivalent: ""
    )
    updates.target = AppActions.shared
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

  /// Puts the shortcut beside the item that does the same thing, so the menu is
  /// where somebody learns it. Silent when the combination was not registered:
  /// printing a key equivalent that fires nothing is worse than printing none.
  private func teach(_ item: NSMenuItem, _ shortcut: Shortcut, held: Set<Shortcut>) {
    guard held.contains(shortcut) else { return }
    item.keyEquivalent = shortcut.menuKeyEquivalent.key
    item.keyEquivalentModifierMask = shortcut.menuKeyEquivalent.modifiers
  }

  /// For work that outlasts a flash. A file has to be read, encrypted and
  /// uploaded before there is anything to confirm, and a mark that expired
  /// halfway through would say the opposite of what is happening.
  func hold(_ symbol: String) {
    guard let button = statusItem?.button else { return }
    restore?.cancel()
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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

  @objc func consumeFromClipboard() {
    Consume.fromClipboard()
  }

  @objc func checkForUpdates() {
    Updates.check()
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

  /// Files picked in Finder. This one answers the host nothing, so it returns at
  /// once and says what happened through the menu bar and a panel. See Files.swift
  /// for why that is not the same shape as the two above.
  @objc func copyFilesToClipboard(
    _ pboard: NSPasteboard,
    userData: String?,
    error errorOut: AutoreleasingUnsafeMutablePointer<NSString>?
  ) {
    Files.send(Files.urls(on: pboard))
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Held for the process's life: releasing it unregisters the hotkey.
  private let hotkey = GlobalHotkey()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Hotkeys first, because the menu prints only the ones that were granted.
    // A combination somebody else already owns is not worth a modal on login:
    // every other way in still works, and the menu item does the same job.
    let held = hotkey.install { shortcut in
      switch shortcut {
      case .generate: AppActions.shared.generateFromClipboard()
      case .consume: Consume.fromClipboard()
      }
    }
    StatusUI.shared.install(held: held)

    let shortcuts = held.isEmpty ? "none" : held.map(\.name).sorted().joined(separator: " ")
    log(
      "boot",
      "pid=\(ProcessInfo.processInfo.processIdentifier)",
      "hotkeys=\(shortcuts)"
    )
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
