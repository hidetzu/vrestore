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
| GUI（書き出し） | E で、検出した ROI と今の設定のまま全フレームを MP4 に書き出す（子プロセスの `vrestore restore --out`）。出力は元の動画の隣に上書きしない名前で置く。フレーム数と音声のパケットが入力と同じ | `zig build gui` の `gui export check`（`vrestore-gui --detect-and-exit --export`、`check-restore` と `check-audio`）。出力の名前・引数・進み具合・残り時間は `src/export_job.zig` の test。X で止める・窓を閉じる経路は自動の検査なし |
| GUI | フレームを窓にアスペクト比を保って置き（レターボックス）、画面座標とフレームの画素座標を相互に変換する。余白は端に寄せる | `src/gui_state.zig` の test `"gui: fit letterboxes a wide frame into a tall window, and maps back"`、`"gui: toScreen is the inverse of toFrame for the corners of a rect"` |
| GUI | ドラッグの向きによらず同じ矩形を選ぶ。クリックだけ（大きさ 0）は前の選択を消さない | test `"gui: selection works in any drag direction and ignores a plain click"` |
| GUI | 選択範囲を表示中のフレームから切り出して参照画像にする | test `"gui: crop cuts the selected pixels"` |
| GUI（E2E） | `vrestore-gui` が動画を開いて指定時刻のフレームを出し、選択範囲から CLI と同じ検出（`detect_roi.detectInVideo`）を回して、既知の位置を `dx=0, dy=0, reliable=true` で返す。SDL のダミー描画で窓を開かずに回す | `zig build gui` の `roi check gui` |
| GUI（プレイヤー） | 操作パネルは映像の下寄り中央に出て、ドラッグで動かしても映像の外へ出ない。映像の領域が縮んだら押し戻す。情報があるときは 3 段目を足す | `src/player_state.zig` の test `"player: the panel starts at the bottom centre and stays inside the video when dragged"`、`"player: the panel is pushed back inside when the video area shrinks, and grows a row for info"` |
| GUI（プレイヤー） | 10 秒戻る / 再生 / 10 秒進むが重ならず、シークバーは経過時刻と全体の長さの間に収まる | test `"player: the controls do not overlap, and the seek bar sits between the two times"` |
| GUI（プレイヤー） | パネルの文字のフォント: 明示したもの（`--font` / `VRESTORE_FONT`）があればそれ、無ければシステムのフォントを順に探す。明示したものが無いときは別のフォントに黙って替えない | `src/fonts.zig` の test `"fonts: an explicit font wins, and is not silently replaced when missing"` |
| GUI（プレイヤー） | パネルの上で押した操作は ROI の選択にならない（再生 / 10 秒戻る・進む / シーク / パネルの移動）。パネルを隠していれば選択になる。ROI を選んでいる間はパネルを描かない | test `"player: presses on the panel never start an ROI selection"` |
| GUI（プレイヤー） | シークバーの横位置から時刻。再生の時計は再生中だけ進む。進めるべきフレーム数を決め、1 秒以上遅れたら・戻ったら seek | test `"player: seek bar maps position to time"`、`"player: the clock advances with wall time only while playing"`、`"player: advance reads the frames that are due, and seeks when far behind"` |
| GUI（プレイヤー） | 時刻の表示（パネルは `00:13:32`）、フレーム番号、共有用の 1 行 `<名前> t=<秒> frame=<番号>` | test `"player: time, frame number and the share line"`、`src/glyphs.zig` の test（パネルの文字） |
| GUI（プレイヤー、E2E） | `--frame` で指定したフレームを開き、再生と同じ経路で N フレーム進め、末尾では止まり、共有用の 1 行を出す | `zig build gui` の `gui share frame` `gui share play` `gui share end` |
| GUI | マウスのドラッグ・キー操作・操作パネルのドラッグと再生 | ⚠ 自動の検査は無い（[ADR 0004](adr/0004-the-gui-is-a-separate-sdl2-executable-that-only-calls-the-detector.md) の帰結） |
| 復元 | 位相相関（低い周波数だけ）で隣り合うフレームの平行移動を推定する。上下左右どちら向きでも、固定のウォーターマークがあっても正しい | `src/temporal.zig` の test `"temporal: estimateShift finds a pan in every direction, ignoring a fixed watermark"` |
| 復元 | affine の合成・逆変換。最小二乗で正確な affine を当て、独自に動くブロックを外れ値として除く（乱数を使わない RANSAC）。ばらばらに動くブロックなら推定できなかったと返す | `src/motion.zig` の test `"motion: compose and inverse"`、`"motion: least squares recovers an exact affine, and RANSAC ignores a block that moves on its own"`、`"motion: too few consistent blocks means not estimated"` |
| 復元 | ブロックの動きから、1% の拡大 + 0.5 度の回転を画面の四隅で 1 px 未満の誤差で推定する | test `"motion: estimateAffine finds a small zoom and rotation between two frames"` |
| 補間 | `--fill` は unrecovered の画素だけを埋めて `spatial_inpainted` にし、見えている画素（ROI の外・Temporal の実画素）は変えない | `src/spatial.zig` の test `"spatial: fills only unrecovered pixels and labels them spatial_inpainted"` |
| 補間 | harmonic は埋めた各画素を上下左右の平均にする（ラプラス方程式を解く）。directional はそうならない。線形の勾配は harmonic で正解との差 1 以内 | test `"spatial: harmonic makes every filled pixel the average of its neighbours, directional does not"`、`"spatial: harmonic reproduces a linear gradient exactly, directional is close"` |
| マスク | 背景が変わる中で変わらない画素（ウォーターマーク）を見分け、2 px 広げる（縁取りの外側の圧縮のにじみまで隠す）。背景も変わらなければ見分けられないとして ROI 全体を隠す。大津の二値化で 2 つの塊を分ける | `src/wmask.zig` の test `"wmask: finds the pixels that stay the same while the background changes"`、`"wmask: falls back to hiding the whole ROI when the background does not move either"`、`"wmask: otsu splits two clusters"` |
| マスク（縁） | 勾配の時間方向の中央値が大きい画素（どのフレームでも同じ縁）も隠す。背景と一緒に色が変わる不透明度 30% の棒を、変わりにくさだけでは 55% しか隠せないが、縁を足すとすべて隠す | `src/wmask.zig` の test `"wmask: the edges catch a translucent watermark that the stillness alone misses"` |
| マスクの範囲 | マスクを使うときは、推定して埋める範囲を ROI の周り 8 px まで広げる（動画の端で止める）。ROI の外でもマスクの内側なら埋め、マスクの外は入力のまま。Temporal の範囲は広げない | test `"maskArea: widens only with the mask, and stops at the frame edge"`、`"fillAndTally: fills the watermark pixels outside the ROI too, and keeps the rest as input"` |
| マスク（見分けられないとき） | 変わりやすさで見分けられないときも、ROI の中はすべて隠し、周りの帯（ROI + 8 px）では、どのフレームでも同じ縁（ROI からはみ出した文字）だけを 2 px 広げて隠す。縁の閾値は範囲全体の中央値から取り直す（背景が止まり文字の方が少し変わる場面で、「変わりにくくない画素」を基準にすると閾値が高すぎて、はみ出しを拾えなかった） | `src/wmask.zig` の test `"wmask: when it cannot tell, it hides the ROI and only the watermark's edges sticking out of it"` |
| マスク（ROI 全体に戻す判定） | 隠す割合の判定（2%〜95%）は、縁を足す前・広げる前の変わりにくい画素で行う。縁と広げた分で 100% になっても、見分けられていればマスクを使う | `src/wmask.zig` の test `"wmask: whether the mask is used is judged before the edges and the dilation widen it"` |
| マスク（合成 E2E） | `--mask auto` で、毎フレーム別の模様の背景を harmonic で埋めて SSIM ≥ 0.67（ROI 全体を埋めると 0.649）、本物のウォーターマークの画素の再現率 ≥ 0.99 | `zig build restore-e2e` の `restore-cut-mask`（check-mask を含む） |
| 埋めの落ち着かせ | 前のフレームでも埋めた画素は、見えている背景の明るさの変化 Δ を足した前の値と混ぜる（λ = 0.3）。明るさが 1 フレームに +1 変わる背景で、埋めた値の乱れ（±6）が半分未満になり、フェードに遅れない（±3 以内）。範囲の中をすべて埋めていても周りの画素で Δ を測る。見えている画素がばらばらに変わる（動いた）ときは混ぜない | `src/stabilize.zig` の test `"stabilize: a static background averages the jitter of the fill, and a fade is followed without lag"`、`"stabilize: the brightness change is measured around the area when every pixel in it is guessed"`、`"stabilize: when the visible background changes (it moved), the fill is not blended"` |
| 埋めの落ち着かせ（合成 E2E） | 動かない背景では全フレームで混ぜ、動く背景では混ぜない | `zig build restore-e2e` の `restore-flat-fill`（`stable_fill.blended` ≥ 59）、`restore-pan7-fill`（≤ 0） |
| 補間（合成 E2E） | 動かない滑らかな背景を harmonic で埋めると SSIM ≥ 0.95、coverage は 0 のまま。パンでは Temporal の実画素を変えずに残りを埋める | `zig build restore-e2e` の `restore-flat-fill` `restore-pan7-fill` |
| 復元 | 位相相関の窓をウォーターマークの ROI と重ならない所から取る | test `"temporal: chooseWindow keeps the window off the ROI and takes the largest"` |
| 復元 | 相関のピークが閾値未満のペアで鎖を切り、動いていないとは見なさない | test `"temporal: Track cuts the chain at an unestimated pair instead of assuming no motion"` |
| 復元 | 戻したと言った画素（由来 `temporal_real`）は正解と一致し、戻せなかった画素は焼かれたまま残って由来が `unrecovered` になる。ROI の外は `original`。推定した移動量が間違っていれば、ROI の周りの帯が合わないのでそのフレームからは借りない。動かない背景では何も戻らない | test `"temporal: recoverFrame restores the exact background under a pan, refuses frames whose surroundings do not match, and reports what it could not"` |
| 復元（借りない範囲） | 別のフレームから、マスクで隠した画素（マスクが無ければ ROI + 8 px）の中は借りず、移動の確かめはその外の帯で行う。ROI がウォーターマークより 4 px 小さくても、はみ出した縁を借りない | `zig build restore-e2e` の `restore-overhang`（coverage ≥ 0.9、外れ ≤ 0.001。守る範囲が無いと coverage 0、ROI + 4 px だと外れ 0.0157） |
| 復元（auto） | `--temporal auto`（既定）は、前後のフレームの両方から取れて値が近く（≤ 10）、帯の差 ≤ 4、動きが落ち着いた（跳ね ≤ 2 px）画素だけを戻したと数える。前後で違う物体が写っていれば採らず、跳ねたペアを越えて借りない。動画の最後のフレームでは採らない。off は借りない | `src/temporal.zig` の test `"temporal: auto takes a pixel only when the frames before and after agree, and it is exact"`、`"temporal: auto rejects a pixel whose frames before and after disagree (something moved there)"`、`"temporal: auto does not borrow across a pair whose motion jumps"` |
| 復元（auto、合成 E2E） | auto で採った画素は外れない。毎フレーム別の模様では採らない。off は借りない | `zig build restore-e2e` の `restore-pan7-auto`、`restore-overhang-auto`（外れ ≤ 0.001）、`restore-cut-auto`、`restore-pan7-off` |
| debug の可視化 | `--debug` で、画素の扱い（緑 = 別のフレームから戻した、赤 = auto の条件を通らず推測で埋めた、青 = 候補なしで推測で埋めた、マゼンタ = 埋めていない）と、借りたフレーム（過去 = 青系、未来 = 橙系、遠いほど明るい、灰色 = 不採用）を横並びに描く。.mp4 なら入力と同じフレーム数・幅 2 倍の動画、ディレクトリなら 1 フレーム 1 枚の PNG | `src/debug_view.zig` の test、`zig build restore-e2e` の `restore-debug mp4 check`・`restore-debug png check` |
| 復元（明るさ） | 借りた画素に、ROI の周りの帯で測った明るさの差（表示中 − 借りたフレーム、R/G/B の平均）を足す。露出がフレームごとに 1 ずつ変わる動画でも、戻した画素は表示中のフレームの正解と一致する | test `"temporal: recoverFrame matches the brightness of the borrowed pixels to the frame shown"` |
| 由来 | 各画素の由来（provenance）を 1 バイトで表す: 0 `original`（ROI の外）、1 `unrecovered`、2 `temporal_real`、4 `spatial_inpainted`。3 は予約（`alpha_recovered`）。知らない値は読まない | `src/provenance.zig` の test `"provenance: byte values are part of the file format"` |
| 由来 | coverage は ROI の中の画素のうち、証拠から戻した由来（今は `temporal_real` だけ）の割合。ROI の外と、推測で埋めた `spatial_inpainted` は数えない | test `"provenance: coverage counts recovered pixels over the ROI, not pixels outside it"` |
| CLI | `--window` は 1〜255（窓のフレーム数が temporal.max_window_frames = 511 に収まる範囲） | `src/main.zig` の test `"parseArgs: restore"` |
| CLI | `vrestore restore (--roi <detection.json> \| --rect) (--out <out.mp4> \| --raw <out.rgb>) [--crf <n>] [--audio copy\|none] [--provenance <out>] [--motion affine\|translation] [--fill none\|directional\|harmonic] [--mask none\|auto] <video>` が全フレームを H.264 の MP4 と / または RGB24 の生フレームに書き、由来を書き、coverage と由来ごとの画素数を JSON で出す | `zig build restore-e2e`（`restore-pan15` で `temporal_real` の割合 ≥ 0.99、`restore-cut` で `unrecovered` の割合 = 1） |
| 書き出し | `--out` の MP4 は、入力と同じ数のフレームを元の時刻で持ち、`--raw` で同時に書いた RGB との差は H.264 の符号化の分だけ（合成のパンで PSNR 42.2 dB・SSIM 0.984、判定 ≥ 38 / ≥ 0.97）。元の音声（AAC）のパケットは数も中身も同じ（再符号化しない） | `zig build restore-e2e` の `restore-export`（`check-restore` と `roi_fixture check-audio`） |
| 書き出し（色） | デコードと書き出しで、同じ色の範囲・行列（ストリームの記述、無ければ BT.601・limited）を使う。フルレンジの入力（yuv420p + color_range=pc）の暗部・明部を潰さない。出力には入力と同じ範囲を付ける | `zig build test` の `cli_full_range check`（明るさ 0〜255 の傾斜、VP9 の劣化なし → `--crf 0`、ffmpeg に範囲の記述どおり RGB にさせて PSNR ≥ 40） |
| 書き出し（回転・大きさ） | 回転の情報（display matrix）を写す。幅か高さが奇数なら、理由を言って書き始める前に止める | `zig build test` の `cli_rotation check`（rotation = 90）、`cli_odd_out`（321x181） |
| 書き出し（音声） | 元に音声が無ければ音声なし（JSON は `"audio":"absent"`）、`--audio none` なら入れない。MP4 に入らない音声（ADPCM・μ-law・WMA などで手元で確認）なら書き始める前に止める | 手元で確認（自動の検査なし） |
| CLI | `vrestore compare --provenance` が、由来ごとに画素数・割合・PSNR・外れた画素（どれかの色で 32 より大きい差）の割合を出す。`masked_*` は coverage に数える由来の画素をまとめたもの。由来によらない矩形全体の外れた画素の割合（`bad_fraction`）はいつも出す。`--roi` で detect-roi の JSON を矩形にする | test `"metrics: mseWhere counts only pixels with the label inside the rect"`、`"metrics: badPixels counts pixels off by more than bad_pixel_error in any color"`、`zig build restore-e2e` |
| 復元（合成 E2E） | パンする背景で、ウォーターマークの ROI をほぼすべて戻し、正解に近い（パン 15 px: coverage ≥ 0.99・SSIM ≥ 0.9・戻した画素の PSNR ≥ 35。パン 7,3: ≥ 0.95・≥ 0.88・≥ 34。遅いパン × crf 35: coverage ≥ 0.6・戻した画素の PSNR ≥ 30） | `zig build restore-e2e` の `restore-pan15` `restore-pan7` `restore-pan3-crf35` |
| 復元（合成 E2E） | 動きで説明できない（毎フレーム別の模様）・動かない背景では、1 画素も戻さない | `zig build restore-e2e` の `restore-cut` `restore-flat` |
| 復元（合成 E2E） | 画面全体の平行移動ではない動き（ズーム）で、戻した画素のうち外れた画素が 2% 以下 | `zig build restore-e2e` の `restore-zoom` |
| 復元（合成 E2E） | 回転 + パンで、affine（既定）が ROI の 8 割以上を戻し、SSIM ≥ 0.75、外れた画素 ≤ 1% | `zig build restore-e2e` の `restore-rotpan`（平行移動では coverage 0.57・SSIM 0.44 で FAIL） |
| 復元（合成 E2E） | `--motion translation` でもパン 7,3 を戻す | `zig build restore-e2e` の `restore-pan7-translation` |
| GUI | T で Temporal（auto / on / off）を切り替え、K でマスク（auto / none）を切り替え、Space で再生 / 一時停止、H で操作パネルを隠す、C で場面（動画名・時刻・フレーム番号）をクリップボードと標準出力へ。B で処理前 / 処理後。F で戻せなかった画素を埋めるか（none / harmonic）を切り替え、M で動きのモデル（affine / translation）を切り替え、窓のタイトルに出す。R で表示中のフレームを戻し（CLI と同じ部品・閾値）、戻せなかった画素はマゼンタで見せる。P で各画素の由来の色（`temporal_real` 緑、`unrecovered` マゼンタ）を重ね、窓のタイトルに由来ごとの割合を出す | `zig build gui` の `gui restore check`（coverage のみ）。表示は `--screenshot` で目視。キー操作は自動の検査なし |
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
| 実写での Temporal Recovery の既定での使用（on） | 画面全体の動きで借りた画素は、実写では外れがある（疑似チェックで画面の端 8.0%、中央 1.5%）。既定は auto で、確かめを通った画素だけを採る（ADR 0017） |
| 背景復元の Alpha Inversion / 生成 | Temporal と Spatial（推測、既定では行わない）だけ（[ADR 0005](adr/0005-temporal-recovery-copies-real-pixels-and-leaves-the-rest-unrecovered.md)、[ADR 0008](adr/0008-spatial-inpainting-is-opt-in-and-never-counted-as-recovered.md)） |
| マスクの既定での使用 | `--mask auto` で使える（ADR 0010、0011）。既定は ROI 全体を隠す。実写で取りこぼしはほぼ無くなったが、背景の動かない縁も隠すので適合率は 0.30〜0.40 |
| Temporal の被写体ごとの動き（ROI 周辺の block motion / optical flow） | 動きは画面全体の affine（ADR 0007）。手持ちの実写で戻らないのは、背景が窓の中で露出していないためで、局所的な動きを追っても戻らない（SPEC §4） |
| ウォーターマークの自動発見 | 解く問題を「指定されたものの位置」に絞る |
| 音声の再符号化、MP4 以外の出力形式、映像のコーデックの選択 | 出力は H.264（libx264）の MP4 だけ。音声はそのまま写し、MP4 に入らない形式なら止めて `--audio none` を案内する（ADR 0013） |
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

