/// A display mode reduced to the values that matter for choosing one.
public struct ModeDescriptor: Hashable, Sendable, CustomStringConvertible {
    /// CoreGraphics' `ioDisplayModeID`, used to find the real mode again.
    public let id: Int32
    /// Size in points (the desktop size the user sees).
    public let width: Int
    public let height: Int
    /// Size of the backing framebuffer in pixels; twice the point size for HiDPI modes.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isUsableForDesktop: Bool

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, isUsableForDesktop: Bool = true) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsableForDesktop = isUsableForDesktop
    }

    public var isHiDPI: Bool {
        pixelWidth > width
    }

    public var sizeLabel: String {
        "\(width)x\(height)"
    }

    public var refreshLabel: String {
        refreshRate == 0 ? "" : refreshRate.rounded() == refreshRate ? "\(Int(refreshRate))Hz" : "\(roundedRate(refreshRate))Hz"
    }

    public var description: String {
        var parts = [sizeLabel]
        if !refreshLabel.isEmpty { parts.append("@ \(refreshLabel)") }
        if isHiDPI { parts.append("HiDPI") } else if pixelWidth != width { parts.append("\(pixelWidth)x\(pixelHeight)px") }
        return parts.joined(separator: " ")
    }

    /// Modes that look identical to the user (same size, backing size and rate) collapse to one.
    var dedupeKey: [Double] {
        [Double(width), Double(height), Double(pixelWidth), Double(pixelHeight), refreshRate.rounded()]
    }
}

func roundedRate(_ rate: Double) -> String {
    let hundredths = Int((rate * 100).rounded())
    let whole = hundredths / 100
    let fraction = hundredths % 100
    if fraction == 0 { return "\(whole)" }
    let digits = String(fraction).leftPadded(to: 2)
    return "\(whole)." + (digits.hasSuffix("0") ? String(digits.dropLast()) : digits)
}

public enum ModeList {
    /// Desktop-usable modes, duplicates removed, largest first, HiDPI before low-resolution
    /// at the same size, higher refresh rates first.
    public static func organize(_ modes: [ModeDescriptor], includeUnusable: Bool = false) -> [ModeDescriptor] {
        var seen = Set<[Double]>()
        return modes
            .filter { includeUnusable || $0.isUsableForDesktop }
            .sorted { a, b in
                if a.width != b.width { return a.width > b.width }
                if a.height != b.height { return a.height > b.height }
                if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
                return a.refreshRate > b.refreshRate
            }
            .filter { seen.insert($0.dedupeKey).inserted }
    }

    /// The HiDPI mode closest in width to `size`, for when the exact size isn't offered.
    /// Among equally close sizes, the refresh rate nearest the current one wins.
    public static func closestHiDPI(to size: LogicalSize, in modes: [ModeDescriptor], current: ModeDescriptor?) -> ModeDescriptor? {
        let hiDPI = organize(modes).filter(\.isHiDPI)
        guard let best = hiDPI.min(by: { abs($0.width - size.width) < abs($1.width - size.width) }) else { return nil }
        return bestMatch(for: ModeSpec(width: best.width, height: best.height, hiDPI: true), in: modes, current: current)
    }

    /// Picks the mode that best matches a request; nil if no mode has the requested size.
    public static func bestMatch(for spec: ModeSpec, in modes: [ModeDescriptor], current: ModeDescriptor?) -> ModeDescriptor? {
        let candidates = organize(modes).filter { $0.width == spec.width && $0.height == spec.height }
        let scaled = candidates.filter { spec.hiDPI == nil || $0.isHiDPI == spec.hiDPI }
        guard !scaled.isEmpty else { return nil }
        let targetRate = spec.refreshRate ?? current?.refreshRate
        guard let targetRate else { return scaled.first }
        return scaled.min { abs($0.refreshRate - targetRate) < abs($1.refreshRate - targetRate) }
    }
}

/// A requested mode, parsed from text like "1920x1080", "2560x1440@144" or "1512x982@120 hidpi".
public struct ModeSpec: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double?
    /// nil = no preference.
    public var hiDPI: Bool?

    public init(width: Int, height: Int, refreshRate: Double? = nil, hiDPI: Bool? = nil) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }

    public init?(_ text: String) {
        let lowered = text.lowercased()
        let sizeAndRate = lowered.split(separator: "@", maxSplits: 1)
        guard let sizePart = sizeAndRate.first else { return nil }
        let size = sizePart.split(separator: "x")
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        if sizeAndRate.count == 2 {
            let rateText = sizeAndRate[1].hasSuffix("hz") ? sizeAndRate[1].dropLast(2) : sizeAndRate[1]
            guard let rate = Double(rateText), rate > 0 else { return nil }
            refreshRate = rate
        }
    }
}
