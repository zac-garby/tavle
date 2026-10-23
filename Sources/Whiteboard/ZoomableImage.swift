import SwiftUI
import UIKit

/// Pinch-zoom / pan / double-tap image viewer (UIScrollView; SwiftUI's gestures are poor at this).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }
    func updateUIView(_ v: ZoomScrollView, context: Context) { if v.image !== image { v.image = image } }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var needsFit = true

    var image: UIImage? {
        didSet {
            zoomScale = 1
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: image?.size ?? .zero)
            contentSize = imageView.frame.size
            needsFit = true
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let s = image?.size, s.width > 0, s.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / s.width, bounds.height / s.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 10, 2)
        if needsFit || zoomScale < fit { zoomScale = fit; needsFit = false }
        centre()
    }

    private func centre() {
        let dx = max(0, (bounds.width - contentSize.width) / 2), dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView), s = min(maximumZoomScale, minimumZoomScale * 4)
            let size = CGSize(width: bounds.width / s, height: bounds.height / s)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
