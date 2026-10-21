import AppKit
import Combine
import DisplayKit
import DisplayMonkCore
import Foundation

/// UI state for every display. Owned and mutated on the main thread only; DDC traffic runs on a
/// background queue per display and publishes results back to the main thread.
final class DisplayStore: ObservableObject {
    static let shared = DisplayStore()

    @Published private(set) var displays: [DisplayState] = []
    private var lastRefresh = Date.distantPast

    private init() {}

    func reload() {
        SoftwareDimmer.reapply()
        displays = DisplayManager.shared.controllers().map(DisplayState.init)
        displays.forEach { $0.refresh() }
        lastRefresh = Date()
    }

    /// Re-reads values when the menu opens, at most every 10 seconds. There is no background
    /// polling: values only change from this app or from the monitor's own buttons.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > 10 else { return }
        displays.forEach { $0.refresh() }
        lastRefresh = Date()
    }

    /// Re-creates virtual HiDPI screens that were on when the app last quit.
    func restoreVirtualHiDPI() {
        for state in displays where Settings.bool(.virtualHiDPI, for: state.display) && !state.display.isVirtualHiDPI {
            state.enableVirtualHiDPI()
        }
    }

    func resumeWrites() {
        displays.forEach { $0.resumeWrites() }
    }

    /// The display under the mouse pointer, falling back to the main display.
    var displayUnderMouse: DisplayState? {
        let id = NSScreen.underMouse?.displayID
        return displays.first { $0.display.modeTarget == id } ?? displays.first { $0.display.isMain }
    }
}

/// Holds DDC traffic while displays sleep and shortly after they wake; some monitors hang if
/// they receive commands then.
final class DDCGate {
    static let shared = DDCGate()
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }
}

final class DisplayState: ObservableObject, Identifiable {
    let controller: DisplayController
    var display: Display { controller.display }
    var id: CGDirectDisplayID { display.id }
    /// Where modes are read and applied: the display, or its HiDPI virtual screen.
    var modeTarget: CGDirectDisplayID { display.modeTarget }
    var hasDDC: Bool { controller.ddc != nil }

    @Published private(set) var brightnessMethod: BrightnessMethod
    /// Backlight first, then software dimming to black, on one slider.
    @Published private(set) var combined: Bool
    @Published private(set) var brightness: Double = 1
    /// nil until read, and stays nil when the display doesn't support the control.
    @Published private(set) var contrast: Double?
    @Published private(set) var volume: Double?
    @Published private(set) var muted = false
    @Published private(set) var input: UInt16?
    @Published private(set) var modes: [ModeDescriptor] = []
    @Published private(set) var currentMode: ModeDescriptor?
    @Published private(set) var rotation = 0
    @Published private(set) var overrideStatus = OverrideStatus.notInstalled
    @Published private(set) var hasExtendedHiDPI = false
    @Published var isWorking = false

    let supportedMethods: [BrightnessMethod]
    private let queue: DispatchQueue
    private let pendingLock = NSLock()
    private var pending: [String: PendingWrite] = [:]
    private var throttles: [String: WriteThrottle<Double>] = [:]

    private struct PendingWrite {
        let value: Double
        let interval: Double
        let work: () -> Void
    }

    init(controller: DisplayController) {
        self.controller = controller
        queue = DispatchQueue(label: "DisplayMonk.display.\(controller.display.id)", qos: .userInitiated)
        var methods: [BrightnessMethod] = []
        if controller.hasNativeBrightness { methods.append(.native) }
        if controller.ddc != nil { methods.append(.ddc) }
        methods.append(.software)
        supportedMethods = methods
        let saved = Settings.string(.brightnessMethod, for: controller.display).flatMap(BrightnessMethod.init(rawValue:))
        brightnessMethod = saved.flatMap { methods.contains($0) ? $0 : nil } ?? controller.preferredBrightnessMethod
        combined = Settings.bool(.combined, for: controller.display, default: true)
    }

    var isCombined: Bool {
        combined && brightnessMethod != .software
    }

    // MARK: Reading

