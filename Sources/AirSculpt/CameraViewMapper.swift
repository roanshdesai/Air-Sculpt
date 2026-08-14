import CoreGraphics

/// Maps camera-normalized coordinates to view-normalized coordinates for the
/// full-window mirror view.
///
/// The camera feed is displayed aspect-FILL: it covers the whole window, so
/// part of the frame is cropped off (vertically in a wide window, laterally
/// in a tall one). Landmarks and strokes must be mapped through the same
/// crop, otherwise they'd drift away from your real hand on screen.
enum CameraViewMapper {
    /// Aspect ratio of the capture preset. Keep in sync with
    /// `CameraManager` (`.hd1280x720` → 16:9; `.vga640x480` → 4:3).
    static let cameraAspect: CGFloat = 16.0 / 9.0

    /// Camera-normalized point (0...1, bottom-left origin, already mirrored)
    /// → view-normalized point (0...1, bottom-left origin) under aspect-fill.
    /// Results can fall slightly outside 0...1 for landmarks in the cropped
    /// region — that's correct (they're off screen).
    static func viewPoint(fromCameraPoint point: CGPoint, viewAspect: CGFloat) -> CGPoint {
        if viewAspect >= cameraAspect {
            // Window wider than the feed: full width shown, top/bottom cropped.
            let visibleFraction = cameraAspect / viewAspect
            return CGPoint(
                x: point.x,
                y: (point.y - (1 - visibleFraction) / 2) / visibleFraction
            )
        } else {
            // Window taller than the feed: full height shown, sides cropped.
            let visibleFraction = viewAspect / cameraAspect
            return CGPoint(
                x: (point.x - (1 - visibleFraction) / 2) / visibleFraction,
                y: point.y
            )
        }
    }
}
