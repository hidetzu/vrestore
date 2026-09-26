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

- 背景復元は、映像内にある実画素だけを戻す。戻せない画素は埋めずに未復元として残す。
  推測で埋めるのは明示したときだけ（`--fill`、[ADR 0008](docs/adr/0008-spatial-inpainting-is-opt-in-and-never-counted-as-recovered.md)）。
  各画素は由来（provenance）を持ち、推測した画素を「戻した」と数えない（[ADR 0006](docs/adr/0006-every-restored-pixel-carries-its-provenance.md)）
  （[ADR 0005](docs/adr/0005-temporal-recovery-copies-real-pixels-and-leaves-the-rest-unrecovered.md)）
- **ROI 検出と背景復元を分ける**（[ADR 0002](docs/adr/0002-roi-detection-is-separate-from-background-recovery.md)）。
  復元アルゴリズムを変えても ROI 検出を触らない
- コンテナ・コーデックを自前で書かない。FFmpeg に任せる（[ADR 0001](docs/adr/0001-zig-for-control-and-image-processing-ffmpeg-for-codecs.md)）
- GUI は SDL2 の別の実行ファイル `vrestore-gui`（[ADR 0004](docs/adr/0004-the-gui-is-a-separate-sdl2-executable-that-only-calls-the-detector.md)）。
  検出のロジックを GUI に書かない
- 理由なしに入れないもの: 別の GUI フレームワーク、FFmpeg・SDL2・SDL2_ttf（`vrestore-gui` の文字、ADR 0009）以外の実行時依存、2 つ目のビルドシステム、
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
| 手持ちの実写で、推定した移動（ピークは 0.85〜0.99 と高い）で別フレームから画素を借り、「戻した」と言った画素の 29.8% が正解から外れた（横縞のような画素を貼った）。画面全体が平行移動していない動きを、平行移動の累積で近似したため | 借りる前に ROI の周りの帯が合うかを確かめる（`temporal.zig` の `ringDiff`、閾値 6）。`zig build restore-e2e` の `restore-zoom` が止める（確かめないと外れ 3.6% で FAIL） |
| 位相相関（全帯域）で、実際は 3,1 px/フレームで動いている合成動画（crf 35）を 59 ペア中 56 ペア (0,0) と推定し、閾値を超えたので間違った画素を貼った（戻した画素の PSNR 20.4 dB）。x264 のブロックの格子（16 px）がどのフレームでも同じ位置にあり、位相相関が全周波数を同じ重みにするため | 位相相関は 0.06 cycles/px 以下だけで取る（`temporal.zig` の `max_freq`）。`zig build restore-e2e` の `restore-pan3-crf35` が止める（全帯域に戻すと coverage 0 で FAIL） |
| Zig 0.16 の `std.Io.File.Writer.init` で stdout に書いたら、`{ echo; vrestore ...; } > file` のように前の出力があるファイルで先頭から上書きした（位置指定書き込み）。`zig build` の Run ステップは stdout をパイプで受けるので、テストでは見えなかった | stdout / stderr は `.initStreaming` で開く。`build.zig` の `cli_stdout_file` が止める |
