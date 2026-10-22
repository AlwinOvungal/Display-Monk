import CoreGraphics
import DisplayMonkCore
import Foundation

public enum DisplayKitError: Error, CustomStringConvertible {
    case modeNotFound
    case configurationFailed(CGError)
    case invalidRotation(Int)
    case unavailable(String)
    case timedOut

    public var description: String {
        switch self {
        case .modeNotFound: "mode not available on this display"
        case let .configurationFailed(error): "display configuration failed (CGError \(error.rawValue))"
        case let .invalidRotation(degrees): "rotation must be 0, 90, 180 or 270 (got \(degrees))"
        case let .unavailable(what): "\(what) is not available on this macOS version"
        case .timedOut: "timed out waiting for the display to change"
        }
    }
}

/// Resolution, HiDPI scaling and refresh rate through public CoreGraphics APIs.
public enum DisplayModes {
    /// Every mode, including the "duplicate" low-resolution variants that reveal HiDPI scaling.
    static func all(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    }

    public static func available(for display: CGDirectDisplayID, includeUnusable: Bool = false) -> [ModeDescriptor] {
        ModeList.organize(all(for: display).map(descriptor), includeUnusable: includeUnusable)
    }

    /// The panel's own unscaled mode: the largest non-HiDPI size, at the current refresh rate
    /// when the display is already at that size, otherwise at the highest rate.
    public static func native(for display: CGDirectDisplayID) -> ModeDescriptor? {
        let unscaled = available(for: display).filter { !$0.isHiDPI }
        guard let largest = unscaled.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else {
            return nil
        }
        let current = current(for: display).flatMap { $0.width == largest.width && $0.height == largest.height ? $0 : nil }
        return ModeList.bestMatch(for: ModeSpec(width: largest.width, height: largest.height, hiDPI: false), in: unscaled, current: current)
    }

    public static func current(for display: CGDirectDisplayID) -> ModeDescriptor? {
        CGDisplayCopyDisplayMode(display).map(descriptor)
    }

    public static func apply(_ mode: ModeDescriptor, to display: CGDirectDisplayID) throws {
        guard let target = all(for: display).first(where: { $0.ioDisplayModeID == mode.id }) else {
            throw DisplayKitError.modeNotFound
        }
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw DisplayKitError.configurationFailed(error) }
        error = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard error == .success else {
            _ = CGCancelDisplayConfiguration(config)
            throw DisplayKitError.configurationFailed(error)
        }
        error = CGCompleteDisplayConfiguration(config, .permanently)
        guard error == .success else { throw DisplayKitError.configurationFailed(error) }
    }

    static func descriptor(_ mode: CGDisplayMode) -> ModeDescriptor {
        ModeDescriptor(
            id: mode.ioDisplayModeID,
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            isUsableForDesktop: mode.isUsableForDesktopGUI()
        )
    }
}

/// Display rotation through the private MonitorPanel framework (what System Settings uses).
public enum DisplayRotation {
    private static let monitorPanel = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

    public static func current(for display: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(display))
    }

    /// Starts the rotation; it completes asynchronously. Pass `wait` to block until it has.
    public static func set(_ degrees: Int, for display: CGDirectDisplayID, wait timeout: TimeInterval = 0) throws {
        guard [0, 90, 180, 270].contains(degrees) else { throw DisplayKitError.invalidRotation(degrees) }
        guard dlopen(monitorPanel, RTLD_LAZY) != nil, let displayClass = NSClassFromString("MPDisplay") else {
            throw DisplayKitError.unavailable("MonitorPanel")
        }
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
        let orientationSelector = NSSelectorFromString("setOrientation:")
        guard let allocMethod = class_getClassMethod(displayClass, allocSelector),
              class_respondsToSelector(displayClass, initSelector),
              class_respondsToSelector(displayClass, orientationSelector),
              let initIMP = class_getMethodImplementation(displayClass, initSelector),
              let orientationIMP = class_getMethodImplementation(displayClass, orientationSelector)
        else { throw DisplayKitError.unavailable("MPDisplay") }

        // Objects are handled as raw pointers so retain counts follow the alloc/init convention exactly.
        typealias Alloc = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32) -> UnsafeMutableRawPointer?
        typealias SetOrientation = @convention(c) (UnsafeMutableRawPointer, Selector, Int32) -> Void

        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let classPointer = UnsafeRawPointer(Unmanaged.passUnretained(displayClass as AnyObject).toOpaque())
        guard let allocated = alloc(classPointer, allocSelector),
              let object = unsafeBitCast(initIMP, to: Init.self)(allocated, initSelector, display)
        else { throw DisplayKitError.unavailable("MPDisplay") }
        defer { Unmanaged<AnyObject>.fromOpaque(object).release() }
        unsafeBitCast(orientationIMP, to: SetOrientation.self)(object, orientationSelector, Int32(degrees))

        guard timeout > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while current(for: display) != degrees {
            guard Date() < deadline else { throw DisplayKitError.timedOut }
            usleep(100_000)
        }
    }
}
