import AppKit

struct Candidate {
    let layout: KeyboardLayout
    /// Whole typed fragment as it would look in this layout.
    let word: String
}

enum Verdict {
    /// The word is valid in the current layout's language.
    case correct
    /// The word is not valid in the current layout, but is valid in these layouts.
    case wrong([Candidate])
    /// Not enough information to decide (too short, no dictionary, etc.).
    case unknown
}

/// Decides whether a typed word belongs to a different layout, using the system spell checker.
final class LayoutDetector {
    static let minWordLength = 2

    private let spellChecker = NSSpellChecker.shared
    private lazy var availableLanguages = Set(spellChecker.availableLanguages)

    func analyze(_ strokes: [KeyStroke], current: KeyboardLayout, layouts: [KeyboardLayout]) -> Verdict {
        let currentText = current.text(for: strokes)
        let currentCore = Self.core(of: currentText)

        if let core = currentCore {
            guard core.count >= Self.minWordLength, let lang = spellLanguage(for: current) else { return .unknown }
            if isWord(core, language: lang) { return .correct }
        }

        var candidates: [Candidate] = []
        var seenLanguages = Set<String>()
        for layout in layouts where layout.id != current.id {
            guard let lang = spellLanguage(for: layout), !seenLanguages.contains(lang) else { continue }
            let text = layout.text(for: strokes)
            // Same characters in both layouts: switching would change nothing for this word.
            guard text != currentText, let core = Self.core(of: text), core.count >= Self.minWordLength else { continue }
            if isWord(core, language: lang) {
                seenLanguages.insert(lang)
                candidates.append(Candidate(layout: layout, word: core))
            }
        }
        return candidates.isEmpty ? .unknown : .wrong(candidates)
    }

    /// Whether `text` (without surrounding punctuation) is a word in the language of `layout`.
    /// False when there is no dictionary for it.
    func isWord(_ text: String, in layout: KeyboardLayout) -> Bool {
        guard let core = Self.core(of: text), let lang = spellLanguage(for: layout) else { return false }
        return isWord(core, language: lang)
    }

    /// Best spelling fix for `text` in the language of `layout`, keeping the punctuation around the word.
    /// Nil if the word is valid, too short, has no dictionary, or the spell checker has nothing to offer.
    func spellingFix(for text: String, in layout: KeyboardLayout) -> String? {
        guard let core = Self.core(of: text), core.count >= Self.minWordLength,
              let lang = spellLanguage(for: layout), !isWord(core, language: lang),
              let range = text.range(of: core) else { return nil }
        let nsRange = NSRange(location: 0, length: (core as NSString).length)
        // `correction` is the autocorrect pick; when it has none, the first guess is usually still sensible.
        let fix = spellChecker.correction(forWordRange: nsRange, in: core, language: lang, inSpellDocumentWithTag: 0)
            ?? spellChecker.guesses(forWordRange: nsRange, in: core, language: lang, inSpellDocumentWithTag: 0)?.first
        guard let fix, fix != core else { return nil }
        return text.replacingCharacters(in: range, with: fix)
    }

    /// Strips leading/trailing punctuation. Returns nil if the rest is not made of letters
    /// (apostrophes and hyphens are allowed inside a word).
    static func core(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'’-"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    private func spellLanguage(for layout: KeyboardLayout) -> String? {
        guard let lang = layout.language else { return nil }
        if availableLanguages.contains(lang) { return lang }
        let base = String(lang.prefix { $0 != "_" && $0 != "-" })
        if availableLanguages.contains(base) { return base }
        return availableLanguages.sorted().first { $0.hasPrefix(base + "_") }
    }

    private func isWord(_ word: String, language: String) -> Bool {
        let range = spellChecker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }
}