### Temporal Recovery: affine と平行移動の比較（`scripts/restore-calibrate.sh -M`）

2026-09-26、同じ環境・条件。上の 120 ケースに、画面中央を軸にした動き（`bg=warp`）を 4 通り足した 216 ケース:
回転 0.3 度/フレーム、拡大 0.5%/フレーム、回転 0.2 度 + パン 5,2、拡大 0.3% + パン 5,2（それぞれ位置 2 × crf 3 × 不透明度 2 ×
seed 2）。同じ入力に `--motion translation` と `--motion affine` をかけた。SSIM・coverage は 12 ケースの平均、
外れた画素は行の全ケースの戻した画素に対する割合。

| 動き / 位置 | 上限（再エンコードだけ） | SSIM 平行移動 → affine | coverage 平行移動 → affine | 外れた画素 平行移動 → affine |
|---|---|---|---|---|
| パン 15,0 / 中央 | 0.933 | 0.931 → 0.932 | 1.000 → 1.000 | 0.00% → 0.00% |
| パン 15,0 / 角 | 0.939 | 0.842 → 0.849 | 0.906 → 0.898 | 0.06% → 0.02% |
| パン 7,3 / 中央 | 0.942 | 0.901 → 0.908 | 0.988 → 0.987 | 0.01% → 0.01% |
| パン 7,3 / 角 | 0.940 | 0.373 → 0.364 | 0.426 → 0.367 | 0.10% → 0.01% |
| パン 3,1 / 中央 | 0.940 | 0.562 → 0.561 | 0.675 → 0.668 | 0.01% → 0.00% |
| パン 3,1 / 角 | 0.938 | 0.231 → 0.210 | 0.294 → 0.205 | 0.28% → 0.00% |
| 回転 0.2 度 + パン 5,2 / 中央 | 0.927 | 0.464 → 0.813 | 0.573 → 0.908 | 0.04% → 0.00% |
| 回転 0.2 度 + パン 5,2 / 角 | 0.921 | 0.180 → 0.386 | 0.136 → 0.389 | 0.32% → 0.03% |
| 拡大 0.3% + パン 5,2 / 中央 | 0.931 | 0.447 → 0.796 | 0.555 → 0.891 | 0.05% → 0.01% |
| 拡大 0.3% + パン 5,2 / 角 | 0.926 | 0.181 → 0.359 | 0.167 → 0.355 | 0.36% → 0.03% |
| 回転 0.3 度 / 中央 | 0.926 | 0.185 → 0.185 | 0.029 → 0.065 | 0.01% → 0.00% |
| 回転 0.3 度 / 角 | 0.923 | 0.158 → 0.231 | 0.000 → 0.212 | 0.00% → 0.01% |
| 拡大 0.5% / 中央 | 0.932 | 0.177 → 0.177 | 0.065 → 0.091 | 0.05% → 0.01% |
| 拡大 0.5% / 角 | 0.934 | 0.157 → 0.176 | 0.000 → 0.140 | 0.00% → 0.00% |
| 毎フレーム別の模様・静止 | 0.900 / 0.990 | 変わらず | 0 → 0 | — |

