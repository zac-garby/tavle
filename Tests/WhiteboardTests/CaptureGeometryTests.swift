import XCTest
import simd
@testable import Whiteboard

func rotation(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) -> simd_double3x3 {
    let (a, b, c) = (yaw * .pi / 180, pitch * .pi / 180, roll * .pi / 180)
    let ry = simd_double3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))])
    let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(b), -sin(b)), SIMD3(0, sin(b), cos(b))])
    let rz = simd_double3x3(rows: [SIMD3(cos(c), -sin(c), 0), SIMD3(sin(c), cos(c), 0), SIMD3(0, 0, 1)])
    return rz * rx * ry
}

/// A camera at `centre` looking along world -z (at a board on z = 0), upright, with a small extra rotation.
func boardCamera(_ centre: SIMD3<Double>, f: Double = 1500, size: SIMD2<Double> = SIMD2(1500, 2000),
                 extra: simd_double3x3 = matrix_identity_double3x3) -> Camera {
    let R0 = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)])
    let R = extra * R0
    let K = simd_double3x3(rows: [SIMD3(f, 0, size.x / 2), SIMD3(0, f, size.y / 2), SIMD3(0, 0, 1)])
    return Camera(K: K, R: R, t: -(R * centre), size: size)
}

final class CaptureGeometryTests: XCTestCase {
    func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tol: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), tol, "\(a) vs \(b)", file: file, line: line)
    }

    func testARKitCameraConversion() {
        // ARKit camera: x right, y up, looking down -z. Put it at (1, 2, 3), yawed 30 degrees.
        let a = Float(30 * Double.pi / 180)
        var T = simd_float4x4(simd_quatf(angle: a, axis: SIMD3(0, 1, 0)))
        T.columns.3 = SIMD4(1, 2, 3, 1)
        let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 540, 1)))
        let cam = Camera(arIntrinsics: k, cameraToWorld: T, imageSize: SIMD2(1920, 1080))
        let c = SIMD3<Double>(1, 2, 3)
        let fwd = -SIMD3<Double>(SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
        let right = SIMD3<Double>(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z))
        let up = SIMD3<Double>(SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z))
        XCTAssertLessThan(simd_length(cam.centre - c), 1e-5)
        close(cam.project(c + 2 * fwd)!, SIMD2(960, 540), 1e-3)
        XCTAssertGreaterThan(cam.project(c + 2 * fwd + 0.1 * right)!.x, 960)
        XCTAssertLessThan(cam.project(c + 2 * fwd + 0.1 * up)!.y, 540)
        XCTAssertNil(cam.project(c - fwd))
    }

    func testRotatedClockwiseMatchesPixelMap() {
        let cam = boardCamera(SIMD3(0.2, 1.4, 0.8), size: SIMD2(1600, 1200), extra: rotation(yaw: 4, pitch: -3, roll: 2))
        let rot = cam.rotatedClockwise()
        XCTAssertEqual(rot.size, SIMD2(1200, 1600))
        for X in [SIMD3(0.0, 1.5, 0), SIMD3(-0.3, 1.2, 0), SIMD3(0.5, 1.9, 0)] {
            let p = cam.project(X)!, q = rot.project(X)!
            close(q, SIMD2(cam.size.y - p.y, p.x), 1e-6)
        }
        XCTAssertLessThan(simd_length(rot.centre - cam.centre), 1e-9)
        let four = cam.rotatedClockwise(quarterTurns: 4)
        close(four.project(SIMD3(0.1, 1.3, 0))!, cam.project(SIMD3(0.1, 1.3, 0))!, 1e-6)
    }

    /// The pixel map assumed by `rotatedClockwise` is what UIKit does for `.right` (used when saving keyframes).
    func testUIImageRightOrientationMatchesPixelMap() {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let src = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: fmt).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 30, y: 4, width: 2, height: 2))   // centre (31, 5)
        }
        let rotated = UIImage(cgImage: src.cgImage!, scale: 1, orientation: .right).normalized(maxDimension: 1000)!
        XCTAssertEqual(rotated.pixelSize, CGSize(width: 20, height: 40))
        // Expect centre at (H - y, x) = (15, 31).
        let cg = rotated.cgImage!
        var px = [UInt8](repeating: 0, count: 20 * 40)
        let ctx = CGContext(data: &px, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 20,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 20, height: 40))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<40 { for x in 0..<20 where px[y * 20 + x] > 128 { sx += Double(x) + 0.5; sy += Double(y) + 0.5; n += 1 } }
        close(SIMD2(sx / n, sy / n), SIMD2(15, 31), 0.6)
    }

    func testUprightQuarterTurns() {
        let upright = boardCamera(SIMD3(0, 1.5, 1))
        XCTAssertEqual(upright.uprightQuarterTurns(), 0)
        // Camera rolled so world-up appears pointing left in the image (phone held landscape-left of upright):
        // rolling the camera by +90 about its axis; one clockwise quarter turn fixes it, etc.
        for k in 0..<4 {
            // Rotating the camera frame by Rz^-k is the inverse of rotating the image k times clockwise.
            var cam = upright
            let Rz = simd_double3x3(rows: [SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
            for _ in 0..<k { cam.R = Rz.transpose * cam.R; cam.t = Rz.transpose * cam.t }
            cam.size = k % 2 == 0 ? upright.size : SIMD2(upright.size.y, upright.size.x)
            XCTAssertEqual(cam.uprightQuarterTurns(), k, "k = \(k)")
            XCTAssertEqual(cam.rotatedClockwise(quarterTurns: k).uprightQuarterTurns(), 0)
        }
    }

    func testBoardPlaneFrame() {
        let p = BoardPlane(origin: SIMD3(0, 1.5, 0), normal: SIMD3(0, 0, -1), facing: SIMD3(0, 1.5, 1))!
        XCTAssertEqual(p.normal, SIMD3(0, 0, 1), "flipped towards the viewer")
        XCTAssertEqual(p.e1, SIMD3(1, 0, 0), "right as seen by the viewer")
        XCTAssertEqual(p.e2, SIMD3(0, -1, 0), "down")
        XCTAssertNil(BoardPlane(origin: .zero, normal: SIMD3(0, 1, 0), facing: SIMD3(0, 1, 0)), "floor has no 'right'")
    }

    func testFootprintAndViewAngle() {
        let plane = BoardPlane(origin: SIMD3(0, 1.5, 0), normal: SIMD3(0, 0, 1), facing: SIMD3(0, 0, 1))!
        let cam = boardCamera(SIMD3(0.3, 1.5, 0.75))
        let fp = plane.footprint(of: cam)!
        // 1500 px at f = 1500 and 0.75 m -> 0.75 m wide; 2000 px -> 1.0 m tall; centred on (0.3, 0) in plane coords.
        close(fp[0], SIMD2(0.3 - 0.375, -0.5), 1e-9)
        close(fp[2], SIMD2(0.3 + 0.375, 0.5), 1e-9)
        XCTAssertEqual(polygonArea(fp), 0.75, accuracy: 1e-9)
        XCTAssertEqual(plane.viewAngle(of: cam), 0, accuracy: 1e-6)
        XCTAssertEqual(plane.viewAngle(of: boardCamera(SIMD3(0, 1.5, 1), extra: rotation(yaw: 20))), 20, accuracy: 1e-6)
        // Looking away from the board: no footprint.
        XCTAssertNil(plane.footprint(of: boardCamera(SIMD3(0, 1.5, 1), extra: rotation(yaw: 180))))
    }

    func testPlaneInducedHomographyAgreesWithProjection() {
        let plane = BoardPlane(origin: SIMD3(0.1, 1.4, -0.05), normal: SIMD3(0.05, 0.02, 1), facing: SIMD3(0, 1.5, 1))!
        let a = boardCamera(SIMD3(-0.4, 1.45, 0.8), extra: rotation(yaw: 5, pitch: 2, roll: -1))
        let b = boardCamera(SIMD3(0.2, 1.55, 0.7), extra: rotation(yaw: -6, pitch: -1, roll: 3))
        let H = planeInducedHomography(from: a, to: b, plane: plane)
        let viaPlane = plane.planeToImage(b) * plane.planeToImage(a).inverse!
        for uv in [SIMD2(0.0, 0), SIMD2(0.2, -0.1), SIMD2(-0.15, 0.3)] {
            let X = plane.toWorld(uv)
            let pa = a.project(X)!, pb = b.project(X)!
            close(H.apply(pa), pb, 1e-6)
            close(viaPlane.apply(pa), pb, 1e-6)
            close(plane.planeToImage(a).apply(uv), pa, 1e-6)
        }
    }

    func testConvexIntersection() {
        let sq = [SIMD2(0.0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let shifted = sq.map { $0 + SIMD2(0.5, 0) }
        XCTAssertEqual(polygonArea(convexIntersection(sq, shifted)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(polygonArea(convexIntersection(sq, Array(shifted.reversed()))), 0.5, accuracy: 1e-12, "either winding")
        XCTAssertEqual(overlapFraction(sq, sq.map { $0 + SIMD2(3, 0) }), 0)
        XCTAssertEqual(overlapFraction(sq, sq), 1, accuracy: 1e-12)
        let diamond = [SIMD2(0.5, -0.5), SIMD2(1.5, 0.5), SIMD2(0.5, 1.5), SIMD2(-0.5, 0.5)]
        XCTAssertEqual(polygonArea(convexIntersection(sq, diamond)), 1, accuracy: 1e-12, "square inside diamond")
    }

    func testKeyframePolicy() {
        let policy = KeyframePolicy()
        let ok = KeyframePolicy.State(trackingNormal: true, hasPlane: true, footprintValid: true, viewAngle: 5, keyframeCount: 2,
                                      overlap: 0.55, speed: 0.05, angularSpeed: 3, sharpness: 100, recentBestSharpness: 110,
                                      capturing: false)
        XCTAssertEqual(policy.decide(ok), .capture)
        var s = ok; s.keyframeCount = 0; s.overlap = nil
        XCTAssertEqual(policy.decide(s), .wait(.tapToStart), "first photo is manual")
        var auto = policy; auto.manualFirst = false
        XCTAssertEqual(auto.decide(s), .capture, "or as soon as steady")
        s = ok; s.overlap = 0.8;            XCTAssertEqual(policy.decide(s), .wait(.keepMoving))
        s = ok; s.overlap = 0.2;            XCTAssertEqual(policy.decide(s), .wait(.moveBack))
        s = ok; s.speed = 0.6;              XCTAssertEqual(policy.decide(s), .wait(.tooFast))
        s = ok; s.sharpness = 20;           XCTAssertEqual(policy.decide(s), .wait(.blurry))
        s = ok; s.hasPlane = false;         XCTAssertEqual(policy.decide(s), .wait(.findBoard))
        s = ok; s.trackingNormal = false;   XCTAssertEqual(policy.decide(s), .wait(.trackingLimited))
        s = ok; s.viewAngle = 60;           XCTAssertEqual(policy.decide(s), .wait(.tooOblique))
        s = ok; s.capturing = true;         XCTAssertEqual(policy.decide(s), .wait(.holdStill))
        s = ok; s.keyframeCount = 14;       XCTAssertEqual(policy.decide(s), .wait(.full))
    }

    func testRecordRoundTripAndSorting() throws {
        let cams = [0.4, -0.6, -0.1].map { boardCamera(SIMD3($0, 1.5, 0.75)) }
        let rec = CaptureRecord(frames: cams.enumerated().map { .init(file: "f\($0.offset).jpg", camera: $0.element, timestamp: Double($0.offset), sharpness: 1) },
                                plane: .init(origin: [0, 1.5, 0], normal: [0, 0, 1]))
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(CaptureRecord.self, from: data)
        XCTAssertEqual(back, rec)
        XCTAssertLessThan(simd_length(back.frames[0].camera.centre - cams[0].centre), 1e-12)
        XCTAssertEqual(rec.sortedLeftToRight().frames.map(\.file), ["f1.jpg", "f2.jpg", "f0.jpg"])
    }

    func testLaplacianVarianceRanksSharpOverBlurred() {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let sharp = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360), format: fmt).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            UIColor.black.setFill()
            for i in 0..<40 { ctx.fill(CGRect(x: 12 * i, y: 0, width: 3, height: 360)) }
        }
        let blurred = UIImage(ciImage: CIImage(image: sharp)!.clampedToExtent().applyingGaussianBlur(sigma: 3)
                                .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 360)))
            .normalized(maxDimension: 480)!
        XCTAssertGreaterThan(sharp.sharpness(), 5 * blurred.sharpness())
    }
}