    func refresh() {
        refreshModes()
        refreshHiDPI()
        pendingLock.lock()
        for key in throttles.keys { throttles[key]?.reset() }
        pendingLock.unlock()

        let method = brightnessMethod
        let combined = isCombined
        let saved = Settings.double(.brightness, for: display)
        // Gamma tables don't survive a relaunch, so the saved software part is the truth.
        let software = method == .software ? (saved ?? 1) : combined ? CombinedBrightness.components(for: saved ?? 1).software : 1
        if software < 1 || method == .software {
            enqueue("brightness.software", value: software, interval: 0) { [id] in SoftwareDimmer.setLevel(software, for: id) }
        }
        if method == .software { brightness = software }
        guard !DDCGate.shared.isPaused else { return }

        queue.async { [controller] in
            let hardware = method == .software ? nil : controller.brightness(using: method)
            let ddc = controller.ddc != nil
            let contrast = ddc ? (try? controller.level(.contrast).get()) : nil
            let volume = ddc ? (try? controller.level(.volume).get()) : nil
            let muted = ddc ? controller.isMuted() : nil
            let input = ddc ? controller.inputSource() : nil
            DispatchQueue.main.async {
                if method != .software {
                    if let hardware {
                        self.brightness = combined ? CombinedBrightness.level(hardware: hardware, software: software) : hardware
                    } else if let saved {
                        self.brightness = saved
                    }
                }
                self.contrast = contrast
                self.volume = volume
                self.muted = muted ?? false
                self.input = input
            }
        }
    }

    func refreshModes() {
        modes = DisplayModes.available(for: modeTarget)
        currentMode = DisplayModes.current(for: modeTarget)
        rotation = DisplayRotation.current(for: modeTarget)
    }

    func refreshHiDPI() {
        guard !display.isBuiltIn else { return }
        overrideStatus = OverrideInstaller.status(for: display)
        hasExtendedHiDPI = OverrideInstaller.hasExtendedHiDPIModes(for: display)
    }

    // MARK: Derived values

    var brightnessTitle: String {
        isCombined ? "Brightness (Combined)" : "Brightness"
    }

    /// Badge text for the on-screen display, e.g. "40%" or "12% Min HW" once the backlight is
    /// at its minimum and the rest is software dimming.
    var brightnessDetail: String {
        let text = percentText(brightness)
        guard isCombined, CombinedBrightness.components(for: brightness).hardware == 0 else { return text }
        return "\(text) Min HW"
    }

    var volumeDetail: String {
        muted ? "Muted" : percentText(volume ?? 0)
    }

    var isHiDPIOn: Bool {
        display.isVirtualHiDPI || hasExtendedHiDPI
    }

    var hiDPIStatusText: String? {
        if display.isVirtualHiDPI { return "Using a virtual screen" }
        if overrideStatus == .installed, !hasExtendedHiDPI { return "Restart your Mac to finish" }
        return nil
    }

    /// One entry per distinct size and scaling, at the refresh rate closest to the current one.
    var resolutionChoices: [ModeDescriptor] {
        var seen = Set<String>()
        return modes.compactMap { mode in
            let key = "\(mode.sizeLabel)-\(mode.isHiDPI)"
            guard seen.insert(key).inserted else { return nil }
            let spec = ModeSpec(width: mode.width, height: mode.height, hiDPI: mode.isHiDPI)
            return ModeList.bestMatch(for: spec, in: modes, current: currentMode)
        }
    }

    /// Sizes for the resolution slider, smallest first: only HiDPI sizes once HiDPI is on.
    var sliderChoices: [ModeDescriptor] {
        let choices = resolutionChoices
        let hiDPI = choices.filter(\.isHiDPI)
        return (isHiDPIOn && hiDPI.count > 1 ? hiDPI : choices).sorted { $0.width < $1.width }
    }

    /// Refresh rates available at the current size and scaling.
    var refreshChoices: [ModeDescriptor] {
        guard let currentMode else { return [] }
        return modes.filter {
            $0.width == currentMode.width && $0.height == currentMode.height && $0.pixelWidth == currentMode.pixelWidth
        }
    }

    // MARK: Brightness and DDC values