| 何を測ったか | 値 |
|---|---|
| 216 ケース全体の戻した画素のうち外れた画素 | 平行移動 0.062%（44,972,487 画素中）→ affine 0.010%（55,514,963 画素中） |
| 平行移動の出力が affine への一般化の前後で同じか（上の 120 ケースの評価値） | 2,880 個すべて一致 |
| 処理時間（640x360・60 フレーム、合成 3 ケース） | 平行移動 0.71〜0.72 秒、affine 1.91〜1.95 秒 |

解釈: 中心を軸にした回転・拡大だけの動きは、ROI が中心付近にあると背景がほとんど動かないので、どちらでも戻らない。

### Temporal Recovery: affine と平行移動の比較（実写）

2026-09-26、同じ環境。「手持ちの実写に焼き込んだ素材」の 72 ケースと、「実写（固定カメラ）」の 24 ケースに、
`--motion translation` と `--motion affine` をかけた（帯の差の閾値 6）。ウォーターマークの外接矩形で測る。

| 素材 | 戻した割合（平均）平行移動 → affine | 戻した画素のうち外れた画素 平行移動 → affine | SSIM（平均）平行移動 → affine（焼き込んだまま） |
|---|---|---|---|
| 手持ちの実写 72 ケース | 0.0039 → 0.0001 | 1.76% → 0.24% | 0.2022 → 0.2014（0.2016） |
| 固定カメラの実写 24 ケース | 0 → 0 | — | 0.3773 → 0.3773（0.3787） |

