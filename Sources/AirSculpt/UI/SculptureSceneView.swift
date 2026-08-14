import SceneKit
import SwiftUI

/// SCNView wrapper with a fully transparent background, so the 3D strokes
/// composite directly over the live camera feed behind it. (SwiftUI's
/// built-in SceneView always paints an opaque background, hence this wrapper.)
struct SculptureSceneView: NSViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        // Keep the render loop running so per-frame node changes (strokes,
        // rotation) always show immediately.
        view.isPlaying = true
        view.rendersContinuously = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}
}
