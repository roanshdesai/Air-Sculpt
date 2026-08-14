import AVFoundation
import SwiftUI

/// Full-window live camera view, mirrored like a mirror.
///
/// Mirroring strategy: the horizontal flip is applied at the SwiftUI layer
/// (`scaleEffect(x: -1)`), which is deterministic from the very first frame.
/// The old approach — setting `isVideoMirrored` on the preview connection —
/// silently failed whenever the connection wasn't ready yet (the session
/// configures on a background queue), which twice shipped the "skeleton at
/// the mirror image of the hand" bug. The connection is now explicitly
/// pinned to NOT mirror, so the view flip is the single source of truth.
struct CameraPreviewView: View {
    let session: AVCaptureSession

    var body: some View {
        PreviewLayerRepresentable(session: session)
            .scaleEffect(x: -1, y: 1)
    }
}

private struct PreviewLayerRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewLayerView {
        PreviewLayerView(session: session)
    }

    func updateNSView(_ nsView: PreviewLayerView, context: Context) {}
}

/// NSView host for the preview layer; keeps the layer sized to the view and
/// pins the connection to un-mirrored so the SwiftUI flip is never doubled.
final class PreviewLayerView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var pinTask: Task<Void, Never>?

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        // The connection appears only after the session finishes configuring
        // on its background queue — retry until we can pin it un-mirrored.
        pinTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if self?.pinConnectionUnmirrored() == true { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        pinTask?.cancel()
    }

    override func layout() {
        super.layout()
        // Sublayers get CALayer's default ~0.25 s implicit animation on
        // frame changes, which made the video crop lag behind the overlay
        // and strokes during live window resize. Kill it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        pinConnectionUnmirrored()
    }

    /// Returns true once the connection exists and is pinned un-mirrored.
    @discardableResult
    private func pinConnectionUnmirrored() -> Bool {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return false }
        if connection.automaticallyAdjustsVideoMirroring || connection.isVideoMirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return true
    }
}
