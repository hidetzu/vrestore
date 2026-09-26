#!/usr/bin/env bash
# git の管理下（コミット済み + ステージ済み）に動画や巨大ファイルが無いことを確かめる。
#
# .gitignore は `git add -f` やリネームで抜けられるので、ここが最後の壁になる。
# 見るのは 3 つ:
#   1. 拡張子が動画・生ストリーム
#   2. 中身が動画（`file --mime-type` が video/*）。拡張子を変えて入れたものを拾う
#   3. サイズが MAX_BYTES を超える。テスト素材は CI で生成する方針なので大きいものは要らない
#
# 使い方: scripts/check-no-media.sh   （リポジトリのどこからでも）
set -euo pipefail

MAX_BYTES=${MAX_BYTES:-1048576} # 1 MiB

cd "$(git rev-parse --show-toplevel)"

ext_re='\.(mp4|m4v|mov|mkv|webm|avi|ts|flv|wmv|h264|264|h265|265|hevc|yuv|y4m)$'

total=0
bad=0
while IFS= read -r -d '' f; do
	# 削除がステージされているだけのものは中身が無い
	[ -f "$f" ] || continue
	total=$((total + 1))
	lower=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
	if [[ "$lower" =~ $ext_re ]]; then
		echo "動画の拡張子: $f"
		bad=$((bad + 1))
		continue
	fi
	mime=$(file -b --mime-type "$f")
	if [[ "$mime" == video/* ]]; then
		echo "中身が動画 ($mime): $f"
		bad=$((bad + 1))
		continue
	fi
	size=$(wc -c <"$f" | tr -d ' ')
	if [ "$size" -gt "$MAX_BYTES" ]; then
		echo "大きすぎる (${size} bytes > ${MAX_BYTES}): $f"
		bad=$((bad + 1))
	fi
done < <(git ls-files -z --cached)

if [ "$bad" -gt 0 ]; then
	echo "check-no-media: FAIL ($bad / $total files)"
	echo "実素材は tmp/media/ に置く。ステージから外すには: git rm --cached <file>"
	exit 1
fi
echo "check-no-media: OK ($total files checked)"
