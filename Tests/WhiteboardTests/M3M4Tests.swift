import XCTest
import simd
@testable import Whiteboard

final class QuadTests: XCTestCase {
    func testHomographyFromFourPoints() {
        let truth = Homography(rowMajor: [1.2, 0.1, 30, -0.05, 0.9, 12, 1e-4, -2e-4, 1])
        let src = [SIMD2(0.0, 0), SIMD2(400, 10), SIMD2(380, 300), SIMD2(-20, 290)]
        let dst = src.map(truth.apply)
        let h = homography(from: src, to: dst)!
        for p in [SIMD2(100.0, 100), SIMD2(250, 40), SIMD2(0, 200)] {
            XCTAssertLessThan(simd_length(h.apply(p) - truth.apply(p)), 1e-6)
        }
        XCTAssertNil(homography(from: [SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2), SIMD2(0, 1)], to: dst), "collinear")
    }

    func testQuadHelpers() {
        let q = [SIMD2(10.0, 10), SIMD2(110, 20), SIMD2(100, 60), SIMD2(5, 50)]
        XCTAssertTrue(isConvexQuad(q))
        XCTAssertFalse(isConvexQuad([q[0], q[2], q[1], q[3]]), "bow-tie")
        XCTAssertFalse(isConvexQuad(q.reversed()), "anticlockwise")
        let (w, h) = rectifiedSize(of: q)
        XCTAssertEqual(w, Int(simd_distance(q[0], q[1]).rounded()))
        XCTAssertEqual(h, Int(simd_distance(q[1], q[2]).rounded()))
    }
}

final class BlendAndEnhanceTests: XCTestCase {
    let pose = PoseCaptureTests()

