# 0004 — GUI は SDL2 の別の実行ファイルにし、検出は既存の入口を呼ぶだけにする

## 決定

- 確認用の UI は `vrestore-gui` として、CLI の `vrestore` とは別の実行ファイルにする。`zig build gui` で作り、
  既定の `zig build`（install）には入れない
- 描画とイベントは SDL2（システムのライブラリを pkg-config で見つける。FFmpeg と同じ扱い）
- UI の層は薄く保つ:
  - 座標変換・ドラッグ選択・タイムラインは `src/gui_state.zig`（SDL に依存しない。ユニットテストする）
  - 検出は `detect_roi.detectInVideo` を呼ぶだけ。CLI の `detect-roi` と同じ関数で、閾値も同じ
    （`detect_roi.default_thresholds`）
  - `src/gui.zig` はイベントを読んで描くだけ
- 数値（得票率・margin・reliable・理由）は窓のタイトルに出し、画面には色（reliable なら赤、そうでなければ黄）と
  得票率の棒（閾値の位置に目盛り）で出す

## 理由

- 本体の CLI と CI の大半は、画面の無い環境で動く。GUI のライブラリを本体にリンクすると、使わない環境にも
  SDL2 が要るようになる
- SDL2 は手元（macOS、Homebrew の 2.32）にも CI（Ubuntu 24.04 の apt `libsdl2-dev`）にもある。
  FFmpeg と同じく pkg-config でリンクでき、2 つ目のビルドの仕組みを持ち込まずに済む
- SDL にはダミーの描画ドライバがあるので、CI で窓を開かずに GUI の経路（フレームの表示 → 選択 → 検出）を回せる
  （`vrestore-gui --detect-and-exit`、`zig build gui` の `roi check gui`）

## 採らなかったもの

- **raylib**: 文字を描けるので表示は楽。ただし手元の Homebrew（6.0）と Ubuntu 24.04 の apt で版がずれうる。
  ソースからビルドするなら Zig 0.16 で依存のビルドが通るかを別に確かめる必要がある
- **SDL3**: 文字を描く機能（デバッグ用のフォント）がある。Ubuntu 24.04 の apt に無い
- **SDL2 + SDL_ttf**: 文字は描けるが依存とフォントファイルが増える。いまの表示はタイトルで足りる
- **GUI のサブコマンドを `vrestore` に入れる**: 上の「本体に SDL2 が要るようになる」ので採らない

## 帰結

- 画面の中に文字は出ない。数値は窓のタイトル（と `--detect-and-exit` の JSON）で見る。
  文字が要るようになったら、SDL3 か SDL_ttf をここで見直す
- マウス操作そのもの（ドラッグの取り回し）は CI では回らない。CI が見るのは、選択が決まった後の経路と
  座標計算（`gui_state.zig`）まで
