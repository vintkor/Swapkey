import AppKit

/// Menu bar glyph: the app icon in one colour, a rounded square with the keyboard cut out of it.
/// A template image, so the system tints it for light/dark menu bars and the disabled state.
enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let shape = rect.insetBy(dx: 1, dy: 1)
            NSBezierPath(roundedRect: shape, xRadius: shape.width * 0.225, yRadius: shape.width * 0.225).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
            guard let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return true }
            let symbolRect = NSRect(
                x: shape.midX - symbol.size.width / 2, y: shape.midY - symbol.size.height / 2,
                width: symbol.size.width, height: symbol.size.height
            )
            symbol.draw(in: symbolRect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Swapkey"
        return image
    }
}
