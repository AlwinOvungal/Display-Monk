import AppKit
import ApplicationServices
import DisplayKit
import DisplayMonkCore
import SwiftUI

/// The menu bar popover: a compact header, brightness for every display (with Sync
/// Brightness), each display's other settings behind a disclosure row, and a quiet footer.
struct MenuView: View {
    @ObservedObject var store: DisplayStore
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Preferences.brightnessKeysKey) private var brightnessKeys = false
    @AppStorage(Preferences.volumeKeysKey) private var volumeKeys = false
    @AppStorage(Preferences.showOSDKey) private var showOSD = true
    @AppStorage(Preferences.autoUpdateCheckKey) private var autoUpdateCheck = true
    /// `Display.persistentKey`s of the display rows that are open, comma-separated.
    @AppStorage("expandedDisplays") private var expandedDisplays = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.displays.isEmpty {
                emptyState
            } else {
                BrightnessPanel(store: store)
                displayList
                if store.displays.count > 1 {
                    ArrangementSection(store: store)
                }
            }
            if brightnessKeys || volumeKeys, !accessibilityTrusted {
                accessibilityWarning
            }
            if updater.status != .idle {
                UpdateBanner(updater: updater)
                    .transition(.opacity)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .tint(.monkSaffron)
        .background {
            // A light tint over the blur keeps the panel translucent without washing out over
            // bright windows behind it, so secondary text stays readable.
            ZStack {
                VisualEffectBackground()
                Color(nsColor: .windowBackgroundColor).opacity(0.45)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onReceive(NotificationCenter.default.publisher(for: .menuWillShow)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onAppear {
            store.refreshIfStale()
            MediaKeyTap.shared.update()
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Display Monk").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    StatusDot(color: store.displays.isEmpty ? .secondary : .green)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    if case .available = updater.status {
                        Text("· Update available").font(.caption).foregroundStyle(Color.monkSaffron)
                    }
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch store.displays.count {
        case 0: "No displays found"
        case 1: "1 display connected"
        case let count: "\(count) displays connected"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display").font(.title2).foregroundStyle(.secondary)
            Text("No displays found").font(.callout.weight(.medium))
            Text("Connect a display, then refresh.").font(.caption).foregroundStyle(.secondary)
            Button("Refresh") { store.reload() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .monkPanel(padding: 16)
    }

    // MARK: Displays

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Displays")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 2) {
                ForEach(store.displays) { state in
                    DisplayRow(state: state, store: store, isExpanded: expandedKeys.contains(state.display.persistentKey)) {
                        toggleExpanded(state)
                    }
                }
            }
        }
    }

    private var expandedKeys: Set<String> {
        Set(expandedDisplays.split(separator: ",").map(String.init))
    }

    private func toggleExpanded(_ state: DisplayState) {
        var keys = expandedKeys
        let key = state.display.persistentKey
        if keys.remove(key) == nil { keys.insert(key) }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            expandedDisplays = keys.sorted().joined(separator: ",")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Menu {
                Toggle("Brightness keys control external displays", isOn: keyBinding($brightnessKeys))
                Toggle("Volume keys control display speakers", isOn: keyBinding($volumeKeys))
                Toggle("Show on-screen display", isOn: $showOSD)
                Divider()
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = LoginItem.setEnabled($0) }
                ))
                Divider()
                Button("Check for Updates…") { updater.check(manual: true) }
                    .disabled(updater.isBusy)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { autoUpdateCheck },
                    set: { autoUpdateCheck = $0; updater.scheduleChecks() }
                ))
                Text("Version \(updater.currentVersion)")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Settings")
            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh displays")
            Spacer()
            Button("Quit Display Monk") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// Every new build of an unsigned app invalidates its old Accessibility grant, even though
    /// System Settings still shows it switched on.
    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Keys need Accessibility access", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("After updating Display Monk, remove it from the Accessibility list (–) and add it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .monkPanel()
    }

    /// Key toggles start or stop the event tap, which asks for Accessibility access the first time.
    private func keyBinding(_ setting: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { setting.wrappedValue }, set: { value in
            setting.wrappedValue = value
            MediaKeyTap.shared.update()
            accessibilityTrusted = AXIsProcessTrusted()
        })
    }
}

