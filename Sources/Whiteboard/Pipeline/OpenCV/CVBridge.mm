// OpenCV must come before any Apple header (macro clashes such as NO / YES).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>
#import <opencv2/photo.hpp>
#pragma clang diagnostic pop

#import "CVBridge.h"

#include <algorithm>
#include <cmath>
#include <vector>

@implementation CVPairRegistration
@end

// MARK: - UIImage <-> cv::Mat (BGR, 8-bit, like cv2.imread)

static cv::Mat matFromImage(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return cv::Mat();
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    cv::Mat rgba((int)h, (int)w, CV_8UC4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba.data, w, h, 8, rgba.step[0], cs,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(cs);
    if (!ctx) return cv::Mat();
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    cv::Mat bgr;
    cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    return bgr;
}

static UIImage *imageFromMat(const cv::Mat &bgr) {
    if (bgr.empty()) return nil;
    cv::Mat rgba;
    cv::cvtColor(bgr, rgba, cv::COLOR_BGR2RGBA);
    NSData *data = [NSData dataWithBytes:rgba.data length:rgba.total() * rgba.elemSize()];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef cg = CGImageCreate(rgba.cols, rgba.rows, 8, 32, rgba.step[0], cs,
                                  (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

static cv::Matx33d matxFromArray(NSArray<NSNumber *> *a) {
    cv::Matx33d m;
    for (int i = 0; i < 9; i++) m.val[i] = a[i].doubleValue;
    return m;
}

static NSArray<NSNumber *> *arrayFromMat33(const cv::Mat &m) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:9];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) [out addObject:@(m.at<double>(r, c))];
    return out;
}

// MARK: - Registration

static cv::Mat prep(const cv::Mat &bgr) {
    cv::Mat g, out;
    cv::cvtColor(bgr, g, cv::COLOR_BGR2GRAY);
    cv::createCLAHE(3.0, cv::Size(8, 8))->apply(g, out);
    return out;
}

/// SIFT + ratio test. `src` are points in b, `dst` the matching points in a.
static void siftMatches(const cv::Mat &ga, const cv::Mat &gb, const cv::Mat &maskA, const cv::Mat &maskB, float ratio,
                        std::vector<cv::Point2f> &src, std::vector<cv::Point2f> &dst) {
    auto sift = cv::SIFT::create(8000, 3, 0.02);
    std::vector<cv::KeyPoint> ka, kb;
    cv::Mat da, db;
    sift->detectAndCompute(ga, maskA, ka, da);
    sift->detectAndCompute(gb, maskB, kb, db);
    if (da.rows < 2 || db.rows < 2) return;
    std::vector<std::vector<cv::DMatch>> m;
    cv::BFMatcher().knnMatch(db, da, m, 2);
    for (auto &x : m) {
        if (x.size() == 2 && x[0].distance < ratio * x[1].distance) {
            src.push_back(kb[x[0].queryIdx].pt);
            dst.push_back(ka[x[0].trainIdx].pt);
        }
    }
}

@implementation CVBridge

+ (CVPairRegistration *)registerLeft:(UIImage *)left right:(UIImage *)right minHomographyInliers:(NSInteger)minInliers {
    cv::Mat a = matFromImage(left), b = matFromImage(right);
    if (a.empty() || b.empty()) return nil;
    cv::Mat ga = prep(a), gb = prep(b);

    std::vector<cv::Point2f> src, dst;
    siftMatches(ga, gb, cv::Mat(), cv::Mat(), 0.75f, src, dst);
    if (src.size() >= 8) {
        cv::Mat inl;
        cv::Mat H = cv::findHomography(src, dst, cv::RANSAC, 4.0, inl);
        int n = H.empty() ? 0 : cv::countNonZero(inl);
        if (!H.empty() && n >= minInliers) {
            CVPairRegistration *r = [CVPairRegistration new];
            r.matrix = arrayFromMat33(H);
            r.inliers = n;
            r.isHomography = YES;
            return r;
        }
    }

    // Thin overlap: restrict to the facing strips and fit a 4-DoF similarity.
    cv::Mat ma = cv::Mat::zeros(a.size(), CV_8U), mb = cv::Mat::zeros(b.size(), CV_8U);
    ma(cv::Rect((int)(a.cols * 0.45), 0, a.cols - (int)(a.cols * 0.45), a.rows)).setTo(255);
    mb(cv::Rect(0, 0, (int)(b.cols * 0.30), b.rows)).setTo(255);
    src.clear(); dst.clear();
    siftMatches(ga, gb, ma, mb, 0.8f, src, dst);
    if (src.size() < 3) return nil;
    cv::Mat inl;
    cv::Mat A = cv::estimateAffinePartial2D(src, dst, inl, cv::RANSAC, 4.0);
    if (A.empty()) return nil;
    cv::Mat H = cv::Mat::eye(3, 3, CV_64F);
    A.copyTo(H(cv::Rect(0, 0, 3, 2)));
    CVPairRegistration *r = [CVPairRegistration new];
    r.matrix = arrayFromMat33(H);
    r.inliers = cv::countNonZero(inl);
    r.isHomography = NO;
    return r;
}

// MARK: - Blending

namespace {
struct Placed {
    cv::Rect roi;        // where the image lands on the canvas
    cv::Matx33d H;       // image -> ROI pixels
};

/// Warped validity mask of an image inside its ROI (non-zero = covered), as in the reference (linear interpolation).
cv::Mat warpedMask(const cv::Mat &im, const Placed &p) {
    cv::Mat m;
    cv::warpPerspective(cv::Mat(im.size(), CV_8U, cv::Scalar(255)), m, p.H, p.roi.size());
    return m;
}

/// Per-channel gain g with `ref ≈ g * img` over `mask`: median of pixel ratios, then re-estimated on the pixels
/// that agree with it (drops glare, ink misalignment, etc. — a mean or plain median gets dragged by them).
cv::Vec3d robustGain(const cv::Mat &img, const cv::Mat &ref, const cv::Mat &mask) {
    std::vector<float> r[3];
    std::vector<cv::Vec2f> pairs[3];
    const int step = std::max(1, (int)std::sqrt((double)cv::countNonZero(mask) / 100000.0));
    for (int y = 0; y < img.rows; y += step) {
        const uchar *a = img.ptr<uchar>(y), *b = ref.ptr<uchar>(y), *m = mask.ptr<uchar>(y);
        for (int x = 0; x < img.cols; x += step) {
            if (!m[x]) continue;
            for (int c = 0; c < 3; c++) {
                const float va = a[3 * x + c], vb = b[3 * x + c];
                if (va < 40 || vb < 40 || va > 252 || vb > 252) continue;   // ink / clipped
                pairs[c].push_back({va, vb});
            }
        }
    }
    cv::Vec3d g(1, 1, 1);
    for (int c = 0; c < 3; c++) {
        if (pairs[c].size() < 50) continue;
        auto median = [](std::vector<float> &v) { std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end()); return v[v.size() / 2]; };
        r[c].clear();
        for (auto &p : pairs[c]) r[c].push_back(p[1] / p[0]);
        float est = median(r[c]);
        for (int it = 0; it < 2; it++) {
            r[c].clear();
            for (auto &p : pairs[c]) if (std::abs(p[1] - est * p[0]) < 8) r[c].push_back(p[1] / p[0]);
            if (r[c].size() < 50) break;
            est = median(r[c]);
        }
        g[c] = est;
    }
    return g;
}

/// Gain-corrected luminance of the warped image.
cv::Mat warpedLuma(const cv::Mat &im, const Placed &p, const cv::Vec3d &gain) {
    cv::Mat w, g;
    cv::warpPerspective(im, w, p.H, p.roi.size());
    cv::cvtColor(w, g, cv::COLOR_BGR2GRAY);
    g.convertTo(g, CV_8U, (gain[0] + gain[1] + gain[2]) / 3);
    return g;
}
}

