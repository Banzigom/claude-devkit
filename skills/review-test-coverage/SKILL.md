---
name: review-test-coverage
description: PR / ローカル diff / Issue の変更を `.claude/rules/` のテスト規約と突合し、単体 / E2E / 手動テスト / Affected Surfaces × Test Plan の過不足を Critical / Important / Suggestion 別レポートで返す。修正はしない。「テスト網羅レビュー」「review-test-coverage」「テストルール突合」「UT/E2E 漏れ確認」「Test Plan 検証」、audit-changes / implement-issue の付随観点として使用してください。
argument-hint: '[PR番号 | --issue N | --local] [--base BRANCH]'
allowed-tools: Bash(gh *), Bash(git *), Bash(grep *), Bash(find *), Bash(wc *), Bash(bash *), Read, Glob, Grep, AskUserQuestion
---

# review-test-coverage — テストルール突合

変更内容と検証宣言を、`.claude/rules/` のテスト関連ルールに照らして過不足を判定する。**修正は行わない**。レポート出力のみ。

## 設計意図

- **テストルールが SoT** — 観点や除外対象は `.claude/rules/` を**毎回 Read** して最新基準で評価する（このスキルに観点を二重定義しない）
- **3 入口を 1 出口に** — PR 番号 / ローカル diff / Issue 番号のどれで呼ばれても、出力は同形式
- **コードレビューと分離** — バグ検出はコードレビューの役割。ここは「テストがルールを満たしているか」のみ
- **根拠を明示** — 各 finding に「どのルールの何節に違反するか」を添える

## 合格基準

- [ ] バグ修正なら**再現する回帰テスト**が追加されている
- [ ] リスクの高い領域に触るなら、対応するテスト計画がある
- [ ] 差分に `skip` / `.only` が新規追加されていない
- [ ] 追加したテストが**実際に CI で実行される場所**に置かれている
- [ ] PR 本文に `## Affected Surfaces` と `## Test Plan` がある
- [ ] 同期必須ポイントに該当する変更なら、同期先のテストも触れている

## PASS / FAIL 判定

- **PASS: Critical = 0** / **FAIL: Critical ≥ 1**
- Important / Suggestion は集計のみ

## 手順