    /// Two overlapping synthetic frames; frame 1 has a glare streak where it overlaps frame 0. With glare
    /// reduction the streak area should come from frame 0 and look like the clean board.
    func testGlareReductionUsesTheCleanFrame() throws {
        let cams = Array(pose.cameras.prefix(2))
        let clean = cams.map(pose.render)
        // Streak: vertical near-white band well inside the overlap (frame 0 sees frame 1's x < ~500).
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let glared = UIGraphicsImageRenderer(size: clean[1].pixelSize, format: fmt).image { ctx in
            clean[1].draw(at: .zero)
            UIColor(white: 1, alpha: 0.95).setFill()
            ctx.fill(CGRect(x: 100, y: 0, width: 140, height: clean[1].pixelSize.height))
        }
        let reg = try PoseRegistrar(record: pose.record(cams)).register(clean)
        func mosaic(_ imgs: [UIImage], glare: Bool) throws -> UIImage {
            var b = CVBlender(); b.reduceGlare = glare
            return try b.blend(imgs, registration: reg)
        }
        let reference = try mosaic(clean, glare: true)
        let with = try mosaic([clean[0], glared], glare: true), without = try mosaic([clean[0], glared], glare: false)
        // Where does the streak land? Map its centre line through frame 1's registration.
        let (shift, _) = canvas(for: reg.toReference.compactMap { $0 }, sizes: clean.map(\.pixelSize))
        let toCanvas = shift * reg.toReference[1]!
        let top = toCanvas.apply(SIMD2(170.0, 400)), bottom = toCanvas.apply(SIMD2(170.0, 1600))
        let region = CGRect(x: top.x - 60, y: top.y, width: 120, height: bottom.y - top.y)
        let errWith = meanAbsDiff(with, reference, region), errWithout = meanAbsDiff(without, reference, region)
        print("glare region error: with reduction \(errWith), without \(errWithout)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (img, name) in [(with, "glare_with"), (without, "glare_without"), (reference, "glare_reference")] {
            try? img.thumbnail(maxDimension: 1400).jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent(name + ".jpg"))
        }
        print("glare region", region)
        let control = toCanvas.apply(SIMD2(-700.0, 400))   // inside frame 0 only
        let controlErr = meanAbsDiff(with, reference, CGRect(x: control.x - 60, y: control.y, width: 120, height: bottom.y - top.y))
        print("control region error \(controlErr)")
        XCTAssertLessThan(errWith, 6)
        XCTAssertGreaterThan(errWithout, 3 * errWith)
    }

    func testFeatherAndMultiBandBothMatchReferenceStitch() throws {
        let url = Bundle(for: Self.self).bundleURL.appendingPathComponent("fixtures/input")
        let imgs = ["1_left.jpeg", "2_middle.jpeg", "3_right.jpeg"].map { UIImage(contentsOfFile: url.appendingPathComponent($0).path)! }
        let reg = try CVRegistrar().register(imgs)
        var feather = CVBlender(); feather.multiBand = false; feather.reduceGlare = false
        let a = try feather.blend(imgs, registration: reg), b = try CVBlender().blend(imgs, registration: reg)
        XCTAssertEqual(a.pixelSize, b.pixelSize)
        XCTAssertLessThan(meanAbsDiff(a, b, CGRect(origin: .zero, size: a.pixelSize)), 8)
    }

    func testEnhancementWhitensBoardAndKeepsInk() throws {
        let board = PoseCaptureTests.boardImage
        let region = CGRect(x: 1000, y: 400, width: 4000, height: 1600)
        let before = luma(board, region)
        for mode in [1, 2] {
            let e = CVBridge.enhance(board, mode: mode)
            XCTAssertEqual(e.pixelSize, board.pixelSize)
            let after = luma(e, region)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-test-output")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? e.cropped(to: CGRect(x: 2600, y: 300, width: 2400, height: 1400))?.jpegData(compressionQuality: 0.85)?
                .write(to: dir.appendingPathComponent("enhanced_\(mode).jpg"))
            print("mode \(mode): median \(percentile(before, 0.5)) -> \(percentile(after, 0.5)), p2 \(percentile(before, 0.02)) -> \(percentile(after, 0.02))")
            XCTAssertGreaterThanOrEqual(percentile(after, 0.5), 245, "board is white")
            XCTAssertLessThan(percentile(after, 0.02), percentile(before, 0.02) + 10, "ink not washed out")
        }
        XCTAssertTrue(CVBridge.enhance(board, mode: 0) === board)
    }

    // MARK: helpers

    func gray(_ img: UIImage, _ r: CGRect, maxSide: Int = 600) -> [UInt8] {
        let s = min(1, Double(maxSide) / Double(max(r.width, r.height)))
        let w = max(1, Int(r.width * s)), h = max(1, Int(r.height * s))
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let cg = img.cgImage!.cropping(to: r.integral)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    func meanAbsDiff(_ a: UIImage, _ b: UIImage, _ r: CGRect) -> Double {
        let x = gray(a, r), y = gray(b, r)
        return zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(x.count)
    }

    func luma(_ img: UIImage, _ r: CGRect) -> [UInt8] { gray(img, r, maxSide: 1500) }
    func percentile(_ v: [UInt8], _ p: Double) -> Int { Int(v.sorted()[Int(Double(v.count - 1) * p)]) }
}

