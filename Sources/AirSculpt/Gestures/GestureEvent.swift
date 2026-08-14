import CoreGraphics

/// Events emitted by `GestureStateMachine` for each processed frame.
enum GestureEvent: Sendable {
    /// The rock sign toggled between idle and active.
    case stateChanged(GestureState)
    /// A pinch just engaged — start a new stroke.
    case strokeBegan
    /// Pinch is held — normalized (0...1) midpoint between thumb and index tips.
    case strokePoint(CGPoint)
    /// Pinch released (or hand lost) — finish the current stroke.
    case strokeEnded
    /// Flat hand dragged — normalized screen-space movement since the
    /// previous frame. Horizontal spins the sculpture, vertical tilts it.
    case orbitDelta(dx: CGFloat, dy: CGFloat)
    /// 🤙 held — replace the last stroke with a perfectly straight line.
    case straightenStroke
    /// ✌️ held — replace the last stroke with a smooth fitted curve.
    case smoothStroke
    /// Both hands open, moving together — carry the sculpture (normalized
    /// screen-space midpoint delta).
    case translateDelta(dx: CGFloat, dy: CGFloat)
    /// Both hands pinching — resize the sculpture by this per-frame factor
    /// (hands spreading apart > 1, closing in < 1).
    case scaleDelta(CGFloat)
    /// Orb-hold: the two-hand pair rotated by this many radians — roll the
    /// sculpture about the screen axis, like turning a held ball.
    case rollDelta(CGFloat)
}
