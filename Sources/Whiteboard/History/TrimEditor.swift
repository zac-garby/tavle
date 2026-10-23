import SwiftUI

/// Crop handles over the whole (uncropped) result: drag a side or a corner to move it, or the middle to move
/// the crop. `trim` and `commit` are in unit coordinates of the image.
struct TrimEditor: View {
    let image: UIImage
    let trim: CGRect
    let commit: (CGRect) -> Void

    @State private var draft: CGRect?
    @State private var grab: Grab?

    /// Which sides a drag holds (none: the whole crop), and the crop when it started.
    private struct Grab { var left = false, right = false, top = false, bottom = false; var start: CGRect }

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(in: geo.size)
            let r = draft ?? trim
            let box = CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                             width: r.width * fit.width, height: r.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                Path { p in p.addRect(fit); p.addRect(box) }
                    .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                Rectangle().path(in: box).stroke(.white.opacity(0.9), lineWidth: 1)
                handles(box)
            }
            .contentShape(Rectangle())
            .gesture(drag(fit: fit, box: box))
            .sensoryFeedback(.selection, trigger: grab != nil)
        }
        .accessibilityElement()
        .accessibilityLabel("Crop")
        .accessibilityHint("Drag the sides or corners to crop")
    }

    /// The image fitted with room around it for the handles.
    private func fitted(in size: CGSize) -> CGRect {
        let inset: CGFloat = 22, s = image.size
        guard s.width > 0, s.height > 0 else { return .zero }
        let k = max(0, min((size.width - 2 * inset) / s.width, (size.height - 2 * inset) / s.height))
        return CGRect(x: (size.width - s.width * k) / 2, y: (size.height - s.height * k) / 2, width: s.width * k, height: s.height * k)
    }

    /// Photos-style: thick L at each corner, a short bar in the middle of each side.
    private func handles(_ box: CGRect) -> some View {
        let arm = min(22, box.width / 3, box.height / 3), bar = min(28, box.width / 3, box.height / 3)
        return Path { p in
            for (c, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1, 1),
                                (CGPoint(x: box.maxX, y: box.maxY), -1, -1), (CGPoint(x: box.minX, y: box.maxY), 1, -1)] {
                p.move(to: CGPoint(x: c.x, y: c.y + dy * arm)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x + dx * arm, y: c.y))
            }
            p.move(to: CGPoint(x: box.midX - bar / 2, y: box.minY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.minY))
            p.move(to: CGPoint(x: box.midX - bar / 2, y: box.maxY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.maxY))
            p.move(to: CGPoint(x: box.minX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.minX, y: box.midY + bar / 2))
            p.move(to: CGPoint(x: box.maxX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.maxX, y: box.midY + bar / 2))
        }
        .stroke(grab == nil ? Color.white : Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    private func drag(fit: CGRect, box: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard fit.width > 0, fit.height > 0 else { return }
                guard let g = grab ?? Self.grab(at: v.startLocation, box: box, start: trim) else { return }
                if grab == nil { grab = g }
                draft = Self.moved(g, by: CGSize(width: v.translation.width / fit.width, height: v.translation.height / fit.height),
                                   minSize: CGSize(width: 44 / fit.width, height: 44 / fit.height))
            }
            .onEnded { _ in
                if let draft { commit(draft) }
                grab = nil
                draft = nil
            }
    }

    /// Sides within reach of the finger (the nearer one per axis); inside the crop with no side near moves it all.
    private static func grab(at p: CGPoint, box: CGRect, start: CGRect) -> Grab? {
        let reach: CGFloat = 30
        var g = Grab(start: start)
        let dl = abs(p.x - box.minX), dr = abs(p.x - box.maxX), dt = abs(p.y - box.minY), db = abs(p.y - box.maxY)
        let alongX = p.x > box.minX - reach && p.x < box.maxX + reach, alongY = p.y > box.minY - reach && p.y < box.maxY + reach
        if alongY, min(dl, dr) < reach { if dl <= dr { g.left = true } else { g.right = true } }
        if alongX, min(dt, db) < reach { if dt <= db { g.top = true } else { g.bottom = true } }
        if !(g.left || g.right || g.top || g.bottom) && !box.contains(p) { return nil }
        return g
    }

    /// The crop after dragging `g` by `d` (unit coordinates), kept inside the image and at least `minSize`.
    private static func moved(_ g: Grab, by d: CGSize, minSize: CGSize) -> CGRect {
        let s = g.start
        guard g.left || g.right || g.top || g.bottom else {
            let x = min(max(0, s.minX + d.width), 1 - s.width), y = min(max(0, s.minY + d.height), 1 - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        var x0 = s.minX, x1 = s.maxX, y0 = s.minY, y1 = s.maxY
        if g.left { x0 = min(max(0, x0 + d.width), x1 - minSize.width) }
        if g.right { x1 = max(min(1, x1 + d.width), x0 + minSize.width) }
        if g.top { y0 = min(max(0, y0 + d.height), y1 - minSize.height) }
        if g.bottom { y1 = max(min(1, y1 + d.height), y0 + minSize.height) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

#if DEBUG
#Preview("Crop") {
    TrimEditor(image: BoardStore.sampleBoard(seed: 3), trim: CGRect(x: 0.05, y: 0.1, width: 0.6, height: 0.8)) { _ in }
        .background(Color.black)
}
#endif
