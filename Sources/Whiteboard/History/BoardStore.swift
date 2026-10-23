import Observation
import UIKit
import simd

/// One whiteboard in the history. Everything lives in Documents/Boards/<id>/:
///   board.json, the source photos (left -> right as listed in `photos`), capture.json (guided scans),
///   mosaic.jpg (unflattened, for corner editing), full.jpg, cropped.jpg, thumb.jpg (small board crop),
///   cover-*.jpg (home picture in the board's look), enhanced caches.
struct Board: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case photos, video, scan }
    enum Status: Codable, Hashable { case draft, done, failed(String) }
    /// Which crop to show: the board (auto crop to its frame, or manual corners), just the writing on it, or
    /// everything that was photographed.
    enum Framing: String, Codable, CaseIterable, Identifiable {
        case board, content, full
        var id: String { rawValue }
        var file: String { switch self { case .board: "cropped"; case .content: "content"; case .full: "full" } }
    }

    enum Enhancement: Int, Codable, CaseIterable, Identifiable {
        case original, whiten, scan
        var id: Int { rawValue }
        var label: String { switch self { case .original: "Original"; case .whiten: "Whiten"; case .scan: "B&W" } }
    }

    var id = UUID()
    var created = Date.now
    var title: String
    var source: Source
    var photos: [String] = []
    var status: Status = .draft
    var warnings: [String] = []
    var mosaicToFull: [Double]?          // 3x3 row-major
    var croppedRect: [Double]?           // x, y, w, h inside full.jpg
    var corners: [[Double]]?             // manual quad on the mosaic (TL, TR, BR, BL); overrides cropped.jpg
    var framing: Framing = .board
    var enhancement: Enhancement = .original
    var trims: [String: [Double]] = [:]  // framing -> user's crop inside that framing's image, unit x, y, w, h
    var leftOut: [String]?               // photos the last flatten didn't use

    static let wholeImage = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The user's crop inside `f`'s image, in unit coordinates (the whole image if they haven't cropped it).
    func trim(_ f: Framing) -> CGRect {
        guard let t = trims[f.rawValue], t.count == 4 else { return Self.wholeImage }
        return CGRect(x: t[0], y: t[1], width: t[2], height: t[3])
    }

    var usedPhotoCount: Int { photos.count - (leftOut?.count ?? 0) }

    var isDone: Bool { status == .done }
    var failure: String? { if case .failed(let m) = status { m } else { nil } }

    /// The date is shown next to the title everywhere, so it isn't repeated in it.
    static func defaultTitle(_ source: Source) -> String {
        switch source { case .photos: "Imported photos"; case .video: "From video"; case .scan: "Scan" }
    }
}

extension Board {
    /// Fields added after the first release may be missing from older board.json files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decode(Source.self, forKey: .source)
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .draft
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        mosaicToFull = try c.decodeIfPresent([Double].self, forKey: .mosaicToFull)
        croppedRect = try c.decodeIfPresent([Double].self, forKey: .croppedRect)
        corners = try c.decodeIfPresent([[Double]].self, forKey: .corners)
        framing = try c.decodeIfPresent(Framing.self, forKey: .framing) ?? .board
        enhancement = try c.decodeIfPresent(Enhancement.self, forKey: .enhancement) ?? .original
        trims = try c.decodeIfPresent([String: [Double]].self, forKey: .trims) ?? [:]
        leftOut = try c.decodeIfPresent([String].self, forKey: .leftOut)
    }
}

extension UIImage {
    /// `unit` (0...1 coordinates) of an `.up`, scale-1 image; itself for the whole image.
    func trimmed(_ unit: CGRect) -> UIImage {
        guard unit != Board.wholeImage else { return self }
        let s = pixelSize
        return cropped(to: CGRect(x: unit.minX * s.width, y: unit.minY * s.height, width: unit.width * s.width, height: unit.height * s.height)) ?? self
    }
}

@Observable
final class BoardStore {
    private(set) var boards: [Board] = []          // newest first
    private(set) var progress: [UUID: String] = [:] // boards being processed -> stage
    @ObservationIgnored private var thumbCache: [URL: UIImage] = [:]
    @ObservationIgnored private var rendering: [URL: Task<UIImage?, Never>] = [:]
    @ObservationIgnored let root: URL
    @ObservationIgnored let defaults: UserDefaults

