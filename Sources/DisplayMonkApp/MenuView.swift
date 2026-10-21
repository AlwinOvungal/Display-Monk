import DisplayKit
import DisplayMonkCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: DisplayStore
    @AppStorage(Preferences.brightnessKeysKey) private var brightnessKeys = false
    @AppStorage(Preferences.volumeKeysKey) private var volumeKeys = false
    @AppStorage(Preferences.showOSDKey) private var showOSD = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.displays.isEmpty {
                Text("No displays found").foregroundStyle(.secondary)
            }
            ForEach(store.displays) { state in
                DisplaySection(state: state)
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
            HStack {
                Button("Refresh") { store.reload() }
                Spacer()
                Button("Quit Display Monk") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    /// Key toggles start or stop the event tap, which asks for Accessibility access the first time.
    private func keyBinding(_ setting: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { setting.wrappedValue }, set: { value in
            setting.wrappedValue = value
            MediaKeyTap.shared.update()
        })
    }
}

struct DisplaySection: View {
    @ObservedObject var state: DisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LevelSlider(
                icon: "sun.max",
                value: Binding(get: { state.brightness }, set: state.setBrightness),
                range: state.brightnessMethod == .software ? SoftwareDimmer.minimumLevel ... 1 : 0 ... 1
            )
            if let contrast = state.contrast {
                LevelSlider(icon: "circle.lefthalf.filled", value: Binding(get: { contrast }, set: state.setContrast))
            }
            if let volume = state.volume {
                HStack(spacing: 6) {
                    Button { state.setMuted(!state.muted) } label: {
                        Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    LevelSlider(icon: nil, value: Binding(get: { volume }, set: state.setVolume))
                }
            }
            controls
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: state.display.isBuiltIn ? "laptopcomputer" : "display")
            Text(state.display.name).font(.headline).lineLimit(1)
            Spacer()
            Menu(label(for: state.brightnessMethod)) {
                ForEach(state.supportedMethods, id: \.self) { method in
                    Button(label(for: method)) { state.setBrightnessMethod(method) }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .font(.caption)
            .help("How brightness is changed on this display")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Menu(state.currentMode.map { "\($0.sizeLabel)\($0.isHiDPI ? " HiDPI" : "")" } ?? "Resolution") {
                ForEach(state.resolutionChoices, id: \.self) { mode in
                    Button(mode.isHiDPI ? "\(mode.sizeLabel) (HiDPI)" : mode.sizeLabel) { state.apply(mode) }
                }
            }
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

struct LevelSlider: View {
    let icon: String?
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).frame(width: 18)
            }
            Slider(value: $value, in: range)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
