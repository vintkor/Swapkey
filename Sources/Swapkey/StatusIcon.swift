import AppKit

/// Menu bar glyph: the app icon in one colour, a rounded square with the keyboard cut out of it.
/// A template image, so the system tints it for light/dark menu bars and the disabled state.
enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let shape = rect.insetBy(dx: 1, dy: 1)
            NSBezierPath(roundedRect: shape, xRadius: shape.width * 0.225, yRadius: shape.width * 0.225).fill()

            // The keyboard is drawn by hand: a scaled-down SF Symbol lands between pixels and comes out blurry.
            // Every edge sits on the 0.5 pt grid, which is one pixel on Retina.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let frame = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5, width: 11, height: 8), xRadius: 1.5, yRadius: 1.5)
            frame.append(NSBezierPath(rect: NSRect(x: 4.5, y: 6, width: 9, height: 6)).reversed)
            frame.fill()
            var keys: [NSRect] = []
            for row in 0..<2 {
                for column in 0..<5 {
                    keys.append(NSRect(x: 5.5 + CGFloat(column) * 1.5, y: 10 - CGFloat(row) * 1.5, width: 1, height: 1))
                }
            }
            keys += [NSRect(x: 5.5, y: 7, width: 1, height: 1), NSRect(x: 7, y: 7, width: 4, height: 1),
                     NSRect(x: 11.5, y: 7, width: 1, height: 1)]
            keys.forEach { $0.fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Swapkey"
        return image
    }
}
