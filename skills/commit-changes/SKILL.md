---
name: commit-changes
description: Conventional Commit 形式のコミットメッセージ候補を生成して即コミットする。独立した複数の論理変更が混在していれば分割を提案する。「コミット」「commit-changes」「サクッとコミット」と言われた時に使用してください。push はしない。
argument-hint: '[--no-verify]'
allowed-tools: Bash(git *), Bash(make *), Bash(npm *), Bash(yarn *), Bash(pnpm *), Bash(npx *), Bash(python *), Bash(bash *), Read, Grep
---

# コミット

Conventional Commit メッセージを組み立て、先頭候補を採用してコミットする。**push はしない。**

`$ARGUMENTS`:

- `--no-verify`: コミット前チェック（lint）をスキップ

## 設定の読み込み

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
```

`eval "$(bash ...)"` と 1 行で書かないこと（コマンド置換の exit code は eval に伝わらず、設定不備が無音で通る）。

## 手順

### 1. ブランチ確認（ベースブランチ保護）

```bash
cd "$DEVKIT_ROOT" && git branch --show-current
```

**必ず `cd` を伴わせる。** シェルの作業ディレクトリは呼び出しを跨いで持続するため、直前に別リポを見ていると `git branch --show-current` が別リポの結果を返し、確認そのものが無意味になる。

`$DEVKIT_BASE_BRANCH` や `main` / `master` / `release` / `deploy/*` 等のベースブランチ上なら**コミットせず停止**し、先に作業ブランチ（`${DEVKIT_BRANCH_PREFIX}<name>`）を切るよう伝える。

さらに、そのブランチが基底より遅れていないかを見る:

```bash
git rev-list --left-right --count "origin/${DEVKIT_BASE_BRANCH}...HEAD"
```

左が大きく右が `0`（例 `10  0`）なら**マージ済みで放置された古いブランチ**のサイン。そこでコミットすると基底の更新を巻き戻す差分を作りうるので停止して報告する。

### 2. コミット前チェック（`--no-verify` 以外）

`$DEVKIT_CMD_LINT` が設定されていれば実行する。失敗したら `$DEVKIT_CMD_FORMAT` で自動整形してから再 lint。それでも通らなければ出力を報告して直してから続行。

**フォーマッタは変更ファイルだけに絞って掛ける。** リポ全体に掛けると、差分と無関係な既存の未整形箇所まで書き換わり、レビューできない巨大 diff になる:

```bash
git diff --name-only HEAD | grep -E '\.(ts|tsx|js|jsx|py|go|rb)$' | xargs -r <formatter>
```

絞って掛けた場合でも、**そのファイル内の「差分と無関係な既存行」は整形される**。実行後に `git diff -U0` を目視し、意図と無関係な整形行は元に戻す。

加えて、ステージ済み変更が**プロダクションコードを含む**なら、`.claude/rules/` のテスト方針と突き合わせて **テストの要否を明示判断**する。「必須 / 除外のどちらに当たるか・なぜか」を一言残す。「軽微な UI 修正だから」で要否判断自体をスキップしない。判定が grey zone（見た目のコンポーネントだが件数しきい値・開閉等の*振る舞い*を持つ）なら、除外の「見た目」は styling/visual を指すと解釈し、振る舞いはテスト対象として扱う。

### 3. ステージ状態の確認

```bash
git status --short
git diff --staged
```

ステージ 0 件なら `git add -A`。既にステージ済みならそれだけをコミット。

### 4. 変更の分析と分割判断

ステージ済み diff を分析する。独立した複数の論理変更（異なる関心事 / 異なる変更種別 / source vs docs / レビューしやすさ）が混在していれば分割を提案。

### 5. メッセージ生成と採用

各コミットに Conventional Commit 候補を 3 つ生成し、**先頭を採用**（確認プロンプトなし）。

- 形式: `<type>: <説明>`（type: feat / fix / docs / style / refactor / perf / test / chore）
- 1 行目は 72 文字以内
- 言語は `$DEVKIT_COMMIT_LANG`。既存コミット履歴（`git log --oneline -20`）の言語に合わせるのが優先

### 6. コミット

```bash
git commit -m "<採用メッセージ>"
```

分割する場合はファイルを個別に `git add` して繰り返す。

### 7. 混入チェック

コミット後、**diff がメッセージと一致するか**を確認する。特に:

```bash
git show --stat HEAD
```

テキストファイルなのに `Bin 0 -> N bytes` と表示されたら**制御文字が混入している**（エディタ経由の書き込みで起きうる）。lint も型チェックも素通りするので、この表示が唯一の検知経路になる。

## 進捗ログ

- 起動時: `▶ /commit-changes を起動（branch: <name>）`
- 分割判断: `分割: N コミットに分ける` or `単一コミット`
- 各コミット: `📝 コミット作成: <SHA短縮> <subject>`

## Notes

- **push しない**（必要ならユーザーに確認）
- `--no-verify` 指定時のみチェックをスキップ
- ベースブランチ上でのコミットは常に停止する。例外を作らない