    static let photoMaxDimension: CGFloat = 4096
    /// Home cards are full width, so ~1100 px on a 3x phone.
    static let listThumbnailSize: CGFloat = 1200

    init(root: URL = URL.documentsDirectory.appendingPathComponent("Boards"), defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        importLegacyCaptures()
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        boards = dirs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("board.json"))).flatMap { try? JSONDecoder().decode(Board.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    func board(_ id: UUID) -> Board? { boards.first { $0.id == id } }
    func dir(_ b: Board) -> URL { root.appendingPathComponent(b.id.uuidString) }
    func file(_ b: Board, _ name: String) -> URL { dir(b).appendingPathComponent(name) }

    func save(_ b: Board) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(b).write(to: file(b, "board.json"))
        if let i = boards.firstIndex(where: { $0.id == b.id }) { boards[i] = b } else { boards.insert(b, at: 0) }
    }

    func delete(_ b: Board) {
        try? FileManager.default.removeItem(at: dir(b))
        boards.removeAll { $0.id == b.id }
    }

    // MARK: creating

    func create(images: [UIImage], source: Board.Source) throws -> Board {
        var b = Board(title: Board.defaultTitle(source), source: source)
        applyLastLook(&b)
        try FileManager.default.createDirectory(at: dir(b), withIntermediateDirectories: true)
        b.photos = try images.map { try writePhoto($0, to: b) }
        save(b)
        return b
    }

    /// A finished guided scan (directory with capture.json + frames). Moved into the history unless `copy`.
    func create(scan src: URL, copy: Bool = false, date: Date = .now) throws -> Board {
        let (rec, _) = try CaptureRecord.load(from: src)     // validates, and gives left -> right order
        var b = Board(created: date, title: Board.defaultTitle(.scan), source: .scan)
        applyLastLook(&b)
        if copy { try FileManager.default.copyItem(at: src, to: dir(b)) } else { try FileManager.default.moveItem(at: src, to: dir(b)) }
        b.photos = rec.frames.map(\.file)
        save(b)
        return b
    }

    /// Scans saved before the history existed (Documents/Captures/*) become draft boards.
    private func importLegacyCaptures() {
        let legacy = URL.documentsDirectory.appendingPathComponent("Captures")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for d in dirs where FileManager.default.fileExists(atPath: d.appendingPathComponent(CaptureRecord.fileName).path) {
            let date = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            _ = try? create(scan: d, date: date)
        }
        boards.sort { $0.created > $1.created }
    }

    private func writePhoto(_ img: UIImage, to b: Board) throws -> String {
        guard let n = img.normalized(maxDimension: Self.photoMaxDimension), let data = n.jpegData(compressionQuality: 0.92)
        else { throw PipelineError.imageConversion }
        let name = "photo_\(UUID().uuidString.prefix(8)).jpg"
        try data.write(to: file(b, name))
        return name
    }

    // MARK: look

    private static let framingKey = "WBLastFraming", enhancementKey = "WBLastEnhancement"

    /// New boards start in the framing and look last picked on any board.
    private func applyLastLook(_ b: inout Board) {
        if let f = defaults.string(forKey: Self.framingKey).flatMap(Board.Framing.init) { b.framing = f }
        if let e = defaults.object(forKey: Self.enhancementKey) as? Int, let e = Board.Enhancement(rawValue: e) { b.enhancement = e }
    }

    func setFraming(_ b: Board, _ f: Board.Framing) { var b = b; b.framing = f; saveLook(b) }
    func setEnhancement(_ b: Board, _ e: Board.Enhancement) { var b = b; b.enhancement = e; saveLook(b) }

    /// `unit` is the crop inside `f`'s image in 0...1 coordinates (the whole image clears it).
    func setTrim(_ b: Board, _ f: Board.Framing, _ unit: CGRect) {
        var b = b
        let r = unit.intersection(Board.wholeImage)
        let whole = abs(r.minX) + abs(r.minY) + abs(1 - r.width) + abs(1 - r.height) < 1e-3
        b.trims[f.rawValue] = whole ? nil : [r.minX, r.minY, r.width, r.height]
        save(b)
    }

    private func saveLook(_ b: Board) {
        defaults.set(b.framing.rawValue, forKey: Self.framingKey)
        defaults.set(b.enhancement.rawValue, forKey: Self.enhancementKey)
        save(b)
    }

    // MARK: editing photos

    func movePhotos(_ b: Board, from: IndexSet, to: Int) {
        var b = b; b.photos.move(fromOffsets: from, toOffset: to); markEdited(&b)
    }

    func removePhotos(_ b: Board, at offsets: IndexSet) {
        var b = b
        for i in offsets { try? FileManager.default.removeItem(at: file(b, b.photos[i])) }
        b.photos.remove(atOffsets: offsets)
        markEdited(&b)
    }

    func addPhotos(_ b: Board, _ images: [UIImage]) throws {
        var b = b
        b.photos += try images.map { try writePhoto($0, to: b) }
        markEdited(&b)
    }

    func reversePhotos(_ b: Board) { var b = b; b.photos.reverse(); markEdited(&b) }

    private func markEdited(_ b: inout Board) {
        if b.status != .draft { b.status = .draft }
        b.leftOut = nil
        save(b)
    }

    func rename(_ b: Board, _ title: String) { var b = b; b.title = title; save(b) }

    // MARK: images

    func photo(_ b: Board, _ name: String) -> UIImage? { UIImage(contentsOfFile: file(b, name).path) }

    func thumbnail(_ url: URL, size: CGFloat = 192) -> UIImage? {
        if let t = thumbCache[url] { return t }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let t = img.thumbnail(maxDimension: size)
        thumbCache[url] = t
        return t
    }

    /// Board crop (or the first photo, before flattening): instant stand-in for `cover`.
    func listThumbnail(_ b: Board) -> UIImage? {
        let t = file(b, "thumb.jpg")
        if b.isDone, FileManager.default.fileExists(atPath: t.path) { return thumbnail(t, size: Self.listThumbnailSize) }
        return b.photos.first.flatMap { thumbnail(file(b, $0), size: Self.listThumbnailSize) }
    }

    /// The home picture of a flattened board: framed, cropped and enhanced as the user left it.
    /// Cached per look as cover-<look>.jpg, so a stale render can never be mistaken for the current one.
    func cover(_ b: Board) async -> UIImage? {
        guard b.isDone else { return listThumbnail(b) }
        let url = coverURL(b)
        if let t = thumbnail(url, size: Self.listThumbnailSize) { return t }
        guard let img = await result(b, framing: b.framing, enhancement: b.enhancement) else { return listThumbnail(b) }
        let trim = b.trim(b.framing)
        let t = await Task.detached(priority: .utility) {
            let t = img.trimmed(trim).thumbnail(maxDimension: Self.listThumbnailSize)
            try? t.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
            return t
        }.value
        thumbCache[url] = t
        return t
    }

    /// The cover if it's already in memory (no disk access; for the first frame of a card).
    func cachedCover(_ b: Board) -> UIImage? { b.isDone ? thumbCache[coverURL(b)] : nil }

    private func coverURL(_ b: Board) -> URL {
        let t = b.trim(b.framing)
        let trim = t == Board.wholeImage ? "all" : [t.minX, t.minY, t.width, t.height].map { String(Int(($0 * 10_000).rounded())) }.joined(separator: "_")
        return file(b, "cover-\(b.framing.rawValue)-e\(b.enhancement.rawValue)-\(trim).jpg")
    }

    /// Drops in-memory renders of `b` (its images on disk were just replaced).
    private func forgetRenders(_ b: Board) {
        let d = dir(b).path
        for url in thumbCache.keys where url.deletingLastPathComponent().path == d { thumbCache[url] = nil }
    }

    /// Margin around the writing for `.content`, as a fraction of the board's long side.
    static let contentMargin = 0.025

    /// Result image with the board's enhancement, before the user's trim. `.content` is cut from the board crop
    /// on first use; it and the enhanced versions are cached on disk (cleared whenever the board crop changes).
    /// Concurrent requests for the same image (board screen + home card) share one render.
    func result(_ b: Board, framing: Board.Framing, enhancement: Board.Enhancement) async -> UIImage? {
        let cached = file(b, framing.file + "_e\(enhancement.rawValue).jpg")
        if let t = rendering[cached] { return await t.value }
        let t = render(b, framing: framing, enhancement: enhancement, cached: cached)
        rendering[cached] = t
        let img = await t.value
        rendering[cached] = nil
        return img
    }

    private func render(_ b: Board, framing: Board.Framing, enhancement: Board.Enhancement, cached: URL) -> Task<UIImage?, Never> {
        let d = dir(b)
        let base = file(b, framing.file + ".jpg")
        return Task.detached(priority: .userInitiated) {
            func load(_ url: URL) -> UIImage? { UIImage(contentsOfFile: url.path)?.normalized(maxDimension: .greatestFiniteMagnitude) }
            if framing == .content, !FileManager.default.fileExists(atPath: base.path) {
                guard let board = load(d.appendingPathComponent("cropped.jpg")),
                      let c = board.cropped(to: CVBridge.contentRect(board, margin: Self.contentMargin)) else { return nil }
                try? c.jpegData(compressionQuality: 0.92)?.write(to: base, options: .atomic)
            }
            if enhancement == .original { return load(base) }
            if let c = load(cached) { return c }
            guard let img = load(base) else { return nil }
            let e = CVBridge.enhance(img, mode: enhancement.rawValue)
            try? e.jpegData(compressionQuality: 0.92)?.write(to: cached, options: .atomic)
            return e
        }
    }

    /// Small previews of the board crop in each look (for the look picker).
    func lookPreviews(_ b: Board) async -> [Board.Enhancement: UIImage] {
        let t = file(b, "thumb.jpg")
        return await Task.detached(priority: .utility) {
            guard let img = UIImage(contentsOfFile: t.path)?.normalized(maxDimension: 480) else { return [:] }
            var out: [Board.Enhancement: UIImage] = [.original: img]
            for e in [Board.Enhancement.whiten, .scan] { out[e] = CVBridge.enhance(img, mode: e.rawValue) }
            return out
        }.value
    }

    // MARK: processing

    func process(_ id: UUID) async {
        guard let b = board(id), progress[id] == nil else { return }
        progress[id] = PipelineStage.preparing.rawValue
        let d = dir(b)
        let photos = b.photos
        let result: Result<PipelineOutput, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let images = try photos.map { name in
                    guard let img = UIImage(contentsOfFile: d.appendingPathComponent(name).path) else { throw PipelineError.imageConversion }
                    return img
                }
                let pipeline: WhiteboardPipeline
                if let rec = Self.captureRecord(in: d, photos: photos) { pipeline = .capture(rec) } else { pipeline = .opencv }
                return try pipeline.run(images) { s in Task { @MainActor in self.progress[id] = s.rawValue } }
            }
        }.value

        guard var b = board(id) else { progress[id] = nil; return }
        switch result {
        case .success(let out):
            await Task.detached {
                try? out.mosaic.jpegData(compressionQuality: 0.9)?.write(to: d.appendingPathComponent("mosaic.jpg"))
                try? out.flatFull.jpegData(compressionQuality: 0.92)?.write(to: d.appendingPathComponent("full.jpg"))
                try? out.flatCropped.jpegData(compressionQuality: 0.92)?.write(to: d.appendingPathComponent("cropped.jpg"))
                Self.writeThumbnail(out.flatCropped, to: d)
                Self.clearEnhancedCaches(d)
            }.value
            b.status = .done
            b.warnings = out.warnings
            b.leftOut = out.dropped.map { photos[$0] }
            b.mosaicToFull = out.mosaicToFull.rowMajor
            let r = out.croppedRect
            b.croppedRect = [r.minX, r.minY, r.width, r.height]
            b.corners = nil
            b.trims = [:]
        case .failure(let e):
            b.status = .failed(e.localizedDescription)
            b.warnings = []
            b.leftOut = nil
        }
        forgetRenders(b)
        save(b)
        progress[id] = nil
    }

    /// The scan's record restricted to (and ordered like) `photos`; nil if not a scan or a photo has no pose.
    static func captureRecord(in d: URL, photos: [String]) -> CaptureRecord? {
        guard let data = try? Data(contentsOf: d.appendingPathComponent(CaptureRecord.fileName)),
              var rec = try? JSONDecoder().decode(CaptureRecord.self, from: data) else { return nil }
        let byFile = Dictionary(rec.frames.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        let frames = photos.compactMap { byFile[$0] }
        guard frames.count == photos.count else { return nil }
        rec.frames = frames
        return rec
    }

    // MARK: corners

    /// Initial quad for the corner editor, in mosaic pixels: the manual one, else the automatic crop mapped back.
    func initialCorners(_ b: Board, mosaicSize: CGSize) -> [SIMD2<Double>] {
        if let c = b.corners, c.count == 4 { return c.map { SIMD2($0[0], $0[1]) } }
        if let m = b.mosaicToFull, let r = b.croppedRect, let inv = Homography(rowMajor: m).inverse {
            let q = [SIMD2(r[0], r[1]), SIMD2(r[0] + r[2], r[1]), SIMD2(r[0] + r[2], r[1] + r[3]), SIMD2(r[0], r[1] + r[3])].map(inv.apply)
            if isConvexQuad(q) { return q }
        }
        let w = Double(mosaicSize.width), h = Double(mosaicSize.height)
        return [SIMD2(0.05 * w, 0.05 * h), SIMD2(0.95 * w, 0.05 * h), SIMD2(0.95 * w, 0.95 * h), SIMD2(0.05 * w, 0.95 * h)]
    }

    /// Flatten the quad on the mosaic into cropped.jpg.
    func applyCorners(_ b: Board, _ quad: [SIMD2<Double>]) async throws {
        let d = dir(b)
        let (w, h) = rectifiedSize(of: quad)
        let dst = [SIMD2(0.0, 0), SIMD2(Double(w), 0), SIMD2(Double(w), Double(h)), SIMD2(0, Double(h))]
        guard isConvexQuad(quad), let H = homography(from: quad, to: dst) else { throw PipelineError.implausibleJoin(pair: 0) }
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let mosaic = UIImage(contentsOfFile: d.appendingPathComponent("mosaic.jpg").path)?
                    .normalized(maxDimension: .greatestFiniteMagnitude),
                  let out = CVBridge.warp(mosaic, homography: H.nsArray, width: w, height: h),
                  let data = out.jpegData(compressionQuality: 0.92) else { return false }
            try? data.write(to: d.appendingPathComponent("cropped.jpg"))
            Self.writeThumbnail(out, to: d)
            Self.clearEnhancedCaches(d)
            return true
        }.value
        guard ok else { throw PipelineError.imageConversion }
        var b = b
        b.corners = quad.map { [$0.x, $0.y] }
        b.dropBoardCropTrims()
        forgetRenders(b)
        save(b)
    }

    /// Back to the automatic crop (cropped.jpg re-cut from full.jpg).
    func resetCorners(_ b: Board) async {
        guard let r = b.croppedRect else { return }
        let d = dir(b)
        await Task.detached {
            guard let full = UIImage(contentsOfFile: d.appendingPathComponent("full.jpg").path)?.normalized(maxDimension: .greatestFiniteMagnitude),
                  let c = full.cropped(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) else { return }
            try? c.jpegData(compressionQuality: 0.92)?.write(to: d.appendingPathComponent("cropped.jpg"))
            Self.writeThumbnail(c, to: d)
            Self.clearEnhancedCaches(d)
        }.value
        var b = b
        b.corners = nil
        b.dropBoardCropTrims()
        forgetRenders(b)
        save(b)
    }

    private static func writeThumbnail(_ img: UIImage, to d: URL) {
        try? img.thumbnail(maxDimension: listThumbnailSize).jpegData(compressionQuality: 0.8)?.write(to: d.appendingPathComponent("thumb.jpg"))
    }

    /// Everything derived from full.jpg / cropped.jpg: enhanced versions, the content crop and the covers.
    private static func clearEnhancedCaches(_ d: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        where name.hasPrefix("full_e") || name.hasPrefix("cropped_e") || name.hasPrefix("content") || name.hasPrefix("cover-") {
            try? FileManager.default.removeItem(at: d.appendingPathComponent(name))
        }
    }
}

private extension Board {
    /// The board and content images are cut from cropped.jpg; trims made on the old one no longer fit.
    mutating func dropBoardCropTrims() {
        trims[Framing.board.rawValue] = nil
        trims[Framing.content.rawValue] = nil
    }
}
