import AVFoundation

/// Wraps `AVCaptureSession` and delivers `CMSampleBuffer` frames to a handler
/// on a dedicated background queue.
///
/// `@unchecked Sendable`: all mutable state is confined to `sessionQueue`
/// (configuration/start/stop) and `videoQueue` (frame delivery) after
/// `start(frameHandler:)` is called once from the main actor.
final class CameraManager: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "AirSculpt.CameraManager.session")
    private let videoQueue = DispatchQueue(label: "AirSculpt.CameraManager.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var isConfigured = false

    /// Returns true when camera access is (or becomes) authorized.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// Starts the session. `frameHandler` is called on a background queue for
    /// every captured frame; do Vision work directly inside it.
    func start(frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.frameHandler = frameHandler
        sessionQueue.async { [self] in
            configureSessionIfNeeded()
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // 1280x720 gives Vision's hand-pose model 4x the pixels of VGA —
        // noticeably more precise landmarks — while still running 30+ fps on
        // Apple silicon. Drop back to .vga640x480 if an older machine
        // struggles. NOTE: if you change this, keep the aspect ratio in
        // CameraViewMapper.cameraAspect in sync.
        session.sessionPreset = .hd1280x720

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Drop frames rather than queueing them if Vision ever falls behind —
        // stale frames would add latency to every gesture.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameHandler?(sampleBuffer)
    }
}
