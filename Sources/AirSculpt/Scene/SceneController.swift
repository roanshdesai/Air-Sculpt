import AppKit
import QuartzCore
import SceneKit
import simd

/// Owns the SceneKit scene: builds tube geometry for drawn strokes, applies
/// rotation from the flat-hand gesture, and rewrites strokes for the shape
/// snapping gestures (🤙 → straight line, ✌️ → smooth curve).
///
/// The scene has a transparent background and is composited over the live
/// camera feed, so strokes appear to float in the room around you. The world
/// mapping is derived from the actual window aspect so a stroke lands
/// exactly under your fingertip on screen.
///
/// All strokes live under `contentNode`; the rotation gesture spins that one
/// node, so the whole sculpture rotates together. Each stroke keeps its
/// sampled points so it can be re-fit and rebuilt by the snap gestures.
@MainActor
final class SceneController {

    // MARK: - Tunable values

    /// Tube radius for *new* strokes, in world units. Driven by the HUD
    /// thickness slider; each stroke locks in the radius it started with.
    var strokeThickness: CGFloat = 0.07

    /// A new cylinder segment is only added once the fingertip has traveled
    /// this far (world units). Smaller = smoother curves but many more nodes;
    /// larger = chunkier strokes but cheaper to render.
    private let minSegmentLength: Float = 0.12

    /// A jump longer than this in one frame is a tracking glitch, not a real
    /// hand movement — the pen "lifts" and re-plants instead of drawing a spike.
    private let maxSegmentLength: Float = 2.5

    /// Extra exponential smoothing on draw points, applied on top of the
    /// One Euro landmark filter (0 = off, closer to 1 = steadier but
    /// laggier). This is the anti-wobble control for line quality — raw
    /// fingertip tracking wiggles a centimeter or two even with good
    /// landmark filtering.
    private let strokeSmoothing: Float = 0.45

    /// Strokes with a total path length below this (world units) are
    /// discarded when they end. They are almost always accidental flicks
    /// from pose transitions, which used to leave confetti dots all over
    /// the canvas. Set to 0 to keep everything (e.g. deliberate tap-dots).
    private let minStrokeLength: Float = 0.3

    /// Number of segments a ✌️-smoothed curve is rebuilt with.
    private let curveSamples = 24

    /// Break healing: if a new stroke starts within this long after the
    /// previous one ended…
    private let joinWindow: TimeInterval = 0.8
    /// …and within this on-screen distance (world units at the drawing
    /// plane) of where it ended, it CONTINUES the previous stroke instead of
    /// starting a new one. This welds together lines fragmented by momentary
    /// pose or tracking flicker.
    private let joinDistance: Float = 0.7

    /// Auto-lock: a stroke that starts or ends within this on-screen
    /// distance of any existing stroke snaps onto it in 3D — so a line drawn
    /// "from" a previous line stays truly connected even when rotation has
    /// put that line at a different depth than the drawing plane.
    private let lockRadius: Float = 0.35

    /// Endpoints closer than this (world units) mark a stroke as a CLOSED
    /// loop, which unlocks polygon snapping (🤙), Fill, and clean extrusion.
    private let closeThreshold: Float = 0.5

    /// A stroke ending within this distance of its own start is welded shut
    /// into a closed loop. Deliberately generous — hand-drawn shapes rarely
    /// land exactly back on their start.
    private let selfCloseRadius: Float = 1.1

    /// Corner-detection tolerance (Douglas-Peucker) for polygon snapping and
    /// extrusion connectors: wobble below this is absorbed into a straight
    /// edge. The effective value also scales with stroke size (see call sites).
    private let cornerEpsilon: Float = 0.22

    /// Extrusion depth = this × the shape's average edge length, so 1.0
    /// turns a square into a cube and a triangle into a matching prism.
    private let extrusionDepthFactor: Float = 1.0

    /// When set, new strokes use this colour instead of cycling the palette.
    /// Driven by the HUD colour picker.
    var strokeColorOverride: NSColor?

    /// Radians of sculpture rotation per full-screen-width of flat-hand
    /// movement. 3.5 ≈ dragging your flat hand across the whole window turns
    /// the sculpture about 200°. Lower it for finer control.
    private let orbitGain: Float = 3.5

    /// How far the camera sits from the drawing plane (world units), and its
    /// vertical field of view. Together these define how much world space the
    /// window shows; the stroke mapping below is derived from them, so the
    /// on-screen size of the visible field always matches the window exactly.
    private let cameraDistance: Float = 11
    private let verticalFOV: CGFloat = 60

    // MARK: - Scene graph

    /// One drawn stroke: its scene node plus the sampled points (in
    /// contentNode-local space) that the snap gestures re-fit.
    private struct Stroke {
        let node: SCNNode
        var points: [simd_float3]
        let radius: CGFloat
        let color: NSColor
        /// Translucent face node added by Fill (removed when toggled off).
        var fillNode: SCNNode?
        /// True once extruded into a 3D object — snaps and re-extrusion then
        /// leave it alone (its points also include the back loop).
        var isSolid = false
        /// For solids: how many leading entries of `points` are the front
        /// face — Fill uses exactly that loop.
        var solidFrontCount: Int?
    }

