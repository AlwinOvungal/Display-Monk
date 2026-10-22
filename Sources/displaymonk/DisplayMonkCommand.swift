import ArgumentParser
import DisplayKit
import DisplayMonkCore
import Foundation

@main
struct DisplayMonkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "displaymonk",
        abstract: "Control display brightness, volume, input and resolution.",
        discussion: """
        Displays are chosen with -d: a list index, "main", "builtin", "external", "id:<n>" \
        or part of the name. Levels are percentages and may be relative: 50, +10, -10.
        """,
        version: "0.1.0",
        subcommands: [
            List.self, Brightness.self, Contrast.self, Volume.self, Mute.self, Input.self,
            GetVCP.self, SetVCP.self, Modes.self, SetMode.self, Rotate.self, HiDPI.self, Reset.self,
        ]
    )
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

struct DisplayOption: ParsableArguments {
    @Option(name: [.short, .customLong("display")], help: "Display to control (default depends on the command).")
    var display: String?

    /// The chosen display, or the first one that `fallback` accepts.
    func controller(default fallback: (DisplayController) -> Bool) throws -> DisplayController {
        if let display {
            guard let controller = DisplayManager.shared.controller(matching: DisplaySelector(display)) else {
                throw CLIError("no display matches \"\(display)\"; run `displaymonk list`")
            }
            return controller
        }
        guard let controller = DisplayManager.shared.controllers().first(where: fallback) else {
            throw CLIError("no suitable display found; pass -d (see `displaymonk list`)")
        }
        return controller
    }

    func mainController() throws -> DisplayController {
        if display == nil, !DisplayManager.shared.controllers().contains(where: { $0.display.isMain }) {
            // The main desktop is a HiDPI virtual screen; its physical display is the first one.
            return try controller { _ in true }
        }
        return try controller { $0.display.isMain }
    }

    func ddcController() throws -> DisplayController {
        let controller = try controller { $0.ddc != nil }
        guard controller.ddc != nil else {
            throw CLIError("\(controller.display.name) has no DDC/CI connection")
        }
        return controller
    }
}

/// Values like "-10" look like options to the parser, so level arguments collect everything
/// left over and are validated here.
func parseLevel(_ arguments: [String]) throws -> LevelChange? {
    let arguments = arguments.filter { $0 != "--" }
    guard let text = arguments.first else { return nil }
    guard arguments.count == 1, let change = LevelChange(text) else {
        throw CLIError("expected a level such as 50, +10 or -10")
    }
    return change
}

func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List displays and how each can be controlled.")

    @Flag(help: "Read brightness over DDC to confirm each connection works (slow).")
    var probe = false

    func run() {
        let controllers = DisplayManager.shared.controllers()
        guard !controllers.isEmpty else {
            print("No displays found.")
            return
        }
        var rows = [["#", "ID", "Name", "Kind", "Control", "Mode"]]
        for (index, controller) in controllers.enumerated() {
            let display = controller.display
            var control = controller.preferredBrightnessMethod.rawValue
            if probe, controller.ddc != nil {
                switch controller.level(.brightness) {
                case let .success(level): control += " (brightness \(percent(level)))"
                case let .failure(error): control += " (\(error))"
                }
            }
            rows.append([
                "\(index)",
                "\(display.id)",
                display.name + (display.isMain ? " *" : ""),
                display.isBuiltIn ? "built-in" : "external",
                control,
                DisplayModes.current(for: display.id)?.description ?? "-",
            ])
        }
        printTable(rows)
        print("\n* main display")
    }
}

func printTable(_ rows: [[String]]) {
    let widths = rows.reduce(into: [Int](repeating: 0, count: rows[0].count)) { widths, row in
        for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
    }
    for row in rows {
        let cells = row.enumerated().map { column, cell in
            cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
        }
        print(cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Levels

struct Brightness: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set brightness (main display by default).")

    @OptionGroup var target: DisplayOption

    @Option(help: "native, ddc or software. Defaults to the best one the display supports.")
    var method: String?

    @Argument(parsing: .allUnrecognized, help: "New level, e.g. 60, +10, -10.")
    var level: [String] = []

    func run() throws {
        let controller = try target.mainController()
        let method = try self.method.map { name in
            guard let parsed = BrightnessMethod(rawValue: name) else { throw CLIError("unknown method \"\(name)\"") }
            return parsed
        } ?? controller.preferredBrightnessMethod
        if method == .software {
            // Gamma changes are undone by macOS as soon as the process that made them exits.
            throw CLIError("software dimming only lasts while the Display Monk app is running; use the app")
        }
        guard let change = try parseLevel(level) else {
            guard let value = controller.brightness(using: method) else {
                throw CLIError("could not read brightness of \(controller.display.name) via \(method.rawValue)")
            }
            print(percent(value))
            return
        }
        let current = (controller.brightness(using: method) ?? 0.5) * 100
        let newLevel = change.apply(to: current)
        guard controller.setBrightness(newLevel / 100, using: method) else {
            throw CLIError("could not set brightness of \(controller.display.name) via \(method.rawValue)")
        }
        print("\(controller.display.name): brightness \(Int(newLevel.rounded()))%")
    }
}

/// Shared implementation for continuous DDC values (contrast, volume).
protocol DDCLevelCommand: ParsableCommand {
    static var code: VCPCode { get }
    var target: DisplayOption { get }
    var level: [String] { get }
}

extension DDCLevelCommand {
    func run() throws {
        let controller = try target.ddcController()
        let name = Self.code.name ?? Self.code.description
        guard let change = try parseLevel(level) else {
            switch controller.level(Self.code) {
            case let .success(value): print(percent(value))
            case let .failure(error): throw CLIError("could not read \(name): \(error)")
            }
            return
        }
        let current = ((try? controller.level(Self.code).get()) ?? 0.5) * 100
        let newLevel = change.apply(to: current)
        guard controller.setLevel(Self.code, newLevel / 100) else {
            throw CLIError("could not set \(name) on \(controller.display.name)")
        }
        print("\(controller.display.name): \(name) \(Int(newLevel.rounded()))%")
    }
}

struct Contrast: DDCLevelCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set contrast over DDC.")
    static let code = VCPCode.contrast

    @OptionGroup var target: DisplayOption
    @Argument(parsing: .allUnrecognized, help: "New level, e.g. 70, +5, -5.")
    var level: [String] = []
}

struct Volume: DDCLevelCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set the monitor's speaker volume over DDC.")
    static let code = VCPCode.volume

    @OptionGroup var target: DisplayOption
    @Argument(parsing: .allUnrecognized, help: "New level, e.g. 30, +10, -10.")
    var level: [String] = []
}

