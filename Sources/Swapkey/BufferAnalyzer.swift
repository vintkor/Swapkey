import Foundation

/// What the typed buffer means: verdicts on finished words, what to offer for them, the automatic
/// rewrites and what a pick would type. No UI, no event tap and no side effects besides the spell
/// checker caches, so it works on plain stroke arrays (and is what the tests drive).
///
/// Caches are keyed by text in the current layout: call `reset()` whenever the buffer is dropped.
final class BufferAnalyzer {
    enum Decision {
        /// Valid in the current language.
        case correct
        /// Typed in the wrong layout: offer these.
        case layouts([Candidate])
        /// A typo in the current language: offer the spelling fix.
        case spelling
        /// Nothing to say (too short, no dictionary, or not trusted).
        case none
    }

    let detector = LayoutDetector()
    /// The single switch for everything spelling-related: with it off, nothing gets fixed.
    var spellingEnabled = true
    /// The layouts Swapkey works with (enabled and not switched off).
    var layouts: [KeyboardLayout] = []

    /// Spell checker verdicts by the word's text in the current layout.
    private var verdicts: [String: Verdict] = [:]
    /// Spelling fixes by layout and text; nil values (nothing to fix) are cached too.
    private var fixes: [String: String?] = [:]
    /// Dictionary lookups by layout and text.
    private var words: [String: Bool] = [:]

    func reset() {
        verdicts.removeAll()
        fixes.removeAll()
        words.removeAll()
    }

    // MARK: - Finished words

    func decide(_ strokes: [KeyStroke], _ range: Range<Int>, current: KeyboardLayout) -> Decision {
        switch verdict(strokes, range, current: current) {
        case .correct:
            return .correct
        case .wrong(let candidates):
            let trusted = candidates.filter { isTrusted($0.layout, strokes, range, current: current) }
            return trusted.isEmpty ? .none : .layouts(trusted)
        case .unknown:
            // Valid nowhere: a typo in the current language, or a typo made in the wrong layout.
            let word = strokes[range]
            if spellingFix(current.text(for: word), in: current) != nil { return .spelling }
            let candidates = layouts.compactMap { layout -> Candidate? in
                let text = layout.text(for: word)
                // Same text in both layouts (Russian and Ukrainian share most letters): that would be a
                // spelling fix in another language, not a layout mistake.
                guard layout.id != current.id, text != current.text(for: word),
                      isTrusted(layout, strokes, range, current: current),
                      let fix = spellingFix(text, in: layout) else { return nil }
                return Candidate(layout: layout, word: fix)
            }
            return candidates.isEmpty ? .none : .layouts(candidates)
        }
    }

    func verdict(_ strokes: [KeyStroke], _ range: Range<Int>, current: KeyboardLayout) -> Verdict {
        let word = Array(strokes[range])
        let key = current.text(for: word)
        if let cached = verdicts[key] { return cached }
        let verdict = detector.analyze(word, current: current, layouts: layouts)
        verdicts[key] = verdict
        return verdict
    }

    /// Valid in the current language, but a word in `layout` too once converted: "Lf" ↔ "Да", "шею" ↔ "it."
    /// (dictionaries accept many short abbreviations). Such a word takes the layout of its neighbours.
    func isAmbiguous(_ strokes: [KeyStroke], _ range: Range<Int>, current: KeyboardLayout, layout: KeyboardLayout) -> Bool {
        let typed = current.text(for: strokes[range])
        let converted = Self.convert(strokes[range], from: current, to: layout)
        return converted != typed && isWord(converted, in: layout)
    }

    private func isWord(_ text: String, in layout: KeyboardLayout) -> Bool {
        let key = layout.id + "\u{1}" + text
        if let cached = words[key] { return cached }
        let result = detector.isWord(text, in: layout)
        words[key] = result
        return result
    }

    func spellingFix(_ text: String, in layout: KeyboardLayout) -> String? {
        guard spellingEnabled else { return nil }
        let key = layout.id + "\u{1}" + text
        if let cached = fixes[key] { return cached }
        let fix = detector.spellingFix(for: text, in: layout)
        fixes[key] = fix
        return fix
    }

