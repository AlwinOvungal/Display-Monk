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
    @Published private(set) var sync = BrightnessSync(isEnabled: Preferences.syncBrightness)
    /// Every display's brightness, republished so views can tell whether synced displays match.
    @Published private(set) var brightnessLevels: [CGDirectDisplayID: Double] = [:]
    private var lastRefresh = Date.distantPast
    private var levelObservers: [AnyCancellable] = []
    private var followWork: DispatchWorkItem?

    private init() {}

    func reload() {
        SoftwareDimmer.reapply()
        VirtualMirror.pruneDisconnected()
        let previous = Set(displays.map(\.display.persistentKey))
        displays = DisplayManager.shared.controllers().map(DisplayState.init)
        observeLevels()
        // Displays that just connected (all of them at launch) join a running sync once their
        // brightness has been read. Displays that stayed connected get no writes here.
        let newcomers = displays.filter { !previous.contains($0.display.persistentKey) }
        let group = DispatchGroup()
        for state in displays {
            var onBrightness: ((Double) -> Void)?
            if newcomers.contains(where: { $0 === state }) {
                group.enter()
                onBrightness = { _ in group.leave() }
            }
            state.refresh(onBrightness: onBrightness)
        }
        if !newcomers.isEmpty {
            group.notify(queue: .main) { [weak self] in self?.syncNewcomers(newcomers) }
        }
        lastRefresh = Date()
        applyHiDPIPreferences()
    }

    /// Re-reads values when the menu opens, at most every 10 seconds. There is no background
    /// polling: values only change from this app or from the monitor's own buttons.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > 10 else { return }
        displays.forEach { $0.refresh() }
        lastRefresh = Date()
    }

    /// Displays already handled this session, so reconfigurations don't re-apply HiDPI.
    private var hiDPIHandled = Set<String>()

    /// HiDPI is on by default for external displays. Applied at launch and when a display is
    /// connected; turning the switch off is remembered per display.
    func applyHiDPIPreferences() {
        // Forget displays that were disconnected, so they get HiDPI again when reconnected.
        hiDPIHandled.formIntersection(displays.map(\.display.persistentKey))
        for state in displays where !state.display.isBuiltIn && !hiDPIHandled.contains(state.display.persistentKey) {
            hiDPIHandled.insert(state.display.persistentKey)
            let display = state.display
            // A virtual screen was active when the app last stopped without cleaning up (a
            // crash): put the display back to native first.
            if Settings.bool(.hiDPIRestorePending, for: display), !display.isVirtualHiDPI {
                VirtualMirror.reset(display.id)
                Settings.set(false, .hiDPIRestorePending, for: display)
            }
            guard Settings.bool(.hiDPIEnabled, for: display, default: true), !state.isHiDPIOn else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.state(for: display.id)?.enableHiDPI()
            }
        }
    }

    func state(for id: CGDirectDisplayID) -> DisplayState? {
        displays.first { $0.id == id }
    }

    /// Called when quitting, after virtual screens were removed cleanly.
    func clearHiDPIRestoreFlags() {
        for state in displays {
            Settings.set(false, .hiDPIRestorePending, for: state.display)
        }
    }

    /// The display other displays are placed relative to: the built-in one, else the main one.
    /// Re-reads every display's position right after a move, so the preview follows at once
    /// instead of waiting for the reconfiguration reload.
    func arrangementDidChange() {
        displays.forEach { $0.refreshFrame() }
        objectWillChange.send()
    }

    func arrangementReference(for state: DisplayState) -> DisplayState? {
        let others = displays.filter { $0.id != state.id }
        return others.first { $0.display.isBuiltIn } ?? others.first { $0.display.isMain } ?? others.first
    }

    func resumeWrites() {
        displays.forEach { $0.resumeWrites() }
    }

    /// The display under the mouse pointer, falling back to the main display.
    var displayUnderMouse: DisplayState? {
        let id = NSScreen.underMouse?.displayID
        return displays.first { $0.display.modeTarget == id } ?? displays.first { $0.display.isMain }
    }

    /// The display whose speakers macOS is playing through, when macOS can't set their volume
    /// itself. Nil for any other output (MacBook speakers, AirPods, USB), so the volume keys
    /// reach macOS.
    var volumeTarget: DisplayState? {
        guard let output = AudioOutput.current(), output.isDisplayAudio, !output.hasSystemVolume else { return nil }
        let candidates = displays.filter { $0.volume != nil }
        // macOS names HDMI and DisplayPort audio after the monitor, e.g. "LG HDR QHD".
        let outputName = output.name.lowercased()
        if !outputName.isEmpty, let match = candidates.first(where: {
            let name = $0.display.name.lowercased()
            return !name.isEmpty && (outputName.contains(name) || name.contains(outputName))
        }) {
            return match
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: Brightness sync

    var canSync: Bool { displays.count > 1 }
    var isSyncActive: Bool { sync.isEnabled && canSync }
    var isSyncMatched: Bool { BrightnessSync.isMatched(brightnessLevels.values) }

    /// Brightness changes a person makes, from the menu or the brightness keys. With sync on,
    /// the other displays follow. They are written directly, never through this method, so a
    /// change can't bounce back.
    func setBrightness(_ value: Double, for state: DisplayState) {
        state.setBrightness(value)
        guard isSyncActive else { return }
        apply(sync.follow(state.id, changedTo: value, levels: levels))
    }

    /// Turning sync on matches every display to the one under the pointer, where the menu bar
    /// was clicked. Turning it off changes nothing: each display keeps its current level.
    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != sync.isEnabled else { return }
        sync.isEnabled = enabled
        Preferences.syncBrightness = enabled
        if enabled { matchAll() }
    }

    /// Brings drifted displays back together, to the level of the display under the pointer.
    func matchAll() {
        guard isSyncActive, let reference = displayUnderMouse ?? displays.first else { return }
        apply(sync.match(levels: levels, to: reference.id))
    }

    /// macOS changes native displays (MacBook, Apple displays) itself when their brightness
    /// keys are pressed. Once the change has settled, the other displays follow whichever
    /// native display changed.
    func followSystemBrightnessChange() {
        guard isSyncActive else { return }
        followWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isSyncActive else { return }
            for state in displays where state.brightnessMethod == .native {
                let before = state.brightness
                state.readBrightness { [weak self, weak state] level in
                    guard let self, let state, isSyncActive, abs(level - before) > BrightnessSync.tolerance,
                          displays.contains(where: { $0 === state }) else { return }
                    apply(sync.follow(state.id, changedTo: level, levels: levels))
                }
            }
        }
        followWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private var levels: [CGDirectDisplayID: Double] {
        Dictionary(displays.map { ($0.id, $0.brightness) }, uniquingKeysWith: { first, _ in first })
    }

    private func apply(_ writes: [CGDirectDisplayID: Double]) {
        for (id, level) in writes {
            displays.first { $0.id == id }?.setBrightness(level)
        }
    }

    private func syncNewcomers(_ newcomers: [DisplayState]) {
        guard isSyncActive else { return }
        let connected = newcomers.filter { state in displays.contains { $0 === state } }
        guard !connected.isEmpty else { return }
        let newIDs = Set(connected.map(\.id))
        // Prefer a display that stayed connected; at launch, the one under the pointer.
        let pointer = displayUnderMouse
        let reference = pointer.flatMap { newIDs.contains($0.id) ? nil : $0 }
            ?? displays.first { !newIDs.contains($0.id) }
            ?? pointer
            ?? displays.first
        guard let reference else { return }
        apply(sync.matchNewcomers(newIDs, levels: levels, reference: reference.id))
    }

    private func observeLevels() {
        levelObservers = displays.map { state in
            state.$brightness.sink { [weak self] level in self?.brightnessLevels[state.id] = level }
        }
        brightnessLevels = levels
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
    /// Bounds in global display space, refreshed with the modes.
    @Published private(set) var frame = DisplayRect(x: 0, y: 0, width: 0, height: 0)

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

    /// Re-reads everything. `onBrightness` is called once on the main thread when the
    /// brightness is known (or, while displays sleep, with the current value).
    func refresh(onBrightness: ((Double) -> Void)? = nil) {
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
        if method == .software {
            brightness = software
            onBrightness?(software)
        }
        guard !DDCGate.shared.isPaused else {
            if method != .software { onBrightness?(brightness) }
            return
        }

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
                        self.brightness = Self.level(hardware: hardware, combined: combined, saved: saved)
                    } else if let saved {
                        self.brightness = saved
                    }
                    onBrightness?(self.brightness)
                }
                self.contrast = contrast
                self.volume = volume
                self.muted = muted ?? false
                self.input = input
            }
        }
    }

    /// Re-reads only the brightness, after macOS changed it (native displays' keys).
    func readBrightness(_ completion: @escaping (Double) -> Void) {
        let method = brightnessMethod
        guard method != .software, !DDCGate.shared.isPaused else {
            completion(brightness)
            return
        }
        let combined = isCombined
        let saved = Settings.double(.brightness, for: display)
        queue.async { [controller] in
            let hardware = controller.brightness(using: method)
            DispatchQueue.main.async {
                if let hardware {
                    self.brightness = Self.level(hardware: hardware, combined: combined, saved: saved)
                }
                completion(self.brightness)
            }
        }
    }

    /// The slider level for a backlight reading. In combined mode the saved software part is
    /// added back, since it can't be read from the display.
    private static func level(hardware: Double, combined: Bool, saved: Double?) -> Double {
        guard combined else { return hardware }
        return CombinedBrightness.level(hardware: hardware, software: CombinedBrightness.components(for: saved ?? 1).software)
    }

    func refreshModes() {
        modes = DisplayModes.available(for: modeTarget)
        currentMode = DisplayModes.current(for: modeTarget)
        rotation = DisplayRotation.current(for: modeTarget)
        refreshFrame()
    }

    func refreshFrame() {
        frame = DisplayArrangement.rect(of: display)
    }

    func refreshHiDPI() {
        guard !display.isBuiltIn else { return }
        overrideStatus = OverrideInstaller.status(for: display)
        hasExtendedHiDPI = OverrideInstaller.hasExtendedHiDPIModes(for: display)
    }

    // MARK: Derived values

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
        display.isVirtualHiDPI || currentMode?.isHiDPI == true
    }

    var hiDPIStatusText: String? {
        guard display.isVirtualHiDPI else { return nil }
        return overrideStatus == .installed
            ? "Virtual screen until your next restart, then permanent"
            : "Using a virtual screen while Display Monk runs"
    }

    /// The HiDPI size to use when HiDPI is turned on: the last one chosen, else the size that
    /// matches Apple's display density.
    var preferredHiDPISize: LogicalSize? {
        Settings.size(.hiDPISize, for: display) ?? defaultHiDPISize
    }

    var defaultHiDPISize: LogicalSize? {
        OverrideInstaller.defaultHiDPISize(for: display)
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

    /// HiDPI sizes for the resolution menu, largest first.
    var hiDPIChoices: [ModeDescriptor] {
        resolutionChoices.filter(\.isHiDPI)
    }

    /// The panel's own unscaled size.
    var nativeLoDPIChoice: ModeDescriptor? {
        let native = OverrideInstaller.nativeSize(for: display)
        return resolutionChoices.first { !$0.isHiDPI && $0.width == native?.width && $0.height == native?.height }
            ?? resolutionChoices.first { !$0.isHiDPI }
    }

    /// Every other unscaled size, for the "More" submenu.
    var otherLoDPIChoices: [ModeDescriptor] {
        let native = nativeLoDPIChoice
        return resolutionChoices.filter { !$0.isHiDPI && $0.id != native?.id }
    }

    func isDefaultHiDPI(_ mode: ModeDescriptor) -> Bool {
        guard mode.isHiDPI, let size = defaultHiDPISize else { return false }
        return ModeList.closestHiDPI(to: size, in: modes, current: currentMode)?.width == mode.width
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
        if mode.isHiDPI {
            Settings.set(LogicalSize(width: mode.width, height: mode.height), .hiDPISize, for: display)
        }
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

    /// Turns HiDPI on right away: natively when macOS already offers the HiDPI sizes (a
    /// permanent configuration is active), otherwise with a virtual screen. Never needs a restart.
    func enableHiDPI() {
        guard !VirtualMirror.isBusy(id) else { return }
        Settings.set(true, .hiDPIEnabled, for: display)
        if hasExtendedHiDPI {
            applyNativeHiDPI()
        } else {
            enableVirtualHiDPI()
        }
    }

    /// Turns HiDPI off right away and remembers that: removes the virtual screen, or switches
    /// to the native unscaled resolution.
    func disableHiDPI() {
        guard !VirtualMirror.isBusy(id) else { return }
        Settings.set(false, .hiDPIEnabled, for: display)
        if display.isVirtualHiDPI {
            disableVirtualHiDPI()
        } else if let native = nativeLoDPIChoice {
            apply(native)
        }
    }

    /// Escape hatch: no virtual screen, no mirroring, native unscaled resolution, HiDPI off.
    func resetDisplay() {
        Settings.set(false, .hiDPIEnabled, for: display)
        Settings.set(false, .hiDPIRestorePending, for: display)
        isWorking = true
        let displayID = id
        VirtualMirror.reset(displayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            DisplayStore.shared.state(for: displayID)?.transitionFinished()
        }
    }

    /// Clears the busy state on whichever object represents this display now; the display
    /// list is usually rebuilt during a transition.
    func transitionFinished() {
        isWorking = false
        refreshModes()
        refreshHiDPI()
    }

    /// Selects the preferred HiDPI size, or the closest one macOS offers.
    func applyNativeHiDPI() {
        refreshModes()
        guard let size = preferredHiDPISize, let mode = ModeList.closestHiDPI(to: size, in: modes, current: currentMode) else { return }
        apply(mode)
    }

    func enableVirtualHiDPI() {
        let display = self.display
        let sizes = OverrideInstaller.presetSizes(for: display)
        let initial = preferredHiDPISize
        isWorking = true
        Settings.set(true, .hiDPIRestorePending, for: display)
        VirtualMirror.enable(for: display, sizes: sizes, initialSize: initial) { result in
            if case let .failure(error) = result {
                Settings.set(false, .hiDPIRestorePending, for: display)
                Alerts.show("Could not create the HiDPI virtual screen", error.localizedDescription)
            }
            DisplayStore.shared.state(for: display.id)?.transitionFinished()
        }
    }

    func disableVirtualHiDPI() {
        let display = self.display
        isWorking = true
        VirtualMirror.disable(for: display.id) {
            Settings.set(false, .hiDPIRestorePending, for: display)
            DisplayStore.shared.state(for: display.id)?.transitionFinished()
        }
    }

    // MARK: Arrangement

    func placement(relativeTo reference: DisplayState) -> (Placement, PlacementAlignment)? {
        Arrangement.placement(of: frame, relativeTo: reference.frame)
    }

    func move(_ placement: Placement, _ alignment: PlacementAlignment, relativeTo reference: DisplayState) {
        do {
            try DisplayArrangement.move(display, placement, alignment, relativeTo: reference.display)
        } catch {
            NSLog("Display Monk: could not move \(display.name): \(error)")
        }
        refreshModes()
    }

    func makeMain(among displays: [DisplayState]) {
        do {
            try DisplayArrangement.makeMain(display, among: displays.map(\.display))
        } catch {
            NSLog("Display Monk: could not make \(display.name) the main display: \(error)")
        }
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
        case hiDPIEnabled
        case hiDPIRestorePending
        case hiDPISize
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

    static func size(_ key: Key, for display: Display) -> LogicalSize? {
        let parts = (string(key, for: display) ?? "").split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? LogicalSize(width: parts[0], height: parts[1]) : nil
    }

    static func set(_ value: LogicalSize, _ key: Key, for display: Display) {
        set(value.description, key, for: display)
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
    static let syncBrightnessKey = "syncBrightness"

    /// One-time clean-ups of settings written by earlier versions.
    static func migrate() {
        let defaults = UserDefaults.standard
        let version = defaults.integer(forKey: "settingsVersion")
        guard version < 3 else { return }
        if version < 2 {
            // HiDPI sizes picked while testing earlier builds would override the 1600x900 default.
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix("display.") && (key.hasSuffix(".hiDPISize") || key.hasSuffix(".virtualHiDPI")) {
                defaults.removeObject(forKey: key)
            }
        }
        // Every section starts closed; from here on, sections stay as the user leaves them.
        defaults.removeObject(forKey: "expandedDisplays")
        defaults.removeObject(forKey: "arrangementExpanded")
        defaults.set(3, forKey: "settingsVersion")
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [brightnessKeysKey: false, volumeKeysKey: false, showOSDKey: true, syncBrightnessKey: false])
    }

    static var brightnessKeys: Bool { UserDefaults.standard.bool(forKey: brightnessKeysKey) }
    static var volumeKeys: Bool { UserDefaults.standard.bool(forKey: volumeKeysKey) }
    static var showOSD: Bool { UserDefaults.standard.bool(forKey: showOSDKey) }

    static var syncBrightness: Bool {
        get { UserDefaults.standard.bool(forKey: syncBrightnessKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncBrightnessKey) }
    }
}