### 1. ルール群を Read

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
ls "$DEVKIT_RULES_DIR"/*.md
```

### 2. 対象決定

| モード | 差分の取り方 |
|---|---|
| PR 番号 / 省略（ブランチから自動検出） | `gh pr diff <n> --repo "$DEVKIT_REPO" --name-only` |
| `--local` | `git diff "origin/${DEVKIT_BASE_BRANCH}...HEAD" --name-only` |
| `--issue N` | Issue に紐づく PR を検索して PR モードへ |

### 3. 影響範囲の特定

1. **直接影響** — 変更ファイルの diff
2. **横展開** — 変更した関数 / 型 / 定数を `grep -rn` で全参照元を列挙
3. **同期必須ポイント** — `.claude/rules/` の同期表に該当するかを 1 行ずつ照合
4. **フロー連鎖** — その変更が乗っている一連の流れ（認証 → 認可 → データ取得 → 表示、投入 → 変換 → 集計 → 出力）のどこに触れたか。**1 段だけ見て「影響なし」と判定しない**
5. **環境・条件分岐** — フラグ / ロール / プラン / 環境変数で挙動が変わるなら、**分岐の全枝**がテスト対象か
6. **データ層** — スキーマ・集計・権限フィルタに触れるなら、**フィルタが効かない経路（管理者バイパス等）**も対象に含まれるか

**走査対象が空でないことを必ず確認する。** 構成変更で 0 件走査になると、違反ゼロと区別が付かないまま緑になる。

### 4. 既存テストの棚卸し

```bash
# 変更ファイルに対応するテストの有無
git diff --name-only "origin/${DEVKIT_BASE_BRANCH}...HEAD" \
  | while read -r f; do
      base=$(basename "$f" | sed 's/\.[^.]*$//')
      echo "$f => $(grep -rl "$base" --include='*test*' --include='*spec*' . 2>/dev/null | head -3)"
    done

# 差分に新規追加された skip / only を検出（既存分は数えない）
git diff "origin/${DEVKIT_BASE_BRANCH}...HEAD" | grep -nE '^\+.*\b(it|test|describe)\.(skip|only)\b' || true
```

### 5. 「CI で実行されるか」の確認

**テストランナーの対象パターンから外れた場所に置くと、テストは書けているのに無言で 0 実行になる。** ローカルでも CI でも緑に見えるので、追加されたテストファイルが実際に収集されるかを確認する:

```bash
# 例: 設定の testMatch / testPathIgnorePatterns / CI が叩くコマンドの引数を突き合わせる
grep -rn 'testMatch\|testPathIgnorePatterns\|testPathPattern' --include='*.config.*' --include='package.json' . | head
cat .github/workflows/*.yml 2>/dev/null | grep -nE 'test|jest|pytest|vitest' | head
```

CI が叩くコマンドの対象範囲に**入っていない**新規テストは **Critical**（回帰防止の実効性がない）。

### 6. 検証宣言の抽出

PR / Issue 本文から `## Affected Surfaces` と `## Test Plan` を抽出し、手順 3 で機械抽出した影響範囲と突き合わせる。

### 7. 突合（採点）

| 観点 | Critical | Important | Suggestion |
|---|---|---|---|
| 回帰テスト | バグ修正なのに再現テストが無い | 再現条件が部分的 | ケースを足せる |
| リスク高領域 | テストもテスト計画も無い | 計画のみで実装が無い | — |
| skip / only | 差分に新規追加されている | — | — |
| CI 収集 | 新規テストが CI の対象外の場所にある | 実行時間が極端に長い | — |
| Test Plan | — | セクションが無い | 対応表を詳細化できる |
| 同期必須ポイント | 同期先のテストが無い | 一部のみ | — |
| テストの品質 | 期待値の両辺に同じ定数を使っており文言回帰を検知できない / ソース静的検証が「呼び出しの存在」しか見ておらず無効化を検知できない | 変異検証の記録が無い | — |

### 8. レポート出力

```markdown
# テスト網羅レビュー — <PR #N / ローカル diff>

## 1. 対象
## 2. Affected Surfaces（自動抽出）
## 3. Test Plan との整合性
## 4. テスト過不足（Severity 別）
### Critical
### Important
### Suggestion
## 5. リスク高領域チェック
## 6. skip / .only 検査
## 7. CI 収集の確認
## 8. 同期必須ポイント網羅（該当 N / 網羅 M）
```

### 9. 返却データ構造（呼出側パース用）

レポート本文と**別に**、末尾に JSON ブロックを出力する。

````
```json findings
{
  "summary": { "critical": 1, "important": 2, "suggestion": 1, "passed": false },
  "findings": [
    {
      "severity": "critical",
      "body": "バグ修正に回帰テストが無い",
      "file": "src/logic/billing.ts",
      "line": 120,
      "rule": "testing-policy.md",
      "section": "§必須 / 除外",
      "suggested_fix": "src/logic/__tests__/billing.test.ts に再現テストを追加"
    },
    {
      "severity": "important",
      "body": "## Test Plan セクション未記載",
      "file": null,
      "line": null,
      "rule": "operations.md",
      "section": "§PR",
      "suggested_fix": "PR 本文に影響範囲 × テストケースの対応表を追加"
    }
  ]
}
```
````

フィールド仕様は `/review-requirements` と同一。**ファイル非依存の指摘（PR 本文のセクション欠落等）は `file: null` / `line: null`** で表現する。呼出側はこれを次の形に正規化して、通常コメントと同じ対話フローで処理する:

```
author: review-test-coverage (virtual)
file: (no file)
body: [important] ## Test Plan セクション未記載（根拠: operations.md §PR）
suggested_fix: PR 本文に対応表を追加
thread_id: null
```

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| PR が見つからない | `--local` にフォールバックし、その旨をレポート冒頭に明記 |
| diff が 0 件 | Critical 0 件で PASS を返すが、**「差分なし」と明記する**（「テスト十分」と誤読させない） |
| `gh` 取得失敗 | **停止して報告**。空で進めない |
| ルールディレクトリが空 | Suggestion 1 件 + レポート冒頭に明記 |

## 進捗ログ

- 起動時: `▶ /review-test-coverage <対象> を起動`
- ルール Read 完了: `📚 ルール群 Read 完了（N ファイル）`
- 影響範囲: `🔎 変更 N ファイル / 参照元 M 箇所 / 同期必須ポイント該当 K 件`
- 突合完了: `📊 突合: Critical=X / Important=Y / Suggestion=Z`
- 判定: `✅ PASS（Critical=0）` / `⚠️ FAIL（Critical=X）`

## 呼出側への返り方

`/review-requirements` の「呼出側への返り方」と同じ。**取得失敗（exit 非 0）を「指摘 0 件」と混同しない。**

## Notes

- **修正はしない。** レポートのみ
- **走査対象が空でないことを確認する。** 構成変更で 0 件走査になると、違反ゼロと区別が付かないまま緑になる
- 禁止語やパターンのソース走査を行う場合、**テストファイル自体は走査対象から除外する**（他のテストのテスト名に誤ヒットする）
