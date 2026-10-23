import UIKit

/// Stages mirror reference/whiteboard_pipeline.py. Swap backends behind these protocols.
/// Images crossing these boundaries are `.up`-oriented, scale-1 UIImages; black (gray <= ~8) means "no data".

enum JoinConfidence: Equatable {
    case high(inliers: Int)   // full homography with plenty of inliers
    case low(inliers: Int)    // thin-overlap fallback (rigid similarity) — warn the user
    case tracked              // from ARKit poses only (image matching failed or disagreed) — warn the user

    var isLow: Bool { if case .high = self { false } else { true } }
    var inliers: Int { switch self { case .high(let n), .low(let n): n; case .tracked: 0 } }

    /// `a`, `b`: 0-based photo indices.
    func warning(_ a: Int, _ b: Int) -> String? {
        switch self {
        case .high: nil
        case .low(let n): "The join between photos \(a + 1) and \(b + 1) is low confidence (only \(n) matching points). Check it looks right; retake with more overlap."
        case .tracked: "Photos \(a + 1) and \(b + 1) were joined using motion tracking only (the images didn't match up). Check the join."
        }
    }
}

/// A join used to place the images: `b` (right) registered to `a` (left), a < b.
struct Join: Equatable { var a: Int, b: Int, confidence: JoinConfidence }

struct RegistrationResult {
    /// image i -> reference frame: the middle image, or (when `isFlat`) pixel coordinates on the board plane.
    /// Nil: image left out (it didn't match anything and its neighbours cover it).
    var toReference: [Homography?]
    var joins: [Join]
    /// The reference frame is already fronto-parallel (from the ARKit plane), so skip VP rectification.
    var isFlat = false

    var confidences: [JoinConfidence] { joins.map(\.confidence) }
    var dropped: [Int] { toReference.indices.filter { toReference[$0] == nil } }

    /// Consecutive images joined in order (the plain chain).
    init(toReference: [Homography], chained confidences: [JoinConfidence], isFlat: Bool = false) {
        self.init(toReference: toReference, joins: confidences.enumerated().map { Join(a: $0.offset, b: $0.offset + 1, confidence: $0.element) }, isFlat: isFlat)
    }

    init(toReference: [Homography?], joins: [Join], isFlat: Bool = false) {
        self.toReference = toReference; self.joins = joins; self.isFlat = isFlat
    }
}

enum PipelineError: LocalizedError, Equatable {
    case noImages
    case noOverlap(pair: Int)          // images pair, pair+1 (0-based)
    case implausibleJoin(pair: Int)
    case imageConversion

    var errorDescription: String? {
        switch self {
        case .noImages: "No photos to process."
        case .noOverlap(let i): "Photos \(i + 1) and \(i + 2) don't seem to overlap. Check the order, or retake with more overlap."
        case .implausibleJoin(let i): "Couldn't join photos \(i + 1) and \(i + 2) sensibly. Check the order, or retake with more overlap."
        case .imageConversion: "Couldn't read one of the photos."
        }
    }
}

protocol Registering {
    /// `images` ordered left -> right.
    func register(_ images: [UIImage]) throws -> RegistrationResult
}

protocol Blending {
    /// Skips images whose `toReference` is nil.
    func blend(_ images: [UIImage], registration: RegistrationResult) throws -> UIImage
}

struct VanishingPoints { var vertical: CGPoint; var horizontal: CGPoint }

protocol Rectifying {
    /// Nil if there aren't enough straight lines to estimate both directions.
    func findVanishingPoints(in mosaic: UIImage) throws -> VanishingPoints?
    /// The flattened image and the homography mosaic -> flattened pixels. Nil if the VPs give a degenerate warp.
    func rectify(_ mosaic: UIImage, using vps: VanishingPoints) throws -> (image: UIImage, homography: Homography)?
}

protocol Cropping {
    /// (bounding box of the valid area, largest all-valid rectangle), in `flat`'s pixel coordinates.
    func cropRects(of flat: UIImage) -> (full: CGRect, tidy: CGRect)
}

