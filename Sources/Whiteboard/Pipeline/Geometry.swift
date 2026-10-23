import CoreGraphics
import Foundation
import simd

/// Pure geometry used by the pipeline (backend-independent, unit-tested).
/// Conventions match reference/whiteboard_pipeline.py: points are (x, y), matrices act on column vectors (x, y, 1).

// MARK: - Homography

struct Homography: Equatable {
    var matrix: simd_double3x3

    init(_ matrix: simd_double3x3) { self.matrix = matrix }

    init(rowMajor m: [Double]) {
        precondition(m.count == 9)
        matrix = simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
    }

    var rowMajor: [Double] {
        let t = matrix.transpose  // columns of the transpose are the rows
        return [t.columns.0, t.columns.1, t.columns.2].flatMap { [$0.x, $0.y, $0.z] }
    }

    static let identity = Homography(matrix_identity_double3x3)
    static func translation(_ dx: Double, _ dy: Double) -> Homography { Homography(rowMajor: [1, 0, dx, 0, 1, dy, 0, 0, 1]) }
    static func scale(_ sx: Double, _ sy: Double) -> Homography { Homography(rowMajor: [sx, 0, 0, 0, sy, 0, 0, 0, 1]) }

    /// `(a * b)` applies `b` first.
    static func * (a: Homography, b: Homography) -> Homography { Homography(a.matrix * b.matrix) }

    var inverse: Homography? {
        let d = matrix.determinant
        guard d.isFinite, abs(d) > 1e-12 else { return nil }
        return Homography(matrix.inverse)
    }

    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> { matrix * v }

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let q = matrix * SIMD3(p.x, p.y, 1)
        return SIMD2(q.x, q.y) / q.z
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let q = apply(SIMD2(Double(p.x), Double(p.y)))
        return CGPoint(x: q.x, y: q.y)
    }

    var isFinite: Bool { rowMajor.allSatisfy(\.isFinite) }
}

func corners(of size: CGSize) -> [SIMD2<Double>] {
    let w = Double(size.width), h = Double(size.height)
    return [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]
}

/// Bounding canvas for images warped by `homographies`: returns the translation that moves the
/// top-left of the union to (0, 0) and the integer canvas size (truncated, as in the reference).
func canvas(for homographies: [Homography], sizes: [CGSize]) -> (shift: Homography, size: (width: Int, height: Int)) {
    var mn = SIMD2(Double.infinity, .infinity), mx = SIMD2(-Double.infinity, -.infinity)
    for (h, s) in zip(homographies, sizes) {
        for c in corners(of: s) {
            let p = h.apply(c)
            mn = simd_min(mn, p); mx = simd_max(mx, p)
        }
    }
    return (.translation(-mn.x, -mn.y), (Int(mx.x - mn.x), Int(mx.y - mn.y)))
}

/// Chains pairwise registrations into "image i -> middle image" homographies.
/// `pairwise[i]` maps image i+1 into image i (right -> left), as returned by the registrar.
func chainToMiddle(_ pairwise: [Homography]) -> [Homography]? {
    let n = pairwise.count + 1, mid = n / 2
    var hs = [Homography](repeating: .identity, count: n)
    if mid > 0 {
        for i in stride(from: mid - 1, through: 0, by: -1) {
            guard let inv = pairwise[i].inverse else { return nil }
            hs[i] = hs[i + 1] * inv
        }
    }
    if mid + 1 < n {
        for i in (mid + 1)..<n { hs[i] = hs[i - 1] * pairwise[i - 1] }
    }
    return hs
}

// MARK: - Vanishing points

struct LineSegment {
    var p: SIMD2<Double>, q: SIMD2<Double>
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { p = SIMD2(x1, y1); q = SIMD2(x2, y2) }

    var length: Double { simd_length(q - p) }
    var midpoint: SIMD2<Double> { (p + q) / 2 }
    var direction: SIMD2<Double> { simd_normalize(q - p) }
    /// Homogeneous line through both endpoints.
    var line: SIMD3<Double> { simd_cross(SIMD3(p.x, p.y, 1), SIMD3(q.x, q.y, 1)) }
    /// Orientation in degrees, in [0, 180).
    var angle: Double {
        let a = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
        return a < 0 ? a + 180 : (a >= 180 ? a - 180 : a)
    }
}

