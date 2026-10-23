import Foundation
import simd

/// Pure camera / plane geometry for guided capture (unit-tested; no ARKit types).
///
/// Conventions: world is ARKit's (metres, +y up, gravity-aligned). Cameras use the OpenCV convention
/// (x right, y down, z forward) so that `K * (R X + t)` gives pixel coordinates (x right, y down).

struct Camera: Equatable {
    var K: simd_double3x3              // intrinsics for an image of `size`
    var R: simd_double3x3              // world -> camera rotation
    var t: SIMD3<Double>               // world -> camera translation
    var size: SIMD2<Double>            // image width, height in pixels

    var centre: SIMD3<Double> { -(R.transpose * t) }
    /// Optical axis in world coordinates.
    var forward: SIMD3<Double> { R.transpose * SIMD3(0, 0, 1) }

    func project(_ X: SIMD3<Double>) -> SIMD2<Double>? {
        let x = K * (R * X + t)
        guard x.z > 1e-9 else { return nil }
        return SIMD2(x.x, x.y) / x.z
    }

    /// World-space ray direction through pixel `p` (not normalised).
    func ray(_ p: SIMD2<Double>) -> SIMD3<Double> { R.transpose * (K.inverse * SIMD3(p.x, p.y, 1)) }

    /// The same camera with its image scaled by `s` (e.g. after downscaling the photo).
    func scaled(_ s: Double) -> Camera {
        var c = self
        c.K = simd_double3x3(rows: [SIMD3(s, 0, 0), SIMD3(0, s, 0), SIMD3(0, 0, 1)]) * K
        c.size = size * s
        return c
    }

    /// The camera for the image rotated by 90 degrees clockwise (UIImage orientation `.right`), as a rotation of
    /// the camera frame about its optical axis so K stays upper-triangular. Pixel map: x' = H - y, y' = x.
    func rotatedClockwise() -> Camera {
        let H = size.y
        let fx = K[0][0], fy = K[1][1], s = K[1][0], cx = K[2][0], cy = K[2][1]
        let Rz = simd_double3x3(rows: [SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
        let K2 = simd_double3x3(rows: [SIMD3(fy, 0, H - cy), SIMD3(-s, fx, cx), SIMD3(0, 0, 1)])
        return Camera(K: K2, R: Rz * R, t: Rz * t, size: SIMD2(size.y, size.x))
    }

    func rotatedClockwise(quarterTurns k: Int) -> Camera {
        var c = self
        for _ in 0..<(((k % 4) + 4) % 4) { c = c.rotatedClockwise() }
        return c
    }

    /// Quarter turns clockwise that make world-up point up in the image (gravity-based, so it doesn't matter how
    /// the phone was held or what the UI orientation was).
    func uprightQuarterTurns(up: SIMD3<Double> = SIMD3(0, 1, 0)) -> Int {
        let X0 = centre + forward, X1 = X0 + 0.1 * up
        guard let p0 = project(X0), let p1 = project(X1) else { return 0 }
        var d = p1 - p0, best = (k: 0, score: -Double.infinity)
        for k in 0..<4 {
            let score = simd_dot(simd_normalize(d), SIMD2(0, -1))
            if score > best.score { best = (k, score) }
            d = SIMD2(-d.y, d.x)  // one clockwise quarter turn in image coordinates (y down)
        }
        return best.k
    }
}

extension Camera {
    /// From ARKit: `cameraToWorld` is `ARCamera.transform` (camera x right, y up, z backwards, sensor orientation),
    /// `intrinsics` is `ARCamera.intrinsics` (column-major) for an image of `imageSize`.
    init(arIntrinsics k: simd_float3x3, cameraToWorld T: simd_float4x4, imageSize: SIMD2<Double>) {
        let Kd = simd_double3x3(columns: (SIMD3<Double>(k.columns.0), SIMD3<Double>(k.columns.1), SIMD3<Double>(k.columns.2)))
        let Td = simd_double4x4(columns: (SIMD4<Double>(T.columns.0), SIMD4<Double>(T.columns.1),
                                          SIMD4<Double>(T.columns.2), SIMD4<Double>(T.columns.3)))
        let w2c = Td.inverse
        let flip = simd_double3x3(diagonal: SIMD3(1, -1, -1))  // ARKit camera -> OpenCV camera
        let Rar = simd_double3x3(columns: (SIMD3(w2c.columns.0.x, w2c.columns.0.y, w2c.columns.0.z),
                                           SIMD3(w2c.columns.1.x, w2c.columns.1.y, w2c.columns.1.z),
                                           SIMD3(w2c.columns.2.x, w2c.columns.2.y, w2c.columns.2.z)))
        let tar = SIMD3(w2c.columns.3.x, w2c.columns.3.y, w2c.columns.3.z)
        self.init(K: Kd, R: flip * Rar, t: flip * tar, size: imageSize)
    }
}

// MARK: - Plane

/// A plane with an in-plane frame: e1 points right along the board (horizontal), e2 points down (along gravity,
/// projected onto the plane), normal towards the viewer.
struct BoardPlane: Equatable {
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>
    var e1: SIMD3<Double>
    var e2: SIMD3<Double>

    /// `normal` is flipped if needed to face `viewer`. Nil if the plane is too close to horizontal to have a "right".
    init?(origin: SIMD3<Double>, normal n0: SIMD3<Double>, facing viewer: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 1, 0)) {
        var n = simd_normalize(n0)
        if simd_dot(n, viewer - origin) < 0 { n = -n }
        let right = simd_cross(-n, up)
        guard simd_length(right) > 0.2 else { return nil }
        self.origin = origin
        normal = n
        e1 = simd_normalize(right)
        e2 = simd_cross(e1, n)
    }

    func toPlane(_ X: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(X - origin, e1), simd_dot(X - origin, e2)) }
    func toWorld(_ p: SIMD2<Double>) -> SIMD3<Double> { origin + p.x * e1 + p.y * e2 }

