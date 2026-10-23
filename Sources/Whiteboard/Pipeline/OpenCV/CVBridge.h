#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ wrappers over the OpenCV calls in reference/whiteboard_pipeline.py.
/// Only image-heavy work lives here; geometry and decisions are in Swift (Geometry.swift, OpenCVBackend.swift).
/// All images are expected `.up`-oriented with scale 1 (see UIImage.normalized).

@interface CVPairRegistration : NSObject
/// 3x3 row-major, maps the RIGHT image into the LEFT image's pixel coordinates.
@property (nonatomic, copy) NSArray<NSNumber *> *matrix;
@property (nonatomic) NSInteger inliers;
/// YES: full-image SIFT + homography. NO: thin-overlap fallback (strips + similarity).
@property (nonatomic) BOOL isHomography;
@end

@interface CVBridge : NSObject

/// `register_pair`. Nil if neither method produced a transform.
+ (nullable CVPairRegistration *)registerLeft:(UIImage *)left
                                        right:(UIImage *)right
                         minHomographyInliers:(NSInteger)minInliers;

/// Warp each image by its homography (row-major 3x3, image -> canvas) into a width x height canvas, gain-match
/// each image to its neighbour towards `middle`, and blend. Weights are distance-to-border (feathering) times,
/// with `reduceGlare`, a penalty where a frame is brighter than the others over plain board. `multiBand`: two-band
/// blend (low frequencies averaged with those weights, fine detail from the highest-weight frame per pixel);
/// otherwise a weighted average of everything (the reference's feathering).
+ (nullable UIImage *)blendImages:(NSArray<UIImage *> *)images
                     homographies:(NSArray<NSArray<NSNumber *> *> *)homographies
                            width:(NSInteger)width
                           height:(NSInteger)height
                           middle:(NSInteger)middle
                      reduceGlare:(BOOL)reduceGlare
                        multiBand:(BOOL)multiBand;

/// Background whitening. mode 0: unchanged, 1: white board + crisp colour ink, 2: black & white "scan".
/// Black (no-photo) areas stay black.
+ (UIImage *)enhance:(UIImage *)image mode:(NSInteger)mode;

/// Hough segments of `find_vps`, as flat [x1, y1, x2, y2, ...] in `image` pixel coordinates.
+ (NSArray<NSNumber *> *)houghSegments:(UIImage *)image;

/// warpPerspective with bicubic interpolation, black outside.
+ (nullable UIImage *)warp:(UIImage *)image
                homography:(NSArray<NSNumber *> *)homography
                     width:(NSInteger)width
                    height:(NSInteger)height;

/// `content_mask`: valid-pixel mask at `scale` with holes (ink) filled. One byte per pixel (0 / 1), row-major.
+ (NSData *)contentMask:(UIImage *)image
                  scale:(double)scale
                  width:(NSInteger *)outWidth
                 height:(NSInteger *)outHeight;

/// Bounding box of the writing (ink as the Whiten enhancement sees it: darker than the local board), ignoring
/// dust and long strips along the image edges, grown by `margin` × the long side. Whole image if no ink.
+ (CGRect)contentRect:(UIImage *)image margin:(double)margin;

/// Per-pixel "how unlike the board surface" map on a copy at most `maxWidth` wide (scale returned): Lab distance
/// from the board colour (median of the central region), counting only darker / more coloured, never brighter
/// (glare). 0..254; 255 = no photo there. Row-major, one byte per pixel.
+ (NSData *)boardDistance:(UIImage *)image
                 maxWidth:(NSInteger)maxWidth
                    width:(NSInteger *)outWidth
                   height:(NSInteger *)outHeight
                    scale:(double *)outScale;

/// Luma plane of a bi-planar camera buffer, area-downscaled to at most `maxWidth` wide (8-bit, row-major).
+ (NSData *)smallLuma:(CVPixelBufferRef)buffer maxWidth:(NSInteger)maxWidth width:(NSInteger *)outWidth height:(NSInteger *)outHeight;

/// Phase-correlation shift of `image` relative to `reference`, both 8-bit gray `width` x `height`.
+ (CGPoint)shiftGrayFrom:(NSData *)reference to:(NSData *)image width:(NSInteger)width height:(NSInteger)height
                response:(double *)response;

/// Translation of `image`'s content relative to `reference` (phase correlation on grayscale, Hann window), in
/// pixels of these images. `response` (0..1) is the peak strength; low means unreliable.
+ (CGPoint)shiftFrom:(UIImage *)reference to:(UIImage *)image response:(double *)response;

@end

NS_ASSUME_NONNULL_END
