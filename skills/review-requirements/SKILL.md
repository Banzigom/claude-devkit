---
name: review-requirements
description: GitHub Issue の `## Requirements` コメントを `.claude/rules/` と突合し、受け入れ条件の計測可能性 / スコープ境界 / 未解決事項の妥当性 / 自律判定の根拠 / リスク領域の宣言の過不足を Critical / Important / Suggestion 別レポートで返す。修正はしない。「要件レビュー」「review-requirements」「要件品質チェック」、define-requirements / implement-issue の付随観点として使用してください。
argument-hint: '[issue番号]'
allowed-tools: Bash(gh *), Bash(git *), Bash(grep:*), Bash(rg:*), Bash(bash *), Read, Glob, Grep, AskUserQuestion
---

# review-requirements — 要件品質の突合

Issue に投稿された `## Requirements` を、`.claude/rules/` の規約に照らして過不足を判定する。**修正は行わない**。レポート出力のみ。

## 設計意図

- **ルールが SoT** — 判定基準は `.claude/rules/` を**毎回 Read**して評価する。このスキルに観点を二重定義しない（二重定義すると片方だけ更新されて食い違う）
- **設計・実装レビューと分離** — 「どう実装するか」は `/review-design`、「バグ検出」はコードレビューの役割。ここは「要件が計測可能・網羅的か」のみ
- **根拠明示** — 各 finding に「どのルールの何節か」を必ず添える（鵜呑み防止）
- **自律推論のヌケ検出** — `未解決事項` に本来自律判定できる項目が残っていないかを再スキャンする

## 合格基準

以下を全て満たせば PASS:

- [ ] `## Requirements` セクションが存在する
- [ ] **受け入れ条件が計測可能**（画面 X で Y が表示 / API Z が 200 / DB カラム W が値 V）。抽象語のみは NG
- [ ] **スコープ (in/out)** が明示され、周辺機能への波及有無が書かれている
- [ ] **自律判定項目**に根拠（該当 rule / 既存 PR / 類似 Issue）が付いている
- [ ] **未解決事項**に、本来自律判定できる項目が残っていない
- [ ] リスクの高い領域（`.claude/rules/` が定義する領域）に該当する変更なら、それが要件に明示されている
- [ ] 同期必須ポイントに該当する変更なら、該当ポイントが要件のスコープに含まれている
- [ ] 運用系スキルのラベルが付いているなら、そのスキルの必須入力が全て要件で解決している

## PASS / FAIL 判定

- **PASS: Critical = 0**
- **FAIL: Critical ≥ 1**
- Important / Suggestion は severity 別に集計して返すが、**PASS/FAIL には影響しない**
- 「Important が前回比で減少」は Cycle 1 で比較対象が無いため採らない

## 手順

### 1. ルール群を Read（毎回最新で評価）

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
ls "$DEVKIT_RULES_DIR"/*.md
```

**どのルールを読むかは実物の一覧から決める。** ファイル名を決め打ちすると、プロジェクトごとに構成が違うため無言で 0 件評価になる。

### 2. Issue 取得

```bash
gh issue view ${ISSUE_NUMBER} --repo "$DEVKIT_REPO" --json number,title,body,labels,comments
```

### 3. 要件パース

最新の `## Requirements` コメントを対象に、背景 / What / スコープ / 受け入れ条件 / 制約 / 自律判定項目 / 未解決事項 のセクションを抽出する。**セクション自体が無い場合は「欠落」として finding に立てる**（無言でスキップしない）。

### 4. 突合（採点）

| 観点 | Critical | Important | Suggestion |
|---|---|---|---|
| 受け入れ条件 | 計測不能な表現のみ / 条件そのものが無い | 一部が抽象的 | 表現をより具体化できる |
| スコープ | in/out の記載が無い | out of scope が曖昧 | 周辺機能への言及を足せる |
| 自律判定の根拠 | 根拠なしの確定値がある | 根拠が古い / 参照先が不明確 | 参照を追記できる |
| 未解決事項 | 自律判定可能な項目が残っている | 判断者が不明 | — |
| リスク領域 | 該当するのに要件で未宣言 | 宣言はあるが影響範囲が不明確 | — |
| 同期必須ポイント | 該当するのにスコープ外 | 一部のみ言及 | — |
| 運用系スキル | 必須入力が未解決 | 入力値の根拠が薄い | — |

### 5. レポート出力

```markdown
# 要件レビュー — Issue #${ISSUE_NUMBER}

## 1. 対象
## 2. 受け入れ条件の計測可能性
## 3. スコープ境界
## 4. 自律判定項目の根拠
## 5. 未解決事項の妥当性
## 6. リスク領域
## 7. 同期必須ポイント
## 8. Severity 別
### Critical
### Important
### Suggestion
```

各 finding に**根拠（ルールファイル名 + 節名）**を必ず添える。

**節番号（`§3`）でなく節名（`§CI ゲート`）で参照する。** 節の統廃合で番号は壊れる。

### 6. 返却データ構造（呼出側パース用）

レポート本文と**別に**、末尾に以下の JSON ブロックを出力する。呼出側（`audit-changes` / `fix-pr-review` / `implement-issue`）はこれをパースする。

````
```json findings
{
  "summary": { "critical": 1, "important": 2, "suggestion": 1, "passed": false },
  "findings": [
    {
      "severity": "critical",
      "body": "受け入れ条件が「正しく動作する」のみで計測不能",
      "file": null,
      "line": null,
      "rule": "testing-policy.md",
      "section": "§必須 / 除外",
      "suggested_fix": "「画面 X で Y が表示される」形式に書き換える"
    }
  ]
}
```
````

| フィールド | 型 | 説明 |
|---|---|---|
| `severity` | `critical` / `important` / `suggestion` | 手順 4 の表に従う |
| `body` | string | 1 文の指摘内容 |
| `file` | string \| null | 該当ファイル相対パス。**ファイル非依存の指摘は `null`** |
| `line` | number \| null | `file` が null なら必ず null |
| `rule` | string | 違反ルールのファイル名（拡張子付き） |
| `section` | string | 違反ルールの節名 |
| `suggested_fix` | string | 推奨修正の 1 行サマリ |

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| `## Requirements` が存在しない | Critical 1 件（「要件未定義」）として返し、`/define-requirements` を促す |
| Issue 取得失敗（レート制限 / 認証） | **停止して報告**。空で進めない（「指摘 0 件 = PASS」と誤認するため） |
| ルールディレクトリが空 | 評価対象なしとして Suggestion 1 件を返し、その旨をレポート冒頭に明記（**PASS と誤読させない**） |

## Notes

- **修正はしない。** レポートのみ
- 判定基準はルール側にある。ここに観点をコピーしない
- **他の skill の SKILL.md 全文を Read しない**。公開されている契約（skill の description と本 SKILL の合格基準）のみを判定契約とする
