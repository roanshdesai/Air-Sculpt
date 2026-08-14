import CoreGraphics

/// One frame of smoothed hand landmarks.
///
/// Coordinates are normalized 0...1 with a **bottom-left origin** (Vision's
/// convention) and are already **mirrored horizontally**, so moving your hand
/// to the right moves points to the right on screen, like a mirror.
struct HandFrame: Sendable {
    var points: [HandJoint: CGPoint]

    subscript(joint: HandJoint) -> CGPoint? {
        points[joint]
    }
}
