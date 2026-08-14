import AppKit

// Looking at the clipboard without reading it.
//
// macOS 15.4 added an alert for programmatic pasteboard reads that no paste-like
// gesture asked for, on by default from macOS 26. A secrets app that trips that
// alert every time somebody presses a hotkey reads as a clipboard snooper, and
// that is the exact reputation this product cannot afford.
//
// `detectedValues` is the way out. It runs data detection inside the system and
// answers with the patterns it found, without handing the app the pasteboard's
// contents and without the alert. Verified on macOS 26.5: the url comes back
// whole, fragment included, which matters more here than anywhere else in the
// product because the fragment is the key.
//
// Below 15.4 there is no alert to avoid, so the old read is the right one there.

@MainActor
enum Clipboard {
  /// The url on the clipboard, or nil. Never reads anything else that is on it.
  static func url() async -> String? {
    if #available(macOS 15.4, *) {
      guard
        let found = try? await NSPasteboard.general.detectedValues(for: [\.probableWebURL])
      else {
        return nil
      }

      let url = found.probableWebURL
      return url.isEmpty ? nil : url
    }

    return NSPasteboard.general.string(forType: .string)
  }

  /// Puts text on the clipboard, replacing what was there.
  static func replace(with text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
