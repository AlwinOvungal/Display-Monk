import CGVirtualDisplayBridge
import CoreGraphics
import DisplayMonkCore
import Foundation

/// HiDPI without a restart: a virtual screen renders the desktop at twice the chosen size, and
/// the physical display mirrors it. The monitor keeps receiving its normal signal; macOS scales
/// the image. Works where display overrides are ignored (M4/M5 Macs), but only while the app
/// runs. If it quits or crashes, macOS removes the virtual screen and the display returns to
/// normal by itself.
public final class VirtualMirror {
    /// Vendor number given to Display Monk's virtual screens, so they can be recognised and hidden.
    public static let vendorID: UInt32 = 0xD15C

    private static var active: [CGDirectDisplayID: VirtualMirror] = [:]

    public let physicalID: CGDirectDisplayID
    public let sizes: [LogicalSize]
    private let virtualDisplay: CGVirtualDisplay

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
    }

    // MARK: Registry (main thread only)

    public static func isActive(for physicalID: CGDirectDisplayID) -> Bool {
        active[physicalID] != nil
    }

    /// Creates the virtual screen, mirrors `display` from it and switches to `initialSize`.
    /// The new screen takes a moment to come online, so mirroring is retried briefly.
    public static func enable(
        for display: Display,
        sizes: [LogicalSize],
        initialSize: LogicalSize?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard active[display.id] == nil else { return completion(.success(())) }
        let refreshRate = DisplayModes.current(for: display.id)?.refreshRate ?? 60
        let mirror: VirtualMirror
        do {
            mirror = try VirtualMirror(physical: display, sizes: sizes, refreshRate: refreshRate > 0 ? refreshRate : 60)
        } catch {
            return completion(.failure(error))
        }
        active[display.id] = mirror
        mirror.startMirroring(attempt: 0, initialSize: initialSize, completion: completion)
    }

    public static func disable(for physicalID: CGDirectDisplayID) {
        guard let mirror = active.removeValue(forKey: physicalID) else { return }
        mirror.stopMirroring()
    }

    public static func disableAll() {
        for physicalID in Array(active.keys) {
            disable(for: physicalID)
        }
    }

    // MARK: Mirroring

    private func startMirroring(attempt: Int, initialSize: LogicalSize?, completion: @escaping (Result<Void, Error>) -> Void) {
        let error = configureMirror(of: physicalID, source: virtualID)
        if error == .success {
            if let initialSize, let mode = DisplayModes.available(for: virtualID).first(where: {
                $0.isHiDPI && $0.width == initialSize.width && $0.height == initialSize.height
            }) {
                try? DisplayModes.apply(mode, to: virtualID)
            }
            return completion(.success(()))
        }
        guard attempt < 10 else {
            Self.active[physicalID] = nil
            return completion(.failure(DisplayKitError.configurationFailed(error)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startMirroring(attempt: attempt + 1, initialSize: initialSize, completion: completion)
        }
    }

    private func stopMirroring() {
        _ = configureMirror(of: physicalID, source: kCGNullDirectDisplay)
        // Releasing `virtualDisplay` (when this object is freed) removes the virtual screen.
    }

    private func configureMirror(of display: CGDirectDisplayID, source: CGDirectDisplayID) -> CGError {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { return error }
        error = CGConfigureDisplayMirrorOfDisplay(config, display, source)
        guard error == .success else {
            _ = CGCancelDisplayConfiguration(config)
            return error
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }
}