手持ちの実写のうち 2 区間（48 ケース）で、帯の差の閾値を変えた:

| 閾値 | 平行移動: 戻した割合 / 外れた画素 | affine: 戻した割合 / 外れた画素 |
|---|---|---|
| 確かめない | 0.1538 / 29.8% | 0.0050 / 18.3% |
| 12 | 0.0282 / 7.9% | 0.0021 / 4.4% |
| 6（既定） | 0.0058 / 1.8% | 0.0002 / 0.24% |

| 何を測ったか | 値 |
|---|---|
| affine で追った ROI の中心の、前後 15 フレームでの最大の動き（1 ケースずつ、ROI 183 x 43） | 600 秒の区間: 中央値 3.3 px・90 パーセンタイル 5.4 px、2500 秒の区間: 8.7 px・13.7 px |
| 窓を広げたときのウォーターマークの外接矩形のうち戻した割合（2500 秒の区間、不透明度 1・crf 20 の 6 ケース、affine） | 前後 15 フレーム: 0〜0.17%、30: 0〜1.1%、60: 0〜1.5%（外れた画素は 0.3% 以下） |

解釈: この実写では、ウォーターマークの下の背景が窓の中でほとんど露出していない（動きが ROI の高さの半分にも届かない）。
affine で戻る割合が小さいのは正しい。平行移動が「戻した」画素の多くは、±1 px の揺れの累積による見かけの露出。

