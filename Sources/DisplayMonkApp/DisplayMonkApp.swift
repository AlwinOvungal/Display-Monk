import AppKit
import DisplayKit
import ServiceManagement
import SwiftUI

@main
struct DisplayMonkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DisplayStore.shared

    var body: some Scene {
        MenuBarExtra("Display Monk", systemImage: "sun.max") {
            MenuView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        // Menu bar only, even when run unbundled with `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Preferences.registerDefaults()
    }

    func applicationDidFinishLaunching(_: Notification) {
        DisplayStore.shared.reload()
        DisplayManager.shared.observeChanges { DisplayStore.shared.reload() }
        MediaKeyTap.shared.update()
    }

    func applicationWillTerminate(_: Notification) {
        SoftwareDimmer.restoreAll()
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, which stays unchanged if registration fails (for example
    /// when running unbundled).
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Display Monk: could not change login item: \(error)")
        }
        return isEnabled
    }
}
