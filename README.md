# AirSculpt

Gesture-controlled 3D drawing for macOS using only the built-in webcam.
Swift + SwiftUI + AVFoundation + Vision (`VNDetectHumanHandPoseRequest`) + SceneKit — no third-party dependencies.

## Run

```sh
cd AirSculpt
swift run              # quick start (camera permission attributed to your terminal)
```

or build a real app bundle (recommended — stable camera-permission identity):

```sh
./make-app.sh
open AirSculpt.app
```

Requires macOS 14+. Grant camera access when prompted (if you previously denied it: System Settings → Privacy & Security → Camera).

## How to use

The whole window is your mirror: the live camera feed fills it, and strokes float in the room around you, landing exactly under your fingertips.

1. Show **one hand** to the camera. A faint skeleton overlays your hand — the index tip (your pen) is highlighted yellow.
2. The app has two modes, flipped by the **🤘 rock sign** (index + pinky out, middle + ring curled, thumb across palm), held ~¼ second — release the pose before you can toggle again. **MOVE mode** (cyan) manipulates the sculpture; **DRAW mode** (green) draws. Keeping them exclusive is what stops gestures from being confused with each other.
3. In **MOVE mode**:
   - **Single flat hand**, moved → turns the sculpture (spin/tilt, like rolling a globe).
   - **Both hands open 🖐🖐** → hold the orb: moving your hands carries the sculpture, and **twisting the hand pair rolls it** — move and re-orient in one grab, like handling a real ball.
   - **Both hands pinching 🤏🤏** → spread apart to enlarge, bring together to shrink.
4. In **DRAW mode**:
   - **Point your index finger** (other fingers curled, like pointing at the screen) and move → draws a 2D cylinder-tube stroke that follows your fingertip. Relax the pose to end the stroke.
   - **🤙 Shaka** (thumb + pinky out), held ~⅕ second → snaps your **last stroke straight**: an open stroke becomes a perfectly straight line; a **closed loop becomes a clean polygon** (corners auto-detected, straight edges).
   - **✌️ Peace** (index + middle out), held ~⅕ second → smooths your **last stroke**: an open stroke becomes a clean curve (quadratic Bézier fit — ideal for trajectories); a **closed loop becomes a perfect circle**. Release and re-form a snap pose before it can fire again.
5. **Real 3D objects — Extrude** (`⌘E`): pulls your last shape into 3D. A square becomes a cube, a triangle a prism: a copy of the shape is placed at depth and connected **corner-to-corner from the detected vertices** — never random edges. Best workflow: draw a rough square → 🤙 (clean polygon) → Extrude.
6. **Fill** (`⌘F`): fills the last closed shape with a translucent wash of its colour; press again to remove. On an **extruded object** it fills whichever face — front, back, or side — is toward the camera right now: rotate, then Fill the face you see. The **colour picker** in the HUD sets the colour of new strokes (until then the palette auto-cycles).
7. **Orientation cube** (top-right, like Blender/CAD): shows the sculpture's orientation (red = X, green = Y, blue = Z faces). **Drag it with the mouse** to rotate, **double-click** to reset the view.
9. **Pose readout**: the HUD shows an emoji of whatever pose the detector currently recognizes (👆🤘🤙✌️🖐, or 🖐🖐/🤏🤏 for two hands). If a gesture "does nothing", glance there — it tells you whether the problem is detection or the action.
10. **Connected diagrams**: a stroke that starts or ends on an existing line **locks onto it in 3D** — even when rotation has put that line at a different depth. Vectors stay attached to the bodies they act on.
11. The **thickness slider** in the HUD sets the tube radius for the next stroke. `⌘Z` undoes the last stroke, `⌘K` clears the canvas, `⌘R` resets the rotation. The green full-screen button gives the full "around you" effect.

## Architecture

| Module | File | Role |
|---|---|---|
| CameraManager | `Camera/CameraManager.swift` | AVCaptureSession, 1280×720 BGRA frames on a background queue |
| HandTracker | `Tracking/HandTracker.swift` | Vision hand-pose per frame → mirrored, confidence-filtered, One-Euro-smoothed landmarks |
| GestureStateMachine | `Gestures/GestureStateMachine.swift` | idle⇄active, rock-sign debounce + re-arm, pointing-pose draw debounce, flat-hand rotation gate |
| SceneController | `Scene/SceneController.swift` | Transparent SceneKit scene over the camera feed; strokes as cylinder+sphere tubes; rotation transforms |
| CameraViewMapper | `CameraViewMapper.swift` | Maps camera coordinates through the aspect-fill crop so strokes/overlay align with your real hand |
| AppModel | `AppModel.swift` | Wires camera queue → main actor; drives SwiftUI state |
| UI | `UI/*.swift` | SceneView canvas, camera preview + landmark overlay, HUD |

Threading: Vision runs synchronously on the camera queue (so `CMSampleBuffer` never crosses threads); only the small `Sendable` `HandFrame` value hops to the main actor, where gestures and SceneKit live.

Depth: Vision gives 2D image coordinates only, so points map onto a fixed camera-facing plane; the rotation gesture spins the sculpture (`contentNode`), and new strokes are converted into its rotated local space — that's where the 3D comes from.

