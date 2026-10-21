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

/// Turning HiDPI on and off, with the explanations and confirmations around it.
enum HiDPIFlow {
    static func enable(_ state: DisplayState) {
        let alert = NSAlert()
        alert.messageText = "Turn on HiDPI for \(state.display.name)?"
        alert.informativeText = """
        Install adds sharper, scalable HiDPI resolutions to macOS's configuration for this \
        display. It needs your administrator password and a restart, and then works without \
        Display Monk running.

        Virtual Screen works right away, without a restart, but only while Display Monk is \
        running. Use it if Install has no effect on your Mac.

        Either way, only the desktop scaling changes; the signal sent to the monitor stays \
        the same. HiDPI uses slightly more graphics power.
        """
        alert.addButton(withTitle: "Install (Restart Needed)")
        alert.addButton(withTitle: "Use Virtual Screen")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: installOverride(state)
        case .alertSecondButtonReturn: state.enableVirtualHiDPI()
        default: break
        }
    }

    static func disable(_ state: DisplayState) {
        if state.display.isVirtualHiDPI {
            state.disableVirtualHiDPI()
            return
        }
        switch state.overrideStatus {
        case .installed:
            guard Alerts.confirm(
                "Remove HiDPI resolutions for \(state.display.name)?",
                "This needs your administrator password, and takes effect after a restart.",
                confirm: "Remove"
            ) else { return }
            run(state, restartReason: "The HiDPI resolutions are removed after a restart.") {
                try OverrideInstaller.remove(for: state.display)
            }
        case .foreign:
            Alerts.show(
                "HiDPI is set up by another app",
                "This display's HiDPI resolutions come from another app's display configuration (for example BetterDisplay). Turn it off in that app."
            )
        case .notInstalled:
            break
        }
    }

    private static func installOverride(_ state: DisplayState) {
        if state.overrideStatus == .foreign {
            guard Alerts.confirm(
                "This display already has a configuration from another app",
                "Display Monk will keep its settings and add HiDPI resolutions to it. A backup of the original is kept and restored if you turn HiDPI off again.",
                confirm: "Continue"
            ) else { return }
        }
        run(state, restartReason: "Restart your Mac to use the new HiDPI resolutions.") {
            try OverrideInstaller.install(for: state.display)
        }
    }

    private static func run(_ state: DisplayState, restartReason: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch Privileged.Failure.cancelled {
            return
        } catch {
            Alerts.show("Could not change the display configuration", "\(error)")
            return
        }
        state.refreshHiDPI()
        if Alerts.confirm("Restart now?", restartReason, confirm: "Restart…", cancel: "Later") {
            OverrideInstaller.requestRestart()
        }
    }
}
