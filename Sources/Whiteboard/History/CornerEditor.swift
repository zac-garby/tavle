import SwiftUI
import simd

/// Manual flattening (M3 fallback): drag four corners on the unflattened mosaic; the quad becomes the result.
struct CornerEditor: View {
    let board: Board
    @Environment(BoardStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var display: UIImage?          // downscaled mosaic for the screen
    @State private var mosaicSize = CGSize.zero    // full-res mosaic pixels
    @State private var corners: [SIMD2<Double>] = []   // full-res mosaic pixels, TL TR BR BL
    @State private var dragging: Int?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if let display, corners.count == 4 {
                    editor(display, in: geo.size)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black)
            .navigationTitle("Adjust corners")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(working || !isConvexQuad(corners))
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Use automatic crop") {
                        working = true
                        Task { await store.resetCorners(board); dismiss() }
                    }
                    .disabled(working || board.corners == nil)
                }
            }
            .alert("Couldn't apply", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .task { await load() }
    }

    private func load() async {
        let url = store.file(board, "mosaic.jpg")
        guard let (img, size) = await Task.detached(operation: { () -> (UIImage, CGSize)? in
            guard let full = UIImage(contentsOfFile: url.path) else { return nil }
            let size = full.pixelSize
            return full.normalized(maxDimension: 3000).map { ($0, size) }
        }).value else { error = "The unflattened image is missing; flatten the board again."; return }
        mosaicSize = size
        corners = store.initialCorners(board, mosaicSize: size)
        display = img
    }

    private func apply() {
        working = true
        Task {
            do { try await store.applyCorners(board, corners); dismiss() } catch { self.error = error.localizedDescription; working = false }
        }
    }

    // MARK: editor

    private func editor(_ img: UIImage, in size: CGSize) -> some View {
        let inset: CGFloat = 24
        let avail = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        let s = min(avail.width / mosaicSize.width, avail.height / mosaicSize.height)   // view points per mosaic pixel
        let fit = CGRect(x: (size.width - mosaicSize.width * s) / 2, y: (size.height - mosaicSize.height * s) / 2,
                         width: mosaicSize.width * s, height: mosaicSize.height * s)
        func toView(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: fit.minX + p.x * s, y: fit.minY + p.y * s) }
        func toMosaic(_ p: CGPoint) -> SIMD2<Double> {
            SIMD2(min(max(0, Double((p.x - fit.minX) / s)), Double(mosaicSize.width)),
                  min(max(0, Double((p.y - fit.minY) / s)), Double(mosaicSize.height)))
        }
        let pts = corners.map(toView)
        let valid = isConvexQuad(corners)

        return ZStack(alignment: .topLeading) {
            Image(uiImage: img).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
            Path { p in p.addLines(pts); p.closeSubpath() }
                .fill((valid ? Color.yellow : Color.red).opacity(0.12))
            Path { p in p.addLines(pts); p.closeSubpath() }
                .stroke(valid ? Color.yellow : Color.red, lineWidth: 2)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color.yellow.opacity(dragging == i ? 0.6 : 0.35)))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle().inset(by: -12))
                    .position(pts[i])
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
                        .onChanged { v in dragging = i; corners[i] = toMosaic(v.location) }
                        .onEnded { _ in dragging = nil })
            }
            if let i = dragging {
                loupe(img, fit: fit, point: pts[i], viewSize: size)
            }
        }
        .coordinateSpace(name: "editor")
    }

    /// Magnified view around the dragged corner, shown in the top corner away from the finger.
    private func loupe(_ img: UIImage, fit: CGRect, point: CGPoint, viewSize: CGSize) -> some View {
        let r: CGFloat = 64, z: CGFloat = 3
        let local = CGPoint(x: point.x - fit.minX, y: point.y - fit.minY)
        let onLeft = point.x > viewSize.width / 2
        let centre = CGPoint(x: onLeft ? r + 16 : viewSize.width - r - 16, y: r + 16)
        return ZStack(alignment: .topLeading) {
            Color.black
            Image(uiImage: img).resizable()
                .frame(width: fit.width * z, height: fit.height * z)
                .offset(x: r - local.x * z, y: r - local.y * z)
        }
        .frame(width: 2 * r, height: 2 * r, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        .overlay {
            Path { p in
                p.move(to: CGPoint(x: r - 10, y: r)); p.addLine(to: CGPoint(x: r + 10, y: r))
                p.move(to: CGPoint(x: r, y: r - 10)); p.addLine(to: CGPoint(x: r, y: r + 10))
            }
            .stroke(.yellow, lineWidth: 1.5)
        }
        .position(centre)
        .allowsHitTesting(false)
    }
}
