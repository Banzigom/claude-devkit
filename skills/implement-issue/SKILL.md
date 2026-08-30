---
name: implement-issue
description: GitHub Issue を起点に、要件定義→設計→ブランチ→実装→lint/test→動作確認→セルフレビュー→ルール整備→コミット→PR作成→レビュー対応 までを統括する。各工程は合格基準を満たすまで自律ループ。自走モード（--autopilot）で設計承認後はマージ直前まで一気通貫で進める。マージはしない。「issue を実装」「implement-issue」「#340 やって」「最後まで一気に」「自走で」「全部やって」と言われた時に使用してください。
argument-hint: '[issue番号] [--autopilot]'
allowed-tools: Skill, Agent, Bash(git *), Bash(gh *), Bash(make *), Bash(npm *), Bash(yarn *), Bash(pnpm *), Bash(npx *), Bash(python *), Bash(pytest *), Bash(bash *), Read, Edit, Write, Glob, Grep, AskUserQuestion, Bash(jq *)
---

# implement-issue — Issue → PR の統括

各ステップのスキルを順に呼び、機械的な作業は自律実行し、下記の**人のゲート**で止まる。

## 設定読み込み

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
```

`tracker.type` が `none` ならこのスキルは使えない（Issue 起点のため）。その旨を伝えて Tier A のスキルを案内する。

## 入力解釈（自然言語対応）

### ISSUE_NUMBER の抽出

| 入力 | 抽出 |
|---|---|
| `340` / `#340` / `issue 340` / `340 番` | `340` |
| Issue の URL | 末尾の番号 |
| 番号なし | 確認する |

### 自走モード判定

「最後まで」「一気に」「マージ直前まで」「自走で」「全自動で」「人介在なし」「全部やって」「お任せ」または明示 `--autopilot` → 自走モード。

### 特定工程への routing

「レビュー対応」「指摘直して」→ `/fix-pr-review` / 「lint 通して」「テスト通して」→ `/loop-until-pass` / 「徹底レビュー」→ `/audit-changes` / 「画面確認」→ `/verify-browser` / 「要件定義」→ `/define-requirements` / 「設計」→ `/design-implementation` / 「コミット」→ `/commit-changes` / 「harvest」→ `/harvest`。

工程フレーズと自走フレーズが**両方**あれば、implement-issue の自走モードを優先する。

## 人のゲート

| モード | 止まる場所 |
|---|---|
| **自走** | 要件・設計の一括承認 / harvest の知見選別 / マージ / 破壊操作・本番環境 |
| **従来** | 上記 + 設計判断の分岐 + コミット/push/PR の直前（まとめて 1 ゲート） |

**マージはユーザーの明示指示がない限り絶対にしない。**

## 進捗ログ規約（必須）

**節目で逐次出力する。** 自走モードでもユーザーが状況を追えるよう、各工程の開始・成果物・合格判定・ループ反復を 1〜2 行で報告する。

| タイミング | 出力例 |
|---|---|
| スキル起動 | `▶ /define-requirements #340 を起動` |
| sub-agent 起動 | `▶ /review-design #340 を起動（sub-agent）` |
| レビュー収束 | `🔁 review-design Cycle 2/3 開始（前回 Critical=1）` |
| Issue/PR/コミット作成 | `📝 PR 作成: owner/repo#346 (feature/#340 → main)` |
| 合格判定 | `✅ verify-browser PASS（試行 2/3, console=0, 4xx5xx=0）` |
| FAIL / 上限到達 | `❌ lint FAIL（3 回試行）— 残: src/foo.ts:42` |
| ゲート停止 | `⏸ コミット前確認 → ユーザー応答待ち` |

**禁止**: 黙って大きな成果物を作らない（PR・Issue・コミットは必ず URL / SHA を併記）/ 「進めます」だけの空ログ / 同じ内容の重複ログ。

## 各工程の合格基準

**レビュー系 4 工程の合格条件は統一する: `Critical=0` で PASS。** Important / Suggestion は集計するが**通過を阻害しない**（「Important が前回比減少」は Cycle 1 で判定不能なので採らない）。

