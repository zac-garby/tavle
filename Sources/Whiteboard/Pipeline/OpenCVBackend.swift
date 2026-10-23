import UIKit

/// OpenCV implementations of the pipeline stages (pixel work in CVBridge.mm, decisions here).

struct CVRegistrar: Registering {
    /// Matching runs on copies at most this big (the fixtures, 2576 px, are matched at full size like the reference).
    var matchMaxDimension: CGFloat = 2600
    /// Below this many homography inliers, fall back to the thin-overlap similarity (and flag the join as low).
    var minHomographyInliers = 200
    /// Below this many similarity inliers, the photos are considered not to overlap.
    var minSimilarityInliers = 15

    func register(_ images: [UIImage]) throws -> RegistrationResult {
        guard !images.isEmpty else { throw PipelineError.noImages }
        // Chain left to right. If a photo doesn't match the previous one, try skipping it (with dense captures its
        // neighbours overlap each other too); otherwise report the failed pair.
        var kept = [0], pairwise: [Homography] = [], joins: [Join] = []
        var i = 1
        while i < images.count {
            let a = kept.last!
            do {
                let (h, c) = try registerPair(images[a], images[i], pair: a)
                kept.append(i); pairwise.append(h); joins.append(Join(a: a, b: i, confidence: c))
                i += 1
            } catch {
                guard i + 1 < images.count, let (h, c) = try? registerPair(images[a], images[i + 1], pair: a) else { throw error }
                kept.append(i + 1); pairwise.append(h); joins.append(Join(a: a, b: i + 1, confidence: c))
                i += 2
            }
        }
        guard let chained = chainToMiddle(pairwise) else { throw PipelineError.implausibleJoin(pair: 0) }
        var toReference = [Homography?](repeating: nil, count: images.count)
        for (k, h) in zip(kept, chained) { toReference[k] = h }
        return RegistrationResult(toReference: toReference, joins: joins)
    }

    /// Full-res homography mapping `right` into `left`'s pixels (`register_pair`), with its confidence.
    func registerPair(_ left: UIImage, _ right: UIImage, pair i: Int) throws -> (Homography, JoinConfidence) {
        guard let a = left.normalized(maxDimension: matchMaxDimension), let b = right.normalized(maxDimension: matchMaxDimension)
        else { throw PipelineError.imageConversion }
        guard let r = CVBridge.registerLeft(a, right: b, minHomographyInliers: minHomographyInliers),
              r.isHomography || r.inliers >= minSimilarityInliers
        else { throw PipelineError.noOverlap(pair: i) }
        // Matching-scale matrix -> full-res: H = Sa^-1 * h * Sb, with S mapping full-res to matching-scale pixels.
        let sa = Double(a.pixelSize.width / left.pixelSize.width), sb = Double(b.pixelSize.width / right.pixelSize.width)
        let h = Homography.scale(1 / sa, 1 / sa) * Homography(rowMajor: r.matrix.map(\.doubleValue)) * Homography.scale(sb, sb)
        guard isPlausibleJoin(h, rightSize: right.pixelSize) else { throw PipelineError.implausibleJoin(pair: i) }
        return (h, r.isHomography ? .high(inliers: r.inliers) : .low(inliers: r.inliers))
    }
}

struct CVBlender: Blending {
    /// The mosaic is scaled down if it would exceed this (memory: the blend buffers are ~12-16 bytes/pixel).
    var maxMosaicPixels: Double = 40e6
    var reduceGlare = true
    var multiBand = true

    func blend(_ allImages: [UIImage], registration reg: RegistrationResult) throws -> UIImage {
        let used = zip(allImages, reg.toReference).compactMap { img, h in h.map { (img, $0) } }
        let images = used.map(\.0)
        let (shift, size) = canvas(for: used.map(\.1), sizes: images.map(\.pixelSize))
        var hs = used.map { shift * $0.1 }
        var (w, h) = size
        let px = Double(w) * Double(h)
        if px > maxMosaicPixels {
            let s = (maxMosaicPixels / px).squareRoot()
            hs = hs.map { .scale(s, s) * $0 }
            (w, h) = (Int(Double(w) * s), Int(Double(h) * s))
        }
        guard w > 0, h > 0 else { throw PipelineError.implausibleJoin(pair: 0) }
        guard let out = CVBridge.blendImages(images, homographies: hs.map(\.nsArray), width: w, height: h,
                                             middle: images.count / 2, reduceGlare: reduceGlare, multiBand: multiBand)
        else { throw PipelineError.imageConversion }
        return out
    }
}

struct CVRectifier: Rectifying {
    var maxOutputPixels: Double = 60e6

    func findVanishingPoints(in mosaic: UIImage) throws -> VanishingPoints? {
        let raw = CVBridge.houghSegments(mosaic).map(\.doubleValue)
        let segs = stride(from: 0, to: raw.count - 3, by: 4).map { LineSegment(raw[$0], raw[$0 + 1], raw[$0 + 2], raw[$0 + 3]) }
        let vert = segs.filter { 60 < $0.angle && $0.angle < 120 }
        let hor = segs.filter { $0.angle < 30 || $0.angle > 150 }
        guard vert.count >= 4, hor.count >= 4,
              let v = ransacVanishingPoint(vert), let h = ransacVanishingPoint(hor) else { return nil }
        return VanishingPoints(vertical: CGPoint(x: v.x, y: v.y), horizontal: CGPoint(x: h.x, y: h.y))
    }

