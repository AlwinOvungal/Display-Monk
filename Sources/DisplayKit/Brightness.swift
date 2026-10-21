import CoreGraphics
import Foundation

/// How a display's brightness is changed.
public enum BrightnessMethod: String, CaseIterable, Sendable {
    /// Apple displays (built-in, Studio Display, Pro Display XDR) through DisplayServices.
    case native
    /// The monitor's own backlight over DDC/CI.
    case ddc
    /// Scaling the gamma table. Works everywhere but only darkens the image.
    case software
}

/// Backlight control for Apple displays through the private DisplayServices framework.
public enum NativeBrightness {
    public static func get(_ display: CGDirectDisplayID) -> Double? {
        guard let get = PrivateAPI.displayServicesGetBrightness else { return nil }
        var value: Float = -1
        guard get(display, &value) == 0, value >= 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    public static func set(_ value: Double, for display: CGDirectDisplayID) -> Bool {
        guard let set = PrivateAPI.displayServicesSetBrightness else { return false }
        return set(display, Float(min(1, max(0, value)))) == 0
    }
}

/// Dims a display by scaling its gamma table. macOS restores the original table when the
/// process that changed it exits, so this only lasts while the app is running.
public enum SoftwareDimmer {
    /// Never go fully black; a black screen with no visible controls is hard to recover from.
    public static let minimumLevel = 0.05

    private struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private static let lock = NSLock()
    private static var originals: [CGDirectDisplayID: GammaTable] = [:]
    private static var levels: [CGDirectDisplayID: Double] = [:]

    public static func level(for display: CGDirectDisplayID) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return levels[display] ?? 1
    }

    @discardableResult
    public static func setLevel(_ level: Double, for display: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let level = min(1, max(minimumLevel, level))
        guard let original = originals[display] ?? currentTable(display) else { return false }
        originals[display] = original
        let scale = CGGammaValue(level)
        let result = CGSetDisplayTransferByTable(
            display, UInt32(original.red.count),
            original.red.map { $0 * scale }, original.green.map { $0 * scale }, original.blue.map { $0 * scale }
        )
        guard result == .success else { return false }
        levels[display] = level
        return true
    }

    /// Re-applies dimming after a display reconfiguration, which may reset gamma tables. The
    /// originals captured before dimming are reused: re-reading them now could capture an
    /// already-dimmed table and compound the dimming.
    public static func reapply() {
        lock.lock()
        let current = levels
        lock.unlock()
        for (display, level) in current where level < 1 {
            setLevel(level, for: display)
        }
    }

    public static func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        originals.removeAll()
        levels.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    private static func currentTable(_ display: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 else {
            return nil
        }
        let used = Int(count)
        return GammaTable(red: Array(red.prefix(used)), green: Array(green.prefix(used)), blue: Array(blue.prefix(used)))
    }
}
