---
name: verify
description: vrestore の変更が壊れていないと言うために何を実行するか。PR の前・変更を「できた」と報告する前に使う。
---

# verify

契約（層・順序・返す形式）は [`.claude/rules/verification.md`](../../rules/verification.md)。
ここは**何を実行するか**だけを持つ。README・CI はここを参照し、コマンドを写さない。

## 前提

- Zig: `build.zig.zon` の `minimum_zig_version`（CI も同じ値を読む）
- ⚠ `zig version` がそれと一致することを最初に確かめる。Zig は版ごとに std が大きく変わる
- FFmpeg: `ffmpeg` コマンド（テスト用動画の合成）と、pkg-config で見つかる libavformat / libavcodec /
  libswscale / libavutil（リンク）。CI で入れているものは `.github/workflows/ci.yml`

## fast

```sh
zig build check
```

`check` は `build.zig` にあり、次をまとめて回す。CI もこれだけを実行する。

| 中身 | 何を見るか |
|---|---|
| `zig fmt --check` | `build.zig` `build.zig.zon` `src/` の整形 |
| `zig build test` | ユニットテスト（動画は ffmpeg で合成してから）と、実行ファイルを起動する `cli_*` |
| `scripts/check-no-media.sh` | 動画・1 MiB 超のファイルが git の管理下（ステージ含む）に無いこと。件数を出す |
| `zig build`（install） | 実行ファイルが作れること |

一部だけ回すとき:

```sh
zig build test                                       # テストだけ
zig build test -Dtest-filter="parseArgs"             # 名前で 1 件
zig fmt --check build.zig build.zig.zon src          # 整形だけ
scripts/check-no-media.sh                            # 衛生だけ
```

## 合成 E2E

まだ無い。ROI 検出が入ったら、合成動画の生成 → 検出 → 正解座標との比較（dx / dy / IoU / reliable）
をここに足す。

## 実素材

`tmp/media/` の動画に対して手で回す。CI では回らない。

```sh
for f in tmp/media/*; do echo "$f"; zig-out/bin/vrestore probe "$f"; done
```
報告では「実素材では見ていない」を `Not verified` に書く。
