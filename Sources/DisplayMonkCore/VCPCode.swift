/// A VESA MCCS "Virtual Control Panel" feature code, the register a DDC/CI request reads or writes.
public struct VCPCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let restoreFactoryDefaults = VCPCode(rawValue: 0x04)
    public static let brightness = VCPCode(rawValue: 0x10)
    public static let contrast = VCPCode(rawValue: 0x12)
    public static let redGain = VCPCode(rawValue: 0x16)
    public static let greenGain = VCPCode(rawValue: 0x18)
    public static let blueGain = VCPCode(rawValue: 0x1A)
    public static let inputSource = VCPCode(rawValue: 0x60)
    public static let volume = VCPCode(rawValue: 0x62)
    public static let mute = VCPCode(rawValue: 0x8D)
    public static let powerMode = VCPCode(rawValue: 0xD6)

    static let names: [(String, VCPCode)] = [
        ("brightness", .brightness),
        ("contrast", .contrast),
        ("red", .redGain),
        ("green", .greenGain),
        ("blue", .blueGain),
        ("input", .inputSource),
        ("volume", .volume),
        ("mute", .mute),
        ("power", .powerMode),
        ("reset", .restoreFactoryDefaults),
    ]

    public var name: String? {
        Self.names.first { $0.1 == self }?.0
    }

    public var description: String {
        let hex = "0x" + String(rawValue, radix: 16, uppercase: true).leftPadded(to: 2)
        return name.map { "\($0) (\(hex))" } ?? hex
    }

    /// Accepts a known name ("brightness"), a hex code ("0x10") or a decimal code ("16").
    public init?(argument: String) {
        let text = argument.lowercased()
        if let named = Self.names.first(where: { $0.0 == text }) {
            self = named.1
        } else if let value = parseByte(text) {
            self.init(rawValue: value)
        } else {
            return nil
        }
    }
}

/// Values for VCP 0x60 (input source) as defined by MCCS, plus USB-C which many vendors use.
public enum InputSource: UInt16, CaseIterable, Sendable, CustomStringConvertible {
    case vga1 = 0x01
    case vga2 = 0x02
    case dvi1 = 0x03
    case dvi2 = 0x04
    case compositeVideo1 = 0x05
    case sVideo1 = 0x07
    case component1 = 0x0C
    case displayPort1 = 0x0F
    case displayPort2 = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12
    case usbC = 0x1B

    public var description: String {
        switch self {
        case .vga1: "VGA 1"
        case .vga2: "VGA 2"
        case .dvi1: "DVI 1"
        case .dvi2: "DVI 2"
        case .compositeVideo1: "Composite"
        case .sVideo1: "S-Video"
        case .component1: "Component"
        case .displayPort1: "DisplayPort 1"
        case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        }
    }

    /// Short, case-insensitive name used on the command line, e.g. "hdmi1" or "dp2".
    public var argumentName: String {
        switch self {
        case .vga1: "vga1"
        case .vga2: "vga2"
        case .dvi1: "dvi1"
        case .dvi2: "dvi2"
        case .compositeVideo1: "composite"
        case .sVideo1: "svideo"
        case .component1: "component"
        case .displayPort1: "dp1"
        case .displayPort2: "dp2"
        case .hdmi1: "hdmi1"
        case .hdmi2: "hdmi2"
        case .usbC: "usbc"
        }
    }

    /// Only the low byte carries the input; some displays set vendor bits in the high byte.
    public init?(vcpValue: UInt16) {
        self.init(rawValue: vcpValue & 0xFF)
    }

    /// Parses an argument name ("hdmi1", "dp", "usb-c") or a raw code. Returns the VCP value to write.
    public static func vcpValue(forArgument argument: String) -> UInt16? {
        let text = String(argument.lowercased().filter { $0 != "-" && $0 != " " })
        let aliases: [String: InputSource] = [
            "hdmi": .hdmi1, "dp": .displayPort1, "displayport": .displayPort1,
            "displayport1": .displayPort1, "displayport2": .displayPort2,
            "usbc": .usbC, "typec": .usbC, "thunderbolt": .usbC, "vga": .vga1, "dvi": .dvi1,
        ]
        if let source = allCases.first(where: { $0.argumentName == text }) ?? aliases[text] {
            return source.rawValue
        }
        return parseByte(text).map(UInt16.init)
    }
}

func parseByte(_ text: String) -> UInt8? {
    if text.hasPrefix("0x") {
        return UInt8(text.dropFirst(2), radix: 16)
    }
    return UInt8(text)
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}
