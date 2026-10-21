import AppKit
import CoreGraphics
import DisplayMonkCore

/// A snapshot of an online display.
public struct Display: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32
    public let unitNumber: UInt32

    init(id: CGDirectDisplayID) {
        self.id = id
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        isMain = CGDisplayIsMain(id) != 0
        vendorID = CGDisplayVendorNumber(id)
        modelID = CGDisplayModelNumber(id)
        serialNumber = CGDisplaySerialNumber(id)
        unitNumber = CGDisplayUnitNumber(id)
        name = Self.localizedName(for: id) ?? (isBuiltIn ? "Built-in Display" : "Display \(id)")
    }

    /// Survives reconnects and reboots, unlike `id`. Identical monitors without serial numbers
    /// fall back to the unit number to stay distinct.
    public var persistentKey: String {
        let base = "\(vendorID)-\(modelID)"
        return serialNumber != 0 ? "\(base)-\(serialNumber)" : "\(base)-u\(unitNumber)"
    }

    public var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    var selectable: SelectableDisplay {
        SelectableDisplay(id: id, name: name, isMain: isMain, isBuiltIn: isBuiltIn)
    }

    private static func localizedName(for id: CGDirectDisplayID) -> String? {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen.localizedName
        }
        if let names = PrivateAPI.displayInfo(id)?["DisplayProductName"] as? [String: String] {
            return names["en_US"] ?? names.values.first
        }
        return nil
    }
}

extension NSScreen {
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen under the mouse pointer.
    public static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
