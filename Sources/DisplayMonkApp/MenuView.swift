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
        VStack(alignment: .leading, spacing: 10) {
            if store.displays.isEmpty {
                Text("No displays found").foregroundStyle(.secondary)
            }
            ForEach(store.displays) { state in
                DisplaySection(state: state)
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
            HStack {
                Button("Refresh") { store.reload() }
                Spacer()
                Button("Quit Display Monk") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            store.refreshIfStale()
            MediaKeyTap.shared.update()
        }
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
                if state.sliderChoices.count > 1 {
                    ResolutionSlider(state: state)
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

    private var hiDPIToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { state.isHiDPIOn },
                // Dialogs run after the current view update has finished.
                set: { on in DispatchQueue.main.async { on ? HiDPIFlow.enable(state) : HiDPIFlow.disable(state) } }
            )) {
                Label("High Resolution (HiDPI)", systemImage: "sparkles")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(state.isWorking)
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
    var range: ClosedRange<Double> = 0 ... 1
    var step: Double?
    var onRelease: (() -> Void)?

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
                if let step {
                    Slider(value: $value, in: range, step: step, onEditingChanged: released)
                } else {
                    Slider(value: $value, in: range, onEditingChanged: released)
                }
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

    private func released(_ editing: Bool) {
        if !editing { onRelease?() }
    }
}

/// Picks a desktop size by dragging; the mode is applied when the slider is released.
struct ResolutionSlider: View {
    @ObservedObject var state: DisplayState
    @State private var position: Double?

    var body: some View {
        let choices = state.sliderChoices
        let current = choices.firstIndex {
            $0.width == state.currentMode?.width && $0.height == state.currentMode?.height && $0.isHiDPI == state.currentMode?.isHiDPI
        } ?? 0
        let index = min(choices.count - 1, max(0, Int((position ?? Double(current)).rounded())))
        let choice = choices[index]
        LabeledSlider(
            title: "Resolution",
            valueText: "\(choice.width) × \(choice.height)" + (choice.isHiDPI ? "" : " (LoDPI)"),
            icon: "arrow.up.left.and.arrow.down.right",
            value: Binding(get: { position ?? Double(current) }, set: { position = $0 }),
            range: 0 ... Double(choices.count - 1),
            step: 1,
            onRelease: {
                if index != current { state.apply(choice) }
                position = nil
            }
        )
    }
}
