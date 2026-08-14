import CoreGraphics

/// Turns per-frame hand landmarks into discrete gesture events.
///
/// State machine: `idle` ⇄ `active`, toggled by a debounced rock sign 🤘.
/// While active: pointing index finger = draw (the stroke follows the index
/// tip), flat open hand moved = rotate (spin-the-globe style: the palm's
/// on-screen movement drives rotation, because palm *twist* is nearly
/// invisible to a single 2D camera — fingers just foreshorten).
@MainActor
final class GestureStateMachine {

    // MARK: - Tunable thresholds

    /// Consecutive frames the rock sign must be held before it toggles
    /// idle/active. At ~30 fps, 6 frames ≈ 200 ms. Raise (toward 8–10) if you
    /// get accidental toggles; lower if toggling feels sluggish.
    private let rockConfirmFrames = 6

    /// Consecutive non-rock frames required before the rock sign is "re-armed"
    /// and can toggle again. This forces the hand to actually leave the pose,
    /// so holding one long 🤘 can never toggle twice.
    private let rockReleaseFrames = 5

    /// A finger counts as *extended* when its tip is this factor farther from
    /// the wrist than its PIP (middle knuckle). 1.15 tolerates slightly bent
    /// but clearly raised fingers; raise toward 1.3 to require straighter fingers.
    private let extendedFactor: CGFloat = 1.15

    /// A finger counts as *curled* when its tip is closer to the wrist than
    /// PIP × this factor. 1.0 means "tip inside the knuckle". Raise toward 1.1
    /// if curled fingers aren't being recognized as curled.
    private let curledFactor: CGFloat = 1.0

    /// Thumb counts as "across the palm" when the thumb tip sits within this
    /// fraction of the palm length (wrist→middle MCP) of the middle MCP.
    /// This is the least reliable part of rock-sign detection — loosen (raise
    /// toward 1.0) or delete the check in `isRockSign` if toggling is finicky.
    private let thumbAcrossRatio: CGFloat = 0.7

    /// Consecutive frames the pointing pose (index out, others curled) must
    /// be held before drawing starts. At ~30 fps, 3 frames ≈ 100 ms. This
    /// debounce replaces the distance hysteresis the old pinch gesture had.
    private let drawStartFrames = 3

    /// Consecutive non-pointing frames before the stroke ends. Larger than
    /// drawStartFrames so glitchy frames mid-stroke don't cut the line.
    private let drawStopFrames = 6

    /// Pose hysteresis for CONTINUING a stroke (vs. the strict factors that
    /// START one): while drawing, the index only needs to be at least as far
    /// out as its knuckle, and the other fingers merely "not fully
    /// extended". A finger hovering at the strict threshold can no longer
    /// chop a line into fragments; you still end cleanly by extending the
    /// other fingers or curling the index.
    private let continueExtendedFactor: CGFloat = 1.0
    private let continueCurledFactor: CGFloat = 1.3

    /// Frames of *lost hand tracking* tolerated mid-stroke before the stroke
    /// ends (~200 ms at 30 fps). Vision dropping the hand for a frame or two
    /// is common during fast motion and used to break lines.
    private let lostFrameTolerance = 6

    /// Consecutive frames 🤙 / ✌️ must be held to snap the last stroke
    /// (straighten / smooth). 6 ≈ 200 ms — long enough that a hand briefly
    /// passing through these shapes while forming another pose never fires.
    private let snapConfirmFrames = 6

    /// Thumb counts as sticking OUT (for 🤙) when the thumb tip is at least
    /// this fraction of the palm length from the middle-finger base — the
    /// mirror image of `thumbAcrossRatio`. Lower it if 🤙 is hard to trigger.
    private let thumbOutRatio: CGFloat = 0.6

    /// Two-hand grab: a hand counts as pinching when its thumb and index
    /// tips are within this fraction of the palm length.
    private let pinchRatio: CGFloat = 0.4

    /// Once the resize grip is engaged it only releases when a hand opens
    /// past this larger fraction (hysteresis) — without it, the pinch
    /// classification flickering for a frame kept aborting the resize.
    private let pinchReleaseRatio: CGFloat = 0.75