// MARK: - Brightness

/// One slider per display, plus Sync Brightness. The rows line up with the sun icon; while sync
/// is on, a saffron link between the sliders shows its status.
struct BrightnessPanel: View {
    @ObservedObject var store: DisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").foregroundStyle(Color.monkSaffron)
                Text("Brightness").font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.canSync {
                    Toggle("Sync Brightness", isOn: Binding(
                        get: { store.sync.isEnabled },
                        set: { enabled in withAnimation(.easeInOut(duration: 0.15)) { store.setSyncEnabled(enabled) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout)
                    .help("Keep all displays at the same brightness")
                }
            }
            VStack(spacing: store.isSyncActive ? 6 : 12) {
                ForEach(Array(store.displays.enumerated()), id: \.element.id) { index, state in
                    if index > 0, store.isSyncActive {
                        SyncLink(store: store)
                            .transition(.opacity)
                    }
                    BrightnessRow(state: state, store: store)
                }
            }
            if store.sync.isEnabled, !store.canSync {
                Text("Sync is on. Connect another display to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monkPanel()
    }
}

/// Sits between the sliders while Sync Brightness is on: linked, or not matched with a way to
/// match them.
struct SyncLink: View {
    @ObservedObject var store: DisplayStore

    var body: some View {
        let matched = store.isSyncMatched
        let color = matched ? Color.monkSaffron : Color.orange
        HStack(spacing: 6) {
            Capsule().fill(color.opacity(0.35)).frame(height: 1)
            Image(systemName: "link").font(.system(size: 9, weight: .bold))
            if matched {
                Text("Synced")
            } else {
                Text("Not matched")
                Button("Match") { store.matchAll() }
                    .buttonStyle(.link)
                    .help("Set every display to the brightness of the one under the pointer")
            }
            Capsule().fill(color.opacity(0.35)).frame(height: 1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct BrightnessRow: View {
    @ObservedObject var state: DisplayState
    @ObservedObject var store: DisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: state.display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(state.display.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.display.name)
                BrightnessMethodMenu(state: state)
                Spacer(minLength: 6)
                Text(percentText(state.brightness))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: Binding(get: { state.brightness }, set: { store.setBrightness($0, for: state) }), in: 0 ... 1)
                .controlSize(.small)
                .accessibilityLabel("\(state.display.name) brightness")
            if state.brightnessMethod == .software {
                Text("Software dimming: darkens the image only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The small badge naming how brightness is changed, with the choices behind it.
struct BrightnessMethodMenu: View {
    @ObservedObject var state: DisplayState

    var body: some View {
        Menu {
            ForEach(state.supportedMethods, id: \.self) { method in
                Toggle(label(for: method), isOn: Binding(
                    get: { state.brightnessMethod == method },
                    set: { if $0 { state.setBrightnessMethod(method) } }
                ))
            }
            if state.brightnessMethod != .software {
                Divider()
                Toggle("Combined: Dim to Black Below Minimum", isOn: Binding(get: { state.combined }, set: state.setCombined))
            }
        } label: {
            Text(label(for: state.brightnessMethod))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .help(state.isCombined ? "How brightness is changed: \(label(for: state.brightnessMethod)), then software dimming to black" : "How brightness is changed on this display")
    }

    private func label(for method: BrightnessMethod) -> String {
        switch method {
        case .native: "Native"
        case .ddc: "DDC"
        case .software: "Software"
        }
    }
}

/// The link drawn beside synced sliders.
// MARK: - Display rows

/// A display's name and current mode; opens to the display's other settings.
struct DisplayRow: View {
    @ObservedObject var state: DisplayState
    @ObservedObject var store: DisplayStore
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: state.display.isBuiltIn ? "laptopcomputer" : "display")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.display.name).lineLimit(1).truncationMode(.middle)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if state.display.isMain, store.displays.count > 1 {
                        Text("Main").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.display.name)
            .accessibilityHint(isExpanded ? "Hides this display's settings" : "Shows this display's settings")
            if isExpanded {
                DisplayControls(state: state, store: store)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.05 : isHovered ? 0.04 : 0))
        )
        .onHover { isHovered = $0 }
    }

    private var summary: String {
        guard let mode = state.currentMode else { return state.display.isBuiltIn ? "Built-in display" : "External display" }
        let size = "\(mode.width) × \(mode.height)" + (mode.isHiDPI ? " HiDPI" : "")
        return mode.refreshLabel.isEmpty ? size : "\(size) · \(mode.refreshLabel)"
    }
}

/// Everything for one display apart from brightness: the controls the menu always had.
struct DisplayControls: View {
    @ObservedObject var state: DisplayState
    @ObservedObject var store: DisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let contrast = state.contrast {
                LabeledSlider(
                    title: "Contrast",
                    valueText: percentText(contrast),
                    icon: "circle.lefthalf.filled",
                    value: Binding(get: { contrast }, set: state.setContrast)
                )
            }
            if let volume = state.volume {
                LabeledSlider(
                    title: "Volume",
                    valueText: state.volumeDetail,
                    icon: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    iconAction: { state.setMuted(!state.muted) },
                    value: Binding(get: { volume }, set: state.setVolume)
                )
            }
            if !state.resolutionChoices.isEmpty {
                ResolutionMenu(state: state)
            }
            if !state.display.isBuiltIn {
                hiDPIToggle
            }
            controls
        }
    }

    /// Takes effect immediately; no password, no restart.
    private var hiDPIToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: Binding(
                    get: { state.isHiDPIOn },
                    // Mode changes run after the current view update has finished.
                    set: { on in DispatchQueue.main.async { on ? state.enableHiDPI() : state.disableHiDPI() } }
                )) {
                    Label("High Resolution (HiDPI)", systemImage: "sparkles")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(state.isWorking)
                Spacer()
                Menu {
                    if state.overrideStatus == .installed {
                        Button("Remove Permanent HiDPI…") { DispatchQueue.main.async { HiDPIFlow.removePermanent(state) } }
                    } else {
                        Button("Make HiDPI Permanent…") { DispatchQueue.main.async { HiDPIFlow.makePermanent(state) } }
                    }
                    Divider()
                    Button("Reset Display to Native Resolution") { DispatchQueue.main.async { state.resetDisplay() } }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Permanent HiDPI works without Display Monk running, from your next restart")
            }
            if let status = state.hiDPIStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if state.refreshChoices.count > 1 {
                Menu {
                    ForEach(state.refreshChoices, id: \.self) { mode in
                        Button(mode.refreshLabel) { state.apply(mode) }
                    }
                } label: {
                    PillLabel(text: state.currentMode?.refreshLabel ?? "Hz")
                }
                .pillMenuStyle()
                .help("Refresh rate")
            }
            Menu {
                ForEach([0, 90, 180, 270], id: \.self) { degrees in
                    Button("\(degrees)°") { state.rotate(to: degrees) }
                }
            } label: {
                PillLabel(text: "\(state.rotation)°")
            }
            .pillMenuStyle()
            .help("Rotation")
            if state.hasDDC {
                Menu {
                    ForEach(InputSource.allCases, id: \.self) { source in
                        Button(source.description) { state.setInput(source.rawValue) }
                    }
                } label: {
                    PillLabel(text: inputLabel)
                }
                .pillMenuStyle()
                .help("Input source")
            }
        }
        .font(.callout)
    }

    private var inputLabel: String {
        guard let input = state.input else { return "Input" }
        return InputSource(vcpValue: input)?.description ?? String(format: "Input 0x%02X", input)
    }
}

/// A titled slider with its value on the right, as in BetterDisplay's menu.
struct LabeledSlider: View {
    let title: String
    let valueText: String
    let icon: String
    var iconAction: (() -> Void)?
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                iconView.frame(width: 20)
                Slider(value: $value, in: 0 ... 1)
            }
        }
    }

    @ViewBuilder private var iconView: some View {
        if let iconAction {
            Button(action: iconAction) { Image(systemName: icon) }.buttonStyle(.borderless)
        } else {
            Image(systemName: icon)
        }
    }
}

