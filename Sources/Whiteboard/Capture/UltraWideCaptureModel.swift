import AVFoundation
import Observation
import UIKit
import simd

/// What the capture screen needs from either capture mode.
protocol CaptureControlling: AnyObject, Observable {
    var guidance: KeyframePolicy.Guidance { get }
    var overlap: Double? { get }
    var thumbnails: [UIImage] { get }
    var capturing: Bool { get }
    var shutterCount: Int { get }
    var errorMessage: String? { get }
    /// Where the photos so far and the current view are, for the little coverage map. Nil before the first photo.
    var coverage: CaptureCoverage? { get }
    var policy: KeyframePolicy { get }
    func start()
    func requestManualCapture()
    func cancel()
}

/// Rectangles in some common 2-D frame (y down); only their relative layout matters.
struct CaptureCoverage: Equatable {
    var shots: [CGRect]
    var view: CGRect?
}

/// 0.5× capture: ARKit can't run world tracking on the ultra-wide camera, so this mode has no poses. Overlap is
/// tracked from image motion between preview frames (phase correlation, as for video import); the photos are
/// then registered from the images alone and flattened by the vanishing-point method, like imported photos.
@Observable
final class UltraWideCaptureModel: NSObject, CaptureControlling, AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCapturePhotoCaptureDelegate {
    private(set) var guidance: KeyframePolicy.Guidance = .tapToStart
    private(set) var overlap: Double?
    private(set) var thumbnails: [UIImage] = []
    private(set) var capturing = false
    private(set) var shutterCount = 0
    private(set) var errorMessage: String?
    private(set) var coverage: CaptureCoverage?

