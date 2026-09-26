#!/usr/bin/env bash
# Temporal Recovery を、正解（ウォーターマークを焼く前の同じ背景）が分かっている合成素材で測る。
#
# 各ケース: 合成（tools/roi_fixture synth / synth-clean）→ yuv420p にエンコード → detect-roi →
# vrestore restore → 可逆で保存 → vrestore compare で正解と比べる。並べる行:
#   watermarked  焼き込んだまま（下限）
#   reencode     正解を同じ crf で再エンコードしただけ（上限）
#   temporal     vrestore restore の出力。ROI 全体の SSIM / PSNR と、戻した画素だけの PSNR・coverage
# 位相相関のピーク（restore の peak_min / peak_max）も出す。閾値 --min-peak の較正に使う。
#
# 使い方: scripts/restore-calibrate.sh [-j 並列数] [-m min_peak] [-M translation|affine]
# 出力:   tmp/out/restore-calibrate/<motion>/results.txt（1 ケース 1 行の JSON）と集計（標準出力）
# CI では回さない（数分かかる）。
set -euo pipefail

jobs=4
min_peak=
motion=translation
while getopts j:m:M: o; do
	case $o in
	j) jobs=$OPTARG ;;
	m) min_peak=$OPTARG ;;
	M) motion=$OPTARG ;;
	*) exit 2 ;;
	esac
done

cd "$(git rev-parse --show-toplevel)"
out=tmp/out/restore-calibrate/$motion
mkdir -p "$out/cases"
zig build tools -Doptimize=ReleaseFast --prefix "$out/bin" >/dev/null
export vr=$out/bin/bin/vrestore tool=$out/bin/bin/roi_fixture out min_peak motion

cases=()
for seed in 1 2; do
	# 動き: bg:pan_x:pan_y:zoom:rot（zoom は 1 フレームあたりの拡大率、rot は度）
	for mv in "pan:3:1:0:0" "pan:7:3:0:0" "pan:15:0:0:0" "cut:0:0:0:0" "flat:0:0:0:0" \
		"warp:0:0:0:0.3" "warp:0:0:0.005:0" "warp:5:2:0.003:0" "warp:5:2:0:0.2"; do
		IFS=: read -r bg px py zm rt <<<"$mv"
		label=$bg$px.$py
		[ "$bg" = warp ] && label="warp-z$zm-r$rt-p$px.$py"
		for pos in corner center; do
			case $pos in
			corner) xy="x=-8,y=6" ;;
			center) xy="x=240,y=150" ;;
			esac
			for crf in 16 23 35; do
				for op in 1 0.5; do
					cases+=("name=$label-$pos-crf$crf-op$op-s$seed,bg=$bg,pan_x=$px,pan_y=$py,zoom=$zm,rot=$rt,$xy,crf=$crf,opacity=$op,seed=$seed,frames=60")
				done
			done
		done
	done
done