    func setBrightnessMethod(_ method: BrightnessMethod) {
        guard method != brightnessMethod else { return }
        if brightnessMethod == .software || isCombined {
            enqueue("brightness.software", value: 1, interval: 0) { [id] in SoftwareDimmer.setLevel(1, for: id) }
        }
        brightnessMethod = method
        Settings.set(method.rawValue, .brightnessMethod, for: display)
        refresh()
    }

    func setCombined(_ value: Bool) {
        guard value != combined else { return }
        combined = value
        Settings.set(value, .combined, for: display)
        if !value {
            enqueue("brightness.software", value: 1, interval: 0) { [id] in SoftwareDimmer.setLevel(1, for: id) }
            setBrightness(max(brightness, CombinedBrightness.split))
        }
    }

    func setBrightness(_ value: Double) {
        let value = min(1, max(0, value))
        brightness = value
        Settings.set(value, .brightness, for: display)
        let method = brightnessMethod
        let interval = method == .ddc ? Self.ddcInterval : 0
        if isCombined {
            let parts = CombinedBrightness.components(for: value)
            enqueue("brightness.hardware", value: parts.hardware, interval: interval) { [controller] in
                controller.setBrightness(parts.hardware, using: method)
            }
            enqueue("brightness.software", value: parts.software, interval: 0) { [id] in
                SoftwareDimmer.setLevel(parts.software, for: id)
            }
        } else if method == .software {
            enqueue("brightness.software", value: value, interval: 0) { [id] in SoftwareDimmer.setLevel(value, for: id) }
        } else {
            enqueue("brightness.hardware", value: value, interval: interval) { [controller] in
                controller.setBrightness(value, using: method)
            }
        }
    }

    func setContrast(_ value: Double) {
        contrast = value
        enqueue("contrast", value: value, interval: Self.ddcInterval) { [controller] in controller.setLevel(.contrast, value) }
    }

    func setVolume(_ value: Double) {
        volume = value
        if muted, value > 0 { setMuted(false) }
        enqueue("volume", value: value, interval: Self.ddcInterval) { [controller] in controller.setLevel(.volume, value) }
    }

    func setMuted(_ value: Bool) {
        muted = value
        enqueue("mute", value: value ? 1 : 0, interval: Self.ddcInterval) { [controller] in controller.setMuted(value) }
    }

    func setInput(_ value: UInt16) {
        input = value
        enqueue("input", value: Double(value), interval: Self.ddcInterval) { [controller] in controller.setInputSource(value) }
    }

    // MARK: Modes

    /// Switches mode. Changes that can alter the signal sent to the monitor (refresh rate, or
    /// an unscaled size other than native) must be confirmed or they revert after 15 seconds.
    func apply(_ mode: ModeDescriptor) {
        let previous = currentMode
        let target = modeTarget
        do {
            try DisplayModes.apply(mode, to: target)
        } catch {
            NSLog("Display Monk: could not switch \(display.name) to \(mode): \(error)")
        }
        refreshModes()
        guard let previous, previous.id != mode.id, changesSignal(from: previous, to: mode) else { return }
        DispatchQueue.main.async {
            guard !ChangeConfirmation.ask("Keep this display setting?") else { return }
            try? DisplayModes.apply(previous, to: target)
            self.refreshModes()
        }
    }

    private func changesSignal(from old: ModeDescriptor, to new: ModeDescriptor) -> Bool {
        guard !display.isVirtualHiDPI else { return false }
        if old.refreshRate.rounded() != new.refreshRate.rounded() { return true }
        let native = OverrideInstaller.nativeSize(for: display)
        return !new.isHiDPI && (new.pixelWidth != native?.width || new.pixelHeight != native?.height)
    }