/// Intersection of two homogeneous lines as a finite point. Parallel lines give a far-away point
/// along their common direction (like the reference's `v[:2] * 1e9`).
func intersect(_ l1: SIMD3<Double>, _ l2: SIMD3<Double>) -> SIMD2<Double> {
    let v = simd_cross(l1, l2)
    return abs(v.z) > 1e-9 ? SIMD2(v.x, v.y) / v.z : SIMD2(v.x, v.y) * 1e9
}

/// Small deterministic PRNG so RANSAC is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// RANSAC vanishing point: pick two segments, intersect, score by the total length of segments whose
/// direction points at the candidate within `tolerance` degrees. Port of `_ransac_vp`.
func ransacVanishingPoint(_ segs: [LineSegment], tolerance: Double = 0.6, iterations: Int = 4000, seed: UInt64 = 1) -> SIMD2<Double>? {
    guard segs.count >= 2 else { return nil }
    let lines = segs.map(\.line), lens = segs.map(\.length), mids = segs.map(\.midpoint), dirs = segs.map(\.direction)
    let cosTol = cos(tolerance * .pi / 180)
    var rng = SplitMix64(seed: seed)
    var best: (vp: SIMD2<Double>, score: Double)?
    for _ in 0..<iterations {
        let i = Int.random(in: 0..<segs.count, using: &rng)
        var j = Int.random(in: 0..<(segs.count - 1), using: &rng)
        if j >= i { j += 1 }
        let vp = intersect(lines[i], lines[j])
        var score = 0.0
        for k in 0..<segs.count {
            let d = vp - mids[k], n = simd_length(d)
            guard n > 1e-9 else { continue }
            if abs(simd_dot(d / n, dirs[k])) > cosTol { score += lens[k] }  // angle < tol  <=>  |cos| > cos(tol)
        }
        if score > (best?.score ?? 0) { best = (vp, score) }
    }
    return best?.vp
}

// MARK: - Rectification

/// Homography that sends the horizon (line through both VPs) to infinity, makes the two VP directions
/// axis-aligned and keeps the image centre at its original scale; plus the translation into a canvas
/// holding the whole warped image. Port of `rectify` (minus the warp). Returns nil if the result is
/// degenerate (horizon crosses the image, non-finite, or the output would be absurdly large).
func rectifyingHomography(vertical v: SIMD2<Double>, horizontal h: SIMD2<Double>, imageSize: CGSize,
                          maxGrowth: Double = 4) -> (homography: Homography, width: Int, height: Int)? {
    let W = Double(imageSize.width), H = Double(imageSize.height)
    let c = SIMD2(W / 2, H / 2)
    let tc = Homography.translation(-c.x, -c.y)
    let vc = tc.apply(SIMD3(v.x, v.y, 1)), hc = tc.apply(SIMD3(h.x, h.y, 1))
    var l = simd_cross(vc, hc)
    let ln = simd_length(SIMD2(l.x, l.y))
    guard ln > 0, ln.isFinite else { return nil }
    l /= ln
    // Orient the horizon so the centre (origin after `tc`) has w > 0; otherwise the warp is the intended one
    // rotated by 180 degrees. (The Python reference has this latent bug; its fixture happens to have w > 0.)
    if l.z < 0 { l = -l }
    let h1 = Homography(rowMajor: [1, 0, 0, 0, 1, 0, l.x, l.y, l.z])

    func direction(_ p: SIMD3<Double>, _ ref: SIMD2<Double>) -> SIMD2<Double> {
        let q3 = h1.apply(p)
        let q = simd_normalize(SIMD2(q3.x, q3.y))
        return simd_dot(q, ref) > 0 ? q : -q
    }
    let dh = direction(hc, SIMD2(1, 0)), dv = direction(vc, SIMD2(0, 1))
    let basis = simd_double2x2(columns: (dh, dv))
    guard abs(basis.determinant) > 1e-6 else { return nil }
    let ai = basis.inverse
    let a = Homography(rowMajor: [ai[0][0], ai[1][0], 0, ai[0][1], ai[1][1], 0, 0, 0, 1])
    var hr = a * h1 * tc

    let p0 = hr.apply(c), jx = hr.apply(c + SIMD2(1, 0)) - p0, jy = hr.apply(c + SIMD2(0, 1)) - p0
    guard abs(jx.x) > 1e-12, abs(jy.y) > 1e-12 else { return nil }
    hr = Homography.scale(1 / abs(jx.x), 1 / abs(jy.y)) * hr

    // All corners must stay on the same side of the horizon as the centre, or the warp folds over.
    let wc = hr.apply(SIMD3(c.x, c.y, 1)).z
    for p in corners(of: imageSize) where hr.apply(SIMD3(p.x, p.y, 1)).z * wc <= 0 { return nil }

    let (shift, size) = canvas(for: [hr], sizes: [imageSize])
    guard hr.isFinite, size.width > 0, size.height > 0,
          Double(size.width) <= W * maxGrowth, Double(size.height) <= H * maxGrowth else { return nil }
    return (shift * hr, size.width, size.height)
}

