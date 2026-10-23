#if DEBUG
import UIKit

/// Sample boards for Xcode previews (Editor ▸ Canvas): drawn whiteboards in a throwaway folder.
extension BoardStore {
    static func preview(empty: Bool = false) -> BoardStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-boards-\(UUID().uuidString)")
        let store = BoardStore(root: root)
        guard !empty else { return store }
        let day = 86_400.0
        let samples: [(String, TimeInterval, Board.Status, [String], Int)] = [
            ("Type theory seminar", -2 * 3600, .done, [], 0),
            ("Group meeting", -day - 3 * 3600, .done,
             ["Photos 3 and 4 were joined using motion tracking only (the images didn't match up). Check the join."], 1),
            ("Lean sketch", -3 * day, .draft, [], 0),
            ("Reading group", -5 * day, .failed("Photos 2 and 3 don't seem to overlap. Check the order, or retake with more overlap."), [], 0),
            ("Category theory", -40 * day, .done, [], 0),
        ]
        for (i, (title, age, status, warnings, leftOut)) in samples.enumerated() {
            let board = sampleBoard(seed: UInt64(i + 1))
            let photos = (0..<5).map { k in
                board.cropped(to: CGRect(x: CGFloat(k) * board.size.width * 0.18, y: 0, width: board.size.width * 0.28, height: board.size.height))!
            }
            guard var b = try? store.create(images: photos, source: .scan) else { continue }
            b.title = title
            b.created = Date.now.addingTimeInterval(age)
            b.status = status
            b.warnings = warnings
            b.leftOut = Array(b.photos.dropFirst(2).prefix(leftOut))
            if status == .done {
                for name in ["cropped.jpg", "full.jpg", "mosaic.jpg"] { try? board.jpegData(compressionQuality: 0.9)?.write(to: store.file(b, name)) }
                try? board.thumbnail(maxDimension: listThumbnailSize).jpegData(compressionQuality: 0.8)?.write(to: store.file(b, "thumb.jpg"))
                let s = board.pixelSize
                b.croppedRect = [0, 0, s.width, s.height]
                b.mosaicToFull = Homography.identity.rowMajor
                if i == 1 { b.framing = .content; b.enhancement = .whiten }
                if i == 4 { b.enhancement = .scan; b.trims[Board.Framing.board.rawValue] = [0, 0, 0.55, 1] }
            }
            store.save(b)
        }
        store.reload()
        return store
    }

    /// A whiteboard: off-white with marker scribbles in rows, a divider, a boxed bit.
    static func sampleBoard(seed: UInt64) -> UIImage {
        var rng = SplitMix64(seed: seed)
        let size = CGSize(width: 2400, height: 880)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let inks: [UIColor] = [UIColor(red: 0.11, green: 0.25, blue: 0.62, alpha: 1), UIColor(white: 0.13, alpha: 1),
                               UIColor(red: 0.70, green: 0.15, blue: 0.12, alpha: 1), UIColor(red: 0.11, green: 0.48, blue: 0.23, alpha: 1)]
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            func scribble(x0: CGFloat, x1: CGFloat, y: CGFloat, ink: UIColor) {
                let p = UIBezierPath(); p.move(to: CGPoint(x: x0, y: y))
                var x = x0
                while x < x1 {
                    p.addLine(to: CGPoint(x: x + 9, y: y - 16 - CGFloat(Double.random(in: 0...14, using: &rng))))
                    p.addLine(to: CGPoint(x: x + 18, y: y + CGFloat(Double.random(in: 0...6, using: &rng))))
                    x += 18
                    if Double.random(in: 0...1, using: &rng) < 0.08 { x += 30; p.move(to: CGPoint(x: x, y: y)) }
                }
                ink.setStroke(); p.lineWidth = 6; p.lineJoinStyle = .round; p.stroke()
            }
            for row in 0..<7 {
                let y = 110 + CGFloat(row) * 105
                scribble(x0: 80 + CGFloat(Double.random(in: 0...60, using: &rng)), x1: 600 + CGFloat(Double.random(in: 0...500, using: &rng)),
                         y: y, ink: inks[row % 3 == 2 ? 2 : (row % 2)])
                if row < 5 { scribble(x0: 1420, x1: 1700 + CGFloat(Double.random(in: 0...550, using: &rng)), y: y, ink: inks[row == 1 ? 3 : 0]) }
            }
            let divider = UIBezierPath(); divider.move(to: CGPoint(x: 1340, y: 60)); divider.addLine(to: CGPoint(x: 1348, y: 820))
            inks[1].setStroke(); divider.lineWidth = 6; divider.stroke()
            let box = UIBezierPath(roundedRect: CGRect(x: 1400, y: 640, width: 700, height: 170), cornerRadius: 20)
            inks[3].setStroke(); box.lineWidth = 6; box.stroke()
        }
    }
}
#endif
