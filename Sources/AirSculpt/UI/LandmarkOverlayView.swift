import SwiftUI

/// Draws the tracked hand skeleton over the full-window camera feed —
/// subtle bones/joints, with the thumb and index tips highlighted since
/// they drive the pinch gesture.
///
/// Landmarks are camera-normalized (bottom-left origin), so each point goes
/// through the same aspect-fill crop as the video feed, then y is flipped
/// for SwiftUI's top-left origin.
struct LandmarkOverlayView: View {
    let frames: [HandFrame]

    var body: some View {
        Canvas { context, size in
            guard !frames.isEmpty, size.height > 0 else { return }
            let viewAspect = size.width / size.height

            func place(_ p: CGPoint) -> CGPoint {
                let v = CameraViewMapper.viewPoint(fromCameraPoint: p, viewAspect: viewAspect)
                return CGPoint(x: v.x * size.width, y: (1 - v.y) * size.height)
            }

            for (handIndex, frame) in frames.enumerated() {
                // Second hand drawn in mint so you can tell the two apart.
                let boneColor: Color = handIndex == 0 ? .cyan : .mint

                // Bones — kept faint so they don't dominate the mirror view.
                for chain in HandJoint.fingerChains {
                    var path = Path()
                    var started = false
                    for joint in chain {
                        guard let point = frame[joint] else { continue }
                        let p = place(point)
                        if started {
                            path.addLine(to: p)
                        } else {
                            path.move(to: p)
                            started = true
                        }
                    }
                    context.stroke(path, with: .color(boneColor.opacity(0.35)), lineWidth: 1.5)
                }

                // Joints — the index tip is the pen, so it gets the highlight.
                for (joint, point) in frame.points {
                    let isPenTip = joint == .indexTip
                    let radius: CGFloat = isPenTip ? 5 : 2.5
                    let p = place(point)
                    let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(isPenTip ? .yellow.opacity(0.9) : boneColor.opacity(0.5))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
