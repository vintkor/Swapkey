import ApplicationServices
import CoreGraphics
import Foundation

/// Called on the event tap thread, not the main thread. Must return quickly and never wait for main:
/// every key press and click in the system is held until the callback returns.
protocol KeyboardMonitorDelegate: AnyObject {
    /// Return true to swallow the event.
    func keyboardMonitor(_ monitor: KeyboardMonitor, keyDown event: CGEvent) -> Bool
    func keyboardMonitorMouseDown(_ monitor: KeyboardMonitor)
}

/// Global CGEventTap on key and mouse presses. Requires Accessibility permission.
///
/// The tap runs on its own thread so that a busy main thread (spell checker, AX calls to a hung app)
/// cannot stall input for the whole system.
///
/// An active tap that outlives its Accessibility permission freezes keyboard and mouse system-wide
/// (only a reboot helps), so the owner must `stop()` it as soon as the permission is revoked.
final class KeyboardMonitor {
    weak var delegate: KeyboardMonitorDelegate?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }

        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "swapkey.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enabling without the permission is what freezes input; the owner will stop() us.
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Injector.marker { break }
            if delegate?.keyboardMonitor(self, keyDown: event) == true { return nil }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            delegate?.keyboardMonitorMouseDown(self)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
