---
name: define-requirements
description: GitHub Issue の要件（背景・なぜやるか・何をするか・スコープ・受け入れ条件・制約・未解決事項）を整理して Issue コメントに投稿し、課題管理ツールの Status を Defined に移す。要件定義＝何を/なぜ（どう実装するかは design-implementation）。人介在を最小化するため、既存実装・ルール・類似 Issue を先回りで調査し、未解決事項を可能な限り埋める。「要件定義」「要件を整理」「define-requirements」「要件まとめて」「要件作って」と言われた時に使用してください。
argument-hint: '[issue番号]'
allowed-tools: Bash(gh *), Bash(git *), Bash(grep:*), Bash(rg:*), Bash(jq *), Bash(bash *), Read, Glob, Grep, AskUserQuestion
---

# 要件定義

GitHub Issue を明確な要件（**何を / なぜ**。どう実装するかは `/design-implementation`）に落とし込み、Issue コメントとして残す。

**自律推論を優先する。** 既存実装・`.claude/rules/`・類似 Issue を先回りで調査し、答えが出る項目は確定済みとして提示する。真に人の判断が要る項目だけを確認に回す。

## 設定読み込み

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
```

Issue 番号は `$ARGUMENTS` から。省略時は対象を尋ねる。

## 手順

### 1. Issue 取得

```bash
gh issue view ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --json number,title,body,labels,comments
```

**本文だけでなくコメントも必ず読む。** 本文は起票時のスナップショットで、議論の結果が本文へ反映されないまま残ることがある。**本文とコメントで方針が食い違っていたら後発のコメントが正**。ただし方針転換を勝手に採用せず**ユーザーに確認する** — 受け入れ条件・スコープも転換後の方針に合わせて読み替えが要るため、確認せず進めると要件ごと逆向きに実装しうる。

既に `## Requirements` コメントがあれば、新規作成せずそれを refine する。

### 2. 自律推論フェーズ（聞く前に埋める）

#### 2.1 ルール照合

`CLAUDE.md` と `.claude/rules/` を読み、Issue に関連する制約・既存ポリシー・命名規則・典型パターンを抽出する。**どのファイルを読むかは `ls .claude/rules/` の実物から判断する**（固定の対応表を持たない）。

#### 2.2 既存実装スキャン

Issue 本文のキーワードで grep / glob し、類似機能・既存値・設定例を特定する。`devkit.json` の `siblingRepos` があれば、そちらも読み取り専用で参照する。

**調査は checkout 中のブランチでなく基底ブランチ（`$DEVKIT_BASE_BRANCH`）の実体で行う。** 親 checkout は別の作業ブランチに載っていることが常態で、そこで grep した数値は基底と乖離する。異なるなら `git worktree add <dir> "origin/${DEVKIT_BASE_BRANCH}"` した実体で計測する。

#### 2.3 類似 Issue / PR の参照

```bash
gh issue list --repo "$DEVKIT_REPO" --search "<keyword>" --state all --limit 10
gh pr list --repo "$DEVKIT_REPO" --search "<keyword>" --state all --limit 10
```

過去の同種 Issue の見積り・実装パターンを基準にする。

#### 2.4 ラベル対応スキルの確認

Issue のラベルに運用系スキル名があれば、対応する SKILL.md を読み、**そのスキルが要求する必須入力を要件として確定させる**。

### 3. 要件のドラフト

挙動と成果に焦点を当てる（ファイルやコードではない）:

- **背景 / なぜやるか (Why)** — Issue にしか残らない情報なので丁寧に
- **何をするか (What)** — 利用者目線で
- **スコープ** — in scope / out of scope
- **受け入れ条件** — 「完了」を判定できる条件を**計測可能な形**で（「画面 X で Y が表示される」「API Z が 200 を返す」「DB カラム W が値 V を持つ」）。「適切に」「正しく」は禁止
- **制約・前提**
- **自律判定項目** — 手順 2 で答えが出た項目を**根拠付き**で確定提示
- **未解決事項** — 真に人の判断が要るもの（価格・対象範囲・SLA 等のビジネス判断）だけを残す

#### 3.1 自律判定の根拠付与

```
- 項目: <例: 対象モデル ID>
- 値: <例: xxx>
- 根拠: <参照: .claude/rules/<file>.md / 既存 PR #XXX / <設定ファイル>>
```