+ (UIImage *)blendImages:(NSArray<UIImage *> *)images
            homographies:(NSArray<NSArray<NSNumber *> *> *)homographies
                   width:(NSInteger)W
                  height:(NSInteger)Ht
                  middle:(NSInteger)mid
             reduceGlare:(BOOL)reduceGlare
               multiBand:(BOOL)multiBand {
    const int n = (int)images.count;
    if (n == 0 || homographies.count != (NSUInteger)n || W <= 0 || Ht <= 0) return nil;
    std::vector<cv::Mat> ims(n);
    std::vector<cv::Matx33d> Hs(n);
    for (int i = 0; i < n; i++) {
        ims[i] = matFromImage(images[i]);
        if (ims[i].empty()) return nil;
        Hs[i] = matxFromArray(homographies[i]);
    }

    // Gains: per-channel match on a ~2 MP preview, chained towards the middle. The reference used means; a robust
    // ratio keeps a glare streak in the overlap from brightening/darkening a whole frame.
    const double gs = std::min(1.0, std::sqrt(2e6 / ((double)W * Ht)));
    const cv::Size small(std::max(1, (int)std::lround(W * gs)), std::max(1, (int)std::lround(Ht * gs)));
    const cv::Matx33d S(gs, 0, 0, 0, gs, 0, 0, 0, 1);
    std::vector<cv::Vec3d> gain(n, cv::Vec3d(1, 1, 1));
    {
        std::vector<cv::Mat> lw(n), lm(n);
        for (int i = 0; i < n; i++) {
            cv::warpPerspective(ims[i], lw[i], S * Hs[i], small);
            cv::warpPerspective(cv::Mat(ims[i].size(), CV_8U, cv::Scalar(255)), lm[i], S * Hs[i], small);
        }
        auto match = [&](int k, int nb) {
            cv::Mat ov = (lm[k] > 0) & (lm[nb] > 0);
            if (cv::countNonZero(ov) <= std::max(50.0, 1000 * gs * gs)) { gain[k] = gain[nb]; return; }
            const cv::Vec3d r = robustGain(lw[k], lw[nb], ov);
            for (int c = 0; c < 3; c++) gain[k][c] = gain[nb][c] * r[c];
        };
        for (int k = (int)mid - 1; k >= 0; k--) match(k, k + 1);
        for (int k = (int)mid + 1; k < n; k++) match(k, k - 1);
    }

    // Each image is only ever warped into its own bounding box on the canvas (memory).
    const cv::Rect canvas(0, 0, (int)W, (int)Ht);
    std::vector<Placed> placed(n);
    for (int i = 0; i < n; i++) {
        std::vector<cv::Point2f> cs = {{0, 0}, {(float)ims[i].cols, 0}, {(float)ims[i].cols, (float)ims[i].rows},
                                       {0, (float)ims[i].rows}}, wc;
        cv::perspectiveTransform(cs, wc, cv::Matx33f(Hs[i]));
        cv::Rect roi = cv::boundingRect(wc);
        roi = cv::Rect(roi.x - 2, roi.y - 2, roi.width + 4, roi.height + 4) & canvas;
        placed[i] = {roi, cv::Matx33d(1, 0, -roi.x, 0, 1, -roi.y, 0, 0, 1) * Hs[i]};
    }

    // Glare: specular streaks move with the viewpoint, so where frames overlap, a frame that is much brighter
    // than the darkest frame *over plain board* is probably glare there. Lmin = darkest luminance per pixel;
    // board = its local background (max filter removes ink, then blur).
    cv::Mat Lmin, board;
    if (reduceGlare && n > 1) {
        Lmin = cv::Mat((int)Ht, (int)W, CV_8U, cv::Scalar(0));
        cv::Mat covered((int)Ht, (int)W, CV_8U, cv::Scalar(0));
        for (int i = 0; i < n; i++) {
            if (placed[i].roi.empty()) continue;
            cv::Mat m = warpedMask(ims[i], placed[i]) > 0, L = warpedLuma(ims[i], placed[i], gain[i]);
            cv::Mat lroi = Lmin(placed[i].roi), croi = covered(placed[i].roi);
            cv::Mat first = m & (croi == 0), later = m & (croi != 0);
            L.copyTo(lroi, first);
            cv::Mat mn; cv::min(lroi, L, mn); mn.copyTo(lroi, later);
            croi.setTo(255, m);
        }
        cv::Mat sm, bg;
        cv::resize(Lmin, sm, cv::Size(), 0.125, 0.125, cv::INTER_AREA);
        cv::dilate(sm, bg, cv::Mat::ones(9, 9, CV_8U));
        cv::GaussianBlur(bg, bg, cv::Size(0, 0), 4);
        cv::resize(bg, board, Lmin.size(), 0, 0, cv::INTER_LINEAR);
    }

    // Per-image weight in its ROI: distance to its border (feathering), times the glare factor.
    auto weight = [&](int i) -> cv::Mat {
        cv::Mat dist;
        cv::distanceTransform(warpedMask(ims[i], placed[i]), dist, cv::DIST_L2, 5);
        if (Lmin.empty()) return dist;
        cv::Mat L = warpedLuma(ims[i], placed[i], gain[i]);
        cv::Mat lmin = Lmin(placed[i].roi), bg = board(placed[i].roi);
        cv::Mat g(L.size(), CV_32F);
        for (int y = 0; y < L.rows; y++) {
            const uchar *l = L.ptr<uchar>(y), *m = lmin.ptr<uchar>(y), *b = bg.ptr<uchar>(y);
            float *o = g.ptr<float>(y);
            for (int x = 0; x < L.cols; x++) {
                const float excess = (float)l[x] - (float)m[x] - 8;
                o[x] = (m[x] < 0.85f * b[x] || excess <= 0) ? 1.f : std::max(0.02f, std::exp(-excess / 6.f));
            }
        }
        cv::GaussianBlur(g, g, cv::Size(0, 0), 6);   // no speckly seams
        return dist.mul(g);
    };

    cv::Mat out((int)Ht, (int)W, CV_8UC3, cv::Scalar::all(0));
    if (multiBand && n > 1) {
        // Two-band blend (Brown & Lowe): low frequencies are a weighted average with the glare-aware weights,
        // done on a 1/8-scale grid (smooth exposure transitions; a glared frame contributes ~nothing); fine
        // detail comes from the single highest-weight frame per pixel (no ghosting from small misalignments).
        cv::Mat best((int)Ht, (int)W, CV_32F, cv::Scalar(0)), owner((int)Ht, (int)W, CV_8U, cv::Scalar(255));
        std::vector<cv::Mat> weights(n);
        for (int i = 0; i < n; i++) {
            if (placed[i].roi.empty()) continue;
            weights[i] = weight(i);
            cv::Mat b = best(placed[i].roi), o = owner(placed[i].roi);
            cv::Mat better = weights[i] > b;
            weights[i].copyTo(b, better);
            o.setTo(i, better);
        }
        best.release();

        const double f = 0.125;
        const cv::Size gsz(std::max(1, (int)std::lround(W * f)), std::max(1, (int)std::lround(Ht * f)));
        cv::Mat lpSum(gsz, CV_32FC3, cv::Scalar::all(0)), lpW(gsz, CV_32F, cv::Scalar(0));
        cv::Mat hp((int)Ht, (int)W, CV_16SC3, cv::Scalar::all(0));
        for (int i = 0; i < n; i++) {
            const Placed &p = placed[i];
            if (p.roi.empty()) continue;
            cv::Mat wimg;
            cv::warpPerspective(ims[i], wimg, p.H, p.roi.size());
            ims[i].release();
            cv::Mat &w = weights[i];
            // w * gain * image, in float, inside the ROI.
            cv::Mat wi(p.roi.size(), CV_32FC3);
            const float g0 = (float)gain[i][0], g1 = (float)gain[i][1], g2 = (float)gain[i][2];
            cv::parallel_for_(cv::Range(0, p.roi.height), [&](const cv::Range &rows) {
                for (int y = rows.start; y < rows.end; y++) {
                    const uchar *s = wimg.ptr<uchar>(y); const float *ww = w.ptr<float>(y); float *o = wi.ptr<float>(y);
                    for (int x = 0; x < p.roi.width; x++) {
                        o[3 * x] = ww[x] * g0 * s[3 * x]; o[3 * x + 1] = ww[x] * g1 * s[3 * x + 1]; o[3 * x + 2] = ww[x] * g2 * s[3 * x + 2];
                    }
                }
            });
            // Low band of this image on a local small grid: weighted mean (no bleeding of the black outside).
            const cv::Size lsz(std::max(1, (int)std::lround(p.roi.width * f)), std::max(1, (int)std::lround(p.roi.height * f)));
            cv::Mat wiS, wS;
            cv::resize(wi, wiS, lsz, 0, 0, cv::INTER_AREA);
            cv::resize(w, wS, lsz, 0, 0, cv::INTER_AREA);
            wi.release();
            cv::Mat lp(lsz, CV_32FC3, cv::Scalar::all(0));
            for (int y = 0; y < lsz.height; y++) {
                const float *a = wiS.ptr<float>(y), *ww = wS.ptr<float>(y); float *o = lp.ptr<float>(y);
                for (int x = 0; x < lsz.width; x++) if (ww[x] > 1e-6f) for (int c = 0; c < 3; c++) o[3 * x + c] = a[3 * x + c] / ww[x];
            }
            // High band where this image owns the pixel: gain * image - its low band.
            cv::Mat lpUp;
            cv::resize(lp, lpUp, p.roi.size(), 0, 0, cv::INTER_LINEAR);
            cv::Mat own = owner(p.roi), hroi = hp(p.roi);
            cv::parallel_for_(cv::Range(0, p.roi.height), [&](const cv::Range &rows) {
                for (int y = rows.start; y < rows.end; y++) {
                    const uchar *s = wimg.ptr<uchar>(y), *ow = own.ptr<uchar>(y); const float *l = lpUp.ptr<float>(y);
                    short *h = hroi.ptr<short>(y);
                    for (int x = 0; x < p.roi.width; x++) {
                        if (ow[x] != i) continue;
                        h[3 * x] = cv::saturate_cast<short>(g0 * s[3 * x] - l[3 * x]);
                        h[3 * x + 1] = cv::saturate_cast<short>(g1 * s[3 * x + 1] - l[3 * x + 1]);
                        h[3 * x + 2] = cv::saturate_cast<short>(g2 * s[3 * x + 2] - l[3 * x + 2]);
                    }
                }
            });
            // Accumulate the weighted low band on the global small grid.
            const cv::Matx23d M(p.roi.width * f / lsz.width, 0, p.roi.x * f, 0, p.roi.height * f / lsz.height, p.roi.y * f);
            cv::Mat a, b;
            cv::warpAffine(wiS, a, M, gsz, cv::INTER_LINEAR, cv::BORDER_CONSTANT);
            cv::warpAffine(wS, b, M, gsz, cv::INTER_LINEAR, cv::BORDER_CONSTANT);
            lpSum += a; lpW += b;
            w.release();
        }
        // Blended low band; grid cells with no weight (at the mosaic's edge) borrow from their neighbours.
        cv::Mat low8(gsz, CV_8UC3), holes(gsz, CV_8U);
        for (int y = 0; y < gsz.height; y++) {
            const float *a = lpSum.ptr<float>(y), *ww = lpW.ptr<float>(y);
            uchar *o = low8.ptr<uchar>(y), *hl = holes.ptr<uchar>(y);
            for (int x = 0; x < gsz.width; x++) {
                hl[x] = ww[x] > 1e-6f ? 0 : 255;
                for (int c = 0; c < 3; c++) o[3 * x + c] = ww[x] > 1e-6f ? cv::saturate_cast<uchar>(a[3 * x + c] / ww[x]) : 0;
            }
        }
        if (cv::countNonZero(holes) > 0) cv::inpaint(low8, holes, low8, 3, cv::INPAINT_TELEA);
        // Recombine in float precision: low band from the 8-bit grid is fine (it's smooth).
        cv::Mat lowUp;
        cv::resize(low8, lowUp, cv::Size((int)W, (int)Ht), 0, 0, cv::INTER_LINEAR);
        cv::parallel_for_(cv::Range(0, (int)Ht), [&](const cv::Range &rows) {
            for (int y = rows.start; y < rows.end; y++) {
                const uchar *l = lowUp.ptr<uchar>(y), *ow = owner.ptr<uchar>(y); const short *h = hp.ptr<short>(y);
                uchar *o = out.ptr<uchar>(y);
                for (int x = 0; x < W; x++) {
                    if (ow[x] == 255) continue;
                    for (int c = 0; c < 3; c++) o[3 * x + c] = cv::saturate_cast<uchar>((int)l[3 * x + c] + h[3 * x + c]);
                }
            }
        });
    } else {
        // Feather blend (the reference): weighted average.
        cv::Mat acc((int)Ht, (int)W, CV_32FC3, cv::Scalar::all(0)), wsum((int)Ht, (int)W, CV_32F, cv::Scalar(0));
        for (int i = 0; i < n; i++) {
            const Placed &p = placed[i];
            if (p.roi.empty()) continue;
            cv::Mat wimg;
            cv::warpPerspective(ims[i], wimg, p.H, p.roi.size());
            cv::Mat wt = weight(i);
            const float g0 = (float)gain[i][0], g1 = (float)gain[i][1], g2 = (float)gain[i][2];
            cv::parallel_for_(cv::Range(0, p.roi.height), [&](const cv::Range &rows) {
                for (int y = rows.start; y < rows.end; y++) {
                    const uchar *src = wimg.ptr<uchar>(y);
                    const float *d = wt.ptr<float>(y);
                    float *a = acc.ptr<float>(y + p.roi.y) + 3 * p.roi.x;
                    float *ws = wsum.ptr<float>(y + p.roi.y) + p.roi.x;
                    for (int x = 0; x < p.roi.width; x++) {
                        const float w = d[x];
                        if (w <= 0) continue;
                        a[3 * x + 0] += w * g0 * src[3 * x + 0];
                        a[3 * x + 1] += w * g1 * src[3 * x + 1];
                        a[3 * x + 2] += w * g2 * src[3 * x + 2];
                        ws[x] += w;
                    }
                }
            });
            ims[i].release();
        }
        cv::parallel_for_(cv::Range(0, (int)Ht), [&](const cv::Range &rows) {
            for (int y = rows.start; y < rows.end; y++) {
                const float *a = acc.ptr<float>(y), *ws = wsum.ptr<float>(y);
                uchar *o = out.ptr<uchar>(y);
                for (int x = 0; x < W; x++) {
                    if (ws[x] <= 0) continue;
                    const float inv = 1.0f / ws[x];
                    for (int c = 0; c < 3; c++) o[3 * x + c] = cv::saturate_cast<uchar>(a[3 * x + c] * inv);
                }
            }
        });
    }
    return imageFromMat(out);
}

