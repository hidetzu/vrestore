# SPEC — 何を主張してよいか

ここは vrestore が自分について主張してよいことだけを書く。
進め方は [`CLAUDE.md`](../CLAUDE.md)、書き方は [`.claude/rules/`](../.claude/rules/)、理由は [`adr/`](adr/)。

⚠ 件数は書かない（[`evidence.md`](../.claude/rules/evidence.md)）。

---

## 1. 実装済み

⚠ 行を足すのは、その振る舞いが存在し、**それを検査するケース**があるときだけ。予定は実装ではない。

| 層 | 何ができるか | 何が検査しているか |
|---|---|---|
| CLI | `vrestore --version` が `build.zig.zon` の版を `vrestore <version>` と表示し、終了コード 0 で終わる | `build.zig` の `cli_version`（`zig build test` で実行ファイルを起動して stdout と終了コードを照合） |
| CLI | 知らない引数にはその引数名と使い方を stderr に出し、終了コード 2 で終わる | `build.zig` の `cli_unknown`（stderr に引数名入りのエラー文が含まれることと終了コードを照合） |
| 動画 | 動画を開き、幅・高さ・尺・平均フレームレート・コーデック名を返す。尺が取れない入力では尺を返さない | `src/video.zig` の test `"video: open reports size, duration, frame rate and codec"` |
| 動画 | 先頭から全フレームを順に RGB24 でデコードし、終端を報告する | test `"video: next decodes every frame in order, then reports the end"` |
| 動画 | 指定時刻以降の最初のフレームへ seek する（キーフレームでない位置、後ろから前への seek を含む） | test `"video: seek lands on the exact frame, including non-keyframes"` |
| 動画 | 尺全体から等間隔に N 枚取り出す | test `"video: sampleFrames spreads over the whole duration"` |
| 動画 | 動画でないファイルは開けないと報告する | test `"video: a file that is not a video fails to open"`、`build.zig` の `cli_probe_bad` |
| CLI | `vrestore probe <video>` が 1 フレーム目までデコードしてから、幅・高さ・尺・コーデックを JSON 1 行で出す | `build.zig` の `cli_probe`（stdout 全体を照合） |
| CLI | stdout が他の出力と共有された通常ファイルでも、前の出力を上書きしない | `build.zig` の `cli_stdout_file` |
| 画像 | RGB24 を PNG に書き、PNG を RGB24 で読んで同じ画素に戻る | test `"video: encodePng then loadImage round-trips the pixels exactly"` |
| ROI | 参照画像を切り出した元の画像から、切り出した位置を 0px で見つける（画面の端を含む） | `src/roi.zig` の test `"roi: locate finds an exact crop, including at the edges"` |
| ROI | 同じ模様が 2 か所にあると margin が 0 近くに落ちる。PSR はほとんど落ちない | test `"roi: an exact duplicate drives margin to zero, while PSR stays high"` |
| ROI | 輪郭の無い参照画像はエラー。比べる相手の位置が無いときは margin / PSR を null にし、reliable と言わない | test `"roi: a flat reference is rejected, and a search with no other position cannot be reliable"`、`build.zig` の `cli_detect_flat_ref` |
| ROI | 複数フレームで投票し、最頻位置と得票率を返す。閾値を下回れば理由付きで reliable=false | test `"roi: detect votes for the fixed position even when some frames miss"` |
| CLI | `vrestore detect-roi --ref <image> <video>` が JSON 1 行を出す。`--debug-dir` で `detection.json` / `frame-overlay.png` / `roi-crop.png` も書く | `src/detect_roi.zig` の test `"detect_roi: writeJson"`、`"detect_roi: drawRect leaves the inside untouched and clips at the edges"`。画像の中身は目視（下記） |
| CLI | 読めない参照画像は、何が悪いかを stderr に出して終了コード 1 | `build.zig` の `cli_detect_bad_ref` |
| ROI（合成 E2E） | 既知の位置に焼いたウォーターマークを、yuv420p にエンコードした動画から `dx=0, dy=0, IoU=1, reliable=true` で見つける（背景のパン・毎フレーム変わる背景・滑らかな背景、crf 16〜35、不透明度 0.35〜1、余白なしの参照、一部だけの参照） | `zig build e2e` の `roi check pan-full` `pan-faint-crf35` `cut-full` `flat-full` `pan-tight` `pan-part` |
| ROI（合成 E2E） | 繰り返す文字列の途中を切った参照で、得票率も PSR も高いまま別の行に当たるとき、reliable=false を返す | `zig build e2e` の `roi check repeat-mid` |
| ROI（合成 E2E） | ウォーターマークの無い（背景が動く）動画では reliable=false を返す | `zig build e2e` の `roi check absent` |
| 指標 | 矩形の中で、R/G/B ごとの MSE と SSIM（x264 / FFmpeg vf_ssim と同じ 8x8 窓・4px 刻み）を出す。同じ画像なら SSIM 1・MSE 0、矩形の外は数えない | `src/metrics.zig` の test `"metrics: identical images score SSIM 1 and MSE 0"`、`"metrics: only pixels inside the rect count"`、`"metrics: MSE and PSNR of a uniform offset"` |
| 指標（外部照合） | `vrestore compare --per-frame` の SSIM（R/G/B/全体）と MSE（R/G/B/平均）が、FFmpeg の `ssim` / `psnr` フィルタとフレームごとに一致する（SSIM は差 2e-6 以内、MSE は 0.006 以内。FFmpeg の出力桁の丸め分）。素材は RGB の可逆（ffv1 gbrp）なので、色変換の違いはこの照合に含まれない | `zig build metrics` の `metrics crosscheck` |
| CLI | `vrestore compare [--rect x,y,w,h] [--per-frame] <reference> <test>` が、フレーム数と大きさが同じ 2 本を先頭から順に比べ、SSIM の平均と最小・MSE の平均・PSNR（平均 MSE から）を JSON 1 行で出す。フレーム数が違えばエラー | `src/compare.zig` の test `"compare: parseRect"`、`zig build metrics`（出力の値）。フレーム数違いのエラーは手で確かめただけ |
| GUI | フレームを窓にアスペクト比を保って置き（レターボックス）、画面座標とフレームの画素座標を相互に変換する。余白は端に寄せる | `src/gui_state.zig` の test `"gui: fit letterboxes a wide frame into a tall window, and maps back"`、`"gui: toScreen is the inverse of toFrame for the corners of a rect"` |
| GUI | ドラッグの向きによらず同じ矩形を選ぶ。クリックだけ（大きさ 0）は前の選択を消さない | test `"gui: selection works in any drag direction and ignores a plain click"` |
| GUI | タイムラインの横位置から時刻を出す（端に寄せる）。選択範囲を表示中のフレームから切り出して参照画像にする | test `"gui: timeline maps position to time and clamps"`、`"gui: crop cuts the selected pixels"` |
| GUI（E2E） | `vrestore-gui` が動画を開いて指定時刻のフレームを出し、選択範囲から CLI と同じ検出（`detect_roi.detectInVideo`）を回して、既知の位置を `dx=0, dy=0, reliable=true` で返す。SDL のダミー描画で窓を開かずに回す | `zig build gui` の `roi check gui` |
| GUI | マウスのドラッグ・キー操作・タイムラインのクリック | ⚠ 自動の検査は無い（[ADR 0004](adr/0004-the-gui-is-a-separate-sdl2-executable-that-only-calls-the-detector.md) の帰結） |
| 復元 | 位相相関（低い周波数だけ）で隣り合うフレームの平行移動を推定する。上下左右どちら向きでも、固定のウォーターマークがあっても正しい | `src/temporal.zig` の test `"temporal: estimateShift finds a pan in every direction, ignoring a fixed watermark"` |
| 復元 | 位相相関の窓をウォーターマークの ROI と重ならない所から取る | test `"temporal: chooseWindow keeps the window off the ROI and takes the largest"` |
| 復元 | 相関のピークが閾値未満のペアで鎖を切り、動いていないとは見なさない | test `"temporal: Track cuts the chain at an unestimated pair instead of assuming no motion"` |
| 復元 | 戻したと言った画素（由来 `temporal_real`）は正解と一致し、戻せなかった画素は焼かれたまま残って由来が `unrecovered` になる。ROI の外は `original`。推定した移動量が間違っていれば、ROI の周りの帯が合わないのでそのフレームからは借りない。動かない背景では何も戻らない | test `"temporal: recoverFrame restores the exact background under a pan, refuses frames whose surroundings do not match, and reports what it could not"` |
| 由来 | 各画素の由来（provenance）を 1 バイトで表す: 0 `original`（ROI の外）、1 `unrecovered`、2 `temporal_real`。3 / 4 は予約（`alpha_recovered` / `spatial_inpainted`）。知らない値は読まない | `src/provenance.zig` の test `"provenance: byte values are part of the file format"` |
| 由来 | coverage は ROI の中の画素のうち、証拠から戻した由来（今は `temporal_real` だけ）の割合。ROI の外は数えない | test `"provenance: coverage counts recovered pixels over the ROI, not pixels outside it"` |
| CLI | `vrestore restore (--roi <detection.json> \| --rect) --raw <out.rgb> [--provenance <out>] <video>` が RGB24 の生フレームと由来を書き、coverage と由来ごとの画素数を JSON で出す | `zig build restore-e2e`（`restore-pan15` で `temporal_real` の割合 ≥ 0.99、`restore-cut` で `unrecovered` の割合 = 1） |
| CLI | `vrestore compare --provenance` が、由来ごとに画素数・割合・PSNR・外れた画素（どれかの色で 32 より大きい差）の割合を出す。`masked_*` は coverage に数える由来の画素をまとめたもの。由来によらない矩形全体の外れた画素の割合（`bad_fraction`）はいつも出す。`--roi` で detect-roi の JSON を矩形にする | test `"metrics: mseWhere counts only pixels with the label inside the rect"`、`"metrics: badPixels counts pixels off by more than bad_pixel_error in any color"`、`zig build restore-e2e` |
| 復元（合成 E2E） | パンする背景で、ウォーターマークの ROI をほぼすべて戻し、正解に近い（パン 15 px: coverage ≥ 0.99・SSIM ≥ 0.9・戻した画素の PSNR ≥ 35。パン 7,3: ≥ 0.95・≥ 0.88・≥ 34。遅いパン × crf 35: coverage ≥ 0.6・戻した画素の PSNR ≥ 30） | `zig build restore-e2e` の `restore-pan15` `restore-pan7` `restore-pan3-crf35` |
| 復元（合成 E2E） | 動きで説明できない（毎フレーム別の模様）・動かない背景では、1 画素も戻さない | `zig build restore-e2e` の `restore-cut` `restore-flat` |
| 復元（合成 E2E） | 画面全体の平行移動ではない動き（ズーム）で、戻した画素のうち外れた画素が 2% 以下 | `zig build restore-e2e` の `restore-zoom` |
| GUI | R で表示中のフレームを戻し（CLI と同じ部品・閾値）、Space で処理前 / 処理後を切り替える。戻せなかった画素はマゼンタ。P で各画素の由来の色（`temporal_real` 緑、`unrecovered` マゼンタ）を重ね、窓のタイトルに由来ごとの割合を出す | `zig build gui` の `gui restore check`（coverage のみ）。表示は `--screenshot` で目視。キー操作は自動の検査なし |
| リポジトリ衛生 | 動画・巨大ファイルが git の管理下に無い | `scripts/check-no-media.sh` |

