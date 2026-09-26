#!/usr/bin/env bash
# 復元率の基準を測る: 手元の実写にウォーターマークを焼き込み、各方式の出力が元の動画にどれだけ一致するかを
# ウォーターマークの矩形の中で SSIM / PSNR で出す（vrestore compare）。
#
# 並べる行（どれも元の動画 = 可逆で固定したクリップと比べる）:
#   watermarked     焼き込んだまま。下限
#   reencode        元の動画を同じ crf で再エンコードしただけ。上限（入力がすでに crf で劣化しているので、
#                   どの復元方式もこれを超えられない）
#   delogo-roi      FFmpeg の delogo に vrestore detect-roi の検出矩形を渡したもの（余白込み）
#   delogo-tight    delogo にウォーターマークぴったりの矩形を渡したもの（検出の誤差・余白の影響を除く）
#   temporal        vrestore restore（Temporal Recovery）に detect-roi の矩形を渡したもの。戻せなかった画素は
#                   焼かれたまま残る。戻した画素だけの PSNR と coverage も出す
# 復元方式の出力は可逆で保存する（出力の再圧縮で落ちる分を混ぜない）。
#
# 使い方: scripts/restore-real.sh [-s 開始秒] [-d 秒数] [-j 並列数] <video>
# 出力:   tmp/out/restore/<動画名>/results.txt と集計（標準出力）
# ⚠ 動画・出力は tmp/ の下にだけ置く（CLAUDE.md §4）。実素材のファイル名を公開物に書かない。
# PIL と CJK フォントが要る（scripts/mkwatermark.py）。CI では回さない。
set -euo pipefail

start=200
dur=5
jobs=4
while getopts s:d:j: o; do
	case $o in
	s) start=$OPTARG ;;
	d) dur=$OPTARG ;;
	j) jobs=$OPTARG ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || {
	echo "usage: scripts/restore-real.sh [-s start] [-d seconds] [-j jobs] <video>" >&2
	exit 2
}
video=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

cd "$(git rev-parse --show-toplevel)"
out=tmp/out/restore/$(basename "${video%.*}")-s$start-d$dur
mkdir -p "$out/wm" "$out/cases"

zig build tools -Doptimize=ReleaseFast --prefix tmp/out/restore/bin >/dev/null
vr=tmp/out/restore/bin/bin/vrestore
tool=tmp/out/restore/bin/bin/roi_fixture

IFS=x read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$video")

designs=(jp-block url logo)
# ウォーターマークは 1920 幅のときの大きさを基準に、動画の幅に合わせて縮める
scale=$(python3 -c "print(max(0.35, $W / 1920))")
for d in "${designs[@]}"; do
	[ -e "$out/wm/$d.png" ] || scripts/mkwatermark.py "$d" "$out/wm/$d.png" "$scale" >/dev/null
done

enc() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 正解: 元の動画のクリップを可逆で固定する（-ss の位置によらず、以降の全ファイルが同じフレームになる）
[ -e "$out/orig.mkv" ] || enc -ss "$start" -t "$dur" -i "$video" -an -c:v ffv1 -pix_fmt yuv420p "$out/orig.mkv"
for crf in 20 32; do
	[ -e "$out/reencode-crf$crf.mp4" ] || enc -i "$out/orig.mkv" -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$out/reencode-crf$crf.mp4"
done
# 全画素が 255 のマスク: 再エンコードだけの行でも「外れた画素の割合」を出し、圧縮だけでどれだけ外れるかを見る
if [ ! -e "$out/all.mask" ]; then
	nf=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$out/orig.mkv")
	python3 -c "import sys; sys.stdout.buffer.write(b'\xff' * ($W * $H * $nf))" >"$out/all.mask"
fi

specs=()
for d in "${designs[@]}"; do
	for pos in tl c; do
		for op in 1 0.5; do
			for crf in 20 32; do specs+=("$d $pos $op $crf"); done
		done
	done
done

