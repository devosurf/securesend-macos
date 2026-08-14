import AppKit
import SecureSendKit

// The Finder half of the way out: pick files, right-click, get a link.
//
// It is the only Service here that does not answer the host. The two text ones
// hand a link back on a pasteboard and so have to block until there is one; this
// one puts the link on the general clipboard when it exists, which means the
// method can return at once and the upload can take the second or two a real file
// takes. A blocked main thread would be a frozen menu bar and a panel that cannot
// open, which is the whole surface this app has to say anything with.
//
// That is also why nothing here writes to the Service's `error` argument. There
// is no moment left to hand a sentence back in, so every refusal comes back the
// way the receiving side's do: a panel, and a mark in the menu bar.

@MainActor
enum Files {
  /// The file urls the system put on the Service pasteboard, in Finder's order.
  static func urls(on pboard: NSPasteboard) -> [URL] {
    let found = pboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
    )

    return found as? [URL] ?? []
  }

  /// Reads, seals and posts them, then puts the link on the clipboard.
  ///
  /// Returns immediately. Reading and encrypting happen off the main thread
  /// because a ten megabyte file is real work, and the cap is checked inside
  /// `Attach.read` before a single byte is read.
  static func send(_ urls: [URL]) {
    StatusUI.shared.hold("arrow.up.circle.fill")

    Task {
      do {
        let files = try await Task.detached(priority: .userInitiated) {
          try Attach.read(urls)
        }.value

        let link = try await SecureSendAPI.createLink(files: files, expiry: defaultExpiry)
        Clipboard.replace(with: link)
        log("finder", "OK", "files=\(files.count)")
        StatusUI.shared.flash("checkmark.circle.fill")
      } catch {
        // Never the localized sentence for a read failure: that one is the
        // system's, and the system names the file in it.
        log("finder", "FAIL", (error as? Attach.Failure)?.label ?? Alerts.short(error))
        StatusUI.shared.flash("exclamationmark.triangle.fill")
        Alerts.tell("Nothing was sent.", Alerts.short(error), style: .warning)
      }
    }
  }
}