    /// Russian and Ukrainian share most keys, so a word missing from the current dictionary often turns
    /// into a valid word of the other language by one letter ("кейсы" → "кейсі"). Such a candidate is
    /// dropped when one of the recent words is valid in the current language only: the user is writing
    /// in it, and the word is just not in the dictionary. Layouts with different letters always pass.
    func isTrusted(_ layout: KeyboardLayout, _ strokes: [KeyStroke], _ range: Range<Int>, current: KeyboardLayout) -> Bool {
        guard Self.isSibling(layout, of: current, for: strokes[range]) else { return true }
        var end = range.lowerBound - 1
        for _ in 0..<5 {
            guard end > 0 else { break }
            let start = Self.wordStart(strokes, before: end)
            let previous = start..<end
            if !previous.isEmpty, case .correct = verdict(strokes, previous, current: current),
               !detector.isWord(layout.text(for: strokes[previous]), in: layout) {
                return false
            }
            end = start - 1
        }
        return true
    }

    /// Whether `layout` renders the word with at least half of the same letters, like Russian and Ukrainian.
    static func isSibling(_ layout: KeyboardLayout, of current: KeyboardLayout, for word: ArraySlice<KeyStroke>) -> Bool {
        let typed = Array(current.text(for: word))
        let converted = Array(layout.text(for: word))
        let shared = zip(typed, converted).filter { $0 == $1 && $0.isLetter }.count
        return shared * 2 >= typed.filter(\.isLetter).count
    }

    /// Words worth teaching the dictionary when the user leaves them as typed: flagged only because the
    /// current dictionary lacks them (a spelling fix in the current language, or a candidate of a
    /// sibling layout). Never wrong-layout gibberish like "ghbdtn", which would then stop being caught.
    func learnableWords(_ strokes: [KeyStroke], from start: Int, current: KeyboardLayout) -> [String] {
        var words: [String] = []
        var index = start
        while index < strokes.count {
            let end = strokes[index...].firstIndex(where: \.isSpace) ?? strokes.count
            // The word being typed is unfinished: half a word is always "misspelled".
            guard end < strokes.count else { break }
            let range = index..<end
            if !range.isEmpty, let core = LayoutDetector.core(of: current.text(for: strokes[range])) {
                let learnable: Bool
                switch verdict(strokes, range, current: current) {
                case .correct: learnable = false
                case .unknown: learnable = spellingFix(core, in: current) != nil
                case .wrong(let candidates):
                    learnable = candidates.allSatisfy { Self.isSibling($0.layout, of: current, for: strokes[range]) }
                }
                if learnable { words.append(core) }
            }
            index = end + 1
        }
        return words
    }

    // MARK: - Automatic rewrites

    /// The buffer with the rewrites applied without asking after the word at `range` is typed.
    func autoFixed(
        _ strokes: [KeyStroke], _ range: Range<Int>, current: KeyboardLayout, stickyShift: Bool, capitalize: Bool
    ) -> [KeyStroke] {
        var fixed = strokes
        if stickyShift { fixStickyShift(&fixed, range, current: current) }
        if capitalize { capitalizeSentence(&fixed, range, current: current) }
        return fixed
    }

    /// "ПРивет" → "Привет": two capitals followed by at least two lowercase letters, fixed only if the
    /// result is a dictionary word (so "IPhone", "MHz" or "IDs" stay).
    private func fixStickyShift(_ strokes: inout [KeyStroke], _ range: Range<Int>, current: KeyboardLayout) {
        guard !strokes[range].contains(where: \.capsLock),
              let offset = Self.stickyShiftIndex(strokes[range].map { current.character(for: $0) }) else { return }
        let second = range.lowerBound + offset
        var fixed = strokes
        fixed[second] = KeyStroke(keyCode: strokes[second].keyCode, shift: false, capsLock: false)
        guard detector.isWord(current.text(for: fixed[range]), in: current) else { return }
        strokes = fixed
    }

