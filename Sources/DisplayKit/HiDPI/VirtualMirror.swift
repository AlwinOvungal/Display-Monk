import CGVirtualDisplayBridge
import CoreGraphics
import DisplayMonkCore
import Foundation

/// HiDPI without a restart: a virtual screen renders the desktop at twice the chosen size, and
/// the physical display mirrors it. The physical display is kept at its native unscaled mode,
/// so the monitor receives its normal signal and macOS scales the image onto the real panel.
/// Works where display overrides are ignored (M4/M5 Macs), but only while the app runs. If it
/// quits or crashes, macOS removes the virtual screen.
public final class VirtualMirror {
    /// Vendor number given to Display Monk's virtual screens, so they can be recognised and hidden.
    public static let vendorID: UInt32 = 0xD15C

    private static var active: [CGDirectDisplayID: VirtualMirror] = [:]
    private static var transitions: Set<CGDirectDisplayID> = []

    public let physicalID: CGDirectDisplayID
    public let sizes: [LogicalSize]
    private let virtualDisplay: CGVirtualDisplay
    /// Where the physical display sat before mirroring; the virtual screen takes its place.
    private let origin: CGPoint

    public var virtualID: CGDirectDisplayID { virtualDisplay.displayID }

    private init(physical: Display, sizes: [LogicalSize], refreshRate: Double) throws {
        guard let largest = sizes.max(by: { $0.width < $1.width }) else {
            throw DisplayKitError.unavailable("a native resolution for this display")
        }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Display Monk HiDPI – \(physical.name)"
        descriptor.maxPixelsWide = UInt32(largest.width * 2)
        descriptor.maxPixelsHigh = UInt32(largest.height * 2)
        let millimetres = CGDisplayScreenSize(physical.id)
        descriptor.sizeInMillimeters = millimetres.width > 0 ? millimetres : CGSize(width: 600, height: 340)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = physical.modelID & 0xFFFF
        descriptor.serialNum = physical.id

        let virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Modes are framebuffer sizes; with hiDPI set, macOS offers each at half size as a HiDPI mode.
        settings.modes = sizes.map {
            CGVirtualDisplayMode(width: UInt($0.width * 2), height: UInt($0.height * 2), refreshRate: refreshRate)
        }
        guard virtualDisplay.displayID != 0, virtualDisplay.apply(settings) else {
            throw DisplayKitError.unavailable("Virtual screens")
        }
        physicalID = physical.id
        self.sizes = sizes
        self.virtualDisplay = virtualDisplay
        origin = CGDisplayBounds(physical.id).origin
    }

    // MARK: Registry (main thread only)

    public static func isActive(for physicalID: CGDirectDisplayID) -> Bool {
        active[physicalID] != nil
    }

    /// True while HiDPI is being switched on or off for this display. New requests are ignored
    /// until it settles, so quick off/on toggles can't overlap.
    public static func isBusy(_ physicalID: CGDirectDisplayID) -> Bool {
        transitions.contains(physicalID)
    }

