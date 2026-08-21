---
name: fix-pr-review
description: PR のレビューコメントを取得し、既解決/自分/bot のコメントを除外して 1 件ずつ対応（修正/skip/inspect）する。修正したインラインコメントは reply ＋ resolve する。「レビュー対応」「レビューコメント対応」「fix-pr-review」「PR の指摘対応」「指摘直して」「コメント対応」と言われた時に使用してください。
argument-hint: '[PR number] [--auto] [--no-test-coverage]'
allowed-tools: Skill, Agent, Bash(gh *), Bash(git *), Bash(bash *), Read, Edit, Write, Glob, Grep, AskUserQuestion
---

# fix-pr-review — PR レビュー対応

PR のレビューコメントを取得し、各コメントの対応を決め、修正 → reply → resolve まで通す。

`$ARGUMENTS`（順不同）:

- PR 番号: `123` / `#123`。省略時は現在のブランチから自動検出
- `--auto`: 確認を省略し「fix」を既定にする（設計変更要求・質問のみは skip してフラグを立てる）
- `--no-test-coverage`: テスト網羅レビューの自動取込をスキップ（既定は実行）

**指摘を鵜呑みにしない。** 各指摘を (1) 具体的な欠陥経路が実在するか、(2) 既存コードやランタイムで既に防がれていないか、(3) 修正が開発フローを壊さないか で判断する。対応しない指摘には**理由を添えて返信する**（黙って無視しない）。

## 手順

### 1. 設定・PR 番号・モードの確定

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"

PR_NUMBER="<引数の数値>"
[ -z "$PR_NUMBER" ] && PR_NUMBER=$(gh pr list --repo "$DEVKIT_REPO" --head "$(git branch --show-current)" --json number -q '.[0].number')
```

PR が見つからなければ報告して停止する。

### 2. 自分のユーザー名を取得

```bash
GH_USER=$(gh api user -q '.login')
```

### 3. コメントを取得

```bash
gh api "repos/$DEVKIT_REPO/issues/$PR_NUMBER/comments"   # PR レベルコメント
gh api "repos/$DEVKIT_REPO/pulls/$PR_NUMBER/comments"    # インラインレビューコメント
gh api "repos/$DEVKIT_REPO/pulls/$PR_NUMBER/reviews"     # レビュー本文
```

### 4. フィルタ

除外する: resolved スレッドのコメント / 自分のコメント（`user.login == GH_USER`）/ bot のコメント（`user.login` に `[bot]` を含む）。

### 4.5 テスト網羅レビューの取込（既定 ON）

`--no-test-coverage` 以外は `review-test-coverage` を実行し、返却された findings を**仮想コメント**としてリスト末尾に追加する。

```
author: review-test-coverage (virtual)
file: <finding.file>:<finding.line>  または (no file)
body: [<severity>] <finding.body>（根拠: <rule> <section>）
thread_id: null   ← GitHub の thread が無いので reply / resolve はしない
```

severity → 既定アクション: Critical / Important = fix、Suggestion = skip。

### 5. コメントごとに判断

**interactive（既定）**: 1 件ずつ提示して `fix / skip / inspect` を尋ねる。

```
Comment [N/total]
author: {user.login}
file: {path}:{line}   ← インラインのみ
body: {body}
code: {diff_hunk}
```

`fix` ならファイルを Read してから変更を適用。`inspect` なら周辺コードを Read して再提示。

**auto**: 自動判断する。

| コメント種別 | アクション |
|---|---|
| 具体的な修正提案 / 文言 / 軽微な改善 | 修正を適用 |
| 設計変更・仕様議論を求めるもの | skip + `design_change_requested` |
| 質問のみ | skip + `answer_required` |
| 判断不能 | skip + `ambiguous` |

### 6. 修正を適用

修正前に必ず対象ファイルを Read し、関連する `.claude/rules/` に従う。

### 7. reply と resolve

**修正・skip いずれも、対象コメントに必ず返信する**（黙ってマージへ進まない）。

thread ID と comment の databaseId のマップを取る（>100 は `pageInfo.endCursor` でページング）:

```bash
OWNER="${DEVKIT_REPO%/*}"; REPO="${DEVKIT_REPO#*/}"
gh api graphql -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" -f query='
  query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{ id isResolved comments(first:100){ nodes{ databaseId } } }
          pageInfo{ hasNextPage endCursor }
        }}}}'
```

返信:

```bash
# インラインレビューコメント（path あり）
gh api --method POST "/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
  --field body="対応しました。${FIX_SUMMARY} (commit: ${COMMIT_SHA})"

# PR レベルコメント / レビュー本文（path なし）
gh pr comment "$PR_NUMBER" --repo "$DEVKIT_REPO" --body "@$REVIEWER_LOGIN ${REPLY_BODY}"
```

resolve（**修正済みのインラインコメントのみ**）:

```bash
gh api graphql -F threadId="$THREAD_ID" -f query='
  mutation($threadId:ID!){ resolveReviewThread(input:{threadId:$threadId}){ thread{ id isResolved } } }'
```

**resolve しないもの**: 設計変更・質問のみ・判断保留で skip したもの（レビュアー待ち）/ PR レベルコメント（スレッド構造がない）/ 逆引きに失敗したもの / 仮想コメント。仮想コメントは `gh pr comment` で「テスト網羅レビューによる修正サマリ」として 1 件にまとめて投稿する。

### 8. 完了サマリー

```
fix-pr-review 完了
- 総コメント数: N（実コメント X + テスト網羅 finding Y）/ 除外: Z
- 修正: N / skip: N
- 返信: N / resolve: N / 返信失敗: [...]
- テスト網羅: Critical=X / Important=Y / Suggestion=Z
```

## 進捗ログ

- 起動時: `▶ /fix-pr-review #${PR_NUMBER}（mode=auto/interactive）を起動`
- 取得: `📥 コメント取得: 全 N 件（除外 X / 対応 Y）`
- 各コメント: `[N/total] {author} {file:line}: <fix/skip/inspect>`
- 返信: `↩️ reply + resolve: thread X`
- 完了: `✅ 修正 N / skip M / reply 失敗 K`

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| `review-test-coverage` 失敗 | finding 0 件として継続（フェイルオープン）。サマリに `test-coverage: skipped` を記録 |
| コメント取得失敗（レート制限 / 認証） | **停止して報告**。空リストで進めない（「指摘 0 件」と誤認するため） |
| reply 失敗（404 / 403 / 逆引き失敗） | `reply_failed` に積んで継続（修正自体は適用済み）。サマリで列挙 |
| `resolveReviewThread` 失敗 | 同上 |

## Notes

- 修正前に必ず対象ファイルを Read する
- コミット / push はしない（別途ユーザー確認）
- **GraphQL が枯渇したら REST へ切り替える**（コメント投稿・PR 操作は REST でも可能。`.claude/rules/general.md` 参照）