    /// Per-frame two-hand midpoint movement above this (normalized units) is
    /// a tracking glitch and ignored.
    private let maxTranslateStep: CGFloat = 0.12

    /// Frames of single-hand input ignored right after a two-hand
    /// interaction. Vision dropping ONE of two hands for a few frames is
    /// routine during a carry — without this pause the surviving open palm
    /// would fall into the single-hand rotate path and spin the sculpture
    /// mid-carry.
    private let handTransitionCooldown = 8

    /// Per-frame palm movement (normalized screen units) above this is a
    /// tracking glitch and is ignored — 0.08 means jumping 8% of the screen
    /// in a single frame.
    private let maxOrbitStep: CGFloat = 0.08

    /// Palm movement below this is jitter and ignored, so a flat hand held
    /// still doesn't make the sculpture drift.
    private let minOrbitStep: CGFloat = 0.0015

    // MARK: - State

    private(set) var state: GestureState = .idle
    private var rockStreak = 0
    private var nonRockStreak = 0
    private var rockArmed = true
    private var isDrawing = false
    private var pointStreak = 0
    private var nonPointStreak = 0
    private var lostFrameStreak = 0
    private var shakaStreak = 0
    private var shakaArmed = true
    private var peaceStreak = 0
    private var peaceArmed = true
    private var previousPalmCenter: CGPoint?
    private var previousHandMidpoint: CGPoint?
    private var previousHandDistance: CGFloat?
    private var previousHandAngle: CGFloat?
    private var scaleGripActive = false
    private var singleHandCooldown = 0

    /// Emoji label of what the detector recognized this frame — shown in the
    /// HUD so you can SEE what the machine thinks your hand is doing
    /// (invaluable when a gesture "does nothing": if the label never shows
    /// 🤙, it's the detector; if it shows 🤙, it's the action).
    private(set) var poseLabel = "—"

    // MARK: - Per-frame processing

    /// Entry point: 0 hands = dropout handling, 1 hand = draw/rotate/snap
    /// gestures, 2 hands = move (both open) / resize (both pinching).
    func process(_ frames: [HandFrame]) -> [GestureEvent] {
        if frames.count >= 2 {
            singleHandCooldown = handTransitionCooldown
            return processTwoHands(frames[0], frames[1])
        }
        if singleHandCooldown > 0 {
            // Fewer hands right after a two-hand interaction is usually
            // Vision momentarily losing one, not the user letting go — hold
            // everything, INCLUDING the grab references, so a resize or
            // carry continues seamlessly when the hand reappears. (Resetting
            // the references here was why resizing kept stuttering.)
            singleHandCooldown -= 1
            return []
        }
        resetTwoHandTracking()
        return processSingleHand(frames.first)
    }