    /// "Привет. как дела" → "Привет. Как дела": capitalizes a lowercase word right after ".", "!" or "?".
    /// Skipped after abbreviations ("т.е.", "т. д.", "см."), numbers and "...", for words with capitals
    /// inside ("iPhone"), and when the sentence end is not in the buffer.
    private func capitalizeSentence(_ strokes: inout [KeyStroke], _ range: Range<Int>, current: KeyboardLayout) {
        guard range.lowerBound >= 2, strokes[range.lowerBound - 1].isSpace,
              !strokes[range].contains(where: \.capsLock) else { return }
        let previousRange = Self.wordStart(strokes, before: range.lowerBound - 1)..<(range.lowerBound - 1)
        guard !previousRange.isEmpty, Self.endsSentence(current.text(for: strokes[previousRange])) else { return }
        // A "." typed in the wrong layout is a letter there ("ю" on the Russian layout).
        if case .wrong = verdict(strokes, previousRange, current: current) { return }

        let chars = strokes[range].map { current.character(for: $0) }
        guard let offset = chars.firstIndex(where: { $0.first?.isLetter == true }),
              chars[offset] != chars[offset].uppercased(),
              !chars[(offset + 1)...].contains(where: { $0 != $0.lowercased() }),
              LayoutDetector.core(of: chars.joined()) != nil else { return }
        // Only opening quotes and brackets before the letter, and nothing that is a letter in another
        // layout: in a wrong-layout word "[" or "'" is the first letter ("х", "э").
        for index in range.lowerBound..<(range.lowerBound + offset) {
            guard Self.openingPunctuation.contains(chars[index - range.lowerBound]),
                  !layouts.contains(where: { $0.character(for: strokes[index]).first?.isLetter == true }) else {
                return
            }
        }
        let index = range.lowerBound + offset
        strokes[index] = KeyStroke(keyCode: strokes[index].keyCode, shift: true, capsLock: false)
    }

    // MARK: - What a pick types

    /// Where the fragment a pick retypes starts, given the first wrong word at `start`. It also takes in
    /// the words right before it that were most likely typed in the same layout: one-letter words, too
    /// short for the dictionary ("F ntcns" → "А тесты"; real ones like "я", "и", "a", "I" stop it), and
    /// ambiguous ones, valid both as typed and converted ("Lf ytn" → "Да нет").
    func fragmentStart(_ strokes: [KeyStroke], before start: Int, current: KeyboardLayout) -> Int {
        let realWords = current.language.flatMap { Self.oneLetterWords[String($0.prefix(2))] } ?? []
        var start = start
        for _ in 0..<3 {
            guard start >= 2, strokes[start - 1].isSpace else { break }
            let end = start - 1
            let wordStart = Self.wordStart(strokes, before: end)
            guard wordStart < end, let core = LayoutDetector.core(of: current.text(for: strokes[wordStart..<end])) else { break }
            let range = wordStart..<end
            let shortWord = core.count < LayoutDetector.minWordLength && !realWords.isEmpty
                && !core.lowercased().allSatisfy(realWords.contains)
            let ambiguous = layouts.contains { $0.id != current.id && isAmbiguous(strokes, range, current: current, layout: $0) }
            guard shortWord || ambiguous else { break }
            start = wordStart
        }
        return start
    }