### Spatial Inpainting（`scripts/restore-real.sh` の fill-* の行）

2026-09-26、同じ環境。「手持ちの実写に焼き込んだ素材」の 3 区間（各 24 ケース）と「実写（固定カメラ）」の 24 ケース。
動きは affine、帯の差の閾値 6。`--fill directional` / `--fill harmonic` を Temporal の後にかけた。ウォーターマークの
外接矩形の中を元の動画と比べる。SSIM は 24 ケースの平均。

| 素材 | 焼き込んだまま | 再エンコードだけ（上限） | delogo（検出矩形） | delogo（ぴったりの矩形） | Temporal のみ | directional | harmonic |
|---|---|---|---|---|---|---|---|
| 手持ち・600 秒の区間 | 0.234 | 0.941 | 0.319 | 0.443 | 0.234 | 0.311 | 0.360 |
| 手持ち・2500 秒の区間 | 0.185 | 0.955 | 0.620 | 0.709 | 0.184 | 0.608 | 0.673 |
| 手持ち・5000 秒の区間 | 0.186 | 0.936 | 0.524 | 0.622 | 0.186 | 0.514 | 0.545 |
| 固定カメラ | 0.379 | 0.927 | 0.471 | 0.519 | 0.377 | 0.462 | 0.485 |

| 何を測ったか | 値 |
|---|---|
| harmonic で焼き込んだままより SSIM が上がったケース | 83 / 96（600 秒 18 / 24、2500 秒 24 / 24、5000 秒 24 / 24、固定カメラ 17 / 24） |
| harmonic で上がらなかったケース（不透明度別） | 不透明度 0.5: 9 / 48、1: 4 / 48 |
| harmonic で埋めた画素だけの PSNR（手持ち 72 + 固定 24 ケースの平均） | 18.4 dB |
| 合成（crf 23、中央の ROI）: 動かない滑らかな背景 | 埋めない SSIM 0.099 → directional 0.994 → harmonic 0.997（coverage は 0 のまま） |
| 合成（同）: パン 7,3 | 埋めない SSIM 0.928 → harmonic 0.942（Temporal で戻らなかった 1.2% を埋めた） |

解釈: 「delogo（ぴったりの矩形）」は焼き込んだ位置を知っている測定側だけが使えるもので、埋める範囲が小さいぶん元に近い。
検出した ROI は余白を含むので、harmonic は余白まで埋めている。

### ウォーターマークのマスク（`--mask auto`）