    private func processTwoHands(_ a: HandFrame, _ b: HandFrame) -> [GestureEvent] {
        lostFrameStreak = 0
        var events: [GestureEvent] = []
        // A second hand cancels any in-progress stroke — you can't draw and
        // grab at the same time — and clears single-hand pose evidence.
        if isDrawing {
            isDrawing = false
            nonPointStreak = 0
            events.append(.strokeEnded)
        }
        pointStreak = 0
        shakaStreak = 0
        peaceStreak = 0
        rockStreak = 0 // transition frames must not ratchet toward a toggle
        previousPalmCenter = nil

        // Manipulation lives in MOVE mode (idle) only, so it can never be
        // confused with drawing gestures.
        guard state == .idle,
              let centerA = palmCenter(a),
              let centerB = palmCenter(b) else {
            poseLabel = "✋✋"
            resetTwoHandTracking()
            return events
        }

        let midpoint = CGPoint(x: (centerA.x + centerB.x) / 2, y: (centerA.y + centerB.y) / 2)
        // Aspect-corrected gap: normalized x units span a 16:9 frame while y
        // spans its height, so a raw hypot changes when the hand pair merely
        // rotates. Correcting x by the camera aspect makes the gap
        // proportional to the hands' physical separation.
        let handGap = hypot(
            (centerA.x - centerB.x) * CameraViewMapper.cameraAspect,
            centerA.y - centerB.y
        )

        // Grip hysteresis: engaging needs a clear pinch on both hands, but
        // once engaged the grip survives until a hand distinctly opens.
        let engaged = isPinching(a, within: pinchRatio) && isPinching(b, within: pinchRatio)
        let held = isPinching(a, within: pinchReleaseRatio) && isPinching(b, within: pinchReleaseRatio)
        if scaleGripActive ? held : engaged {
            // 🤏🤏 Both hands pinching → resize: the change in the distance
            // between the hands scales the sculpture (spread = grow).
            scaleGripActive = true
            poseLabel = "🤏🤏"
            if let previous = previousHandDistance, previous > 0.02 {
                let factor = handGap / previous
                // Per-frame clamp rejects tracking glitches.
                if factor > 0.5, factor < 2.0 {
                    events.append(.scaleDelta(factor))
                }
            }
            previousHandDistance = handGap
            previousHandMidpoint = nil
        } else if isOpenPalm(a), isOpenPalm(b) {
            scaleGripActive = false
            // 🖐🖐 Both hands open → hold the orb: the midpoint between the
            // hands carries the sculpture, and turning the hand PAIR (the
            // angle of the line between them, aspect-corrected like the gap)
            // rolls it — move and re-orient in one continuous grab.
            poseLabel = "🖐🖐"
            if let previous = previousHandMidpoint {
                let dx = midpoint.x - previous.x
                let dy = midpoint.y - previous.y
                if abs(dx) < maxTranslateStep, abs(dy) < maxTranslateStep,
                   abs(dx) > minOrbitStep || abs(dy) > minOrbitStep {
                    events.append(.translateDelta(dx: dx, dy: dy))
                }
            }
            previousHandMidpoint = midpoint

            let pairAngle = atan2(
                centerB.y - centerA.y,
                (centerB.x - centerA.x) * CameraViewMapper.cameraAspect
            )
            if let previousAngle = previousHandAngle {
                var delta = pairAngle - previousAngle
                // Wrap across the atan2 seam; the 0.3 rad clamp also rejects
                // the ~π flip when crossing hands swap left/right slots.
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                if abs(delta) > 0.002, abs(delta) < 0.3 {
                    events.append(.rollDelta(delta))
                }
            }
            previousHandAngle = pairAngle
            previousHandDistance = nil
        } else {
            poseLabel = "✋✋"
            resetTwoHandTracking()
        }
        return events
    }

    private func resetTwoHandTracking() {
        previousHandMidpoint = nil
        previousHandDistance = nil
        previousHandAngle = nil
        scaleGripActive = false
    }

