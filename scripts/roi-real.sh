#!/usr/bin/env bash
# 手元の実写の動画に、既知の位置へウォーターマークを焼き込み、ROI 検出が正しい位置を返すかを測る。
#
# 合成素材（scripts/roi-calibrate.sh）では背景が作り物なので、実写の背景
# （照明の変化・人の動き・静止した機材・圧縮のされ方）で同じことを確かめる。
# 焼き込んだ位置が正解なので、実写でも dx / dy / IoU を数値で出せる。
#
# 使い方: scripts/roi-real.sh [-s 開始秒] [-d 秒数] [-j 並列数] <video>
# 出力:   tmp/out/real/<動画名>/results.txt（1 ケース 1 行）と集計（標準出力）
#
# ⚠ 動画・焼き込み結果・参照画像は tmp/ の下にだけ置く（コミットしない。CLAUDE.md §4）。
# ⚠ 実素材のファイル名を公開物に書かない（.claude/rules/git.md）。
# PIL と CJK フォントが要る（scripts/mkwatermark.py）。CI では回さない。
set -euo pipefail

start=200
dur=10
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
	echo "usage: scripts/roi-real.sh [-s start] [-d seconds] [-j jobs] <video>" >&2
	exit 2
}
video=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

cd "$(git rev-parse --show-toplevel)"
out=tmp/out/real/$(basename "${video%.*}")-s$start-d$dur
mkdir -p "$out/wm" "$out/cases"

zig build tools -Doptimize=ReleaseFast --prefix tmp/out/real/bin >/dev/null
vr=tmp/out/real/bin/bin/vrestore
tool=tmp/out/real/bin/bin/roi_fixture

IFS=x read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$video")

designs=(jp-block url repeat logo small)
for d in "${designs[@]}"; do
	[ -e "$out/wm/$d.png" ] || scripts/mkwatermark.py "$d" "$out/wm/$d.png" >/dev/null
done

# 1 行 = 1 本の焼き込み動画: design pos opacity crf
specs=()
for d in "${designs[@]}"; do
	for pos in tl tc c br; do
		for op in 1 0.5 0.25; do
			for crf in 20 32; do specs+=("$d $pos $op $crf"); done
		done
	done
done
# 対照: ウォーターマークを焼かない。参照画像は jp-block を置くはずだった場所から切る
for pos in tl tc c br; do for crf in 20 32; do specs+=("none $pos 0 $crf"); done; done

run_spec() {
	local design=$1 pos=$2 op=$3 crf=$4
	local wm=$out/wm/$design.png
	[ "$design" = none ] && wm=$out/wm/jp-block.png
	local ww wh
	read -r ww wh < <(python3 -c "from PIL import Image; i=Image.open('$wm'); print(i.width, i.height)")
	local x y
	case $pos in
	tl) x=40 y=40 ;;
	tc) x=$(((W - ww) / 2)) y=40 ;;
	c) x=$(((W - ww) / 2)) y=$(((H - wh) / 2)) ;;
	br) x=$((W - ww - 40)) y=$((H - wh - 40)) ;;
	esac
	local name=$design-$pos-op$op-crf$crf
	local d=$out/cases/$name
	mkdir -p "$d"
	if [ "$design" = none ]; then
		ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$dur" -i "$video" -an \
			-c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/case.mp4"
	else
		ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$dur" -i "$video" -loop 1 -i "$wm" \
			-filter_complex "[1:v]format=rgba,colorchannelmixer=aa=$op[w];[0:v][w]overlay=$x:$y:shortest=1" \
			-t "$dur" -an -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/case.mp4"
	fi
	# 参照画像 3 通り: 全体 + 余白 12px / 余白なし / 左 1/3 だけ（余白 4px）
	local kind rx ry rw rh m
	for kind in full tight part; do
		case $kind in
		full) m=12 rw=$ww ;;
		tight) m=0 rw=$ww ;;
		part) m=4 rw=$((ww / 3)) ;;
		esac
		rx=$((x - m)) ry=$((y - m)) rw=$((rw + 2 * m)) rh=$((wh + 2 * m))
		local expect=safe
		[ "$design" = none ] && expect=reject
		printf '{"case":"%s","expect":"%s","width":%d,"height":%d,"ref_x":%d,"ref_y":%d,"ref_w":%d,"ref_h":%d,"ref_frame":15,"crf":%d,"opacity":%s}\n' \
			"$name-$kind" "$expect" "$W" "$H" "$rx" "$ry" "$rw" "$rh" "$crf" "$op" >"$d/truth-$kind.json"
		"$tool" cutref "$d/case.mp4" "$d/truth-$kind.json" "$d/ref-$kind.png"
		"$vr" detect-roi --ref "$d/ref-$kind.png" "$d/case.mp4" >"$d/detection-$kind.json" 2>/dev/null
		"$tool" check "$d/truth-$kind.json" "$d/detection-$kind.json" || true
	done
}
export -f run_spec
export out video start dur W H vr tool

