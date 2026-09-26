# vrestore — how we work

ここには**進め方**だけ書く。
**何を主張してよいか**は [`docs/SPEC.md`](docs/SPEC.md)、**なぜそう決めたか**は [`docs/adr/`](docs/adr/)、
**どう書くか**は [`.claude/rules/`](.claude/rules/)。

⚠ **同じことを 2 か所に書かない。** 片方が必ず古くなる。仕様が変わったら SPEC を直す。

作業を始める前に [`.claude/rules/README.md`](.claude/rules/README.md) を読む。

---

## 0. このリポジトリは何か

動画に固定位置で焼き付けられたウォーターマーク領域について、**時系列の映像情報から本来の背景を
できるだけ忠実に復元する**ことを試す実験的な動画ツール。Zig で書き、demux / decode / encode は
FFmpeg (libav\*) に任せる。

## 1. 第一原則

**生成する前に、映像内にある証拠から復元する。**

⚠ これは [`.claude/rules/evidence.md`](.claude/rules/evidence.md) より上には来ない。

## 2. 検証

実行するものは [`.claude/skills/verify/SKILL.md`](.claude/skills/verify/SKILL.md) だけが持つ。
README・CI・ここにコマンドを写さない。

## 3. 境界

- **ROI 検出と背景復元を分ける**（[ADR 0002](docs/adr/0002-roi-detection-is-separate-from-background-recovery.md)）。
  復元アルゴリズムを変えても ROI 検出を触らない
- コンテナ・コーデックを自前で書かない。FFmpeg に任せる（[ADR 0001](docs/adr/0001-zig-for-control-and-image-processing-ffmpeg-for-codecs.md)）
- 理由なしに入れないもの: GUI フレームワーク、FFmpeg 以外の実行時依存、2 つ目のビルドシステム、
  シングルスレッド版が動く前のスレッド化、SIMD / GPU 最適化。入れるときは ADR を先に書く

## 4. 手元の素材

⚠ **動画はコミットしない。** Public リポジトリなので、権利物・private な動画・他者のウォーターマーク
画像は一度 push したら取り消せない。

```
tmp/              # .gitignore 済み。実素材も出力も全部ここ
  media/          # 実素材。手持ちの動画をシンボリックリンクで置く
  fixtures/       # 合成素材（生成スクリプトが作る）
  out/            # 実行結果・デバッグ画像
```

```
mkdir -p tmp/media
ln -s ~/path/to/実素材.mp4 tmp/media/
```

- `.gitignore` は `git add -f` で抜けられる。最後の壁は `scripts/check-no-media.sh` で、verify と CI が回す
- CI で使う素材は CI の中で合成する。バイナリ fixture は、生成できない理由があるときだけ置く

## 5. 進め方

1. **磨く前に測る。** 直す前に、今どうなっているかを数値で言う
2. **観測**（測定値・出力）と**解釈**を分けて報告する
3. 確かめていないことを確かめたと言わない
4. `Non-goals`（SPEC §2）を越えて広げない。最小の変更が既定
5. 映像処理では「もっともらしい画像になった」ではなく「正解にどれだけ近いか」を測る。
   正解の分かる合成素材で数値を出してから実素材で見る

## 6. git

[`.claude/rules/git.md`](.claude/rules/git.md)。

## 7. 踏んだ罠

⚠ **このリポジトリで実際に起きたことだけ書く。** 行を足すときはそれを止めるテストも残す。

| 何が起きたか | 代わりにどうするか |
|---|---|
| — | — |
