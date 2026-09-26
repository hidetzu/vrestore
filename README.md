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
- `vrestore restore --roi detection.json --raw out.rgb --provenance out.prov input.mp4` — 検出した ROI の画素を、
  背景が動いて見えている別のフレームの実画素で戻す（Temporal Recovery）。戻せなかった画素は焼かれたまま残し、
  各画素の由来（provenance: 戻した `temporal_real` / 戻せなかった `unrecovered`）と coverage（戻せた割合）で
  報告する。出力は RGB24 の生フレーム（ffmpeg でエンコードする）。
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
`vrestore-gui` には SDL2（pkg-config の `sdl2`）も要ります。

```sh
zig build gui        # zig-out/bin/vrestore-gui
zig-out/bin/vrestore-gui input.mp4
```

操作: ドラッグで範囲を選ぶ / Enter で検出 / R で表示中のフレームを復元 / Space で処理前・処理後（戻せなかった画素はマゼンタ）/
P で各画素の由来を色で重ねる /
← → で 1 フレーム（Shift で 1 秒、↑ ↓ で 10 秒）/ 下の帯のクリックで移動 / Esc で消す / Q で終了

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
