import Foundation

// A folder to work in that is gone by the time the test returns.
//
// Two suites reach the real filesystem, one saving attachments and one reading
// them, and both have to do it somewhere that is not a real folder of somebody's.
// Shared rather than copied, so a test that leaves its folder behind is a bug
// with one place to fix.

func inTemporaryFolder(_ body: (URL) throws -> Void) throws {
  let folder = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("securesend-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }

  try body(folder)
}
