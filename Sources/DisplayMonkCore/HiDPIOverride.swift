/// A desktop size in points.
public struct LogicalSize: Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String {
        "\(width)x\(height)"
    }
}

/// Display override files: plists under /Library/Displays/Contents/Resources/Overrides that
/// WindowServer reads at boot. Their `scale-resolutions` entries add HiDPI modes, which are only
/// framebuffer sizes macOS renders and scales down. The signal sent to the monitor never changes.
public enum HiDPIOverride {
    public static let overridesDirectory = "/Library/Displays/Contents/Resources/Overrides"

    /// One `scale-resolutions` entry: framebuffer width and height (twice the logical size) and
    /// the HiDPI flag, each a big-endian UInt32.
    public static func scaleResolutionEntry(_ size: LogicalSize) -> [UInt8] {
        let words: [UInt32] = [UInt32(size.width * 2), UInt32(size.height * 2), 1]
        return words.flatMap { (value: UInt32) -> [UInt8] in
            [24, 16, 8, 0].map { (shift: UInt32) -> UInt8 in UInt8(truncatingIfNeeded: value >> shift) }
        }
    }

    /// "DisplayVendorID-1e6d/DisplayProductID-7750", relative to `overridesDirectory`.
    public static func relativePath(vendorID: UInt32, productID: UInt32) -> String {
        "DisplayVendorID-\(String(vendorID, radix: 16))/DisplayProductID-\(String(productID, radix: 16))"
    }

    /// HiDPI desktop sizes with the panel's aspect ratio, from half the native width up to the
    /// native width in 64-point steps. Sizes stay within the native resolution (the largest
    /// macOS accepts) and within `maxFramebufferWidth`, a GPU limit.
    public static func presetSizes(nativeWidth: Int, nativeHeight: Int, maxFramebufferWidth: Int = 7680) -> [LogicalSize] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let limit = min(nativeWidth, maxFramebufferWidth / 2)
        func size(_ width: Int) -> LogicalSize {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth) / 2).rounded()) * 2
            return LogicalSize(width: width, height: height)
        }
        var sizes: [LogicalSize] = []
        var width = nativeWidth / 2 / 2 * 2
        while width < limit {
            sizes.append(size(width))
            width = (width / 64 + 1) * 64
        }
        sizes.append(size(limit / 2 * 2))
        return sizes
    }

    /// Apple's desktop UI density in points per inch: the 27" Studio Display looks like
    /// 2560x1440 and the 32" Pro Display XDR like 3008x1692, both about 110.
    public static let appleDesktopPointsPerInch = 110.0

    /// The default HiDPI size wherever a panel offers it: every 16:9 panel from 1600 to 3200
    /// pixels wide, such as 2K monitors.
    public static let preferredDefault = LogicalSize(width: 1600, height: 900)

    /// The size HiDPI starts at: `preferredDefault` when the display has it. Otherwise (4K, where
    /// 1600x900 would be stretched up and blurry, or other aspect ratios) the size that makes
    /// the UI as large as on Apple's own displays, e.g. 2560x1440 on a 27" 4K panel. Without a
    /// physical size, the native size is used.
    public static func defaultSize(in sizes: [LogicalSize], native: LogicalSize, physicalWidthMM: Double?) -> LogicalSize? {
        if sizes.contains(preferredDefault) { return preferredDefault }
        let target: Double
        if let physicalWidthMM, physicalWidthMM > 0 {
            target = appleDesktopPointsPerInch * physicalWidthMM / 25.4
        } else {
            target = Double(native.width)
        }
        return sizes.min { abs(Double($0.width) - target) < abs(Double($1.width) - target) }
    }
}