## 2. ROI 検出の契約

**入力:** 動画 1 本 + ウォーターマーク参照画像 1 枚（利用者が「これを消したい」と切り出した領域）。

解く問題は「どれがウォーターマークか」ではなく「**指定されたウォーターマークが、動画内のどこに
固定されているか**」。返す矩形は参照画像の大きさそのもの（余白を含めて切ったなら、余白込み）。

**出力（JSON 1 行）:**

```json
{"x":493,"y":5,"width":142,"height":77,"confidence":1.000,"psr":12.9,"margin":0.552,"peak":0.949,"frames_voted":15,"reliable":true,"reasons":[]}
```

| キー | 意味 |
|---|---|
| `confidence` | 投票での最頻位置の得票率 |
| `margin` | その位置の相関と、それ以外で最も良い位置の相関の差（最頻位置に投票したフレームの平均）。測れないときは `null` |
| `psr` | 相関のピークの突出度（同上）。**判定には使わない**、診断用 |
| `peak` | 相関 (ZNCC) の値（同上） |
| `reliable` | `confidence >= 0.4` かつ `margin >= 0.08`。閾値の根拠は §4、PSR を使わない理由は [ADR 0003](adr/0003-reliable-is-decided-by-vote-ratio-and-margin-not-psr.md)（⚠ 暫定。判定方式は見直し中） |
| `reasons` | reliable=false の理由: `low_confidence` / `low_margin` / `low_psr`（`--min-psr` を与えたときだけ）/ `unmeasured_margin` |

