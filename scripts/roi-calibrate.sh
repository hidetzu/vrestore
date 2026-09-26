#!/usr/bin/env bash
# ROI 検出の reliable 判定の閾値を、正解が分かっている合成素材で較正する。
#
# 条件を振った合成動画を作り、各ケースで検出した値（confidence / margin / psr）と
# 位置が正しかったかを集め、閾値の組み合わせごとに
#   wrong-but-reliable: 位置が違う（またはウォーターマークが無い）のに reliable=true   ← 0 でなければならない
#   rejected-correct  : 位置は正しいのに reliable=false
# を数える。結果の読み方と採用値は docs/SPEC.md §4。
#
# 使い方: scripts/roi-calibrate.sh [-j 並列数]
# 出力:   tmp/out/calibrate/results.txt（1 ケース 1 行）と、閾値ごとの集計（標準出力）
# CI では回さない（数分かかる）。
set -euo pipefail

jobs=4
while getopts j: o; do
	case $o in
	j) jobs=$OPTARG ;;
	*) exit 2 ;;
	esac
done

cd "$(git rev-parse --show-toplevel)"
out=tmp/out/calibrate
mkdir -p "$out/cases"

# 較正は速度が要るので ReleaseFast で別の場所に作る（zig-out を汚さない）
zig build tools -Doptimize=ReleaseFast --prefix "$out/bin" >/dev/null
vr=$out/bin/bin/vrestore
tool=$out/bin/bin/roi_fixture

cases=()
for seed in 1 2; do
	for bg in pan cut flat; do
		for crf in 16 23 35; do
			for op in 1 0.6 0.35; do
				cases+=("name=$bg-crf$crf-op$op-full-s$seed,bg=$bg,crf=$crf,opacity=$op,seed=$seed,expect=safe")
				cases+=("name=$bg-crf$crf-op$op-tight-s$seed,bg=$bg,crf=$crf,opacity=$op,seed=$seed,margin=0,expect=safe")
				cases+=("name=$bg-crf$crf-op$op-part-s$seed,bg=$bg,crf=$crf,opacity=$op,seed=$seed,ref=part,part_chars=3,margin=2,expect=safe")
				# 繰り返しの途中を 1 周期ぶんだけ切る: 左右に同じ模様が並ぶ（PoC で誤マッチした形）
				cases+=("name=$bg-crf$crf-op$op-repeat-s$seed,bg=$bg,crf=$crf,opacity=$op,seed=$seed,period=3,ref=part,part_chars=3,part_offset=3,margin=0,expect=safe")
			done
			# ウォーターマークの無い動画。背景が動かない flat では、切った背景そのものが毎フレーム同じ位置に
			# あるので「正しく見つかる」。静止した領域とウォーターマークは区別できない（docs/SPEC.md §3）ので含めない
			[ "$bg" = flat ] || cases+=("name=$bg-crf$crf-absent-s$seed,bg=$bg,crf=$crf,opacity=0,seed=$seed,expect=reject")
		done
	done
done

run_case() {
	local spec=$1 out=$2 vr=$3 tool=$4
	local name=${spec#name=}
	name=${name%%,*}
	local crf=${spec##*crf=}
	crf=${crf%%,*}
	local d=$out/cases/$name
	mkdir -p "$d"
	"$tool" synth "$spec" "$d/frames.rgb" "$d/truth.json"
	ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt rgb24 -s 640x360 -r 10 -i "$d/frames.rgb" \
		-c:v libx264 -preset veryfast -crf "$crf" -pix_fmt yuv420p "$d/case.mp4"
	rm -f "$d/frames.rgb"
	"$tool" cutref "$d/case.mp4" "$d/truth.json" "$d/ref.png"
	"$vr" detect-roi --ref "$d/ref.png" "$d/case.mp4" >"$d/detection.json" 2>/dev/null
	"$tool" check "$d/truth.json" "$d/detection.json" || true
}
export -f run_case

echo "calibrate: ${#cases[@]} cases, $jobs jobs, $(ffmpeg -version | head -1 | cut -d' ' -f1-3), $(zig version)"
printf '%s\n' "${cases[@]}" | xargs -P "$jobs" -I{} bash -c 'run_case "$@"' _ {} "$out" "$vr" "$tool" |
	sort >"$out/results.txt"
echo "calibrate: $(wc -l <"$out/results.txt" | tr -d ' ') results in $out/results.txt"

python3 - "$out/results.txt" <<'EOF'
import sys

rows = []
for line in open(sys.argv[1]):
    f = dict(kv.split("=", 1) for kv in line.split()[1:])
    rows.append({
        "case": f["case"],
        "present": float(f["opacity"]) > 0,
        "correct": float(f["opacity"]) > 0 and f["dx"] == "0" and f["dy"] == "0",
        "conf": float(f["confidence"]),
        "margin": float(f["margin"]),
        "psr": float(f["psr"]),
    })
present = [r for r in rows if r["present"]]
correct = [r for r in rows if r["correct"]]
print(f"observed: {len(rows)} cases, watermark present {len(present)}, "
      f"position correct {len(correct)}/{len(present)}, absent {len(rows) - len(present)}")

def evaluate(mc, mm, mp):
    wrong = rej = 0
    for r in rows:
        rel = r["conf"] >= mc and r["margin"] >= mm and r["psr"] >= mp
        if rel and not r["correct"]:
            wrong += 1
        if r["correct"] and not rel:
            rej += 1
    return wrong, rej

confs = [x / 20 for x in range(0, 21)]
margins = [x / 100 for x in range(0, 31)]
psrs = [x / 2 for x in range(0, 41)]

def best(label, grid):
    cands = []
    for mc, mm, mp in grid:
        w, r = evaluate(mc, mm, mp)
        if w == 0:
            cands.append((r, -mm, -mc, -mp, mc, mm, mp))
    if not cands:
        print(f"{label}: no threshold keeps wrong-but-reliable at 0")
        return
    r, *_, mc, mm, mp = min(cands)
    print(f"{label}: min_confidence={mc:.2f} min_margin={mm:.2f} min_psr={mp:.1f} "
          f"-> wrong-but-reliable 0, rejected-correct {r}/{len(correct)}")

best("confidence + PSR   ", [(c, 0, p) for c in confs for p in psrs])
best("confidence + margin", [(c, m, 0) for c in confs for m in margins])
best("all three          ", [(c, m, p) for c in confs for m in margins for p in psrs])

print("\nwrong position (or absent) cases, with what each would have to beat:")
for r in rows:
    if not r["correct"]:
        print(f"  {r['case']:<34} conf={r['conf']:.3f} margin={r['margin']:.3f} psr={r['psr']:.1f}")
EOF
