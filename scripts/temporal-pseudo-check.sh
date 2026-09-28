#!/usr/bin/env bash
# 正解の無い実素材で、Temporal Recovery が戻した画素の正しさを測る（疑似チェック）。
#
# ウォーターマークの無い場所に、本物の ROI と同じ大きさの矩形を置いて restore し、そこで戻した画素（temporal_real）を
# 同じ場所の入力（= 正解）と比べる。外れ = どれかの色で誤差 > 32（SPEC と同じ）。
#
# 使い方: scripts/temporal-pseudo-check.sh [-n クリップ数] [-d 秒] [-o "restore の追加の引数"] <video> <x,y,w,h> [<x,y,w,h> ...]
#   矩形の中に、動かないロゴ・字幕・黒帯などが無いこと（あればそれを「正解」と比べてしまう）
# 出力: tmp/out/pseudo/<動画名>/ に、クリップと矩形ごとの結果（results.txt）と集計（標準出力）
# ⚠ 動画・出力は tmp/ の下にだけ置く（CLAUDE.md §4）。実素材のファイル名を公開物に書かない。
set -euo pipefail

clips=20
dur=20
extra=""
while getopts n:d:o: o; do
	case $o in
	n) clips=$OPTARG ;;
	d) dur=$OPTARG ;;
	o) extra=$OPTARG ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || {
	echo "usage: scripts/temporal-pseudo-check.sh [-n clips] [-d seconds] [-o \"restore args\"] <video> <x,y,w,h> [...]" >&2
	exit 2
}
video=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
rects=("$@")

cd "$(git rev-parse --show-toplevel)"
out=tmp/out/pseudo/$(basename "${video%.*}")
mkdir -p "$out"
zig build -Doptimize=ReleaseFast --prefix tmp/out/pseudo/bin >/dev/null
vr=tmp/out/pseudo/bin/bin/vrestore

total=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
res=$out/results.txt
: >"$res"
echo "pseudo-check: $clips clips x ${dur}s, rects ${rects[*]}, restore args '$extra'"
for k in $(seq 0 $((clips - 1))); do
	start=$(python3 -c "print(round(($total - $dur) * ($k + 0.5) / $clips, 2))")
	clip=$out/clip.mkv
	ffmpeg -hide_banner -loglevel error -y -ss "$start" -i "$video" -t "$dur" -an -c:v ffv1 -pix_fmt yuv420p "$clip"
	IFS=x read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$clip")
	for r in "${rects[@]}"; do
		# shellcheck disable=SC2086
		"$vr" restore --rect "$r" --fill none --mask none $extra --raw "$out/o.rgb" --provenance "$out/o.prov" "$clip" >/dev/null
		ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt rgb24 -s "${W}x${H}" -r "$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$clip")" \
			-i "$out/o.rgb" -c:v ffv1 -pix_fmt gbrp "$out/o.mkv"
		printf '%s %s %s\n' "$start" "$r" "$("$vr" compare --rect "$r" --provenance "$out/o.prov" "$clip" "$out/o.mkv")" >>"$res"
		rm -f "$out/o.rgb" "$out/o.prov" "$out/o.mkv"
	done
	rm -f "$clip"
done

python3 - "$res" <<'PY'
import sys, json, collections
acc = collections.defaultdict(lambda: [0, 0.0, 0, 0.0])  # 戻した画素、外れ、ROI の画素、戻した画素の二乗誤差の和
for line in open(sys.argv[1]):
    start, rect, js = line.split(" ", 2)
    d = json.loads(js); t = d["provenance"].get("temporal_real")
    a = acc[rect]
    a[2] += sum(v["pixels"] for v in d["provenance"].values())
    if t:
        a[0] += t["pixels"]; a[1] += t["bad_fraction"] * t["pixels"]
        if t["psnr"] is not None: a[3] += t["pixels"] * 255 ** 2 / 10 ** (t["psnr"] / 10)
import math
for rect, (px, bad, allpx, se) in acc.items():
    psnr = "-" if px == 0 or se == 0 else f"{10 * math.log10(255 ** 2 / (se / px)):.1f}"
    print(f"rect {rect}: coverage {px / max(1, allpx):.4f}  bad {bad / max(1, px):.4f}  PSNR {psnr} dB  (recovered {px} of {allpx})")
PY
