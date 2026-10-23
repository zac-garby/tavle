import XCTest
import simd
@testable import Whiteboard

final class GeometryTests: XCTestCase {
    func assertClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tol: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), tol, "\(a) vs \(b)", file: file, line: line)
    }

    // MARK: homographies

    func testRowMajorRoundTrip() {
        let m: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 10]
        XCTAssertEqual(Homography(rowMajor: m).rowMajor, m)
        assertClose(Homography.translation(3, -2).apply(SIMD2(1, 1)), SIMD2(4, -1))
    }

    func testCompositionAppliesRightFirst() {
        let a = Homography(rowMajor: [1.1, 0.05, 10, -0.02, 0.95, 5, 1e-4, -2e-4, 1])
        let b = Homography(rowMajor: [0.9, -0.1, -3, 0.08, 1.05, 7, -3e-5, 5e-5, 1])
        for p in [SIMD2(0.0, 0), SIMD2(120, -40), SIMD2(1900, 2500)] {
            assertClose((a * b).apply(p), a.apply(b.apply(p)), 1e-8)
            assertClose(a.inverse!.apply(a.apply(p)), p, 1e-8)
        }
        XCTAssertNil(Homography(rowMajor: [1, 2, 3, 2, 4, 6, 0, 0, 1]).inverse)
    }

    func testChainToMiddle() {
        // 3 images, each shifted 100px right of the previous: pairwise (right -> left) = translate(+100).
        let t = Homography.translation(100, 0)
        let hs = chainToMiddle([t, t])!
        assertClose(hs[0].apply(SIMD2(0, 0)), SIMD2(-100, 0))
        assertClose(hs[1].apply(SIMD2(0, 0)), SIMD2(0, 0))
        assertClose(hs[2].apply(SIMD2(0, 0)), SIMD2(100, 0))
        XCTAssertEqual(chainToMiddle([])!.count, 1)
        // 2 images: middle is the right one.
        let two = chainToMiddle([t])!
        assertClose(two[0].apply(SIMD2(0, 0)), SIMD2(-100, 0))
    }

    func testCanvas() {
        let (shift, size) = canvas(for: [.translation(-100, 0), .identity, .translation(100, 20)],
                                   sizes: Array(repeating: CGSize(width: 200, height: 100), count: 3))
        XCTAssertEqual(size.width, 400); XCTAssertEqual(size.height, 120)
        assertClose(shift.apply(SIMD2(-100, 0)), SIMD2(0, 0))
    }

    func testPlausibleJoin() {
        let size = CGSize(width: 1000, height: 1500)
        XCTAssertTrue(isPlausibleJoin(.translation(700, 10), rightSize: size))
        XCTAssertFalse(isPlausibleJoin(.scale(5, 5), rightSize: size))              // way too big
        XCTAssertFalse(isPlausibleJoin(.scale(-1, 1), rightSize: size))              // mirrored
        XCTAssertFalse(isPlausibleJoin(Homography(rowMajor: [1, 0, 0, 0, 1, 0, -0.002, 0, 1]), rightSize: size)) // horizon inside
    }

    // MARK: vanishing points

    func testIntersection() {
        let a = LineSegment(0, 0, 10, 10), b = LineSegment(0, 10, 10, 0)
        assertClose(intersect(a.line, b.line), SIMD2(5, 5))
        // Parallel lines meet far away along their direction.
        let p = intersect(LineSegment(0, 0, 0, 10).line, LineSegment(5, 0, 5, 10).line)
        XCTAssertGreaterThan(abs(p.y), 1e6); XCTAssertLessThan(abs(p.x), 1e-3 * abs(p.y))
    }

    func testRansacFindsVanishingPointDespiteOutliers() {
        let vp = SIMD2(800.0, -20000.0)
        var rng = SplitMix64(seed: 42)
        var segs: [LineSegment] = []
        for _ in 0..<60 {  // inliers: segments on lines through vp
            let base = SIMD2(Double.random(in: 0...2000, using: &rng), Double.random(in: 200...1500, using: &rng))
            let d = simd_normalize(vp - base) * Double.random(in: 100...400, using: &rng)
            segs.append(LineSegment(base.x, base.y, base.x + d.x, base.y + d.y))
        }
        for _ in 0..<30 {  // outliers: random near-vertical junk
            let x = Double.random(in: 0...2000, using: &rng), y = Double.random(in: 0...1500, using: &rng)
            segs.append(LineSegment(x, y, x + Double.random(in: -60...60, using: &rng), y + 150))
        }
        let est = ransacVanishingPoint(segs)!
        // Compare as directions from the image centre (a far VP is only well-defined up to that).
        let c = SIMD2(1000.0, 750.0)
        let angle = acos(simd_dot(simd_normalize(est - c), simd_normalize(vp - c))) * 180 / .pi
        XCTAssertLessThan(angle, 0.2)
        XCTAssertNil(ransacVanishingPoint([LineSegment(0, 0, 1, 1)]))
    }

    // MARK: rectification

    /// Distort an axis-aligned grid by a known homography, estimate VPs from its lines, rectify, and check the
    /// grid comes back axis-aligned with the centre at unit scale.
    func testRectifyingHomographyUndoesPerspective() {
        let size = CGSize(width: 3000, height: 2000)
        let g = Homography(rowMajor: [1.0, 0.08, 0, -0.05, 0.97, 60, 4e-5, -6e-5, 1])
        let gridV = stride(from: 200.0, through: 2800, by: 400).map { x in (SIMD2(x, 100), SIMD2(x, 1900)) }
        let gridH = stride(from: 200.0, through: 1800, by: 400).map { y in (SIMD2(100, y), SIMD2(2900, y)) }
        func seg(_ e: (SIMD2<Double>, SIMD2<Double>)) -> LineSegment {
            let p = g.apply(e.0), q = g.apply(e.1); return LineSegment(p.x, p.y, q.x, q.y)
        }
        let v = ransacVanishingPoint(gridV.map(seg), tolerance: 0.05)!, h = ransacVanishingPoint(gridH.map(seg), tolerance: 0.05)!
        let (hr, w, ht) = rectifyingHomography(vertical: v, horizontal: h, imageSize: size)!
        XCTAssertGreaterThan(w, 0); XCTAssertGreaterThan(ht, 0)
        let total = hr * g
        for (a, b) in gridV {
            let p = total.apply(a), q = total.apply(b)
            XCTAssertLessThan(abs(p.x - q.x) / abs(p.y - q.y), 1e-3, "vertical stays vertical")
            XCTAssertGreaterThan(q.y, p.y, "not flipped")
        }
        for (a, b) in gridH {
            let p = total.apply(a), q = total.apply(b)
            XCTAssertLessThan(abs(p.y - q.y) / abs(p.x - q.x), 1e-3, "horizontal stays horizontal")
            XCTAssertGreaterThan(q.x, p.x, "not mirrored")
        }
        // Unit scale at the (distorted) image centre.
        let c = SIMD2(1500.0, 1000.0)
        let p0 = hr.apply(c)
        XCTAssertEqual(abs((hr.apply(c + SIMD2(1, 0)) - p0).x), 1, accuracy: 1e-3)
        XCTAssertEqual(abs((hr.apply(c + SIMD2(0, 1)) - p0).y), 1, accuracy: 1e-3)
        // Everything lands inside the canvas.
        for p in corners(of: size) {
            let q = hr.apply(p)
            XCTAssertGreaterThanOrEqual(q.x, -1e-6); XCTAssertGreaterThanOrEqual(q.y, -1e-6)
            XCTAssertLessThanOrEqual(q.x, Double(w) + 1); XCTAssertLessThanOrEqual(q.y, Double(ht) + 1)
        }
    }

    func testRectifyingHomographyRejectsHorizonThroughImage() {
        let size = CGSize(width: 1000, height: 1000)
        // Both VPs inside the image -> horizon crosses it.
        XCTAssertNil(rectifyingHomography(vertical: SIMD2(500, 100), horizontal: SIMD2(900, 120), imageSize: size))
    }

    func testRectifyingHomographyNearIdentityForFarVPs() {
        let size = CGSize(width: 1000, height: 800)
        let (hr, w, h) = rectifyingHomography(vertical: SIMD2(500, 1e9), horizontal: SIMD2(1e9, 400), imageSize: size)!
        XCTAssertEqual(Double(w), 1000, accuracy: 1); XCTAssertEqual(Double(h), 800, accuracy: 1)
        assertClose(hr.apply(SIMD2(123, 456)), SIMD2(123, 456), 1e-3)
    }

    // MARK: rectangles

    func testLargestRectangleSmall() {
        let rows = ["0100",
                    "1111",
                    "1110",
                    "0010"]
        let m = rows.flatMap { $0.map { $0 == "1" } }
        XCTAssertEqual(largestRectangle(in: m, width: 4, height: 4), PixelRect(x0: 0, y0: 1, x1: 3, y1: 3))
        XCTAssertEqual(boundingBox(of: m, width: 4, height: 4), PixelRect(x0: 0, y0: 0, x1: 4, y1: 4))
        XCTAssertNil(largestRectangle(in: [false, false], width: 2, height: 1))
        XCTAssertNil(boundingBox(of: [false, false], width: 2, height: 1))
    }

    func testLargestRectangleMatchesBruteForce() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<40 {
            let w = Int.random(in: 1...9, using: &rng), h = Int.random(in: 1...9, using: &rng)
            let p = Double.random(in: 0.3...0.95, using: &rng)
            let m = (0..<(w * h)).map { _ in Double.random(in: 0..<1, using: &rng) < p }
            var best = 0
            for y0 in 0..<h { for y1 in (y0 + 1)...h { for x0 in 0..<w { for x1 in (x0 + 1)...w {
                var ok = true
                outer: for y in y0..<y1 { for x in x0..<x1 where !m[y * w + x] { ok = false; break outer } }
                if ok { best = max(best, (x1 - x0) * (y1 - y0)) }
            } } } }
            let r = largestRectangle(in: m, width: w, height: h)
            let area = r.map { ($0.x1 - $0.x0) * ($0.y1 - $0.y0) } ?? 0
            XCTAssertEqual(area, best)
            if let r { for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { XCTAssertTrue(m[y * w + x]) } } }
        }
    }
}
