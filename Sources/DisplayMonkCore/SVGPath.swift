/// One drawing step of an SVG path, in absolute coordinates.
public enum SVGPathCommand: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case curve(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
    case close
}

/// A small parser for SVG path data (`d` attributes) covering M, L, H, V, C and Z in absolute
/// and relative forms: enough to draw icon artwork without bundling or rendering SVG files.
public enum SVGPath {
    /// Returns nil for malformed data or unsupported commands.
    public static func parse(_ data: String) -> [SVGPathCommand]? {
        guard let tokens = tokenize(data) else { return nil }
        var commands: [SVGPathCommand] = []
        var index = 0
        var current = (x: 0.0, y: 0.0)
        var subpathStart = (x: 0.0, y: 0.0)
        var command: Character?

        func numbers(_ count: Int) -> [Double]? {
            guard index + count <= tokens.count else { return nil }
            var values: [Double] = []
            for token in tokens[index ..< index + count] {
                guard case let .number(value) = token else { return nil }
                values.append(value)
            }
            index += count
            return values
        }

        while index < tokens.count {
            if case let .command(letter) = tokens[index] {
                command = letter
                index += 1
            }
            guard let letter = command else { return nil }
            let relative = letter.isLowercase
            let origin = relative ? current : (x: 0.0, y: 0.0)
            switch letter.uppercased() {
            case "M":
                guard let v = numbers(2) else { return nil }
                current = (origin.x + v[0], origin.y + v[1])
                subpathStart = current
                commands.append(.move(x: current.x, y: current.y))
                // Further coordinate pairs after a move are implicit line-tos.
                command = relative ? "l" : "L"
            case "L":
                guard let v = numbers(2) else { return nil }
                current = (origin.x + v[0], origin.y + v[1])
                commands.append(.line(x: current.x, y: current.y))
            case "H":
                guard let v = numbers(1) else { return nil }
                current.x = origin.x + v[0]
                commands.append(.line(x: current.x, y: current.y))
            case "V":
                guard let v = numbers(1) else { return nil }
                current.y = origin.y + v[0]
                commands.append(.line(x: current.x, y: current.y))
            case "C":
                guard let v = numbers(6) else { return nil }
                commands.append(.curve(
                    x1: origin.x + v[0], y1: origin.y + v[1],
                    x2: origin.x + v[2], y2: origin.y + v[3],
                    x: origin.x + v[4], y: origin.y + v[5]
                ))
                current = (origin.x + v[4], origin.y + v[5])
            case "Z":
                commands.append(.close)
                current = subpathStart
                command = nil
            default:
                return nil
            }
        }
        return commands
    }

    private enum Token {
        case command(Character)
        case number(Double)
    }

    private static func tokenize(_ data: String) -> [Token]? {
        var tokens: [Token] = []
        var number = ""
        var hasDot = false
        var hasExponent = false

        func flush() -> Bool {
            guard !number.isEmpty else { return true }
            guard let value = Double(number) else { return false }
            tokens.append(.number(value))
            number = ""
            hasDot = false
            hasExponent = false
            return true
        }

        for character in data {
            switch character {
            case "0" ... "9":
                number.append(character)
            case ".":
                // "0.5.5" is two numbers: a second dot starts a new one.
                if hasDot || hasExponent { guard flush() else { return nil } }
                hasDot = true
                number.append(character)
            case "e", "E":
                guard !number.isEmpty, !hasExponent else { return nil }
                hasExponent = true
                number.append(character)
            case "-", "+":
                // A sign starts a new number unless it belongs to an exponent.
                if let last = number.last, last == "e" || last == "E" {
                    number.append(character)
                } else {
                    guard flush() else { return nil }
                    number.append(character)
                }
            case " ", ",", "\n", "\t", "\r":
                guard flush() else { return nil }
            default:
                guard character.isLetter, flush() else { return nil }
                tokens.append(.command(character))
            }
        }
        guard flush() else { return nil }
        return tokens
    }
}
