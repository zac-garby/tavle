import UIKit
import simd

/// What a guided capture saves: upright JPEGs plus each frame's camera and the board plane.
/// Written as `capture.json` next to the frames, so a capture from the phone can be replayed in the simulator
/// (`-WBCapture <dir>`) or turned into a test fixture.
struct CaptureRecord: Codable, Equatable {
    struct Frame: Codable, Equatable {
        var file: String
        var width: Double, height: Double
        var K: [Double]              // 3x3 row-major, for the saved (upright) image
        var R: [Double]              // 3x3 row-major, world -> camera (OpenCV convention)
        var t: [Double]
        var timestamp: Double
        var sharpness: Double

        init(file: String, camera c: Camera, timestamp: Double, sharpness: Double) {
            self.file = file
            width = c.size.x; height = c.size.y
            K = Homography(c.K).rowMajor; R = Homography(c.R).rowMajor; t = [c.t.x, c.t.y, c.t.z]
            self.timestamp = timestamp
            self.sharpness = sharpness
        }

        var camera: Camera {
            Camera(K: Homography(rowMajor: K).matrix, R: Homography(rowMajor: R).matrix,
                   t: SIMD3(t[0], t[1], t[2]), size: SIMD2(width, height))
        }
    }

    struct Plane: Codable, Equatable {
        var origin: [Double]
        var normal: [Double]
    }

    var version = 1
    var frames: [Frame]
    var plane: Plane?

    /// The board plane, oriented towards the first camera. Nil if none was found or it's degenerate.
    var boardPlane: BoardPlane? {
        guard let p = plane, let c = frames.first?.camera else { return nil }
        return BoardPlane(origin: SIMD3(p.origin[0], p.origin[1], p.origin[2]),
                          normal: SIMD3(p.normal[0], p.normal[1], p.normal[2]), facing: c.centre)
    }

    /// Frames ordered left -> right along the board (lesson 1: order explicitly), by where each optical axis
    /// meets the plane. Without a plane: capture order.
    func sortedLeftToRight() -> CaptureRecord {
        guard let plane = boardPlane else { return self }
        func key(_ f: Frame) -> Double {
            let c = f.camera
            return plane.intersect(from: c.centre, dir: c.forward).map { plane.toPlane($0).x } ?? .infinity
        }
        var r = self
        r.frames = frames.sorted { key($0) < key($1) }
        return r
    }

    static let fileName = "capture.json"

    func write(to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent(Self.fileName))
    }

    /// The record (sorted left -> right) and its images in the same order.
    static func load(from dir: URL) throws -> (CaptureRecord, [UIImage]) {
        let rec = try JSONDecoder().decode(CaptureRecord.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
            .sortedLeftToRight()
        let imgs = try rec.frames.map { f in
            guard let img = UIImage(contentsOfFile: dir.appendingPathComponent(f.file).path) else { throw PipelineError.imageConversion }
            return img
        }
        return (rec, imgs)
    }

    /// Documents/Captures/<timestamp>; visible in the Files app (UIFileSharingEnabled) for pulling off the phone.
    static func newDirectory() throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = URL.documentsDirectory.appendingPathComponent("Captures").appendingPathComponent(fmt.string(from: .now))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Sharpness

/// Variance of the 4-neighbour Laplacian over an 8-bit luma buffer, sampled every `step` pixels inside the
/// central `crop` fraction. Higher = sharper. Only meaningful relative to other frames of the same scene.
func laplacianVariance(_ base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                       step: Int = 4, crop: Double = 0.6) -> Double {
    let x0 = max(step, Int(Double(width) * (1 - crop) / 2)), x1 = min(width - step - 1, Int(Double(width) * (1 + crop) / 2))
    let y0 = max(step, Int(Double(height) * (1 - crop) / 2)), y1 = min(height - step - 1, Int(Double(height) * (1 + crop) / 2))
    guard x1 > x0, y1 > y0 else { return 0 }
    var sum = 0.0, sumSq = 0.0, n = 0.0
    var y = y0
    while y <= y1 {
        let row = base + y * bytesPerRow, up = row - bytesPerRow, down = row + bytesPerRow
        var x = x0
        while x <= x1 {
            let l = Double(up[x]) + Double(down[x]) + Double(row[x - 1]) + Double(row[x + 1]) - 4 * Double(row[x])
            sum += l; sumSq += l * l; n += 1
            x += step
        }
        y += step
    }
    let mean = sum / n
    return sumSq / n - mean * mean
}

extension UIImage {
    /// Laplacian variance of a small grayscale copy (for video frames and tests).
    func sharpness(width w: Int = 480) -> Double {
        guard let cg = cgImage, cg.width > 0 else { return 0 }
        let h = max(1, Int(Double(w) * Double(cg.height) / Double(cg.width)))
        var px = [UInt8](repeating: 0, count: w * h)
        return px.withUnsafeMutableBytes { buf -> Double in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return 0 }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return laplacianVariance(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), width: w, height: h,
                                     bytesPerRow: w, step: 1)
        }
    }
}
