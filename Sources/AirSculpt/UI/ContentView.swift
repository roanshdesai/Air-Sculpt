import SceneKit
import SwiftUI

/// Main window, AR-mirror style: the live mirrored camera feed fills the
/// whole window, the 3D strokes are composited on top of it so they float
/// in the room around you, with the hand skeleton and a status HUD overlaid.
struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(session: model.cameraManager.session)

                SculptureSceneView(
                    scene: model.sceneController.scene,
                    pointOfView: model.sceneController.cameraNode
                )

                LandmarkOverlayView(frames: model.handFrames)

                VStack {
                    Spacer()
                    HUDView(model: model)
                }

                if model.cameraStatus == .denied {
                    cameraDeniedOverlay
                }
            }
            // Keep the stroke/overlay mappings in sync with the window shape
            // (the camera feed is aspect-filled, so the crop depends on it).
            .onChange(of: geometry.size, initial: true) {
                let size = geometry.size
                guard size.height > 0 else { return }
                model.sceneController.viewAspect = size.width / size.height
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            GizmoView(
                scene: model.sceneController.gizmoScene,
                pointOfView: model.sceneController.gizmoCameraNode,
                onDrag: { dx, dy in model.sceneController.applyOrbit(dx: dx, dy: dy) },
                onReset: { model.sceneController.resetOrientation() }
            )
            .frame(width: 110, height: 110)
            .padding(10)
            .help("Drag to rotate the sculpture · double-click to reset")
            .accessibilityLabel("Orientation cube")
        }
        .frame(minWidth: 960, minHeight: 640)
        .task {
            await model.start()
        }
        .onAppear {
            // SwiftPM executables launch as background processes; promote to
            // a regular app so the window gets focus and a Dock icon.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var cameraDeniedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Camera access is required")
                .font(.title2)
            Text("Enable it in System Settings → Privacy & Security → Camera, then relaunch AirSculpt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
