import XCTest
import simd
@testable import Whiteboard

/// Synthetic guided captures: the reference flat board is placed on the plane z = 0 (3 m wide) and photographed by
/// known cameras, so pose-based registration can be checked exactly in the simulator.
final class PoseCaptureTests: XCTestCase {
    static var boardImage: UIImage = {
        let url = Bundle(for: PoseCaptureTests.self).bundleURL.appendingPathComponent("fixtures/expected/flat_cropped.jpg")
        return UIImage(contentsOfFile: url.path)!
    }()

    let boardWidth = 3.0
    var boardPxPerMetre: Double { Double(Self.boardImage.pixelSize.width) / boardWidth }
    /// Board top-left corner in the world; e1 = +x, e2 = -y.
    var boardTopLeft: SIMD3<Double> { SIMD3(-boardWidth / 2, 1.5 + Double(Self.boardImage.pixelSize.height) / boardPxPerMetre / 2, 0) }
    var boardFrame: BoardPlane { BoardPlane(origin: boardTopLeft, normal: SIMD3(0, 0, 1), facing: SIMD3(0, 1.5, 1))! }

    /// board pixels -> camera pixels
    func boardToImage(_ cam: Camera) -> Homography {
        boardFrame.planeToImage(cam) * .scale(1 / boardPxPerMetre, 1 / boardPxPerMetre)
    }

    func render(_ cam: Camera) -> UIImage {
        CVBridge.warp(Self.boardImage, homography: boardToImage(cam).nsArray, width: Int(cam.size.x), height: Int(cam.size.y))!
    }

    /// 5 frames, ~33% overlap, slightly varying distance and orientation.
    var cameras: [Camera] {
        let xs = [-1.1, -0.6, -0.1, 0.4, 0.9], zs = [0.75, 0.73, 0.76, 0.74, 0.75]
        let rots = [(1.0, -0.5, 0.8), (-0.8, 0.6, -0.5), (0.3, 0.2, 0.4), (-0.5, -0.7, -0.9), (0.9, 0.4, 0.2)]
        return (0..<5).map { i in boardCamera(SIMD3(xs[i], 1.5, zs[i]), extra: rotation(yaw: rots[i].0, pitch: rots[i].1, roll: rots[i].2)) }
    }

    func record(_ cams: [Camera]) -> CaptureRecord {
        CaptureRecord(frames: cams.enumerated().map { .init(file: "f\($0.offset).jpg", camera: $0.element, timestamp: 0, sharpness: 1) },
                      plane: .init(origin: [0, 1.5, 0], normal: [0, 0, 1]))
    }

    /// toReference_i ∘ boardToImage_i (board px -> flat px), normalised.
    func composite(_ reg: RegistrationResult, _ cams: [Camera]) -> [Homography] {
        zip(reg.toReference, cams).map { h, c in
            let m = ((h ?? .identity) * boardToImage(c)).matrix
            return Homography(m * (1 / m[2][2]))
        }
    }

    func testExactPosesGiveSimilarityIntoBoard() throws {
        let cams = cameras, imgs = cams.map(render)
        let reg = try PoseRegistrar(record: record(cams)).register(imgs)
        XCTAssertTrue(reg.isFlat)
        XCTAssertFalse(reg.confidences.contains { $0.isLow }, "\(reg.confidences)")
        let cs = composite(reg, cams)
        // Every frame maps the board by the same pure scale + translation (no rotation, shear or perspective).
        let m = cs[2].rowMajor
        XCTAssertEqual(m[0], m[4], accuracy: 1e-3 * m[0]); XCTAssertEqual(m[1], 0, accuracy: 1e-3); XCTAssertEqual(m[3], 0, accuracy: 1e-3)
        XCTAssertEqual(m[6], 0, accuracy: 1e-8); XCTAssertEqual(m[7], 0, accuracy: 1e-8)
        for c in cs {
            for p in [SIMD2(1000.0, 500), SIMD2(5000, 2000), SIMD2(3400, 1200)] {
                XCTAssertLessThan(simd_length(c.apply(p) - cs[2].apply(p)), 2.0, "frames agree on board positions")
            }
        }
    }

