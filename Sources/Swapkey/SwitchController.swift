import AppKit
import Carbon

/// Tracks typed key strokes, detects wrong-layout words and applies the user's choice.
///
/// The buffer holds every printable stroke (including spaces) since the last reset. Anything that
/// moves the caret or may have changed text out of our sight (mouse click, arrows, Return, shortcuts)
/// resets it, because then we no longer know what is in front of the caret.
final class SwitchController: KeyboardMonitorDelegate {
    /// Hotkey: ⌥ + digit picks a suggestion while the panel is visible.
    static let hotkeyModifier: CGEventFlags = .maskAlternate
    static let hotkeyPrefix = "⌥"
    static let spellingDigit = 0
    static let maxBufferLength = 300

    /// Indexed by digit. ⌥1…⌥9 pick layouts, ⌥0 picks the spelling fix.
    private static let digitKeyCodes: [Int] = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    private static let resetKeyCodes: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ]

    var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }

    private let monitor = KeyboardMonitor()
    private let detector = LayoutDetector()
    private let panel = SuggestionPanel()

    /// All layouts enabled in System Settings, in their order there (which defines the hotkey digits).
    private(set) var layouts: [KeyboardLayout] = []
    /// The ones Swapkey works with: `layouts` minus those switched off in its menu.
    private var activeLayouts: [KeyboardLayout] = []
    private let settings = Settings.shared
    /// The frontmost app is in the exclusion list.
    private var isExcludedApp = false
    private var currentLayout: KeyboardLayout?

    private var strokes: [KeyStroke] = []
    /// Strokes at the end of the buffer erased with Backspace while the panel is up. They stay in the
    /// buffer so that a pick still brings back the whole corrected phrase; typing anything else drops them.
    private var erased = 0
    /// Bumped on every reset so that late async analysis results are dropped.
    private var generation = 0
    /// Buffer index where the first wrong word starts; everything from here is retyped on selection.
    private var anchor: Int?
    private var candidates: [Candidate] = []
    /// Correct words in a row since the last wrong one, while the panel is up.
    private var correctStreak = 0
    /// Spell checker verdicts by the word's text in the current layout (which is fixed until a reset).
    private var verdicts: [String: Verdict] = [:]
    /// Spelling fixes by layout and text; nil values (nothing to fix) are cached too.
    private var fixes: [String: String?] = [:]
    private var hideTimer: Timer?

    /// Digits (0…9) selectable by hotkey right now, empty when the panel is hidden.
    /// The only state read from the event tap thread.
    private var hotkeyDigits: Set<Int> {
        get { tapLock.withLock { _hotkeyDigits } }
        set { tapLock.withLock { _hotkeyDigits = newValue } }
    }
    private var _hotkeyDigits: Set<Int> = []
    /// Key presses already passed to the app by the event tap but not yet seen by `keyDown` on main.
    /// Text may only be rewritten automatically when this is 0, or the deletes would miss those keys.
    private var _pendingKeys = 0
    /// Guards the state shared with the event tap thread.
    private let tapLock = NSLock()
    private let caretQueue = DispatchQueue(label: "swapkey.caret")

    init() {
        monitor.delegate = self
        reloadLayouts()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, queue: .main) { [weak self] _ in
            self?.currentLayout = InputSources.currentLayout()
            self?.reset()
        }
        center.addObserver(forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, queue: .main) { [weak self] _ in
            self?.reloadLayouts()
        }
        // Another app means another text field: the buffer no longer matches what is in front of the caret.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.settingsChanged()
        }
    }

    /// Re-reads everything that depends on Settings. Call after changing them.
    func settingsChanged() {
        let disabled = settings.disabledLayoutIDs
        activeLayouts = layouts.filter { !disabled.contains($0.id) }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        isExcludedApp = bundleID.map(settings.excludedBundleIDs.contains) ?? false
        reset()
    }

    var isRunning: Bool { monitor.isRunning }

    func start() -> Bool { monitor.start() }

    func stop() {
        monitor.stop()
        reset()
    }

    // MARK: - KeyboardMonitorDelegate (event tap thread)

    func keyboardMonitor(_ monitor: KeyboardMonitor, keyDown event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let commandLike = flags.intersection([.maskCommand, .maskControl, .maskAlternate])

        if commandLike == Self.hotkeyModifier,
           let digit = Self.digitKeyCodes.firstIndex(of: keyCode), hotkeyDigits.contains(digit) {
            DispatchQueue.main.async { self.apply(digit: digit) }
            return true
        }
        tapLock.withLock { _pendingKeys += 1 }
        DispatchQueue.main.async { self.keyDown(keyCode: keyCode, flags: flags) }
        return false
    }

    func keyboardMonitorMouseDown(_ monitor: KeyboardMonitor) {
        DispatchQueue.main.async { self.reset() }
    }

    // MARK: - Typing (main thread)

    private func keyDown(keyCode: Int, flags: CGEventFlags) {
        tapLock.withLock { _pendingKeys -= 1 }
        guard isEnabled, !isExcludedApp, let currentLayout,
              activeLayouts.contains(where: { $0.id == currentLayout.id }) else { return }
        if anchor != nil { restartHideTimer() }
        let commandLike = flags.intersection([.maskCommand, .maskControl, .maskAlternate])

        if !commandLike.isEmpty || Self.resetKeyCodes.contains(keyCode) {
            return reset()
        }

        if keyCode == kVK_Delete {
            if anchor != nil {
                // Noticing the wrong layout, people erase by reflex: keep the offer alive.
                erased = min(erased + 1, strokes.count)
            } else if strokes.isEmpty {
                reset()
            } else {
                strokes.removeLast()
            }
            return
        }

        let stroke = KeyStroke(
            keyCode: UInt16(keyCode),
            shift: flags.contains(.maskShift),
            capsLock: flags.contains(.maskAlphaShift)
        )
        guard Self.isPrintable(currentLayout.character(for: stroke)), strokes.count < Self.maxBufferLength else {
            return reset()
        }

        dropErased()
        strokes.append(stroke)
        if stroke.isSpace { wordFinished() }
        refreshPanel()
        let character = currentLayout.character(for: stroke)
        if settings.capitalizeSentences, Self.sentenceEnds.contains(character) {
            capitalizeAhead(after: character, generation: generation, count: strokes.count)
        }
    }

    // MARK: - Detection

    private func wordFinished() {
        // The word is everything between the previous space and the one just typed.
        let end = strokes.count - 1
        let start = strokes[..<end].lastIndex(where: \.isSpace).map { $0 + 1 } ?? 0
        guard start < end, let current = currentLayout else { return }

        let generation = self.generation
        // Let the key press finish first; the spell checker may take a while on first use.
        DispatchQueue.main.async { self.analyzeWord(start..<end, generation: generation, current: current) }
    }

    private func analyzeWord(_ range: Range<Int>, generation: Int, current: KeyboardLayout) {
        guard generation == self.generation, range.upperBound < strokes.count, current === currentLayout else { return }
        if settings.fixStickyShift || settings.capitalizeSentences, erased == 0 {
            // Keys typed after the space may already be in the app: wait until we have seen them all.
            if tapLock.withLock({ _pendingKeys }) > 0 {
                DispatchQueue.main.async { self.analyzeWord(range, generation: generation, current: current) }
                return
            }
            autoFix(range, current: current)
        }

        switch verdict(for: range) {
        case .correct:
            guard anchor != nil else { return }
            correctStreak += 1
            if correctStreak >= settings.hideAfterCorrectWords { hidePanel() }
        case .wrong(let candidates):
            offerLayouts(candidates, from: range.lowerBound)
        case .unknown:
            // Valid nowhere: a typo in the current language, or a typo made in the wrong layout.
            let word = strokes[range]
            if spellingFix(current.text(for: word), in: current) != nil {
                correctStreak = 0
                offer(from: range.lowerBound)
                return
            }
            let candidates = activeLayouts.compactMap { layout -> Candidate? in
                guard layout.id != current.id, let fix = spellingFix(layout.text(for: word), in: layout) else {
                    return nil
                }
                return Candidate(layout: layout, word: fix)
            }
            if !candidates.isEmpty { offerLayouts(candidates, from: range.lowerBound) }
        }
    }

    /// The rewrites applied without asking, right after a word is typed: sticky Shift and sentence
    /// capitalization. Rewrites the text in place once, from the first changed stroke, and updates
    /// the buffer to match.
    private func autoFix(_ range: Range<Int>, current: KeyboardLayout) {
        var fixed = strokes
        if settings.fixStickyShift { fixStickyShift(&fixed, range, current: current) }
        if settings.capitalizeSentences { capitalizeSentence(&fixed, range, current: current) }
        guard let first = fixed.indices.first(where: { fixed[$0] != strokes[$0] }) else { return }

        // Everything from the first changed letter on, including whatever was typed after the word.
        let deleteCount = strokes.count - first
        strokes = fixed
        verdicts.removeAll()
        Injector.replace(deleteCount: deleteCount, with: current.text(for: strokes[first...]))
        refreshPanel()
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
        let previousStart = strokes[..<(range.lowerBound - 1)].lastIndex(where: \.isSpace).map { $0 + 1 } ?? 0
        let previousRange = previousStart..<(range.lowerBound - 1)
        guard !previousRange.isEmpty, Self.endsSentence(current.text(for: strokes[previousRange])) else { return }
        // A "." typed in the wrong layout is a letter there ("ю" on the Russian layout).
        if case .wrong = verdict(for: previousRange) { return }

        let chars = strokes[range].map { current.character(for: $0) }
        guard let offset = chars.firstIndex(where: { $0.first?.isLetter == true }),
              chars[offset] != chars[offset].uppercased(),
              !chars[(offset + 1)...].contains(where: { $0 != $0.lowercased() }),
              LayoutDetector.core(of: chars.joined()) != nil else { return }
        // Only opening quotes and brackets before the letter, and nothing that is a letter in another
        // layout: in a wrong-layout word "[" or "'" is the first letter ("х", "э").
        for index in range.lowerBound..<(range.lowerBound + offset) {
            guard Self.openingPunctuation.contains(chars[index - range.lowerBound]),
                  !activeLayouts.contains(where: { $0.character(for: strokes[index]).first?.isLetter == true }) else {
                return
            }
        }
        let index = range.lowerBound + offset
        strokes[index] = KeyStroke(keyCode: strokes[index].keyCode, shift: true, capsLock: false)
    }

    /// "привет| как дела" + "." → "привет. Как дела": a sentence end typed in the middle of text
    /// capitalizes the word after it. The buffer knows nothing past the caret, so the text comes from
    /// Accessibility. Retried a few times: the app may not have inserted `mark` yet when AX is asked.
    private func capitalizeAhead(after mark: String, generation: Int, count: Int, attempt: Int = 0) {
        guard attempt < 4, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        caretQueue.asyncAfter(deadline: .now() + 0.03 * Double(attempt + 1)) {
            let text = CaretLocator.surroundingText(pid: pid)
            DispatchQueue.main.async {
                // Anything typed since then may be in front of the word, or have moved the caret.
                guard generation == self.generation, count == self.strokes.count, self.erased == 0,
                      let text, self.tapLock.withLock({ self._pendingKeys }) == 0 else { return }
                guard text.before.hasSuffix(mark) else {
                    return self.capitalizeAhead(after: mark, generation: generation, count: count, attempt: attempt + 1)
                }
                let previous = text.before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                guard Self.endsSentence(previous), let fix = Self.capitalizationAhead(text.after) else { return }
                Injector.replaceAhead(offset: fix.offset, length: 1, with: fix.letter)
            }
        }
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

    private static let sentenceEnds: Set<String> = [".", "!", "?"]
    private static let openingPunctuation: Set<String> = ["\"", "«", "„", "“", "(", "‘"]
    /// Abbreviations that end with a dot but usually do not end the sentence (single letters and
    /// ones with a dot inside, like "т.е." or "e.g.", are recognised without the list).
    private static let abbreviations: Set<String> = [
        "др", "см", "стр", "рис", "табл", "ул", "пр", "пер", "д", "кв", "тел", "им", "гл", "св", "проф",
        "акад", "напр", "прим", "англ", "рус", "укр", "тыс", "млн", "млрд", "руб", "коп", "грн", "мин",
        "сек", "вв", "гг", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "cf", "no", "approx", "incl",
    ]

    /// Whether a word ending with this text is a sentence end: "!" and "?" always, "." unless it is
    /// "..." or follows an abbreviation or a number.
    static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        if last == "!" || last == "?" { return true }
        guard last == ".", !token.hasSuffix(".."), let core = LayoutDetector.core(of: token) else { return false }
        // `core` is nil for "т.е." or "5.", and a single letter is an initial or "т. д.".
        return core.count > 1 && !abbreviations.contains(core.lowercased())
    }

    private func offerLayouts(_ candidates: [Candidate], from start: Int) {
        correctStreak = 0
        if self.candidates.isEmpty {
            // Listed in the order of System Settings, which is also where their hotkey digits come from.
            self.candidates = candidates.sorted { digit(for: $0.layout) ?? .max < digit(for: $1.layout) ?? .max }
        }
        offer(from: start)
    }

    /// Shows the panel starting at the word at `start`, or refreshes it if it is already up.
    private func offer(from start: Int) {
        if anchor == nil {
            anchor = start
            showPanel()
        } else {
            refreshPanel()
        }
    }

    /// The single switch for everything spelling-related: with it off, nothing gets fixed.
    private func spellingFix(_ text: String, in layout: KeyboardLayout) -> String? {
        guard settings.spellingEnabled else { return nil }
        let key = layout.id + "\u{1}" + text
        if let cached = fixes[key] { return cached }
        let fix = detector.spellingFix(for: text, in: layout)
        fixes[key] = fix
        return fix
    }

    private func verdict(for range: Range<Int>) -> Verdict {
        guard let current = currentLayout else { return .unknown }
        let word = Array(strokes[range])
        let key = current.text(for: word)
        if let cached = verdicts[key] { return cached }
        let verdict = detector.analyze(word, current: current, layouts: activeLayouts)
        verdicts[key] = verdict
        return verdict
    }

    /// The fragment from `start` with every word that is not valid in the current layout
    /// re-rendered through `layout` (and spell-fixed there once finished). Correct words, spaces and
    /// tokens that would not become a word in `layout` (numbers, dashes) stay as typed.
    private func correction(to layout: KeyboardLayout, from start: Int) -> [SuggestionPanel.Segment] {
        rewrite(from: start) { range, typed, finished in
            let verdict = verdict(for: range)
            if case .correct = verdict { return nil }
            let converted = layout.text(for: strokes[range])
            // Judge by the result, not by what was typed: ";" or "[" are letters in Cyrillic layouts ("vj;tv" → "можем").
            guard LayoutDetector.core(of: converted) != nil else { return nil }
            guard finished else { return converted }
            if case .wrong = verdict { return converted }
            // Valid nowhere: a typo made in the wrong layout, or a typo in the current language.
            if let fix = spellingFix(converted, in: layout) { return fix }
            if let current = currentLayout, spellingFix(typed, in: current) != nil { return nil }
            return converted
        }
    }

    /// The fragment from `start` with finished misspelled words replaced by the spell checker's pick.
    /// Words typed in the wrong layout are left to the layout rows, and the word still being typed
    /// is left alone: half a word is always "misspelled".
    private func spelling(from start: Int) -> [SuggestionPanel.Segment] {
        guard let current = currentLayout else { return [] }
        return rewrite(from: start) { range, typed, finished in
            guard finished, case .unknown = verdict(for: range) else { return nil }
            return spellingFix(typed, in: current)
        }
    }

    /// Splits the fragment from `start` into words and spaces. `replace` gets each word's range, its text
    /// in the current layout and whether a space follows it, and returns new text or nil to keep it.
    private func rewrite(
        from start: Int, _ replace: (_ range: Range<Int>, _ typed: String, _ finished: Bool) -> String?
    ) -> [SuggestionPanel.Segment] {
        guard let current = currentLayout else { return [] }
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

    /// Hotkey digit of a layout: its position among the enabled layouts in System Settings, so that
    /// each layout keeps the same key whatever the other suggestions are.
    private func digit(for layout: KeyboardLayout) -> Int? {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }), index + 1 < Self.digitKeyCodes.count else {
            return nil
        }
        return index + 1
    }

    private func apply(digit: Int) {
        guard let anchor, anchor < strokes.count, let current = currentLayout else { return reset() }
        let layout = candidates.first { self.digit(for: $0.layout) == digit }?.layout
        guard digit == Self.spellingDigit || layout != nil else { return reset() }
        let segments = layout.map { correction(to: $0, from: anchor) } ?? spelling(from: anchor)
        // What is still on screen; if the user erased past the anchor, the correct text before it comes back too.
        let visible = strokes.count - erased
        let start = min(anchor, visible)
        let text = current.text(for: strokes[start..<anchor]) + segments.map(\.text).joined()
        let deleteCount = visible - start
        // Keep the current layout if the phrase ends with a correct word: the user is typing in it now.
        let endsChanged = segments.last { !$0.text.allSatisfy(\.isWhitespace) }?.changed ?? true

        reset()
        if endsChanged, let layout { InputSources.select(layout) }
        Injector.replace(deleteCount: deleteCount, with: text)
    }

    // MARK: - State

    private func reset() {
        generation += 1
        strokes.removeAll()
        erased = 0
        verdicts.removeAll()
        fixes.removeAll()
        hidePanel()
    }

    private func showPanel() {
        let generation = self.generation
        hotkeyDigits = Set(panelRows().compactMap(\.hotkey))
        // AX calls can block on a busy app, keep them off the main thread.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screens = NSScreen.screens.map(\.frame)
        caretQueue.async {
            let caret = pid.flatMap { CaretLocator.locate(pid: $0, screens: screens) }
            DispatchQueue.main.async {
                guard generation == self.generation, self.anchor != nil else { return }
                // Built here, not before the AX lookup: the user may have typed more meanwhile.
                let rows = self.panelRows()
                self.hotkeyDigits = Set(rows.compactMap(\.hotkey))
                self.panel.show(rows, title: self.panelTitle, hotkeyPrefix: Self.hotkeyPrefix, caret: caret)
            }
        }
        restartHideTimer()
    }

    /// The panel shows exactly what a pick would type, so it follows the typing.
    private func refreshPanel() {
        guard anchor != nil, panel.isVisible else { return }
        let rows = panelRows()
        // E.g. the typo that opened the panel was erased and is being retyped.
        guard !rows.isEmpty else { return hidePanel() }
        hotkeyDigits = Set(rows.compactMap(\.hotkey))
        panel.update(rows, title: panelTitle)
    }

    private var panelTitle: String {
        candidates.isEmpty ? "Похоже, опечатка" : "Похоже, не та раскладка"
    }

    /// One row per layout candidate, plus the spelling row if the fragment has typos.
    private func panelRows() -> [SuggestionPanel.Row] {
        guard let anchor, anchor < strokes.count else { return [] }
        var rows = candidates.map {
            SuggestionPanel.Row(
                hotkey: digit(for: $0.layout), segments: correction(to: $0.layout, from: anchor), layoutName: $0.layout.name
            )
        }
        let spelling = spelling(from: anchor)
        if spelling.contains(where: \.changed) {
            rows.append(SuggestionPanel.Row(hotkey: Self.spellingDigit, segments: spelling, layoutName: "Орфография"))
        }
        return rows
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: settings.panelTimeout, repeats: false) { [weak self] _ in
            self?.hidePanel()
        }
    }

    /// Forgets the erased strokes: from now on the buffer must match the screen again.
    private func dropErased() {
        guard erased > 0 else { return }
        strokes.removeLast(erased)
        erased = 0
        if let anchor, anchor >= strokes.count { hidePanel() } else { refreshPanel() }
    }

    private func hidePanel() {
        if erased > 0 {
            strokes.removeLast(erased)
            erased = 0
        }
        anchor = nil
        candidates = []
        correctStreak = 0
        hotkeyDigits = []
        hideTimer?.invalidate()
        hideTimer = nil
        if panel.isVisible { panel.hide() }
    }

    private func reloadLayouts() {
        layouts = InputSources.enabledLayouts()
        currentLayout = InputSources.currentLayout()
        settingsChanged()
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

    private static func isPrintable(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