echo "roi-real: ${#specs[@]} videos x 3 refs, ${W}x${H}, ${dur}s from ${start}s, $jobs jobs, $(ffmpeg -version | head -1 | cut -d' ' -f1-3), $(zig version)"
printf '%s\n' "${specs[@]}" | xargs -P "$jobs" -L 1 bash -c 'run_spec "$@"' _ | sort >"$out/results.txt"
echo "roi-real: $(wc -l <"$out/results.txt" | tr -d ' ') results in $out/results.txt"

python3 - "$out/results.txt" <<'EOF'
import sys, collections
rows = []
for line in open(sys.argv[1]):
    f = dict(kv.split("=", 1) for kv in line.split()[1:])
    parts = f["case"].split("-")
    kind = parts[-1]; crf = parts[-2]; op = parts[-3]; pos = parts[-4]; design = "-".join(parts[:-4])
    dx, dy = int(f["dx"]), int(f["dy"])
    rows.append(dict(design=design, pos=pos, op=op, crf=crf, kind=kind, present=design != "none",
                     exact=dx == 0 and dy == 0, near=abs(dx) <= 1 and abs(dy) <= 1,
                     iou=float(f["iou"]), rel=f["reliable"] == "true",
                     conf=float(f["confidence"]), margin=float(f["margin"]), psr=float(f["psr"])))
P = [r for r in rows if r["present"]]
A = [r for r in rows if not r["present"]]

def line(label, rs):
    n = len(rs)
    if n == 0:
        return
    ex = sum(r["exact"] for r in rs); nr = sum(r["near"] for r in rs)
    rel = sum(r["rel"] for r in rs); wr = sum(r["rel"] and not r["exact"] for r in rs)
    rj = sum(r["exact"] and not r["rel"] for r in rs)
    print(f"  {label:<14} exact {ex:>3}/{n:<3}  |d|<=1 {nr:>3}/{n:<3}  reliable {rel:>3}/{n:<3}  "
          f"wrong-but-reliable {wr:>2}  correct-but-rejected {rj:>2}")

print(f"\nwatermark present ({len(P)} detections):")
line("all", P)
for key in ["design", "pos", "op", "crf", "kind"]:
    print(f" by {key}:")
    for v in sorted({r[key] for r in P}):
        line(v, [r for r in P if r[key] == v])
print(f"\nno watermark ({len(A)} detections): reliable {sum(r['rel'] for r in A)}/{len(A)}  "
      f"(static background can be found correctly; see docs/SPEC.md §3)")
for r in A:
    if r["rel"]:
        print(f"  reliable: {r['pos']}-{r['crf']}-{r['kind']} exact={r['exact']} conf={r['conf']:.3f} margin={r['margin']:.3f}")
wrong = [r for r in P if r["rel"] and not r["exact"]]
if wrong:
    print("\nwrong-but-reliable:")
    for r in wrong:
        print(f"  {r['design']}-{r['pos']}-op{r['op']}-crf{r['crf']}-{r['kind']} iou={r['iou']:.3f} conf={r['conf']:.3f} margin={r['margin']:.3f} psr={r['psr']:.1f}")
EOF