**デバッグ出力（`--debug-dir <dir>`）:** `detection.json`（stdout と同じ）、`frame-overlay.png`（投票に使った
1 枚目のフレームに検出矩形の外枠を描く。reliable なら赤、そうでなければ黄）、`roi-crop.png`（同じフレームから
検出矩形を切り出したもの）。

**参照画像の切り方（利用者向け）:** 小さく切らない。ウォーターマーク全体の特徴が入るよう、余白を含めて
大きめに選ぶ。繰り返す文字列の一部だけを切ると、別の行・別の周期に当たる（§4）。
yuv420p の動画を `ffmpeg -vf crop` で切ると座標と大きさが偶数に丸められるので、RGB に変換してから切る
（`-vf format=rgb24,crop=...`）。

## 3. 意図して実装しないこと（現段階）

| 実装しない | 理由 |
|---|---|
| 背景復元の Alpha / Spatial / 生成 | Temporal だけを先に入れた（[ADR 0005](adr/0005-temporal-recovery-copies-real-pixels-and-leaves-the-rest-unrecovered.md)）。戻せない画素は未復元のまま残す |
| Temporal の小数画素・回転・ズーム・被写体ごとの動き | 画面全体の整数画素の平行移動だけ（ADR 0005） |
| ウォーターマークの自動発見 | 解く問題を「指定されたものの位置」に絞る |
| MP4 の書き出し | 復元が無い段階で出すものが無い |
| 動画プレイヤー UI | CLI / テストで境界を作るのが先。導入時に ADR を書く |
| GPU / SIMD 最適化 | 測って遅いと分かってから |
| 動かない背景とウォーターマークの区別 | 解く問題は「参照画像がどこに固定されているか」なので、背景が静止している動画では、切った背景そのものが毎フレーム同じ位置にあり、正しく見つかる（較正で観測）。それがウォーターマークかどうかは判定しない |
| 大きさ・向きの違う参照画像 | 照合は平行移動だけ。別の解像度の動画から切った参照画像は当たらないか、相関が低くなる |

