import AVFoundation
import UIKit
import Combine

/// Continuous camera capture on iOS.
///
/// Records video frames whenever the app is in the foreground.
/// iOS restriction: camera access is blocked when backgrounded.
/// The mic handles 24/7 — the camera captures whenever the screen is on.
///
/// Frames are extracted at low frequency (1 per 5 seconds), described,
/// and the raw frames are discarded. Only text descriptions persist.
final class CameraManager: NSObject, ObservableObject {
    static let shared = CameraManager()

    @Published var isCapturing = false

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.timvoice.camera", qos: .background)

    private var lastFrameTime: Date = .distantPast
    private let frameCaptureInterval: TimeInterval = 5.0 // 1 frame every 5 seconds

    var onFrameCaptured: ((CameraFrame) -> Void)?

    private override init() {
        super.init()
        setupSession()
        observeAppLifecycle()
    }

    // MARK: - Session Setup

    private func setupSession() {
        captureSession.sessionPreset = .medium // 480p is enough for scene understanding

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("[Camera] No camera available")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
    }

    // MARK: - Lifecycle

    /// Start capturing when app is foregrounded, stop when backgrounded.
    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.startCapture()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopCapture()
        }
    }

    func startCapture() {
        guard !captureSession.isRunning else { return }
        processingQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isCapturing = true
            }
        }
    }

    func stopCapture() {
        guard captureSession.isRunning else { return }
        processingQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.isCapturing = false
            }
        }
    }
}

// MARK: - Frame Processing

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date.now
        guard now.timeIntervalSince(lastFrameTime) >= frameCaptureInterval else { return }
        lastFrameTime = now

        // Convert sample buffer to JPEG data
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.5) else { return }

        let frame = CameraFrame(
            imageData: jpegData,
            timestamp: now,
            source: .iPhone
        )

        onFrameCaptured?(frame)
    }
}

// MARK: - Models

struct CameraFrame {
    let imageData: Data
    let timestamp: Date
    let source: CameraSource

    enum CameraSource: String, Codable {
        case iPhone = "iphone_camera"
        case macbook = "macbook_camera"
    }
}