2026-09-26〜27、同じ環境。harmonic で埋める。列の意味:
「変わりにくさ」= hidetzu/vrestore#11、「+ 縁（1 px）」= 縁を ROI の中央値基準で足し 1 px 広げたもの、
「今回」= 縁を背景の中央値基準（5 倍、下限 8）で足し、全体を 2 px 広げ、マスクの範囲を ROI の周り 8 px まで広げたもの（ADR 0011）。

合成（640x360 / 10 fps / 60 フレーム / crf 23、中央の ROI、各 1 ケース）。再現率 = 本物のウォーターマークの画素のうち
隠れている扱いにした割合（`roi_fixture check-mask`）。「今回」は Temporal の明るさ合わせ（ADR 0012）込み:

| 背景 | SSIM: ROI 全体 → 変わりにくさ → 今回 | 外れた画素: ROI 全体 → 変わりにくさ → 今回 | 再現率 |
|---|---|---|---|
| パン 7,3 | 0.942 → 0.942 → 0.942 | 0.01% → 0.00% → 0.00% | 1.0000 |
| パン 7,3（不透明度 50%） | — → 0.942 → 0.942 | — → 0.00% → 0.00% | 1.0000 |
| 遅いパン 3,1 | 0.855 → 0.881 → 0.856 | 6.36% → 1.14% → 6.08% | 1.0000 |
| 毎フレーム別の模様 | 0.649 → 0.758 → 0.689 | 29.89% → 2.92% → 19.87% | 1.0000 |
| 回転 0.2 度 + パン 5,2 | 0.920 → 0.923 → 0.920 | 0.71% → 0.09% → 0.67% | 1.0000 |
| 静止（見分けられないので ROI 全体） | 0.997 → 0.997 → 0.997 | 0 → 0 → 0 | 1.0000 |

手持ちの実写に焼き込んだ 3 区間と固定カメラ（各 24 ケース、「Spatial Inpainting」と同じ条件、動きは affine）。
ウォーターマークの外接矩形の SSIM（24 ケースの平均）と、焼いた PNG の不透明な画素に対する再現率。
「今回」の実写は明るさ合わせ（ADR 0012）の前に測った（実写では Temporal で戻る画素が外接矩形のほぼ 0% なので、影響は小さいと見込む。未測定）:

| 素材 | 焼き込んだまま | harmonic（ROI 全体） | 変わりにくさ | + 縁（1 px） | 今回 | 参考: delogo（ぴったりの矩形） |
|---|---|---|---|---|---|---|
| A 600 秒 | 0.234 | 0.360 | 0.441 | 0.402 | 0.380 | 0.443 |
| A 2500 秒 | 0.185 | 0.673 | 0.781 | 0.753 | 0.741 | 0.709 |
| A 5000 秒 | 0.186 | 0.545 | 0.656 | 0.629 | 0.602 | 0.622 |
| 固定カメラ 200 秒 | 0.379 | 0.485 | 0.530 | 0.570 | 0.549 | 0.519 |

| 素材 | マスクを使えた（変わりにくさ → 今回） | 再現率 最小（変わりにくさ → + 縁 → 今回） | 入力のまま残して正解から外れた画素 / 外接矩形（変わりにくさ → + 縁 → 今回） |
|---|---|---|---|
| A 600 秒 | 22 → 24 / 24 | 0.930 → 1.0000 → 1.0000 | 0.28% → 0.02% → 0.01% |
| A 2500 秒 | 24 → 24 / 24 | 0.976 → 1.0000 → 1.0000 | 0.27% → 0.04% → 0.03% |
| A 5000 秒 | 24 → 23 / 24 | 0.985 → 0.9998 → 0.9988 | 0.13% → 0.01% → 0.01% |
| 固定カメラ 200 秒 | 24 → 24 / 24 | 0.644 → 0.9987 → 0.9997 | 2.37% → 0.31% → 0.24% |

「入力のまま残して正解から外れた画素」は、由来が `original` の画素のうち誤差 > 32 のもの（残ったウォーターマークの見積もり）。

| 何を測ったか | 値 |
|---|---|
| A の 72 ケースでのマスク（変わりにくさ）の効果（SSIM の差、マスク − ROI 全体） | 平均 +0.100、最小 −0.057、最大 +0.326。下がったのは 9 / 72 |
| 今回のマスクの効果（SSIM の差、今回 − ROI 全体） | A 600 / 2500 / 5000 秒・固定カメラ: 平均 +0.019 / +0.068 / +0.058 / +0.064。下がったのは 4 / 4 / 0 / 1（各 24 ケース中） |
| 縁を足した効果（SSIM の差、+ 縁 − 変わりにくさ） | A 600 / 2500 / 5000 秒: 平均 −0.039 / −0.028 / −0.028。固定カメラ: 平均 +0.040、最小 −0.088、最大 +0.609（不透明度 50% の URL、0.155 → 0.763） |
| 隠す割合の平均（今回、マスクの範囲 = ROI の周り 8 px まで に対して） | 92% / 81% / 73% / 83% |
| PSNR の平均: ROI 全体 → 変わりにくさ → 今回 | A 600 秒 16.10 → 18.31 → 17.05、A 2500 秒 19.54 → 23.33 → 21.36、A 5000 秒 21.06 → 24.94 → 23.10、固定カメラ 16.87 → 17.91 → 18.81 dB |
| 最初の設計（Temporal の範囲もマスクで絞る）での合成のパン 7,3 | SSIM 0.942 → 0.804（採らなかった、ADR 0010） |
| Temporal の範囲まで ROI の周り 8 px に広げた場合の合成の遅いパン（同じ範囲の temporal_real） | 430049 → 307902 画素、SSIM 0.856 → 0.801（採らなかった、ADR 0011） |

