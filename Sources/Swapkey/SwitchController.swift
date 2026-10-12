import AppKit
import Carbon

/// Tracks typed key strokes, detects wrong-layout words and applies the user's choice.
///
/// The buffer holds every printable stroke (including spaces) since the last reset. Anything that
/// moves the caret or may have changed text out of our sight (mouse click, arrows, Return, shortcuts)
/// resets it, because then we no longer know what is in front of the caret.
final class SwitchController: KeyboardMonitorDelegate {
    /// Hotkey: ⌘ + digit picks a suggestion while the panel is visible (and only then: otherwise ⌘1…⌘9
    /// stay with the app, e.g. browser tabs).
    static let hotkeyModifier: CGEventFlags = .maskCommand
    static let hotkeyPrefix = "⌘"
    static let spellingDigit = 0
    static let maxBufferLength = 300

    /// Indexed by digit. ⌘1…⌘9 pick layouts, ⌘0 picks the spelling fix.
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
    private let analyzer = BufferAnalyzer()
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
            self?.syncCurrentLayout()
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
        analyzer.layouts = activeLayouts
        analyzer.spellingEnabled = settings.spellingEnabled
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
        // The change notification may come after the first keys typed in the new layout: without this
        // they would be judged in the old one, and the late reset would cut the word in half.
        syncCurrentLayout()
        guard isEnabled, !isExcludedApp, let currentLayout,
              activeLayouts.contains(where: { $0.id == currentLayout.id }) else { return }
        if anchor != nil { restartHideTimer() }
        let commandLike = flags.intersection([.maskCommand, .maskControl, .maskAlternate])