    func rotate(to degrees: Int) {
        let previous = rotation
        guard degrees != previous else { return }
        do {
            try DisplayRotation.set(degrees, for: modeTarget)
            rotation = degrees
        } catch {
            NSLog("Display Monk: could not rotate \(display.name): \(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !ChangeConfirmation.ask("Keep this rotation?") else { return }
            try? DisplayRotation.set(previous, for: self.modeTarget)
            self.rotation = previous
        }
    }

    // MARK: HiDPI

    func enableVirtualHiDPI() {
        let sizes = OverrideInstaller.presetSizes(for: display)
        let native = OverrideInstaller.nativeSize(for: display)
        let initial = native.flatMap { HiDPIOverride.defaultSize(in: sizes, nativeWidth: $0.width) }
        isWorking = true
        VirtualMirror.enable(for: display, sizes: sizes, initialSize: initial) { [weak self] result in
            guard let self else { return }
            isWorking = false
            switch result {
            case .success:
                Settings.set(true, .virtualHiDPI, for: display)
            case let .failure(error):
                Settings.set(false, .virtualHiDPI, for: display)
                Alerts.show("Could not create the HiDPI virtual screen", error.localizedDescription)
            }
        }
    }

    func disableVirtualHiDPI() {
        VirtualMirror.disable(for: id)
        Settings.set(false, .virtualHiDPI, for: display)
    }

    // MARK: Write queue

    private static let ddcInterval = 0.1

    /// Writes go through one serial queue per display. Only the newest value per control is
    /// kept, values the display already has are skipped, and DDC writes are spaced at least
    /// `ddcInterval` apart so slider drags don't flood the monitor's settings memory.
    private func enqueue(_ control: String, value: Double, interval: Double, _ work: @escaping () -> Void) {
        pendingLock.lock()
        let scheduled = pending[control] != nil
        pending[control] = PendingWrite(value: value, interval: interval, work: work)
        pendingLock.unlock()
        guard !scheduled else { return }
        queue.async { [weak self] in self?.flush(control) }
    }

    /// Runs on `queue`.
    private func flush(_ control: String) {
        // Left pending while displays sleep; `resumeWrites()` picks it up on wake.
        guard !DDCGate.shared.isPaused else { return }
        pendingLock.lock()
        guard let next = pending[control] else {
            pendingLock.unlock()
            return
        }
        var throttle = throttles[control] ?? WriteThrottle(minimumInterval: next.interval)
        let now = ProcessInfo.processInfo.systemUptime
        switch throttle.decision(for: next.value, now: now) {
        case .skip:
            pending[control] = nil
            pendingLock.unlock()
        case let .wait(delay):
            pendingLock.unlock()
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush(control) }
        case .send:
            pending[control] = nil
            throttle.recordSent(next.value, at: now)
            throttles[control] = throttle
            pendingLock.unlock()
            next.work()
        }
    }

    func resumeWrites() {
        pendingLock.lock()
        let controls = Array(pending.keys)
        pendingLock.unlock()
        for control in controls {
            queue.async { [weak self] in self?.flush(control) }
        }
    }
}

func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

/// Per-display values remembered across launches, keyed by `Display.persistentKey`.
enum Settings {
    enum Key: String {
        case brightness
        case brightnessMethod
        case combined
        case virtualHiDPI
    }

    private static func key(_ key: Key, _ display: Display) -> String {
        "display.\(display.persistentKey).\(key.rawValue)"
    }

    static func double(_ key: Key, for display: Display) -> Double? {
        UserDefaults.standard.object(forKey: self.key(key, display)) as? Double
    }

    static func string(_ key: Key, for display: Display) -> String? {
        UserDefaults.standard.string(forKey: self.key(key, display))
    }

    static func bool(_ key: Key, for display: Display, default defaultValue: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: self.key(key, display)) as? Bool ?? defaultValue
    }

    static func set(_ value: Any, _ key: Key, for display: Display) {
        UserDefaults.standard.set(value, forKey: self.key(key, display))
    }
}

/// App-wide preferences, also bound directly by the menu through `@AppStorage`.
enum Preferences {
    static let brightnessKeysKey = "brightnessKeysControlExternalDisplays"
    static let volumeKeysKey = "volumeKeysControlDisplaySpeakers"
    static let showOSDKey = "showOSD"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [brightnessKeysKey: false, volumeKeysKey: false, showOSDKey: true])
    }

    static var brightnessKeys: Bool { UserDefaults.standard.bool(forKey: brightnessKeysKey) }
    static var volumeKeys: Bool { UserDefaults.standard.bool(forKey: volumeKeysKey) }
    static var showOSD: Bool { UserDefaults.standard.bool(forKey: showOSDKey) }
}
