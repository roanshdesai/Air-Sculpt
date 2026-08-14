import CoreMedia
import Vision

/// Runs `VNDetectHumanHandPoseRequest` on each camera frame and outputs
/// smoothed, mirrored, normalized landmarks — now for up to TWO hands.
/// One hand drives drawing/snapping; two hands move and resize the sculpture.
///
/// Accuracy comes from three places: 720p capture (see CameraManager), a
/// confidence gate on each landmark, and per-joint One Euro filtering using
/// real frame timestamps.
///
/// `@unchecked Sendable`: an instance is handed to the camera queue once and
/// only ever touched there (single-consumer invariant), so the mutable filter
/// state never races.
final class HandTracker: @unchecked Sendable {
    /// Landmarks below this Vision confidence are dropped for the frame.
    /// Raise toward 0.5 if you see jittery "ghost" joints; lower toward 0.15
    /// if joints keep flickering in and out.
    private let minimumConfidence: Float = 0.3

    private let request: VNDetectHumanHandPoseRequest

    /// Per-hand-slot, per-joint filters. Slots are ordered by on-screen x
    /// (leftmost hand = slot 0) so each filter stays attached to the same
    /// physical hand from frame to frame (hands crossing swaps them for a
    /// moment — the downstream glitch guards absorb that).
    private var filters: [Int: [HandJoint: OneEuroFilter]] = [:]
    private var previousHandCount = 0
    private var previousTimestamp: CMTime?

    init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
    }

    /// Call on the camera queue. Returns [] when no hand is confidently
    /// detected; hands are sorted left-to-right on screen.
    func process(_ sampleBuffer: CMSampleBuffer) -> [HandFrame] {
        // Real inter-frame dt for the One Euro filter (falls back to 30 fps).
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var dt = 1.0 / 30.0
        if let previous = previousTimestamp {
            let seconds = (timestamp - previous).seconds
            if seconds > 0.001, seconds < 0.5 {
                dt = seconds
            }
        }
        previousTimestamp = timestamp

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return lostHands()
        }
        guard let observations = request.results, !observations.isEmpty else {
            return lostHands()
        }

        // Collect raw (mirrored, confidence-gated) hands first.
        var rawHands: [[HandJoint: CGPoint]] = []
        for observation in observations.prefix(2) {
            guard let recognized = try? observation.recognizedPoints(.all) else { continue }
            var points: [HandJoint: CGPoint] = [:]
            for joint in HandJoint.allCases {
                guard let visionPoint = recognized[joint.visionName],
                      visionPoint.confidence >= minimumConfidence else { continue }
                // Mirror horizontally so on-screen motion matches your hand
                // like a mirror (Vision gives un-mirrored sensor coordinates).
                points[joint] = CGPoint(x: 1 - visionPoint.location.x, y: visionPoint.location.y)
            }
            // Without a wrist there is nothing the gesture logic can do.
            if points[.wrist] != nil {
                rawHands.append(points)
            }
        }
        guard !rawHands.isEmpty else {
            return lostHands()
        }
        rawHands.sort { ($0[.wrist]?.x ?? 0) < ($1[.wrist]?.x ?? 0) }

        // A hand appearing or vanishing reshuffles the slots — restart
        // smoothing rather than dragging filters across different hands.
        if rawHands.count != previousHandCount {
            filters.removeAll()
            previousHandCount = rawHands.count
        }

        var frames: [HandFrame] = []
        for (slot, raw) in rawHands.enumerated() {
            var slotFilters = filters[slot] ?? [:]
            var smoothed: [HandJoint: CGPoint] = [:]
            for (joint, point) in raw {
                var filter = slotFilters[joint] ?? OneEuroFilter()
                smoothed[joint] = filter.filter(point, dt: dt)
                slotFilters[joint] = filter
            }
            filters[slot] = slotFilters
            frames.append(HandFrame(points: smoothed))
        }
        return frames
    }

    private func lostHands() -> [HandFrame] {
        // Reset smoothing so reappearing hands don't get dragged toward
        // their stale pre-disappearance positions.
        filters.removeAll()
        previousHandCount = 0
        return []
    }
}
