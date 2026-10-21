import CoreGraphics
import DisplayMonkCore
import Foundation

/// Lists displays and hands out controllers. DDC discovery walks the IORegistry, so channels
/// are cached until the display configuration changes.
public final class DisplayManager {
    public static let shared = DisplayManager()

    private let lock = NSLock()
    private var channels: [CGDirectDisplayID: DDCChannel]?
    private var channelsDisplayIDs: Set<CGDirectDisplayID> = []
    private var changeHandler: (() -> Void)?
    private var pendingChange: DispatchWorkItem?

    private init() {}

    /// Connected physical displays: built-in first, then left to right. Displays mirroring
    /// another display are left out, except those mirroring a Display Monk HiDPI virtual
    /// screen, which is itself hidden.
    public func displays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let online = Array(ids.prefix(Int(count)))
        let virtualScreens = Set(online.filter { CGDisplayVendorNumber($0) == VirtualMirror.vendorID })
        return online
            .compactMap { id -> Display? in
                guard !virtualScreens.contains(id) else { return nil }
                let master = CGDisplayMirrorsDisplay(id)
                if master == kCGNullDirectDisplay { return Display(id: id) }
                return virtualScreens.contains(master) ? Display(id: id, modeTarget: master) : nil
            }
            .sorted { a, b in
                if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
                return CGDisplayBounds(a.modeTarget).minX < CGDisplayBounds(b.modeTarget).minX
            }
    }

    public func controllers() -> [DisplayController] {
        let displays = displays()
        let channels = channels(for: displays)
        return displays.map { DisplayController(display: $0, ddc: channels[$0.id]) }
    }

    /// Resolves a command-line selector against the current display list.
    public func controller(matching selector: DisplaySelector) -> DisplayController? {
        let all = controllers()
        return selector.resolve(in: all.map(\.display.selectable)).map { all[$0] }
    }

    public func invalidate() {
        lock.lock()
        channels = nil
        lock.unlock()
    }

    private func channels(for displays: [Display]) -> [CGDirectDisplayID: DDCChannel] {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(displays.map(\.id))
        if let channels, ids == channelsDisplayIDs {
            return channels
        }
        let discovered = DDCChannels.discover(for: displays)
        channels = discovered
        channelsDisplayIDs = ids
        return discovered
    }

    /// Calls `handler` on the main queue once a burst of reconfiguration events (plugging,
    /// waking, changing modes) has settled. Channels are invalidated before it runs.
    public func observeChanges(_ handler: @escaping () -> Void) {
        let first = changeHandler == nil
        changeHandler = handler
        guard first else { return }
        _ = CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.scheduleChange() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.invalidate()
            self?.changeHandler?()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