struct Mute: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or change the monitor's mute state over DDC.")

    enum State: String, ExpressibleByArgument {
        case on, off, toggle
    }

    @OptionGroup var target: DisplayOption
    @Argument var state: State?

    func run() throws {
        let controller = try target.ddcController()
        let current = controller.isMuted()
        guard let state else {
            guard let current else { throw CLIError("could not read mute state") }
            print(current ? "on" : "off")
            return
        }
        let muted: Bool
        switch state {
        case .on: muted = true
        case .off: muted = false
        case .toggle:
            guard let current else { throw CLIError("could not read mute state to toggle it") }
            muted = !current
        }
        guard controller.setMuted(muted) else { throw CLIError("could not change mute state") }
        print("\(controller.display.name): mute \(muted ? "on" : "off")")
    }
}

struct Input: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or switch the monitor's input over DDC.",
        discussion: "Sources: " + InputSource.allCases.map(\.argumentName).joined(separator: ", ") + ", or a raw code such as 0x0f."
    )

    @OptionGroup var target: DisplayOption
    @Argument var source: String?

    func run() throws {
        let controller = try target.ddcController()
        guard let source else {
            guard let value = controller.inputSource() else { throw CLIError("could not read the input source") }
            let hexValue = String(format: "0x%02X", value)
            print(InputSource(vcpValue: value).map { "\($0) (\(hexValue))" } ?? hexValue)
            return
        }
        guard let value = InputSource.vcpValue(forArgument: source) else {
            throw CLIError("unknown input \"\(source)\"")
        }
        guard controller.setInputSource(value) else { throw CLIError("could not switch input") }
        print("\(controller.display.name): input \(InputSource(vcpValue: value)?.description ?? String(format: "0x%02X", value))")
    }
}

// MARK: - Raw VCP access

struct GetVCP: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read any VCP code, e.g. `get 0x10` or `get volume`.")

    @OptionGroup var target: DisplayOption
    @Argument var code: String

    func run() throws {
        guard let vcp = VCPCode(argument: code) else { throw CLIError("unknown VCP code \"\(code)\"") }
        let controller = try target.ddcController()
        switch controller.read(vcp) {
        case let .success(reply): print("\(vcp): current \(reply.current), max \(reply.maximum)")
        case let .failure(error): throw CLIError("\(vcp): \(error)")
        }
    }
}

struct SetVCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Write a raw value to a VCP code, e.g. `set contrast 70` or `set 0x60 17`.",
        discussion: """
        Only the everyday controls are allowed by default: brightness, contrast, volume, mute and \
        input. Other codes (factory reset, power, colour gains, vendor codes) can change or reset \
        settings stored in the monitor; pass --force only if you know what the code does.
        """
    )

    @OptionGroup var target: DisplayOption
    @Argument var code: String
    @Argument var value: UInt16
    @Flag(help: "Allow codes other than brightness, contrast, volume, mute and input.") var force = false

    func run() throws {
        guard let vcp = VCPCode(argument: code) else { throw CLIError("unknown VCP code \"\(code)\"") }
        guard vcp.isUserControl || force else {
            throw CLIError("\(vcp) is not an everyday control; refusing without --force")
        }
        let controller = try target.ddcController()
        // Never send more than the monitor says it supports.
        let clamped = vcp.isContinuous ? min(value, controller.maximum(for: vcp)) : value
        guard controller.write(vcp, value: clamped) else { throw CLIError("write to \(vcp) failed") }
        print("\(controller.display.name): \(vcp) = \(clamped)")
    }
}

// MARK: - Modes

