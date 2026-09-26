# vrestore

> **Experimental.** 実験段階のプロジェクトです。CLI・出力形式・内部構造は予告なく変わります。

動画に固定位置で焼き付けられたウォーターマーク領域について、**時系列の映像情報から本来の背景を
できるだけ忠実に復元する**ことを試す、実験的な動画復元ツールです。

生成で「それらしく埋める」前に、他のフレームに写っている実際の画素など、映像内にある証拠から
復元することを目指します。

## 現在できること

- `vrestore probe <video>` — 動画を FFmpeg で開いて 1 フレーム目までデコードし、幅・高さ・尺・コーデックを JSON で出す
- 内部: 動画から任意時刻のフレームを RGB24 で取り出す（ROI 検出の土台）

## 現在できないこと

背景復元はまだ入っていません。ウォーターマーク除去ツールとしては使えません。
次の段階は、指定したウォーターマークの位置を動画から検出する **ROI 検出**です
（[docs/SPEC.md](docs/SPEC.md) §2）。

## Build / Test

Zig（版は [`build.zig.zon`](build.zig.zon) の `minimum_zig_version`）と FFmpeg が必要です。
FFmpeg は `ffmpeg` コマンドと、pkg-config で見つかる開発用ライブラリ（libavformat / libavcodec / libswscale / libavutil）を使います。

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
