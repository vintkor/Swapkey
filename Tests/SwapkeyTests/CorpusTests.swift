import Testing
@testable import Swapkey

/// Whole sentences typed word by word, as SwitchController sees them. Results depend on the system
/// spell checker, so the thresholds leave some room; the printed report shows what changed.
@Suite(.enabled(if: Layouts.available), .serialized)
struct CorpusTests {
    let english = Layouts.english!
    let russian = Layouts.russian!
    let ukrainian = Layouts.ukrainian!

    private func analyzer() -> BufferAnalyzer {
        let analyzer = BufferAnalyzer()
        analyzer.layouts = Layouts.all
        return analyzer
    }

    // MARK: - Correct text must stay quiet

    @Test(arguments: [("ru", "Russian"), ("uk", "Ukrainian"), ("en", "English")])
    func correctTextGetsNoLayoutOffers(corpus: String, layoutName: String) throws {
        let layout = try #require(Layouts.all.first { $0.language == corpus })
        let analyzer = analyzer()
        var layoutOffers: [String] = []
        var spellingOffers: [String] = []
        let lines = Corpus.lines(corpus)
        for line in lines {
            guard let session = Session(line, typedOn: layout, current: layout, analyzer: analyzer) else { continue }
            layoutOffers += session.layoutOffers
            spellingOffers += session.spellingOffers
        }
        print("[\(layoutName)] \(lines.count) lines; layout offers: \(layoutOffers); spelling offers: \(spellingOffers)")
        // A wrong layout offer on correct text is the worst mistake: it asks to break what is right.
        #expect(layoutOffers.isEmpty, "layout offered for correct \(layoutName) words: \(layoutOffers)")
        // Dictionary gaps ("раскладку") show up as typos; keep an eye on their number.
        #expect(spellingOffers.count <= lines.count / 4, "too many spelling offers: \(spellingOffers)")
    }

    // MARK: - Text typed in the wrong layout must come back

    @Test(arguments: [
        ("ru", "en"), // Russian typed with ABC on
        ("en", "ru"), // English typed with Russian on
        ("uk", "en"), // Ukrainian typed with ABC on
        ("uk", "ru"), // Ukrainian typed with Russian on
    ])
    func wrongLayoutTextIsRestored(corpus: String, typedWith: String) throws {
        let intended = try #require(Layouts.all.first { $0.language == corpus })
        let current = try #require(Layouts.all.first { $0.language == typedWith })
        let analyzer = analyzer()
        var total = 0
        var missed: [String] = []
        var garbled: [(String, String)] = []
        for line in Corpus.lines(corpus) {
            guard let session = Session(line, typedOn: intended, current: current, analyzer: analyzer) else { continue }
            // Typed on the intended layout's keys, but the current layout shows the same text: nothing to detect.
            if current.text(for: session.strokes).trimmingCharacters(in: .whitespaces) == line { continue }
            total += 1
            guard session.candidates.contains(where: { $0.layout.id == intended.id }) else {
                missed.append(current.text(for: session.strokes))
                continue
            }
            let result = session.picked(intended)
            if result != line { garbled.append((line, result)) }
        }
        let restored = total - missed.count - garbled.count
        print("[\(corpus) typed with \(typedWith)] \(restored)/\(total) restored; missed: \(missed); garbled: \(garbled)")
        // Ukrainian typed on the Russian layout differs in a few letters only ("мені" → "мены", a Russian
        // word too), so some of it is legitimately missed.
        let required = typedWith == "ru" && corpus == "uk" ? 0.75 : 0.95
        #expect(Double(restored) >= Double(total) * required)
    }

    // MARK: - Known cases

    @Test func siblingLayoutIsNotOfferedInRussianText() throws {
        let session = try #require(Session("сейчас посмотрю кейсы", typedOn: russian, current: russian, analyzer: analyzer()))
        #expect(session.layoutOffers.isEmpty)
    }

    @Test func shortFirstWordIsConverted() throws {
        let session = try #require(Session("А тесты есть?", typedOn: russian, current: english, analyzer: analyzer()))
        #expect(session.picked(russian) == "А тесты есть?")
    }
}