    /// Creates the virtual screen in the physical display's place, mirrors the display from it,
    /// keeps the display at its native mode and switches the desktop to `initialSize`.
    public static func enable(
        for display: Display,
        sizes: [LogicalSize],
        initialSize: LogicalSize?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard active[display.id] == nil, !transitions.contains(display.id) else { return completion(.success(())) }
        let refreshRate = DisplayModes.native(for: display.id)?.refreshRate ?? DisplayModes.current(for: display.id)?.refreshRate ?? 60
        let mirror: VirtualMirror
        do {
            mirror = try VirtualMirror(physical: display, sizes: sizes, refreshRate: refreshRate > 0 ? refreshRate : 60)
        } catch {
            return completion(.failure(error))
        }
        active[display.id] = mirror
        transitions.insert(display.id)
        mirror.startMirroring(attempt: 0, initialSize: initialSize) { result in
            if case .failure = result {
                Self.active[display.id] = nil
            }
            // Let the reconfiguration settle before accepting another change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Self.transitions.remove(display.id)
                completion(result)
            }
        }
    }

    /// Stops mirroring, removes the virtual screen and puts the display back at its native
    /// resolution, in the place the virtual screen occupied.
    public static func disable(for physicalID: CGDirectDisplayID, completion: (() -> Void)? = nil) {
        guard let mirror = active[physicalID], !transitions.contains(physicalID) else {
            completion?()
            return
        }
        transitions.insert(physicalID)
        let place = CGDisplayBounds(mirror.virtualID).origin
        _ = configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, physicalID, kCGNullDirectDisplay)
        }
        // Releasing the object removes the virtual screen.
        active[physicalID] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.restoreNative(physicalID, at: place)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Self.transitions.remove(physicalID)
                completion?()
            }
        }
    }

    /// Drops virtual screens whose physical display was unplugged, so no phantom display is left.
    public static func pruneDisconnected() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        let online = Set(ids.prefix(Int(count)))
        for physicalID in Array(active.keys) where !online.contains(physicalID) {
            active[physicalID] = nil
            transitions.remove(physicalID)
        }
    }

    /// Synchronous version for quitting: there is no time to wait for macOS to settle.
    public static func disableAll() {
        for (physicalID, mirror) in active {
            let place = CGDisplayBounds(mirror.virtualID).origin
            _ = configure { config in
                CGConfigureDisplayMirrorOfDisplay(config, physicalID, kCGNullDirectDisplay)
            }
            active[physicalID] = nil
            restoreNative(physicalID, at: place)
        }
    }

    /// Recovery for a display left in a wrong state (for example after a crash, or by another
    /// app): stops any mirroring involving it and applies its native unscaled resolution.
    public static func reset(_ physicalID: CGDirectDisplayID) {
        if active[physicalID] != nil {
            transitions.remove(physicalID)
            disable(for: physicalID)
            return
        }
        if CGDisplayMirrorsDisplay(physicalID) != kCGNullDirectDisplay {
            _ = configure { config in
                CGConfigureDisplayMirrorOfDisplay(config, physicalID, kCGNullDirectDisplay)
            }
        }
        restoreNative(physicalID, at: nil)
    }

    private static func restoreNative(_ physicalID: CGDirectDisplayID, at place: CGPoint?) {
        if let native = DisplayModes.native(for: physicalID) {
            try? DisplayModes.apply(native, to: physicalID)
        }
        if let place {
            _ = configure { config in
                CGConfigureDisplayOrigin(config, physicalID, Int32(place.x), Int32(place.y))
            }
        }
    }

    // MARK: Mirroring

    private func startMirroring(attempt: Int, initialSize: LogicalSize?, completion: @escaping (Result<Void, Error>) -> Void) {
        let virtualID = virtualID
        let physicalID = physicalID
        let origin = origin
        let error = Self.configure { config in
            let error = CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)
            guard error == .success else { return error }
            // Put the virtual screen where the display was, so the arrangement doesn't change.
            return CGConfigureDisplayOrigin(config, virtualID, Int32(origin.x), Int32(origin.y))
        }
        guard error == .success else {
            guard attempt < 10 else {
                return completion(.failure(DisplayKitError.configurationFailed(error)))
            }
            // The new screen takes a moment to come online.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startMirroring(attempt: attempt + 1, initialSize: initialSize, completion: completion)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // macOS may switch the mirroring display to a lower mode; keep it at its native
            // resolution so the scaled image is sharp and the monitor gets its normal signal.
            if let native = DisplayModes.native(for: physicalID), DisplayModes.current(for: physicalID)?.id != native.id {
                try? DisplayModes.apply(native, to: physicalID)
            }
            let modes = DisplayModes.available(for: virtualID)
            if let initialSize, let mode = ModeList.closestHiDPI(to: initialSize, in: modes, current: nil) {
                try? DisplayModes.apply(mode, to: virtualID)
            }
            completion(.success(()))
        }
    }

    private static func configure(_ body: (CGDisplayConfigRef) -> CGError) -> CGError {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { return error }
        error = body(config)
        guard error == .success else {
            _ = CGCancelDisplayConfiguration(config)
            return error
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }
}