    private func processSingleHand(_ frame: HandFrame?) -> [GestureEvent] {
        guard let frame else {
            poseLabel = "—"
            // Tolerate brief tracking dropouts in EVERY state: hold the pen,
            // the streaks, and the once-per-hold latches exactly as they
            // are. Resetting on a single lost frame used to let one held 🤘
            // toggle twice (the dropout re-armed it mid-hold).
            lostFrameStreak += 1
            if lostFrameStreak <= lostFrameTolerance {
                return []
            }
            return handLost()
        }
        lostFrameStreak = 0
        var events: [GestureEvent] = []

        // --- Rock sign: debounce + re-arm ---
        let rock = isRockSign(frame)
        updatePoseLabel(frame, rock: rock)
        if rock {
            rockStreak += 1
            nonRockStreak = 0
        } else {
            // Any single miss resets the streak — "consecutive" means
            // consecutive, otherwise borderline flicker ratchets up to a
            // toggle that was never deliberately held.
            rockStreak = 0
            nonRockStreak += 1
            if nonRockStreak >= rockReleaseFrames {
                rockArmed = true
            }
        }
        if rockArmed && rockStreak >= rockConfirmFrames {
            rockArmed = false // stays disarmed until the pose is released
            state = (state == .idle) ? .active : .idle
            if state == .idle, isDrawing {
                isDrawing = false
                events.append(.strokeEnded)
            }
            previousPalmCenter = nil
            resetTwoHandTracking()
            events.append(.stateChanged(state))
        }

        // Never draw or manipulate while the hand still holds the rock pose
        // (avoids junk actions mid-toggle). Streaks reset so pose evidence
        // gathered mid-toggle can't instantly fire a gesture afterwards.
        guard !rock else {
            previousPalmCenter = nil
            pointStreak = 0
            shakaStreak = 0
            peaceStreak = 0
            return events
        }

        // --- MOVE mode (idle): single flat hand turns the sculpture ---
        // All movement lives here, fully separated from drawing, so 👆 and
        // 🤏 can never be mistaken for each other across modes.
        guard state == .active else {
            pointStreak = 0
            shakaStreak = 0
            peaceStreak = 0
            if isOpenPalm(frame), let center = palmCenter(frame) {
                if let previous = previousPalmCenter {
                    let dx = center.x - previous.x
                    let dy = center.y - previous.y
                    if abs(dx) < maxOrbitStep, abs(dy) < maxOrbitStep,
                       abs(dx) > minOrbitStep || abs(dy) > minOrbitStep {
                        events.append(.orbitDelta(dx: dx, dy: dy))
                    }
                }
                previousPalmCenter = center
            } else {
                previousPalmCenter = nil
            }
            return events
        }

        // --- Pointing index finger → draw ---
        // The stroke follows the index fingertip while the hand holds the
        // pointing pose (index extended, middle/ring/little curled). Curling
        // the other fingers is what distinguishes drawing from the flat
        // rotate pose, and the curled pinky distinguishes it from 🤘.
        // Starting uses the STRICT pose; continuing uses the RELAXED pose
        // (hysteresis), so borderline fingers can't fragment a line.
        if isDrawing {
            // A fully-formed ✌️ or flat hand must ALWAYS count toward ending
            // the stroke: those poses overlap the relaxed continue band
            // (continueCurledFactor > extendedFactor), and without this
            // check a held peace/flat hand could keep the stroke alive
            // forever — never ending, never snapping, never rotating.
            let deliberateExit = isPeace(frame) || isOpenPalm(frame)
            if !deliberateExit, isPointing(frame, relaxed: true) {
                nonPointStreak = 0
            } else {
                nonPointStreak += 1
            }
            if nonPointStreak >= drawStopFrames {
                isDrawing = false
                events.append(.strokeEnded)
            }
        } else {
            if isPointing(frame, relaxed: false) {
                pointStreak += 1
            } else {
                pointStreak = 0
            }
            if pointStreak >= drawStartFrames {
                isDrawing = true
                pointStreak = 0
                nonPointStreak = 0
                events.append(.strokeBegan)
            }
        }
        if isDrawing {
            if let indexTip = frame[.indexTip] {
                events.append(.strokePoint(indexTip))
            }
            previousPalmCenter = nil
            return events
        }

        // --- Snap gestures: 🤙 straighten, ✌️ smooth curve ---
        // Each fires ONCE per hold (re-arms only after the pose is released)
        // and rewrites the most recently finished stroke — like the shape
        // correction in drawing apps.
        let shaka = isShaka(frame)
        if shaka {
            shakaStreak += 1
        } else {
            shakaStreak = 0
            shakaArmed = true
        }
        if shakaArmed, shakaStreak >= snapConfirmFrames {
            shakaArmed = false
            events.append(.straightenStroke)
        }
        let peace = isPeace(frame)
        if peace {
            peaceStreak += 1
        } else {
            peaceStreak = 0
            peaceArmed = true
        }
        if peaceArmed, peaceStreak >= snapConfirmFrames {
            peaceArmed = false
            events.append(.smoothStroke)
        }
        if shaka || peace {
            previousPalmCenter = nil
            return events
        }

        // DRAW mode has no movement gestures — manipulation lives in MOVE
        // mode (idle).
        previousPalmCenter = nil
        return events
    }

