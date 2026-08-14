import AppKit

/// The mark from apps/web/public/favicon.svg, at any size, anchored anywhere.
///
/// The SVG numbers are kept verbatim and converted here so this stays diffable
/// against that file: SVG is a 32pt grid with y growing downward, AppKit grows
/// upward. If the mark changes there, change these six calls.
public func markPath(edge: CGFloat, origin: NSPoint = .zero) -> NSBezierPath {
  let s = edge / 32
  func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: origin.x + x * s, y: origin.y + (32 - y) * s)
  }

  let path = NSBezierPath()
  path.move(to: p(3, 4))
  path.curve(to: p(29, 4), controlPoint1: p(12, 8), controlPoint2: p(22, 9))
  path.curve(to: p(22, 14), controlPoint1: p(27, 11), controlPoint2: p(25, 14))
  path.line(to: p(17, 14))
  path.curve(to: p(11, 29), controlPoint1: p(17, 19), controlPoint2: p(18, 23))
  path.curve(to: p(3, 4), controlPoint1: p(13, 21), controlPoint2: p(8, 11))
  path.close()
  return path
}

/// A template image, so the menu bar tints it itself: white on a dark bar, black
/// on a light one, and correct in every future appearance we do not know about.
public func markImage(edge: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
    NSColor.black.setFill()
    markPath(edge: edge).fill()
    return true
  }
  image.isTemplate = true
  return image
}