    /// Ray from `from` along `dir` hits the plane at parameter t > 0 (nil if parallel / behind / beyond `maxDistance`).
    func intersect(from c: SIMD3<Double>, dir: SIMD3<Double>, maxDistance: Double = 10) -> SIMD3<Double>? {
        let denom = simd_dot(normal, dir)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(normal, origin - c) / denom
        guard t > 0, t * simd_length(dir) < maxDistance else { return nil }
        return c + t * dir
    }

    /// Camera's image outline on the plane, in plane coordinates (TL, TR, BR, BL). Nil if any corner misses.
    func footprint(of cam: Camera) -> [SIMD2<Double>]? {
        let w = cam.size.x, h = cam.size.y
        var out: [SIMD2<Double>] = []
        for p in [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)] {
            guard let X = intersect(from: cam.centre, dir: cam.ray(p)) else { return nil }
            out.append(toPlane(X))
        }
        return out
    }

    /// Angle (degrees) between the optical axis and the board normal (0 = facing it squarely).
    func viewAngle(of cam: Camera) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(cam.forward), -normal)))) * 180 / .pi
    }

    /// Homography taking plane coordinates (metres, in this frame) to `cam`'s pixels: K [R e1 | R e2 | R o + t].
    func planeToImage(_ cam: Camera) -> Homography {
        let c0 = cam.R * e1, c1 = cam.R * e2, c2 = cam.R * origin + cam.t
        return Homography(cam.K * simd_double3x3(columns: (c0, c1, c2)))
    }
}

/// Plane-induced homography H mapping camera a's pixels to camera b's, for the plane nᵀX = d (world):
/// H = K_b (R + t n_aᵀ / d_a) K_a⁻¹ with (R, t) the relative pose a -> b and (n_a, d_a) the plane in a's frame.
/// (PLAN.md writes R − t nᵀ/d for the nᵀX + d = 0 convention; same thing.)
func planeInducedHomography(from a: Camera, to b: Camera, plane: BoardPlane) -> Homography {
    let R = b.R * a.R.transpose
    let t = b.t - R * a.t
    let na = a.R * plane.normal
    let da = simd_dot(plane.normal, plane.origin) + simd_dot(na, a.t)
    let M = R + simd_double3x3(columns: (t * na.x, t * na.y, t * na.z)) * (1 / da)
    return Homography(b.K * M * a.K.inverse)
}

// MARK: - Polygons

func polygonArea(_ p: [SIMD2<Double>]) -> Double {
    guard p.count >= 3 else { return 0 }
    var a = 0.0
    for i in p.indices { let q = p[i], r = p[(i + 1) % p.count]; a += q.x * r.y - r.x * q.y }
    return abs(a) / 2
}

/// Intersection of two convex polygons (Sutherland–Hodgman). Either winding.
func convexIntersection(_ subject: [SIMD2<Double>], _ clip: [SIMD2<Double>]) -> [SIMD2<Double>] {
    guard subject.count >= 3, clip.count >= 3 else { return [] }
    // Orient the clip polygon counter-clockwise (in the maths sense) so "inside" is the left side of each edge.
    var signed = 0.0
    for i in clip.indices { let q = clip[i], r = clip[(i + 1) % clip.count]; signed += q.x * r.y - r.x * q.y }
    let c = signed >= 0 ? clip : clip.reversed()
    func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ p: SIMD2<Double>) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
    var out = subject
    for i in c.indices {
        let a = c[i], b = c[(i + 1) % c.count]
        let input = out
        out = []
        guard !input.isEmpty else { break }
        for j in input.indices {
            let p = input[j], q = input[(j + 1) % input.count]
            let pin = cross(a, b, p) >= 0, qin = cross(a, b, q) >= 0
            if pin { out.append(p) }
            if pin != qin {
                let cp = cross(a, b, p), cq = cross(a, b, q)
                out.append(p + (q - p) * (cp / (cp - cq)))
            }
        }
    }
    return out
}

/// Fraction of `a`'s area that is also covered by `b`.
func overlapFraction(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Double {
    let area = polygonArea(a)
    return area > 0 ? polygonArea(convexIntersection(a, b)) / area : 0
}
