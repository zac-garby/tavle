import ARKit
import AVFoundation
import SceneKit
import SwiftUI

enum CaptureResult {
    case scan(URL)              // AR scan directory (capture.json + frames)
    case photos([UIImage])      // ultra-wide photos, left -> right, no poses
}

/// Full-screen guided capture: 1× = ARKit (tracked poses, flattened from the board plane); 0.5× = ultra-wide
/// (ARKit can't track on it; joined and flattened from the images). The lens can be switched until the first photo.
struct CaptureView: View {
    var onFinish: (CaptureResult) -> Void
    var onCancel: () -> Void

    enum Lens { case ultraWide, wide }
    @State private var lens: Lens = .wide
    @State private var ar = CaptureModel()
    @State private var uw = UltraWideCaptureModel()

    var body: some View {
        Group {
            switch lens {
            case .wide:
                CaptureScreen(model: ar, camera: ARCameraView(model: ar), lensPicker: lensPicker(locked: !ar.keyframes.isEmpty),
                              note: nil, onDone: { if let dir = ar.finish() { onFinish(.scan(dir)) } }, onCancel: { ar.cancel(); onCancel() })
            case .ultraWide:
                CaptureScreen(model: uw, camera: CameraPreview(session: uw.session), lensPicker: lensPicker(locked: !uw.thumbnails.isEmpty),
                              note: "0.5× has no motion tracking: photos are joined from the images alone.",
                              onDone: { let imgs = uw.finish(); if !imgs.isEmpty { onFinish(.photos(imgs)) } },
                              onCancel: { uw.cancel(); onCancel() })
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder private func lensPicker(locked: Bool) -> some View {
        if UltraWideCaptureModel.isAvailable && CaptureModel.isSupported && !locked {
            LensPicker(ultraWide: lens == .ultraWide) { switchLens(to: $0 ? .ultraWide : .wide) }
        }
    }

    private func switchLens(to l: Lens) {
        guard l != lens else { return }
        if lens == .wide { ar.cancel(); ar = CaptureModel() } else { uw.cancel(); uw = UltraWideCaptureModel() }
        lens = l
    }
}

/// Camera-app style lens switch: the selected lens reads "1×" / "0.5×" in the accent, the other just its number.
struct LensPicker: View {
    let ultraWide: Bool
    let select: (Bool) -> Void
    var body: some View {
        HStack(spacing: 2) {
            lens(true, on: "0.5×", off: ".5")
            lens(false, on: "1×", off: "1")
        }
        .padding(3)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func lens(_ uw: Bool, on: String, off: String) -> some View {
        let selected = uw == ultraWide
        return Button { select(uw) } label: {
            Text(selected ? on : off)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.accent : .white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(selected ? 0.18 : 0)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(uw ? "Ultra wide lens" : "Wide lens")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The HUD shared by both modes.
private struct CaptureScreen<Model: CaptureControlling, Camera: View, Lenses: View>: View {
    let model: Model
    let camera: Camera
    let lensPicker: Lenses
    let note: String?
    let onDone: () -> Void
    let onCancel: () -> Void
    @State private var flash = false

    var body: some View {
        ZStack {
            camera.ignoresSafeArea()
            Color.white.opacity(flash ? 0.5 : 0).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 12) {
                Text(model.errorMessage ?? model.guidance.rawValue)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .glass(in: Capsule())
                    .animation(.default, value: model.guidance)
                    .padding(.horizontal)
                if let note, model.thumbnails.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.white).shadow(radius: 3).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                if let c = model.coverage { CoverageMap(coverage: c) }
                Spacer()
                if !model.thumbnails.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { i, t in
                                    Image(uiImage: t).resizable().scaledToFill()
                                        .frame(width: 40, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1.5))
                                        .id(i)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .onChange(of: model.thumbnails.count) { _, n in withAnimation { proxy.scrollTo(n - 1, anchor: .trailing) } }
                    }
                    .frame(height: 56)
                }
                lensPicker
                HStack {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .buttonStyle(.glassCircle)
                        .accessibilityLabel("Cancel")
                    Spacer()
                    Button { model.requestManualCapture() } label: {
                        ShutterLabel(progress: ringProgress, ringColor: ringColor, size: 80, dimmed: model.capturing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.thumbnails.isEmpty ? "Take the first photo" : "Take a photo now")
                    Spacer()
                    Button(action: onDone) {
                        Text("Done · \(model.thumbnails.count)")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 52)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(model.thumbnails.isEmpty || model.capturing ? 0.4 : 1)
                    .disabled(model.thumbnails.isEmpty || model.capturing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
        }
        .onAppear { model.start() }
        .onChange(of: model.shutterCount) {
            withAnimation(.easeOut(duration: 0.05)) { flash = true }
            withAnimation(.easeIn(duration: 0.3).delay(0.05)) { flash = false }
        }
    }

    /// The shutter ring fills as the view moves on from the last photo; full = the next photo is due.
    private var ringProgress: Double {
        guard !model.thumbnails.isEmpty, let o = model.overlap else { return 0 }
        let t = model.policy.triggerOverlap
        return (1 - o) / max(0.01, 1 - t)
    }

    private var ringColor: Color {
        if let o = model.overlap, !model.thumbnails.isEmpty, o < model.policy.minOverlap { return Theme.warning }
        return Theme.accent
    }
}

/// Bird's-eye strip of the sweep: photos taken (white) and where the camera points now (green outline).
private struct CoverageMap: View {
    let coverage: CaptureCoverage

    var body: some View {
        Canvas { ctx, size in
            let all = coverage.shots + (coverage.view.map { [$0] } ?? [])
            guard var u = all.first else { return }
            for r in all.dropFirst() { u = u.union(r) }
            let inset: CGFloat = 8
            let s = min((size.width - 2 * inset) / max(u.width, 1e-9), (size.height - 2 * inset) / max(u.height, 1e-9))
            let ox = (size.width - u.width * s) / 2, oy = (size.height - u.height * s) / 2
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: ox + (r.minX - u.minX) * s, y: oy + (r.minY - u.minY) * s, width: r.width * s, height: r.height * s)
            }
            for r in coverage.shots {
                ctx.fill(Path(roundedRect: map(r), cornerRadius: 3), with: .color(.white.opacity(0.28)))
            }
            if let v = coverage.view {
                ctx.stroke(Path(roundedRect: map(v), cornerRadius: 4), with: .color(Theme.accent), lineWidth: 2)
            }
        }
        .frame(width: 240, height: 48)
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Coverage: \(coverage.shots.count) photos")
    }
}

private struct ARCameraView: UIViewRepresentable {
    let model: CaptureModel
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = model.session
        v.automaticallyUpdatesLighting = false
        v.scene.rootNode.addChildNode(model.overlayRoot)
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: PreviewView, context: Context) {}
}

#if DEBUG
@Observable
private final class PreviewCapture: CaptureControlling {
    var guidance = KeyframePolicy.Guidance.keepMoving
    var overlap: Double? = 0.82
    var thumbnails: [UIImage] = (1...3).map { _ in BoardStore.sampleBoard(seed: 1).thumbnail(maxDimension: 160) }
    var capturing = false
    var shutterCount = 0
    var errorMessage: String?
    var coverage: CaptureCoverage? = CaptureCoverage(
        shots: (0..<3).map { CGRect(x: Double($0) * 0.3, y: 0.02 * Double($0), width: 1, height: 0.75) },
        view: CGRect(x: 0.75, y: 0.05, width: 1, height: 0.75))
    var policy = KeyframePolicy()
    func start() {}
    func requestManualCapture() {}
    func cancel() {}
}

extension CaptureView {
    /// The HUD frozen mid-sweep over a still picture (App Store screenshots; see `Screenshots`).
    static func still(backdrop: UIImage?, thumbnails: [UIImage]) -> some View {
        let m = PreviewCapture()
        if !thumbnails.isEmpty { m.thumbnails = thumbnails }
        let n = m.thumbnails.count
        m.coverage = CaptureCoverage(shots: (0..<n).map { CGRect(x: Double($0) * 0.35, y: 0.015 * Double($0 % 2), width: 1, height: 0.75) },
                                     view: CGRect(x: Double(n) * 0.35 - 0.12, y: 0.01, width: 1, height: 0.75))
        let camera = Color.black.overlay { if let backdrop { Image(uiImage: backdrop).resizable().scaledToFill() } }.clipped()
        return CaptureScreen(model: m, camera: camera, lensPicker: LensPicker(ultraWide: false) { _ in }, note: nil, onDone: {}, onCancel: {})
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
    }
}

#Preview("Capture") {
    let m = PreviewCapture()
    return CaptureScreen(model: m, camera: Color(white: 0.25).overlay(Image(uiImage: BoardStore.sampleBoard(seed: 2)).resizable().scaledToFit().padding()),
                         lensPicker: LensPicker(ultraWide: false) { _ in }, note: nil, onDone: {}, onCancel: {})
        .preferredColorScheme(.dark)
}
#endif