    /// The fragment from `start` with every word that is not valid in the current layout
    /// re-rendered through `layout` (and spell-fixed there once finished). Correct words, spaces and
    /// tokens that would not become a word in `layout` (numbers, dashes) stay as typed.
    func correction(
        _ strokes: [KeyStroke], from start: Int, to layout: KeyboardLayout, current: KeyboardLayout
    ) -> [SuggestionPanel.Segment] {
        let textEnd = (strokes.lastIndex { !$0.isSpace } ?? -1) + 1
        return Self.rewrite(strokes, from: start, current: current) { range, typed, finished in
            let converted = Self.convert(strokes[range], from: current, to: layout, atEnd: range.upperBound == textEnd)
            // Judge by the result, not by what was typed: ";" or "[" are letters in Cyrillic layouts ("vj;tv" → "можем").
            guard LayoutDetector.core(of: converted) != nil else { return nil }
            switch verdict(strokes, range, current: current) {
            case .correct:
                // "Lf ytn" → "Да нет": valid as typed, but a word once converted too, next to a converted word.
                guard isAmbiguous(strokes, range, current: current, layout: layout),
                      hasConvertedNeighbour(strokes, range, from: start, current: current) else { return nil }
                return converted
            case .wrong:
                return converted
            case .unknown:
                guard finished else { return converted }
                // Valid nowhere. A typo in the current language stays as typed (the spelling row has it);
                // otherwise it is a typo made in the wrong layout. Either way no spelling fix here: on top of
                // a conversion it does more harm than good ("коммит" → "кормит").
                if spellingFix(typed, in: current) != nil, spellingFix(converted, in: layout) == nil { return nil }
                return converted
            }
        }
    }

    /// Whether the word before or after `range` (within the fragment) is one a layout row converts.
    private func hasConvertedNeighbour(_ strokes: [KeyStroke], _ range: Range<Int>, from start: Int, current: KeyboardLayout) -> Bool {
        func converts(_ neighbour: Range<Int>) -> Bool {
            guard !neighbour.isEmpty else { return false }
            if case .correct = verdict(strokes, neighbour, current: current) { return false }
            return true
        }
        if range.lowerBound - 1 > start {
            let end = range.lowerBound - 1
            if converts(max(start, Self.wordStart(strokes, before: end))..<end) { return true }
        }
        if range.upperBound + 1 < strokes.count {
            let next = range.upperBound + 1
            if converts(next..<(strokes[next...].firstIndex(where: \.isSpace) ?? strokes.count)) { return true }
        }
        return false
    }

    /// The fragment from `start` with finished misspelled words replaced by the spell checker's pick.
    /// Words typed in the wrong layout are left to the layout rows, and the word still being typed
    /// is left alone: half a word is always "misspelled".
    func spelling(_ strokes: [KeyStroke], from start: Int, current: KeyboardLayout) -> [SuggestionPanel.Segment] {
        Self.rewrite(strokes, from: start, current: current) { range, typed, finished in
            guard finished, case .unknown = verdict(strokes, range, current: current) else { return nil }
            return spellingFix(typed, in: current)
        }
    }

    /// The strokes rendered through `layout`. Punctuation is converted too, since that is where the other
    /// layout keeps it ("ghbdtn/" → "привет.", "Ghbdtn? rfr" → "Привет, как": Shift+/ is a comma on the
    /// Russian layout). The exception is "?" or "!" ending the text (`atEnd`): a question typed as such,
    /// not a comma at the very end ("tcnm?" → "есть?").
    static func convert(
        _ strokes: ArraySlice<KeyStroke>, from current: KeyboardLayout, to layout: KeyboardLayout, atEnd: Bool = false
    ) -> String {
        let typed = strokes.map { current.character(for: $0) }
        let converted = strokes.map { layout.character(for: $0) }
        // Where the trailing marks start: after the last stroke that is a letter in either layout.
        let tail = (typed.indices.last { typed[$0].first?.isLetter == true || converted[$0].first?.isLetter == true } ?? -1) + 1
        return typed.indices.map { index in
            let keep = atEnd && index >= tail && sentenceEnds.contains(typed[index]) && typed[index] != "."
            return keep ? typed[index] : converted[index]
        }.joined()
    }

