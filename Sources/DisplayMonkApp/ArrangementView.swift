import DisplayKit
import DisplayMonkCore
import SwiftUI

/// A live, to-scale picture of the displays with one-click placement: arrows put the selected
/// display beside the MacBook (or main display), alignment icons line up its edges, and Set as
/// Main moves the menu bar and Dock.
struct ArrangementSection: View {
    @ObservedObject var store: DisplayStore
    @State private var selectedID: CGDirectDisplayID?

    var body: some View {
        let displays = store.displays
        let selected = displays.first { $0.id == selectedID } ?? displays.first { !$0.display.isBuiltIn } ?? displays.first
        VStack(alignment: .leading, spacing: 4) {
            Text("Arrangement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 8) {
                ArrangementPreview(displays: displays, selectedID: selected?.id) { selectedID = $0 }
                    .frame(height: 96)
                if let selected {
                    controls(for: selected)
                }
            }
            .monkPanel(padding: 10)
        }
    }

    @ViewBuilder private func controls(for selected: DisplayState) -> some View {
        HStack(spacing: 5) {
            if !selected.display.isBuiltIn, let reference = store.arrangementReference(for: selected) {
                let current = selected.placement(relativeTo: reference)
                let side = current?.0 ?? Arrangement.nearestPlacement(of: selected.frame, relativeTo: reference.frame)
                let referenceName = arrangementName(reference)
                ForEach([Placement.left, .above, .right, .below], id: \.self) { placement in
                    IconButton(icon: arrow(for: placement), isOn: current?.0 == placement, help: positionLabel(placement, referenceName)) {
                        selected.move(placement, current?.1 ?? .center, relativeTo: reference)
                    }
                }
                Divider().frame(height: 16).padding(.horizontal, 2)
                ForEach(PlacementAlignment.allCases, id: \.self) { alignment in
                    IconButton(icon: icon(for: alignment, along: side), isOn: current?.1 == alignment, help: "Align \(alignment.label(for: side).lowercased())") {
                        selected.move(side, alignment, relativeTo: reference)
                    }
                }
            } else {
                Text(arrangementName(selected)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !selected.display.isMain {
                Button("Set as Main") { selected.makeMain(among: store.displays) }
                    .controlSize(.small)
                    .help("Moves the menu bar and Dock to \(arrangementName(selected))")
            }
        }
    }

    private func arrow(for placement: Placement) -> String {
        switch placement {
        case .left: "arrow.left"
        case .above: "arrow.up"
        case .right: "arrow.right"
        case .below: "arrow.down"
        }
    }

    private func icon(for alignment: PlacementAlignment, along side: Placement) -> String {
        switch (alignment, side.isHorizontal) {
        case (.start, true): "align.vertical.top"
        case (.center, true): "align.vertical.center"
        case (.end, true): "align.vertical.bottom"
        case (.start, false): "align.horizontal.left"
        case (.center, false): "align.horizontal.center"
        case (.end, false): "align.horizontal.right"
        }
    }

    private func positionLabel(_ placement: Placement, _ reference: String) -> String {
        switch placement {
        case .left: "Left of \(reference)"
        case .right: "Right of \(reference)"
        case .above: "Above \(reference)"
        case .below: "Below \(reference)"
        }
    }
}

/// "MacBook" for the built-in display; long names are shortened to fit the menu.
func arrangementName(_ state: DisplayState) -> String {
    guard !state.display.isBuiltIn else { return "MacBook" }
    let name = state.display.name
    return name.count > 16 ? String(name.prefix(15)).trimmingCharacters(in: .whitespaces) + "…" : name
}

private struct IconButton: View {
    let icon: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.monkSaffron.opacity(0.3) : Color.primary.opacity(0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The displays drawn to scale in their real arrangement; click one to select it.
private struct ArrangementPreview: View {
    let displays: [DisplayState]
    let selectedID: CGDirectDisplayID?
    let onSelect: (CGDirectDisplayID) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frames = displays.map(\.frame)
            let minX = frames.map(\.x).min() ?? 0
            let minY = frames.map(\.y).min() ?? 0
            let spanX = max(1, (frames.map(\.maxX).max() ?? 1) - minX)
            let spanY = max(1, (frames.map(\.maxY).max() ?? 1) - minY)
            let width = Double(geometry.size.width)
            let height = Double(geometry.size.height)
            let scale = min((width - 20) / spanX, (height - 16) / spanY)
            let offsetX = (width - spanX * scale) / 2
            let offsetY = (height - spanY * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { state in
                    let frame = state.frame
                    DisplayBox(name: arrangementName(state), isMain: state.display.isMain, isSelected: state.id == selectedID)
                        .frame(width: CGFloat(max(4, frame.width * scale - 2)), height: CGFloat(max(4, frame.height * scale - 2)))
                        .offset(x: CGFloat(offsetX + (frame.x - minX) * scale + 1), y: CGFloat(offsetY + (frame.y - minY) * scale + 1))
                        .onTapGesture { onSelect(state.id) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct DisplayBox: View {
    let name: String
    let isMain: Bool
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.monkSaffron.opacity(0.3) : Color.primary.opacity(0.14))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? Color.monkSaffron : Color.primary.opacity(0.25), lineWidth: isSelected ? 1.5 : 1)
            if isMain {
                // The menu bar lives on the main display.
                Capsule().fill(Color.primary.opacity(0.4)).frame(height: 3).padding(.horizontal, 4).padding(.top, 3)
            }
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
    }
}