    /// Speeds here are in frame widths per second (no metric scale without tracking).
    @ObservationIgnored var policy = KeyframePolicy(maxSpeed: 0.5, maxAngularSpeed: .infinity, maxViewAngle: 90)
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "uk.co.zacgarby.whiteboard.ultrawide")
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?

    // Main-thread state.
    @ObservationIgnored private var photos: [(image: UIImage, position: SIMD2<Double>)] = []
    @ObservationIgnored private var pendingPosition = SIMD2<Double>.zero

    // Video-queue state.
    @ObservationIgnored private var prev: Data?
    @ObservationIgnored private var frameSize = SIMD2(1.0, 1.0)
    @ObservationIgnored private var position = SIMD2<Double>.zero
    @ObservationIgnored private var keyPositions: [SIMD2<Double>] = []
    @ObservationIgnored private var lastTime: Double?
    @ObservationIgnored private var speed = 0.0
    @ObservationIgnored private var lostFrames = 0
    @ObservationIgnored private var sharpness: [(time: Double, value: Double)] = []
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var manualRequested = false
    @ObservationIgnored private var busy = false   // mirrors `capturing` on the queue
    @ObservationIgnored private var pendingQ = SIMD2<Double>.zero

    static var isAvailable: Bool { AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self else { return }
            guard ok else { DispatchQueue.main.async { self.errorMessage = "Allow camera access in Settings." }; return }
            queue.async { self.configure() }
        }
    }

    private func configure() {
        guard let dev = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.errorMessage = "No ultra-wide camera on this device." }
            return
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
        rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        applyRotation()
        session.startRunning()
    }

    /// Photos and tracking frames use the same rotation (horizon-level for how the phone is held), fixed at the
    /// first photo so the sweep direction stays consistent.
    private func applyRotation() {
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        for c in [photoOutput.connection(with: .video), videoOutput.connection(with: .video)] {
            if let c, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
    }

    func requestManualCapture() { queue.async { self.manualRequested = true } }

    func cancel() { queue.async { self.session.stopRunning() } }

    /// Stops the camera; photos ordered left -> right along the board.
    func finish() -> [UIImage] {
        queue.async { self.session.stopRunning(); self.setExposureLocked(false) }
        // Content moving right (positive x) over the sweep means the camera moved left: reverse capture order.
        guard let first = photos.first, let last = photos.last else { return [] }
        let imgs = photos.map(\.image)
        return last.position.x - first.position.x > 0 ? imgs.reversed() : imgs
    }

    // MARK: tracking (video queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 2 == 0, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var w = 0, h = 0
        let small = CVBridge.smallLuma(pb, maxWidth: 240, width: &w, height: &h)
        guard w > 0, h > 0 else { return }
        let size = SIMD2(Double(w), Double(h))
        let sharp = small.withUnsafeBytes { laplacianVariance($0.baseAddress!.assumingMemoryBound(to: UInt8.self), width: w, height: h, bytesPerRow: w, step: 1) }
        sharpness.append((t, sharp))
        sharpness.removeAll { t - $0.time > 2 }

        if let p = prev, size == frameSize, let t0 = lastTime, t > t0 {
            var response = 0.0
            let s = CVBridge.shiftGray(from: p, to: small, width: w, height: h, response: &response)
            if response > 0.03 {
                let d = SIMD2(Double(s.x), Double(s.y))
                position += d
                speed = 0.7 * speed + 0.3 * simd_length(d / size) / (t - t0)
                lostFrames = 0
            } else {
                lostFrames += 1
            }
        }
        prev = small; frameSize = size; lastTime = t

        let ov = keyPositions.map { KeyframeSelection.overlap(position - $0, size) }.max()
        let state = KeyframePolicy.State(
            trackingNormal: lostFrames < 5, hasPlane: true, footprintValid: true, viewAngle: 0,
            keyframeCount: keyPositions.count, overlap: ov, speed: speed, angularSpeed: 0, sharpness: sharp,
            recentBestSharpness: sharpness.map(\.value).max() ?? 0, capturing: busy)
        let decision = policy.decide(state)
        let manual = manualRequested && !busy && lostFrames < 5
        manualRequested = false
        if decision == .capture || manual { busy = true }
        let pos = position
        // The view moves opposite to the content.
        func rect(_ p: SIMD2<Double>) -> CGRect { CGRect(x: -p.x, y: -p.y, width: size.x, height: size.y) }
        let cov = keyPositions.isEmpty ? nil : CaptureCoverage(shots: keyPositions.map(rect), view: lostFrames < 5 ? rect(position) : nil)
        DispatchQueue.main.async {
            if cov != self.coverage { self.coverage = cov }
            let shown = ov.map { ($0 * 50).rounded() / 50 }
            if shown != self.overlap { self.overlap = shown }
            if case .wait(let g) = decision, g != self.guidance { self.guidance = g }
            if decision == .capture || manual { self.capture(at: pos) }
        }
    }

    // MARK: photos

    private func capture(at pos: SIMD2<Double>) {
        capturing = true
        guidance = .holdStill
        pendingPosition = photos.isEmpty ? .zero : pos
        queue.async {
            self.pendingQ = self.keyPositions.isEmpty ? .zero : pos   // where the view was when the photo was triggered
            if self.keyPositions.isEmpty {
                // Fix the orientation now; restart tracking in it.
                self.applyRotation()
                self.prev = nil; self.position = .zero; self.speed = 0
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap(UIImage.init(data:))?.normalized(maxDimension: BoardStore.photoMaxDimension)
        queue.async {
            if img != nil { self.keyPositions.append(self.pendingQ) }
            self.busy = false
            if self.keyPositions.count == 1 { self.setExposureLocked(true) }
        }
        DispatchQueue.main.async {
            self.capturing = false
            guard let img else { self.errorMessage = "Couldn't take that photo."; return }
            self.photos.append((img, self.pendingPosition))
            self.thumbnails.append(img.thumbnail(maxDimension: 160))
            self.shutterCount += 1
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func setExposureLocked(_ locked: Bool) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        if locked {
            if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
            if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        } else {
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }
}
