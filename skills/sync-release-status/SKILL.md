---
name: sync-release-status
description: リリース PR に束ねられた feature PR から親 Issue を特定し、GitHub Project の Status を一括遷移する。順方向（PR 本文の参照キーワード）と逆方向（Issue タイムライン照合）の両方向マッチングで抽出漏れを防ぎ、後退・フロースキップはガードして dry-run 承認後に適用する。「ステータス一括更新」「リリース反映のステータス更新」「sync-release-status」「Issue のステータスをまとめて変更」と言われた時に使用してください。
argument-hint: '[リリース PR の URL...] [--to <遷移先 Status>]'
allowed-tools: Bash(bash *), Bash(gh *), Bash(jq *), Bash(awk *), Read, Write, AskUserQuestion
---

# sync-release-status — リリース反映に伴う Status 一括遷移

リリース PR（複数の feature PR を束ねる PR）がマージされた後、束ねられた PR 群から親 Issue を特定し、Project の Status を一括で次段階へ進める。

`tracker.type` が `github-project` でなければ使えない。

## 前提

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
[ "$DEVKIT_TRACKER" = "github-project" ] || { echo "tracker.type が github-project でないため利用不可"; exit 0; }

ORDER=$(jq -c '.tracker.releaseStatusOrder // []' "$DEVKIT_CONFIG")
IDS=$(jq -c '.tracker.statusOptionIds // {}' "$DEVKIT_CONFIG")
```

**遷移は `tracker.releaseStatusOrder` の順序に沿った前進のみ。後退は禁止。**

🔴 **差し戻し Status（`tracker.reworkStatus`）は前進フローの直線上に無い。** ボード上の並び順が途中にあっても、意味は「検証フェーズからの差し戻し」であって次の前進段階ではない。**遷移元テーブルに一切登場させない**（修正着手時に担当者が手動で作業中へ戻し、そこから通常フローを再走する）。

遷移元の分類:

| 遷移元 | 扱い |
|---|---|
| 遷移先の**直前**の Status | ✅ クリーン（自動適用の対象） |
| 遷移先より**2 つ以上手前**の Status | ⚠️ 要判断（**中間の確認工程をスキップする**ので個別承認） |
| 遷移先と同じ or それより先 | 🚫 後退防止（スキップ） |

## 手順

### 1. 入力の解決

1. **リリース PR** — 引数の URL 群を使う。未指定なら各リポの直近マージ済みリリース PR を自動検出して提示・確認する
2. **遷移先 Status** — `--to` があればそれ。無ければ PR の base / head から推定して確認する
3. 各リリース PR が **MERGED** であることを確認する（未マージなら停止して報告）

### 2. バンドル PR 番号の抽出

リリース PR の本文はチェックリスト形式のことが多い。本文から PR 番号を抽出する:

```bash
gh pr view "$NUM" --repo "$REPO" --json body --jq .body \
  | grep -oE '#[0-9]+' | tr -d '#' | sort -n | uniq
```

### 3. 順方向マッチング（PR 本文の参照キーワード）

束ねられた PR の本文を **GraphQL エイリアスで一括取得**する（1 クエリ最大 60 件目安、超えたら分割）。本文から参照を抽出する:

```text
(closes?|close[ds]|fix(es|ed)?|resolves?|refs?)[: ]+<owner>/<repo>#([0-9]+)   # 大文字小文字無視
```

🔴 **`refs` を除外しない。** 規約上は「`Closes` = 解決する実装 PR / `Refs` = 参照のみの追従 PR」だが、**実運用ではこの signal が成立しないことがある**（実装 PR が `Refs` を使う）。除外すると実装 PR の大半を取りこぼす。

帰結として **要判断バケットが増えるのは仕様。** dry-run の `matched=<keyword>` と PR タイトルを見て**人が判定する**。「`Refs` だから追従 PR」と機械的に落とさない。

### 4. 逆方向マッチング（Project → Issue タイムライン照合）

🔴 **順方向だけでは 2 割前後が漏れる**（参照規約に従っていない PR が原因）。逆方向で補完する。

1. Project から**「クリーンな遷移元」と「要判断の遷移元」の両方**の Issue 一覧を取得する（毎回 fresh）:

```bash
bash "$DEVKIT_ROOT/.claude/devkit/project-items-fetch.sh" /tmp/srs_items.json
jq -r '.items[] | select(.status == "<クリーンな遷移元>" or .status == "<要判断の遷移元>")
       | "\(.content.number)\t\(.id)\t\(.status)\t\(.content.title)"' /tmp/srs_items.json