    /// Where and when the last surviving stroke ended — the rejoin target.
    private struct StrokeEnd {
        let point: simd_float3
        let time: TimeInterval
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Separate mini-scene for the Blender-style orientation cube in the
    /// window corner; its cube mirrors contentNode's orientation.
    let gizmoScene = SCNScene()
    let gizmoCameraNode = SCNNode()
    private let gizmoCube = SCNNode()
    private let contentNode = SCNNode()   // rotated by the flat-hand gesture
    private var strokes: [Stroke] = []
    private var strokePending = false     // strokeBegan received, first point not yet
    private var activeStrokeIndex: Int?
    private var lastStrokeEnd: StrokeEnd?
    private var skipGlitchGuardOnce = false
    private var lastPoint: simd_float3?
    private var smoothedDrawPoint: simd_float3?
    private var strokeCount = 0

    /// Window aspect ratio (width / height), pushed in from SwiftUI whenever
    /// the window resizes. Drives the camera-crop and world mappings.
    var viewAspect: CGFloat = 16.0 / 9.0

    /// contentNode's uniform scale. Stroke points live in contentNode-LOCAL
    /// space, but every threshold constant in this class is meant in WORLD
    /// (on-screen) units — so measured local distances are multiplied by
    /// this before comparison. Without it, a two-hand resize silently
    /// rescaled the junk filter, self-close radius, sampling density, etc.
    private var contentScale: Float {
        max(0.001, contentNode.simdScale.x)
    }

    private let palette: [NSColor] = [
        .systemTeal, .systemPink, .systemYellow,
        .systemGreen, .systemOrange, .systemPurple,
    ]

    init() {
        setUpScene()
        setUpGizmo()
    }

    // MARK: - Stroke drawing

    func beginStroke() {
        // Creation is deferred to the first sampled point so we can decide
        // between rejoining the previous stroke, locking onto existing
        // geometry, or genuinely starting fresh.
        strokePending = true
        lastPoint = nil
        smoothedDrawPoint = nil
    }

    /// Adds a sampled fingertip point (camera-normalized 0...1, bottom-left
    /// origin) to the current stroke.
    func addStrokePoint(_ normalized: CGPoint) {
        guard strokePending || activeStrokeIndex != nil else { return }
        let world = worldPoint(fromCameraPoint: normalized)
        // Convert into contentNode's (possibly rotated) local space so the
        // stroke appears under your fingertip even after rotating. Drawing is
        // always 2D — on the camera-facing plane — but drawing after a
        // rotation places strokes on a different plane of the sculpture,
        // which is what builds up real 3D structure.
        var local = contentNode.simdConvertPosition(world, from: nil)

        // Second-stage smoothing for line quality (see strokeSmoothing).
        if let previous = smoothedDrawPoint {
            local = simd_mix(previous, local, simd_float3(repeating: 1 - strokeSmoothing))
        }
        smoothedDrawPoint = local

        if strokePending {
            strokePending = false
            startStroke(at: local)
            return
        }
        guard let index = activeStrokeIndex, let last = lastPoint else { return }
        // World-space length (local × scale): zoom level must never change
        // sampling density or the glitch guard.
        let segmentLength = simd_length(local - last) * contentScale
        if skipGlitchGuardOnce {
            // First segment after locking onto existing geometry may bridge
            // a real depth gap — that jump is intentional, not a glitch.
            skipGlitchGuardOnce = false
            if segmentLength >= minSegmentLength {
                appendPoint(local, toStrokeAt: index, connectingFrom: last)
            }
            return
        }
        if segmentLength > maxSegmentLength {
            // Tracking glitch: lift the pen and re-plant.
            appendPoint(local, toStrokeAt: index, connectingFrom: nil)
            return
        }
        guard segmentLength >= minSegmentLength else { return }
        appendPoint(local, toStrokeAt: index, connectingFrom: last)
    }

    /// Decides how a stroke actually starts once its first point is known.
    private func startStroke(at point: simd_float3) {
        // 1) Break healing: continue the previous stroke if this starts
        //    right where and when it ended.
        if let end = lastStrokeEnd,
           let index = strokes.indices.last,
           !strokes[index].isSolid, // never draw INTO an extruded object
           CACurrentMediaTime() - end.time < joinWindow,
           let a = screenPlanePoint(ofLocal: point),
           let b = screenPlanePoint(ofLocal: end.point),
           simd_length(a - b) < joinDistance {
            activeStrokeIndex = index
            lastPoint = strokes[index].points.last ?? end.point
            lastStrokeEnd = nil
            return
        }
        // 2) New stroke — auto-lock its start onto nearby existing geometry.
        let anchor = nearestGeometryPoint(to: point, within: lockRadius)
        let node = SCNNode()
        contentNode.addChildNode(node)
        strokes.append(Stroke(
            node: node,
            points: [],
            // Radius is stored in local units; dividing by the current scale
            // makes the slider value mean on-screen thickness at any zoom.
            radius: strokeThickness / CGFloat(contentScale),
            color: strokeColorOverride ?? palette[strokeCount % palette.count]
        ))
        strokeCount += 1
        let index = strokes.count - 1
        activeStrokeIndex = index
        appendPoint(anchor ?? point, toStrokeAt: index, connectingFrom: nil)
        skipGlitchGuardOnce = anchor != nil
    }

