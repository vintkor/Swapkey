import AppKit
import ApplicationServices

/// Finds where on screen the user is typing, in Cocoa (bottom-left origin) coordinates.
///
/// Apps expose this very unevenly, so several sources are tried in order:
/// caret bounds → bounds of the character before/after the caret → focused element → focused window.
///
/// Runs off the main thread: AX calls block until the target app answers. `screens` are the
/// `NSScreen.screens` frames captured on the main thread, primary screen first.
enum CaretLocator {
    enum Source: String { case caret, previousChar, nextChar, element, window }

    /// Global AX timeout (the default is ~6 s per call). Per-element timeouts do not carry over
    /// to child elements, so set it on the system-wide element once.
    private static let setTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }()

    static func locate(pid: pid_t, screens: [NSRect]) -> (rect: NSRect, source: Source)? {
        _ = setTimeout
        let appElement = AXUIElementCreateApplication(pid)
        // Electron (VS Code, Slack, Telegram, …) and Chromium build their AX tree only on request.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let element: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) {
            if let result = caretRect(in: element, screens: screens) { return result }
            if let rect = frame(of: element, screens: screens), isPlausible(rect, screens: screens, maxHeight: 400) { return (rect, .element) }
        }
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute),
           let rect = frame(of: window, screens: screens), isPlausible(rect, screens: screens, maxHeight: .infinity) {
            return (rect, .window)
        }
        return nil
    }

    /// Text right before and after the caret in the focused element, up to `limit` UTF-16 units each way.
    /// Nil if the element exposes no text or something is selected.
    static func surroundingText(pid: pid_t, limit: Int = 64) -> (before: String, after: String)? {
        _ = setTimeout
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let element: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute),
              let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var caret = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &caret), caret.length == 0, caret.location >= 0 else { return nil }

        let start = max(0, caret.location - limit)
        let before = CFRange(location: start, length: caret.location - start)
        // Ask only for the text around the caret: the whole value of a long document is slow to copy.
        if let count: Int = attribute(element, kAXNumberOfCharactersAttribute), count >= caret.location {
            let after = CFRange(location: caret.location, length: min(limit, count - caret.location))
            if let beforeText = string(in: element, range: before), let afterText = string(in: element, range: after) {
                return (beforeText, afterText)
            }
        }
        guard let value: String = attribute(element, kAXValueAttribute) else { return nil }
        let text = value as NSString
        guard caret.location <= text.length else { return nil }
        let afterLength = min(limit, text.length - caret.location)
        return (text.substring(with: NSRange(location: before.location, length: before.length)),
                text.substring(with: NSRange(location: caret.location, length: afterLength)))
    }

    private static func string(in element: AXUIElement, range: CFRange) -> String? {
        if range.length == 0 { return "" }
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success else { return nil }
        return result as? String
    }

    private static func caretRect(in element: AXUIElement, screens: [NSRect]) -> (NSRect, Source)? {
        guard let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }

        // Many apps return an empty or bogus rect for a zero-length selection; neighbour chars work more often.
        if let rect = bounds(in: element, screens: screens, range: range), isPlausible(rect, screens: screens) {
            return (rect, .caret)
        }
        if range.location > 0,
           let rect = bounds(in: element, screens: screens, range: CFRange(location: range.location - 1, length: 1)), isPlausible(rect, screens: screens) {
            return (NSRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height), .previousChar)
        }
        if let rect = bounds(in: element, screens: screens, range: CFRange(location: range.location, length: 1)), isPlausible(rect, screens: screens) {
            return (NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), .nextChar)
        }
        return nil
    }

    private static func bounds(in element: AXUIElement, screens: [NSRect], range: CFRange) -> NSRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
        return toCocoa(rect, screens: screens)
    }

    private static func frame(of element: AXUIElement, screens: [NSRect]) -> NSRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return toCocoa(CGRect(origin: position, size: size), screens: screens)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// AX uses a top-left origin on the primary screen; Cocoa uses bottom-left.
    private static func toCocoa(_ rect: CGRect, screens: [NSRect]) -> NSRect {
        let primaryHeight = screens.first?.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Rejects the junk some apps return: zero rects, absurd sizes, points off every screen.
    private static func isPlausible(_ rect: NSRect, screens: [NSRect], maxHeight: CGFloat = 200) -> Bool {
        guard rect.height > 0, rect.height <= maxHeight, rect.width >= 0 else { return false }
        if rect.origin == .zero { return false }
        let point = NSPoint(x: rect.minX + 1, y: rect.midY)
        return screens.contains { $0.contains(point) }
    }
}
