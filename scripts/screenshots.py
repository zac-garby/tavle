#!/usr/bin/env python3
"""App Store screenshots from real whiteboard photos.

  scripts/screenshots.py                       # build, flatten screenshots/boards/*, shoot, frame
  scripts/screenshots.py --reuse               # skip building and flattening (just reshoot + reframe)
  scripts/screenshots.py --frame-only          # only redo the captions/frames from screenshots/raw
  SIM="iPad Pro 13-inch (M5)" scripts/screenshots.py

Inputs (see Sources/Whiteboard/UI/Screenshots.swift for the folder format):
  screenshots/boards/<NN Title>/   photos (or a guided scan copied off the phone), optional look.json
  screenshots/boards/capture.jpg   optional: the camera view behind the capture screen
  screenshots/shots.json           which screens to take, in App Store order, with captions
Outputs: screenshots/raw/<device>/<name>.png (straight from the simulator) and
         screenshots/appstore/<device>/<NN>-<name>.png (captioned, at the simulator's native size).
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = "uk.co.zacgarby.whiteboard-scan"
DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/Whiteboard-screenshots"   # not under ~/Desktop (xattrs break codesign)


def run(*cmd, check=True, quiet=False, **kw):
    if not quiet:
        print("$", " ".join(map(str, cmd)), flush=True)
    return subprocess.run(list(map(str, cmd)), check=check, text=True, capture_output=quiet, **kw)


def simulator(name):
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", quiet=True).stdout)["devices"]
    matches = [(rt, d) for rt, ds in devices.items() for d in ds if d["name"] == name]
    if not matches:
        sys.exit(f"No simulator called {name!r} (xcrun simctl list devices available)")
    return sorted(matches)[-1][1]["udid"]   # newest runtime


def build(udid):
    env = {k: v for k, v in os.environ.items() if k not in ("LIBRARY_PATH", "CPATH")}
    run("xcodegen", "generate", cwd=ROOT, env=env)
    run("xcodebuild", "-project", ROOT / "Whiteboard.xcodeproj", "-scheme", "Whiteboard", "-configuration", "Debug",
        "-destination", f"id={udid}", "-derivedDataPath", DERIVED, "-quiet", "build", env=env)
    return DERIVED / "Build/Products/Debug-iphonesimulator/Whiteboard.app"


def container(udid):
    return Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data", quiet=True).stdout.strip())


def launch(udid, boards, *args):
    run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE, "-WBShots", boards, *args, quiet=True)


def shoot(udid, boards, shots, raw_dir, rebuild):
    if rebuild:
        print("Flattening the boards (a few seconds per board)…", flush=True)
        launch(udid, boards, "-WBShotsRebuild", "YES")
        ready = container(udid) / "Library/Application Support/Screenshots/ready"
        deadline = time.time() + 900
        while not ready.exists():
            if time.time() > deadline:
                sys.exit("Timed out waiting for the boards to flatten")
            time.sleep(1)
    raw_dir.mkdir(parents=True, exist_ok=True)
    for s in shots:
        args = ["-WBScene", s["scene"], "-WBOpen", str(s.get("open", 0))] + s.get("args", [])
        launch(udid, boards, *args)
        time.sleep(s.get("settle", 4))
        out = raw_dir / f"{s['name']}.png"
        run("xcrun", "simctl", "io", udid, "screenshot", "--type=png", out, quiet=True)
        print("  shot", out.relative_to(ROOT), flush=True)


# ---- framing ---------------------------------------------------------------------------------------------------

ACCENT = (166, 227, 176)   # Theme.accent
BACKGROUND = (12, 13, 12)


def font(size, weight="Bold"):
    from PIL import ImageFont
    for path in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            f = ImageFont.truetype(path, size)
            try:
                f.set_variation_by_name(weight)
            except Exception:
                pass
            return f
        except OSError:
            continue
    return ImageFont.load_default(size)


def wrap(draw, text, f, width):
    lines = []
    for para in text.split("\n"):
        line = ""
        for word in para.split():
            trial = f"{line} {word}".strip()
            if draw.textlength(trial, font=f) <= width or not line:
                line = trial
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def frame(raw_path, shot, out_path):
    """Caption on top, the screenshot below in a thin bezel that runs off the bottom edge."""
    from PIL import Image, ImageDraw
    shot_img = Image.open(raw_path).convert("RGB")
    W, H = shot_img.size
    u = W / 1320                                        # design units: an iPhone 6.9" canvas
    canvas = Image.new("RGB", (W, H), BACKGROUND)
    d = ImageDraw.Draw(canvas)

    # soft green glow behind the device
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([W * 0.05, H * 0.30, W * 0.95, H * 1.15], fill=60)
    from PIL import ImageFilter
    glow = glow.filter(ImageFilter.GaussianBlur(220 * u))
    canvas = Image.composite(Image.new("RGB", (W, H), ACCENT), canvas, glow.point(lambda v: v * 0.35))
    d = ImageDraw.Draw(canvas)

    margin = 96 * u
    y = 150 * u
    title_f, sub_f = font(int(104 * u), "Bold"), font(int(50 * u), "Medium")
    for line in wrap(d, shot["caption"], title_f, W - 2 * margin):
        d.text((W / 2, y), line, font=title_f, fill="white", anchor="ma")
        y += 118 * u
    if shot.get("subcaption"):
        y += 22 * u
        for line in wrap(d, shot["subcaption"], sub_f, W - 2 * margin):
            d.text((W / 2, y), line, font=sub_f, fill=ACCENT, anchor="ma")
            y += 64 * u
    top = max(y + 70 * u, 560 * u)

    # the screenshot, scaled into a phone-shaped bezel
    sw = int(W * (0.80 if W < H else 0.86))
    sh = int(H * sw / W)
    screen = shot_img.resize((sw, sh), Image.LANCZOS)
    radius = int(sw * 0.115) if W < H else int(sw * 0.04)
    bezel = int(16 * u)
    x0 = (W - sw) // 2
    y0 = int(top)
    d.rounded_rectangle([x0 - bezel, y0 - bezel, x0 + sw + bezel, y0 + sh + bezel], radius=radius + bezel, fill=(28, 30, 29),
                        outline=(70, 74, 72), width=max(2, int(3 * u)))
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=radius, fill=255)
    canvas.paste(screen, (x0, y0), mask)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_path)
    print("  framed", out_path.relative_to(ROOT), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--boards", default=ROOT / "screenshots/boards", type=Path)
    ap.add_argument("--shots", default=ROOT / "screenshots/shots.json", type=Path)
    ap.add_argument("--sim", default=os.environ.get("SIM", "iPhone 17 Pro Max"))
    ap.add_argument("--reuse", action="store_true", help="don't rebuild the app or reflatten the boards")
    ap.add_argument("--frame-only", action="store_true", help="only recaption the existing raw screenshots")
    ap.add_argument("--only", nargs="*", help="shot names to (re)take")
    a = ap.parse_args()

    shots = json.loads(a.shots.read_text())
    if a.only:
        shots = [s for s in shots if s["name"] in a.only]
    device = a.sim.replace(" ", "-").replace("(", "").replace(")", "")
    raw_dir = ROOT / "screenshots/raw" / device
    out_dir = ROOT / "screenshots/appstore" / device

    if not a.frame_only:
        udid = simulator(a.sim)
        run("xcrun", "simctl", "boot", udid, check=False, quiet=True)
        run("xcrun", "simctl", "bootstatus", udid, "-b", quiet=True)
        run("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
            "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100")
        if not a.reuse:
            run("xcrun", "simctl", "install", udid, build(udid))
        shoot(udid, a.boards.resolve(), shots, raw_dir, rebuild=not a.reuse)

    all_shots = json.loads(a.shots.read_text())
    for i, s in enumerate(all_shots, 1):
        if a.only and s["name"] not in a.only:
            continue
        raw = raw_dir / f"{s['name']}.png"
        if raw.exists():
            frame(raw, s, out_dir / f"{i:02d}-{s['name']}.png")


if __name__ == "__main__":
    main()