    func endStroke() {
        defer {
            strokePending = false
            activeStrokeIndex = nil
            skipGlitchGuardOnce = false
            lastPoint = nil
            smoothedDrawPoint = nil
        }
        guard let index = activeStrokeIndex else { return }
        let scale = contentScale
        if let last = lastPoint {
            let currentPoints = strokes[index].points
            var drawnLength: Float = 0
            for i in 1..<max(currentPoints.count, 1) {
                drawnLength += simd_length(currentPoints[i] - currentPoints[i - 1])
            }
            // Candidate 1 — self-closing weld: a stroke ending near its own
            // start closes the loop exactly, so 🤙 (polygon), ✌️ (circle),
            // Fill, and Extrude all see a closed shape. The gap must also be
            // small RELATIVE to the stroke, so a V-arrowhead's open tip
            // isn't welded into a triangle.
            var selfGap = Float.greatestFiniteMagnitude
            if let first = currentPoints.first, currentPoints.count >= 6 {
                let gap = simd_length(last - first) * scale
                if gap > 0.001 { selfGap = gap }
            }
            let selfEligible = selfGap < selfCloseRadius && selfGap < 0.25 * drawnLength * scale
            // Candidate 2 — end-lock onto other geometry, so arrows meet
            // their targets exactly.
            var lockTarget: simd_float3?
            var lockDistance = Float.greatestFiniteMagnitude
            if let target = nearestGeometryPoint(to: last, within: lockRadius, excluding: index),
               simd_length(target - last) > 0.001 {
                lockTarget = target
                if let a = screenPlanePoint(ofLocal: last), let b = screenPlanePoint(ofLocal: target) {
                    lockDistance = simd_length(a - b)
                }
            }
            // The nearer connection wins.
            if selfEligible, selfGap <= lockDistance, let first = currentPoints.first {
                appendPoint(first, toStrokeAt: index, connectingFrom: last)
            } else if let lockTarget {
                appendPoint(lockTarget, toStrokeAt: index, connectingFrom: last)
            }
        }
        let points = strokes[index].points
        var pathLength: Float = 0
        for i in 1..<max(points.count, 1) {
            pathLength += simd_length(points[i] - points[i - 1])
        }
        // Junk cleanup: accidental flicks from pose transitions produce tiny
        // strokes that litter the canvas — drop them. (A healed/rejoined
        // stroke is measured whole, so it always survives.)
        if points.count < 2 || pathLength * scale < minStrokeLength {
            strokes[index].node.removeFromParentNode()
            strokes.remove(at: index)
            // Keep the previous stroke's end info: if this fragment was
            // noise between two halves of one line, the next start can still
            // rejoin the real stroke.
        } else if let endPoint = points.last {
            lastStrokeEnd = StrokeEnd(point: endPoint, time: CACurrentMediaTime())
        }
    }

    /// Removes the most recently drawn stroke (no-op while a stroke is in
    /// progress).
    func undoLastStroke() {
        guard activeStrokeIndex == nil, let stroke = strokes.popLast() else { return }
        stroke.node.removeFromParentNode()
        lastStrokeEnd = nil
    }

    /// Nearest sampled point across all existing strokes whose *on-screen*
    /// position is within `radius` of the given point's on-screen position.
    /// Screen-space matching is the whole trick: after rotation, geometry
    /// that appears right under your fingertip can sit at a very different
    /// depth — locking adopts that 3D point so the connection is real, not
    /// just visual.
    private func nearestGeometryPoint(to point: simd_float3, within radius: Float, excluding: Int? = nil) -> simd_float3? {
        guard let target = screenPlanePoint(ofLocal: point) else { return nil }
        var best: (point: simd_float3, distance: Float)?
        for (index, stroke) in strokes.enumerated() where index != excluding && index != activeStrokeIndex {
            for candidate in stroke.points {
                guard let projected = screenPlanePoint(ofLocal: candidate) else { continue }
                let distance = simd_length(projected - target)
                if distance < radius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (candidate, distance)
                }
            }
        }
        return best?.point
    }

    /// Projects a contentNode-local point through the camera onto the z = 0
    /// drawing plane — "where it appears on screen", in world units.
    private func screenPlanePoint(ofLocal point: simd_float3) -> simd_float2? {
        let world = contentNode.simdConvertPosition(point, to: nil)
        let denominator = cameraDistance - world.z
        guard denominator > 0.5 else { return nil } // behind or at the camera
        let scale = cameraDistance / denominator
        return simd_float2(world.x * scale, world.y * scale)
    }

