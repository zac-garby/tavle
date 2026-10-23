#!/usr/bin/env python3
"""Reference implementation (Python + OpenCV) of the whiteboard pipeline.
Port this to the iOS app. Usage:
    python3 whiteboard_pipeline.py OUT_DIR left.jpg middle.jpg right.jpg   # photos LEFT->RIGHT
Outputs in OUT_DIR: stitched.jpg, flat_full.jpg, flat_cropped.jpg
Stages: 1 register (pairwise, to middle frame)  2 blend  3 find vanishing points
        4 rectify (metric-ish, centre-preserving)  5 crop
"""
import sys, os, random
import cv2, numpy as np

def prep(im):
    g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY)
    return cv2.createCLAHE(3.0, (8, 8)).apply(g)

# ---------- 1. registration ----------
def register_pair(a, b):
    """a is the LEFT image, b the RIGHT one. Return 3x3 matrix mapping b -> a. Tries full-image SIFT+homography; if weak
    (thin overlap), retries on overlap strips with a rigid similarity (4 DoF)."""
    sift = cv2.SIFT_create(8000, contrastThreshold=0.02)
    ka, da = sift.detectAndCompute(prep(a), None)
    kb, db = sift.detectAndCompute(prep(b), None)
    m = cv2.BFMatcher().knnMatch(db, da, k=2)
    good = [x for x, y in m if x.distance < 0.75 * y.distance]
    src = np.float32([kb[x.queryIdx].pt for x in good]); dst = np.float32([ka[x.trainIdx].pt for x in good])
    if len(good) >= 8:
        Hm, mk = cv2.findHomography(src, dst, cv2.RANSAC, 4.0)
        if Hm is not None and mk.sum() >= 200:
            print(f"  homography, {int(mk.sum())} inliers"); return Hm
    # fallback: thin overlap -> restrict to strips, similarity transform
    h, w = a.shape[:2]
    ma = np.zeros(a.shape[:2], np.uint8); ma[:, int(w * 0.45):] = 255   # right of a
    mb = np.zeros(b.shape[:2], np.uint8); mb[:, :int(w * 0.30)] = 255   # left of b
    ka, da = sift.detectAndCompute(prep(a), ma); kb, db = sift.detectAndCompute(prep(b), mb)
    m = cv2.BFMatcher().knnMatch(db, da, k=2)
    good = [x for x, y in m if x.distance < 0.8 * y.distance]
    src = np.float32([kb[x.queryIdx].pt for x in good]); dst = np.float32([ka[x.trainIdx].pt for x in good])
    A, mk = cv2.estimateAffinePartial2D(src, dst, ransacReprojThreshold=4)
    print(f"  similarity (thin overlap), {int(mk.sum())} inliers  <- LOW CONFIDENCE, warn user")
    return np.vstack([A, [0, 0, 1]])

def stitch(imgs):
    mid = len(imgs) // 2
    Hs = [None] * len(imgs); Hs[mid] = np.eye(3)
    for i in range(mid - 1, -1, -1):      # leftwards: img i -> img i+1 -> ... -> mid
        Hs[i] = Hs[i + 1] @ np.linalg.inv(register_pair(imgs[i], imgs[i + 1]))
    for i in range(mid + 1, len(imgs)):   # rightwards
        Hs[i] = Hs[i - 1] @ register_pair(imgs[i - 1], imgs[i])
    cs = []
    for im, Hm in zip(imgs, Hs):
        h, w = im.shape[:2]
        cs.append(cv2.perspectiveTransform(np.float32([[0, 0], [w, 0], [w, h], [0, h]]).reshape(-1, 1, 2), Hm))
    allc = np.vstack(cs).reshape(-1, 2); mn = allc.min(0); mx = allc.max(0)
    T = np.array([[1, 0, -mn[0]], [0, 1, -mn[1]], [0, 0, 1]], float)
    W, Ht = int(mx[0] - mn[0]), int(mx[1] - mn[1])
    ws, ds, ms = [], [], []
    for im, Hm in zip(imgs, Hs):
        ws.append(cv2.warpPerspective(im, T @ Hm, (W, Ht)).astype(np.float32))
        mk = cv2.warpPerspective(np.full(im.shape[:2], 255, np.uint8), T @ Hm, (W, Ht)); ms.append(mk)
        ds.append(cv2.distanceTransform(mk, cv2.DIST_L2, 5))
    for k in range(len(imgs)):            # crude gain match to the middle image
        if k == mid: continue
        ov = (ms[k] > 0) & (ms[mid] > 0)
        if ov.sum() > 1000:
            for c in range(3): ws[k][..., c] *= ws[mid][..., c][ov].mean() / ws[k][..., c][ov].mean()
    wsum = sum(ds) + 1e-6
    out = sum(w_ * d_[..., None] for w_, d_ in zip(ws, ds)) / wsum[..., None]
    return np.clip(out, 0, 255).astype(np.uint8)

