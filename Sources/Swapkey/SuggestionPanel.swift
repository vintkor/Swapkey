import AppKit

/// Small floating window next to the caret listing layouts the user probably meant.
final class SuggestionPanel {
    struct Segment {
        let text: String
        /// Re-rendered in the candidate layout, as opposed to kept as typed.
        let changed: Bool
    }

    struct Row {
        /// Digit for the hotkey, nil if the layout has none (past the 9th).
        let hotkey: Int?
        /// What will be typed if this row is picked.
        let segments: [Segment]
        let layoutName: String
    }

    /// Longer text is cut from the start: the end, next to the caret, is what the user just typed.
    static let maxTextLength = 40

    private let panel: NSPanel
    private let stack = NSStackView()
    /// Opaque on purpose: a translucent material lets busy content behind show through and kills contrast.
    private let content = PanelBackground()

    /// Where the panel was attached when shown; updates keep it there instead of chasing the caret.
    private var anchor: NSRect?
    private var hotkeyPrefix = ""

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]


        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Padding via constraints: with .leading alignment the stack ignores its right edge inset.
        stack.edgeInsets = NSEdgeInsetsZero
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
        ])
        panel.contentView = content
    }

    func show(_ rows: [Row], title: String, hotkeyPrefix: String, caret: (rect: NSRect, source: CaretLocator.Source)?) {
        self.hotkeyPrefix = hotkeyPrefix
        anchor = anchorRect(caret)
        render(rows, title: title)
        panel.orderFrontRegardless()
    }

    /// Replaces the rows of a visible panel without moving it.
    func update(_ rows: [Row], title: String) {
        guard panel.isVisible else { return }
        render(rows, title: title)
    }

    private func render(_ rows: [Row], title: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label(title, size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(grid(rows))
        stack.addArrangedSubview(label("Esc — скрыть", size: 11, color: .secondaryLabelColor))

        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(frame(for: size, near: anchor), display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// One row per candidate, columns aligned: hotkey | text | layout name.
    private func grid(_ rows: [Row]) -> NSGridView {
        let views = rows.map { row in
            [
                label(row.hotkey.map { "\(hotkeyPrefix)\($0)" } ?? "", font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                      color: .controlAccentColor),
                singleLine(NSTextField(labelWithAttributedString: Self.phrase(row.segments))),
                label(row.layoutName, font: .systemFont(ofSize: 12), color: .secondaryLabelColor),
            ]
        }
        let grid = NSGridView(views: views)
        grid.columnSpacing = 10
        grid.rowSpacing = 4
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// Corrected words stand out, words kept as typed are dimmed.
    private static func phrase(_ segments: [Segment]) -> NSAttributedString {
        let changed: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let kept: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSMutableAttributedString()
        for segment in segments {
            text.append(NSAttributedString(string: segment.text, attributes: segment.changed ? changed : kept))
        }
        // Trailing space is noise; long text is cut at the start, away from the caret.
        while text.string.last?.isWhitespace == true {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        if text.length > maxTextLength {
            text.deleteCharacters(in: NSRange(location: 0, length: text.length - (maxTextLength - 1)))
            while text.string.first?.isWhitespace == true {
                text.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
            text.insert(NSAttributedString(string: "…", attributes: kept), at: 0)
        }
        return text
    }

    private func label(_ string: String, size: CGFloat, color: NSColor) -> NSTextField {
        label(string, font: .systemFont(ofSize: size), color: color)
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        return singleLine(field)
    }

    private func singleLine(_ field: NSTextField) -> NSTextField {
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }

    /// Where to attach the panel: right under the caret if possible, otherwise somewhere sensible.
    private func anchorRect(_ caret: (rect: NSRect, source: CaretLocator.Source)?) -> NSRect? {
        guard let (rect, source) = caret else {
            NSLog("Swapkey: caret not found, using mouse location")
            return nil
        }
        NSLog("Swapkey: anchor from \(source.rawValue): \(NSStringFromRect(rect))")
        switch source {
        case .caret, .previousChar, .nextChar, .element:
            return rect
        case .window:
            // No idea where in the window the caret is: show it in the middle rather than under the window.
            return NSRect(x: rect.midX - 100, y: rect.midY, width: 0, height: 0)
        }
    }

    private func frame(for size: NSSize, near anchor: NSRect?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let anchor = anchor ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let gap: CGFloat = 6

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - gap)
        if origin.y < visible.minY { origin.y = anchor.maxY + gap }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

/// Rounded opaque background that follows the light/dark appearance.
private final class PanelBackground: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        // CGColor does not track the appearance by itself, so resolve it on every redraw.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
