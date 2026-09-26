#!/usr/bin/env python3
"""実写の動画に焼き込んで試すための、ウォーターマークの透過 PNG を作る。

文言はすべて無害な見本。実在の配布元・他者のウォーターマークは使わない（.claude/rules/git.md）。
PIL と CJK フォントが要るので CI では使わない。CI の合成素材は tools/roi_fixture.zig が作る。

  scripts/mkwatermark.py <design> <out.png> [scale]

design:
  jp-block  日本語 2 行 + 英字 2 行、赤と青、黒の縁取り（よくある配布元表記の形）
  url       URL 1 行、白、黒の縁取り
  repeat    同じ語を 3 回繰り返した 1 行（「PSR は高いが位置が違う」を起こしやすい）
  logo      円と四角の図形 + 短い語
  small     短い 1 語、小さい文字
"""
import sys

from PIL import Image, ImageDraw, ImageFont

FONTS = [
    "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
]

RED = (255, 40, 40)
BLUE = (40, 110, 255)
WHITE = (255, 255, 255)


def font(size):
    for path in FONTS:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    raise SystemExit("CJK フォントが見つからない: " + ", ".join(FONTS))


def text_block(lines, stroke=2, leading=4):
    """[(text, color, size)] を縦に積んだ透過画像。余白は付けない（外接矩形 = 画像の大きさ）"""
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    boxes = [probe.textbbox((0, 0), t, font=font(s), stroke_width=stroke) for t, _, s in lines]
    w = max(b[2] - b[0] for b in boxes)
    h = sum(b[3] - b[1] for b in boxes) + leading * (len(lines) - 1)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    y = 0
    for (t, c, s), b in zip(lines, boxes):
        d.text((-b[0], y - b[1]), t, font=font(s), fill=c + (255,), stroke_width=stroke, stroke_fill=(0, 0, 0, 255))
        y += b[3] - b[1] + leading
    return img


def logo(k):
    s = int(96 * k)
    word = text_block([("SAMPLE", WHITE, int(40 * k))], stroke=max(1, int(2 * k)))
    img = Image.new("RGBA", (s + int(12 * k) + word.width, max(s, word.height)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    lw = max(2, int(6 * k))
    d.ellipse((lw, lw, s - lw, s - lw), outline=(255, 255, 255, 255), width=lw)
    q = s // 4
    d.rectangle((q, q, s - q, s - q), fill=(255, 200, 0, 255))
    img.alpha_composite(word, (s + int(12 * k), (img.height - word.height) // 2))
    return img


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    design, out = sys.argv[1], sys.argv[2]
    k = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    z = lambda n: max(8, int(n * k))  # noqa: E731
    if design == "jp-block":
        img = text_block([
            ("動画見本倉庫", RED, z(40)),
            ("sample.invalid", RED, z(34)),
            ("見本宣伝文句 登録無料", BLUE, z(34)),
            ("www.example.invalid", BLUE, z(30)),
        ])
    elif design == "url":
        img = text_block([("www.example.invalid", WHITE, z(40))])
    elif design == "repeat":
        img = text_block([("SAMPLE SAMPLE SAMPLE", WHITE, z(40))])
    elif design == "logo":
        img = logo(k)
    elif design == "small":
        img = text_block([("@sample", WHITE, z(24))], stroke=1)
    else:
        raise SystemExit(f"unknown design: {design}")
    img.save(out)
    print(f"{design} {img.width}x{img.height}")


if __name__ == "__main__":
    main()
