import SwiftUI

/// Bottom status bar: current gesture state, hand visibility, contextual
/// instructions, stroke thickness slider, and canvas controls.
struct HUDView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(model.handVisible ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .accessibilityLabel(model.handVisible ? "Hand detected" : "No hand detected")

            // Live pose readout: what the detector thinks your hand is doing
            // right now. If a gesture "does nothing", look here first.
            Text(model.detectedPose)
                .font(.title3)
                .frame(width: 44)
                .help("Recognized pose")

            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle)
                    .font(.headline.monospaced())
                    .foregroundStyle(model.gestureState == .active ? .green : .cyan)
                Text(instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                ColorPicker("Stroke colour", selection: $model.strokeColor)
                    .labelsHidden()
                    .help("Colour for new strokes and fills")
                Image(systemName: "lineweight")
                    .foregroundStyle(.secondary)
                // Thickness applies to the next stroke; strokes already drawn
                // keep the radius they were drawn with.
                Slider(value: $model.strokeThickness, in: 0.02...0.25)
                    .frame(width: 120)
                    .accessibilityLabel("Stroke thickness")
                Circle()
                    .fill(.primary.opacity(0.8))
                    .frame(width: previewDotSize, height: previewDotSize)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }

            Button("Fill", systemImage: "drop.halffull", action: model.fill)
                .keyboardShortcut("f", modifiers: .command)
                .help("Fill the last closed shape with its colour (press again to remove)")
            Button("Extrude", systemImage: "cube", action: model.extrude)
                .keyboardShortcut("e", modifiers: .command)
                .help("Pull the last shape into 3D: square → cube, triangle → prism")
            Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Reset View", systemImage: "arrow.counterclockwise", action: model.resetView)
                .keyboardShortcut("r", modifiers: .command)
            Button("Clear", systemImage: "trash", action: model.clearCanvas)
                .keyboardShortcut("k", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    /// Live preview dot next to the slider, scaled from world-unit radius to
    /// a rough on-screen diameter.
    private var previewDotSize: CGFloat {
        model.strokeThickness * 80
    }

    private var stateTitle: String {
        switch model.gestureState {
        case .idle: "MOVE"
        case .active: model.isDrawing ? "DRAW — DRAWING" : "DRAW"
        }
    }

    private var instruction: String {
        if !model.handVisible {
            return "Show one hand to the camera."
        }
        switch model.gestureState {
        case .idle:
            return "🖐 turn · 🖐🖐 hold the orb: move it, twist hands to roll · 🤏🤏 resize · 🤘 to draw"
        case .active:
            return "👆 draw · 🤙 straighten last · ✌️ curve last · 🤘 back to move"
        }
    }
}