// MARK: - Enhancement

/// Board background per channel: at 1/8 scale, max filter (removes strokes up to ~50 px of `im`) then blur.
static cv::Mat boardBackground(const cv::Mat &im) {
    const double f = 0.125;
    cv::Mat sm, bg;
    cv::resize(im, sm, cv::Size(), f, f, cv::INTER_AREA);
    cv::dilate(sm, bg, cv::Mat::ones(7, 7, CV_8U));
    cv::GaussianBlur(bg, bg, cv::Size(0, 0), 3);
    cv::resize(bg, bg, im.size(), 0, 0, cv::INTER_LINEAR);
    return bg;
}

+ (UIImage *)enhance:(UIImage *)image mode:(NSInteger)mode {
    cv::Mat im = matFromImage(image);
    if (im.empty() || mode == 0) return image;
    // Valid = not the black "no photo" area (holes from dark ink filled by closing).
    cv::Mat g, valid;
    cv::cvtColor(im, g, cv::COLOR_BGR2GRAY);
    cv::morphologyEx(g > 3, valid, cv::MORPH_CLOSE, cv::Mat::ones(15, 15, CV_8U));

    const cv::Mat bg = boardBackground(im);

    cv::Mat out(im.size(), CV_8UC3, cv::Scalar::all(0));
    const bool scan = mode == 2;
    cv::parallel_for_(cv::Range(0, im.rows), [&](const cv::Range &rows) {
        for (int y = rows.start; y < rows.end; y++) {
            const uchar *p = im.ptr<uchar>(y), *b = bg.ptr<uchar>(y), *v = valid.ptr<uchar>(y);
            uchar *o = out.ptr<uchar>(y);
            for (int x = 0; x < im.cols; x++) {
                if (!v[x]) continue;
                float c[3];
                for (int k = 0; k < 3; k++) c[k] = std::min(1.f, (float)p[3 * x + k] / std::max(16.f, (float)b[3 * x + k]));
                if (scan) {
                    // Gray, strong levels: board -> white, ink -> near black.
                    float l = 0.114f * c[0] + 0.587f * c[1] + 0.299f * c[2];
                    l = std::clamp((l - 0.45f) / (0.85f - 0.45f), 0.f, 1.f);
                    const uchar u = cv::saturate_cast<uchar>(255 * l * l * (3 - 2 * l));
                    o[3 * x] = o[3 * x + 1] = o[3 * x + 2] = u;
                } else {
                    // Colour: board -> white; gamma deepens and saturates ink.
                    for (int k = 0; k < 3; k++) {
                        const float t = std::clamp(c[k] / 0.88f, 0.f, 1.f);
                        o[3 * x + k] = cv::saturate_cast<uchar>(255 * std::pow(t, 1.8f));
                    }
                }
            }
        }
    });
    return imageFromMat(out);
}