// MARK: - Masks and rectangles

struct PixelRect: Equatable { var x0, y0, x1, y1: Int }  // half-open

/// Largest axis-aligned rectangle of `true` cells (row-major `mask`, `width` columns), via the
/// histogram/stack method. Port of `largest_rect`. Returns nil if the mask is all false.
func largestRectangle(in mask: [Bool], width w: Int, height h: Int) -> PixelRect? {
    precondition(mask.count == w * h)
    var hs = [Int](repeating: 0, count: w)
    var best: (area: Int, rect: PixelRect)?
    var stack: [(start: Int, height: Int)] = []
    stack.reserveCapacity(w + 1)
    for y in 0..<h {
        let row = y * w
        for x in 0..<w { hs[x] = mask[row + x] ? hs[x] + 1 : 0 }
        stack.removeAll(keepingCapacity: true)
        for x in 0...w {
            let cur = x < w ? hs[x] : 0
            var start = x
            while let top = stack.last, top.height >= cur {
                stack.removeLast()
                let area = top.height * (x - top.start)
                if area > (best?.area ?? 0) { best = (area, PixelRect(x0: top.start, y0: y - top.height + 1, x1: x, y1: y + 1)) }
                start = top.start
            }
            stack.append((start, cur))
        }
    }
    return best?.rect
}

/// Bounding box of the `true` cells. Nil if none.
func boundingBox(of mask: [Bool], width w: Int, height h: Int) -> PixelRect? {
    var r: PixelRect?
    for y in 0..<h {
        for x in 0..<w where mask[y * w + x] {
            if var b = r {
                b.x0 = min(b.x0, x); b.y0 = min(b.y0, y); b.x1 = max(b.x1, x + 1); b.y1 = max(b.y1, y + 1); r = b
            } else {
                r = PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)
            }
        }
    }
    return r
}

// MARK: - Quads (manual corners)

/// Homography mapping the 4 points `src` to `dst` (DLT with h33 = 1). Nil if degenerate (3 collinear points).
func homography(from src: [SIMD2<Double>], to dst: [SIMD2<Double>]) -> Homography? {
    precondition(src.count == 4 && dst.count == 4)
    // Rows of A h = b for h = (h11 h12 h13 h21 h22 h23 h31 h32).
    var a = [[Double]](), b = [Double]()
    for (p, q) in zip(src, dst) {
        a.append([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y]); b.append(q.x)
        a.append([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y]); b.append(q.y)
    }
    // Gaussian elimination with partial pivoting.
    for c in 0..<8 {
        guard let piv = (c..<8).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 else { return nil }
        a.swapAt(c, piv); b.swapAt(c, piv)
        for r in 0..<8 where r != c {
            let f = a[r][c] / a[c][c]
            if f == 0 { continue }
            for k in c..<8 { a[r][k] -= f * a[c][k] }
            b[r] -= f * b[c]
        }
    }
    let h = (0..<8).map { b[$0] / a[$0][$0] }
    let H = Homography(rowMajor: h + [1])
    return H.isFinite ? H : nil
}

