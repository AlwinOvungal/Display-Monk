import AppKit
import SwiftUI

/// The brightness/volume HUD, styled and placed like macOS's own: a compact dark panel at the
/// top right of the target screen, under the menu bar, with the display name, the value and a
/// level bar with step marks.
final class OSD {
    static let shared = OSD()

    enum Kind {
        case brightness
        case volume
        case muted

        var minIcon: String {
            switch self {
            case .brightness: "sun.min"
            case .volume: "speaker.fill"
            case .muted: "speaker.slash.fill"
            }
        }

        var maxIcon: String {
            switch self {
            case .brightness: "sun.max"
            case .volume, .muted: "speaker.wave.3.fill"
            }
        }
    }

    private final class Model: ObservableObject {
        @Published var kind = Kind.brightness
        @Published var title = ""
        @Published var detail = ""
        @Published var level = 0.0
    }

    private let model = Model()
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show so a fade that is already running doesn't hide a newer HUD.
    private var generation = 0

    private static let width: CGFloat = 300
    private static let margin: CGFloat = 12

    private init() {}

    func show(_ kind: Kind, title: String, detail: String, level: Double, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        model.kind = kind
        model.title = title
        model.detail = detail
        model.level = level
        generation += 1

        let size = panel.contentView?.fittingSize ?? NSSize(width: Self.width, height: 64)
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        panel.setFrame(NSRect(
            x: screen.frame.maxX - Self.margin - size.width,
            y: screen.frame.maxY - menuBarHeight - 8 - size.height,
            width: size.width,
            height: size.height
        ), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let shownGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.generation == shownGeneration { self.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OSDView(model: model))
        return panel
    }

    private struct OSDView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(model.detail)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 8) {
                    Image(systemName: model.kind.minIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14)
                    LevelBar(level: model.kind == .muted ? 0 : model.level)
                    Image(systemName: model.kind.maxIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: OSD.width)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .environment(\.colorScheme, .dark)
        }
    }

    /// A thin track with the filled level and 16 step marks beneath it.
    private struct LevelBar: View {
        let level: Double
        private let steps = 16

        var body: some View {
            VStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: max(4, geometry.size.width * min(1, max(0, level))))
                    }
                }
                .frame(height: 4)
                HStack(spacing: 0) {
                    ForEach(0 ... steps, id: \.self) { step in
                        Circle().fill(.white.opacity(0.3)).frame(width: 2, height: 2)
                        if step < steps { Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}
