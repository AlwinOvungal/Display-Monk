import ApplicationServices
import DisplayKit
import DisplayMonkCore
import SwiftUI

/// The menu bar popover: a compact header, brightness for every display (with Sync
/// Brightness), each display's other settings behind a disclosure row, and a quiet footer.
struct MenuView: View {
    @ObservedObject var store: DisplayStore
    @AppStorage(Preferences.brightnessKeysKey) private var brightnessKeys = false
    @AppStorage(Preferences.volumeKeysKey) private var volumeKeys = false
    @AppStorage(Preferences.showOSDKey) private var showOSD = true
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
            }
            if brightnessKeys || volumeKeys, !accessibilityTrusted {
                accessibilityWarning
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .tint(.monkSaffron)
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

/// One slider per display, plus Sync Brightness. The rows look the same synced or not, so
/// switching sync doesn't move anything; a saffron link joins the sliders while it's on.
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
            VStack(spacing: 12) {
                ForEach(store.displays) { state in
                    BrightnessRow(state: state, store: store)
                }
            }
            .padding(.leading, store.canSync ? 20 : 0)
            .overlay(alignment: .leading) {
                if store.canSync {
                    LinkBracket(isActive: store.isSyncActive)
                }
            }
            if store.canSync || store.sync.isEnabled {
                caption
            }
        }
        .monkPanel()
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if store.isSyncActive {
                if store.isSyncMatched {
                    StatusDot(color: .monkSaffron)
                    Text("Linked across \(store.displays.count) displays · move any slider")
                } else {
                    StatusDot(color: .orange)
                    Text("Not matched")
                    Spacer()
                    Button("Match") { store.matchAll() }
                        .buttonStyle(.link)
                        .help("Set every display to the brightness of the one under the pointer")
                }
            } else if store.canSync {
                Text("Each display is adjusted on its own")
            } else {
                Text("Sync is on. Connect another display to use it.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 16)
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
struct LinkBracket: View {
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            Capsule().frame(width: 2)
            Image(systemName: "link").font(.system(size: 9, weight: .bold))
            Capsule().frame(width: 2)
        }
        .foregroundStyle(Color.monkSaffron)
        .frame(width: 12)
        .padding(.vertical, 6)
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .accessibilityHidden(true)
    }
}

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
            if store.displays.count > 1 {
                arrangement
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Permanent HiDPI works without Display Monk running, from your next restart")
            }
            if let status = state.hiDPIStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Position dropdowns relative to the MacBook (or main display), and "Set as Main".
    @ViewBuilder private var arrangement: some View {
        let reference = store.arrangementReference(for: state)
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle").frame(width: 20)
            if !state.display.isBuiltIn, let reference {
                let current = state.placement(relativeTo: reference)
                let side = current?.0 ?? Arrangement.nearestPlacement(of: state.frame, relativeTo: reference.frame)
                let name = reference.display.isBuiltIn ? "MacBook" : shortName(reference.display.name)
                Menu(current.map { positionLabel($0.0, name) } ?? "Custom position") {
                    ForEach(Placement.allCases, id: \.self) { placement in
                        Toggle(positionLabel(placement, name), isOn: Binding(
                            get: { current?.0 == placement },
                            set: { if $0 { state.move(placement, current?.1 ?? .center, relativeTo: reference) } }
                        ))
                    }
                }
                .fixedSize()
                Menu(current.map { $0.1.label(for: $0.0) } ?? "Align") {
                    ForEach(PlacementAlignment.allCases, id: \.self) { alignment in
                        Toggle(alignment.label(for: side), isOn: Binding(
                            get: { current?.1 == alignment },
                            set: { if $0 { state.move(side, alignment, relativeTo: reference) } }
                        ))
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if !state.display.isMain {
                Button("Set as Main") { state.makeMain(among: store.displays) }
                    .fixedSize()
                    .help("Moves the menu bar and Dock to this display")
            }
        }
        .controlSize(.small)
    }

    /// Long display names would push the position menu past the popover's width.
    private func shortName(_ name: String) -> String {
        name.count > 16 ? String(name.prefix(15)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    private func positionLabel(_ placement: Placement, _ reference: String) -> String {
        switch placement {
        case .left: "Left of \(reference)"
        case .right: "Right of \(reference)"
        case .above: "Above \(reference)"
        case .below: "Below \(reference)"
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if state.refreshChoices.count > 1 {
                Menu(state.currentMode?.refreshLabel ?? "Hz") {
                    ForEach(state.refreshChoices, id: \.self) { mode in
                        Button(mode.refreshLabel) { state.apply(mode) }
                    }
                }
                .fixedSize()
            }
            Menu("\(state.rotation)°") {
                ForEach([0, 90, 180, 270], id: \.self) { degrees in
                    Button("\(degrees)°") { state.rotate(to: degrees) }
                }
            }
            .fixedSize()
            if state.hasDDC {
                Menu(inputLabel) {
                    ForEach(InputSource.allCases, id: \.self) { source in
                        Button(source.description) { state.setInput(source.rawValue) }
                    }
                }
            }
        }
        .controlSize(.small)
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
                Text(currentLabel).monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
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