| 工程 | 合格基準 | ループ |
|---|---|---|
| 要件 | 受け入れ条件が計測可能 / 未解決事項 0 | define-requirements 内の自律推論 |
| **要件レビュー** | **Critical=0** | review-requirements、最大 `review.requirementsCycles` |
| 設計 | 方針評価に根拠 / リスク・テスト計画あり | design-implementation 内の自動採用 |
| **設計レビュー** | **Critical=0** | review-design、最大 `review.designCycles` |
| lint | exit 0 | 最大 3 回 |
| **実装レビュー（軽量）** | **Critical=0** | コードレビュー、最大 `review.implementationCycles` |
| test | exit 0 | 既知の一過性パターンは 1 回再実行、3 回失敗で停止 |
| **テスト網羅レビュー** | **Critical=0** | review-test-coverage、最大 `review.testCoverageCycles` |
| 動作確認 | console error=0 / 4xx5xx=0 / 期待要素の描画 | verify-browser の自律ループ |
| セルフレビュー（徹底） | Critical=0 / Important 前回比減少 | audit-changes の収束ループ |
| CI | 全 check green | REST の check-runs で polling + 既知の再実行 |
| レビュー対応 | 新規指摘 0 or 全 resolved | fix-pr-review |

### Important finding の後工程への引継

各レビューは **Important の主要 3 件を件名付きで返す**。本スキルはこれを `IMPORTANT_BACKLOG` に蓄積し、手順 11 で PR 本文の `## Test Plan` に転記する:

```markdown
### レビュー sub-agent Important 引継

- [要件] <件名>（review-requirements Cycle 1）— 対応: <どうしたか>
- [設計] <件名>（review-design Cycle 2）— 対応: 本 PR では defer、続 PR で扱う
- [実装] N/A
- [テスト網羅] <件名>（review-test-coverage Cycle 1）— 対応: 本 PR にスモーク 1 件追加済
```

**転記漏れは後段の検証で対応漏れの温床になるため必須。** 空なら「Important 引継: 0 件」と明示的に書く。

## 手順

### 1. 要件（Issue に済みなら省略）

```bash
gh issue view ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --json comments
```

`## Requirements` があればそれを使う。無ければ **`Agent(subagent_type="define-requirements")`** で独立コンテキスト実行する（rules 精読・既存実装 grep で親コンテキストを汚さないため）。

### 1.5 要件レビュー（自律ループ）

**`Agent(subagent_type="review-requirements", ${ISSUE_NUMBER})`**。Critical 残なら要件コメントを修正 → 再レビュー。**手順 1 で既存の `## Requirements` を使った場合も本レビューは実施する**（既存要件の品質検査を兼ねる）。

### 2. 実装設計（Issue に済みなら省略）

`## Implementation Design` があればそれを使う。無ければ **`Agent(subagent_type="design-implementation")`**。

### 2.5 設計レビュー（自律ループ）

**`Agent(subagent_type="review-design", ${ISSUE_NUMBER})`**。Critical 残なら設計コメントを修正 → 再レビュー。

### 3. ブランチ + Status:In progress

```bash
git branch --show-current                      # ベースブランチ上でないことを確認
git ls-remote --heads origin | grep "${ISSUE_NUMBER}"   # 他人が既に着手していないか
gh pr list --repo "$DEVKIT_REPO" --state all --search "${ISSUE_NUMBER}" --json number,state,headRefName
```

**着手前に「その Issue で誰かが既に作業していないか」を確認する。** 既存 PR が OPEN で内容が食い違う場合は、他人の PR に push せず別ブランチ名で新 PR を作る（旧 PR の扱いは作成者に委ねる）。

`origin/${DEVKIT_BASE_BRANCH}` から `${DEVKIT_BRANCH_PREFIX}${ISSUE_NUMBER}` を切る。直後に Status を `In progress` へ移す（`tracker.type = "github-project"` のみ。ITEM_ID の取得は `/define-requirements` 手順 6 と同じ targeted query）。

**コードを触り始めるタイミングが Status 遷移のトリガー**。要件・設計フェーズはまだ前の Status のままでよい。

### 4. 実装

確定した設計と `.claude/rules/` に従って実装する。

- Issue のラベルに運用系スキル名があれば、**ハンドコードせずそのスキルで実装する**
- 設計判断が生じたらゲートで確認、それ以外は進める
- **設計で列挙したリスク対策を 1 行ずつ照合する**（抜けても lint / test は通るので、明示的に見返さないと落ちる）

### 4.5 実装レビュー（軽量・自律ループ）

現ブランチの diff を対象に軽量レビューを回す。目的は**実装直後の早期発見**（手戻り最小化）で、徹底レビューは手順 8 に委ねる。Important / Suggestion はここで深追いせず手順 8 へ送る。

> **レビュー用の built-in skill / agent は起動を拒否されることがある。** その場合 agent は手動レビューへフォールバックして**判定結果は返してくる**ため、返却値だけ見ていると skill が走ったと誤読する。**返却の冒頭に「skill を起動できなかった」旨の但し書きが無いか確認し、あれば進捗ログと PR / 報告に「手動レビューで代替」と明記する。**