## 4. 測定値

⚠ 分母・日付・条件の無い数値は、直すのではなく消す。

| 何を測ったか | 値 | いつ | 条件 |
|---|---|---|---|
| yuv420p を経由した灰色の往復誤差（RGB24 で見た値 − 合成時の値） | 最大 1（全 10 フレーム、全画素） | 2026-09-26 | 64x48 / 10 fps / libx264 `-qp 0` / 灰色 16+20k（k=0..9）。ffmpeg 8.1.1 コマンドの rawvideo rgb24 出力で観測。テストの許容差 2 はこれに基づく |

### ROI 検出の較正（`scripts/roi-calibrate.sh`）

2026-09-26、macOS、zig 0.16.0、ffmpeg 8.1.1（libx264, `-preset veryfast`）、ReleaseFast、各ケース 1 回。
640x360 / 10 fps / 30 フレーム、15 フレームで投票。条件は全組み合わせ:
背景 {パン 7px,3px/フレーム・毎フレーム別の模様・静止した滑らかなグラデーション} × crf {16, 23, 35} ×
不透明度 {1, 0.6, 0.35} × 参照 {余白 6px・余白 0・1 行目の先頭 3 文字・繰り返し文字列（周期 3）の途中 1 周期} ×
seed {1, 2}、および ウォーターマーク無し（背景が動くもの）× crf × seed。
参照画像はエンコード後の 1 フレーム目から切る。ウォーターマークは乱数のグリフ（縁取り付き）で、フォントは使わない。

