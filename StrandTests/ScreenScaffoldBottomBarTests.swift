import XCTest
import SwiftUI
@testable import Strand

/// The bottom-bar inset must be attached ONLY when a bar was supplied.
///
/// This exists because of a real regression: adding `.safeAreaInset(edge: .bottom)` unconditionally — with
/// an `EmptyView` for the screens that passed nothing — reserved a region the scroll view treated as
/// content. Every scaffold screen gained dead space below its last card and could be dragged up and off the
/// screen. Today was unaffected only because it builds its own `ScrollView`.
///
/// The invariant is structural rather than visual, so it is asserted at the init rather than by rendering:
/// a scaffold built without a bar must not claim to have one.
final class ScreenScaffoldBottomBarTests: XCTestCase {

    func testAScaffoldWithNoBarDoesNotClaimOne() {
        let plain = ScreenScaffold(title: "Test") { Text("content") }
        XCTAssertFalse(plain.hasBottomBar,
                       "an unconditional inset is what let every screen scroll past its content")
    }

    func testAScaffoldWithATrailingItemStillHasNoBar() {
        let withTrailing = ScreenScaffold(title: "Test",
                                          trailing: { Text("badge") },
                                          content: { Text("content") })
        XCTAssertFalse(withTrailing.hasBottomBar)
    }

    /// And the Coach shape — the one case that needs it — does.
    func testAScaffoldGivenABarClaimsIt() {
        let withBar = ScreenScaffold(title: "Test",
                                      bottomBar: { Text("composer") },
                                      content: { Text("content") })
        XCTAssertTrue(withBar.hasBottomBar)
    }
}