## Tuning guide

All thresholds live as commented constants:

| Constant | File | Default | Effect |
|---|---|---|---|
| `minimumConfidence` | HandTracker | 0.3 | Drop low-confidence landmarks. Raise if ghost joints appear. |
| `minCutoff` | OneEuroFilter | 1.2 Hz | Lower = steadier when holding still, laggier slow moves. |
| `beta` | OneEuroFilter | 4.0 | Raise if fast strokes trail behind the finger. |
| `rockConfirmFrames` | GestureStateMachine | 6 (~200 ms) | Frames of 🤘 needed to toggle. |
| `rockReleaseFrames` | GestureStateMachine | 5 | Non-🤘 frames before it can toggle again. |
| `extendedFactor` / `curledFactor` | GestureStateMachine | 1.15 / 1.0 | Finger extended/curled tests (tip vs PIP distance from wrist). |
| `thumbAcrossRatio` | GestureStateMachine | 0.7 | Thumb-across-palm test. **Loosen or delete first** if 🤘 won't trigger. |
| `drawStartFrames` / `drawStopFrames` | GestureStateMachine | 3 / 6 | Frames of pointing pose to start / non-pointing to stop a stroke. |
| `continueExtendedFactor` / `continueCurledFactor` | GestureStateMachine | 1.0 / 1.3 | Relaxed pose band that keeps a stroke alive (anti-fragmentation hysteresis). |
| `lostFrameTolerance` | GestureStateMachine | 6 | Frames of lost hand tracking tolerated mid-stroke. |
| `joinWindow` / `joinDistance` | SceneController | 0.8 s / 0.7 | A stroke starting this soon + close to the last one's end continues it (break healing). |
| `lockRadius` | SceneController | 0.35 | On-screen distance within which stroke starts/ends lock onto existing lines in 3D. |
| `closeThreshold` | SceneController | 0.5 | Endpoint gap below which a stroke counts as a closed loop (polygon/fill/extrude). |
| `cornerEpsilon` | SceneController | 0.22 | Corner-detection tolerance for polygon snap and extrusion connectors. |
| `extrusionDepthFactor` | SceneController | 1.0 | Extrusion depth as a multiple of average edge length (1.0: square → cube). |
| `snapConfirmFrames` | GestureStateMachine | 6 (~200 ms) | Hold time for 🤙/✌️ before the last stroke is snapped. |
| `thumbOutRatio` | GestureStateMachine | 0.8 | Thumb-sticking-out test for 🤙. Lower if shaka won't trigger. |
| `strokeSmoothing` | SceneController | 0.45 | Extra anti-wobble smoothing on draw points (0 = off, higher = steadier/laggier). |
| `minStrokeLength` | SceneController | 0.3 | Strokes shorter than this are auto-deleted as accidental flicks (0 keeps tap-dots). |
| `maxOrbitStep` / `minOrbitStep` | GestureStateMachine | 0.08 / 0.0015 | Reject glitchy palm jumps / ignore drift jitter. |
| `pinchRatio` / `pinchReleaseRatio` | GestureStateMachine | 0.4 / 0.75 | Two-hand resize grip engage / release (hysteresis). |
| `handTransitionCooldown` | GestureStateMachine | 8 frames | Grace period bridging two-hand ↔ one-hand tracking flicker. |
| `strokeThickness` | SceneController / HUD slider | 0.07 (0.02–0.25) | Tube radius for new strokes. |
| `minSegmentLength` | SceneController | 0.12 | Stroke resolution vs. node count. |
| `orbitGain` | SceneController | 3.5 | Radians of rotation per full-screen flat-hand drag. |

## Staged verification checklist

The code was built in the stages below; each is independently observable at runtime:

1. **Landmarks** — the skeleton overlay tracks your hand smoothly across the full mirror view, staying glued to your real fingers even at the window edges. HUD dot green when a hand is visible.
2. **Rock-sign toggle** — 🤘 flips the HUD label IDLE ⇄ ACTIVE after a brief hold; holding the pose does *not* toggle twice; you must release and re-form it to toggle again.
3. **Index-finger drawing** — while ACTIVE, point your index finger and move: HUD shows "ACTIVE — DRAWING" and a colored tube follows exactly under your fingertip (highlighted yellow). Relax the pose to end the stroke; pointing again starts a new one in the next palette color and the current slider thickness.
4. **Flat-hand rotation** — while ACTIVE, splay your hand flat and drag it sideways/up-down: the sculpture spins/tilts like a globe. Verify a pointing or half-closed hand does *not* rotate anything.
5. **3D tubes** — strokes are lit cylinders/spheres floating over the camera feed, visibly volumetric when rotated.
6. **Shape snapping** — draw a shaky line, hold 🤙: it becomes ruler-straight. Draw an arc, hold ✌️: it becomes a clean curve. Each fires once per hold and only affects the most recent stroke.

If 30 fps is not reached on your machine, drop the capture preset back to `.vga640x480` in `CameraManager` (and set `CameraViewMapper.cameraAspect` to 4/3), or raise `minSegmentLength` (fewer SceneKit nodes).
