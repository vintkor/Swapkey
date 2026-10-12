import Testing
@testable import Swapkey

struct SentenceRulesTests {
    @Test(arguments: [
        ("привет.", true), ("Да!", true), ("что?!", true), ("(навсегда).", true),
        ("т.е.", false), ("т.", false), ("см.", false), ("Mr.", false), ("e.g.", false), ("5.", false),
        ("ну...", false), ("так…", false), ("привет,", false), ("\"Да.\"", false), ("", false),
    ])
    func endsSentence(token: String, expected: Bool) {
        #expect(BufferAnalyzer.endsSentence(token) == expected)
    }

    @Test func capitalizesTheNextWord() {
        #expect(BufferAnalyzer.capitalizationAhead(" как дела")! == (1, "К"))
        #expect(BufferAnalyzer.capitalizationAhead("  как")! == (2, "К"))
        #expect(BufferAnalyzer.capitalizationAhead(" «как» дела")! == (2, "К"))
        #expect(BufferAnalyzer.capitalizationAhead(" я")! == (1, "Я"))
    }

    @Test(arguments: [" Как дела", " iPhone вышел", "как дела", "", " 5 раз", "\nкак", " config.json"])
    func leavesTheNextWord(after: String) {
        #expect(BufferAnalyzer.capitalizationAhead(after) == nil)
    }
}

struct StickyShiftTests {
    private func index(_ word: String) -> Int? {
        BufferAnalyzer.stickyShiftIndex(word.map(String.init))
    }

    @Test func findsTheSecondCapital() {
        #expect(index("ПРивет") == 1)
        #expect(index("HEllo") == 1)
        #expect(index("«ПРивет") == 2)
    }

    @Test func leavesOtherWords() {
        #expect(index("Привет") == nil)
        #expect(index("ПРИВЕТ") == nil)
        #expect(index("IDs") == nil)
        #expect(index("MHz") == nil)
        #expect(index("iPhone") == nil)
    }
}

struct WordCoreTests {
    @Test func stripsPunctuation() {
        #expect(LayoutDetector.core(of: "«привет»,") == "привет")
        #expect(LayoutDetector.core(of: "из-за") == "из-за")
        #expect(LayoutDetector.core(of: "don't") == "don't")
    }

    @Test func rejectsNonWords() {
        #expect(LayoutDetector.core(of: "5") == nil)
        #expect(LayoutDetector.core(of: "т.е") == nil)
        #expect(LayoutDetector.core(of: "n/t") == nil)
        #expect(LayoutDetector.core(of: "—") == nil)
    }

    @Test func dictionaryForm() {
        #expect(Settings.dictionaryForm("Кейсы") == "кейсы")
        #expect(Settings.dictionaryForm("кейсы") == "кейсы")
        #expect(Settings.dictionaryForm("iPhone") == "iPhone")
        #expect(Settings.dictionaryForm("GitHub") == "GitHub")
    }
}

@Suite(.enabled(if: Layouts.available))
struct ConversionTests {
    let english = Layouts.english!
    let russian = Layouts.russian!
    let ukrainian = Layouts.ukrainian!

    private func convert(_ text: String, typedOn: KeyboardLayout, to layout: KeyboardLayout, atEnd: Bool = false) -> String {
        let strokes = Typist.strokes(text, on: typedOn)!
        return BufferAnalyzer.convert(strokes[...], from: typedOn, to: layout, atEnd: atEnd)
    }

    @Test func convertsPunctuationByKey() {
        // Shift+/ is a comma on the Russian layout, Shift+7 a question mark.
        #expect(convert("Ghbdtn?", typedOn: english, to: russian) == "Привет,")
        #expect(convert("ltkf&", typedOn: english, to: russian) == "дела?")
    }

    @Test func keepsQuestionMarkEndingTheText() {
        #expect(convert("tcnm?", typedOn: english, to: russian, atEnd: true) == "есть?")
        #expect(convert("ghbdtn!", typedOn: english, to: russian, atEnd: true) == "привет!")
    }

    @Test func convertsOtherSymbols() {
        // On the Russian layout "." is on the "/" key.
        #expect(convert("ghbdtn/", typedOn: english, to: russian) == "привет.")
        // ";" and "," are letters on Cyrillic layouts.
        #expect(convert("vj;tv", typedOn: english, to: russian) == "можем")
        #expect(convert(",eltn", typedOn: english, to: russian) == "будет")
    }

    @Test func siblingLayouts() {
        let word = Typist.strokes("кейсы", on: russian)![...]
        #expect(BufferAnalyzer.isSibling(ukrainian, of: russian, for: word))
        #expect(!BufferAnalyzer.isSibling(english, of: russian, for: word))
    }

    @Test func includesOneLetterWordsBeforeTheFirstWrongOne() {
        let analyzer = BufferAnalyzer()
        let strokes = Typist.strokes("F ntcns ", on: english)!
        #expect(analyzer.fragmentStart(strokes, before: 2, current: english) == 0)
    }

    @Test func stopsAtRealOneLetterWords() {
        let analyzer = BufferAnalyzer()
        // "a" and "I" are English words; "я" and "и" Russian ones.
        #expect(analyzer.fragmentStart(Typist.strokes("a ntcns ", on: english)!, before: 2, current: english) == 2)
        #expect(analyzer.fragmentStart(Typist.strokes("я руддщ ", on: russian)!, before: 2, current: russian) == 2)
    }
}
