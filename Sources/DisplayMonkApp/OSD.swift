import AppKit
import SwiftUI

/// A brightness/volume HUD shown near the bottom of the target screen.
final class OSD {
    static let shared = OSD()

    private final class Model: ObservableObject {
        @Published var icon = "sun.max.fill"
        @Published var level = 0.0
    }

    private let model = Model()
    private let size = NSSize(width: 200, height: 200)
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show so a fade that is already running doesn't hide a newer HUD.
    private var generation = 0

    private init() {}

    func show(icon: String, level: Double, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        model.icon = icon
        model.level = level
        generation += 1
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let shownGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.generation == shownGeneration { self.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OSDView(model: model))
        return panel
    }

    private struct OSDView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(spacing: 22) {
                Image(systemName: model.icon)
                    .font(.system(size: 56, weight: .medium))
                    .frame(height: 70)
                ProgressView(value: model.level)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
            .frame(width: 200, height: 200)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}