| 何を測ったか | 値 |
|---|---|
| 位置が正しかった（dx=0, dy=0）: 繰り返し以外 | 162 / 162 |
| 位置が正しかった: 繰り返し文字列の途中を切った参照 | 34 / 54（外れた 20 件は別の行または周期に当たった） |
| 閾値 0.4 / 0.08 で、位置が違う（またはウォーターマークが無い）のに reliable=true | 0 / 228 |
| 閾値 0.4 / 0.08 で、位置が正しいのに reliable=false: 繰り返し以外 | 0 / 162 |
| 閾値 0.4 / 0.08 で reliable=true になった繰り返し文字列のケース | 11 / 54（すべて位置が正しい） |
| ウォーターマーク無しで reliable=true | 0 / 12 |
| 位置が外れた繰り返し文字列のケースの PSR | 4.1〜23.3（得票率 0.067〜1.000） |
| 位置が正しかった繰り返し以外のケースの PSR | 4.2〜20.2 |
| 得票率 ≥ 0.4 で位置が違うケースの margin の最大 | 0.021 |
| 位置が正しかった繰り返し以外のケースの margin の最小 | 0.112 |
| 得票率 + PSR のどの閾値の組み合わせ（得票率 0〜1 を 0.05 刻み、PSR 0〜20 を 0.5 刻み）でも、位置が違うのに reliable=true を 0 にできたか | できなかった |

解釈: margin の閾値 0.08 は、外れたケースの最大 0.021 と正しいケースの最小 0.112 の間にある。
この閾値は姉妹プロジェクト mp4tool で別の合成素材から較正されたもので、ここでは測り直して変えていない。

### ROI 検出: 実写に焼き込んだ素材（`scripts/roi-real.sh`）

2026-09-26、同じ環境。手元の実写 1 本（1920x1080、29.97 fps、固定カメラ、照明が大きく変わる）の 10 秒間に、
既知の位置へウォーターマークを焼き込んで yuv420p（libx264 veryfast）で再エンコード。焼き込んだ位置が正解。
条件は全組み合わせ: ウォーターマーク 5 種（日本語 4 行 / URL 1 行 / 同じ語 3 回の繰り返し / 図形 + 語 / 小さい 1 語。
PIL と実フォントで描画）× 位置 4（左上・上中央・中央・右下）× 不透明度 {1, 0.5, 0.25} × crf {20, 32} ×
参照 {余白 12px・余白 0・左 1/3 + 余白 4px}。参照画像は焼き込み後の 16 フレーム目から切る。各 1 回。

| 何を測ったか | 値 |
|---|---|
| 位置が正しかった（dx=0, dy=0） | 354 / 360 |
| 外れた 6 件の条件 | すべて不透明度 0.25 かつ左 1/3 の参照。6 件とも reliable=false |
| 閾値 0.4 / 0.08 で、位置が違うのに reliable=true | 0 / 360 |
| 閾値 0.4 / 0.08 で、位置が正しいのに reliable=false | 22 / 354 |
| 繰り返す語の一部を切った参照が隣の語に当たったケース | 1 件（dx=390、得票率 0.600、PSR 14.9、margin 0.043 → reliable=false） |
| ウォーターマークを焼かない動画で、参照を切った位置に reliable=true で当たった | 13 / 24（固定カメラで背景が静止しているため。§3） |

解釈: 合成素材と同じく、位置違いを止めているのは margin。ウォーターマークの無い動画での reliable=true は
誤検出ではなく、静止した背景を正しく見つけている。参照画像がウォーターマークかどうかはこのツールでは判定できない。

### 復元率の基準（`scripts/restore-real.sh`）

「復元率」= 処理後の動画が、ウォーターマークを焼く前の元の動画にどれだけ一致するか。
ウォーターマークの外接矩形の中で `vrestore compare` の SSIM（フレーム平均）を見る。

2026-09-26、同じ環境。手元の実写 1 本（1920x1080、固定カメラ）の 5 秒を可逆（ffv1）で固定したものを正解とし、
ウォーターマーク 3 種（日本語 4 行 / URL 1 行 / 図形 + 語）× 位置 2（左上の暗い所・中央の人と照明が動く所）×
不透明度 {1, 0.5} × crf {20, 32} の 24 ケース。各 1 回。復元方式の出力は可逆で保存。

