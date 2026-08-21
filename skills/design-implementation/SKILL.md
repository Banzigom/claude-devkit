---
name: design-implementation
description: 確定要件から実装設計（影響ファイル・スキーマ/API 変更・実装方針・リスク・複雑度・テスト計画）を作り、Issue コメント（## Implementation Design）として投稿し、Status を Ready に移す。複数方針が考えうる場合は pros/cons を比較し、根拠と共に推奨を提示。明確な勝者があれば自動採用。「実装設計」「設計」「design-implementation」「設計作って」「実装方針」と言われた時に使用してください。
argument-hint: '[issue番号]'
allowed-tools: Bash(gh *), Bash(git *), Bash(grep:*), Bash(rg:*), Bash(jq *), Bash(bash *), Read, Glob, Grep, AskUserQuestion
---

# 実装設計

確定要件を実装設計（**どう実装するか**）に落とす。要件が先（`/define-requirements`）。

**自律判定を優先する。** 複数方針が考えうる項目は pros/cons + 既存ルール照合 + 類似実装比較で評価し、明確な勝者があれば自動採用する。引き分けやビジネス上のトレードオフだけをユーザー確認に回す。

## 設定読み込み

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
```

## 手順

### 1. 要件の読み込み

```bash
gh issue view ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --json number,title,body,comments
```

最新の `## Requirements` コメント（人手編集があればそれ）を SoT とする。無ければ `/define-requirements` を先に促す。

### 2. 実装の調査

関連する `.claude/rules/` と、影響を受けるコードを読む。`devkit.json` の `siblingRepos` があれば読み取り専用で参照する。

**着手前に、同じ問題への暫定対応が基底ブランチへ先行マージされていないか確認する。** 他人の先行修正は `git diff` にも grep にも出ず、両方残すと二重駆動になる:

```bash
git log "origin/${DEVKIT_BASE_BRANCH}" --oneline -15 -- <対象ファイル>
gh pr list --repo "$DEVKIT_REPO" --state merged --search "<症状のキーワード>" --limit 10
```

見つかったら**設計に「暫定対応の撤去」を明示的なタスクとして含める**（付随する暫定対応向けテストの反転も同時に）。

**外部システム・フレームワークの挙動は、名前や慣習から推測せず実物で確認する。** 推測はそのままモックに固定され、単体テストは緑のまま通り、実機で初めて壊れる。相手側の実装を読むか、実際に叩くか、ライブラリのソースを読む。

### 3. 方針候補の洗い出しと自動評価

設計に複数の選択肢がある項目（配置場所・データ構造・段階リリース戦略・マイグレーション方式）を全て列挙し、各候補に付与する:

- **pros** / **cons**
- **既存ルール照合** — 該当する `.claude/rules/` の記述と整合するか
- **類似実装** — 既存コードでの先例（PR # / ファイル）
- **判定** — ✅ 推奨 / ⚠️ 条件付き / ❌ 非推奨

**自動採用条件**: pros が cons を大きく上回り既存規約と整合するなら自動採用。判定結果は設計コメントに残す。引き分け・ビジネス上のトレードオフはユーザー確認に回す。

### 4. 設計の作成

- **影響範囲**（影響度 高/中/低）と**変更するファイル / モジュール**（具体パス）
- **スキーマ / API 変更**とその影響
- **同期必須ポイント** — 1 箇所直したら必ず一緒に直す箇所（`.claude/rules/` の同期表を機械的に照合する）
- **方針評価** — 手順 3 の候補と判定結果
- **実装方針** — 順序立てた手順
- **リスク**と対策
- **複雑度**: X/10
- **テスト計画** — 単体 / 結合 / E2E / 手動確認
- **合格基準** — 実装完了を判定する条件（lint pass / test pass / 受け入れ条件を全て満たす）。UI 変更を含むなら実機検証の PASS も加える

**「入口が複数ある機能」では、症状の再現条件とこれから触る経路が一致しているかを実装前に突き合わせる。** 経路が 2 つあるのに片方だけ直すと、テストは緑でデプロイしても症状が消えない。

### 5. 確認・投稿

- 自動採用のみ → 「設計を一括承認 / 個別レビュー」の 2 択
- 要確認項目あり → その項目のみ確認（往復最大 3 回）

承認後、`## Implementation Design` ヘッダで投稿する:

```bash
gh issue comment ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --body-file <file>
```

投稿本文に「方針評価」セクションを必ず含め、自動採用の根拠を残す。

### 6. Status 遷移（`tracker.type = "github-project"` のみ）

```bash
OWNER="${DEVKIT_REPO%/*}"; NAME="${DEVKIT_REPO#*/}"
ITEM_ID=$(gh api graphql -f query='
  query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){
    issue(number:$num){ projectItems(first:10){ nodes{ id project{ number } } } } } }' \
  -F o="$OWNER" -F n="$NAME" -F num="${ISSUE_NUMBER}" \
  --jq ".data.repository.issue.projectItems.nodes[] | select(.project.number==${DEVKIT_PROJECT_NUMBER}) | .id")

gh project item-edit --project-id "$DEVKIT_PROJECT_ID" --id "$ITEM_ID" \
  --field-id "$DEVKIT_STATUS_FIELD_ID" --single-select-option-id "$DEVKIT_STATUS_READY"
```

全件スキャンを使わない理由・scope の注意は `/define-requirements` 手順 6 と同じ。

## 合格基準

- 影響範囲（ファイル・スキーマ）が具体的に列挙されている
- 方針評価で**採用根拠**が全項目に付与されている
- リスクと対策が列挙されている
- テスト計画がリスクの高さに見合っている
- 合格基準（実装完了判定）が明示されている

## 進捗ログ

- 起動時: `▶ /design-implementation #${ISSUE_NUMBER} を起動`
- 方針評価: `方針候補 N 件評価 → 自動採用 X / 要確認 Y`
- 投稿: `📝 Implementation Design 投稿: #${ISSUE_NUMBER}`
- Status 遷移: `Status: Defined → Ready` / `skip（tracker=issues-only）`

## Notes

- 設計のみ。コード変更はしない
- 要件が SoT。曖昧なら確認する
- 自動採用は根拠付きで設計コメントに残す（後から検証できるように）
- **設計で列挙したリスク対策は、実装完了時に 1 行ずつ「実装済みか」を機械的に照合する。** 対策は実装の勢いで後回しになりやすく、抜けても lint / 型チェック / テストは通る（対策が存在しないだけなので）