    /// Splits the fragment from `start` into words and spaces. `replace` gets each word's range, its text
    /// in the current layout and whether a space follows it, and returns new text or nil to keep it.
    private static func rewrite(
        _ strokes: [KeyStroke], from start: Int, current: KeyboardLayout,
        _ replace: (_ range: Range<Int>, _ typed: String, _ finished: Bool) -> String?
    ) -> [SuggestionPanel.Segment] {
        var segments: [SuggestionPanel.Segment] = []
        func add(_ text: String, changed: Bool) {
            if let last = segments.last, last.changed == changed {
                segments[segments.count - 1] = .init(text: last.text + text, changed: changed)
            } else {
                segments.append(.init(text: text, changed: changed))
            }
        }

        var index = start
        while index < strokes.count {
            if strokes[index].isSpace {
                add(current.text(for: strokes[index...index]), changed: false)
                index += 1
                continue
            }
            let end = strokes[index...].firstIndex(where: \.isSpace) ?? strokes.count
            let typed = current.text(for: strokes[index..<end])
            if let new = replace(index..<end, typed, end < strokes.count), new != typed {
                add(new, changed: true)
            } else {
                add(typed, changed: false)
            }
            index = end
        }
        return segments
    }

    // MARK: - Text rules

    /// Start of the word that ends at `end` (exclusive): right after the previous space.
    static func wordStart(_ strokes: [KeyStroke], before end: Int) -> Int {
        strokes[..<end].lastIndex(where: \.isSpace).map { $0 + 1 } ?? 0
    }

    /// Index of the character to lowercase if `chars` (one per stroke) look like "ПРивет":
    /// the first two letters uppercase, then at least two more letters, all lowercase.
    static func stickyShiftIndex(_ chars: [String]) -> Int? {
        let letters = chars.indices.filter { chars[$0].first?.isLetter == true }
        guard letters.count >= 4 else { return nil }
        let upper = letters.map { chars[$0].first!.isUppercase }
        guard upper[0], upper[1], !upper[2...].contains(true) else { return nil }
        return letters[1]
    }

    /// Whether a word ending with this text is a sentence end: "!" and "?" always, "." unless it is
    /// "..." or follows an abbreviation or a number.
    static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        if last == "!" || last == "?" { return true }
        guard last == ".", !token.hasSuffix(".."), let core = LayoutDetector.core(of: token) else { return false }
        // `core` is nil for "т.е." or "5.", and a single letter is an initial or "т. д.".
        return core.count > 1 && !abbreviations.contains(core.lowercased())
    }

    /// For text after a sentence end: where the lowercase letter starting the next word is (in characters
    /// from the caret) and its capital. The word must follow spaces, may open with quotes or a bracket,
    /// and must have no capitals inside ("iPhone"). Nil when there is nothing to fix.
    static func capitalizationAhead(_ after: String) -> (offset: Int, letter: String)? {
        let spaces = after.prefix { $0 == " " }
        guard !spaces.isEmpty else { return nil }
        let word = after.dropFirst(spaces.count).prefix { !$0.isWhitespace }
        let openers = word.prefix { openingPunctuation.contains(String($0)) }
        guard let letter = word.dropFirst(openers.count).first, letter.isLetter, letter.isLowercase,
              LayoutDetector.core(of: String(word)) != nil,
              !word.dropFirst(openers.count + 1).contains(where: \.isUppercase) else { return nil }
        return (spaces.count + openers.count, letter.uppercased())
    }

    static let sentenceEnds: Set<String> = [".", "!", "?"]
    private static let openingPunctuation: Set<String> = ["\"", "«", "„", "“", "(", "‘"]
    /// Abbreviations that end with a dot but usually do not end the sentence (single letters and
    /// ones with a dot inside, like "т.е." or "e.g.", are recognised without the list).
    private static let abbreviations: Set<String> = [
        "др", "см", "стр", "рис", "табл", "ул", "пр", "пер", "д", "кв", "тел", "им", "гл", "св", "проф",
        "акад", "напр", "прим", "англ", "рус", "укр", "тыс", "млн", "млрд", "руб", "коп", "грн", "мин",
        "сек", "вв", "гг", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "cf", "no", "approx", "incl",
    ]
    /// The system spell checker accepts any single letter, so these are listed by hand.
    private static let oneLetterWords: [String: Set<Character>] = [
        "ru": Set("абвжикосуя"), "uk": Set("авєзійоуя"), "en": Set("ai"),
    ]
}