run_case() {
	local spec=$1
	local name=${spec#name=}
	name=${name%%,*}
	local crf=${spec##*crf=}
	crf=${crf%%,*}
	local d=$out/cases/$name
	mkdir -p "$d"
	local raw="-f rawvideo -pix_fmt rgb24 -s 640x360 -r 10"
	"$tool" synth "$spec" "$d/wm.rgb" "$d/truth.json"
	"$tool" synth-clean "$spec" "$d/clean.rgb" "$d/truth-clean.json"
	ffmpeg -hide_banner -loglevel error -y $raw -i "$d/wm.rgb" -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/wm.mp4"
	ffmpeg -hide_banner -loglevel error -y $raw -i "$d/clean.rgb" -c:v ffv1 -pix_fmt gbrp "$d/clean.mkv"
	ffmpeg -hide_banner -loglevel error -y $raw -i "$d/clean.rgb" -c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/reencode.mp4"
	rm -f "$d/wm.rgb" "$d/clean.rgb"
	"$tool" cutref "$d/wm.mp4" "$d/truth.json" "$d/ref.png"
	"$vr" detect-roi --ref "$d/ref.png" "$d/wm.mp4" >"$d/roi.json" 2>/dev/null
	local mp=()
	[ -n "$min_peak" ] && mp=(--min-peak "$min_peak")
	"$vr" restore --motion "$motion" --roi "$d/roi.json" --raw "$d/out.rgb" --provenance "$d/provenance.bin" "${mp[@]}" "$d/wm.mp4" >"$d/restore.json"
	ffmpeg -hide_banner -loglevel error -y $raw -i "$d/out.rgb" -c:v ffv1 -pix_fmt gbrp "$d/restored.mkv"
	rm -f "$d/out.rgb"
	local rect
	rect=$(python3 -c "import json;d=json.load(open('$d/roi.json'));print(f\"{d['x']},{d['y']},{d['width']},{d['height']}\")")
	python3 - "$name" "$d" <<PY
import json, subprocess, sys
name, d = sys.argv[1], sys.argv[2]
def cmp(f, mask=None):
    a = ["$vr", "compare", "--rect", "$rect"] + (["--provenance", mask] if mask else []) + [d + "/clean.mkv", d + "/" + f]
    return json.loads(subprocess.run(a, capture_output=True, check=True, text=True).stdout)
row = {"case": name, "roi": json.load(open(d + "/roi.json")), "restore": json.load(open(d + "/restore.json")),
       "watermarked": cmp("wm.mp4"), "reencode": cmp("reencode.mp4"), "temporal": cmp("restored.mkv", d + "/provenance.bin")}
print(json.dumps(row))
PY
	rm -f "$d/provenance.bin"
}
export -f run_case

echo "restore-calibrate: ${#cases[@]} cases, motion $motion, $jobs jobs, $(ffmpeg -version | head -1 | cut -d' ' -f1-3), $(zig version)"
printf '%s\n' "${cases[@]}" | xargs -P "$jobs" -I{} bash -c 'run_case "$@"' _ {} | sort >"$out/results.txt"
echo "restore-calibrate: $(wc -l <"$out/results.txt" | tr -d ' ') results in $out/results.txt"

python3 - "$out/results.txt" <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1])]
def key(r):
    parts = r["case"].split("-")
    i = next(i for i, p in enumerate(parts) if p in ("center", "corner"))
    return ("-".join(parts[:i]), parts[i])
by = collections.defaultdict(list)
for r in rows: by[key(r)].append(r)
print(f"\n{'motion/pos':<30}{'n':>3} {'wm SSIM':>8} {'reenc SSIM':>10} {'temporal SSIM':>13} {'coverage':>9} {'bad':>6} {'masked PSNR':>11} {'reenc PSNR':>10} {'peak min..max':>14} {'cut':>4}")
for k in sorted(by):
    rs = by[k]; n = len(rs)
    avg = lambda f: sum(f(r) for r in rs) / n
    mp = [r["temporal"]["masked_psnr"] for r in rs if r["temporal"]["masked_psnr"] is not None]
    mpx = sum(r["temporal"]["masked_pixels"] for r in rs)
    bad = sum(r["temporal"]["masked_bad_fraction"] * r["temporal"]["masked_pixels"] for r in rs) / mpx if mpx else 0
    print(f"{k[0]+'/'+k[1]:<30}{n:>3} {avg(lambda r: r['watermarked']['ssim']):>8.3f} {avg(lambda r: r['reencode']['ssim']):>10.3f} "
          f"{avg(lambda r: r['temporal']['ssim']):>13.3f} {avg(lambda r: r['restore']['coverage']):>9.3f} {bad:>6.4f} "
          f"{(min(mp) if mp else float('nan')):>11.1f} {min(r['reencode']['psnr'] for r in rs):>10.1f} "
          f"{min(r['restore']['peak_min'] for r in rs):>6.3f}..{max(r['restore']['peak_max'] for r in rs):<6.3f} {sum(r['restore']['pairs_cut'] for r in rs):>4}")
print("\n(bad = recovered pixels off by more than 32 in any color, over all cases of the row; masked PSNR = the worst case's PSNR over recovered pixels only;"
      " reenc PSNR = the worst case's PSNR of the upper bound over the whole ROI)")
bad = [r for r in rows if not r["roi"]["reliable"]]
if bad: print("detect-roi not reliable:", [r["case"] for r in bad])
PY
