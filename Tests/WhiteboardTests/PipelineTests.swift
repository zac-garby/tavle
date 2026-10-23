import XCTest
@testable import Whiteboard

final class PipelineTests: XCTestCase {
    let pipeline = WhiteboardPipeline.opencv

    func fixture(_ path: String) throws -> UIImage {
        let url = Bundle(for: Self.self).bundleURL.appendingPathComponent("fixtures/\(path)")
        return try XCTUnwrap(UIImage(contentsOfFile: url.path), path)
    }

    var inputs: [UIImage] {
        get throws { try ["1_left.jpeg", "2_middle.jpeg", "3_right.jpeg"].map { try fixture("input/\($0)") } }
    }

    /// Stage outputs land here for eyeballing (path is printed; it's on the Mac's disk).
    func save(_ img: UIImage, _ name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? img.jpegData(compressionQuality: 0.85)?.write(to: url)
        print("wrote \(url.path) \(img.pixelSize)")
    }

    func testFixturesLoad() throws {
        XCTAssertEqual(try inputs.count, 3)
    }

    func testThreeFixturesMatchReference() throws {
        let out = try pipeline.run(try inputs)
        save(out.mosaic, "stitched.jpg"); save(out.flatFull, "flat_full.jpg"); save(out.flatCropped, "flat_cropped.jpg")
        print("confidences", out.confidences, "warnings", out.warnings)

        XCTAssertEqual(out.confidences.count, 2)
        XCTAssertTrue(out.confidences[0].isLow, "left join is the thin-overlap one")
        XCTAssertFalse(out.confidences[1].isLow)
        XCTAssertEqual(out.warnings.count, 1, "one low-confidence warning, flattening succeeded")

        // Registration + blending is deterministic and should match the reference almost pixel for pixel. The VP
        // RANSAC samples differently from Python's RNG, so flattened outputs differ by a few % in scale: compare
        // those loosely, and check straightness directly.
        for (got, name, minNCC) in [(out.mosaic, "stitched_unrectified.jpg", 0.97), (out.flatFull, "flat_full.jpg", 0.8),
                                    (out.flatCropped, "flat_cropped.jpg", 0.6)] {
            let exp = try fixture("expected/\(name)")
            let (g, e) = (got.pixelSize, exp.pixelSize)
            // The cropped output is now cut at the board's frame (the reference keeps the frame + a strip of wall).
            let tol = name == "flat_cropped.jpg" ? 0.15 : 0.1
            XCTAssertEqual(g.width / g.height, e.width / e.height, accuracy: tol * e.width / e.height, "\(name) aspect")
            XCTAssertEqual(g.width, e.width, accuracy: tol * e.width, "\(name) width")
            let ncc = similarity(got, exp)
            print(name, "size", g, "expected", e, "ncc", ncc)
            XCTAssertGreaterThan(ncc, minNCC, "\(name) looks like the reference")
        }

        let ref = straightness(try fixture("expected/flat_full.jpg")), ours = straightness(out.flatFull)
        print("straightness (deg, weighted median |deviation|): reference", ref, "ours", ours)
        XCTAssertLessThan(ours.vertical, max(0.3, ref.vertical * 1.5), "verticals vertical")
        XCTAssertLessThan(ours.horizontal, max(0.3, ref.horizontal * 1.5), "text rows straight")
    }

    /// Length-weighted median deviation (degrees) of near-vertical segments from 90 and near-horizontal ones from 0.
    func straightness(_ img: UIImage) -> (vertical: Double, horizontal: Double) {
        let raw = CVBridge.houghSegments(img).map(\.doubleValue)
        let segs = stride(from: 0, to: raw.count - 3, by: 4).map { LineSegment(raw[$0], raw[$0 + 1], raw[$0 + 2], raw[$0 + 3]) }
        func wmedian(_ xs: [(Double, Double)]) -> Double {
            let s = xs.sorted { $0.0 < $1.0 }, half = s.reduce(0) { $0 + $1.1 } / 2
            var acc = 0.0
            for (v, w) in s { acc += w; if acc >= half { return v } }
            return .nan
        }
        let v = segs.filter { 60 < $0.angle && $0.angle < 120 }.map { (abs($0.angle - 90), $0.length) }
        let h = segs.filter { $0.angle < 30 || $0.angle > 150 }.map { (min($0.angle, 180 - $0.angle), $0.length) }
        return (wmedian(v), wmedian(h))
    }

    func testSinglePhoto() throws {
        let out = try pipeline.run([try fixture("input/2_middle.jpeg")])
        XCTAssertTrue(out.confidences.isEmpty)
        XCTAssertGreaterThan(out.flatCropped.pixelSize.width, 500)
    }

    func testTwoPhotos() throws {
        let imgs = try inputs
        let out = try pipeline.run([imgs[1], imgs[2]])
        XCTAssertEqual(out.confidences.count, 1)
        XCTAssertGreaterThan(out.mosaic.pixelSize.width, imgs[1].pixelSize.width * 1.2)
    }

    func testNoOverlapReportsError() throws {
        let imgs = try inputs
        XCTAssertThrowsError(try pipeline.run([imgs[0], imgs[2]])) { err in
            XCTAssertEqual(err as? PipelineError, .noOverlap(pair: 0), "\(err)")
        }
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000)).image { ctx in
            UIColor(white: 0.9, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        }
        XCTAssertThrowsError(try pipeline.run([imgs[1], blank]))
    }

    func testEmptyInput() {
        XCTAssertThrowsError(try pipeline.run([])) { XCTAssertEqual($0 as? PipelineError, .noImages) }
    }

    func testVeryLargePhotoIsDownscaled() throws {
        let src = try fixture("input/2_middle.jpeg")
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 6048, height: 8064), format: fmt).image { _ in
            src.draw(in: CGRect(x: 0, y: 0, width: 6048, height: 8064))
        }
        let out = try pipeline.run([big])
        XCTAssertLessThanOrEqual(max(out.mosaic.pixelSize.width, out.mosaic.pixelSize.height), pipeline.maxInputDimension)
    }

    /// Normalised cross-correlation of small grayscale thumbnails (both squashed to the same size).
    func similarity(_ a: UIImage, _ b: UIImage, width: Int = 240, height: Int = 126) -> Double {
        func thumb(_ img: UIImage) -> [Double] {
            var px = [UInt8](repeating: 0, count: width * height)
            let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(img.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
            return px.map(Double.init)
        }
        let x = thumb(a), y = thumb(b)
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        return sxy / (sxx * syy).squareRoot()
    }
}
