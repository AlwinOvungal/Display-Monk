import SwiftUI

/// Display Monk's colours and surfaces, from the app icon and website: saffron for anything
/// active, and soft fills instead of borders.
extension Color {
    /// The robe orange of the Display Monk mascot.
    static let monkSaffron = Color(red: 1, green: 122 / 255, blue: 61 / 255)
}

/// A soft rounded fill that groups related controls.
struct MonkPanel: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

extension View {
    func monkPanel(padding: CGFloat = 12) -> some View {
        modifier(MonkPanel(padding: padding))
    }
}

/// A small coloured dot used for status.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}