run_spec() {
	local design=$1 pos=$2 op=$3 crf=$4
	local wm=$out/wm/$design.png ww wh x y
	read -r ww wh < <(python3 -c "from PIL import Image; i=Image.open('$wm'); print(i.width, i.height)")
	case $pos in
	tl) x=40 y=40 ;;
	c) x=$(((W - ww) / 2)) y=$(((H - wh) / 2)) ;;
	esac
	local name=$design-$pos-op$op-crf$crf d=$out/cases/$design-$pos-op$op-crf$crf
	mkdir -p "$d"
	enc -i "$out/orig.mkv" -loop 1 -i "$wm" \
		-filter_complex "[1:v]format=rgba,colorchannelmixer=aa=$op[w];[0:v][w]overlay=$x:$y:shortest=1" \
		-c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/watermarked.mp4"

	# 検出: 余白 12px で切った参照画像から
	local m=12
	printf '{"case":"%s","expect":"hit","width":%d,"height":%d,"ref_x":%d,"ref_y":%d,"ref_w":%d,"ref_h":%d,"ref_frame":15,"crf":%d,"opacity":%s}\n' \
		"$name" "$W" "$H" $((x - m)) $((y - m)) $((ww + 2 * m)) $((wh + 2 * m)) "$crf" "$op" >"$d/truth.json"
	"$tool" cutref "$d/watermarked.mp4" "$d/truth.json" "$d/ref.png"
	"$vr" detect-roi --ref "$d/ref.png" "$d/watermarked.mp4" >"$d/detection.json" 2>/dev/null
	local rx ry rw rh
	read -r rx ry rw rh < <(python3 -c "import json; d=json.load(open('$d/detection.json')); print(d['x'], d['y'], d['width'], d['height'])")

	enc -i "$d/watermarked.mp4" -vf "delogo=x=$rx:y=$ry:w=$rw:h=$rh" -c:v ffv1 -pix_fmt yuv420p "$d/delogo-roi.mkv"
	enc -i "$d/watermarked.mp4" -vf "delogo=x=$x:y=$y:w=$ww:h=$wh" -c:v ffv1 -pix_fmt yuv420p "$d/delogo-tight.mkv"

	"$vr" restore --roi "$d/detection.json" --raw "$d/temporal.rgb" --mask "$d/temporal.mask" "$d/watermarked.mp4" >"$d/temporal.json"
	enc -f rawvideo -pix_fmt rgb24 -s "${W}x${H}" -r "$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$d/watermarked.mp4")" \
		-i "$d/temporal.rgb" -c:v ffv1 -pix_fmt yuv444p "$d/temporal.mkv"
	rm -f "$d/temporal.rgb"

	# 測るのはウォーターマークの外接矩形（焼き込んだ場所）。temporal のマスクは ROI（余白込み）について出ているが、
	# マスクのある画素だけを数えるので、外接矩形の中の戻した画素の PSNR になる
	local rect=$x,$y,$ww,$wh row f
	for row in watermarked reencode delogo-roi delogo-tight temporal; do
		case $row in
		watermarked) f=$d/watermarked.mp4 ;;
		reencode) f=$out/reencode-crf$crf.mp4 ;;
		*) f=$d/$row.mkv ;;
		esac
		local mask=()
		[ "$row" = temporal ] && mask=(--mask "$d/temporal.mask")
		[ "$row" = reencode ] && mask=(--mask "$out/all.mask")
		printf '%s %s %s\n' "$name" "$row" "$("$vr" compare --rect "$rect" "${mask[@]}" "$out/orig.mkv" "$f")"
	done
}
export -f run_spec enc
export out W H vr tool

echo "restore-real: ${#specs[@]} videos, ${W}x${H}, ${dur}s from ${start}s, $jobs jobs, $(ffmpeg -version | head -1 | cut -d' ' -f1-3), $(zig version)"
printf '%s\n' "${specs[@]}" | xargs -P "$jobs" -L 1 bash -c 'run_spec "$@"' _ | sort >"$out/results.txt"
echo "restore-real: $(wc -l <"$out/results.txt" | tr -d ' ') rows in $out/results.txt"

python3 - "$out/results.txt" <<'EOF'
import sys, json, collections
rows = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    name, row, js = line.split(" ", 2)
    rows[name][row] = json.loads(js)
order = ["watermarked", "reencode", "delogo-roi", "delogo-tight", "temporal"]
print(f"\n{'case':<26}" + "".join(f"{r:>22}" for r in order))
print(f"{'':<26}" + "".join(f"{'SSIM mean/min  PSNR':>22}" for _ in order))
for name in sorted(rows):
    cells = []
    for r in order:
        v = rows[name][r]
        p = "inf" if v["psnr"] is None else f"{v['psnr']:.1f}"
        cells.append(f"{v['ssim']:.3f}/{v['ssim_min']:.3f} {p:>5}")
    print(f"{name:<26}" + "".join(f"{c:>22}" for c in cells))
print("\ntemporal: recovered fraction of the watermark rect / PSNR over recovered pixels / bad fraction of recovered pixels"
      " (reencode: bad fraction of all pixels in the rect)")
for name in sorted(rows):
    t = rows[name]["temporal"]
    mp = "-" if t.get("masked_psnr") is None else f"{t['masked_psnr']:.1f}"
    print(f"  {name:<26} {t['masked_fraction']:.3f}  {mp:>5}  bad {t['masked_bad_fraction']:.3f}   reencode bad {rows[name]['reencode']['masked_bad_fraction']:.3f}")
print("\nmean over cases (SSIM mean):")
for r in order:
    vals = [rows[n][r]["ssim"] for n in rows]
    print(f"  {r:<14} {sum(vals)/len(vals):.4f}  (min case {min(vals):.4f}, {len(vals)} cases)")
EOF
