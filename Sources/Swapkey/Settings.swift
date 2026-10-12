import Foundation

/// User preferences, stored in UserDefaults (`defaults read local.swapkey`).
final class Settings {
    static let shared = Settings()

    static let panelTimeoutChoices: [TimeInterval] = [15, 30, 60]
    static let hideAfterCorrectWordsChoices = [2, 3, 5]

    private let defaults = UserDefaults.standard

    private enum Key {
        static let spellingEnabled = "spellingEnabled"
        static let fixStickyShift = "fixStickyShift"
        static let panelTimeout = "panelTimeout"
        static let hideAfterCorrectWords = "hideAfterCorrectWords"
        static let disabledLayoutIDs = "disabledLayoutIDs"
        static let excludedBundleIDs = "excludedBundleIDs"
    }

    private init() {
        migrateFromPunto()
        defaults.register(defaults: [
            Key.spellingEnabled: true,
            Key.fixStickyShift: true,
            Key.panelTimeout: 30.0,
            Key.hideAfterCorrectWords: 3,
        ])
    }

    /// The app used to be called Punto (bundle ID local.punto): carry its settings over once.
    private func migrateFromPunto() {
        let migrated = "migratedFromPunto"
        guard !defaults.bool(forKey: migrated) else { return }
        for (key, value) in defaults.persistentDomain(forName: "local.punto") ?? [:] {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migrated)
    }

    /// Offer spelling fixes (⌥0) and fix typos in words typed in the wrong layout.
    var spellingEnabled: Bool {
        get { defaults.bool(forKey: Key.spellingEnabled) }
        set { defaults.set(newValue, forKey: Key.spellingEnabled) }
    }

    /// Fix "ПРивет" → "Привет" right after the word is typed, without asking.
    var fixStickyShift: Bool {
        get { defaults.bool(forKey: Key.fixStickyShift) }
        set { defaults.set(newValue, forKey: Key.fixStickyShift) }
    }

    /// Idle time after which the panel hides; every key press while it is shown restarts the countdown.
    var panelTimeout: TimeInterval {
        get { defaults.double(forKey: Key.panelTimeout) }
        set { defaults.set(newValue, forKey: Key.panelTimeout) }
    }

    /// The panel gives up after this many correct words in a row: the user is typing fine and ignores it.
    var hideAfterCorrectWords: Int {
        get { defaults.integer(forKey: Key.hideAfterCorrectWords) }
        set { defaults.set(newValue, forKey: Key.hideAfterCorrectWords) }
    }

    /// Input source IDs that Swapkey neither suggests nor watches.
    var disabledLayoutIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledLayoutIDs) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.disabledLayoutIDs) }
    }

    /// Bundle IDs of apps where Swapkey stays quiet.
    var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excludedBundleIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.excludedBundleIDs) }
    }
}