```

🔴 **候補プールを「クリーンな遷移元」だけに絞らない。** 「同一 Issue に対する既存 PR が先に進めており、今回のリリースにはその**フォローアップ PR**（二重 close 回避のため参照のみ）が束ねられている」ケースが実在する。この Issue は要判断側の Status に居るため、絞ると**順方向・逆方向どちらでも永久に検出されない**。

2. 各 Issue のタイムラインから紐付く PR を取得する。**紐付けイベントは 2 種類あり、両方を照合する**:

**(a) `cross-referenced`**（PR 本文・コメントでの Issue 言及。キーワードの有無に関わらず発火するので参照のみの PR も捕捉できる）— REST timeline API:

```bash
gh api "repos/$DEVKIT_REPO/issues/${N}/timeline" --paginate --jq '
  .[] | select(.event == "cross-referenced") | .source.issue
  | select(.pull_request != null) | "\(.repository.full_name)\t\(.number)"'
```

**(b) `connected`**（Issue サイドバーの Development フィールドからの手動リンク）— REST は相手 PR の repo / number を返さないため **GraphQL が必須**。**リンク解除は `DISCONNECTED_EVENT` として積まれるので、両イベントを取得して PR ごとに最新イベントで判定（後勝ち）する**:

```bash
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){
  issue(number:$n){ timelineItems(first:100, itemTypes:[CONNECTED_EVENT, DISCONNECTED_EVENT]){ nodes{
    __typename
    ... on ConnectedEvent { subject { ... on PullRequest { number repository { nameWithOwner } } } }
    ... on DisconnectedEvent { subject { ... on PullRequest { number repository { nameWithOwner } } } }
  } } } } }' -f o="${DEVKIT_REPO%%/*}" -f r="${DEVKIT_REPO##*/}" -F n="$N" \
  --jq '.data.repository.issue.timelineItems.nodes
    | map(select(.subject.number != null) | {t:.__typename, r:.subject.repository.nameWithOwner, n:.subject.number})
    | group_by([.r,.n]) | map(last)
    | .[] | select(.t == "ConnectedEvent") | "\(.r)\t\(.n)"'
```

`timelineItems` は古→新の順で返り jq の `group_by` は安定ソートなので、`map(last)` が PR ごとの現在の紐付け状態になる。**`CONNECTED_EVENT` 単独取得に簡略化しない**（解除済みの古いリンクを有効扱いしてしまう）。

3. 取得した PR がバンドルに含まれていれば、その Issue も遷移対象に加える

> **Issue 番号を含む検索（`gh search prs "repo#NN"`）は `#` を検索できずヒットしない。** タイムライン API が確実。

### 5. ガード付き分類

| 分類 | 条件 | 扱い |
|---|---|---|
| ✅ 遷移対象 | 現在 = クリーンな遷移元 かつ バンドル一致 | dry-run に載せ承認後に適用 |
| ⚠️ 要判断 | 現在 = 要判断の遷移元 かつ バンドル一致 | 別枠で提示し個別に確認 |
| 🚫 後退防止 | 現在が遷移先と同じ or それより先 | スキップ（理由付きで報告） |
| ⚠️ フロー外 | 作業前 Status 等 | スキップ（理由付きで報告） |
| 📋 stale 候補 → 🔁 解消提案 | 候補プールに居るがどのバンドルにも紐づかない | **実反映を機械判定**して確定分は解消提案に載せる（下記） |