// MARK: - Vanishing-point segments

+ (NSArray<NSNumber *> *)houghSegments:(UIImage *)image {
    cv::Mat im = matFromImage(image);
    if (im.empty()) return @[];
    const double s = 2000.0 / im.cols;
    cv::Mat sm, g, valid, blur, e;
    cv::resize(im, sm, cv::Size(), s, s, cv::INTER_AREA);
    im.release();
    cv::cvtColor(sm, g, cv::COLOR_BGR2GRAY);
    cv::erode(g > 8, valid, cv::Mat::ones(15, 15, CV_8U));
    cv::GaussianBlur(g, blur, cv::Size(0, 0), 1.5);
    cv::Canny(blur, e, 30, 90);
    e.setTo(0, valid == 0);
    std::vector<cv::Vec4i> segs;
    cv::HoughLinesP(e, segs, 1, CV_PI / 720, 60, 110, 12);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:segs.size() * 4];
    for (auto &l : segs)
        for (int k = 0; k < 4; k++) [out addObject:@(l[k] / s)];
    return out;
}

// MARK: - Warp, mask

+ (UIImage *)warp:(UIImage *)image homography:(NSArray<NSNumber *> *)homography width:(NSInteger)width height:(NSInteger)height {
    cv::Mat im = matFromImage(image);
    if (im.empty() || width <= 0 || height <= 0) return nil;
    cv::Mat out;
    cv::warpPerspective(im, out, matxFromArray(homography), cv::Size((int)width, (int)height), cv::INTER_CUBIC);
    return imageFromMat(out);
}