struct Modes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List resolutions (main display by default).")

    @OptionGroup var target: DisplayOption

    @Flag(help: "Include modes macOS marks as unsuitable for the desktop.")
    var all = false

    func run() throws {
        let controller = try target.mainController()
        let current = DisplayModes.current(for: controller.display.id)
        print("\(controller.display.name):")
        for mode in DisplayModes.available(for: controller.display.id, includeUnusable: all) {
            let marker = mode.id == current?.id ? "*" : " "
            print("\(marker) \(mode)")
        }
    }
}

struct SetMode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-mode",
        abstract: "Switch resolution, e.g. `set-mode 1920x1080`, `set-mode 2560x1440@144 --no-hidpi`."
    )

    @OptionGroup var target: DisplayOption
    @Argument(help: "WIDTHxHEIGHT[@HZ] in points.") var mode: String
    @Flag(inversion: .prefixedNo, help: "Require (or avoid) a HiDPI mode.") var hidpi: Bool?

    func run() throws {
        guard var spec = ModeSpec(mode) else { throw CLIError("expected a mode like 1920x1080 or 1920x1080@60") }
        spec.hiDPI = hidpi
        let controller = try target.mainController()
        let id = controller.display.id
        guard let match = ModeList.bestMatch(for: spec, in: DisplayModes.available(for: id), current: DisplayModes.current(for: id)) else {
            throw CLIError("\(controller.display.name) has no \(mode) mode; run `displaymonk modes`")
        }
        try DisplayModes.apply(match, to: id)
        print("\(controller.display.name): \(match)")
    }
}

struct Rotate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rotate a display (main display by default).")

    @OptionGroup var target: DisplayOption
    @Argument(help: "0, 90, 180 or 270.") var degrees: Int

    func run() throws {
        let controller = try target.mainController()
        try DisplayRotation.set(degrees, for: controller.display.id, wait: 10)
        print("\(controller.display.name): rotated to \(degrees)°")
    }
}

// MARK: - HiDPI

struct HiDPI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hidpi",
        abstract: "Show, add or remove HiDPI resolutions for an external display.",
        discussion: """
        enable and disable change macOS's display configuration and need sudo; they take effect \
        after a restart. Only scaled desktop sizes are added: the signal sent to the monitor is \
        unchanged. The app can also use a virtual screen instead, which needs no restart.
        """
    )

    enum Action: String, ExpressibleByArgument {
        case status, enable, disable
    }

    @OptionGroup var target: DisplayOption
    @Argument var action: Action = .status

    func run() throws {
        let controller = try target.controller { !$0.display.isBuiltIn }
        let display = controller.display
        guard !display.isBuiltIn else { throw CLIError("built-in displays already use HiDPI") }
        switch action {
        case .status:
            let status = OverrideInstaller.status(for: display)
            print("\(display.name)")
            print("  native resolution: \(OverrideInstaller.nativeSize(for: display)?.description ?? "unknown")")
            print("  configuration:     \(describe(status)) (\(OverrideInstaller.path(for: display)))")
            print("  HiDPI sizes:       \(OverrideInstaller.hasExtendedHiDPIModes(for: display) ? "available" : "not available")")
            if display.isVirtualHiDPI { print("  virtual screen:    on (from the Display Monk app)") }
            if status == .installed, !OverrideInstaller.hasExtendedHiDPIModes(for: display) {
                print("  Restart your Mac to load the new resolutions.")
            }
        case .enable:
            try requireRoot()
            try OverrideInstaller.install(for: display)
            let sizes = OverrideInstaller.presetSizes(for: display)
            print("\(display.name): added \(sizes.count) HiDPI sizes (\(sizes.first?.description ?? "") to \(sizes.last?.description ?? "")).")
            print("Restart your Mac to use them.")
        case .disable:
            try requireRoot()
            guard OverrideInstaller.status(for: display) == .installed else {
                throw CLIError("no Display Monk configuration to remove for \(display.name)")
            }
            try OverrideInstaller.remove(for: display)
            print("\(display.name): HiDPI configuration removed. Restart your Mac to finish.")
        }
    }

    private func requireRoot() throws {
        guard geteuid() == 0 else { throw CLIError("this changes macOS's display configuration; run it with sudo") }
    }

    private func describe(_ status: OverrideStatus) -> String {
        switch status {
        case .notInstalled: "none"
        case .installed: "installed by Display Monk"
        case .foreign: "from another app"
        }
    }
}

// MARK: - Reset

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put a display back to its native resolution if it got stuck in a wrong mode.",
        discussion: """
        Stops any mirroring involving the display and applies its native unscaled resolution. \
        Quit the Display Monk app first if it is running HiDPI on that display with a virtual \
        screen; quitting removes the virtual screen.
        """
    )

    @OptionGroup var target: DisplayOption

    func run() throws {
        let controller = try target.controller { !$0.display.isBuiltIn }
        let id = controller.display.id
        VirtualMirror.reset(id)
        guard let native = DisplayModes.native(for: id) else {
            throw CLIError("could not find the native resolution of \(controller.display.name)")
        }
        print("\(controller.display.name): reset to \(native)")
    }
}
