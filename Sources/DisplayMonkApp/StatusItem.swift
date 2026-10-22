import AppKit
import SwiftUI

extension Notification.Name {
    static let menuWillShow = Notification.Name("DisplayMonkMenuWillShow")
}

/// The menu bar icon and the panel it opens. A custom panel, rather than MenuBarExtra, allows
/// rounded corners and a more translucent background.
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var controller: NSHostingController<MenuView>?
    /// The panel hangs from this point under the icon; it grows downwards when content changes.
    private var anchor = NSPoint.zero
    private var monitors: [Any] = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image
        item.button?.target = self
        item.button?.action = #selector(toggle)
        // Open on press, like the system's menu bar menus.
        item.button?.sendAction(on: [.leftMouseDown])
        item.button?.setAccessibilityLabel("Display Monk")
        statusItem = item
    }

    var isOpen: Bool {
        panel?.isVisible == true
    }

    @objc private func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        let panel = panel ?? makePanel()
        DisplayStore.shared.refreshIfStale()
        MediaKeyTap.shared.update()
        NotificationCenter.default.post(name: .menuWillShow, object: nil)

        if let view = controller?.view {
            view.layoutSubtreeIfNeeded()
            panel.setContentSize(view.fittingSize)
        }
        anchor = anchorPoint(for: panel.frame.width)
        panel.setFrameTopLeftPoint(anchor)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)

        // Close on a click anywhere outside the panel, or on Escape. A click on the icon itself
        // is left to `toggle`: closing here as well would make that click reopen the panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !self.isPointerOnIcon else { return }
            self.close()
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            self?.close()
            return nil
        }) {
            monitors.append(monitor)
        }
    }

    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makePanel() -> NSPanel {
        let controller = NSHostingController(rootView: MenuView(store: DisplayStore.shared))
        controller.sizingOptions = .preferredContentSize
        let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        NotificationCenter.default.addObserver(self, selector: #selector(reanchor), name: NSWindow.didResizeNotification, object: panel)
        // Set as Main moves the menu bar, and the icon with it.
        NotificationCenter.default.addObserver(self, selector: #selector(reanchor), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        self.controller = controller
        self.panel = panel
        return panel
    }

    /// Keeps the top edge under the icon when the content grows or shrinks, or the screens change.
    @objc private func reanchor() {
        guard let panel, panel.isVisible else { return }
        anchor = anchorPoint(for: panel.frame.width)
        panel.setFrameTopLeftPoint(anchor)
        panel.invalidateShadow()
    }

    /// The icon's frame in screen coordinates.
    private var iconFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var isPointerOnIcon: Bool {
        iconFrame?.contains(NSEvent.mouseLocation) ?? false
    }

    private func anchorPoint(for width: CGFloat) -> NSPoint {
        guard let iconFrame, let window = statusItem?.button?.window else { return anchor }
        var x = iconFrame.midX - width / 2
        if let visible = window.screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        }
        return NSPoint(x: x, y: iconFrame.minY - 6)
    }
}

/// Borderless panels can't become key by default; the menu needs that for its controls.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
