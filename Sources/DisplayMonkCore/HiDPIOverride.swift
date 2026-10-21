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

    /// The preset to switch to right after enabling HiDPI: about 80% of the native width,
    /// e.g. 2048x1152 on a 2560x1440 panel.
    public static func defaultSize(in sizes: [LogicalSize], nativeWidth: Int) -> LogicalSize? {
        let target = Double(nativeWidth) * 0.8
        return sizes.min { abs(Double($0.width) - target) < abs(Double($1.width) - target) }
    }
}
