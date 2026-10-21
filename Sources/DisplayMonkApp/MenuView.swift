import AppKit
import ApplicationServices
import DisplayKit
import DisplayMonkCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: DisplayStore
    @AppStorage(Preferences.brightnessKeysKey) private var brightnessKeys = false
    @AppStorage(Preferences.volumeKeysKey) private var volumeKeys = false
    @AppStorage(Preferences.showOSDKey) private var showOSD = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.displays.isEmpty {
                Text("No displays found").foregroundStyle(.secondary)
            }
            ForEach(store.displays) { state in
                DisplaySection(state: state, store: store)
            }
            if store.displays.count > 1 {
                ArrangementSection(store: store)
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Brightness keys control external displays", isOn: keyBinding($brightnessKeys))
                Toggle("Volume keys control display speakers", isOn: keyBinding($volumeKeys))
                Toggle("Show on-screen display", isOn: $showOSD)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = LoginItem.setEnabled($0) }
                ))
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(.horizontal, 4)
            if brightnessKeys || volumeKeys, !accessibilityTrusted {
                accessibilityWarning
            }
            HStack {
                Button("Refresh") { store.reload() }
                Spacer()
                Button("Quit Display Monk") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 340)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onReceive(NotificationCenter.default.publisher(for: .menuWillShow)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
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
        .padding(.horizontal, 4)
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

struct DisplaySection: View {
    @ObservedObject var state: DisplayState
    @ObservedObject var store: DisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 10) {
                LabeledSlider(
                    title: state.brightnessTitle,
                    valueText: percentText(state.brightness),
                    icon: "sun.max",
                    value: Binding(get: { state.brightness }, set: state.setBrightness)
                )
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
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.display.isBuiltIn ? "laptopcomputer" : "display")
            Text(state.display.name).font(.headline).lineLimit(1)
            Spacer()
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
            .buttonStyle(.borderless)
            .fixedSize()
            .font(.caption)
            .help("How brightness is changed on this display")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08)))
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

    private func label(for method: BrightnessMethod) -> String {
        switch method {
        case .native: "Native"
        case .ddc: "DDC"
        case .software: "Software"
        }
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
