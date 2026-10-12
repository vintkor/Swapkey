import Carbon
import Foundation
@testable import Swapkey

/// The layouts the tests type with, taken from every layout installed in macOS (not only the enabled
/// ones), so the results do not depend on the settings of the machine.
enum Layouts {
    static let english = layout("com.apple.keylayout.ABC")
    static let russian = layout("com.apple.keylayout.RussianWin")
    static let ukrainian = layout("com.apple.keylayout.Ukrainian-PC")

    static var all: [KeyboardLayout] { [english, russian, ukrainian].compactMap { $0 } }
    static var available: Bool { all.count == 3 }

    private static func layout(_ id: String) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return KeyboardLayout(source: source)
    }
}

/// Turns text into the key strokes that type it on a layout.
enum Typist {
    /// Nil if the layout cannot type some character of `text`.
    static func strokes(_ text: String, on layout: KeyboardLayout) -> [KeyStroke]? {
        let keys = keyMap(layout)
        var strokes: [KeyStroke] = []
        for character in text {
            guard let stroke = keys[String(character)] else { return nil }
            strokes.append(stroke)
        }
        return strokes
    }

    private static var cache: [String: [String: KeyStroke]] = [:]

    private static func keyMap(_ layout: KeyboardLayout) -> [String: KeyStroke] {
        if let cached = cache[layout.id] { return cached }
        var keys: [String: KeyStroke] = [:]
        // Main block first: the keypad repeats digits and "." under higher key codes.
        // Not the ISO section key: ANSI keyboards have none, and "ё" is under "`" there.
        for keyCode in 0..<128 where keyCode != kVK_ISO_Section {
            for shift in [false, true] {
                let stroke = KeyStroke(keyCode: UInt16(keyCode), shift: shift, capsLock: false)
                let character = layout.character(for: stroke)
                if !character.isEmpty, keys[character] == nil { keys[character] = stroke }
            }
        }
        cache[layout.id] = keys
        return keys
    }
}

/// What SwitchController would do while a line is typed word by word: which words open the panel
/// and from where a pick would retype.
struct Session {
    struct Offer {
        let word: String
        let decision: BufferAnalyzer.Decision
    }

    let strokes: [KeyStroke]
    let current: KeyboardLayout
    let analyzer: BufferAnalyzer
    private(set) var offers: [Offer] = []
    private(set) var anchor: Int?
    private(set) var candidates: [Candidate] = []

    /// Types `text` plus a final space on `current`, as if the strokes came from `typedOn`.
    init?(_ text: String, typedOn: KeyboardLayout, current: KeyboardLayout, analyzer: BufferAnalyzer) {
        guard let strokes = Typist.strokes(text + " ", on: typedOn) else { return nil }
        self.strokes = strokes
        self.current = current
        self.analyzer = analyzer
        analyzer.reset()

        var start = 0
        for end in strokes.indices where strokes[end].isSpace {
            defer { start = end + 1 }
            guard start < end else { continue }
            let decision = analyzer.decide(strokes, start..<end, current: current)
            switch decision {
            case .correct, .none:
                continue
            case .layouts(let found):
                if candidates.isEmpty { candidates = found }
            case .spelling:
                break
            }
            offers.append(Offer(word: current.text(for: strokes[start..<end]), decision: decision))
            if anchor == nil { anchor = analyzer.fragmentStart(strokes, before: start, current: current) }
        }
    }

    var layoutOffers: [String] {
        offers.compactMap { if case .layouts = $0.decision { $0.word } else { nil } }
    }

    var spellingOffers: [String] {
        offers.compactMap { if case .spelling = $0.decision { $0.word } else { nil } }
    }

    /// The whole line after picking `layout`: the part before the anchor as typed, the rest corrected.
    func picked(_ layout: KeyboardLayout) -> String {
        let anchor = anchor ?? strokes.count
        let fragment = analyzer.correction(strokes, from: anchor, to: layout, current: current).map(\.text).joined()
        return (current.text(for: strokes[..<anchor]) + fragment).trimmingCharacters(in: .whitespaces)
    }
}

enum Corpus {
    static func lines(_ name: String) -> [String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Corpus"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