**答えが出せる仕様項目は要件定義で確定させる。** ユーザーに聞けば決まる項目（バージョン・上限値・対象範囲・単価）を「未解決事項」に残したまま先へ進めない（設計フェーズへ先送りしない）。「未解決事項」は本当に判断保留が必要なものだけにする。

### 4. 見積り（tracker が対応している場合）

Size / 工数 / 分類を、類似 Issue（手順 2.3）を基準に推定し、**根拠を併記**する。

| Size | 工数目安 |
|---|---|
| XS | 〜0.5 人日 |
| S | 0.5〜1 人日 |
| M | 1〜3 人日 |
| L | 3〜7 人日 |
| XL | 7 人日超 |

`tracker.sizeFieldId` 等が未設定なら、この手順はスキップして要件本文に見積りを書くだけにする。

### 5. 確認・投稿

ドラフト・自律判定項目・見積りを提示する。

**確認の出し方**（上から評価し、最初に一致した分岐のみ実行）:

1. **未解決事項あり** → その項目のみ確認（往復最大 3 回）
2. **未解決事項 0 件** → 「自律判定を一括承認 / 個別修正」の 2 択

承認後、`## Requirements` ヘッダで投稿する:

```bash
gh issue comment ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --body-file <file>
```

投稿本文に「自律判定項目」セクションを必ず含め、根拠を残す（後から検証できるように）。

### 6. Status 遷移（`tracker.type = "github-project"` のみ）

`issues-only` / `none` ならこの手順はスキップし、その旨を報告に書く。

```bash
OWNER="${DEVKIT_REPO%/*}"; NAME="${DEVKIT_REPO#*/}"
ITEM_ID=$(gh api graphql -f query='
  query($o:String!,$n:String!,$num:Int!){ repository(owner:$o,name:$n){
    issue(number:$num){ projectItems(first:10){ nodes{ id project{ number } } } } } }' \
  -F o="$OWNER" -F n="$NAME" -F num="${ISSUE_NUMBER}" \
  --jq ".data.repository.issue.projectItems.nodes[] | select(.project.number==${DEVKIT_PROJECT_NUMBER}) | .id")

[ -n "$ITEM_ID" ] || { echo "ERROR: Project 未追加。gh project item-add ${DEVKIT_PROJECT_NUMBER} --owner ${DEVKIT_PROJECT_OWNER} --url <issue URL> を先に実行" >&2; exit 1; }

gh project item-edit --project-id "$DEVKIT_PROJECT_ID" --id "$ITEM_ID" \
  --field-id "$DEVKIT_STATUS_FIELD_ID" --single-select-option-id "$DEVKIT_STATUS_DEFINED"
```

**Issue 起点の targeted query を使う。** Project の全件スキャン（`gh project item-list`）は item 数に比例したコスト（1 pt/item）がかかり、数百 item の Project では 1 回で GraphQL 枠の 2 割近くを消費して 5〜6 回で枯渇する。上のクエリは 1 pt で済み、`repository(owner,name)` 起点なので**別リポの同番号 Issue に誤マッチしない**。

**`--limit` を上げて全件スキャンで凌ぐのは誤った対処。** 空が返ったときに「未追加」と「limit 不足」を区別できない無言の 0 件になる。

**Project への書き込みには `project` scope が要る**（`read:project` は読み取り専用）。無いと `gh project item-edit` が無音で失敗するので、`2>&1` を付けて exit code を見る。

## 合格基準

- 受け入れ条件が計測可能（曖昧表現なし）
- 未解決事項 = 0 件（またはビジネス判断が必須の項目のみ）
- 自律判定項目に**全て根拠**が付与されている
- 見積りが確定している（tracker 対応時）

## 進捗ログ

- 起動時: `▶ /define-requirements #${ISSUE_NUMBER} を起動`
- 自律推論完了: `自律判定 N/M 件確定（未解決 X 件: <項目>）`
- 投稿: `📝 Requirements 投稿: #${ISSUE_NUMBER}`
- Status 遷移: `Status: → Defined` / `Status 遷移: skip（tracker=issues-only）`

## Notes

- 要件のみ。実装設計・コード変更はしない
- 真にビジネス判断な項目だけをユーザー確認に回す
- 投稿・Status 更新の前に必ずユーザー確認する
