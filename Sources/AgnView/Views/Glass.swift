import SwiftUI

/// A glass surface. iOS 26 and later draw the system glass. Older systems draw
/// a thin material with a hairline. With Reduce Transparency on, the surface
/// is opaque on every system.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Theme.glassSolid))
                .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(Theme.glassLine.opacity(0.6), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
        }
    }
}

extension View {
    /// Draws a glass surface behind the view in the given shape.
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}