    func testNoisyPosesAreRefinedByMatching() throws {
        let cams = cameras, imgs = cams.map(render)
        var rng = SplitMix64(seed: 3)
        let noisy = cams.map { c -> Camera in
            var n = c
            let d = SIMD3(Double.random(in: -0.015...0.015, using: &rng), Double.random(in: -0.015...0.015, using: &rng),
                          Double.random(in: -0.01...0.01, using: &rng))
            n.R = rotation(yaw: .random(in: -0.4...0.4, using: &rng), pitch: .random(in: -0.4...0.4, using: &rng),
                           roll: .random(in: -0.4...0.4, using: &rng)) * n.R
            n.t = -(n.R * (c.centre + d))
            return n
        }
        let reg = try PoseRegistrar(record: record(noisy)).register(imgs)
        XCTAssertFalse(reg.confidences.contains { $0.isLow }, "\(reg.confidences)")
        // Joins: adjacent frames agree where they overlap (the board point between their centres).
        let cs = composite(reg, cams)
        for i in 0..<(cs.count - 1) {
            let mid = (cams[i].centre.x + cams[i + 1].centre.x) / 2
            let p = (SIMD2(mid, boardTopLeft.y - 1.5) - SIMD2(boardTopLeft.x, 0)) * boardPxPerMetre
            let q = SIMD2(p.x, p.y)
            XCTAssertLessThan(simd_length(cs[i].apply(q) - cs[i + 1].apply(q)), 3.0, "join \(i)")
        }
        // Pose-only (refinement off) is visibly worse — i.e. the refinement is doing something.
        var poseOnly = PoseRegistrar(record: record(noisy)); poseOnly.maxRefinementDeviation = -1
        let csPose = composite(try poseOnly.register(imgs), cams)
        let worst = (0..<(cs.count - 1)).map { i -> Double in
            let mid = (cams[i].centre.x + cams[i + 1].centre.x) / 2
            let q = (SIMD2(mid, boardTopLeft.y - 1.5) - SIMD2(boardTopLeft.x, 0)) * boardPxPerMetre
            return simd_length(csPose[i].apply(q) - csPose[i + 1].apply(q))
        }.max()!
        XCTAssertGreaterThan(worst, 5)
    }

    func testCapturePipelineEndToEnd() throws {
        let cams = cameras, imgs = cams.map(render)
        let out = try WhiteboardPipeline.capture(record(cams)).run(imgs)
        XCTAssertTrue(out.warnings.isEmpty, "\(out.warnings)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.flatCropped.jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent("capture_cropped.jpg"))
        try? imgs[0].jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent("capture_frame0.jpg"))
        // Coverage is x in [-1.475, 1.275] m of a 3 m board and ~1 m of its 1.1 m height.
        let a = out.flatCropped.pixelSize
        XCTAssertEqual(a.width / a.height, 2.75 / 1.0, accuracy: 0.3)
    }

    func testWithoutPlaneFallsBackToImageRegistration() throws {
        let cams = Array(cameras.prefix(3)), imgs = cams.map(render)
        var rec = record(cams); rec.plane = nil
        let reg = try PoseRegistrar(record: rec).register(imgs)
        XCTAssertFalse(reg.isFlat)
        XCTAssertEqual(reg.confidences.count, 2)
    }

    /// A dense sweep (~67% overlap) where one photo is ruined (blank, e.g. glare or motion blur).
    var denseCameras: [Camera] {
        (0..<7).map { i in boardCamera(SIMD3(-1.0 + 0.25 * Double(i), 1.5, 0.75), extra: rotation(yaw: 0.4 * Double(i % 3) - 0.4, pitch: 0.3, roll: 0)) }
    }

    func ruined(_ size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testBadPhotoInDenseScanIsLeftOut() throws {
        let cams = denseCameras
        var imgs = cams.map(render)
        imgs[3] = ruined(imgs[3].pixelSize)
        let reg = try PoseRegistrar(record: record(cams)).register(imgs)
        XCTAssertEqual(reg.dropped, [3])
        XCTAssertFalse(reg.confidences.contains { $0 == .tracked }, "\(reg.joins)")
        XCTAssertTrue(reg.joins.contains { $0.a == 2 && $0.b == 4 }, "bridged: \(reg.joins)")
        let cs = composite(reg, cams)
        for i in [0, 1, 2, 4, 5, 6] {
            for p in [SIMD2(1000.0, 500), SIMD2(3400, 1200)] {
                XCTAssertLessThan(simd_length(cs[i].apply(p) - cs[2].apply(p)), 2.0, "frame \(i)")
            }
        }
        let out = try WhiteboardPipeline.capture(record(cams)).run(imgs)
        XCTAssertTrue(out.warnings.isEmpty, "\(out.warnings)")
    }

    func testImageOnlyRegistrationSkipsBadPhoto() throws {
        let cams = Array(denseCameras.prefix(5))
        var imgs = cams.map(render)
        imgs[2] = ruined(imgs[2].pixelSize)
        let reg = try CVRegistrar().register(imgs)
        XCTAssertEqual(reg.dropped, [2])
        XCTAssertEqual(reg.joins.map { [$0.a, $0.b] }, [[0, 1], [1, 3], [3, 4]])
    }
}
