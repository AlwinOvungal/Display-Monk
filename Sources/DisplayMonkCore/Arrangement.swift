/// A rectangle in CoreGraphics' global display space: points, origin at the main display's
/// top-left corner, y growing downward.
public struct DisplayRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct DisplayPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Which side of the reference display a display sits on.
public enum Placement: String, CaseIterable, Sendable {
    case left, right, above, below

    public var isHorizontal: Bool {
        self == .left || self == .right
    }
}

/// Where along that side: top/left, centre or bottom/right.
public enum PlacementAlignment: String, CaseIterable, Sendable {
    case start, center, end

    public func label(for placement: Placement) -> String {
        switch self {
        case .start: placement.isHorizontal ? "Top" : "Left"
        case .center: "Center"
        case .end: placement.isHorizontal ? "Bottom" : "Right"
        }
    }
}

public enum Arrangement {
    /// The origin that puts a display of the given size beside `reference`, edges touching.
    public static func origin(width: Double, height: Double, _ placement: Placement, _ alignment: PlacementAlignment, relativeTo reference: DisplayRect) -> DisplayPoint {
        func along(_ start: Double, _ referenceLength: Double, _ length: Double) -> Double {
            switch alignment {
            case .start: start
            case .center: (start + (referenceLength - length) / 2).rounded()
            case .end: start + referenceLength - length
            }
        }
        switch placement {
        case .left: return DisplayPoint(x: reference.x - width, y: along(reference.y, reference.height, height))
        case .right: return DisplayPoint(x: reference.maxX, y: along(reference.y, reference.height, height))
        case .above: return DisplayPoint(x: along(reference.x, reference.width, width), y: reference.y - height)
        case .below: return DisplayPoint(x: along(reference.x, reference.width, width), y: reference.maxY)
        }
    }

    /// The preset matching the current layout, or nil for a custom position (for example one
    /// dragged in System Settings). Centre is preferred when displays are the same size.
    public static func placement(of rect: DisplayRect, relativeTo reference: DisplayRect, tolerance: Double = 1) -> (Placement, PlacementAlignment)? {
        for placement in Placement.allCases {
            for alignment in [PlacementAlignment.center, .start, .end] {
                let origin = origin(width: rect.width, height: rect.height, placement, alignment, relativeTo: reference)
                if abs(origin.x - rect.x) <= tolerance, abs(origin.y - rect.y) <= tolerance {
                    return (placement, alignment)
                }
            }
        }
        return nil
    }

    /// The side a display is mostly on, used when its position doesn't match a preset.
    public static func nearestPlacement(of rect: DisplayRect, relativeTo reference: DisplayRect) -> Placement {
        let dx = (rect.midX - reference.midX) / max(1, reference.width + rect.width)
        let dy = (rect.midY - reference.midY) / max(1, reference.height + rect.height)
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .above : .below
    }

    /// New origins for every display so that `index` sits at (0, 0), which is what makes it the
    /// main display (menu bar and Dock). Relative positions are unchanged.
    public static func originsMakingMain(_ index: Int, rects: [DisplayRect]) -> [DisplayPoint] {
        guard rects.indices.contains(index) else { return rects.map { DisplayPoint(x: $0.x, y: $0.y) } }
        let shift = rects[index]
        return rects.map { DisplayPoint(x: $0.x - shift.x, y: $0.y - shift.y) }
    }
}
