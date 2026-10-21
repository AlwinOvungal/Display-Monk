import AppKit
import CoreGraphics
import DisplayMonkCore
import Foundation

public enum OverrideStatus: Equatable, Sendable {
    case notInstalled
    /// Written by Display Monk.
    case installed
    /// Written by something else, e.g. BetterDisplay or a script.
    case foreign
}

/// Installs and removes the display override that adds HiDPI modes. macOS reads it at boot, so
/// changes take effect at the next restart (the app uses a virtual screen until then). Only scaled desktop sizes are added; the monitor's
/// timing, refresh rate and EDID are left alone.
public enum OverrideInstaller {
    static let markerKey = "DisplayMonkManaged"

    public static func path(for display: Display) -> String {
        HiDPIOverride.overridesDirectory + "/" + HiDPIOverride.relativePath(vendorID: display.vendorID, productID: display.modelID)
    }

    public static func status(for display: Display) -> OverrideStatus {
        guard let plist = readPlist(atPath: path(for: display)) else { return .notInstalled }
        return plist[markerKey] as? Bool == true ? .installed : .foreign
    }

    /// The panel's native resolution: the largest mode that isn't scaled.
    public static func nativeSize(for display: Display) -> LogicalSize? {
        let modes = DisplayModes.all(for: display.id).map(DisplayModes.descriptor).filter { !$0.isHiDPI }
        guard let largest = modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else {
            return nil
        }
        return LogicalSize(width: largest.pixelWidth, height: largest.pixelHeight)
    }

    public static func presetSizes(for display: Display) -> [LogicalSize] {
        guard let native = nativeSize(for: display) else { return [] }
        return HiDPIOverride.presetSizes(nativeWidth: native.width, nativeHeight: native.height)
    }

    /// The HiDPI size that matches the UI density of Apple's own displays (see
    /// `HiDPIOverride.defaultSize`), e.g. 2560x1440 on a 27" QHD panel.
    public static func defaultHiDPISize(for display: Display) -> LogicalSize? {
        guard let native = nativeSize(for: display) else { return nil }
        let widthMM = Double(CGDisplayScreenSize(display.id).width)
        return HiDPIOverride.defaultSize(in: presetSizes(for: display), native: native, physicalWidthMM: widthMM)
    }

    /// True once macOS offers HiDPI sizes beyond the usual half-native one.
    public static func hasExtendedHiDPIModes(for display: Display) -> Bool {
        guard let native = nativeSize(for: display) else { return false }
        return DisplayModes.available(for: display.id).contains { $0.isHiDPI && $0.width > native.width / 2 }
    }

    /// The override plist. An existing file from another tool is kept and extended, so its
    /// settings survive; a backup is made before installing anyway.
    static func plistData(for display: Display) throws -> Data {
        let sizes = presetSizes(for: display)
        guard !sizes.isEmpty else { throw DisplayKitError.unavailable("a native resolution for this display") }
        var plist = readPlist(atPath: path(for: display)) ?? [:]
        let existing = plist["scale-resolutions"] as? [Data] ?? []
        let added = sizes.map { Data(HiDPIOverride.scaleResolutionEntry($0)) }.filter { !existing.contains($0) }
        plist["DisplayVendorID"] = Int(display.vendorID)
        plist["DisplayProductID"] = Int(display.modelID)
        if plist["DisplayProductName"] == nil { plist["DisplayProductName"] = display.name }
        plist["scale-resolutions"] = existing + added
        plist[markerKey] = true
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Asks for an administrator password (unless running as root) and writes the override.
    public static func install(for display: Display) throws {
        let destination = path(for: display)
        let data = try plistData(for: display)
        if status(for: display) == .foreign {
            let backup = backupURL(for: display)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(atPath: destination, toPath: backup.path)
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("displaymonk-\(UUID().uuidString).plist")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let q = Privileged.quote
        try Privileged.run([
            "mkdir -p \(q((destination as NSString).deletingLastPathComponent))",
            "cp \(q(temporary.path)) \(q(destination))",
            "chown root:wheel \(q(destination))",
            "chmod 644 \(q(destination))",
            "defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES",
        ].joined(separator: " && "))
    }

    /// Restores another tool's original file if one was backed up, otherwise deletes the
    /// override. Files Display Monk didn't write are never touched.
    public static func remove(for display: Display) throws {
        guard status(for: display) == .installed else { return }
        let destination = path(for: display)
        let backup = backupURL(for: display)
        let q = Privileged.quote
        if FileManager.default.fileExists(atPath: backup.path) {
            try Privileged.run([
                "cp \(q(backup.path)) \(q(destination))",
                "chown root:wheel \(q(destination))",
                "chmod 644 \(q(destination))",
            ].joined(separator: " && "))
            try? FileManager.default.removeItem(at: backup)
        } else {
            let directory = (destination as NSString).deletingLastPathComponent
            try Privileged.run("rm -f \(q(destination)) && (rmdir \(q(directory)) 2>/dev/null || true)")
        }
    }

    static func backupURL(for display: Display) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = HiDPIOverride.relativePath(vendorID: display.vendorID, productID: display.modelID).replacingOccurrences(of: "/", with: "_")
        return support.appendingPathComponent("DisplayMonk/OverrideBackups/\(name).plist")
    }

    private static func readPlist(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Runs a shell command as root: directly when already root (the CLI under sudo), otherwise
/// through the standard macOS administrator password prompt.
public enum Privileged {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The user dismissed the password prompt.
        case cancelled
        case failed(String)

        public var description: String {
            switch self {
            case .cancelled: "cancelled"
            case let .failed(message): message
            }
        }
    }

    static func run(_ command: String) throws {
        if geteuid() == 0 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.failed("command failed (\(process.terminationStatus))") }
            return
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw Failure.failed("could not prepare the administrator prompt")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw Failure.cancelled }
            throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
