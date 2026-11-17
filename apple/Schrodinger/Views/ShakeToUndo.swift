#if os(iOS)
import SwiftUI
import SwiftData
import UIKit

// Shake to undo on iPhone/iPad. Edits go through the main model context's UndoManager (set in SchrodingerApp),
// which UIKit's own shake-to-undo never sees, so a shake is caught here and answered with the familiar
// Undo / Redo alert. While a text field is being edited, the shake goes to UIKit instead, which undoes typing.

extension Notification.Name {
    static let deviceDidShake = Notification.Name("SchrodingerDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake, !(UIResponder.currentFirstResponder is UITextInput) {
            NotificationCenter.default.post(name: .deviceDidShake, object: self)
            return
        }
        super.motionEnded(motion, with: event)
    }
}

@MainActor private weak var foundFirstResponder: UIResponder?

extension UIResponder {
    /// The responder that currently has keyboard focus, if any.
    static var currentFirstResponder: UIResponder? {
        foundFirstResponder = nil
        UIApplication.shared.sendAction(#selector(UIResponder.schrodingerCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return foundFirstResponder
    }
    @objc fileprivate func schrodingerCaptureFirstResponder(_ sender: Any?) { foundFirstResponder = self }
}

private struct ShakeToUndo: ViewModifier {
    @Environment(\.modelContext) private var ctx
    @State private var asking = false
    @State private var canUndo = false
    @State private var canRedo = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                guard let um = ctx.undoManager else { return }
                ctx.processPendingChanges()
                canUndo = um.canUndo
                canRedo = um.canRedo
                if canUndo || canRedo { asking = true }
            }
            .alert(canUndo ? "Undo last change?" : "Redo last change?", isPresented: $asking) {
                if canUndo { Button("Undo") { run { $0.undo() } } }
                if canRedo { Button("Redo") { run { $0.redo() } } }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func run(_ action: (UndoManager) -> Void) {
        guard let um = ctx.undoManager else { return }
        action(um)
        try? ctx.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

extension View {
    /// Shake the device to undo (or redo) the last edit.
    func shakeToUndo() -> some View { modifier(ShakeToUndo()) }
}
#endif
