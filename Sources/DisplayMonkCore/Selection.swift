/// How a command-line user names a display.
public enum DisplaySelector: Equatable, Sendable {
    case index(Int)
    case id(UInt32)
    case name(String)
    case main
    case builtIn
    case external

    /// "main", "builtin", "external", "id:5", a list index ("1") or part of a display name.
    public init(_ text: String) {
        let lowered = text.lowercased()
        switch lowered {
        case "main": self = .main
        case "builtin", "built-in", "internal": self = .builtIn
        case "external": self = .external
        default:
            if lowered.hasPrefix("id:"), let id = UInt32(lowered.dropFirst(3)) {
                self = .id(id)
            } else if let index = Int(lowered) {
                self = .index(index)
            } else {
                self = .name(lowered)
            }
        }
    }

    /// Resolves against displays in list order. Returns the index of the match.
    public func resolve(in displays: [SelectableDisplay]) -> Int? {
        switch self {
        case let .index(index):
            return displays.indices.contains(index) ? index : nil
        case let .id(id):
            return displays.firstIndex { $0.id == id }
        case let .name(name):
            return displays.firstIndex { $0.name.lowercased() == name }
                ?? displays.firstIndex { $0.name.lowercased().contains(name) }
        case .main:
            return displays.firstIndex { $0.isMain }
        case .builtIn:
            return displays.firstIndex { $0.isBuiltIn }
        case .external:
            return displays.firstIndex { !$0.isBuiltIn }
        }
    }
}

public struct SelectableDisplay: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let isMain: Bool
    public let isBuiltIn: Bool

    public init(id: UInt32, name: String, isMain: Bool, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
    }
}

/// An absolute or relative level change, in percent: "50", "50%", "+10", "-10".
public enum LevelChange: Equatable, Sendable {
    case absolute(Double)
    case relative(Double)

    public init?(_ text: String) {
        var body = Substring(text.trimmingSpaces())
        if body.hasSuffix("%") { body = body.dropLast() }
        if body.hasPrefix("+") || body.hasPrefix("-") {
            guard let delta = Double(body) else { return nil }
            self = .relative(delta)
        } else {
            guard let value = Double(body), value >= 0 else { return nil }
            self = .absolute(value)
        }
    }

    /// Applies the change to a current percentage and clamps the result to 0...100.
    public func apply(to current: Double) -> Double {
        let target: Double
        switch self {
        case let .absolute(value): target = value
        case let .relative(delta): target = current + delta
        }
        return min(100, max(0, target))
    }
}

/// Converts between a 0...1 fraction and a DDC raw value with the display's reported maximum.
public enum LevelScale {
    public static func raw(fromFraction fraction: Double, maximum: UInt16) -> UInt16 {
        let clamped = min(1, max(0, fraction))
        return UInt16((clamped * Double(maximum)).rounded())
    }

    public static func fraction(fromRaw raw: UInt16, maximum: UInt16) -> Double {
        guard maximum > 0 else { return 0 }
        return min(1, Double(raw) / Double(maximum))
    }

    /// One media-key step: 1/16 normally, 1/64 for fine steps, snapped to the step grid so
    /// repeated presses land on the same values the system's own OSD uses.
    public static func step(_ fraction: Double, up: Bool, fine: Bool) -> Double {
        let divisions = fine ? 64.0 : 16.0
        let position = (fraction * divisions).rounded()
        let next = up ? position + 1 : position - 1
        return min(1, max(0, next / divisions))
    }
}

extension String {
    func trimmingSpaces() -> String {
        String(drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
    }
}