+ (NSData *)contentMask:(UIImage *)image scale:(double)f width:(NSInteger *)outWidth height:(NSInteger *)outHeight {
    *outWidth = 0; *outHeight = 0;
    cv::Mat im = matFromImage(image);
    if (im.empty()) return [NSData data];
    cv::Mat sm, g, m;
    cv::resize(im, sm, cv::Size(), f, f, cv::INTER_AREA);
    im.release();
    cv::cvtColor(sm, g, cv::COLOR_BGR2GRAY);
    cv::morphologyEx(g > 3, m, cv::MORPH_CLOSE, cv::Mat::ones(15, 15, CV_8U));  // 0 / 255
    // Flood the outside from a 1px border of "invalid" so holes enclosed by valid pixels (ink) are filled,
    // even when the image corner itself is valid.
    cv::Mat inv;
    cv::copyMakeBorder(m == 0, inv, 1, 1, 1, 1, cv::BORDER_CONSTANT, cv::Scalar(255));
    cv::floodFill(inv, cv::Point(0, 0), cv::Scalar(128));
    cv::Mat filled = inv(cv::Rect(1, 1, m.cols, m.rows)) != 128;
    cv::Mat er;
    cv::erode(filled, er, cv::Mat::ones(5, 5, CV_8U));
    cv::Mat bytes = er / 255;
    if (!bytes.isContinuous()) bytes = bytes.clone();
    *outWidth = bytes.cols; *outHeight = bytes.rows;
    return [NSData dataWithBytes:bytes.data length:bytes.total()];
}