| 行 | SSIM（24 ケースの平均） | 範囲（ケースごとの平均） |
|---|---|---|
| 焼き込んだまま（下限） | 0.379 | 0.159〜0.663 |
| 元の動画を同じ crf で再エンコードしただけ（上限） | 0.927 | 0.880〜0.970 |
| FFmpeg delogo（detect-roi の検出矩形 = 余白 12px 込み） | 0.471 | 0.306〜0.722 |
| FFmpeg delogo（ウォーターマークぴったりの矩形） | 0.519 | 0.336〜0.806 |

観測: delogo は左上の暗い所では焼き込んだままより上がる（例: URL 不透明度 1 / crf 20 で 0.190 → 0.806）が、
中央では下がることがある（例: 図形 + 語 不透明度 0.5 / crf 20 で 0.663 → 0.344）。
解釈（未検証）: 中央は人や照明の模様があり、delogo の内挿がそれを塗りつぶす。半透明のウォーターマークは
背景が透けて残っているので、塗りつぶすより焼き込んだままの方が元に近い。

### Temporal Recovery の較正（`scripts/restore-calibrate.sh`）

2026-09-26、macOS、zig 0.16.0、ffmpeg 8.1.1（libx264 veryfast）、ReleaseFast、各 1 回。640x360 / 10 fps / 60 フレーム、
窓は前後 15 フレーム、位相相関の閾値 0.5、帯の差の閾値 6。条件は全組み合わせ: 動き {パン 3,1 / 7,3 / 15,0 px/フレーム・
毎フレーム別の模様・静止} × 位置 {右上の角・中央} × crf {16, 23, 35} × 不透明度 {1, 0.5} × seed {1, 2}（各 12 ケース）。
ROI は detect-roi の検出矩形（ウォーターマーク + 余白 6 px）。正解はウォーターマークを焼く前の同じ背景（可逆）。
SSIM・coverage は 12 ケースの平均。

| 動き / 位置 | 焼き込んだまま SSIM | 再エンコードだけ（上限） | Temporal SSIM | coverage | 戻した画素の PSNR（最悪ケース） | 上限の PSNR（最悪ケース） |
|---|---|---|---|---|---|---|
| パン 15,0 / 中央 | 0.170 | 0.933 | 0.931 | 1.000 | 33.4 | 34.1 |
| パン 15,0 / 角 | 0.159 | 0.939 | 0.842 | 0.906 | 32.3 | 34.3 |
| パン 7,3 / 中央 | 0.170 | 0.942 | 0.901 | 0.988 | 31.9 | 34.7 |
| パン 7,3 / 角 | 0.161 | 0.940 | 0.373 | 0.426 | 30.8 | 34.3 |
| パン 3,1 / 中央 | 0.171 | 0.940 | 0.562 | 0.675 | 32.1 | 34.3 |
| パン 3,1 / 角 | 0.157 | 0.938 | 0.231 | 0.294 | 29.7 | 34.0 |
| 毎フレーム別の模様 | 0.164〜0.171 | 0.900 | 焼き込んだままと同じ | 0 | — | — |
| 静止 | 0.111〜0.137 | 0.990 | 焼き込んだままと同じ | 0 | — | — |

| 何を測ったか | 値 |
|---|---|
| 戻した画素のうち外れた画素（どれかの色で 32 より大きい差）: パン全体 | 0.05%（33,173,840 画素中） |
| 正しいパンのペアの位相相関のピーク | 0.848〜0.999 |
| 毎フレーム別の模様（対応が無い）のペアのピーク | 0.094〜0.226（すべて閾値未満で鎖を切った） |
| 全帯域の位相相関で正しく推定できたペア（crf 35・パン 3,1・角、numpy で同じ計算） | 0 / 59（(0,0) と推定。周波数の上限 0.1 で 13 / 59、0.06 で 56 / 59） |

解釈: coverage が低いのは、窓（前後 15 フレーム）の間に背景がウォーターマークの幅だけ動かない所（遅いパン）と、
画面の角（背景が画面外へ出る・帯の一部が画面外で確かめられない）。戻した画素の PSNR が上限より 1〜4 dB 低いのは、
強い圧縮で移動量が ±1 px ずれるため（未検証）。

### provenance への置き換えで評価値が変わらないこと

2026-09-26、同じ環境。二値マスクを provenance に置き換える前に保存した `scripts/restore-calibrate.sh` の結果と、
置き換えた後に同じ 120 ケースを回した結果を比べた。

