#if os(iOS)
import UIKit

/// End native scroll interactions left across suspension without rebuilding SwiftUI tab roots.
/// This uses public UIKit APIs and preserves offsets, enabled state and each screen's deceleration rate.
@MainActor
enum ScrollResumeRecovery {
    static func recover(log: (String) -> Void) {
        var scrolls: [UIScrollView] = []
        func visit(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled { scrolls.append(scroll) }
            for child in view.subviews { visit(child) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        where scene.activationState == .foregroundActive {
            for window in scene.windows where !window.isHidden { visit(window) }
        }
        let interrupted = scrolls.filter { $0.isDragging || $0.isTracking || $0.isDecelerating }.count
        let states = scrolls.map { String($0.panGestureRecognizer.state.rawValue) }.joined(separator: ",")
        var restored = 0
        UIView.performWithoutAnimation {
            for scroll in scrolls {
                let offset = scroll.contentOffset
                let pan = scroll.panGestureRecognizer
                // A cancelled touch has no onEnded callback to unwind. Re-enable only recognizers that
                // were enabled, leaving intentionally disabled controls alone.
                if pan.isEnabled { pan.isEnabled = false; pan.isEnabled = true }
                scroll.setContentOffset(offset, animated: false)
                if scroll.contentOffset == offset { restored += 1 }
            }
        }
        log("Scroll resume: native-scrolls=\(scrolls.count) interrupted=\(interrupted) pan-states-before=[\(states)] offsets-restored=\(restored)/\(scrolls.count)")
    }
}
#endif
