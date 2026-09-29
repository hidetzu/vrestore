# vrestore

> **Experimental.** 実験段階のプロジェクトです。CLI・出力形式・内部構造は予告なく変わります。

動画に固定位置で焼き付けられたウォーターマーク領域について、**時系列の映像情報から本来の背景を
できるだけ忠実に復元する**ことを試す、実験的な動画復元ツールです。

生成で「それらしく埋める」前に、他のフレームに写っている実際の画素など、映像内にある証拠から
復元することを目指します。

## 現在できること

- `vrestore detect-roi --ref <image> <video>` — 消したいウォーターマークを切り出した画像を渡すと、
  それが動画内のどこに固定されているかを探し、位置と信頼度を JSON で出す。
  `--debug-dir <dir>` で、検出した矩形を重ねたフレームと切り出し画像も書き出す
- `vrestore-gui <video>` — フレームを見ながらウォーターマークの範囲をドラッグで選び、Enter で検出する確認用の画面。
  検出した位置が枠で重なり、得票率・margin・reliable が窓のタイトルに出る（`zig build gui` で作る。SDL2 が要る）
- `vrestore restore --roi detection.json --out restored.mp4 input.mp4` — 検出した ROI の画素を、
  背景が動いて見えている別のフレームの実画素で戻す（Temporal Recovery）。戻せなかった画素は焼かれたまま残し、
  各画素の由来（provenance: 戻した `temporal_real` / 戻せなかった `unrecovered`）と coverage（戻せた割合）で
  報告する。動きは画面全体の affine（平行移動 + 回転 + 拡大縮小）で追う（`--motion translation` で平行移動だけ）。
  `--mask auto` で、ROI の中のウォーターマークの画素（動画を通して色が変わらない画素）だけを埋め、文字の間などに
  見えている本物の背景は残す（実写で取りこぼしがあるので既定は使わない）。
  `--fill harmonic` で、戻せなかった画素を周囲から推測して埋める（背景が明るさしか変わらない所では前のフレームと混ぜて
  ちらつきを抑える。`--stable-fill off` で止める）（由来 `spatial_inpainted`、coverage には数えない。
  既定では埋めない）。`--out` で全フレームを H.264 の MP4 に書き出し、元の音声を再符号化せずに入れる
  （`--crf` で画質、`--audio none` で音声なし）。`--raw out.rgb` で RGB24 の生フレーム、`--provenance` で各画素の由来も書ける。
  別のフレームから借りるのは、既定（`--temporal auto`）では前後のフレームが合い、動きが落ち着いた画素だけ
  （`--temporal on` で今までの方式、`off` で借りない）。`--debug out.mp4` で、各画素の扱いと借りたフレームを動画で見られる。
  背景が動かない動画（固定カメラ）では何も戻らない
- `vrestore compare --rect x,y,w,h <original> <processed>` — 処理後の動画が元の動画にどれだけ一致するかを、
  矩形の中で SSIM / PSNR で出す（復元の良さを測るためのもの）
- `vrestore probe <video>` — 動画を FFmpeg で開いて 1 フレーム目までデコードし、幅・高さ・尺・コーデックを JSON で出す

```sh
vrestore detect-roi --ref watermark.png --debug-dir debug input.mp4
```

参照画像は小さく切らず、ウォーターマーク全体と少しの余白を含めて切ってください。
出力の読み方と、検出を信頼してよい条件は [docs/SPEC.md](docs/SPEC.md) §2。

## 現在できないこと

背景復元は、背景が平行移動する動画で隠れた画素を別のフレームから戻す方式（Temporal Recovery）だけです。
戻せない画素は埋めずに残すので、ウォーターマーク除去ツールとして完成したものではありません。

## Build / Test

Zig（版は [`build.zig.zon`](build.zig.zon) の `minimum_zig_version`）と FFmpeg が必要です。
FFmpeg は `ffmpeg` コマンドと、pkg-config で見つかる開発用ライブラリ（libavformat / libavcodec / libswscale / libavutil）を使います。
`vrestore-gui` には SDL2（pkg-config の `sdl2`）と SDL2_ttf（Homebrew の `sdl2_ttf`、Ubuntu の `libsdl2-ttf-dev`）も要ります。
パネルの文字はシステムのフォントで描きます（`--font` で指定、見つからなければ数字だけの内蔵フォント）。

```sh
zig build gui        # zig-out/bin/vrestore-gui
zig-out/bin/vrestore-gui input.mp4
```

操作:
- 再生: Space で再生 / 一時停止。映像の上の操作パネル（10 秒戻る・▶・10 秒進む、シークバー、時刻とフレーム番号）はドラッグで動かせる。H で隠す
- 場面の共有: C で `A.mp4 t=1234.501 frame=36998` のような 1 行をクリップボードにコピー。`--frame 36998` / `--at 1234.501` で同じ場面を開ける
- 移動: ← → で 1 フレーム（Shift で 1 秒、↑ ↓ で 10 秒）、操作パネルのシークバー
- 検出と復元: ドラッグで範囲を選ぶ / Enter で検出 / R で表示中のフレームを復元 / B で処理前・処理後（戻せなかった画素はマゼンタ）/
  P で各画素の由来を色で重ねる / M で動きのモデル（affine / translation）/ F で戻せなかった画素を周囲から埋めるか / K でウォーターマークの画素だけを埋めるか / T で別のフレームから借りるか（auto / on / off）/ E で全フレームを動画の隣の `<名前>-restored.mp4` に書き出す（音声付き、X で止める）/ Esc で消す / Q で終了

```sh
zig build            # zig-out/bin/vrestore
zig build test
```

変更を確かめる手順は [`.claude/skills/verify/SKILL.md`](.claude/skills/verify/SKILL.md) にまとめてあります。

## ドキュメント

- [docs/SPEC.md](docs/SPEC.md) — 何ができて、何を次にやるか
- [docs/adr/](docs/adr/) — なぜそう決めたか
- [CLAUDE.md](CLAUDE.md) — 開発の進め方（動画素材の置き場所を含む）

## 動画素材について

このリポジトリには動画をコミットしません。テストに使う動画は CI の中で合成します。
