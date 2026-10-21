import CoreGraphics
import DisplayMonkCore

/// Moves displays relative to each other. Only the desktop layout changes; nothing is sent to
/// the monitors.
public enum DisplayArrangement {
    public static func rect(of display: Display) -> DisplayRect {
        let bounds = CGDisplayBounds(display.modeTarget)
        return DisplayRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    public static func placement(of display: Display, relativeTo reference: Display) -> (Placement, PlacementAlignment)? {
        Arrangement.placement(of: rect(of: display), relativeTo: rect(of: reference))
    }

    public static func nearestPlacement(of display: Display, relativeTo reference: Display) -> Placement {
        Arrangement.nearestPlacement(of: rect(of: display), relativeTo: rect(of: reference))
    }

    public static func move(_ display: Display, _ placement: Placement, _ alignment: PlacementAlignment, relativeTo reference: Display) throws {
        let current = rect(of: display)
        let origin = Arrangement.origin(width: current.width, height: current.height, placement, alignment, relativeTo: rect(of: reference))
        try configure { config in
            CGConfigureDisplayOrigin(config, display.modeTarget, Int32(origin.x), Int32(origin.y))
        }
    }

    /// Makes `display` the main display (menu bar and Dock) by moving it to the origin.
    public static func makeMain(_ display: Display, among displays: [Display]) throws {
        guard let index = displays.firstIndex(where: { $0.id == display.id }) else { return }
        let origins = Arrangement.originsMakingMain(index, rects: displays.map(rect(of:)))
        try configure { config in
            for (display, origin) in zip(displays, origins) {
                let error = CGConfigureDisplayOrigin(config, display.modeTarget, Int32(origin.x), Int32(origin.y))
                if error != .success { return error }
            }
            return .success
        }
    }

    private static func configure(_ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw DisplayKitError.configurationFailed(error) }
        error = body(config)
        guard error == .success else {
            _ = CGCancelDisplayConfiguration(config)
            throw DisplayKitError.configurationFailed(error)
        }
        error = CGCompleteDisplayConfiguration(config, .permanently)
        guard error == .success else { throw DisplayKitError.configurationFailed(error) }
    }
}
