import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = SwitchController()
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startWhenTrusted()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.make()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatus()
    }

    /// Starts the tap once Accessibility is granted and stops it the moment it is revoked:
    /// an active tap without the permission freezes all input in the system.
    private func startWhenTrusted() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { _ = controller.start() }
        updateStatus()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted, !self.controller.isRunning {
                _ = self.controller.start()
            } else if !trusted, self.controller.isRunning {
                NSLog("Swapkey: Accessibility revoked, stopping the event tap")
                self.controller.stop()
            } else {
                return
            }
            self.updateStatus()
        }
    }

    private func updateStatus() {
        statusItem.button?.appearsDisabled = !controller.isRunning || !controller.isEnabled
    }

    // MARK: - Menu

    /// Rebuilt on every open, so layouts, the frontmost app and the login item state are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = !controller.isRunning ? "Нужен доступ в Универсальном доступе"
            : controller.isEnabled ? "Работает" : "На паузе"
        menu.addItem(disabled(status))
        menu.addItem(item(controller.isEnabled ? "Пауза" : "Продолжить", #selector(toggleEnabled)))
        menu.addItem(.separator())

        menu.addItem(item("Проверять орфографию", #selector(toggleSpelling), checked: settings.spellingEnabled))
        menu.addItem(item("Исправлять залипший Shift (ПРивет → Привет)", #selector(toggleStickyShift),
                          checked: settings.fixStickyShift))
        menu.addItem(item("Заглавная буква в начале предложения", #selector(toggleCapitalizeSentences),
                          checked: settings.capitalizeSentences))
        menu.addItem(submenu("Показывать подсказку", Settings.panelTimeoutChoices.map { seconds in
            item("\(Int(seconds)) с без нажатий", #selector(setPanelTimeout(_:)),
                 checked: settings.panelTimeout == seconds, value: seconds)
        }))
        menu.addItem(submenu("Скрывать после правильных слов", Settings.hideAfterCorrectWordsChoices.map { count in
            item("\(count) подряд", #selector(setHideAfterCorrectWords(_:)),
                 checked: settings.hideAfterCorrectWords == count, value: count)
        }))
        menu.addItem(.separator())

        menu.addItem(submenu("Раскладки", layoutItems()))
        menu.addItem(submenu("Исключения", exclusionItems()))
        menu.addItem(.separator())

        menu.addItem(item("Открывать при входе в систему", #selector(toggleLaunchAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Настройки Универсального доступа…", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        menu.addItem(item("О программе Swapkey \(Self.version)…", #selector(showAbout)))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func layoutItems() -> [NSMenuItem] {
        let switchedOff = settings.disabledLayoutIDs
        var items = controller.layouts.enumerated().map { index, layout in
            // The digit is the hotkey: it comes from the order in System Settings and never changes.
            let hotkey = index < 9 ? "\(SwitchController.hotkeyPrefix)\(index + 1)  " : ""
            return item(hotkey + layout.name, #selector(toggleLayout(_:)),
                        checked: !switchedOff.contains(layout.id), value: layout.id)
        }
        items.append(.separator())
        items.append(disabled("Выключенные не предлагаются и не проверяются"))
        return items
    }

    private func exclusionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let excluded = settings.excludedBundleIDs
        // The status menu does not activate Swapkey, so the frontmost app is still the one the user typed in.
        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier, !excluded.contains(bundleID) {
            items.append(item("Не работать в «\(app.localizedName ?? bundleID)»", #selector(toggleExclusion(_:)),
                              value: bundleID))
        }
        if !excluded.isEmpty {
            if !items.isEmpty { items.append(.separator()) }
            items.append(disabled("Не работает в (нажмите, чтобы вернуть):"))
            for bundleID in excluded {
                items.append(item(Self.appName(bundleID), #selector(toggleExclusion(_:)), checked: true, value: bundleID))
            }
        }
        if items.isEmpty { items.append(disabled("Нет исключений")) }
        return items
    }

    /// "1.2.0 (34)" from Info.plist, which build.sh fills from the git tag and commit count.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.representedObject = value
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        controller.isEnabled.toggle()
        updateStatus()
    }

    @objc private func toggleSpelling() {
        settings.spellingEnabled.toggle()
        controller.settingsChanged()
    }

    @objc private func toggleStickyShift() {
        settings.fixStickyShift.toggle()
    }

    @objc private func toggleCapitalizeSentences() {
        settings.capitalizeSentences.toggle()
    }

    @objc private func setPanelTimeout(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        settings.panelTimeout = seconds
    }

    @objc private func setHideAfterCorrectWords(_ sender: NSMenuItem) {
        guard let count = sender.representedObject as? Int else { return }
        settings.hideAfterCorrectWords = count
    }

    @objc private func toggleLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.disabledLayoutIDs.formSymmetricDifference([id])
        controller.settingsChanged()
    }

    @objc private func toggleExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if let index = settings.excludedBundleIDs.firstIndex(of: bundleID) {
            settings.excludedBundleIDs.remove(at: index)
        } else {
            settings.excludedBundleIDs.append(bundleID)
        }
        controller.settingsChanged()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Swapkey: login item: \(error)")
        }
        // macOS may want the user to confirm it in System Settings → General → Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Исправляет слова, набранные не в той раскладке.\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "github.com/vintkor/Swapkey",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .link: URL(string: "https://github.com/vintkor/Swapkey")!]))
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        // A menu-bar app is never active on its own, so the panel would open behind the frontmost window.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
