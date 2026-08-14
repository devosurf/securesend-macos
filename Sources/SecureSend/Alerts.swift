import AppKit

// How this app talks to a person, which is only ever a panel.
//
// It has no windows, no Dock icon and no notification permission, so an alert is
// the only surface there is. Shared rather than per-feature, because a panel that
// comes forward and a panel that opens behind the thing somebody was reading are
// different products, and that difference should not depend on which file raised
// it.

@MainActor
enum Alerts {
  /// One thing to say and a button to dismiss it.
  static func tell(_ message: String, _ detail: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    _ = run(alert)
  }

  /// The app has no windows and no Dock icon, so it has to come forward on its
  /// own or the panel opens behind whatever the person was looking at.
  static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.activate()
    return alert.runModal()
  }

  /// An error's own words, never a secret's. Every error that reaches a panel is
  /// one this app wrote, and none of them quotes a link, an id or any plaintext.
  static func short(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(type(of: error))"
  }
}
