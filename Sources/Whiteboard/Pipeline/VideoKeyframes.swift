import AVFoundation
import UIKit
import simd

/// "Just record a video and sweep": sample the video, track the sweep by phase correlation between consecutive
/// samples, and pick sharp frames at ~30% overlap. The result goes through the normal image pipeline (no poses).
struct VideoKeyframeExtractor {
    var sampleFPS = 8.0
    var motionSize: CGFloat = 400          // long side of the frames used for tracking
    var outputMaxDimension: CGFloat = 4096
    var selection = KeyframeSelection()

    enum ExtractError: LocalizedError {
        case unreadable, tooShort, tooFew
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read that video."
            case .tooShort: "That video is too short."
            case .tooFew: "Couldn't find enough distinct views in that video. Sweep slowly along the board."
            }
        }
    }

    func extract(from url: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> [UIImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.3 else { throw ExtractError.tooShort }

        let small = AVAssetImageGenerator(asset: asset)
        small.appliesPreferredTrackTransform = true
        small.maximumSize = CGSize(width: motionSize, height: motionSize)
        let tol = CMTime(seconds: 0.5 / sampleFPS, preferredTimescale: 600)
        small.requestedTimeToleranceBefore = tol
        small.requestedTimeToleranceAfter = tol

        let n = max(2, Int(duration * sampleFPS))
        var times: [CMTime] = [], positions: [SIMD2<Double>] = [], sharpness: [Double] = []
        var prev: UIImage?, lastShift = SIMD2<Double>.zero, frameSize = SIMD2<Double>.zero
        for k in 0..<n {
            let t = CMTime(seconds: min(duration - 0.01, Double(k) / sampleFPS), preferredTimescale: 600)
            guard let r = try? await small.image(at: t) else { continue }
            let cg = r.image, actual = r.actualTime
            let img = UIImage(cgImage: cg)
            frameSize = SIMD2(Double(cg.width), Double(cg.height))
            if let p = prev, p.pixelSize == img.pixelSize {
                var response = 0.0
                let s = CVBridge.shift(from: p, to: img, response: &response)
                // A weak peak (blur, blank board) is unreliable: assume the sweep continued at the same speed.
                lastShift = response > 0.03 ? SIMD2(Double(s.x), Double(s.y)) : lastShift
                positions.append(positions.last! + lastShift)
            } else {
                positions.append(.zero)
            }
            times.append(actual)
            sharpness.append(img.sharpness(width: cg.width))
            prev = img
            progress(0.8 * Double(k + 1) / Double(n))
        }
        guard !positions.isEmpty else { throw ExtractError.unreadable }
        let keys = selection.select(positions: positions, sharpness: sharpness, frameSize: frameSize)
        guard !keys.isEmpty else { throw ExtractError.tooFew }

        let full = AVAssetImageGenerator(asset: asset)
        full.appliesPreferredTrackTransform = true
        full.requestedTimeToleranceBefore = .zero
        full.requestedTimeToleranceAfter = .zero
        var out: [UIImage] = []
        for (i, k) in keys.enumerated() {
            let (cg, _) = try await full.image(at: times[k])
            guard let img = UIImage(cgImage: cg).normalized(maxDimension: outputMaxDimension) else { throw ExtractError.unreadable }
            out.append(img)
            progress(0.8 + 0.2 * Double(i + 1) / Double(keys.count))
        }
        return out
    }
}

/// Picks keyframe indices from a tracked sweep. Pure; unit-tested.
struct KeyframeSelection {
    /// Start looking for the next keyframe once overlap with the last one drops below this...
    var trigger = 0.40
    /// ...and choose the sharpest sample whose overlap is in this range.
    var window = 0.28...0.55
    /// Add a final keyframe if the end of the sweep overlaps the last keyframe by less than this.
    var endOverlap = 0.85

    static func overlap(_ d: SIMD2<Double>, _ size: SIMD2<Double>) -> Double {
        max(0, 1 - abs(d.x) / size.x) * max(0, 1 - abs(d.y) / size.y)
    }

    /// `positions[i]`: content offset of sample i (cumulative image shift). Returns indices ordered left -> right
    /// along the board (the sweep can go either way).
    func select(positions p: [SIMD2<Double>], sharpness: [Double], frameSize size: SIMD2<Double>) -> [Int] {
        let n = p.count
        guard n > 0, size.x > 0, size.y > 0 else { return [] }
        func ov(_ i: Int, _ j: Int) -> Double { Self.overlap(p[i] - p[j], size) }
        func sharpest(_ c: [Int]) -> Int? { c.max { sharpness[$0] < sharpness[$1] } }

        var keys = [sharpest((0..<n).filter { ov($0, 0) >= 0.85 }) ?? 0]
        var i = keys[0] + 1
        while i < n {
            let last = keys.last!
            if ov(i, last) < trigger {
                var cands: [Int] = []
                var j = last + 1
                while j < n, ov(j, last) >= window.lowerBound { if ov(j, last) <= window.upperBound { cands.append(j) }; j += 1 }
                let next = sharpest(cands) ?? max(last + 1, i - 1)
                keys.append(next)
                i = next + 1
            } else {
                i += 1
            }
        }
        if let last = keys.last, last != n - 1, ov(n - 1, last) < endOverlap {
            keys.append(sharpest((last + 1..<n).filter { ov($0, n - 1) >= 0.9 }) ?? n - 1)
        }
        // Content moving left (negative x) means the camera moved right, so time order is already left -> right.
        if keys.count > 1, p[keys.last!].x - p[keys.first!].x > 0 { keys.reverse() }
        return keys
    }
}