解釈: 取りこぼし（再現率 < 1）の画素はウォーターマークが残る。縁を足すと取りこぼしがほぼ無くなり、残るウォーターマークは
減るが、隠す（推測で埋める）画素が増えるので、背景が動く素材では外接矩形の SSIM が下がる。
SSIM は少数の画素に残るウォーターマークをほとんど罰しない。この評価のウォーターマーク（PNG を焼いたもの）は縁のにじみが少なく、
手持ちの実写に元から焼かれていた縁取り付きの文字で見えた点線の縁取り（2 px 広げると消えた、目視）は、この表には出にくい。

### 埋めの落ち着かせ（`--stable-fill`、ADR 0015）

2026-09-27、同じ環境。

手持ちの実写 A の先頭 30 秒（平らな灰色のフェードイン）、マスク auto（この 30 秒では見分けられず ROI 全体）+ harmonic。
ちらつき = 埋めた面（検出した ROI の内側）のフレーム間の変化から、その平均の変化（フェード）を引いた残りの絶対値の平均:

| 設定 | 1〜11 フレーム（フェード中） | 1〜119 フレーム | フェード中の埋めた面の明るさの、混ぜない場合との差（最大） |
|---|---|---|---|
| 混ぜない | 0.67 | 0.47 | 0 |
| λ = 0.3（既定） | 0.48 | 0.25 | 0.44 |
| λ = 0.15 | 0.43 | 0.19 | 0.49 |
| λ = 0.1 | 0.46 | 0.18 | 0.68 |
| 参考: 埋めていない周りの背景 | 0.12 | 0.02 | — |

実写 96 ケース（「ウォーターマークのマスク」と同じ、今回のマスク + harmonic、混ぜない → λ = 0.3）。SSIM / PSNR は外接矩形の全フレーム、
ちらつきと埋めた画素の誤差は先頭 60 フレームの、続けて埋めた画素:

| 素材 | SSIM | PSNR | 埋めた画素の誤差 | ちらつき（正解） | 混ぜたフレームの割合 |
|---|---|---|---|---|---|
| A 600 秒 | 0.3795 → 0.3795 | 17.05 → 17.05 | 24.75 → 24.70 | 1.20 → 1.08（2.55） | 49% |
| A 2500 秒 | 0.7410 → 0.7410 | 21.38 → 21.39 | 11.84 → 11.98 | 1.19 → 1.14（1.76） | 46% |
| A 5000 秒 | 0.6024 → 0.6022 | 23.10 → 23.11 | 15.72 → 15.72 | 2.97 → 2.95（7.55） | 31% |
| 固定カメラ | 0.5488 → 0.5478 | 18.80 → 18.81 | 26.89 → 26.91 | 3.70 → 3.65（7.33） | 40% |

SSIM が下がったのは 15 / 96（最大 −0.0026）、上がったのは 0。合成 6 ケースは、背景が動く 5 ケースで全フレーム混ぜず（結果は同じ）、
静止で全フレーム混ぜて PSNR 42.91 → 42.95。

解釈: 正解との近さはほぼ変えずに、平らな背景で目に付くちらつきを減らす。評価の 96 ケースは模様のある背景が多く、
埋めた面のちらつきは正解より小さいので、効果は小さい。

### マスクを見分けられないときの、はみ出しの扱い

2026-09-29、同じ環境。手持ちの実写 A の先頭 30 秒（白い背景のフェード。マスクは見分けられない）、本物の ROI 505,5 120x72、
`--mask auto --fill harmonic`。ROI の左に 2 px はみ出した文字の縁（x = 503〜504）が、前は ROI の外として残り、それを手がかりに
埋めて紫のにじみが中へ広がった（目視）。直した後は、マスクの範囲（ROI + 8 px）のうち隠す割合が 72.2%（ROI だけ）→ 76.5% になり、
にじみは消えた（目視）。

### Temporal Recovery: 借りない範囲と auto（ADR 0016 / 0017）

2026-09-29、同じ環境。

合成（640x360 / 10 fps / 60 フレーム / crf 23、`--fill none`、正解と比べる）。「縮め」は ROI をウォーターマークの外接矩形から縮めた幅（はみ出しの幅）。
coverage / 外れ（誤差 > 32 の割合、戻した画素のうち）:

| 背景・縮め | on・借りない範囲なし（hidetzu/vrestore#16 まで） | on・ROI + 4 px | on・ROI + 8 px（今の on） | on・マスク | auto |
|---|---|---|---|---|---|
| パン 7,3・0 | 0.965 / 1.31% | 0.994 / 0.01% | 0.987 / 0.00% | 0.995 / 0.01% | 0.450 / 0.00%（ROI = 検出） |
| パン 7,3・2 | 0 / — | 0.997 / 0.02% | 0.991 / 0.00% | 0.996 / 0.01% | — |
| パン 7,3・4 | 0 / — | 0.970 / 1.57% | 0.995 / 0.01% | 0.997 / 0.01% | 0.571 / 0.00% |
| 遅いパン 3,1・0 | 0.565 / 2.36% | 0.649 / 0.00% | 0.539 / 0.00% | 0.681 / 0.00% | 0.028 / 0.00%（ROI = 検出） |
| 回転 + パン・0 | 0.775 / 0.59% | 0.926 / 0.00% | 0.890 / 0.00% | 0.932 / 0.00% | 0.116 / 0.00%（ROI = 検出） |

手持ちの実写 A の疑似チェック（`scripts/temporal-pseudo-check.sh`、20 クリップ × 20 秒、ウォーターマークの無い場所に 120x72 の矩形。
左上 = 本物の ROI を左右反転した位置、中央。`--mask none --fill none`）。coverage / 外れ / 戻した画素の PSNR:

