import AppKit

// The log, and what may never go in it.
//
// A link contains the fragment token, and the fragment token contains the key, so
// writing one line with a link in it would undo the whole product. The same goes
// for anything that came out of an envelope: a note, a filename, a username.
//
// What is allowed is shape. App names, states, counts, lengths. Enough to work
// out why a Service did nothing on a Tuesday, and not enough to open anything.

let logURL = URL(
  fileURLWithPath: NSString(string: "~/Library/Logs/securesend.log").expandingTildeInPath
)

func log(_ fields: String...) {
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
