import AppKit
import SecureSendKit

// Draws the application icon into an .iconset directory, which iconutil turns
// into AppIcon.icns. See scripts/icon.sh, which is the only thing that should
// run this.
//
// The mark comes from markPath, the same geometry the menu bar draws, so the
// icon in the Dock and the glyph in the bar can never drift apart. The colours
// are the site's own: surface for the ground, accent for the mark, spelled out
// here because a Swift target has no stylesheet to read a token from. If either
// moves in apps/web/src/styles/tokens.css, move it here too.

let surface = NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 1)
let accent = NSColor(srgbRed: 0x2d / 255, green: 0xd4 / 255, blue: 0xbf / 255, alpha: 1)

/// Apple's icon grid, as ratios of the canvas. On the 1024 canvas the rounded
/// square is 824 wide, centred, with a corner radius of 185.4. Every size below
/// is that same shape scaled, which is what makes the icon look like it belongs
/// beside the ones Apple ships rather than a square someone pasted in.
let squircleInset = 100.0 / 1024.0
let squircleRadius = 185.4 / 824.0

/// How much of the rounded square the mark fills. The mark is an open shape with
/// a lot of air in it, so it carries a larger box than a solid glyph would.
let markShare = 0.62

let entries: [(name: String, pixels: Int)] = [
  ("icon_16x16", 16),
  ("icon_16x16@2x", 32),
  ("icon_32x32", 32),
  ("icon_32x32@2x", 64),
  ("icon_128x128", 128),
  ("icon_128x128@2x", 256),
  ("icon_256x256", 256),
  ("icon_256x256@2x", 512),
  ("icon_512x512", 512),
  ("icon_512x512@2x", 1024),
]

func render(pixels: Int) -> Data? {
  let side = CGFloat(pixels)
  let image = NSImage(size: NSSize(width: side, height: side))

  image.lockFocus()
  NSGraphicsContext.current?.imageInterpolation = .high

  let inset = side * squircleInset
  let ground = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
  let radius = ground.width * squircleRadius
  surface.setFill()
  NSBezierPath(roundedRect: ground, xRadius: radius, yRadius: radius).fill()

  // Measured, then drawn again where the measurement says it belongs. The mark
  // is not centred inside its own 32pt box, so centring the box would leave it
  // visibly high and to the left.
  let edge = ground.width * markShare
  let measured = markPath(edge: edge).bounds
  let centred = markPath(
    edge: edge,
    origin: NSPoint(
      x: ground.midX - measured.midX,
      y: ground.midY - measured.midY
    )
  )
  accent.setFill()
  centred.fill()

  image.unlockFocus()

  guard let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff)
  else { return nil }
  return rep.representation(using: .png, properties: [:])
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try FileManager.default.createDirectory(
  atPath: directory, withIntermediateDirectories: true
)

for entry in entries {
  guard let png = render(pixels: entry.pixels) else {
    FileHandle.standardError.write(Data("could not encode \(entry.name)\n".utf8))
    exit(1)
  }
  try png.write(to: URL(fileURLWithPath: "\(directory)/\(entry.name).png"))
}

print(directory)