# ---------- 2. vanishing points ----------
def _ransac_vp(ls, tol=0.6, n=4000):
    L = [np.cross([l[0], l[1], 1.], [l[2], l[3], 1.]) for l in ls]
    lens = np.array([np.hypot(l[2] - l[0], l[3] - l[1]) for l in ls])
    mids = np.array([[(l[0] + l[2]) / 2, (l[1] + l[3]) / 2] for l in ls])
    dirs = np.array([[l[2] - l[0], l[3] - l[1]] for l in ls], float); dirs /= np.linalg.norm(dirs, axis=1)[:, None]
    rng = random.Random(1); best = (None, 0)
    for _ in range(n):
        i, j = rng.sample(range(len(ls)), 2); v = np.cross(L[i], L[j])
        vp = v[:2] / v[2] if abs(v[2]) > 1e-9 else v[:2] * 1e9
        d = vp - mids; d /= np.linalg.norm(d, axis=1)[:, None] + 1e-9
        err = np.degrees(np.arccos(np.clip(np.abs((d * dirs).sum(1)), 0, 1)))
        sc = lens[err < tol].sum()
        if sc > best[1]: best = (vp, sc)
    return best[0]

def find_vps(im):
    """Vertical VP from frame edges / hand-drawn dividers; horizontal VP from text baselines,
    underlines and the frame top. Works on a 2000px-wide copy. Returns (v, h) in full-res coords."""
    s = 2000 / im.shape[1]
    sm = cv2.resize(im, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    g = cv2.cvtColor(sm, cv2.COLOR_BGR2GRAY)
    valid = cv2.erode((g > 8).astype(np.uint8), np.ones((15, 15))) > 0
    e = cv2.Canny(cv2.GaussianBlur(g, (0, 0), 1.5), 30, 90); e[~valid] = 0
    segs = cv2.HoughLinesP(e, 1, np.pi / 720, 60, minLineLength=110, maxLineGap=12).reshape(-1, 4)
    ang = lambda l: np.degrees(np.arctan2(l[3] - l[1], l[2] - l[0])) % 180
    vert = [l for l in segs if 60 < ang(l) < 120]; hor = [l for l in segs if ang(l) < 30 or ang(l) > 150]
    return _ransac_vp(vert) / s, _ransac_vp(hor) / s

# ---------- 3. rectify ----------
def rectify(im):
    H, W = im.shape[:2]; v, h = find_vps(im)
    c = np.array([W / 2, H / 2]); Tc = np.array([[1, 0, -c[0]], [0, 1, -c[1]], [0, 0, 1]])
    vc, hc = Tc @ np.append(v, 1.), Tc @ np.append(h, 1.)
    l = np.cross(vc, hc); l /= np.linalg.norm(l[:2])
    H1 = np.array([[1, 0, 0], [0, 1, 0], [l[0], l[1], l[2]]])          # send horizon to infinity
    def direction(p, ref):
        q = (H1 @ p)[:2]; q = q / np.linalg.norm(q); return q if q @ ref > 0 else -q
    dh, dv = direction(hc, np.array([1., 0])), direction(vc, np.array([0, 1.]))
    A = np.eye(3); A[:2, :2] = np.linalg.inv(np.column_stack([dh, dv]))   # make directions axis-aligned
    Hr = A @ H1 @ Tc
    f = lambda x, y: (lambda q: q[:2] / q[2])(Hr @ np.array([x, y, 1.]))
    p0 = f(*c); jx = f(c[0] + 1, c[1]) - p0; jy = f(c[0], c[1] + 1) - p0
    Hr = np.diag([1 / abs(jx[0]), 1 / abs(jy[1]), 1]) @ Hr              # keep centre at original scale
    corn = np.float32([[0, 0], [W, 0], [W, H], [0, H]]).reshape(-1, 1, 2)
    pc = cv2.perspectiveTransform(corn, Hr).reshape(-1, 2); mn = pc.min(0); mx = pc.max(0)
    T = np.array([[1, 0, -mn[0]], [0, 1, -mn[1]], [0, 0, 1]])
    return cv2.warpPerspective(im, T @ Hr, (int(mx[0] - mn[0]), int(mx[1] - mn[1])), flags=cv2.INTER_CUBIC)

# ---------- 4. crop ----------
def content_mask(im, f=0.25):
    g = cv2.cvtColor(cv2.resize(im, None, fx=f, fy=f, interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
    m = cv2.morphologyEx((g > 3).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    inv = 1 - m; ff = inv.copy(); cv2.floodFill(ff, np.zeros((m.shape[0] + 2, m.shape[1] + 2), np.uint8), (0, 0), 2)
    return cv2.erode((ff != 2).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0   # holes (ink) filled

def largest_rect(m):
    h, w = m.shape; hs = np.zeros(w, int); best = (0, 0, 0, 0, 0)
    for y in range(h):
        hs = np.where(m[y], hs + 1, 0); st = []
        for x in range(w + 1):
            cur = hs[x] if x < w else 0; start = x
            while st and st[-1][1] >= cur:
                sx, sh = st.pop()
                if sh * (x - sx) > best[0]: best = (sh * (x - sx), sx, y - sh + 1, x, y + 1)
                start = sx
            st.append((start, cur))
    return best[1:]

def crops(im, f=0.25):
    m = content_mask(im, f); x0, y0, x1, y1 = [int(v / f) for v in largest_rect(m)]
    ys, xs = np.where(m); bx = [int(v / f) for v in (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)]
    return im[bx[1]:bx[3], bx[0]:bx[2]], im[y0:y1, x0:x1]

if __name__ == "__main__":
    out_dir, paths = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    imgs = [cv2.imread(p) for p in paths]
    st = stitch(imgs); cv2.imwrite(f"{out_dir}/stitched.jpg", st)
    flat = rectify(st); full, tidy = crops(flat)
    cv2.imwrite(f"{out_dir}/flat_full.jpg", full); cv2.imwrite(f"{out_dir}/flat_cropped.jpg", tidy)
    print("done", full.shape, tidy.shape)