/// Output size for flattening the quad (TL, TR, BR, BL): the longer of each pair of opposite edges.
func rectifiedSize(of q: [SIMD2<Double>]) -> (width: Int, height: Int) {
    let w = max(simd_distance(q[0], q[1]), simd_distance(q[3], q[2]))
    let h = max(simd_distance(q[0], q[3]), simd_distance(q[1], q[2]))
    return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
}

/// Convex, clockwise-in-image-coordinates (TL, TR, BR, BL) quad?
func isConvexQuad(_ q: [SIMD2<Double>]) -> Bool {
    guard q.count == 4 else { return false }
    return (0..<4).allSatisfy { i in
        let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
        let e1 = b - a, e2 = c - b
        return e1.x * e2.y - e1.y * e2.x > 0
    }
}

// MARK: - Board frame

/// Where the physical board's frame is, in the coordinates of a board-distance map (see CVBridge.boardDistance):
/// the first board-surface pixel on each side. Nil for a side where no frame is visible.
struct BoardFrame: Equatable { var left, right, top, bottom: Int? }

/// Finds each side's frame as a sharp step in the median board-distance profile (columns over the central rows
/// for left/right, rows over the central columns for top/bottom): board on the inside, and a solid band of
/// not-board just outside — every pixel of it, so a thin hand-drawn divider (board on both sides of a 1–3 px
/// line) doesn't count, while the frame (a band ≥ ~1 cm) does. Steps next to "no photo" are photo boundaries,
/// not frames. Searches the outer `searchFraction` of each side; takes the strongest step.
func detectBoardFrame(distance d: [UInt8], width w: Int, height h: Int,
                      boardTolerance: Double = 22, minStep: Double = 22, searchFraction: Double = 0.4) -> BoardFrame {
    precondition(d.count == w * h)
    guard w > 40, h > 40 else { return BoardFrame() }
    let (colProfile, rowProfile) = boardProfiles(distance: d, width: w, height: h)

    /// Index of the first board pixel after the strongest qualifying step, scanning from p's start.
    func edge(_ p: [Double]) -> Int? {
        let n = p.count, inner = max(4, n / 150), band = max(3, n / 300)
        // "Board" relative to this side's own level (one side of the board can be in shade).
        let side = p[(n / 10)..<(n / 2)].filter { $0 < 255 }.sorted()
        let tolerance = max(boardTolerance, side.isEmpty ? 0 : side[side.count / 2] + 30)
        var best: (x: Int, step: Double)?
        for x in band..<Int(Double(n) * searchFraction) where x + inner <= n {
            let inMean = p[x..<(x + inner)].sorted()[inner / 2]   // median: robust to the blurred transition pixel
            let out = p[(x - band)..<x]
            guard inMean <= tolerance, !out.contains(255), let outMin = out.min(), outMin - inMean >= minStep else { continue }
            let step = out.reduce(0, +) / Double(band) - inMean
            if step > (best?.step ?? 0) { best = (x, step) }
        }
        return best?.x
    }
    return BoardFrame(left: edge(colProfile), right: edge(colProfile.reversed()).map { w - $0 },
                      top: edge(rowProfile), bottom: edge(rowProfile.reversed()).map { h - $0 })
}

/// Median board distance per column (over the central rows) and per row (over the central columns).
func boardProfiles(distance d: [UInt8], width w: Int, height h: Int) -> (columns: [Double], rows: [Double]) {
    /// Median of the valid (non-255) values along a line; 255 if under 30% valid.
    func median(_ values: (Int) -> UInt8, count n: Int) -> Double {
        var hist = [Int](repeating: 0, count: 256), valid = 0
        for i in 0..<n { let v = Int(values(i)); hist[v] += 1; if v != 255 { valid += 1 } }
        guard valid * 10 >= n * 3 else { return 255 }
        var acc = 0
        for v in 0..<255 { acc += hist[v]; if acc * 2 >= valid { return Double(v) } }
        return 254
    }
    let rows = (h / 4)..<(3 * h / 4), cols = (w / 4)..<(3 * w / 4)
    let colProfile = (0..<w).map { x in median({ d[(rows.lowerBound + $0) * w + x] }, count: rows.count) }
    let rowProfile = (0..<h).map { y in median({ d[y * w + cols.lowerBound + $0] }, count: cols.count) }
    return (colProfile, rowProfile)
}