### 5. lint（合格まで自律ループ）

`$DEVKIT_CMD_LINT` を実行。失敗 → 修正 → 再 lint を最大 3 回。抜けなければ出力を要約して停止。

### 6. テスト（合格まで自律ループ）

`$DEVKIT_CMD_TEST` を実行。`.claude/rules/` に記録済みの一過性パターンに該当すれば 1 回だけ再実行。該当しない失敗は修正 → 再実行を最大 3 回。

**「全体のエラー件数」で合否を判定しない。** base 時点で既存の失敗があるプロジェクトでは件数で混入を検出できない。**変更ファイル名で絞って、そこに出ないことだけを見る。**

### 6.5 テスト網羅レビュー（自律ループ）

**`Agent(subagent_type="review-test-coverage", "--local")`**。Critical 残ならテストを追加 → 再実行 → 再レビュー。

### 7. 動作確認（合格まで自律ループ）

**`Agent(subagent_type="verify-browser")`**。変更が UI に該当しなければその旨を述べてスキップする。

### 8. セルフレビュー（収束ループ）

軽微ならコードレビューを直接。影響が大きいなら **`Agent(subagent_type="audit-changes")`** で Critical=0 まで収束ループ。**指摘は鵜呑みにせず判断する。**

### 9. ルール整備

変更が `.claude/rules/` の記述（コマンド・パス・API）に影響するならドリフトを検出・更新する。

### 10. 知見の永続化

`/harvest` — 知見を提案し、永続化はユーザーが取捨選択する（ゲート）。**自走モードでも残す**（永続知見の品質を維持するため）。

### 11. コミット + push + PR

**従来モード**: コミット前にユーザー確認。承認後 `/commit-changes` → push → PR 作成。
**自走モード**: 設計承認時に事前承認を取得済みとして確認なしで実行。

PR 本文に `## Affected Surfaces` / `## Test Plan` を書き、**`IMPORTANT_BACKLOG` を必ず転記する。**

**Issue 番号の表記**: 別リポの Issue を bare `#NN` で書かない（そのリポ自身の同番号 Issue/PR に autolink され、無関係なタイトルが表示される）。`Closes` 行に限らず本文中の全言及を `owner/repo#NN` 形式にする。

### 12. CI 監視（自律ループ）

**REST の check-runs で polling する**（`gh pr checks --watch` は GraphQL 枯渇で exit 0 終了しうる）:

```bash
SHA=<push した SHA をリテラルで埋め込む>
N=$(gh api "repos/$DEVKIT_REPO/commits/$SHA/check-runs" \
      --jq '[.check_runs[] | select(.status != "completed")] | length' 2>/dev/null)
case "$N" in ''|*[!0-9]*) sleep 30; continue;; esac
[ "$N" -eq 0 ] && break
```

- CI 失敗 → `.claude/rules/` の既知パターンに該当すれば 1 回自動再実行
- 該当しない失敗 → 原因を切り分けて修正 push（**同一原因の修正 push は最大 `review.ciFixPushes` 回**）
- **ジョブが 1 つも生成されず失敗した場合、再実行では絶対に抜けない**（ワークフロー定義自体が不正）。lint ツールでワークフローファイルを検証する

### 13. レビュー対応（自律ループ）

**`Agent(subagent_type="fix-pr-review", ${PR_NUMBER})`**。CI が緑になり指摘が解消するまで手順 12 と自律ループする。**手順 12-13 全体の繰り返しは最大 `review.ciReviewRounds` ラウンド**（無限ループ抑止と料金暴走防止を兼ねる）。上限到達時は停止して判断を仰ぐ。

### 14. マージ前で停止

**マージしない。** 最終状態（PR URL / CI 状態 / 未解決の指摘）を報告する。

## Notes

- 各工程は合格基準を満たすまで自律ループし、上限到達時のみ停止する
- 要件 / 設計は Issue 側に既にある場合があるので手順 1-2 で検出して省略する
- すべての `.claude/rules/` と CLAUDE.md に従う
- **自走モードでも本番環境への破壊操作は確認する**
- **sub-agent の利用が抑止されている環境では、多くの工程が実行不能になる。** その場合は同名 skill を `Skill` ツールで親コンテキストから直接実行する（ただし一部の built-in レビュー skill は Skill ツールから呼べない。その場合は diff を自分で読んでセルフレビューし、**その旨を PR / 報告に明記する**）
