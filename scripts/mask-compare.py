#!/usr/bin/env python3
"""マスクの作り方（restore --mask / --mask-image）を並べて、目で比べる動画を作る。

ROI の周りを切り出して拡大し、横に「入力 | 設定ごとの出力 | 正解（あれば）」を並べる。正解を渡すと、下の段に
正解との差（|差| x 4）も並べる。縁の残像・ぼけは止めて、ちらつきは再生して見る。

使い方:
  scripts/mask-compare.py [--truth 正解.mkv] [--frames N] [--scale S] [--vrestore PATH]
                          --variant "名前=restore の引数" [--variant ...] <video> <x,y,w,h> <out.mp4>
  例: --variant "auto=--mask auto --fill harmonic" --variant "gradient=--mask-image grad.png --fill harmonic"
正解は、入力と同じフレームから始まる可逆の動画（scripts/restore-real.sh の orig.mkv など）。
⚠ 出力は tmp/ の下に置く（CLAUDE.md §4）。実素材の動画もフレームもコミットしない。PIL と numpy が要る。CI では回さない。
"""
import argparse, json, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SWS = ["-fps_mode", "passthrough", "-sws_flags", "bicubic+accurate_rnd+full_chroma_int+full_chroma_inp"]


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate",
                          "-of", "json", path], capture_output=True, check=True).stdout
    s = json.loads(out)["streams"][0]
    return s["width"], s["height"], s["r_frame_rate"]


def decode(path, w, h, n):
    b = subprocess.run(["ffmpeg", "-v", "error", "-i", path, *SWS, "-frames:v", str(n), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                       capture_output=True, check=True).stdout
    return np.frombuffer(b, np.uint8).reshape(-1, h, w, 3)


def font(size):
    for p in ["/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("rect")
    ap.add_argument("out")
    ap.add_argument("--truth")
    ap.add_argument("--frames", type=int, default=150)
    ap.add_argument("--scale", type=int, default=3)
    ap.add_argument("--margin", type=int, default=12, help="ROI の周りに何 px 見せるか")
    ap.add_argument("--variant", action="append", required=True, help="名前=restore の引数（--rect と出力は付ける）")
    ap.add_argument("--vrestore", default="zig-out/bin/vrestore")
    a = ap.parse_args()
    x, y, rw, rh = map(int, a.rect.split(","))
    W, H, fps = probe(a.video)

    cols = [("input", decode(a.video, W, H, a.frames))]
    n = cols[0][1].shape[0]
    with tempfile.TemporaryDirectory() as td:
        for v in a.variant:
            name, args = v.split("=", 1)
            raw = os.path.join(td, "o.rgb")
            r = subprocess.run([a.vrestore, "restore", "--rect", a.rect, "--frames", str(n), *args.split(), "--raw", raw, a.video],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit("vrestore restore (%s) failed: %s" % (name, r.stderr.strip()))
            s = json.loads(r.stdout)
            print("%-10s mask %s  mask_fraction %s" % (name, s.get("mask"), s.get("mask_fraction")), file=sys.stderr)
            cols.append((name, np.fromfile(raw, np.uint8).reshape(-1, H, W, 3)[:n]))
    truth = decode(a.truth, W, H, n) if a.truth else None
    if truth is not None:
        cols.append(("truth", truth))
    n = min(c[1].shape[0] for c in cols)

    m = a.margin
    x0, y0, x1, y1 = max(0, x - m), max(0, y - m), min(W, x + rw + m), min(H, y + rh + m)
    cw, ch = (x1 - x0) * a.scale, (y1 - y0) * a.scale
    label_h = 18
    rows = 2 if truth is not None else 1
    fw, fh = cw * len(cols), (ch + label_h) * rows
    fw += fw % 2
    fh += fh % 2
    f = font(13)
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (fw, fh), "-r", fps, "-i", "-",
                            "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", a.out], stdin=subprocess.PIPE)
    for t in range(n):
        canvas = Image.new("RGB", (fw, fh), (0, 0, 0))
        d = ImageDraw.Draw(canvas)
        for i, (name, v) in enumerate(cols):
            crop = v[t, y0:y1, x0:x1]
            img = Image.fromarray(crop).resize((cw, ch), Image.NEAREST)
            canvas.paste(img, (i * cw, label_h))
            d.text((i * cw + 4, 2), "%s  #%d" % (name, t) if i == 0 else name, fill=(255, 255, 255), font=f)
            # ROI の枠（細い線）
            d.rectangle([i * cw + (x - x0) * a.scale, label_h + (y - y0) * a.scale, i * cw + (x - x0 + rw) * a.scale - 1, label_h + (y - y0 + rh) * a.scale - 1], outline=(0, 200, 230))
            if truth is not None:
                err = np.abs(crop.astype(np.int16) - truth[t, y0:y1, x0:x1].astype(np.int16)).max(axis=2)
                e8 = np.clip(err * 4, 0, 255).astype(np.uint8)
                heat = np.stack([e8, e8, e8], axis=2)
                canvas.paste(Image.fromarray(heat).resize((cw, ch), Image.NEAREST), (i * cw, ch + 2 * label_h))
                d.text((i * cw + 4, ch + label_h + 2), "|diff| x4  mean %.1f" % err.mean(), fill=(255, 255, 255), font=f)
        enc.stdin.write(canvas.tobytes())
    enc.stdin.close()
    enc.wait()
    print(a.out, file=sys.stderr)


main()
