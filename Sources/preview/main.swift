import AppKit
import SecureSendKit

// Renders the menu bar mark at candidate sizes on a dark and a light bar, so the
// icon is judged as pixels rather than guessed at. Writes one PNG and exits.

let sizes: [CGFloat] = [14, 15, 16, 17, 18, 20]
let scale: CGFloat = 5
let cell = NSSize(width: 60, height: 28)
let canvas = NSSize(width: cell.width * CGFloat(sizes.count), height: cell.height * 2)

let out = NSImage(size: NSSize(width: canvas.width * scale, height: canvas.height * scale))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
let zoom = NSAffineTransform()
zoom.scale(by: scale)
zoom.concat()

// The dark menu bar on top, the light one below.
let bars: [(background: NSColor, ink: NSColor, y: CGFloat)] = [
  (NSColor(white: 0.13, alpha: 1), .white, cell.height),
  (NSColor(white: 0.97, alpha: 1), .black, 0),
]

for bar in bars {
  bar.background.setFill()
  NSRect(x: 0, y: bar.y, width: canvas.width, height: cell.height).fill()

  for (index, edge) in sizes.enumerated() {
    let box = NSRect(
      x: CGFloat(index) * cell.width, y: bar.y, width: cell.width, height: cell.height
    )
    bar.ink.setFill()
    markPath(
      edge: edge,
      origin: NSPoint(x: box.midX - edge / 2, y: box.midY - edge / 2)
    ).fill()

    ("\(Int(edge))pt" as NSString).draw(
      at: NSPoint(x: box.minX + 3, y: box.minY + 1),
      withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular),
        .foregroundColor: bar.ink.withAlphaComponent(0.5),
      ]
    )
  }
}

out.unlockFocus()

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./mark-preview.png"
guard let tiff = out.tiffRepresentation,
  let rep = NSBitmapImageRep(data: tiff),
  let png = rep.representation(using: .png, properties: [:])
else {
  FileHandle.standardError.write(Data("could not encode the preview\n".utf8))
  exit(1)
}
try png.write(to: URL(fileURLWithPath: path))
print(path)
