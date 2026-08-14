import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Wires the pipeline together:
/// camera queue: CameraManager → HandTracker (Vision + smoothing)
/// main actor:   GestureStateMachine → SceneController + SwiftUI state
@MainActor
@Observable
final class AppModel {
    enum CameraStatus {
        case starting, running, denied
    }

    var cameraStatus: CameraStatus = .starting
    var gestureState: GestureState = .idle
    var handFrames: [HandFrame] = []
    var isDrawing = false
    /// Emoji of the pose the detector recognized this frame (HUD indicator).
    var detectedPose = "—"

    /// Tube thickness for new strokes (world units), bound to the HUD slider.
    var strokeThickness: CGFloat = 0.07 {
        didSet { sceneController.strokeThickness = strokeThickness }
    }

    /// Colour for new strokes, bound to the HUD colour picker. The palette
    /// keeps cycling until the user actually changes this (didSet only runs
    /// on change, not at init).
    var strokeColor: Color = .cyan {
        didSet { sceneController.strokeColorOverride = NSColor(strokeColor) }
    }

    var handVisible: Bool { !handFrames.isEmpty }

    let cameraManager = CameraManager()
    let sceneController = SceneController()
    private let gestures = GestureStateMachine()
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        guard await CameraManager.requestAccess() else {
            cameraStatus = .denied
            return
        }
        // The tracker is handed to the camera queue and only touched there;
        // finished HandFrames (plain Sendable values) hop to the main actor.
        let tracker = HandTracker()
        cameraManager.start { [weak self] sampleBuffer in
            let frames = tracker.process(sampleBuffer)
            Task { @MainActor [weak self] in
                self?.ingest(frames)
            }
        }
        cameraStatus = .running
    }

    private func ingest(_ frames: [HandFrame]) {
        handFrames = frames
        for event in gestures.process(frames) {
            switch event {
            case .stateChanged(let newState):
                gestureState = newState
            case .strokeBegan:
                isDrawing = true
                sceneController.beginStroke()
            case .strokePoint(let point):
                sceneController.addStrokePoint(point)
            case .strokeEnded:
                isDrawing = false
                sceneController.endStroke()
            case .orbitDelta(let dx, let dy):
                sceneController.applyOrbit(dx: dx, dy: dy)
            case .straightenStroke:
                sceneController.straightenLastStroke()
            case .smoothStroke:
                sceneController.smoothLastStroke()
            case .translateDelta(let dx, let dy):
                sceneController.applyTranslation(dx: dx, dy: dy)
            case .scaleDelta(let factor):
                sceneController.applyScale(factor)
            case .rollDelta(let delta):
                sceneController.applyRoll(delta)
            }
        }
        detectedPose = gestures.poseLabel
    }

    func undo() {
        sceneController.undoLastStroke()
    }

    func fill() {
        sceneController.toggleFillOnLastStroke()
    }

    func extrude() {
        sceneController.extrudeLastStroke()
    }

    func clearCanvas() {
        sceneController.clearAll()
    }

    func resetView() {
        sceneController.resetOrientation()
    }
}