| 何を比べたか | 値 |
|---|---|
| restore の recovered / pixels / coverage / coverage_min / pairs_cut / peak_min / peak_max、compare の SSIM / SSIM 最小 / MSE / PSNR / 戻した画素の数・割合・PSNR・外れた画素の割合、焼き込んだまま・再エンコードだけの SSIM / PSNR、検出の位置と reliable | 120 ケース × 24 値 = 2,880 個すべて一致 |
| 由来の内訳（unrecovered + temporal_real）と pixels、temporal_real と recovered | 120 ケースすべて一致 |

### Temporal Recovery: 手持ちの実写に焼き込んだ素材（帯の確認の較正）

2026-09-26、同じ環境。手元の実写 1 本（640x360、29.97 fps、手持ちの揺れ・被写体の動き・寄り引きがある）から
20 秒ずつ 3 区間を取り、「復元率の基準」と同じ 24 通りのウォーターマーク（1920 幅基準の大きさを 0.35 倍）を焼き込んだ
72 ケース。元のクリップ（可逆）が正解。帯の差の閾値だけを変えて、同じ入力に `vrestore restore` をかけた。各 1 回。

| 帯の差の閾値 | ウォーターマークの外接矩形のうち戻した割合（平均） | 戻した画素のうち外れた画素 | 戻した画素の PSNR（最悪ケース） |
|---|---|---|---|
| 確かめない | 0.104 | 29.8% | 13.2 |
| 12 | 0.019 | 7.9% | 17.6 |
| 8 | 0.007 | 4.3% | 23.9 |
| **6（既定）** | **0.004** | **1.8%** | **25.2** |
| 4 | 0.001 | 0.3% | 28.7 |

| 何を測ったか | 値 |
|---|---|
| 再エンコードだけで外れた画素（矩形の全画素、72 ケース） | 最大 1.1% |
| 合成のパン（中央）の coverage への影響（閾値 6） | 変わらない（15,0: 1.000、7,3: 0.988、3,1: 0.680 → 0.680） |
| 合成のズーム（1%/フレーム、crf 23）: 確かめない → 閾値 6 | 外れた画素 3.6% → 0.0%、戻した割合 0.375 → 0.104 |

解釈: この素材は画面全体が平行移動していないので、ほとんど戻らないのが正しい。確かめないと、ピークの高い
（0.85〜0.99）推定で間違った画素を「戻した」と言っていた。閾値 4 はさらに外れが少ないが、合成のパン 7,3（中央）の
coverage が 0.988 → 0.942 に下がったので 6 にした。

### Temporal Recovery: 実写（固定カメラ）

2026-09-26、同じ環境。「復元率の基準」と同じ 24 ケース（実写 1 本、固定カメラ、5 秒）に `vrestore restore`（帯の差の閾値 6）を加えた。

| 何を測ったか | 値 |
|---|---|
| ウォーターマークの外接矩形のうち戻せた割合 | 0.000（24 ケースすべて） |
| Temporal の SSIM（24 ケースの平均） | 0.377（焼き込んだまま 0.379） |
| 隣り合うフレームの推定（1 ケース、149 ペア） | (0,0) が 84、±1 px の揺れが残り、ピーク 0.675〜0.961 |

解釈: カメラが固定なので、隠れた背景はどのフレームにも写っていない。戻せないのが正しい。
この素材では Temporal Recovery は効かない。

### ROI 検出: 合成でない素材で見たもの

2026-09-26、同じ環境。正解座標が無いので、目視と全探索による検算だけ。

| 素材 | 結果 |
|---|---|
| mp4tool の合成素材（PIL と実フォントで描いた透かし、640x360、crf 18）。背景の違う別の動画のフレームから、RGB で切った参照画像 | 2 か所とも生成時の座標と一致（dx=0, dy=0）、reliable=true |
| 手元の実素材 1 本（640x360、正解なし） | reliable=true（得票率 0.733、margin 0.286、peak 0.322）。全解像度の全探索（4 フレーム）でも同じ位置が最良。roi-crop.png は目視で参照画像と同じ透かし。peak が低いのは、参照画像がこの動画から切ったものではないためと推測（未確認） |
