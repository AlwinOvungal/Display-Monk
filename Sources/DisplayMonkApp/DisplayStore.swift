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

    private init() {}

    func reload() {
        SoftwareDimmer.reapply()
        displays = DisplayManager.shared.controllers().map(DisplayState.init)
        displays.forEach { $0.refresh() }
    }

    /// The display under the mouse pointer, falling back to the main display.
    var displayUnderMouse: DisplayState? {
        let id = NSScreen.underMouse?.displayID
        return displays.first { $0.id == id } ?? displays.first { $0.display.isMain }
    }
}

final class DisplayState: ObservableObject, Identifiable {
    let controller: DisplayController
    var display: Display { controller.display }
    var id: CGDirectDisplayID { display.id }
    var hasDDC: Bool { controller.ddc != nil }

    @Published private(set) var brightnessMethod: BrightnessMethod
    @Published private(set) var brightness: Double = 1
    /// nil until read, and stays nil when the display doesn't support the control.
    @Published private(set) var contrast: Double?
    @Published private(set) var volume: Double?
    @Published private(set) var muted = false
    @Published private(set) var input: UInt16?
    @Published private(set) var modes: [ModeDescriptor] = []
    @Published private(set) var currentMode: ModeDescriptor?
    @Published private(set) var rotation = 0

    let supportedMethods: [BrightnessMethod]
    private let queue: DispatchQueue
    private let pendingLock = NSLock()
    private var pendingWrites: [String: () -> Void] = [:]

    init(controller: DisplayController) {
        self.controller = controller
        queue = DispatchQueue(label: "DisplayMonk.ddc.\(controller.display.id)", qos: .userInitiated)
        var methods: [BrightnessMethod] = []
        if controller.hasNativeBrightness { methods.append(.native) }
        if controller.ddc != nil { methods.append(.ddc) }
        methods.append(.software)
        supportedMethods = methods
        let saved = Settings.string(.brightnessMethod, for: controller.display).flatMap(BrightnessMethod.init(rawValue:))
        brightnessMethod = saved.flatMap { methods.contains($0) ? $0 : nil } ?? controller.preferredBrightnessMethod
    }

    // MARK: Reading

    func refresh() {
        refreshModes()
        let method = brightnessMethod
        let display = display
        let saved = Settings.double(.brightness, for: display)
        if method == .software {
            // Gamma tables don't survive a relaunch, so the saved level is the truth.
            setBrightness(saved ?? 1)
        }
        queue.async { [controller] in
            let brightness = method == .software ? nil : controller.brightness(using: method)
            let ddc = controller.ddc != nil
            let contrast = ddc ? (try? controller.level(.contrast).get()) : nil
            let volume = ddc ? (try? controller.level(.volume).get()) : nil
            let muted = ddc ? controller.isMuted() : nil
            let input = ddc ? controller.inputSource() : nil
            DispatchQueue.main.async {
                if let value = brightness ?? (method == .software ? nil : saved) { self.brightness = value }
                self.contrast = contrast
                self.volume = volume
                self.muted = muted ?? false
                self.input = input
            }
        }
    }

    func refreshModes() {
        modes = DisplayModes.available(for: id)
        currentMode = DisplayModes.current(for: id)
        rotation = DisplayRotation.current(for: id)
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

    /// Refresh rates available at the current size and scaling.
    var refreshChoices: [ModeDescriptor] {
        guard let currentMode else { return [] }
        return modes.filter {
            $0.width == currentMode.width && $0.height == currentMode.height && $0.pixelWidth == currentMode.pixelWidth
        }
    }

    // MARK: Writing

    func setBrightnessMethod(_ method: BrightnessMethod) {
        guard method != brightnessMethod else { return }
        if brightnessMethod == .software {
            enqueue("dim") { [id] in SoftwareDimmer.setLevel(1, for: id) }
        }
        brightnessMethod = method
        Settings.set(method.rawValue, .brightnessMethod, for: display)
        refresh()
    }

    func setBrightness(_ value: Double) {
        let floor = brightnessMethod == .software ? SoftwareDimmer.minimumLevel : 0
        let value = min(1, max(floor, value))
        brightness = value
        Settings.set(value, .brightness, for: display)
        let method = brightnessMethod
        enqueue("brightness") { [controller] in controller.setBrightness(value, using: method) }
    }

    func setContrast(_ value: Double) {
        contrast = value
        enqueue("contrast") { [controller] in controller.setLevel(.contrast, value) }
    }

    func setVolume(_ value: Double) {
        volume = value
        if muted, value > 0 { setMuted(false) }
        enqueue("volume") { [controller] in controller.setLevel(.volume, value) }
    }

    func setMuted(_ value: Bool) {
        muted = value
        enqueue("mute") { [controller] in controller.setMuted(value) }
    }

    func setInput(_ value: UInt16) {
        input = value
        enqueue("input") { [controller] in controller.setInputSource(value) }
    }

    func apply(_ mode: ModeDescriptor) {
        do {
            try DisplayModes.apply(mode, to: id)
        } catch {
            NSLog("Display Monk: could not switch \(display.name) to \(mode): \(error)")
        }
        refreshModes()
    }

    func rotate(to degrees: Int) {
        do {
            try DisplayRotation.set(degrees, for: id)
            rotation = degrees
        } catch {
            NSLog("Display Monk: could not rotate \(display.name): \(error)")
        }
    }

    /// Slider drags produce far more values than a display can take over DDC. Only the newest
    /// value per control is kept while an earlier write is still in flight.
    private func enqueue(_ control: String, _ work: @escaping () -> Void) {
        pendingLock.lock()
        let scheduled = pendingWrites[control] != nil
        pendingWrites[control] = work
        pendingLock.unlock()
        guard !scheduled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            pendingLock.lock()
            let latest = pendingWrites.removeValue(forKey: control)
            pendingLock.unlock()
            latest?()
        }
    }
}

/// Per-display values remembered across launches, keyed by `Display.persistentKey`.
enum Settings {
    enum Key: String {
        case brightness
        case brightnessMethod
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