struct PipelineOutput {
    var mosaic: UIImage
    var flatFull: UIImage
    var flatCropped: UIImage
    var confidences: [JoinConfidence]
    var warnings: [String]
    /// Inputs left out of the mosaic (matched nothing; their neighbours cover them).
    var dropped: [Int] = []
    /// mosaic pixels -> flatFull pixels (for manual corner editing on the mosaic).
    var mosaicToFull: Homography
    /// Where flatCropped sits inside flatFull.
    var croppedRect: CGRect
}

enum PipelineStage: String { case preparing = "Preparing photos", registering = "Matching photos", blending = "Blending",
                                  rectifying = "Flattening", cropping = "Cropping" }

struct WhiteboardPipeline {
    var registrar: Registering
    var blender: Blending
    var rectifier: Rectifying
    var cropper: Cropping
    /// Inputs are downscaled to this before anything else (memory bound for 48 MP photos).
    var maxInputDimension: CGFloat = 4096

    static let opencv = WhiteboardPipeline(registrar: CVRegistrar(), blender: CVBlender(), rectifier: CVRectifier(), cropper: CVCropper())

    /// For a guided capture: poses + plane give the joins and the flattening; images refine the joins.
    static func capture(_ record: CaptureRecord) -> WhiteboardPipeline {
        var p = opencv
        p.registrar = PoseRegistrar(record: record)
        return p
    }

    func run(_ inputs: [UIImage], progress: (PipelineStage) -> Void = { _ in }) throws -> PipelineOutput {
        guard !inputs.isEmpty else { throw PipelineError.noImages }
        progress(.preparing)
        let images = try inputs.map { img in
            guard let n = img.normalized(maxDimension: maxInputDimension) else { throw PipelineError.imageConversion }
            return n
        }
        progress(.registering)
        let reg = try registrar.register(images)
        progress(.blending)
        let mosaic = try blender.blend(images, registration: reg)

        progress(.rectifying)
        var warnings = reg.joins.compactMap { $0.confidence.warning($0.a, $0.b) }
        var flat = mosaic, toFlat = Homography.identity
        if reg.isFlat {
            // Already in board coordinates.
        } else if let vps = try rectifier.findVanishingPoints(in: mosaic), let r = try rectifier.rectify(mosaic, using: vps) {
            (flat, toFlat) = r
        } else {
            warnings.append("Couldn't find enough straight lines to flatten the board; showing it unflattened. Use Adjust corners to fix it.")
        }
        progress(.cropping)
        let r = cropper.cropRects(of: flat)
        guard let full = flat.cropped(to: r.full), let tidy = flat.cropped(to: r.tidy) else { throw PipelineError.imageConversion }
        return PipelineOutput(mosaic: mosaic, flatFull: full, flatCropped: tidy, confidences: reg.confidences, warnings: warnings,
                              dropped: reg.dropped, mosaicToFull: .translation(-r.full.minX, -r.full.minY) * toFlat,
                              croppedRect: r.tidy.offsetBy(dx: -r.full.minX, dy: -r.full.minY))
    }
}

extension UIImage {
    /// Redraws into an 8-bit sRGB bitmap with `.up` orientation and scale 1, at most `maxDimension` on the long side.
    func normalized(maxDimension: CGFloat) -> UIImage? {
        let w = size.width * scale, h = size.height * scale  // `size` already accounts for orientation
        guard w >= 1, h >= 1 else { return nil }
        let s = min(1, maxDimension / max(w, h))
        if s == 1, imageOrientation == .up, self.scale == 1, cgImage != nil { return self }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        fmt.preferredRange = .standard
        let out = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
        return UIGraphicsImageRenderer(size: out, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: out)) }
    }

    var pixelSize: CGSize { CGSize(width: size.width * scale, height: size.height * scale) }

    /// Aspect-preserving thumbnail (`preparingThumbnail(of:)` stretches to the size given).
    func thumbnail(maxDimension m: CGFloat) -> UIImage {
        let s = min(1, m / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
        return preparingThumbnail(of: target) ?? self
    }

    /// Crop in pixel coordinates (of an `.up`, scale-1 image).
    func cropped(to r: CGRect) -> UIImage? {
        guard let cg = cgImage?.cropping(to: r.integral) else { return nil }
        return UIImage(cgImage: cg)
    }
}