/// The desktop size, as a dropdown: one mode change per choice, nothing while browsing.
struct ResolutionMenu: View {
    @ObservedObject var state: DisplayState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20)
            Text("Resolution").foregroundStyle(.secondary)
            Spacer()
            Menu {
                let hiDPI = state.hiDPIChoices
                if !hiDPI.isEmpty {
                    Section("HiDPI (sharp)") {
                        ForEach(hiDPI.indices, id: \.self) { index in
                            choice(hiDPI[index], note: note(for: hiDPI[index], index: index, count: hiDPI.count))
                        }
                    }
                }
                Section("Low resolution") {
                    if let native = state.nativeLoDPIChoice {
                        choice(native, note: "Native")
                    }
                    let others = state.otherLoDPIChoices
                    if !others.isEmpty {
                        Menu("More") {
                            ForEach(others, id: \.self) { choice($0, note: nil) }
                        }
                    }
                }
            } label: {
                PillLabel(text: currentLabel)
            }
            .pillMenuStyle()
        }
        .font(.callout)
    }

    private var currentLabel: String {
        guard let mode = state.currentMode else { return "—" }
        return "\(mode.width) × \(mode.height)" + (mode.isHiDPI ? " HiDPI" : "")
    }

    private func choice(_ mode: ModeDescriptor, note: String?) -> some View {
        Toggle("\(mode.width) × \(mode.height)" + (note.map { " — \($0)" } ?? ""), isOn: Binding(
            get: { isCurrent(mode) },
            set: { if $0 { DispatchQueue.main.async { state.apply(mode) } } }
        ))
    }

    private func note(for mode: ModeDescriptor, index: Int, count: Int) -> String? {
        if state.isDefaultHiDPI(mode) { return "Default" }
        if count > 1, index == 0 { return "More Space" }
        if count > 1, index == count - 1 { return "Larger Text" }
        return nil
    }

    private func isCurrent(_ mode: ModeDescriptor) -> Bool {
        guard let current = state.currentMode else { return false }
        return current.width == mode.width && current.height == mode.height && current.isHiDPI == mode.isHiDPI
    }
}