    /// Hand disappeared from the frame. Note the idle/active state is kept —
    /// a momentary tracking dropout shouldn't kick you out of active mode.
    private func handLost() -> [GestureEvent] {
        rockStreak = 0
        nonRockStreak = 0
        rockArmed = true
        pointStreak = 0
        nonPointStreak = 0
        shakaStreak = 0
        shakaArmed = true
        peaceStreak = 0
        peaceArmed = true
        previousPalmCenter = nil
        if isDrawing {
            isDrawing = false
            return [.strokeEnded]
        }
        return []
    }

    private func updatePoseLabel(_ frame: HandFrame, rock: Bool) {
        if rock {
            poseLabel = "🤘"
        } else if isPointing(frame, relaxed: false) {
            poseLabel = "👆"
        } else if isShaka(frame) {
            poseLabel = "🤙"
        } else if isPeace(frame) {
            poseLabel = "✌️"
        } else if isOpenPalm(frame) {
            poseLabel = "🖐"
        } else {
            poseLabel = "·"
        }
    }

    /// One hand pinching (thumb + index together) — the two-hand resize
    /// grip. The index TIP is often occluded by the thumb mid-pinch and
    /// drops below Vision's confidence gate, so the DIP knuckle serves as a
    /// fallback; without it the pinch classification flickered constantly.
    private func isPinching(_ frame: HandFrame, within ratio: CGFloat) -> Bool {
        guard let thumbTip = frame[.thumbTip],
              let palmLength = palmLength(frame),
              let indexPoint = frame[.indexTip] ?? frame[.indexDIP] else { return false }
        return distance(thumbTip, indexPoint) < ratio * palmLength
    }

    // MARK: - Pose predicates

    /// Rock sign 🤘: index + little extended, middle + ring curled, thumb
    /// folded across the palm.
    private func isRockSign(_ frame: HandFrame) -> Bool {
        guard let wrist = frame[.wrist],
              let thumbTip = frame[.thumbTip],
              let middleMCP = frame[.middleMCP],
              let palmLength = palmLength(frame) else { return false }

        guard isExtended(frame, tip: .indexTip, pip: .indexPIP, wrist: wrist),
              isExtended(frame, tip: .littleTip, pip: .littlePIP, wrist: wrist),
              isCurled(frame, tip: .middleTip, pip: .middlePIP, wrist: wrist),
              isCurled(frame, tip: .ringTip, pip: .ringPIP, wrist: wrist) else {
            return false
        }
        // Thumb across the palm: thumb tip near the middle-finger base.
        return distance(thumbTip, middleMCP) < thumbAcrossRatio * palmLength
    }

    /// Flat open hand: index, middle, and ring extended. The pinky and thumb
    /// are deliberately NOT tested — they're the least reliably tracked
    /// joints and the first to foreshorten when the palm tilts, which used
    /// to make this pose impossible to hold. No ambiguity is lost: pointing
    /// and 🤘 both require a *curled* middle+ring, so they can never pass.
    private func isOpenPalm(_ frame: HandFrame) -> Bool {
        guard let wrist = frame[.wrist] else { return false }
        return isExtended(frame, tip: .indexTip, pip: .indexPIP, wrist: wrist)
            && isExtended(frame, tip: .middleTip, pip: .middlePIP, wrist: wrist)
            && isExtended(frame, tip: .ringTip, pip: .ringPIP, wrist: wrist)
    }

    /// Shaka 🤙: pinky out, index curled, thumb away from the palm. Only
    /// three checks on purpose — the middle/ring-curled tests were dropped
    /// because they track poorly in this pose and made 🤙 nearly impossible
    /// to hit. No ambiguity is lost: index-curled + pinky-out is already
    /// unique (🤘, ✌️, 👆, and 🖐 all need the index extended).
    private func isShaka(_ frame: HandFrame) -> Bool {
        guard let wrist = frame[.wrist],
              let thumbTip = frame[.thumbTip],
              let middleMCP = frame[.middleMCP],
              let palmLength = palmLength(frame) else { return false }
        return isExtended(frame, tip: .littleTip, pip: .littlePIP, wrist: wrist)
            && isCurled(frame, tip: .indexTip, pip: .indexPIP, wrist: wrist)
            && distance(thumbTip, middleMCP) > thumbOutRatio * palmLength
    }