// MARK: - Content

+ (CGRect)contentRect:(UIImage *)image margin:(double)margin {
    const CGRect whole = CGRectMake(0, 0, image.size.width * image.scale, image.size.height * image.scale);
    cv::Mat full = matFromImage(image);
    if (full.empty()) return whole;
    const double s = std::min(1.0, 1600.0 / std::max(full.cols, full.rows));
    cv::Mat im, g, valid;
    cv::resize(full, im, cv::Size(), s, s, cv::INTER_AREA);
    full.release();
    cv::cvtColor(im, g, cv::COLOR_BGR2GRAY);
    cv::erode(g > 3, valid, cv::Mat::ones(5, 5, CV_8U));
    const cv::Mat bg = boardBackground(im);

    // Ink: some channel at least 25% darker than the local board (as Whiten sees it; glare is brighter, so not ink).
    cv::Mat ink(im.size(), CV_8U, cv::Scalar(0));
    for (int y = 0; y < im.rows; y++) {
        const uchar *p = im.ptr<uchar>(y), *b = bg.ptr<uchar>(y), *v = valid.ptr<uchar>(y);
        uchar *o = ink.ptr<uchar>(y);
        for (int x = 0; x < im.cols; x++) {
            if (!v[x]) continue;
            float r = 1;
            for (int c = 0; c < 3; c++) r = std::min(r, (float)p[3 * x + c] / std::max(16.f, (float)b[3 * x + c]));
            if (r < 0.75f) o[x] = 255;
        }
    }
    // Join strokes into words/blobs, then drop dust (tiny blobs) and long edge strips (leftover frame/wall).
    cv::Mat joined, labels, stats, centroids;
    cv::dilate(ink, joined, cv::Mat::ones(5, 5, CV_8U));
    const int n = cv::connectedComponentsWithStats(joined, labels, stats, centroids, 8);
    const double minArea = 1e-5 * im.total() + 40;
    int x0 = INT_MAX, y0 = INT_MAX, x1 = -1, y1 = -1;
    for (int i = 1; i < n; i++) {
        const int l = stats.at<int>(i, cv::CC_STAT_LEFT), t = stats.at<int>(i, cv::CC_STAT_TOP);
        const int w = stats.at<int>(i, cv::CC_STAT_WIDTH), h = stats.at<int>(i, cv::CC_STAT_HEIGHT);
        if (stats.at<int>(i, cv::CC_STAT_AREA) < minArea) continue;
        const bool touches = l <= 1 || t <= 1 || l + w >= im.cols - 1 || t + h >= im.rows - 1;
        if (touches && (w > 0.5 * im.cols || h > 0.5 * im.rows)) continue;
        x0 = std::min(x0, l); y0 = std::min(y0, t); x1 = std::max(x1, l + w); y1 = std::max(y1, t + h);
    }
    if (x1 < 0) return whole;
    const double m = margin * std::max(im.cols, im.rows);
    CGRect r = CGRectMake((x0 - m) / s, (y0 - m) / s, (x1 - x0 + 2 * m) / s, (y1 - y0 + 2 * m) / s);
    return CGRectIntegral(CGRectIntersection(r, whole));
}

