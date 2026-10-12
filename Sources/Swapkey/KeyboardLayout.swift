import Carbon

/// Physical key press, independent of the layout that was active when it was typed.
struct KeyStroke {
    let keyCode: UInt16
    let shift: Bool
    let capsLock: Bool

    var isSpace: Bool { keyCode == UInt16(kVK_Space) }
}

/// Wrapper around a TIS keyboard layout that can translate key codes into characters.
final class KeyboardLayout {
    let source: TISInputSource
    let id: String
    let name: String
    /// Primary language of the layout (e.g. "en", "ru", "uk").
    let language: String?
    private let layoutData: CFData

    init?(source: TISInputSource) {
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.layoutData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        self.source = source
        self.id = Self.string(source, kTISPropertyInputSourceID) ?? ""
        self.name = Self.string(source, kTISPropertyLocalizedName) ?? id
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] {
            self.language = langs.first
        } else {
            self.language = nil
        }
    }

    func character(for stroke: KeyStroke) -> String {
        var modifiers: UInt32 = 0
        if stroke.shift { modifiers |= UInt32(shiftKey >> 8) }
        if stroke.capsLock { modifiers |= UInt32(alphaLock >> 8) }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let layout = UnsafeRawPointer(CFDataGetBytePtr(layoutData)!).assumingMemoryBound(to: UCKeyboardLayout.self)
        let status = UCKeyTranslate(
            layout,
            stroke.keyCode,
            UInt16(kUCKeyActionDown),
            modifiers,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    func text(for strokes: some Sequence<KeyStroke>) -> String {
        strokes.map(character(for:)).joined()
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

enum InputSources {
    /// Keyboard layouts enabled by the user in System Settings.
    static func enabledLayouts() -> [KeyboardLayout] {
        let filter = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap(KeyboardLayout.init)
    }

    static func currentLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(source: source)
    }

    static func select(_ layout: KeyboardLayout) {
        TISSelectInputSource(layout.source)
    }
}
