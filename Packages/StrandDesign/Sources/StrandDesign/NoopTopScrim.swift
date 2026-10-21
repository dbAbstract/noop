import SwiftUI

// MARK: - A top scrim with no edge of its own
//
// Chrome pinned over scrolling content (the Coach header, the sticky Today header) needs a backing so the
// content passing under it does not fight its text. A material rectangle does that, but it ends in a hard
// bottom edge, and the edge is what makes it read as a translucent toolbar rather than as the content
// dimming where the chrome sits. This blurs and darkens like that rectangle, then fades to nothing past the
// chrome's bottom, so there is no line anywhere.

/// Blur and darken behind top chrome, fading out below it. Use as the chrome's `.background`.
public struct NoopTopScrim: View {
    /// How far below the chrome the fade runs, in points. The scrim is fully opaque down to the chrome's
    /// bottom edge and clear this far past it.
    public var fadeExtent: CGFloat
    /// The whole scrim's strength, 0…1. Lets a caller fade it in as content scrolls under.
    public var strength: Double

    public init(fadeExtent: CGFloat = 32, strength: Double = 1) {
        self.fadeExtent = fadeExtent
        self.strength = strength
    }

    public var body: some View {
        GeometryReader { geo in
            let height = geo.size.height + fadeExtent
            // Where the chrome ends inside the extended frame: opaque above it, fading below it.
            let solid = height > 0 ? geo.size.height / height : 1
            Rectangle().fill(.ultraThinMaterial)
                .overlay(StrandPalette.chatScrim)
                .environment(\.colorScheme, .dark)
                .frame(height: height)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: solid * 0.7),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .opacity(strength)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}