// MARK: - Board frame

+ (NSData *)boardDistance:(UIImage *)image maxWidth:(NSInteger)maxWidth width:(NSInteger *)outWidth
                   height:(NSInteger *)outHeight scale:(double *)outScale {
    *outWidth = 0; *outHeight = 0; *outScale = 1;
    cv::Mat im = matFromImage(image);
    if (im.empty()) return [NSData data];
    const double s = std::min(1.0, (double)maxWidth / im.cols);
    cv::Mat sm, lab, g, valid;
    cv::resize(im, sm, cv::Size(), s, s, cv::INTER_AREA);
    im.release();
    cv::cvtColor(sm, g, cv::COLOR_BGR2GRAY);
    cv::erode(g > 3, valid, cv::Mat::ones(5, 5, CV_8U));
    cv::cvtColor(sm, lab, cv::COLOR_BGR2Lab);
    // Board colour: per-channel median of the valid central 40% (ink is sparse, so the median is the surface).
    const cv::Rect centre(sm.cols * 3 / 10, sm.rows * 3 / 10, std::max(1, sm.cols * 2 / 5), std::max(1, sm.rows * 2 / 5));
    cv::Mat cm = valid(centre);
    if (cv::countNonZero(cm) < 100) return [NSData data];
    std::vector<uchar> ch[3];
    for (int y = centre.y; y < centre.y + centre.height; y++) {
        const uchar *p = lab.ptr<uchar>(y), *v = valid.ptr<uchar>(y);
        for (int x = centre.x; x < centre.x + centre.width; x++) if (v[x]) for (int c = 0; c < 3; c++) ch[c].push_back(p[3 * x + c]);
    }
    float board[3];
    for (int c = 0; c < 3; c++) {
        std::nth_element(ch[c].begin(), ch[c].begin() + ch[c].size() / 2, ch[c].end());
        board[c] = ch[c][ch[c].size() / 2];
    }
    cv::Mat d(sm.size(), CV_8U);
    for (int y = 0; y < sm.rows; y++) {
        const uchar *p = lab.ptr<uchar>(y), *v = valid.ptr<uchar>(y);
        uchar *o = d.ptr<uchar>(y);
        for (int x = 0; x < sm.cols; x++) {
            if (!v[x]) { o[x] = 255; continue; }
            const float dl = std::max(0.f, board[0] - p[3 * x]), da = p[3 * x + 1] - board[1], db = p[3 * x + 2] - board[2];
            o[x] = (uchar)std::min(254.f, std::sqrt(dl * dl + da * da + db * db));
        }
    }
    *outWidth = d.cols; *outHeight = d.rows; *outScale = s;
    return [NSData dataWithBytes:d.data length:d.total()];
}

