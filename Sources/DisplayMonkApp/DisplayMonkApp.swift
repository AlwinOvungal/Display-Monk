import AppKit
import DisplayKit
import ServiceManagement
import SwiftUI

@main
struct DisplayMonkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DisplayStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
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
        DisplayStore.shared.restoreVirtualHiDPI()
        DisplayManager.shared.observeChanges { DisplayStore.shared.reload() }
        MediaKeyTap.shared.update()
        observeSleep()
        SnapshotHarness.runIfRequested()
    }

    func applicationWillTerminate(_: Notification) {
        VirtualMirror.disableAll()
        SoftwareDimmer.restoreAll()
    }

    /// No DDC while displays sleep, and none for 2 seconds after they wake: some monitors
    /// hang if they get commands while powering up. Gamma dimming is re-applied on wake.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            DDCGate.shared.isPaused = true
        }
        _ = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                DDCGate.shared.isPaused = false
                SoftwareDimmer.reapply()
                DisplayStore.shared.resumeWrites()
            }
        }
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
