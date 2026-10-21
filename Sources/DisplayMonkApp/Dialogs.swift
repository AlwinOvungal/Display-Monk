import AppKit
import DisplayKit
import DisplayMonkCore

enum Alerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    /// Returns true if the first button was chosen.
    static func confirm(_ title: String, _ message: String, confirm: String, cancel: String = "Cancel") -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// "Keep this setting?" with a countdown, like macOS's own prompt after a display change.
/// Anything other than an explicit Keep (including no answer) reverts.
enum ChangeConfirmation {
    static func ask(_ title: String, seconds: Int = 15) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(seconds)
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")
        let countdown = Countdown(alert: alert, remaining: seconds)
        let timer = Timer(timeInterval: 1, target: countdown, selector: #selector(Countdown.tick(_:)), userInfo: nil, repeats: true)
        // The modal session runs the main run loop in modal-panel mode.
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        return response == .alertFirstButtonReturn
    }

    static func message(_ seconds: Int) -> String {
        "The previous setting comes back in \(max(seconds, 0)) seconds unless you keep this one."
    }

    private final class Countdown: NSObject {
        let alert: NSAlert
        var remaining: Int

        init(alert: NSAlert, remaining: Int) {
            self.alert = alert
            self.remaining = remaining
        }

        @objc func tick(_ timer: Timer) {
            remaining -= 1
            alert.informativeText = ChangeConfirmation.message(remaining)
            if remaining <= 0 {
                timer.invalidate()
                NSApp.abortModal()
            }
        }
    }
}

/// The optional permanent HiDPI configuration. The switch in the menu never needs a restart:
/// it uses a virtual screen until a permanent configuration takes over at the next restart.
enum HiDPIFlow {
    static func makePermanent(_ state: DisplayState) {
        if state.overrideStatus == .foreign {
            guard Alerts.confirm(
                "This display already has a configuration from another app",
                "Display Monk will keep its settings and add HiDPI resolutions to it. A backup of the original is kept and restored if you remove permanent HiDPI again.",
                confirm: "Continue"
            ) else { return }
        }
        guard run({ try OverrideInstaller.install(for: state.display) }) else { return }
        state.refreshHiDPI()
        Alerts.show(
            "HiDPI will become permanent",
            "Nothing else to do: keep using HiDPI as it is. After your next restart, Display Monk switches \(state.display.name) from the virtual screen to native HiDPI when it starts (turn on Launch at login to make this automatic). From then on HiDPI stays on even when the app isn't running."
        )
    }

    static func removePermanent(_ state: DisplayState) {
        guard Alerts.confirm(
            "Remove permanent HiDPI for \(state.display.name)?",
            "The HiDPI sizes disappear after your next restart. You can still use HiDPI with the switch, which then uses a virtual screen.",
            confirm: "Remove"
        ) else { return }
        guard run({ try OverrideInstaller.remove(for: state.display) }) else { return }
        state.refreshHiDPI()
    }

    /// Returns false if the user cancelled the password prompt or the change failed.
    private static func run(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            return true
        } catch Privileged.Failure.cancelled {
            return false
        } catch {
            Alerts.show("Could not change the display configuration", "\(error)")
            return false
        }
    }
}
