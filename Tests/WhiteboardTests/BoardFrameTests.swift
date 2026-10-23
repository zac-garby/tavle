import XCTest
@testable import Whiteboard

final class BoardFrameTests: XCTestCase {
    func testDetectsFrameNotDivider() {
        let w = 1200, h = 500
        var rng = SplitMix64(seed: 5)
        var d = [UInt8](repeating: 0, count: w * h)
        // Board inside [100, 1150) x [40, 470); 10px frame (60) around it; wall (90) outside; top-right no photo.
        for y in 0..<h {
            for x in 0..<w {
                let inBoard = (100..<1150).contains(x) && (40..<470).contains(y)
                let inFrame = (90..<1160).contains(x) && (30..<480).contains(y)
                var v: Int = inBoard ? Int.random(in: 0...12, using: &rng) : (inFrame ? 60 : 90)
                if inBoard, (400..<403).contains(x) { v = 110 }                 // ruler-straight divider
                if inBoard, (700..<760).contains(x), y % 7 == 0 { v = 120 }     // writing
                if x > 1000 && y < 60 { v = 255 }                               // not photographed
                d[y * w + x] = UInt8(v)
            }
        }
        let f = detectBoardFrame(distance: d, width: w, height: h)
        XCTAssertEqual(Double(f.left ?? -1), 100, accuracy: 2)
        XCTAssertEqual(Double(f.right ?? -1), 1150, accuracy: 2)
        XCTAssertEqual(Double(f.top ?? -1), 40, accuracy: 2)
        XCTAssertEqual(Double(f.bottom ?? -1), 470, accuracy: 2)
    }

    func testNoFrameWhenBoardRunsOffThePhotos() {
        let w = 800, h = 300
        var rng = SplitMix64(seed: 9)
        let d = (0..<(w * h)).map { _ in UInt8.random(in: 0...12, using: &rng) }
        XCTAssertEqual(detectBoardFrame(distance: d, width: w, height: h), BoardFrame())
    }

    /// The reference board pasted inside a grey frame on a beige wall, with a black (unphotographed) corner.
    func testCropsToFrameInSyntheticPhoto() throws {
        // Inner part of the reference board (its edges contain bits of the real frame).
        let src = PoseCaptureTests.boardImage, ss = src.pixelSize
        let board = src.cropped(to: CGRect(x: ss.width * 0.05, y: ss.height * 0.08, width: ss.width * 0.9, height: ss.height * 0.84))!
            .thumbnail(maxDimension: 3000)
        let bs = board.pixelSize
        let canvas = CGSize(width: bs.width + 400, height: bs.height + 300)
        let boardRect = CGRect(x: 180, y: 120, width: bs.width, height: bs.height)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            UIColor(red: 0.72, green: 0.66, blue: 0.55, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: canvas))
            UIColor(white: 0.42, alpha: 1).setFill(); ctx.fill(boardRect.insetBy(dx: -25, dy: -25))
            board.draw(in: boardRect)
            UIColor.black.setFill(); ctx.fill(CGRect(x: canvas.width - 500, y: 0, width: 500, height: 200))
        }
        let frame = try XCTUnwrap(CVCropper().boardFrameRect(img))
        print("frame", frame, "board", boardRect)
        XCTAssertEqual(frame.minX, boardRect.minX, accuracy: 30)
        XCTAssertEqual(frame.maxX, boardRect.maxX, accuracy: 30)
        XCTAssertEqual(frame.minY, boardRect.minY, accuracy: 30)
        XCTAssertEqual(frame.maxY, boardRect.maxY, accuracy: 30)
        let (_, tidy) = CVCropper().cropRects(of: img)
        XCTAssertTrue(boardRect.insetBy(dx: -5, dy: -5).contains(tidy), "\(tidy) inside the board")
        XCTAssertGreaterThan(tidy.width, 0.8 * boardRect.width)
        var plain = CVCropper(); plain.detectFrame = false
        XCTAssertFalse(boardRect.insetBy(dx: -5, dy: -5).contains(plain.cropRects(of: img).tidy), "without detection the wall is kept")
    }

    func testFixtureCrop() throws {
        let url = Bundle(for: Self.self).bundleURL.appendingPathComponent("fixtures/input")
        let imgs = ["1_left.jpeg", "2_middle.jpeg", "3_right.jpeg"].map { UIImage(contentsOfFile: url.appendingPathComponent($0).path)! }
        let out = try WhiteboardPipeline.opencv.run(imgs)
        let frame = CVCropper().boardFrameRect(out.flatFull)
        print("fixture full", out.flatFull.pixelSize, "frame", String(describing: frame), "cropped", out.croppedRect)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.flatCropped.thumbnail(maxDimension: 1600).jpegData(compressionQuality: 0.85)?.write(to: dir.appendingPathComponent("frame_cropped.jpg"))
        try? out.flatFull.thumbnail(maxDimension: 1600).jpegData(compressionQuality: 0.85)?.write(to: dir.appendingPathComponent("frame_full.jpg"))
    }
}

final class ContentCropTests: XCTestCase {
    /// White board with writing in a known block, dust, a frame strip along the left edge and a glare streak.
    func testContentRectFindsTheWriting() throws {
        let size = CGSize(width: 4000, height: 1600)
        let writing = CGRect(x: 900, y: 400, width: 1800, height: 700)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(white: 0.78, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.97, alpha: 1).setFill(); ctx.fill(CGRect(x: 3000, y: 0, width: 300, height: 1600))   // glare
            UIColor(white: 0.45, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 1600))       // frame
            UIColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1).setFill()                                            // ink
            var x = writing.minX
            while x < writing.maxX {
                ctx.fill(CGRect(x: x, y: writing.minY, width: 8, height: writing.height))
                ctx.fill(CGRect(x: x, y: writing.minY + CGFloat(Int(x) % 300), width: 120, height: 8))
                x += 140
            }
            ctx.fill(CGRect(x: writing.minX, y: writing.maxY - 8, width: writing.width, height: 8))
            UIColor(white: 0.3, alpha: 1).setFill()
            for p in [CGPoint(x: 300, y: 200), CGPoint(x: 3600, y: 1400), CGPoint(x: 2000, y: 1500)] {   // dust
                ctx.fill(CGRect(origin: p, size: CGSize(width: 3, height: 3)))
            }
        }
        let r = CVBridge.contentRect(img, margin: 0.025)
        let m = 0.025 * 4000.0
        print("content rect", r)
        XCTAssertEqual(r.minX, writing.minX - m, accuracy: 25)
        XCTAssertEqual(r.maxX, writing.maxX + m, accuracy: 25)
        XCTAssertEqual(r.minY, writing.minY - m, accuracy: 25)
        XCTAssertEqual(r.maxY, writing.maxY + m, accuracy: 25)
    }

    func testBlankBoardKeepsEverything() {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: fmt).image { ctx in
            UIColor(white: 0.8, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        XCTAssertEqual(CVBridge.contentRect(img, margin: 0.025), CGRect(x: 0, y: 0, width: 800, height: 400))
    }

    func testFixtureContent() throws {
        let board = PoseCaptureTests.boardImage
        let r = CVBridge.contentRect(board, margin: 0.025)
        print("fixture board", board.pixelSize, "content", r)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? board.cropped(to: r)?.thumbnail(maxDimension: 1600).jpegData(compressionQuality: 0.85)?.write(to: dir.appendingPathComponent("content.jpg"))
        XCTAssertTrue(CGRect(origin: .zero, size: board.pixelSize).contains(r))
    }
}
