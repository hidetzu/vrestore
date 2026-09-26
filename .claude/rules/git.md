# Git

## コミット

- MUST: Conventional Commits（`<type>(<scope>): <subject>`）。
- MUST: ⚠ `git add -A` で無関係なものを巻き込まない。1 つの理由に 1 コミット。
- MUST NOT: ⚠ 既定ブランチへ直接コミットしない。`<type>/<short-name>` のブランチを切る。
- SHOULD: 本文に**なぜ**と**測った数値**を書く。

## 許可

- MUST: ⚠ `git push` は毎回許可を取る。前の許可は持ち越さない。
- MUST: ⚠ マージも毎回許可を取る。auto-merge・`--admin` は使わない。CI が赤・実行中ならマージしない。

## ⚠ 言われない限りやらない

```text
git push --force
git reset --hard
git clean -fd
git checkout -- .
git restore .
```

⚠ `git clean -fdx` は `tmp/media/`（実素材へのリンク）ごと消す。

## ⚠ 公開物に書かないもの

⚠ **根拠: Public リポジトリ。** コミット本文・PR・issue・コメントは誰でも読める。履歴は取り消せない。

- MUST NOT: ⚠ 動画・フレーム画像・ウォーターマーク画像のうち、権利物・private なもの・他者のもの。
  合成素材だけ（CLAUDE.md §4）。
- MUST NOT: ⚠ ローカルの絶対パス（`/Users/<name>/…`）、ホスト名、実素材のファイル名。
- MUST NOT: ⚠ AI 作業セッションの URL、トークン、API キー。
- MUST: issue はリポジトリ名付きで書く（`hidetzu/vrestore#N`）。
