import ARKit
import CoreImage
import Observation
import SceneKit
import UIKit

/// Guided capture: ARKit world tracking + vertical plane detection; takes a high-res keyframe whenever the
/// view has moved on to ~30% overlap (see `KeyframePolicy`), and saves frames + poses as a `CaptureRecord`.
/// All ARSession callbacks arrive on the main queue (no `delegateQueue` set).
@Observable
final class CaptureModel: NSObject, ARSessionDelegate, CaptureControlling {
    struct Keyframe: Identifiable {
        let id = UUID()
        let frame: CaptureRecord.Frame
        let thumbnail: UIImage
    }

    // UI state
    private(set) var guidance: KeyframePolicy.Guidance = .findBoard
    private(set) var overlap: Double?
    private(set) var keyframes: [Keyframe] = []
    var thumbnails: [UIImage] { keyframes.map(\.thumbnail) }
    private(set) var capturing = false
    private(set) var shutterCount = 0
    private(set) var errorMessage: String?
    private(set) var coverage: CaptureCoverage?

    @ObservationIgnored let session = ARSession()
    @ObservationIgnored let overlayRoot = SCNNode()
    @ObservationIgnored var policy = KeyframePolicy()
    @ObservationIgnored private var dir: URL?
    @ObservationIgnored private var plane: BoardPlane?
    @ObservationIgnored private var planeAnchorID: UUID?
    @ObservationIgnored private var last: (transform: simd_float4x4, time: TimeInterval)?
    @ObservationIgnored private var speed = 0.0
    @ObservationIgnored private var angularSpeed = 0.0
    @ObservationIgnored private var sharpnessHistory: [(time: TimeInterval, value: Double)] = []
    @ObservationIgnored private var manualRequested = false
    @ObservationIgnored private var exposureLocked = false
    @ObservationIgnored private var lastOverlayRebuild: TimeInterval = 0
    @ObservationIgnored private var lastCoverageUpdate: TimeInterval = 0
    @ObservationIgnored private let ciContext = CIContext()

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func start() {
        guard Self.isSupported else { errorMessage = "Scanning needs an iPhone with ARKit."; return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]
        config.isAutoFocusEnabled = true
        if let fmt = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { config.videoFormat = fmt }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        do { dir = try CaptureRecord.newDirectory() } catch { errorMessage = "Couldn't create a folder for the scan." }
    }

    func requestManualCapture() { manualRequested = true }

    /// Stops the session and writes `capture.json`. Returns the capture directory.
    func finish() -> URL? {
        session.pause()
        setExposureLocked(false)
        guard let dir, !keyframes.isEmpty else { return nil }
        let rec = CaptureRecord(frames: keyframes.map(\.frame),
                                plane: plane.map { .init(origin: [$0.origin.x, $0.origin.y, $0.origin.z],
                                                         normal: [$0.normal.x, $0.normal.y, $0.normal.z]) })
        do { try rec.write(to: dir) } catch { errorMessage = "Couldn't save the scan."; return nil }
        return dir
    }

    func cancel() {
        session.pause()
        setExposureLocked(false)
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: per-frame

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.timestamp
        updateMotion(frame.camera.transform, t)
        let sharp = lumaSharpness(frame.capturedImage, step: 4)
        sharpnessHistory.append((t, sharp))
        sharpnessHistory.removeAll { t - $0.time > 2 }

        let res = frame.camera.imageResolution
        let cam = Camera(arIntrinsics: frame.camera.intrinsics, cameraToWorld: frame.camera.transform,
                         imageSize: SIMD2(Double(res.width), Double(res.height)))
        updatePlane(frame, cam)

        let footprint = plane?.footprint(of: cam)
        let kfPrints = plane.map { p in keyframes.compactMap { p.footprint(of: $0.frame.camera) } } ?? []
        let ov = footprint.flatMap { f in kfPrints.map { overlapFraction(f, $0) }.max() }
        let shown = ov.map { ($0 * 50).rounded() / 50 }
        if shown != overlap { overlap = shown }
        if t - lastCoverageUpdate > 0.1 {
            lastCoverageUpdate = t
            func box(_ q: [SIMD2<Double>]) -> CGRect {
                let xs = q.map(\.x), ys = q.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            let cov = kfPrints.isEmpty ? nil : CaptureCoverage(shots: kfPrints.map(box), view: footprint.map(box))
            if cov != coverage { coverage = cov }
        }

        let tracking: Bool = { if case .normal = frame.camera.trackingState { return true } else { return false } }()
        let state = KeyframePolicy.State(
            trackingNormal: tracking, hasPlane: plane != nil, footprintValid: footprint != nil,
            viewAngle: plane?.viewAngle(of: cam) ?? 90, keyframeCount: keyframes.count, overlap: ov,
            speed: speed, angularSpeed: angularSpeed, sharpness: sharp,
            recentBestSharpness: sharpnessHistory.map(\.value).max() ?? 0, capturing: capturing)
        switch policy.decide(state) {
        case .capture:
            captureKeyframe()
        case .wait(let g):
            if g != guidance { guidance = g }
            if manualRequested, !capturing, plane != nil, tracking { captureKeyframe() }
        }
        manualRequested = false

        if t - lastOverlayRebuild > 1 { rebuildOverlay(); lastOverlayRebuild = t }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }

    private func updateMotion(_ T: simd_float4x4, _ t: TimeInterval) {
        defer { last = (T, t) }
        guard let (T0, t0) = last, t > t0 else { return }
        let dt = t - t0
        let dp = simd_distance(SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z),
                               SIMD3<Float>(T0.columns.3.x, T0.columns.3.y, T0.columns.3.z))
        let dq = simd_quatf(T) * simd_quatf(T0).inverse
        let angle = Double(abs(dq.angle > .pi ? 2 * .pi - dq.angle : dq.angle)) * 180 / .pi
        speed = 0.7 * speed + 0.3 * Double(dp) / dt
        angularSpeed = 0.7 * angularSpeed + 0.3 * angle / dt
    }

