#if os(iOS)
import SwiftUI
import UIKit

// UIKit gesture recognizers for the outline on iPhone/iPad.
//
// SwiftUI DragGestures attached to a ScrollView or to its rows (even with .simultaneousGesture) stop the
// ScrollView from scrolling on iOS 18 and later. These recognizers only claim the touches they are for and
// always allow the scroll view's own pan to run alongside them, so vertical swipes keep scrolling the list.

/// A sideways pan: begins only when the finger moves mostly horizontally, so vertical swipes stay with the list.
/// Reports translation while moving, and translation + horizontal velocity (points/s) when it ends.
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        g.cancelsTouchesInView = false
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let t = g.translation(in: nil)
        switch g.state {
        case .changed: onChanged(CGSize(width: t.x, height: t.y))
        case .ended: onEnded(CGSize(width: t.x, height: t.y), g.velocity(in: nil).x)
        case .cancelled, .failed: onEnded(.zero, 0)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Press and hold, then move: lifts an item and drags it. Moving before the hold completes fails the recognizer,
/// so that touch scrolls the list instead. Reports the finger's movement since the hold began (window coordinates).
struct HoldDragGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: Double = 0.25
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    /// Runs on release and on cancel, so a lifted item is always put down.
    var onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = minimumDuration
        g.allowableMovement = 10
        g.delegate = context.coordinator
        g.cancelsTouchesInView = false
        return g
    }

    func updateUIGestureRecognizer(_ g: UILongPressGestureRecognizer, context: Context) {
        g.minimumPressDuration = minimumDuration
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let p = g.location(in: nil)
        switch g.state {
        case .began:
            context.coordinator.start = p
            onBegan()
        case .changed:
            let s = context.coordinator.start
            onChanged(CGSize(width: p.x - s.x, height: p.y - s.y))
        case .ended, .cancelled, .failed:
            onEnded()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
