import AppKit
import ApplicationServices
import DisplayKit
import DisplayMonkCore

/// Intercepts the brightness and volume keys and applies them to the display under the mouse
/// pointer. Keys for displays macOS already controls (Apple displays, normal audio devices) are
/// passed through untouched.
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hasPrompted = false
    private var retryDelay: TimeInterval = 3
    private var retryWindowStart: Date?
    private var retryScheduled = false

    private init() {}

    func update() {
        let wanted = Preferences.brightnessKeys || Preferences.volumeKeys
        if wanted, tap == nil {
            start()
        } else if !wanted {
            stop()
        }
    }

    private func start() {
        guard isTrusted() else {
            scheduleRetry()
            return
        }
        retryDelay = 3
        retryWindowStart = nil
        // Volume and older brightness keys arrive as NX_SYSDEFINED events; current Apple
        // keyboards send brightness as ordinary key-down events (key codes 144 and 145).
        let events = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: mediaKeyCallback, userInfo: nil
        ) else {
            NSLog("Display Monk: could not create the media key event tap")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Access is granted in System Settings, so check again a few times with growing gaps,
    /// then stop until the menu is next opened (which calls `update()`).
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        let windowStart = retryWindowStart ?? Date()
        retryWindowStart = windowStart
        guard Date().timeIntervalSince(windowStart) < 300 else {
            retryWindowStart = nil
            retryDelay = 3
            return
        }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.retryScheduled = false
            self?.update()
        }
        retryDelay = min(retryDelay * 2, 30)
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Prompts for Accessibility access once per launch, then checks quietly.
    private func isTrusted() -> Bool {
        if hasPrompted { return AXIsProcessTrusted() }
        hasPrompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true when the key was handled and must not reach the system.
    fileprivate func handle(_ key: MediaKey, isDown: Bool, fine: Bool) -> Bool {
        guard let state = DisplayStore.shared.displayUnderMouse else { return false }
        switch key {
        case .brightnessUp, .brightnessDown:
            guard Preferences.brightnessKeys, state.brightnessMethod != .native else { return false }
            if isDown {
                state.setBrightness(LevelScale.step(state.brightness, up: key == .brightnessUp, fine: fine))
                showOSD(.brightness, detail: state.brightnessDetail, level: state.brightness, on: state)
            }
            return true
        case .volumeUp, .volumeDown:
            guard Preferences.volumeKeys, let volume = state.volume else { return false }
            if isDown {
                state.setVolume(LevelScale.step(volume, up: key == .volumeUp, fine: fine))
                showOSD(.volume, detail: state.volumeDetail, level: state.volume ?? 0, on: state)
            }
            return true
        case .mute:
            guard Preferences.volumeKeys, state.volume != nil else { return false }
            if isDown {
                state.setMuted(!state.muted)
                showOSD(state.muted ? .muted : .volume, detail: state.volumeDetail, level: state.volume ?? 0, on: state)
            }
            return true
        }
    }

    private func showOSD(_ kind: OSD.Kind, detail: String, level: Double, on state: DisplayState) {
        guard Preferences.showOSD else { return }
        OSD.shared.show(kind, title: state.display.name, detail: detail, level: level, on: state.display.screen)
    }
}

fileprivate enum MediaKey: Int {
    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7

    /// Key codes of the brightness keys on current Apple keyboards, which send them as key-down
    /// events rather than media-key events.
    init?(brightnessKeyCode: Int64) {
        switch brightnessKeyCode {
        case 144: self = .brightnessUp
        case 145: self = .brightnessDown
        default: return nil
        }
    }
}

/// Runs on the main thread: the tap's run loop source is added to the main run loop.
private func mediaKeyCallback(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MediaKeyTap.shared.reenable()
        return passThrough
    }
    let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
    if type == .keyDown {
        // Every other key returns straight away, so typing is unaffected.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = MediaKey(brightnessKeyCode: keyCode) else { return passThrough }
        return MediaKeyTap.shared.handle(key, isDown: true, fine: fine) ? nil : passThrough
    }
    // Media keys arrive as NX_SYSDEFINED events with subtype NX_SUBTYPE_AUX_CONTROL_BUTTONS (8).
    guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return passThrough
    }
    let data = nsEvent.data1
    guard let key = MediaKey(rawValue: (data & 0xFFFF_0000) >> 16) else { return passThrough }
    let isDown = (data & 0xFF00) >> 8 == 0x0A
    return MediaKeyTap.shared.handle(key, isDown: isDown, fine: fine) ? nil : passThrough
}