    private func updatePlane(_ frame: ARFrame, _ cam: Camera) {
        if let id = planeAnchorID, let a = frame.anchors.first(where: { $0.identifier == id }) as? ARPlaneAnchor {
            setPlane(a.transform, centre: a.center, cam)
            return
        }
        let centre = CGPoint(x: 0.5, y: 0.5)
        let q = frame.raycastQuery(from: centre, allowing: .existingPlaneGeometry, alignment: .vertical)
        if let r = session.raycast(q).first, let a = r.anchor as? ARPlaneAnchor {
            planeAnchorID = a.identifier
            setPlane(a.transform, centre: a.center, cam)
        } else if plane == nil {
            // Before ARKit commits to a plane anchor, use its estimate so the first keyframe isn't held up.
            let q2 = frame.raycastQuery(from: centre, allowing: .estimatedPlane, alignment: .vertical)
            if let r = session.raycast(q2).first { setPlane(r.worldTransform, centre: .zero, cam) }
        }
    }

    /// The plane's normal is whichever axis of `T` points most along the view direction.
    private func setPlane(_ T: simd_float4x4, centre: SIMD3<Float>, _ cam: Camera) {
        let o = T * SIMD4(centre, 1)
        let axes = [T.columns.0, T.columns.1, T.columns.2].map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let n = axes.max { abs(simd_dot($0, cam.forward)) < abs(simd_dot($1, cam.forward)) }!
        if let p = BoardPlane(origin: SIMD3(Double(o.x), Double(o.y), Double(o.z)), normal: n, facing: cam.centre) { plane = p }
    }

    // MARK: keyframes

    private func captureKeyframe() {
        guard !capturing, let dir else { return }
        capturing = true
        guidance = .holdStill
        session.captureHighResolutionFrame { [weak self] frame, error in
            DispatchQueue.main.async { self?.didCapture(frame, error, dir: dir) }
        }
    }

    private func didCapture(_ frame: ARFrame?, _ error: Error?, dir: URL) {
        guard let frame else { capturing = false; return }
        let pb = frame.capturedImage
        let w = Double(CVPixelBufferGetWidth(pb))
        let res = frame.camera.imageResolution
        let sensorCam = Camera(arIntrinsics: frame.camera.intrinsics, cameraToWorld: frame.camera.transform,
                               imageSize: SIMD2(Double(res.width), Double(res.height))).scaled(w / Double(res.width))
        let k = sensorCam.uprightQuarterTurns()
        let cam = sensorCam.rotatedClockwise(quarterTurns: k)
        let sharp = lumaSharpness(pb, step: 8)
        let index = keyframes.count, timestamp = frame.timestamp
        let ci = CIImage(cvPixelBuffer: pb), ctx = ciContext
        Task { @MainActor [weak self] in
            let kf: Keyframe? = await Task.detached(priority: .userInitiated) {
                let orientation: UIImage.Orientation = [.up, .right, .down, .left][k]
                guard let cg = ctx.createCGImage(ci, from: ci.extent),
                      let upright = UIImage(cgImage: cg, scale: 1, orientation: orientation).normalized(maxDimension: .greatestFiniteMagnitude),
                      let data = upright.jpegData(compressionQuality: 0.92)
                else { return nil }
                let name = String(format: "frame_%02d.jpg", index)
                guard (try? data.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
                let thumb = upright.thumbnail(maxDimension: 160)
                return Keyframe(frame: CaptureRecord.Frame(file: name, camera: cam, timestamp: timestamp, sharpness: sharp), thumbnail: thumb)
            }.value
            guard let self else { return }
            if let kf { added(kf) } else { capturing = false }
        }
    }

    private func added(_ kf: Keyframe) {
        keyframes.append(kf)
        capturing = false
        shutterCount += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !exposureLocked { setExposureLocked(true) }   // first frame sets the exposure for the whole board
        rebuildOverlay()
    }

    private func setExposureLocked(_ locked: Bool) {
        guard let dev = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try dev.lockForConfiguration()
            defer { dev.unlockForConfiguration() }
            if locked {
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            exposureLocked = locked
        } catch {}
    }

    // MARK: overlay

    /// Translucent green patches on the board where keyframes already cover it.
    private func rebuildOverlay() {
        overlayRoot.childNodes.forEach { $0.removeFromParentNode() }
        guard let p = plane else { return }
        for kf in keyframes {
            guard let fp = p.footprint(of: kf.frame.camera) else { continue }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: fp[0].x, y: -fp[0].y))
            for q in fp.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: -q.y)) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.22)
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            shape.materials = [m]
            let node = SCNNode(geometry: shape)
            // Local x = e1, local y = up (-e2), local z = normal; nudged off the board to avoid z-fighting.
            let o = p.origin + 0.003 * p.normal
            node.simdTransform = simd_float4x4(columns: (SIMD4(SIMD3<Float>(p.e1), 0), SIMD4(SIMD3<Float>(-p.e2), 0),
                                                         SIMD4(SIMD3<Float>(p.normal), 0), SIMD4(SIMD3<Float>(o), 1)))
            overlayRoot.addChildNode(node)
        }
    }
}

/// Laplacian variance of the luma plane of a camera pixel buffer (bi-planar YUV: plane 0 is Y).
func lumaSharpness(_ pb: CVPixelBuffer, step: Int) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard CVPixelBufferGetPlaneCount(pb) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
    return laplacianVariance(base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidthOfPlane(pb, 0),
                             height: CVPixelBufferGetHeightOfPlane(pb, 0), bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                             step: step)
}
