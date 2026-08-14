import CoreGraphics
import Foundation

/// One Euro filter (Casiez et al., CHI 2012) — an adaptive low-pass filter
/// for noisy pointing input.
///
/// Unlike a moving average, its smoothing strength adapts to speed:
/// heavy when the hand is nearly still (kills jitter), light when the hand
/// moves fast (kills lag). This is the standard choice for fingertip
/// tracking and drawing input.
struct OneEuroFilter {
    /// Cutoff frequency (Hz) when nearly stationary. Lower = steadier hold
    /// (less jitter while hovering) but laggier slow movements.
    var minCutoff: Double = 1.2

    /// How aggressively the cutoff opens up with speed. Raise if fast strokes
    /// trail behind your finger; lower if fast movement looks noisy.
    /// Note: velocity here is in normalized-frame units per second (crossing
    /// the whole frame in 1 s = speed 1.0), which is why this is much larger
    /// than the pixel-unit examples in the paper.
    var beta: Double = 4.0

    /// Cutoff for the internal velocity estimate; rarely needs tuning.
    var derivativeCutoff: Double = 1.0

    private var previousValue: CGPoint?
    private var previousDerivative: CGPoint = .zero

    mutating func filter(_ point: CGPoint, dt: Double) -> CGPoint {
        guard dt > 0, let previous = previousValue else {
            previousValue = point
            previousDerivative = .zero
            return point
        }

        // Filtered velocity estimate.
        let dx = Double(point.x - previous.x) / dt
        let dy = Double(point.y - previous.y) / dt
        let alphaDerivative = smoothingFactor(cutoff: derivativeCutoff, dt: dt)
        let edx = alphaDerivative * dx + (1 - alphaDerivative) * Double(previousDerivative.x)
        let edy = alphaDerivative * dy + (1 - alphaDerivative) * Double(previousDerivative.y)
        previousDerivative = CGPoint(x: edx, y: edy)

        // Speed-adaptive cutoff: still hand → minCutoff, fast hand → wide open.
        let speed = (edx * edx + edy * edy).squareRoot()
        let alpha = smoothingFactor(cutoff: minCutoff + beta * speed, dt: dt)

        let filtered = CGPoint(
            x: CGFloat(alpha) * point.x + CGFloat(1 - alpha) * previous.x,
            y: CGFloat(alpha) * point.y + CGFloat(1 - alpha) * previous.y
        )
        previousValue = filtered
        return filtered
    }

    mutating func reset() {
        previousValue = nil
        previousDerivative = .zero
    }

    private func smoothingFactor(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
