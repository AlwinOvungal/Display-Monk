import CoreGraphics
import Foundation
import IOKit

/// Private symbols used by DisplayKit, resolved at runtime with `dlsym` instead of being linked.
/// If Apple removes or renames one, the feature that needs it reports itself unavailable and the
/// app still launches.
enum PrivateAPI {
    private static let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let coreGraphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    private static let coreDisplay = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private static func load<T>(_ name: String, from image: String) -> T? {
        guard let handle = dlopen(image, RTLD_LAZY), let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    // IOAVService is a CFType; it is passed around as an opaque pointer here and retained by `AVService`.
    typealias IOAVServiceCreateWithService = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    typealias IOAVServiceI2C = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias CoreDisplayCreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> UnsafeMutableRawPointer?
    typealias DisplayServicesGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias DisplayServicesSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CGSServiceForDisplayNumber = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<io_service_t>) -> Void

    static let ioAVServiceCreateWithService: IOAVServiceCreateWithService? = load("IOAVServiceCreateWithService", from: ioKit)
    static let ioAVServiceReadI2C: IOAVServiceI2C? = load("IOAVServiceReadI2C", from: ioKit)
    static let ioAVServiceWriteI2C: IOAVServiceI2C? = load("IOAVServiceWriteI2C", from: ioKit)
    static let coreDisplayCreateInfoDictionary: CoreDisplayCreateInfoDictionary? = load("CoreDisplay_DisplayCreateInfoDictionary", from: coreDisplay)
    static let displayServicesGetBrightness: DisplayServicesGetBrightness? = load("DisplayServicesGetBrightness", from: displayServices)
    static let displayServicesSetBrightness: DisplayServicesSetBrightness? = load("DisplayServicesSetBrightness", from: displayServices)
    static let cgsServiceForDisplayNumber: CGSServiceForDisplayNumber? = load("CGSServiceForDisplayNumber", from: coreGraphics)

    /// CoreDisplay's info dictionary for a display (product names, IODisplayLocation, EDID fields).
    static func displayInfo(_ display: CGDirectDisplayID) -> [String: Any]? {
        guard let create = coreDisplayCreateInfoDictionary, let raw = create(display) else { return nil }
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        return dictionary as? [String: Any]
    }
}

/// Reads a registry property and bridges it to a Swift value.
func registryProperty<T>(_ entry: io_registry_entry_t, _ key: String, as _: T.Type = T.self) -> T? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
}

func registryName(_ entry: io_registry_entry_t) -> String? {
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { buffer.deallocate() }
    guard IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS else { return nil }
    return String(cString: buffer)
}

func registryPath(_ entry: io_registry_entry_t) -> String? {
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
    defer { buffer.deallocate() }
    guard IORegistryEntryGetPath(entry, kIOServicePlane, buffer) == KERN_SUCCESS else { return nil }
    return String(cString: buffer)
}