    private func appendPoint(_ point: simd_float3, toStrokeAt index: Int, connectingFrom previous: simd_float3?) {
        let stroke = strokes[index]
        strokes[index].points.append(point)
        if let previous {
            stroke.node.addChildNode(segmentNode(from: previous, to: point, radius: stroke.radius, color: stroke.color))
        }
        stroke.node.addChildNode(jointSphere(at: point, radius: stroke.radius, color: stroke.color))
        lastPoint = point
    }

    // MARK: - Shape snapping (🤙 straight, ✌️ curve)

    /// 🤙 — makes the last stroke perfectly straight-edged.
    ///
    /// Open stroke → one straight tube (least-squares flavored: the line
    /// runs through the points' centroid in the endpoint direction, with
    /// every point projected onto it so it spans exactly what you drew).
    ///
    /// CLOSED stroke → a clean polygon: corners found by Douglas-Peucker,
    /// straight edges between them. Draw a rough square, 🤙, get a real
    /// square — then Extrude turns it into a cube.
    func straightenLastStroke() {
        guard let index = strokes.indices.last, activeStrokeIndex == nil, !strokes[index].isSolid else { return }
        let points = strokes[index].points
        guard points.count >= 2, let first = points.first, let last = points.last else { return }

        if points.count >= 6, simd_length(first - last) * contentScale < closeThreshold {
            let corners = detectCorners(of: points)
            if corners.count >= 3 {
                rebuildStroke(at: index, with: corners + [corners[0]])
                return
            }
        }
        var direction = last - first
        let span = simd_length(direction)
        guard span > 0.001 else { return }
        direction /= span
        let centroid = points.reduce(simd_float3()) { $0 + $1 } / Float(points.count)
        var tMin = Float.greatestFiniteMagnitude
        var tMax = -Float.greatestFiniteMagnitude
        for point in points {
            let t = simd_dot(point - centroid, direction)
            tMin = min(tMin, t)
            tMax = max(tMax, t)
        }
        rebuildStroke(at: index, with: [centroid + direction * tMin, centroid + direction * tMax])
    }

    /// ✌️ — replaces the last stroke with a smooth curve: a quadratic Bézier
    /// with the drawn endpoints fixed and the control point solved by least
    /// squares against every sampled point (parameterized by arc length).
    /// A quadratic gives exactly the clean single-bend arcs physics diagrams
    /// need (trajectories, field lines); a wobblier multi-bend scribble
    /// still comes out as its best single-curve approximation.
    func smoothLastStroke() {
        guard let index = strokes.indices.last, activeStrokeIndex == nil, !strokes[index].isSolid else { return }
        let points = strokes[index].points
        guard points.count >= 3, let p0 = points.first, let p2 = points.last else {
            straightenLastStroke() // 2 points: a curve is meaningless, snap straight
            return
        }

        // CLOSED loop → perfect circle. A fixed-endpoint Bézier is degenerate
        // when p0 ≈ p2 (it collapses the shape to an out-and-back line), and
        // a circle is what a hand-drawn closed "round" shape means anyway.
        if simd_length(p0 - p2) * contentScale < closeThreshold {
            snapCircle(at: index)
            return
        }

        // Parameterize samples by normalized cumulative arc length.
        var cumulative: [Float] = [0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + simd_length(points[i] - points[i - 1]))
        }
        guard let total = cumulative.last, total > 0.001 else { return }

        // Solve the free control point C minimizing Σ |B(t_i) - P_i|².
        var numerator = simd_float3()
        var denominator: Float = 0
        for (i, point) in points.enumerated() {
            let t = cumulative[i] / total
            let b0 = (1 - t) * (1 - t)
            let b1 = 2 * t * (1 - t)
            let b2 = t * t
            numerator += (point - b0 * p0 - b2 * p2) * b1
            denominator += b1 * b1
        }
        guard denominator > 0.0001 else { return }
        let control = numerator / denominator

