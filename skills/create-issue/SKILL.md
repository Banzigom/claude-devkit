---
name: create-issue
description: 指示内容をリポジトリの Issue テンプレート（.github/ISSUE_TEMPLATE/）に沿って整形し、GitHub Issue を作成して課題管理ボードへ紐付ける。「issue 作って」「issue 化して」「create-issue」と言われた時に使用してください。
argument-hint: <指示内容>
allowed-tools: Bash(bash *), Bash(gh *), Bash(git *), Bash(ls *), Bash(jq *), Read, Glob, Grep, AskUserQuestion
---

# create-issue — テンプレートに沿った Issue 作成

ユーザー指示: `$ARGUMENTS`

**`.github/ISSUE_TEMPLATE/` の yml が source of truth。** Issue 本文はテンプレのセクション見出しと一字一句揃える（Issue Forms 経由で作られた既存 Issue と検索性・パース互換性を保つため）。

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
ls .github/ISSUE_TEMPLATE/ 2>/dev/null
```

テンプレートが 1 つも無ければ、その旨を伝えて**自由形式の Issue 本文をユーザーと合意してから**作成する（勝手にフォーマットを発明しない）。

## 手順

### 1. 最初に Issue 種別を聞く（必ず最初に）

🔴 **何より先に `AskUserQuestion` で種別を選んでもらう。** 指示内容から推測できそうでも必ず明示確認する — **テンプレ選択を間違えると後工程の自動化（ラベル起点のスキル選択・見積り対象の抽出）が動かない**。

`.github/ISSUE_TEMPLATE/*.yml` の `name` / `description` を読んで選択肢を作る。`AskUserQuestion` は 4 択までなので、テンプレが多ければ**大分類 → 具体テンプレ**の 2 段に分ける。

**選択肢のラベルにファイル名を出さない**（ユーザーが見るのは種別であって yml のファイル名ではない）。

種別が確定したら、対応する yml を Read して **項目（`label` / `id` / `type` / `validations.required` / `options`）と `labels:` を取得**する。

### 2. 既存実装の調査はしない

このスキルの目的は**起票**。実装の整合性確認は `/define-requirements` 以降のフェーズで行う。

### 3. テンプレ項目を順次ヒアリング

**yml の `body` 順に 1 項目ずつ聞く。** `$ARGUMENTS` に既に値が含まれている項目は埋めて飛ばし、不足だけ尋ねる。

質問の出し方は `type` に合わせる:

- `input` / `textarea`（自由記述）→ **プレーンテキストで質問して待つ。** `AskUserQuestion` で「これから伝える / 中止」のような Yes/No ラップをしない
- `dropdown` / `checkboxes`（選択肢が yml にある）→ **`AskUserQuestion` で yml の `options` をそのまま出す。** `checkboxes` は `multiSelect: true`

**任意 / 必須を問わず、yml にある項目は全て一度は聞く。** 違いはスキップ可否だけ:

- **必須**（`validations.required: true`）— スキップ不可。空回答なら理由を添えて再度聞く
- **任意** — 「スキップ可」と明示する。「なし」等ならそのセクションごと省略する

出力形式:

- `checkboxes` → 該当を `- [x]`、未該当を `- [ ]`
- `dropdown` → 選択値をカンマ区切りで 1 行
- **具体的な値が指示にあればそのまま使う。推測で埋めない**

### 3.5 精査して補足質問

一通り埋めたら回答を見返し、**調査・再現に役立つ項目**を追加で聞く:

- 不具合報告 → ブラウザ / OS、影響範囲（全ユーザー or 特定条件）、エラーメッセージ、発生開始時期、認証方式
- 機能追加 → 対象画面・対象ロール
- 運用系 → 対象環境・対象の識別子

聞いた内容は本文の **`### 補足` セクション**にまとめる（テンプレ項目に該当しない情報の置き場）。無ければセクションごと省略。

### 3.6 機能追加なら規模感を提示

**機能追加・拡張の場合のみ**、補足ヒアリング後に**ざっくりした規模感**を提示する。目的は、Issue 化の前に「思ったより重い」「分割した方がよい」という方針判断の機会をユーザーに渡すこと。

- 粒度は **T シャツサイズ（XS / S / M / L / XL）+ 期間の目安**で十分。`/define-requirements` の精緻な見積りとは**別物**（仮見積り）
- **根拠を 1〜2 行添える**（対象範囲の広さ / 依存リポ数 / デザイン作成の有無 / 移行リスク）
- 「分割したい」「縮小したい」と返ったら、テンプレ再ヒアリングか別 Issue への分割の判断を仰ぐ
- 提示した内容は本文の **`### 仮見積り` セクション**にそのまま残す（口頭の認識合わせを記録に残す目的）

不具合報告・運用系では行わない（規模感は要件定義 / 専用スキルの責務）。

### 4. 本文の組み立て

Issue Forms が投稿する形式に合わせ、各項目を `### {label}` + 空行 + 値 で並べる。

タイトルは簡潔に（70 文字以内）。**ラベルは別途付与するので title に `[bug]` 等の prefix を付けない。**

### 5. Issue 作成

```bash
ISSUE_URL=$(gh issue create --repo "$DEVKIT_REPO" \
  --title "<タイトル>" \
  --label "<yml の labels をすべて>" \
  --body-file <(cat <<'BODY'
### <項目1のlabel>

<値>
BODY
))
ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
echo "$ISSUE_URL"
```

**`--assignee @me` は付けない**（起票者と担当が一致するとは限らない）。指示に assignee / milestone の指定があればそのときだけ付ける。

### 6. 課題管理ボードへの紐付け（`tracker.type = "github-project"` のみ）

```bash
gh project item-add "$DEVKIT_PROJECT_NUMBER" --owner "$DEVKIT_PROJECT_OWNER" --url "$ISSUE_URL"
```

🔴 **直後に実在確認する。** `item-add` は**レスポンス無音で失敗しうる**:

```bash
OWNER="${DEVKIT_REPO%%/*}"; NAME="${DEVKIT_REPO##*/}"
ITEM_ID=$(gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){ repository(owner:$o, name:$r){
    issue(number:$n){ projectItems(first:10){ nodes{ id project{ number } } } } } }' \
  -f o="$OWNER" -f r="$NAME" -F n="$ISSUE_NUMBER" \
  --jq ".data.repository.issue.projectItems.nodes[] | select(.project.number==$DEVKIT_PROJECT_NUMBER) | .id")
