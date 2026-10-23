import UIKit
import simd

/// Registration for guided captures. Each frame's pose + the board plane give a homography straight into
/// fronto-parallel board coordinates (so no VP rectification is needed). Joins are then refined by image matching
/// (`CVRegistrar.registerPair`) when it agrees with the pose prediction. Captures overlap densely, so a photo that
/// matches neither neighbour is bridged (its neighbours are matched to each other) and left out; the pose is only
/// used for a join when there's no optical route. Without a plane, falls back to plain image registration.
struct PoseRegistrar: Registering {
    var record: CaptureRecord            // frames in the same order as the images passed to `register`
    var refiner = CVRegistrar()
    /// Image matching is accepted if it moves the overlap region by at most this fraction of the image width
    /// relative to the pose prediction (ARKit drift is ~cm; a wrong match is usually way off).
    var maxRefinementDeviation = 0.06
    /// Skip-one joins are only tried if the poses say the two photos overlap at least this much.
    var minBridgeOverlap = 0.12

    func register(_ images: [UIImage]) throws -> RegistrationResult {
        guard !images.isEmpty else { throw PipelineError.noImages }
        guard images.count == record.frames.count, let plane = record.boardPlane else { return try refiner.register(images) }
        let n = images.count
        // Cameras for the images as given (the pipeline may have downscaled them).
        let cams = zip(images, record.frames).map { img, f in f.camera.scaled(Double(img.pixelSize.width) / f.width) }
        guard let flat = FlatFrame(plane: plane, middle: cams[n / 2]) else { return try refiner.register(images) }
        let poseToFlat = try cams.map { c in
            guard let h = flat.imageToFlat(c) else { throw PipelineError.implausibleJoin(pair: 0) }
            return h
        }
        func predicted(_ a: Int, _ b: Int) -> Homography? { poseToFlat[a].inverse.map { $0 * poseToFlat[b] } }

        // Optical joins (b -> a pixels), adjacent first, then skip-one around the failures.
        var optical: [Int: [Int: (Homography, JoinConfidence)]] = [:]
        func tryJoin(_ a: Int, _ b: Int) {
            guard let p = predicted(a, b), optical[a]?[b] == nil,
                  let (h, c) = try? refiner.registerPair(images[a], images[b], pair: a),
                  agrees(h, p, rightSize: images[b].pixelSize) else { return }
            optical[a, default: [:]][b] = (h, c)
        }
        for i in 0..<(n - 1) { tryJoin(i, i + 1) }
        let outlines = poseToFlat.enumerated().map { i, h in corners(of: images[i].pixelSize).map { h.apply($0) } }
        for i in 0..<(n - 1) where optical[i]?[i + 1] == nil {
            for (a, b) in [(i - 1, i + 1), (i, i + 2)] where a >= 0 && b < n && overlapFraction(outlines[b], outlines[a]) >= minBridgeOverlap {
                tryJoin(a, b)
            }
        }
        let edges = optical.flatMap { a, bs in bs.map { b, hc in (a: a, b: b, h: hc.0, c: hc.1) } }

        // Leave out photos with no optical join whose neighbours are joined across them.
        let kept = (0..<n).filter { k in
            edges.contains { $0.a == k || $0.b == k } || !edges.contains { $0.a < k && k < $0.b }
        }
        // Pose-only joins between consecutive kept photos, used only when there's no optical route.
        var all = edges.filter { kept.contains($0.a) && kept.contains($0.b) }
        for (a, b) in zip(kept, kept.dropFirst()) where !all.contains(where: { $0.a == a && $0.b == b }) {
            if let p = predicted(a, b) { all.append((a, b, p, .tracked)) }
        }
        func cost(_ c: JoinConfidence) -> Double { switch c { case .high: 1; case .low: 4; case .tracked: 100 } }

        // Shortest-path tree from the middle kept photo (Dijkstra; n is small).
        let root = kept[kept.count / 2]
        var toRoot: [Int: Homography] = [root: .identity], dist: [Int: Double] = [root: 0], via: [Int: Join] = [:]
        var done = Set<Int>()
        while let u = dist.filter({ !done.contains($0.key) }).min(by: { $0.value < $1.value })?.key {
            done.insert(u)
            for e in all where e.a == u || e.b == u {
                let v = e.a == u ? e.b : e.a, d = dist[u]! + cost(e.c)
                guard !done.contains(v), d < dist[v] ?? .infinity else { continue }
                // e.h maps b -> a pixels.
                guard let h = e.a == u ? Optional(toRoot[u]! * e.h) : e.h.inverse.map({ toRoot[u]! * $0 }) else { continue }
                dist[v] = d; toRoot[v] = h; via[v] = Join(a: e.a, b: e.b, confidence: e.c)
            }
        }
        guard kept.allSatisfy({ toRoot[$0] != nil }) else { throw PipelineError.implausibleJoin(pair: 0) }
        let mid = poseToFlat[root]
        return RegistrationResult(toReference: (0..<n).map { toRoot[$0].map { mid * $0 } },
                                  joins: via.values.sorted { ($0.a, $0.b) < ($1.a, $1.b) }, isFlat: true)
    }

    /// Compare where both put the left third of the right image (the part that overlaps its left neighbour).
    func agrees(_ h: Homography, _ predicted: Homography, rightSize s: CGSize) -> Bool {
        let w = Double(s.width), ht = Double(s.height)
        let pts = [SIMD2(0, 0), SIMD2(w / 3, 0), SIMD2(w / 3, ht), SIMD2(0, ht), SIMD2(w / 6, ht / 2)]
        let err = pts.map { simd_length(h.apply($0) - predicted.apply($0)) }.max() ?? .infinity
        return err <= maxRefinementDeviation * w
    }
}

/// Pixel coordinates on the board: x along e1 (right), y along e2 (down), origin where the middle camera's
/// optical axis meets the board, scaled so the middle image keeps roughly its resolution there.
struct FlatFrame {
    var plane: BoardPlane
    var pixelsPerMetre: Double
    var origin: SIMD2<Double>          // in plane coordinates (metres)

    init?(plane: BoardPlane, middle c: Camera) {
        guard let X = plane.intersect(from: c.centre, dir: c.forward) else { return nil }
        self.plane = plane
        origin = plane.toPlane(X)
        pixelsPerMetre = (c.K[0][0] + c.K[1][1]) / 2 / simd_distance(X, c.centre)
    }

    /// flat pixels -> plane metres
    var flatToPlane: Homography {
        Homography(rowMajor: [1 / pixelsPerMetre, 0, origin.x, 0, 1 / pixelsPerMetre, origin.y, 0, 0, 1])
    }

    func imageToFlat(_ c: Camera) -> Homography? { (plane.planeToImage(c) * flatToPlane).inverse }
}