        if !commandLike.isEmpty || Self.resetKeyCodes.contains(keyCode) {
            // Esc dismisses the panel, Return sends the text as it is: either way the words were fine.
            if keyCode == kVK_Escape || keyCode == kVK_Return { learnIgnoredWords() }
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
        if settings.capitalizeSentences, BufferAnalyzer.sentenceEnds.contains(character) {
            capitalizeAhead(generation: generation, count: strokes.count)
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
        // Backspace may have changed the buffer since the space was typed.
        guard generation == self.generation, range.upperBound < strokes.count, strokes[range.upperBound].isSpace,
              current === currentLayout else { return }
        if settings.fixStickyShift || settings.capitalizeSentences, erased == 0 {
            // Keys typed after the space may already be in the app: wait until we have seen them all.
            if tapLock.withLock({ _pendingKeys }) > 0 {
                DispatchQueue.main.async { self.analyzeWord(range, generation: generation, current: current) }
                return
            }
            autoFix(range, current: current)
        }

        switch analyzer.decide(strokes, range, current: current) {
        case .correct:
            guard anchor != nil else { return }
            correctStreak += 1
            if correctStreak >= settings.hideAfterCorrectWords {
                learnIgnoredWords()
                hidePanel()
            }
        case .layouts(let candidates):
            offerLayouts(candidates, from: range.lowerBound)
        case .spelling:
            correctStreak = 0
            offer(from: range.lowerBound)
        case .none:
            break
        }
    }

    /// The rewrites applied without asking, right after a word is typed: sticky Shift and sentence
    /// capitalization. Rewrites the text in place once, from the first changed stroke, and updates
    /// the buffer to match.
    private func autoFix(_ range: Range<Int>, current: KeyboardLayout) {
        let fixed = analyzer.autoFixed(strokes, range, current: current, stickyShift: settings.fixStickyShift,
                                       capitalize: settings.capitalizeSentences)
        guard let first = fixed.indices.first(where: { fixed[$0] != strokes[$0] }) else { return }

        // Everything from the first changed letter on, including whatever was typed after the word.
        let deleteCount = strokes.count - first
        strokes = fixed
        analyzer.reset()
        Injector.replace(deleteCount: deleteCount, with: current.text(for: strokes[first...]))
        refreshPanel()
    }

    /// "привет| как дела" + "." → "привет. Как дела": a sentence end typed in the middle of text
    /// capitalizes the word after it. The buffer knows nothing past the caret, so the text comes from
    /// Accessibility. Retried a few times: the app may not have inserted the mark yet when AX is asked.
    private func capitalizeAhead(generation: Int, count: Int, attempt: Int = 0) {
        guard attempt < 4, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        caretQueue.asyncAfter(deadline: .now() + 0.03 * Double(attempt + 1)) {
            let text = CaretLocator.surroundingText(pid: pid)
            DispatchQueue.main.async {
                // Anything typed since then may be in front of the word, or have moved the caret.
                guard generation == self.generation, count == self.strokes.count, self.erased == 0,
                      let current = self.currentLayout, let text,
                      self.tapLock.withLock({ self._pendingKeys }) == 0 else { return }
                // What we saw typed must be right before the caret, or AX reports a different place
                // (apps differ wildly here) and the arrows would edit the wrong text.
                let typed = current.text(for: self.strokes.suffix(16))
                guard text.before.hasSuffix(typed) else {
                    return self.capitalizeAhead(generation: generation, count: count, attempt: attempt + 1)
                }
                let previous = text.before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                guard BufferAnalyzer.endsSentence(previous), let fix = BufferAnalyzer.capitalizationAhead(text.after) else {
                    return
                }
                Injector.replaceAhead(offset: fix.offset, length: 1, with: fix.letter)
            }
        }
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
            anchor = currentLayout.map { analyzer.fragmentStart(strokes, before: start, current: $0) } ?? start
            showPanel()
        } else {
            refreshPanel()
        }
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
        let segments = layout.map { analyzer.correction(strokes, from: anchor, to: $0, current: current) }
            ?? analyzer.spelling(strokes, from: anchor, current: current)
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

    /// The panel goes away without a pick: words flagged only because the dictionary lacks them get a
    /// mark, and after `Settings.learnAfterIgnores` marks they go to the system dictionary, so neither
    /// Swapkey nor other apps flag them again ("раскладку", "кейсы").
    private func learnIgnoredWords() {
        guard settings.learnWords, let anchor, erased == 0, let current = currentLayout else { return }
        let words = Set(analyzer.learnableWords(strokes, from: anchor, current: current).map(Settings.dictionaryForm))
        guard !words.isEmpty else { return }
        var ignored = settings.ignoredWords
        var learned = settings.learnedWords
        for word in words {
            let count = (ignored[word] ?? 0) + 1
            if count >= Settings.learnAfterIgnores {
                NSSpellChecker.shared.learnWord(word)
                ignored[word] = nil
                if !learned.contains(word) { learned.append(word) }
                NSLog("Swapkey: learned \"\(word)\"")
            } else {
                ignored[word] = count
            }
        }
        settings.ignoredWords = ignored
        settings.learnedWords = learned
        analyzer.reset()
    }

    /// Takes a word back out of the system dictionary.
    func unlearn(_ word: String) {
        NSSpellChecker.shared.unlearnWord(word)
        settings.learnedWords.removeAll { $0 == word }
        analyzer.reset()
    }

    // MARK: - State

    private func reset() {
        generation += 1
        strokes.removeAll()
        erased = 0
        analyzer.reset()
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
        guard let anchor, anchor < strokes.count, let current = currentLayout else { return [] }
        var rows = candidates.map {
            SuggestionPanel.Row(
                hotkey: digit(for: $0.layout), segments: analyzer.correction(strokes, from: anchor, to: $0.layout, current: current),
                layoutName: $0.layout.name
            )
        }
        let spelling = analyzer.spelling(strokes, from: anchor, current: current)
        if spelling.contains(where: \.changed) {
            rows.append(SuggestionPanel.Row(hotkey: Self.spellingDigit, segments: spelling, layoutName: "Орфография"))
        }
        return rows
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard settings.panelTimeout > 0 else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: settings.panelTimeout, repeats: false) { [weak self] _ in
            self?.learnIgnoredWords()
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

    /// Picks up a change of the input source; the buffer was typed in the old one, so it goes.
    private func syncCurrentLayout() {
        guard InputSources.currentLayoutID() != currentLayout?.id else { return }
        currentLayout = InputSources.currentLayout()
        reset()
    }

    private func reloadLayouts() {
        layouts = InputSources.enabledLayouts()
        currentLayout = InputSources.currentLayout()
        settingsChanged()
    }

    private static func isPrintable(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
