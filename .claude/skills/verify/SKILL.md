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
- SDL2: pkg-config の `sdl2`、SDL2_ttf（`vrestore-gui` だけが使う）

## fast

```sh
zig build check
```

`check` は `build.zig` にあり、次をまとめて回す。CI もこれだけを実行する。

| 中身 | 何を見るか |
|---|---|
| `zig fmt --check` | `build.zig` `build.zig.zon` `src/` の整形 |
| `zig build test` | ユニットテスト（動画は ffmpeg で合成してから）と、実行ファイルを起動する `cli_*` |
| `zig build gui` | `vrestore-gui` をビルドし、SDL のダミー描画で「フレーム表示 → 選択 → 検出」を回して正解と照合する（`roi check gui`）。`--frame` / `--play-frames` で場面を動かし、共有用の 1 行を照合する（`gui share *`） |
| `zig build restore-e2e` | Temporal Recovery の合成 E2E。ケースは `build.zig` の `restore_cases`。合成 → エンコード → detect-roi → restore → 正解と compare → 条件で判定 |
| `zig build metrics` | `vrestore compare` の SSIM / MSE を FFmpeg の ssim / psnr フィルタとフレームごとに突き合わせる |
| `zig build e2e` | ROI の合成 E2E。ケースは `build.zig` の `roi_cases`。1 ケース = 合成 → エンコード → 参照画像を切る → `detect-roi` → 正解と照合 |
| `scripts/check-no-media.sh` | 動画・1 MiB 超のファイルが git の管理下（ステージ含む）に無いこと。件数を出す |
| `zig build`（install） | 実行ファイルが作れること |

一部だけ回すとき:

```sh
zig build test                                       # テストだけ
zig build test -Dtest-filter="parseArgs"             # 名前で 1 件
zig build e2e                                        # ROI の合成 E2E だけ
zig fmt --check build.zig build.zig.zon src tools    # 整形だけ
scripts/check-no-media.sh                            # 衛生だけ
```

## 合成 E2E

`zig build check` に含まれる（`zig build e2e`）。失敗したケースは `FAIL case=... dx= dy= iou= reliable= ...` の行が
失敗文に出る。

復元（temporal.zig / restore）を変えたときは、合成の較正もやり直す:

```sh
scripts/restore-calibrate.sh -j 6 -M affine        # 数分。結果は tmp/out/restore-calibrate/affine/results.txt
scripts/restore-calibrate.sh -j 6 -M translation   # 比較用
```

毎フレーム別の模様・静止の行で coverage が 0 でなければ FAIL（動きで説明できない画素を貼っている）。

ROI の判定（閾値・照合・投票）を変えたときは、CI のケースだけでなく較正もやり直す:

```sh
scripts/roi-calibrate.sh -j 6      # 数分。結果は tmp/out/calibrate/results.txt
```

「位置が違うのに reliable=true」が 0 でなければ FAIL。数値が変わったら docs/SPEC.md §4 を更新する。

## 実素材

`tmp/media/` の動画に対して手で回す。CI では回らない。

```sh
for f in tmp/media/*; do echo "$f"; zig-out/bin/vrestore probe "$f"; done
zig-out/bin/vrestore detect-roi --ref tmp/media/<参照画像>.png --debug-dir tmp/out/<名前> tmp/media/<動画>
```

正解のある実写で数値を出すには、手元の実写に既知の位置へ焼き込む（PIL と CJK フォントが要る）:

```sh
scripts/roi-real.sh -j 6 tmp/media/<動画>     # 10 分前後。結果は tmp/out/real/
```

GUI のマウス・キー操作は自動の検査が無い。触ったら手で確かめる:

```sh
zig build gui && zig-out/bin/vrestore-gui tmp/media/<動画>
# 画面を見ずに描画結果を確かめる（選択と検出の枠、タイムライン、得票率の棒）
SDL_VIDEODRIVER=dummy zig-out/bin/vrestore-gui --select x,y,w,h --detect-and-exit --screenshot tmp/out/gui.png tmp/media/<動画>
```

復元率の基準（焼き込んだまま / 再エンコードだけ / delogo）を実写で出す:

```sh
scripts/restore-real.sh -j 6 tmp/media/<動画>  # 5 分前後。結果は tmp/out/restore/
```

`frame-overlay.png` と `roi-crop.png` を開いて、消したい場所を囲んでいるかを見る。実素材には正解が無いので、
数値で言えるのは JSON の値まで。
報告では「実素材では見ていない」を `Not verified` に書く。
