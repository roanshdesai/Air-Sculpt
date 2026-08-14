import SceneKit
import SwiftUI

/// Blender-style orientation cube for the window corner: shows the
/// sculpture's current orientation (red = X, green = Y, blue = Z faces),
/// drag it with the mouse to rotate, double-click to reset.
struct GizmoView: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode
    let onDrag: (CGFloat, CGFloat) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> GizmoSCNView {
        let view = GizmoSCNView()
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.rendersContinuously = true
        view.isPlaying = true
        view.onDrag = onDrag
        view.onReset = onReset
        return view
    }

    func updateNSView(_ nsView: GizmoSCNView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onReset = onReset
    }
}

/// SCNView subclass that turns mouse drags into orbit deltas.
final class GizmoSCNView: SCNView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onReset: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // ~150 pt of mouse travel ≈ one full-screen hand swipe; lower the
        // divisor for faster mouse rotation. deltaY is negated because mouse
        // deltas grow downward but orbit expects screen-up positive.
        onDrag?(event.deltaX / 150, -event.deltaY / 150)
    }
}