        var resampled: [simd_float3] = []
        for i in 0...curveSamples {
            let t = Float(i) / Float(curveSamples)
            let b0 = (1 - t) * (1 - t)
            let b1 = 2 * t * (1 - t)
            let b2 = t * t
            resampled.append(b0 * p0 + b1 * control + b2 * p2)
        }
        rebuildStroke(at: index, with: resampled)
    }

    // MARK: - 3D objects (Extrude + Fill)

    /// Extrudes the last stroke into a 3D object: a copy of the shape is
    /// placed at depth behind it and connected corner-to-corner — a square
    /// becomes a cube, a triangle a prism. Connectors leave from the shape's
    /// detected corners (or an open stroke's ends), never from random spots.
    func extrudeLastStroke() {
        guard let index = strokes.indices.last, activeStrokeIndex == nil, !strokes[index].isSolid else { return }
        var front = strokes[index].points
        guard front.count >= 2 else { return }
        let closed = front.count >= 3 && simd_length(front[0] - front[front.count - 1]) * contentScale < closeThreshold
        // Polygon-snapped loops repeat their first corner at the end — drop
        // the duplicate so it doesn't get a second connector.
        if closed, simd_length(front[0] - front[front.count - 1]) < 0.001 {
            front.removeLast()
        }

        var perimeter: Float = 0
        for i in 1..<front.count {
            perimeter += simd_length(front[i] - front[i - 1])
        }
        if closed {
            perimeter += simd_length(front[0] - front[front.count - 1])
        }
        guard perimeter > 0.01 else { return }

        // Connectors leave from real corners: reuse corner detection on the
        // dense path (a snapped polygon just returns its own corners).
        var connectorPoints = closed ? detectCorners(of: front + [front[0]]) : detectCorners(of: front)
        if connectorPoints.count < 2 {
            connectorPoints = [front[0], front[front.count - 1]]
        }

        // Extrusion direction: the shape's own plane normal (Newell), pushed
        // AWAY from the camera; straight lines fall back to the current
        // drawing-plane normal.
        var normal = newellNormal(front)
            ?? simd_normalize(contentNode.simdConvertVector(simd_float3(0, 0, -1), from: nil))
        let worldNormal = contentNode.simdConvertVector(normal, to: nil)
        if worldNormal.z > 0 {
            normal = -normal
        }

        // Depth: average edge length for closed shapes (square → cube);
        // open strokes get 0.6× their length. The sanity clamp is applied in
        // WORLD units (candidate × scale) so zoom can't turn cubes into
        // slabs or thin prisms into towers.
        let candidate: Float
        if closed {
            candidate = extrusionDepthFactor * perimeter / Float(max(3, connectorPoints.count))
        } else {
            candidate = 0.6 * perimeter
        }
        let depth = min(5, max(0.5, candidate * contentScale)) / contentScale
        let offset = normal * depth

        let stroke = strokes[index]
        let backPoints = front.map { $0 + offset }
        stroke.node.addChildNode(jointSphere(at: backPoints[0], radius: stroke.radius, color: stroke.color))
        for i in 1..<backPoints.count {
            stroke.node.addChildNode(segmentNode(from: backPoints[i - 1], to: backPoints[i], radius: stroke.radius, color: stroke.color))
            stroke.node.addChildNode(jointSphere(at: backPoints[i], radius: stroke.radius, color: stroke.color))
        }
        if closed {
            stroke.node.addChildNode(segmentNode(from: backPoints[backPoints.count - 1], to: backPoints[0], radius: stroke.radius, color: stroke.color))
        }
        for corner in connectorPoints {
            stroke.node.addChildNode(segmentNode(from: corner, to: corner + offset, radius: stroke.radius, color: stroke.color))
        }

        strokes[index].isSolid = true
        strokes[index].solidFrontCount = front.count
        // Include the back loop in the stored points so new strokes can
        // auto-lock onto the back corners too.
        strokes[index].points = front + backPoints
        // The stroke is an object now — the next stroke must never silently
        // continue it via break healing.
        lastStrokeEnd = nil
    }

    /// Fills the last closed stroke with a translucent face of its own
    /// colour (press again to remove). Fan-triangulated around the centroid,
    /// which is exact for convex shapes and fine for mildly concave ones.
    func toggleFillOnLastStroke() {
        guard let index = strokes.indices.last, activeStrokeIndex == nil else { return }
        if let existing = strokes[index].fillNode {
            existing.removeFromParentNode()
            strokes[index].fillNode = nil
            return
        }
        let loop = fillLoop(for: strokes[index])
        guard loop.count >= 3 else { return }

        let centroid = loop.reduce(simd_float3()) { $0 + $1 } / Float(loop.count)
        var vertices = [SCNVector3(CGFloat(centroid.x), CGFloat(centroid.y), CGFloat(centroid.z))]
        vertices += loop.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }
        var indices: [Int32] = []
        for i in 0..<loop.count {
            indices += [0, Int32(i + 1), Int32((i + 1) % loop.count + 1)]
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.diffuse.contents = strokes[index].color.withAlphaComponent(0.35)
        material.lightingModel = .constant // flat wash of colour, no shading
        material.isDoubleSided = true      // visible from both sides when rotated
        geometry.materials = [material]
        let fillNode = SCNNode(geometry: geometry)
        strokes[index].node.addChildNode(fillNode)
        strokes[index].fillNode = fillNode
    }

    /// Which loop Fill paints. A plain stroke fills its own outline. An
    /// extruded solid fills whichever of its faces — front, back, or a side
    /// quad — most squarely faces the camera RIGHT NOW: rotate the object,
    /// press Fill, and the face you're looking at gets the colour.
    private func fillLoop(for stroke: Stroke) -> [simd_float3] {
        guard stroke.isSolid, let frontCount = stroke.solidFrontCount else {
            var loop = stroke.points
            if loop.count >= 2, simd_length(loop[0] - loop[loop.count - 1]) < 0.001 {
                loop.removeLast()
            }
            return loop
        }

        let front = Array(stroke.points.prefix(frontCount))
        let back = Array(stroke.points.dropFirst(frontCount))
        var faces: [[simd_float3]] = [front]
        if back.count == front.count {
            faces.append(back)
            // Side quads only for corner-snapped shapes — a dense freehand
            // loop would produce dozens of sliver faces.
            if front.count <= 12 {
                for i in front.indices {
                    let j = (i + 1) % front.count
                    faces.append([front[i], front[j], back[j], back[i]])
                }
            }
        }

        let cameraPosition = simd_float3(0, 0, cameraDistance)
        var best = front
        var bestScore = -Float.greatestFiniteMagnitude
        for face in faces {
            guard let localNormal = newellNormal(face) else { continue }
            let worldNormal = simd_normalize(contentNode.simdConvertVector(localNormal, to: nil))
            let localCentroid = face.reduce(simd_float3()) { $0 + $1 } / Float(face.count)
            let worldCentroid = contentNode.simdConvertPosition(localCentroid, to: nil)
            let toCamera = cameraPosition - worldCentroid
            let toCameraDistance = simd_length(toCamera)
            guard toCameraDistance > 0.001 else { continue }
            // How squarely the face points at the camera (normal sign is
            // ambiguous, so take the magnitude), minus a small distance
            // penalty so between front and back — parallel normals — the
            // NEARER face, the one you actually see, wins.
            let score = abs(simd_dot(worldNormal, toCamera / toCameraDistance)) - 0.03 * toCameraDistance
            if score > bestScore {
                bestScore = score
                best = face
            }
        }
        return best
    }

    /// ✌️ on a closed loop — replaces it with a perfect circle: centre at
    /// the loop's centroid, radius the mean in-plane distance, in the loop's
    /// own plane. Great for pulleys, orbits, and field-line circles.
    private func snapCircle(at index: Int) {
        var loop = strokes[index].points
        if loop.count >= 2, simd_length(loop[0] - loop[loop.count - 1]) < 0.001 {
            loop.removeLast()
        }
        guard loop.count >= 3 else { return }
        let centroid = loop.reduce(simd_float3()) { $0 + $1 } / Float(loop.count)
        let normal = newellNormal(loop)
            ?? simd_normalize(contentNode.simdConvertVector(simd_float3(0, 0, -1), from: nil))
        // Orthonormal basis in the loop's plane.
        var u = simd_cross(normal, simd_float3(0, 0, 1))
        if simd_length(u) < 0.01 {
            u = simd_cross(normal, simd_float3(0, 1, 0))
        }
        u = simd_normalize(u)
        let v = simd_normalize(simd_cross(normal, u))
        // Mean in-plane distance from the centroid = the fitted radius.
        var radius: Float = 0
        for point in loop {
            let offset = point - centroid
            let inPlane = offset - simd_dot(offset, normal) * normal
            radius += simd_length(inPlane)
        }
        radius /= Float(loop.count)
        guard radius * contentScale > 0.05 else { return }
        // Start the circle at the drawn start point's angle so the snap
        // visually "grows from" what you drew.
        let start = loop[0] - centroid
        let startAngle = atan2(simd_dot(start, v), simd_dot(start, u))
        let samples = 32
        var circle: [simd_float3] = []
        for i in 0...samples {
            let angle = startAngle + Float(i) / Float(samples) * 2 * .pi
            circle.append(centroid + radius * (cos(angle) * u + sin(angle) * v))
        }
        rebuildStroke(at: index, with: circle)
    }

    /// Corner detection: Ramer-Douglas-Peucker simplification, with the
    /// tolerance scaled to the stroke's size so big and small shapes both
    /// resolve to their true corners.
    private func detectCorners(of points: [simd_float3]) -> [simd_float3] {
        guard points.count > 2 else { return points }
        var pathLength: Float = 0
        for i in 1..<points.count {
            pathLength += simd_length(points[i] - points[i - 1])
        }
        // The absolute epsilon floor is a world-space value; the relative
        // term is scale-free because pathLength is local like the points.
        let epsilon = max(cornerEpsilon / contentScale, 0.03 * pathLength)
        let closedInput = simd_length(points[0] - points[points.count - 1]) * contentScale < closeThreshold
        var corners = simplify(points, epsilon: epsilon)
        // A closed input repeats its first point last — drop the repeat.
        if corners.count >= 2, simd_length(corners[0] - corners[corners.count - 1]) < closeThreshold {
            corners.removeLast()
        }
        // Closed loops: RDP unconditionally keeps the drawing-start sample,
        // which is a real corner only if you happened to START at a corner.
        // Prune any vertex that is cyclically collinear with its neighbours
        // so a square started mid-edge still resolves to exactly 4 corners
        // (and extrusion depth/connectors stay true).
        if closedInput {
            var changed = true
            while changed, corners.count > 3 {
                changed = false
                for i in corners.indices {
                    let previous = corners[(i + corners.count - 1) % corners.count]
                    let next = corners[(i + 1) % corners.count]
                    if distanceToSegment(corners[i], previous, next) < epsilon {
                        corners.remove(at: i)
                        changed = true
                        break
                    }
                }
            }
        }
        return corners
    }

    private func simplify(_ points: [simd_float3], epsilon: Float) -> [simd_float3] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance: Float = 0
        var maxIndex = 0
        for i in 1..<points.count - 1 {
            let d = distanceToSegment(points[i], first, last)
            if d > maxDistance {
                maxDistance = d
                maxIndex = i
            }
        }
        if maxDistance <= epsilon {
            return [first, last]
        }
        let left = simplify(Array(points[0...maxIndex]), epsilon: epsilon)
        let right = simplify(Array(points[maxIndex...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    private func distanceToSegment(_ p: simd_float3, _ a: simd_float3, _ b: simd_float3) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-8 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return simd_length(p - (a + t * ab))
    }

    /// Newell's method: the average plane normal of a (roughly planar) loop.
    /// Returns nil for degenerate input like a straight line.
    private func newellNormal(_ points: [simd_float3]) -> simd_float3? {
        guard points.count >= 3 else { return nil }
        var normal = simd_float3()
        for i in points.indices {
            let current = points[i]
            let next = points[(i + 1) % points.count]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        let length = simd_length(normal)
        guard length > 0.05 else { return nil }
        return normal / length
    }

    /// Tears down a stroke's geometry and rebuilds it along new points,
    /// keeping its color and thickness.
    private func rebuildStroke(at index: Int, with newPoints: [simd_float3]) {
        var stroke = strokes[index]
        stroke.node.childNodes.forEach { $0.removeFromParentNode() }
        stroke.fillNode = nil // any fill was torn down with the children
        // A snapped stroke's endpoints moved — break healing must not
        // append new drawing onto the rewritten shape.
        lastStrokeEnd = nil
        // Drop consecutive duplicates so segmentNode never sees zero length.
        var cleaned: [simd_float3] = []
        for point in newPoints where cleaned.last.map({ simd_length(point - $0) > 0.0005 }) ?? true {
            cleaned.append(point)
        }
        stroke.points = cleaned
        strokes[index] = stroke
        guard let first = cleaned.first else { return }
        stroke.node.addChildNode(jointSphere(at: first, radius: stroke.radius, color: stroke.color))
        for i in 1..<cleaned.count {
            stroke.node.addChildNode(segmentNode(from: cleaned[i - 1], to: cleaned[i], radius: stroke.radius, color: stroke.color))
            stroke.node.addChildNode(jointSphere(at: cleaned[i], radius: stroke.radius, color: stroke.color))
        }
    }

    // MARK: - Rotation

    /// Spin-the-globe rotation from flat-hand movement (normalized screen
    /// deltas): horizontal movement spins the sculpture around the vertical
    /// axis, vertical movement tilts it forward/back.
    func applyOrbit(dx: CGFloat, dy: CGFloat) {
        let yaw = simd_quatf(angle: Float(dx) * orbitGain, axis: simd_float3(0, 1, 0))
        // Negative: moving the hand up tips the top of the sculpture away,
        // matching how you'd roll a physical globe.
        let pitch = simd_quatf(angle: Float(-dy) * orbitGain, axis: simd_float3(1, 0, 0))
        // Premultiply: both rotations are about *world* axes regardless of
        // the sculpture's current orientation.
        contentNode.simdOrientation = simd_normalize(yaw * pitch * contentNode.simdOrientation)
        syncGizmo()
    }

    /// Two-hand carry: camera-normalized delta → world translation on the
    /// camera plane. The delta passes through the same aspect-fill crop as
    /// stroke points, so the sculpture tracks the hands 1:1 on screen.
    func applyTranslation(dx: CGFloat, dy: CGFloat) {
        var viewDx = dx
        var viewDy = dy
        let cameraAspect = CameraViewMapper.cameraAspect
        if viewAspect >= cameraAspect {
            viewDy /= cameraAspect / viewAspect   // top/bottom cropped
        } else {
            viewDx /= viewAspect / cameraAspect   // sides cropped
        }
        let extent = visibleExtent()
        contentNode.simdPosition += simd_float3(Float(viewDx) * extent.width, Float(viewDy) * extent.height, 0)
    }

    /// Orb-hold roll: the two-hand pair rotated by `delta` radians spins the
    /// sculpture about the screen axis, 1:1 — like turning a ball you hold.
    func applyRoll(_ delta: CGFloat) {
        let roll = simd_quatf(angle: Float(delta), axis: simd_float3(0, 0, 1))
        contentNode.simdOrientation = simd_normalize(roll * contentNode.simdOrientation)
        syncGizmo()
    }

    /// Two-hand pinch resize. Total scale is clamped so the sculpture can
    /// neither vanish nor explode.
    func applyScale(_ factor: CGFloat) {
        let target = min(6, max(0.15, contentNode.simdScale.x * Float(factor)))
        contentNode.simdScale = simd_float3(repeating: target)
    }

    // MARK: - Housekeeping

    func clearAll() {
        contentNode.childNodes.forEach { $0.removeFromParentNode() }
        strokes.removeAll()
        strokePending = false
        activeStrokeIndex = nil
        lastStrokeEnd = nil
        skipGlitchGuardOnce = false
        lastPoint = nil
        smoothedDrawPoint = nil
        strokeCount = 0
        // A fresh canvas also gets a fresh view — leaving a stale zoom/pan
        // behind an empty screen just looks like the app broke.
        resetOrientation()
    }

    /// Reset View: orientation, carry offset, and scale all go home.
    func resetOrientation() {
        contentNode.simdOrientation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        contentNode.simdPosition = .zero
        contentNode.simdScale = simd_float3(repeating: 1)
        syncGizmo()
    }

    // MARK: - Coordinate mapping

    /// Camera-normalized point → world point on the plane z = 0.
    ///
    /// Two steps: (1) camera → view coordinates through the same aspect-fill
    /// crop the video feed uses, (2) view → world using the extent of the
    /// z = 0 plane visible to the SceneKit camera. Vision has no depth from a
    /// single camera, so depth comes from rotating the sculpture, not the hand.
    private func worldPoint(fromCameraPoint point: CGPoint) -> simd_float3 {
        let view = CameraViewMapper.viewPoint(fromCameraPoint: point, viewAspect: viewAspect)
        let extent = visibleExtent()
        return simd_float3(
            (Float(view.x) - 0.5) * extent.width,
            (Float(view.y) - 0.5) * extent.height,
            0
        )
    }

    /// World-space size of the z = 0 plane region the window shows.
    private func visibleExtent() -> (width: Float, height: Float) {
        let height = 2 * cameraDistance * Float(tan(verticalFOV / 2 * .pi / 180))
        return (height * Float(viewAspect), height)
    }

    // MARK: - Scene setup

    private func setUpScene() {
        // No background — the scene is composited over the live camera feed.
        scene.background.contents = nil

        let camera = SCNCamera()
        camera.zFar = 200
        camera.fieldOfView = verticalFOV
        camera.projectionDirection = .vertical
        cameraNode.camera = camera
        cameraNode.simdPosition = simd_float3(0, 0, cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.simdPosition = simd_float3(6, 8, 12)
        scene.rootNode.addChildNode(key)

        scene.rootNode.addChildNode(contentNode)
    }

    /// Orientation cube: CAD-style axis colours — red = X faces, green = Y,
    /// blue = Z (brighter on the positive side). Dragging it rotates the
    /// sculpture; its orientation always mirrors contentNode.
    private func setUpGizmo() {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.85
        gizmoCameraNode.camera = camera
        gizmoCameraNode.simdPosition = simd_float3(0, 0, 3)
        gizmoScene.rootNode.addChildNode(gizmoCameraNode)

        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1)
        func face(_ color: NSColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.lightingModel = .constant
            return material
        }
        // SCNBox material order: +Z, +X, -Z, -X, +Y, -Y.
        box.materials = [
            face(.systemBlue),
            face(.systemRed),
            face(NSColor.systemBlue.blended(withFraction: 0.55, of: .black) ?? .darkGray),
            face(NSColor.systemRed.blended(withFraction: 0.55, of: .black) ?? .darkGray),
            face(.systemGreen),
            face(NSColor.systemGreen.blended(withFraction: 0.55, of: .black) ?? .darkGray),
        ]
        gizmoCube.geometry = box
        gizmoScene.rootNode.addChildNode(gizmoCube)
        gizmoScene.background.contents = nil
        syncGizmo()
    }

    private func syncGizmo() {
        gizmoCube.simdOrientation = contentNode.simdOrientation
    }

    // MARK: - Geometry helpers

    /// Cylinder between two points. SCNCylinder's axis is local Y, so the
    /// node is positioned at the midpoint and rotated from Y to the segment
    /// direction.
    private func segmentNode(from a: simd_float3, to b: simd_float3, radius: CGFloat, color: NSColor) -> SCNNode {
        let vector = b - a
        let length = simd_length(vector)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        // 12 radial segments reads as a genuinely round cylinder even at the
        // thick end of the slider, while hundreds of segments stay cheap.
        cylinder.radialSegmentCount = 12
        cylinder.firstMaterial = strokeMaterial(color)
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = orientation(fromYAxisTo: vector / length)
        return node
    }

    /// Small sphere at each sampled point — rounds off the seams between
    /// cylinder segments so strokes read as one continuous tube.
    private func jointSphere(at position: simd_float3, radius: CGFloat, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 12
        sphere.firstMaterial = strokeMaterial(color)
        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        return node
    }

    private func strokeMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        // Emission is kept LOW on purpose: strong emission fills in the
        // shadow side of the tube and makes it read as a flat marker line.
        // The diffuse falloff + specular highlight are what make the
        // cylinders look round. Raise toward 0.3 only if strokes get lost
        // against a very bright room.
        material.emission.contents = color.withAlphaComponent(0.1)
        material.specular.contents = NSColor.white
        material.shininess = 0.6
        return material
    }

    /// Quaternion rotating the +Y axis onto `direction` (which must be
    /// normalized). Handles the antiparallel case explicitly because
    /// simd_quatf(from:to:) is undefined for opposite vectors.
    private func orientation(fromYAxisTo direction: simd_float3) -> simd_quatf {
        let up = simd_float3(0, 1, 0)
        if simd_dot(up, direction) < -0.9999 {
            return simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        }
        return simd_quatf(from: up, to: direction)
    }
}