    func rectify(_ mosaic: UIImage, using vps: VanishingPoints) throws -> (image: UIImage, homography: Homography)? {
        let v = SIMD2(Double(vps.vertical.x), Double(vps.vertical.y)), h = SIMD2(Double(vps.horizontal.x), Double(vps.horizontal.y))
        guard var (hr, w, ht) = rectifyingHomography(vertical: v, horizontal: h, imageSize: mosaic.pixelSize) else { return nil }
        let px = Double(w) * Double(ht)
        if px > maxOutputPixels {
            let s = (maxOutputPixels / px).squareRoot()
            hr = .scale(s, s) * hr
            (w, ht) = (Int(Double(w) * s), Int(Double(ht) * s))
        }
        return CVBridge.warp(mosaic, homography: hr.nsArray, width: w, height: ht).map { ($0, hr) }
    }
}

struct CVCropper: Cropping {
    var maskScale = 0.25

    /// Also crop to the physical board's frame where it's visible.
    var detectFrame = true

    func cropRects(of flat: UIImage) -> (full: CGRect, tidy: CGRect) {
        let whole = CGRect(origin: .zero, size: flat.pixelSize)
        var w = 0, h = 0
        let data = CVBridge.contentMask(flat, scale: maskScale, width: &w, height: &h)
        var mask = data.map { $0 != 0 }
        guard w > 0, h > 0, let bb = boundingBox(of: mask, width: w, height: h) else { return (whole, whole) }
        let f = maskScale
        if detectFrame, let frame = boardFrameRect(flat) {
            // Only keep valid pixels inside the frame (in mask coordinates), then take the largest rectangle.
            let x0 = Int((frame.minX * f).rounded(.up)), x1 = Int((frame.maxX * f).rounded(.down))
            let y0 = Int((frame.minY * f).rounded(.up)), y1 = Int((frame.maxY * f).rounded(.down))
            for y in 0..<h { for x in 0..<w where x < x0 || x >= x1 || y < y0 || y >= y1 { mask[y * w + x] = false } }
        }
        guard let lr = largestRectangle(in: mask, width: w, height: h) else { return (whole, whole) }
        func rect(_ r: PixelRect) -> CGRect {
            let x0 = Int(Double(r.x0) / f), y0 = Int(Double(r.y0) / f), x1 = Int(Double(r.x1) / f), y1 = Int(Double(r.y1) / f)
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(whole)
        }
        return (rect(bb), rect(lr))
    }

    /// The board's frame in `flat` pixels (sides without a visible frame left open), inset slightly so the
    /// frame's edge itself isn't included. Nil if no side was found.
    func boardFrameRect(_ flat: UIImage) -> CGRect? {
        var w = 0, h = 0, s = 1.0
        let data = CVBridge.boardDistance(flat, maxWidth: 1200, width: &w, height: &h, scale: &s)
        guard w > 0, h > 0 else { return nil }
        let fr = detectBoardFrame(distance: [UInt8](data), width: w, height: h)
        guard fr != BoardFrame() else { return nil }
        let size = flat.pixelSize, inset = 0.004 * max(size.width, size.height)
        let x0 = fr.left.map { CGFloat($0) / s + inset } ?? 0, x1 = fr.right.map { CGFloat($0) / s - inset } ?? size.width
        let y0 = fr.top.map { CGFloat($0) / s + inset } ?? 0, y1 = fr.bottom.map { CGFloat($0) / s - inset } ?? size.height
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A right->left pairwise join is plausible if the right image's warped outline is a non-folded, non-mirrored
/// quad (in front of the camera) of roughly similar area.
func isPlausibleJoin(_ h: Homography, rightSize: CGSize, maxAreaRatio: Double = 4) -> Bool {
    guard h.isFinite else { return false }
    let cs = corners(of: rightSize)
    for c in cs where h.apply(SIMD3(c.x, c.y, 1)).z <= 0 { return false }
    let p = cs.map { h.apply($0) }
    var crossSigns: [Double] = [], area = 0.0
    for i in 0..<4 {
        let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
        let e1 = b - a, e2 = c - b
        crossSigns.append(e1.x * e2.y - e1.y * e2.x)
        area += a.x * b.y - b.x * a.y
    }
    guard crossSigns.allSatisfy({ $0 > 0 }) else { return false }  // TL, TR, BR, BL turns clockwise (y down)
    let ratio = abs(area / 2) / Double(rightSize.width * rightSize.height)
    return ratio > 1 / maxAreaRatio && ratio < maxAreaRatio
}

extension Homography {
    var nsArray: [NSNumber] { rowMajor.map { NSNumber(value: $0) } }
}
