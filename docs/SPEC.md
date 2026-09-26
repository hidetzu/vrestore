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
| 動画 | 動画を開き、幅・高さ・尺・コーデック名を返す。尺が取れない入力では尺を返さない | `src/video.zig` の test `"video: open reports size, duration and codec"` |
| 動画 | 先頭から全フレームを順に RGB24 でデコードし、終端を報告する | test `"video: next decodes every frame in order, then reports the end"` |
| 動画 | 指定時刻以降の最初のフレームへ seek する（キーフレームでない位置、後ろから前への seek を含む） | test `"video: seek lands on the exact frame, including non-keyframes"` |
| 動画 | 尺全体から等間隔に N 枚取り出す | test `"video: sampleFrames spreads over the whole duration"` |
| 動画 | 動画でないファイルは開けないと報告する | test `"video: a file that is not a video fails to open"`、`build.zig` の `cli_probe_bad` |
| CLI | `vrestore probe <video>` が 1 フレーム目までデコードしてから、幅・高さ・尺・コーデックを JSON 1 行で出す | `build.zig` の `cli_probe`（stdout 全体を照合） |
| CLI | stdout が他の出力と共有された通常ファイルでも、前の出力を上書きしない | `build.zig` の `cli_stdout_file` |
| リポジトリ衛生 | 動画・巨大ファイルが git の管理下に無い | `scripts/check-no-media.sh` |

## 2. 次に実装すること（契約）

### 2-1. ROI 検出

**入力:** 動画 1 本 + ウォーターマーク参照画像 1 枚（ユーザーが「これを消したい」と切り出した領域）。

解く問題は「どれがウォーターマークか」ではなく「**指定されたウォーターマークが、動画内のどこに
固定されているか**」。

**出力（JSON）:**

```json
{
  "x": 493,
  "y": 5,
  "width": 142,
  "height": 77,
  "confidence": 1.0,
  "psr": 19.5,
  "frames_voted": 15,
  "reliable": true
}
```

- `confidence` は複数フレームの投票での最頻位置の得票率
- `reliable` は得票率と PSR を併せて決める。⚠ **PSR 単独で決めない**
  （繰り返しパターンで「PSR は高いが位置が違う」例が PoC で出ている）

**デバッグ出力（正式機能の完成条件）:**

```
debug/
  detection.json
  frame-overlay.png   # 元フレームに検出矩形を描いたもの
  roi-crop.png        # 検出した ROI だけを切り出したもの
```

**参照画像の切り方（利用者向け）:** 小さく切らない。ウォーターマーク全体の特徴が入るよう、
余白を含めて大きめに選ぶ。小さい参照ほど似た文字列・同じウォーターマーク内の別位置に誤マッチした（PoC）。

**完成の判定:** CI 内で合成した動画（既知の位置に既知のウォーターマークを焼き付け、yuv420p で
エンコード）で、`dx` / `dy` / `IoU` / `reliable` を機械判定する。

## 3. 意図して実装しないこと（現段階）

| 実装しない | 理由 |
|---|---|
| 背景復元（Temporal / Alpha / Spatial / 生成） | ROI 検出を独立した安定モジュールにしてから（[ADR 0002](adr/0002-roi-detection-is-separate-from-background-recovery.md)） |
| ウォーターマークの自動発見 | 解く問題を「指定されたものの位置」に絞る |
| MP4 の書き出し | 復元が無い段階で出すものが無い |
| 動画プレイヤー UI | CLI / テストで境界を作るのが先。導入時に ADR を書く |
| GPU / SIMD 最適化 | 測って遅いと分かってから |

## 4. 測定値

⚠ 分母・日付・条件の無い数値は、直すのではなく消す。

| 何を測ったか | 値 | いつ | 条件 |
|---|---|---|---|
| yuv420p を経由した灰色の往復誤差（RGB24 で見た値 − 合成時の値） | 最大 1（全 10 フレーム、全画素） | 2026-09-26 | 64x48 / 10 fps / libx264 `-qp 0` / 灰色 16+20k（k=0..9）。ffmpeg 8.1.1 コマンドの rawvideo rgb24 出力で観測。テストの許容差 2 はこれに基づく |

ROI 検出が入ったら、合成素材での結果をここに置く。
