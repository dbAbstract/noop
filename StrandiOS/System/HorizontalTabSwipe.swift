#if os(iOS)
import SwiftUI
import UIKit

/// Reject vertical gestures before recognition rather than letting an ancestor SwiftUI drag compete
/// with every scroll view. The recognizer is cancelled explicitly when the app loses activation.
struct HorizontalTabSwipe: UIViewRepresentable {
    let enabled: Bool
    let onSwipe: (Int) -> Void

    final class Anchor: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindow?(window) }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onSwipe = onSwipe
    }
    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled, onSwipe: onSwipe) }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.attach(nil) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool {
            didSet { pan.isEnabled = enabled && UIApplication.shared.applicationState == .active }
        }
        var onSwipe: (Int) -> Void
        private weak var window: UIWindow?
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(moved))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            return pan
        }()
        init(enabled: Bool, onSwipe: @escaping (Int) -> Void) {
            self.enabled = enabled; self.onSwipe = onSwipe
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(inactive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        func attach(_ next: UIWindow?) {
            guard window !== next else { return }
            window?.removeGestureRecognizer(pan)
            window = next
            next?.addGestureRecognizer(pan)
        }
        @objc private func inactive() { pan.isEnabled = false }
        @objc private func active() { pan.isEnabled = enabled }
        @objc private func moved() {
            guard enabled, pan.state == .ended else { return }
            let value = pan.translation(in: window)
            guard abs(value.x) > 60, abs(value.x) > abs(value.y) * 1.6 else { return }
            onSwipe(value.x < 0 ? 1 : -1)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, window?.rootViewController?.presentedViewController == nil else { return false }
            let velocity = pan.velocity(in: window)
            return abs(velocity.x) > abs(velocity.y) * 1.6
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