/// The current value of a dropdown, in normal text colour inside a soft pill, so it stays
/// readable on the translucent panel (tinted text did not).
struct PillLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
        .contentShape(Capsule())
    }
}

extension View {
    /// Shows a `Menu`'s label as drawn (no tint, no system indicator), for `PillLabel`.
    func pillMenuStyle() -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
    }
}

/// A translucent, blurred background (more see-through than the standard popover) for the
/// rounded menu panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

// MARK: - Updates

/// Shown above the footer while there's something to say about updates.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.status {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").foregroundStyle(.secondary)
                }
            case .upToDate:
                Label("Display Monk \(updater.currentVersion) is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case let .available(update):
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.monkSaffron)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Display Monk \(update.version.description) is available")
                        Button("What's new") { updater.openReleasePage() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Spacer(minLength: 6)
                    Button("Install") { updater.install() }
                        .controlSize(.small)
                        .help("Downloads the update, then restarts Display Monk")
                }
            case let .downloading(progress):
                Text("Downloading update…").foregroundStyle(.secondary)
                ProgressView(value: progress).progressViewStyle(.linear)
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing and restarting…").foregroundStyle(.secondary)
                }
            case let .failed(message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Button("Open release page") { updater.openReleasePage() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Spacer(minLength: 6)
                    Button { updater.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monkPanel(padding: 10)
    }
}
