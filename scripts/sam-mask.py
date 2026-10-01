#!/usr/bin/env python3
"""1 枚のフレームから、MobileSAM でウォーターマークのマスクを作る（docs/adr/0021）。

`vrestore restore` の既定（--mask gradient）は、背景が止まっていて模様がある動画や短い動画では形を信用できず
--mask auto に戻る（ADR 0020）。そのときに、ここで作ったマスクを `--mask-image` で渡せる。

  scripts/sam-mask.py --weights mobile_sam.pt [--frame 75] <video> <x,y,w,h> <out.png>
  vrestore restore --rect x,y,w,h --mask-image out.png --out restored.mp4 <video>

- 先頭から --frame 番目（既定 75）のフレームを読み、ROI の周り 64 px を切り出して、ROI を箱として MobileSAM に与える。
  出た 3 つの候補のうち、モデルの評価値が最も高いものを使う
- 1 px 広げ、ROI の周り 8 px（vrestore がマスクを見る範囲）の外は捨てて、動画と同じ大きさの 0 / 255 の画像に書く
- 推測した画素を「戻した」とは数えない（マスクは「どこを置き換えるか」を決めるだけで、埋めるのは vrestore）

必要なもの（vrestore の実行時の依存ではない。CI では回さない）:
- Python 3.12、PyTorch 2.2 系、MobileSAM（https://github.com/ChaoningZhang/MobileSAM、Apache-2.0）、timm、Pillow、numpy、ffmpeg
- 重み mobile_sam.pt（同じリポジトリの weights/、Apache-2.0）。リポジトリには置かない
⚠ 出力は tmp/ の下に置く（CLAUDE.md §4）。
"""
import argparse, json, subprocess, sys
import numpy as np
from PIL import Image


def dilate(m, r):
    for _ in range(r):
        p = np.pad(m, 1)
        m = np.zeros_like(m)
        for dy in range(3):
            for dx in range(3):
                m |= p[dy:dy + m.shape[0], dx:dx + m.shape[1]]
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('video')
    ap.add_argument('rect', help='ROI: x,y,w,h（vrestore restore --rect と同じ）')
    ap.add_argument('out')
    ap.add_argument('--weights', required=True, help='MobileSAM の重み（mobile_sam.pt）')
    ap.add_argument('--frame', type=int, default=75, help='使うフレームの番号（先頭から、0 始まり）')
    a = ap.parse_args()
    import torch
    from mobile_sam import sam_model_registry, SamPredictor
    torch.set_grad_enabled(False)

    s = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'json', a.video], capture_output=True, check=True).stdout)
    W, H = s['streams'][0]['width'], s['streams'][0]['height']
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', a.video, '-vf', 'select=eq(n\\,%d)' % a.frame, '-frames:v', '1',
                          '-sws_flags', 'bicubic+accurate_rnd+full_chroma_int+full_chroma_inp', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True, check=True).stdout
    if len(raw) < W * H * 3:
        sys.exit('sam-mask: the video has no frame %d' % a.frame)
    f = np.frombuffer(raw, np.uint8)[:W * H * 3].reshape(H, W, 3)
    x, y, w, h = map(int, a.rect.split(','))
    m = 64
    x0, y0, x1, y1 = max(0, x - m), max(0, y - m), min(W, x + w + m), min(H, y + h + m)

    sam = sam_model_registry['vit_t'](checkpoint=a.weights).eval()
    pred = SamPredictor(sam)
    pred.set_image(np.ascontiguousarray(f[y0:y1, x0:x1]))
    masks, scores, _ = pred.predict(box=np.array([x - x0, y - y0, x + w - x0, y + h - y0]), multimask_output=True)
    k = int(np.argmax(scores))
    mk = np.zeros((H, W), bool)
    mk[y0:y1, x0:x1] = masks[k]
    lim = np.zeros((H, W), bool)
    lim[max(0, y - 8):y + h + 8, max(0, x - 8):x + w + 8] = True
    mk = dilate(mk & lim, 1) & lim
    Image.fromarray((mk * 255).astype(np.uint8)).save(a.out)
    roi = mk[y:y + h, x:x + w]
    print(json.dumps({'frame': a.frame, 'score': float(scores[k]), 'roi_fraction': float(roi.mean()), 'pixels': int(mk.sum())}))


main()