[ -n "$ITEM_ID" ] || { echo "ERROR: Project 未追加" >&2; exit 1; }
```

**`repository(owner:, name:)` 起点なので別リポの同番号 Issue に誤マッチしない。** 全件スキャン（`gh project item-list`）は使わない（item 数に比例してコストがかかる）。

Status / Size / 見積りフィールドの更新は**このスキルでは行わない**（`/define-requirements` の責務）。ボードに乗せて既定 Status までで良い。

`tracker.type` が `issues-only` ならこの手順ごとスキップし、その旨を報告する。

### 7. 画像の添付（ユーザーが画像を提供した場合のみ）

提供が無ければスキップ。**勝手に生成・取得しない。**

リポジトリ内の画像置き場（例 `images/issues/issue-<N>/`）へ格納し、`gh issue edit` で本文の参考情報セクションへ raw URL を追記する。ファイル名は英小文字ケバブケース。

### 8. 結果報告

作成した Issue URL と、ボードへの追加状況を 1〜2 行で報告する。

## 注意事項

- 🔴 **手順 1 を飛ばさない。** 種別が自明に見えても必ず確認する
- 🔴 **必須項目を埋めずに作らない。** 満たされない Issue は後続フェーズの対象から漏れて放置される
- 🔴 **見出しはテンプレの `label` と一字一句揃える。** 勝手に短縮しない
- **指示にない技術詳細を勝手に足さない。** テンプレの技術要件セクションは、指示に明示があるときだけ書く
- 🔴 **ボードへの紐付けを忘れない。** 乗っていない Issue は後続スキルの対象にならず放置されやすい。**追加 + 実在確認までがワンセット**