final class ExportTests: XCTestCase {
    func testFormats() {
        let img = PoseCaptureTests.boardImage.thumbnail(maxDimension: 800)
        XCTAssertEqual(ExportFormat.pdf.data(for: img)?.prefix(4), Data("%PDF".utf8))
        XCTAssertEqual(ExportFormat.png.data(for: img)?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(ExportFormat.jpeg.data(for: img)?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(img.pixelSize.width, 800, accuracy: 1)
        XCTAssertEqual(img.pixelSize.width / img.pixelSize.height,
                       PoseCaptureTests.boardImage.pixelSize.width / PoseCaptureTests.boardImage.pixelSize.height, accuracy: 0.01)
    }
}

final class BoardStoreTests: XCTestCase {
    var root: URL!
    var store: BoardStore!
    var defaults: UserDefaults!
    let suite = "whiteboard-tests-\(UUID().uuidString)"

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("boards-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: suite)
        store = BoardStore(root: root, defaults: defaults)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    var fixtures: [UIImage] {
        let url = Bundle(for: Self.self).bundleURL.appendingPathComponent("fixtures/input")
        return ["1_left.jpeg", "2_middle.jpeg", "3_right.jpeg"].map { UIImage(contentsOfFile: url.appendingPathComponent($0).path)! }
    }

    func testFailedBoardKeepsPhotosAndCanBeFixed() async throws {
        let f = fixtures
        // Left + right only: no overlap -> fails, but the board and its photos stay.
        var b = try store.create(images: [f[0], f[2]], source: .photos)
        await store.process(b.id)
        b = store.board(b.id)!
        XCTAssertNotNil(b.failure)
        XCTAssertEqual(b.photos.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(b, b.photos[0]).path))
        // Fix it: add the middle photo and put it in the middle.
        try store.addPhotos(b, [f[1]])
        store.movePhotos(store.board(b.id)!, from: [2], to: 1)
        await store.process(b.id)
        b = store.board(b.id)!
        XCTAssertTrue(b.isDone, "\(b.status)")
        for name in ["mosaic.jpg", "full.jpg", "cropped.jpg", "thumb.jpg", "board.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(b, name).path), name)
        }
        // Persisted: a fresh store sees the same board.
        let again = BoardStore(root: root)
        XCTAssertEqual(again.board(b.id), b)
        // Enhanced result is produced and cached.
        let e = await store.result(b, framing: .board, enhancement: .whiten)
        XCTAssertNotNil(e)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(b, "cropped_e1.jpg").path))
        // Content crop: inside the board crop, cached, and enhanced versions of it too.
        let board = await store.result(b, framing: .board, enhancement: .original)!
        let content = await store.result(b, framing: .content, enhancement: .original)!
        XCTAssertLessThanOrEqual(content.pixelSize.width, board.pixelSize.width)
        XCTAssertLessThanOrEqual(content.pixelSize.height, board.pixelSize.height)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(b, "content.jpg").path))
        let contentScan = await store.result(b, framing: .content, enhancement: .scan)
        XCTAssertNotNil(contentScan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(b, "content_e2.jpg").path))
        store.delete(b)
        XCTAssertNil(store.board(b.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dir(b).path))
    }

    func testCorners() async throws {
        var b = try store.create(images: fixtures, source: .photos)
        await store.process(b.id)
        b = store.board(b.id)!
        let mosaic = UIImage(contentsOfFile: store.file(b, "mosaic.jpg").path)!
        let auto = store.initialCorners(b, mosaicSize: mosaic.pixelSize)
        XCTAssertTrue(isConvexQuad(auto), "auto crop maps back to a sensible quad: \(auto)")
        // Mapping the auto quad forward lands on the cropped rectangle.
        let m = Homography(rowMajor: b.mosaicToFull!)
        let r = b.croppedRect!
        XCTAssertLessThan(simd_length(m.apply(auto[0]) - SIMD2(r[0], r[1])), 1)
        XCTAssertLessThan(simd_length(m.apply(auto[2]) - SIMD2(r[0] + r[2], r[1] + r[3])), 1)

        let quad = [SIMD2(500.0, 600), SIMD2(4500, 500), SIMD2(4600, 3000), SIMD2(400, 3100)]
        try await store.applyCorners(b, quad)
        b = store.board(b.id)!
        XCTAssertNotNil(b.corners)
        let out = UIImage(contentsOfFile: store.file(b, "cropped.jpg").path)!
        XCTAssertEqual(Int(out.pixelSize.width), rectifiedSize(of: quad).width)
        XCTAssertEqual(store.initialCorners(b, mosaicSize: mosaic.pixelSize), quad)
        await store.resetCorners(b)
        b = store.board(b.id)!
        XCTAssertNil(b.corners)
        XCTAssertEqual(UIImage(contentsOfFile: store.file(b, "cropped.jpg").path)!.pixelSize.width, r[2], accuracy: 1)
    }

    func testScanBoardUsesPosesForItsOwnFrames() throws {
        let pose = PoseCaptureTests()
        let cams = Array(pose.cameras.prefix(3))
        let src = root.appendingPathComponent("scan-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let rec = pose.record(cams)
        for (f, c) in zip(rec.frames, cams) { try pose.render(c).jpegData(compressionQuality: 0.9)!.write(to: src.appendingPathComponent(f.file)) }
        try rec.write(to: src)
        let b = try store.create(scan: src)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "moved into the history")
        XCTAssertEqual(b.photos, ["f0.jpg", "f1.jpg", "f2.jpg"])
        XCTAssertEqual(BoardStore.captureRecord(in: store.dir(b), photos: ["f2.jpg", "f0.jpg"])?.frames.map(\.file), ["f2.jpg", "f0.jpg"])
        try store.addPhotos(b, [pose.render(cams[0])])
        let withExtra = store.board(b.id)!
        XCTAssertNil(BoardStore.captureRecord(in: store.dir(withExtra), photos: withExtra.photos), "added photo has no pose")
    }

    func testLookIsSavedAndBecomesTheDefault() throws {
        let b = try store.create(images: [fixtures[0]], source: .photos)
        XCTAssertEqual(b.framing, .board)
        XCTAssertEqual(b.enhancement, .original)
        store.setFraming(b, .content)
        store.setEnhancement(store.board(b.id)!, .whiten)
        let again = BoardStore(root: root, defaults: defaults).board(b.id)!
        XCTAssertEqual(again.framing, .content)
        XCTAssertEqual(again.enhancement, .whiten)
        let next = try store.create(images: [fixtures[1]], source: .photos)
        XCTAssertEqual(next.framing, .content, "last framing is the default")
        XCTAssertEqual(next.enhancement, .whiten, "last look is the default")
    }

    func testOldBoardJSONStillLoads() throws {
        let id = UUID()
        let d = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let json = #"{"id":"\#(id.uuidString)","created":0,"title":"Old","source":"photos","photos":["a.jpg"],"status":{"draft":{}},"warnings":[]}"#
        try Data(json.utf8).write(to: d.appendingPathComponent("board.json"))
        let b = try XCTUnwrap(BoardStore(root: root, defaults: defaults).board(id))
        XCTAssertEqual(b.title, "Old")
        XCTAssertEqual(b.framing, .board)
        XCTAssertEqual(b.enhancement, .original)
        XCTAssertEqual(b.trim(.content), Board.wholeImage)
    }

    func testTrimsAndCovers() async throws {
        var b = try store.create(images: fixtures, source: .photos)
        await store.process(b.id)
        b = store.board(b.id)!
        let whole = await store.cover(b)!
        let r = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        store.setTrim(b, .board, r)
        store.setTrim(store.board(b.id)!, .full, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        b = store.board(b.id)!
        XCTAssertEqual(b.trim(.board).minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b.trim(.content), Board.wholeImage, "trims are per framing")
        // The cover follows the trim (aspect of the cropped region).
        let base = await store.result(b, framing: .board, enhancement: .original)!
        let cover = await store.cover(b)!
        XCTAssertEqual(cover.size.width / cover.size.height, (0.5 * base.pixelSize.width) / (0.6 * base.pixelSize.height), accuracy: 0.02)
        XCTAssertNotEqual(cover.size.width / cover.size.height, whole.size.width / whole.size.height, accuracy: 0.02)
        XCTAssertEqual(base.trimmed(b.trim(.board)).pixelSize.width, (0.5 * base.pixelSize.width).rounded(), accuracy: 1)
        // Back to the whole image clears it.
        store.setTrim(b, .board, Board.wholeImage)
        XCTAssertNil(store.board(b.id)!.trims["board"])
        // New corners make board / content trims meaningless; the full-image trim stays.
        store.setTrim(store.board(b.id)!, .content, r)
        try await store.applyCorners(store.board(b.id)!, [SIMD2(500.0, 600), SIMD2(4500, 500), SIMD2(4600, 3000), SIMD2(400, 3100)])
        b = store.board(b.id)!
        XCTAssertEqual(b.trim(.content), Board.wholeImage)
        XCTAssertNotEqual(b.trim(.full), Board.wholeImage)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: store.dir(b).path)).allSatisfy { !$0.hasPrefix("cover-") },
                      "covers are re-rendered after the crop changes")
    }
}
