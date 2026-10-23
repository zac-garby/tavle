import AVFoundation
import XCTest
import simd
@testable import Whiteboard

final class VideoTests: XCTestCase {
    func testPhaseCorrelationSign() throws {
        let board = PoseCaptureTests.boardImage.cgImage!
        func crop(_ x: Int) -> UIImage { UIImage(cgImage: board.cropping(to: CGRect(x: x, y: 600, width: 400, height: 300))!) }
        var r = 0.0
        // Viewport moves right by 12 px -> content moves left by 12 px.
        let s = CVBridge.shift(from: crop(2000), to: crop(2012), response: &r)
        XCTAssertEqual(Double(s.x), -12, accuracy: 0.5)
        XCTAssertEqual(Double(s.y), 0, accuracy: 0.5)
        XCTAssertGreaterThan(r, 0.1)
    }

    func testSelectionOnSyntheticSweep() {
        let size = SIMD2(400.0, 700.0)
        // Camera pans right 1600 px in 100 samples (content moves left), with a blurry patch.
        let p = (0..<100).map { SIMD2(-16.0 * Double($0), 0.3 * Double($0 % 3)) }
        var sharp = [Double](repeating: 100, count: 100)
        for i in 20..<26 { sharp[i] = 10 }
        let keys = KeyframeSelection().select(positions: p, sharpness: sharp, frameSize: size)
        XCTAssertEqual(keys, keys.sorted(), "pan right: time order is left -> right")
        for (n, (a, b)) in zip(keys, keys.dropFirst()).enumerated() {
            let o = KeyframeSelection.overlap(p[b] - p[a], size)
            XCTAssertGreaterThanOrEqual(o, 0.28)
            if n < keys.count - 2 { XCTAssertLessThanOrEqual(o, 0.55) }   // the extra end frame may overlap more
        }
        XCTAssertFalse(keys.contains { (20..<26).contains($0) }, "skips blurry samples when it can")
        XCTAssertGreaterThan(keys.last!, 90, "covers the end of the sweep")
        // Same sweep the other way round -> reversed.
        let back = KeyframeSelection().select(positions: p.map { -$0 }, sharpness: sharp, frameSize: size)
        XCTAssertEqual(back, back.sorted(by: >))
        XCTAssertEqual(KeyframeSelection().select(positions: [.zero, .zero], sharpness: [1, 2], frameSize: size), [1])
    }

    /// Writes a 720x1280 video panning across the reference board, then extracts and stitches it.
    func makeSweepVideo(leftToRight: Bool) async throws -> URL {
        let board = PoseCaptureTests.boardImage.cgImage!
        let H = 1280, W = 720
        let scale = Double(H) / Double(board.height), bw = Int(Double(board.width) * scale)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(leftToRight).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: W, AVVideoHeightKey: H])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W,
            kCVPixelBufferHeightKey as String: H])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = 120
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let u = Double(f) / Double(frames - 1)
            let x = Double(bw - W) * (leftToRight ? u : 1 - u)
            ctx.draw(board, in: CGRect(x: -x, y: 0, width: Double(bw), height: Double(H)))
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testVideoSweepEndToEnd() async throws {
        for ltr in [true, false] {
            let url = try await makeSweepVideo(leftToRight: ltr)
            let frames = try await VideoKeyframeExtractor().extract(from: url)
            XCTAssertGreaterThanOrEqual(frames.count, 5, "ltr \(ltr)")
            XCTAssertLessThanOrEqual(frames.count, 9, "ltr \(ltr)")
            let reg = try CVRegistrar().register(frames)
            // Left -> right: frame centres land at increasing x in the reference frame.
            XCTAssertEqual(reg.dropped, [])
            let xs = zip(reg.toReference, frames).map { (h: Homography?, f: UIImage) -> Double in
                let c = SIMD2(Double(f.pixelSize.width) / 2, Double(f.pixelSize.height) / 2)
                return h?.apply(c).x ?? 0
            }
            XCTAssertEqual(xs, xs.sorted(), "ltr \(ltr): \(xs)")
            let out = try WhiteboardPipeline.opencv.run(frames)
            let s = out.mosaic.pixelSize
            XCTAssertEqual(s.width / s.height, Double(PoseCaptureTests.boardImage.pixelSize.width / PoseCaptureTests.boardImage.pixelSize.height),
                           accuracy: 0.3)
        }
    }
}
