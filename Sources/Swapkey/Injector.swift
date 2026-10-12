import Carbon
import CoreGraphics
import Foundation

/// Posts synthetic keyboard events to erase and retype text in the focused app.
enum Injector {
    /// Tag on our own events so the monitor ignores them ("SWAP").
    static let marker: Int64 = 0x5357_4150

    private static let queue = DispatchQueue(label: "swapkey.injector")
    private static let delay: useconds_t = 3_000

    static func replace(deleteCount: Int, with text: String) {
        queue.async {
            // Private state: the user's still-held hotkey modifier must not leak into our events.
            let source = CGEventSource(stateID: .privateState)
            for _ in 0..<deleteCount {
                post(keyCode: CGKeyCode(kVK_Delete), source: source)
            }
            for char in text {
                post(keyCode: 0, unicode: Array(String(char).utf16), source: source)
            }
        }
    }

    private static func post(keyCode: CGKeyCode, unicode: [UniChar]? = nil, source: CGEventSource?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if let unicode {
                event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            event.post(tap: .cghidEventTap)
            usleep(delay)
        }
    }
}