| 設定 | 左上 | 中央 |
|---|---|---|
| on・借りない範囲なし | 0.0099 / 8.0% / 20.7 dB | 0.0172 / 1.5% / 30.1 dB |
| on・ROI + 3 px | 0.0047 / 9.4% / 19.6 dB | 0.0036 / 2.6% / 28.6 dB |
| on・ROI + 8 px | 0.0025 / 11.3% / 18.6 dB | 0.0007 / 7.0% / 25.2 dB |
| **auto（既定）** | 0（1 画素も採らない） | 0 |

参考（別の調査、40 クリップ・左右反転の位置）: 同じ画素を harmonic で埋めると外れ 8.65%・20.1 dB。

同じ実写の 60 秒（本物の ROI、`--mask auto --fill harmonic`、既定の auto）: 採用 11,570 画素・不採用 251,532 画素（ROI の画素の 0.07% を採用）。
先頭 30 秒（フェード）: 採用 0・不採用 1,554。

解釈: 実写では画面全体の動きで借りた画素は当てにならず、auto はほぼ採らない。借りない範囲は、はみ出しのある合成では外れを消すが、
はみ出しの無い実写では戻す量を減らし外れを増やす（大きく動くフレームほど、画面全体の動きの近似が合わない、と考える。未検証）。

### YUV と RGB の往復（デコード → 書き出し）

2026-09-28、同じ環境。手持ちの実写 A の先頭 30 秒の 60 フレームを、何も変えずに `--crf 0`（劣化なし）で書き出し、YUV の平面で入力と比べた
（差の平均 / 絶対値の平均）:

| swscale の設定（デコードと書き出しの両方） | Y | U | V |
|---|---|---|---|
| bilinear + accurate_rnd（hidetzu/vrestore#15 まで） | −1.382 / 1.404 | −0.008 / 0.481 | −0.123 / 0.209 |
| bilinear + accurate_rnd + full_chroma_int / inp | −0.062 / 0.079 | −0.083 / 0.789 | −0.016 / 0.228 |
| **bicubic + accurate_rnd + full_chroma_int / inp（今）** | −0.063 / 0.086 | −0.071 / 0.511 | −0.018 / 0.119 |

前の設定では、色差を横に補間しない経路を通り、画面全体が約 1.4 暗くなっていた（書き出した MP4 の ROI の外で R/G/B −1.84 / −1.62 / −1.57）。
デコードの変換なので、検出・マスク・復元・比較の画素値にも同じ偏りが乗っていた。

フルレンジの入力（明るさ 0〜255 の横の傾斜、色差 128、`--crf 0`、ffmpeg に範囲の記述どおり RGB にさせて比べる）:

| 入力 | 範囲を渡す前 | 渡した後 |
|---|---|---|
| VP9 劣化なし、yuv420p + color_range=pc | 17 → 0、241 → 255、差の平均 8.22 | 一致（差 0.00） |
| x264 劣化なし、yuvj420p | 差の平均 0.45 | 一致（差 0.00） |

### 書き出しの時間（`restore --out`）

2026-09-27、同じ環境（Apple M2 Max 上の x86_64 / Rosetta、ReleaseFast、他に重い処理なし）。手持ちの実写 A（640x360・30 fps）の 10 秒（300 フレーム）、
手で選んだ ROI 113x69、動きは affine:

| 設定 | 時間 | 1 フレームあたり |
|---|---|---|
| 平行移動、埋めない、マスクなし、`--raw /dev/null` | 6.60 秒 | 22 ms |
| affine、埋めない | 11.96 秒 | 40 ms |
| affine、harmonic | 18.47 秒 | 62 ms |
| affine、harmonic、`--mask auto`（マスクの推定 1 回を含む） | 26.12 秒 | 87 ms |
| 同じ設定で `--out`（H.264 crf 18・preset medium、音声を写す） | 26.31 秒 | 88 ms |
| 同じ設定で `--out`、60 秒（1800 フレーム） | 126.96 秒 | 71 ms（約 14 fps） |

harmonic の反復を先に並べる前（`perf(spatial)` の前）は、同じ 300 フレームの harmonic の分が約 2 倍だった（並行して別の処理が走っていた測定なので目安）。
反復回数を 300 → 1500 → 5000 にしても、実写 4 ケースの外接矩形の SSIM の差は −0.005〜+0.004 で、時間は 2〜7 倍になった。

### Temporal Recovery: 借りた画素の明るさ合わせ（ADR 0012）

2026-09-27、同じ環境。手持ちの実写 A の 2500 秒に焼いた 1 ケース（logo・中央・不透明・crf 20、600 フレーム）を、
今回のマスク + harmonic で、明るさ合わせの有無だけを変えて復元。比べる相手は元の動画:

| 何を測ったか | 合わせない → 合わせる |
|---|---|
| 戻した画素（由来 `temporal_real`）の誤差の絶対値の平均（検出した ROI + 周り 4 px、50 フレームおきの 12 フレーム、1 フレームあたり 710 画素） | 3.15 → 2.31 |
| 同じ画素の誤差の符号付き平均 | +0.41 → +0.21 |
| SSIM（検出した ROI）/（ウォーターマークの外接矩形） | 0.9356 → 0.9370 / 0.9419 → 0.9421 |
| 合成 6 ケース（上の「ウォーターマークのマスク」の表） | SSIM の差 0.001 以内（合成の動画は明るさが変わらない） |

観測のきっかけ: 合わせないと、ROI の下端に沿った 3 行が別フレームから戻され、正解より +2.2 / +1.2 / +0.3 明るく、線に見えた
（入力はその行で正解との差 0.0）。

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
