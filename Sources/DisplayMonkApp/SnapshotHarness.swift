import AppKit
import CGVirtualDisplayBridge
import SwiftUI

/// THROWAWAY verification harness (never merged). Adds a real second display with
/// CGVirtualDisplay, drives DisplayStore's sync through the scenarios, logs PASS/FAIL, and
/// renders MenuView in each state to PNG.
enum SnapshotHarness {
    private static var second: CGVirtualDisplay?
    private static var dir = ""
    private static var log: [String] = []

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["DISPLAYMONK_SNAPSHOT_DIR"] else { return }
        self.dir = dir
        say("displays at launch: \(names())")
        addSecondDisplay()
        steps([
            (4, { reload("second display added") }),
            (2, { capture("1-two-displays-unsynced") }),
            (0.5, unsyncedIndependence),
            (1, { enableSync() }),
            (1.5, { capture("2-synced-light") }),
            (0.5, { capture("3-synced-dark", dark: true) }),
            (0.5, bothDirections),
            (1, { drift() }),
            (0.5, { capture("4-not-matched") }),
            (1.5, { DisplayStore.shared.matchAll(); check("Match aligns everyone", matched()) }),
            (1, detach),
            (1, { capture("5-detached") }),
            (1.5, { expandAll(); }),
            (1.5, { capture("6-expanded") }),
            (1.5, { capture("6b-expanded-dark", dark: true) }),
            (0.5, disconnectWhileSynced),
            (4, { reload("after disconnect"); }),
            (2, { check("one display after disconnect", DisplayStore.shared.displays.count == 1); capture("7-one-display-sync-on") }),
            (0.5, { setFirst(0.35); addSecondDisplay() }),
            (4, { reload("after reconnect") }),
            (3, { check("reconnected display took the connected display's level", matched(), detail: levels()); capture("8-reconnected") }),
            (2, finish),
        ])
    }

    // MARK: Scenarios

    private static var store: DisplayStore { .shared }

    private static func unsyncedIndependence() {
        guard store.displays.count == 2 else { return check("two displays", false, detail: names()) }
        store.setSyncEnabled(false)
        let b = store.displays[1].brightness
        store.setBrightness(0.42, for: store.displays[0])
        check("sync off: A changes alone", abs(store.displays[1].brightness - b) < 0.001, detail: levels())
    }

    private static func enableSync() {
        store.setBrightness(0.9, for: store.displays[1])
        store.setSyncEnabled(true)
        check("sync on: matched to reference", matched(), detail: levels())
    }

    private static func bothDirections() {
        store.setBrightness(0.3, for: store.displays[0])
        check("sync on: A → B", matched() && abs(store.displays[1].brightness - 0.3) < 0.001, detail: levels())
        store.setBrightness(0.75, for: store.displays[1])
        check("sync on: B → A", matched() && abs(store.displays[0].brightness - 0.75) < 0.001, detail: levels())
        check("toggle state unchanged by brightness", store.sync.isEnabled)
    }

    private static func drift() {
        // Simulates a change made outside the app: set one display without going through sync.
        store.displays[0].setBrightness(0.5)
        check("drift shows Not matched", !store.isSyncMatched, detail: levels())
    }

    private static func detach() {
        let before = store.displays.map(\.brightness)
        store.setSyncEnabled(false)
        check("detach keeps levels", store.displays.map(\.brightness) == before, detail: levels())
        store.setBrightness(0.2, for: store.displays[0])
        check("detached: B unchanged", abs(store.displays[1].brightness - before[1]) < 0.001, detail: levels())
        store.setBrightness(0.6, for: store.displays[1])
        check("detached: A unchanged", abs(store.displays[0].brightness - 0.2) < 0.001, detail: levels())
    }

    private static func expandAll() {
        UserDefaults.standard.set(store.displays.map(\.display.persistentKey).joined(separator: ","), forKey: "expandedDisplays")
    }

    private static func disconnectWhileSynced() {
        UserDefaults.standard.set("", forKey: "expandedDisplays")
        store.setSyncEnabled(true)
        second = nil
    }

    private static func setFirst(_ level: Double) {
        store.setBrightness(level, for: store.displays[0])
    }

    private static func finish() {
        let text = log.joined(separator: "\n") + "\n"
        try? text.write(toFile: dir + "/results.txt", atomically: true, encoding: .utf8)
        print(text)
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private static func addSecondDisplay() {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Studio Monitor With A Rather Long Product Name 27"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.vendorID = 0x1E6D
        descriptor.productID = 0x5B11
        descriptor.serialNum = 4242
        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60),
        ]
        say("virtual display id \(display.displayID) applied \(display.apply(settings))")
        second = display
    }

    private static func reload(_ label: String) {
        store.reload()
        say("\(label): \(names())")
    }

    private static func matched() -> Bool {
        BrightnessSyncCheck.matched(store.displays.map(\.brightness))
    }

    private static func levels() -> String {
        store.displays.map { "\($0.display.name)=\(Int(($0.brightness * 100).rounded()))%(\($0.brightnessMethod.rawValue))" }.joined(separator: ", ")
    }

    private static func names() -> String {
        store.displays.map(\.display.name).joined(separator: " | ")
    }

    private static func check(_ name: String, _ ok: Bool, detail: String = "") {
        say("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func say(_ line: String) {
        log.append(line)
        NSLog("HARNESS %@", line)
    }

    private static func steps(_ list: [(Double, () -> Void)]) {
        var delay = 0.0
        for (wait, action) in list {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private static func capture(_ name: String, dark: Bool = false) {
        let host = NSHostingView(rootView: MenuView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 340, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                // cacheDisplay leaves the window background out; put the view on one.
                let image = NSImage(size: host.bounds.size)
                image.lockFocus()
                (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSRect(origin: .zero, size: host.bounds.size).fill()
                rep.draw(in: NSRect(origin: .zero, size: host.bounds.size))
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                say("captured \(name) \(Int(host.bounds.width))×\(Int(host.bounds.height))")
            }
            window.orderOut(nil)
        }
    }
}

private enum BrightnessSyncCheck {
    static func matched(_ levels: [Double]) -> Bool {
        guard let low = levels.min(), let high = levels.max() else { return true }
        return high - low <= 0.005
    }
}