// MARK: - Motion

+ (NSData *)smallLuma:(CVPixelBufferRef)pb maxWidth:(NSInteger)maxWidth width:(NSInteger *)outWidth height:(NSInteger *)outHeight {
    *outWidth = 0; *outHeight = 0;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    NSData *out = [NSData data];
    if (CVPixelBufferGetPlaneCount(pb) > 0) {
        cv::Mat y((int)CVPixelBufferGetHeightOfPlane(pb, 0), (int)CVPixelBufferGetWidthOfPlane(pb, 0), CV_8U,
                  CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 0));
        const double s = std::min(1.0, (double)maxWidth / y.cols);
        cv::Mat sm;
        cv::resize(y, sm, cv::Size(std::max(1, (int)std::lround(y.cols * s)), std::max(1, (int)std::lround(y.rows * s))), 0, 0, cv::INTER_AREA);
        *outWidth = sm.cols; *outHeight = sm.rows;
        out = [NSData dataWithBytes:sm.data length:sm.total()];
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return out;
}

+ (CGPoint)shiftGrayFrom:(NSData *)reference to:(NSData *)image width:(NSInteger)width height:(NSInteger)height
                response:(double *)response {
    *response = 0;
    if (reference.length != (NSUInteger)(width * height) || image.length != reference.length || width < 8 || height < 8) return CGPointZero;
    cv::Mat a((int)height, (int)width, CV_8U, (void *)reference.bytes), b((int)height, (int)width, CV_8U, (void *)image.bytes);
    cv::Mat fa, fb, win;
    a.convertTo(fa, CV_64F); b.convertTo(fb, CV_64F);
    cv::createHanningWindow(win, fa.size(), CV_64F);
    double r = 0;
    cv::Point2d d = cv::phaseCorrelate(fa, fb, win, &r);
    *response = r;
    return CGPointMake(d.x, d.y);
}

+ (CGPoint)shiftFrom:(UIImage *)reference to:(UIImage *)image response:(double *)response {
    *response = 0;
    cv::Mat a = matFromImage(reference), b = matFromImage(image);
    if (a.empty() || b.empty() || a.size() != b.size()) return CGPointZero;
    cv::Mat ga, gb;
    cv::cvtColor(a, ga, cv::COLOR_BGR2GRAY); ga.convertTo(ga, CV_64F);
    cv::cvtColor(b, gb, cv::COLOR_BGR2GRAY); gb.convertTo(gb, CV_64F);
    cv::Mat win;
    cv::createHanningWindow(win, ga.size(), CV_64F);
    double r = 0;
    cv::Point2d d = cv::phaseCorrelate(ga, gb, win, &r);
    *response = r;
    return CGPointMake(d.x, d.y);
}

@end