    /// Peace ✌️: index + middle extended, ring + pinky curled. The curled
    /// ring separates it from the flat rotate pose; the extended middle
    /// separates it from the pointing (draw) pose.
    private func isPeace(_ frame: HandFrame) -> Bool {
        guard let wrist = frame[.wrist] else { return false }
        return isExtended(frame, tip: .indexTip, pip: .indexPIP, wrist: wrist)
            && isExtended(frame, tip: .middleTip, pip: .middlePIP, wrist: wrist)
            && isCurled(frame, tip: .ringTip, pip: .ringPIP, wrist: wrist)
            && isCurled(frame, tip: .littleTip, pip: .littlePIP, wrist: wrist)
    }

    /// Midpoint of wrist and middle-finger base — a stable "center of the
    /// palm" that barely moves when individual fingers wiggle.
    private func palmCenter(_ frame: HandFrame) -> CGPoint? {
        guard let wrist = frame[.wrist], let middleMCP = frame[.middleMCP] else { return nil }
        return CGPoint(x: (wrist.x + middleMCP.x) / 2, y: (wrist.y + middleMCP.y) / 2)
    }

    /// Pointing pose: index extended, middle/ring/little curled. The thumb
    /// is ignored — people hold it anywhere while pointing.
    /// `relaxed` widens the acceptance band for stroke continuation (see
    /// continueExtendedFactor/continueCurledFactor).
    private func isPointing(_ frame: HandFrame, relaxed: Bool) -> Bool {
        guard let wrist = frame[.wrist] else { return false }
        let extendedThreshold = relaxed ? continueExtendedFactor : extendedFactor
        let curledThreshold = relaxed ? continueCurledFactor : curledFactor
        guard let index = fingerRatio(frame, tip: .indexTip, pip: .indexPIP, wrist: wrist),
              let middle = fingerRatio(frame, tip: .middleTip, pip: .middlePIP, wrist: wrist),
              let ring = fingerRatio(frame, tip: .ringTip, pip: .ringPIP, wrist: wrist),
              let little = fingerRatio(frame, tip: .littleTip, pip: .littlePIP, wrist: wrist) else {
            return false
        }
        return index > extendedThreshold
            && middle < curledThreshold
            && ring < curledThreshold
            && little < curledThreshold
    }

    private func isExtended(_ frame: HandFrame, tip: HandJoint, pip: HandJoint, wrist: CGPoint) -> Bool {
        guard let ratio = fingerRatio(frame, tip: tip, pip: pip, wrist: wrist) else { return false }
        return ratio > extendedFactor
    }

    private func isCurled(_ frame: HandFrame, tip: HandJoint, pip: HandJoint, wrist: CGPoint) -> Bool {
        guard let ratio = fingerRatio(frame, tip: tip, pip: pip, wrist: wrist) else { return false }
        return ratio < curledFactor
    }

    /// tip-to-wrist distance over PIP-to-wrist distance: > 1 means the
    /// fingertip is beyond its knuckle (extending), < 1 means folded inside.
    private func fingerRatio(_ frame: HandFrame, tip: HandJoint, pip: HandJoint, wrist: CGPoint) -> CGFloat? {
        guard let tipPoint = frame[tip], let pipPoint = frame[pip] else { return nil }
        let pipDistance = distance(pipPoint, wrist)
        guard pipDistance > 0.001 else { return nil }
        return distance(tipPoint, wrist) / pipDistance
    }

    /// Wrist → middle-finger-base distance: a scale reference proportional to
    /// how big the hand appears, used to normalize every other threshold.
    private func palmLength(_ frame: HandFrame) -> CGFloat? {
        guard let wrist = frame[.wrist], let middleMCP = frame[.middleMCP] else { return nil }
        let length = distance(wrist, middleMCP)
        return length > 0.001 ? length : nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