**stale 候補の実反映チェック（積極的に解消する）**: バンドルに現れない反映経路が実在する（手動リリースブランチ・hotfix 中継・過去サイクルでの取りこぼし）。タイムラインから辿れた PR の merge commit を compare API で照合する:

```bash
SHA=$(gh pr view "$PRNUM" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)
gh api "repos/${REPO}/compare/<統合先ブランチ>...${SHA}" --jq .status   # behind / identical なら到達済み
```

- 到達済みと判明した候補は**今回の遷移先が妥当なら dry-run に「stale 解消」として追加提案**する
- **反映有無が確定できない（`diverged` 等）ものだけ、純粋な報告に留める**（自動提案しない）

### 6. dry-run 提示・承認（書き込み前ゲート）

適用前に必ず一覧表で提示して承認を取る。各行:

Issue 番号 / タイトル / 現在 Status → 遷移先 / 根拠 PR / **`matched=<keyword>`** / **根拠 PR のタイトル** / マッチ方向（順方向 or 逆方向）

**`matched` と PR タイトルを省略しない。** キーワードから実装 PR / 追従 PR が判別できない分を、レビュー時に人が補うための情報。スキップ・stale 候補も理由付きで列挙する。

### 7. 適用

```bash
gh project item-edit --project-id "$DEVKIT_PROJECT_ID" --id "$ITEM_ID" \
  --field-id "$DEVKIT_STATUS_FIELD_ID" --single-select-option-id "$OPTION_ID"
```

🔴 **適用後に Project を再取得し、遷移先 Status の Issue 集合が期待と一致することを検証してから完了報告する。**

### 8. 完了報告

更新（**バンドル一致分 / stale 解消分を分けて明示**）/ 要判断（保留）/ スキップ（理由別）/ 未確定 stale 候補 の件数と一覧。**参照規約に従っておらず逆方向でしか拾えなかった PR は、リンク運用改善のフィードバック材料として明示する。**

## 実装上の落とし穴（必読）

- 🔴 **シェルの word-splitting**: zsh は クォートしていない変数を単語分割しない。**ループ・配列を使う処理は bash スクリプトファイルに書いて `bash script.sh` で実行する**
- **BSD grep に `-P` は無い**（macOS）。タブ区切り TSV の完全一致は `awk -F'\t' -v n="$n" '$1 == n'` を使う
- **GraphQL のエイリアスバッチは 60 件 / クエリ目安**。それ以上は分割する
- **`gh project item-edit` には `project` scope が必要。** 失敗したら `gh auth status` で確認し `gh auth refresh -s project`
- 🔴 **Issue 番号の重複除去は必須**（1 Issue に複数リポの PR が紐づく）
- 🔴 **参照キーワードから実装 PR / 追従 PR を判別できると仮定しない**（手順 3 参照）
- 🔴 **逆方向マッチングの候補プールを「クリーンな遷移元」だけに絞らない**（手順 4 参照）
- 🔴 **差し戻し Status を「作業中の次の前進 Status」と扱わない**

## 合格基準

- 順方向・逆方向の**両方**でマッチングしている
- 逆方向の候補プールに**要判断の遷移元も含めて**いる
- 後退遷移が 0 件
- フロースキップ遷移をユーザー承認なしに適用していない
- 適用前に dry-run で承認を得ている
- 適用後に Project を再取得して検証している
- stale 候補は compare API で反映有無を判定し、確定分のみ解消提案に含めている

## 進捗ログ

- 起動: `▶ /sync-release-status（PR n 件, → <遷移先>）`
- 抽出: `📦 バンドル PR x 件 / 順方向 y Issue / 逆方向 +z Issue（要判断の遷移元含む）`
- dry-run: `🔍 遷移対象 a / 要判断 b / スキップ c / stale 候補 d（うち解消提案 e）`
- 適用: `✅ 更新 p 件（バンドル一致 q + stale 解消 r、検証済）`
