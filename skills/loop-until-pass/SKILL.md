---
name: loop-until-pass
description: 任意の検査スキル / コマンドを「合格 or 上限N回」までループ実行する汎用統括。各イテレーションで合格判定→不合格なら原因要約→修正→再実行を繰り返す。「合格まで回して」「loop-until-pass」「pass するまでやって」「lint 通して」「lint 直して」「test 通して」「テスト通して」「テスト直して」「通るまで回して」「グリーンにして」と言われた時に使用してください。
argument-hint: '<check> [--max N] [--fix <action>] [--pass-when <condition>]'
allowed-tools: Skill, Agent, Bash(*), Read, Edit, Glob, Grep, AskUserQuestion
---

# loop-until-pass — 合格基準を満たすまで自律ループ

任意の検査（スキル / シェルコマンド / テストコマンド）を「合格 or 上限到達」までループ実行する汎用統括。各工程スキルが個別に持つループロジックの汎用版。

## 設計意図

- **検査と修正の分離**: 検査で原因を特定 → 修正 → 再検査、の明示分離
- **上限制御**: 無限ループと料金暴走の抑止（既定 3）
- **原因要約**: 各失敗で「何が」「なぜ」を構造化し、次イテレーションで参照
- **既知パターンは修正でなく再実行**: 一過性の失敗を「バグ」として直しにいかない

## 引数

`$ARGUMENTS`:

- `<check>`: 検査内容（必須）
  - `skill:<name> [args]` — 例 `skill:audit-changes 5`
  - `cmd:<command>` — 例 `cmd:npm run lint`
  - `test:<command>` — 例 `test:npm run test:ci`
  - 省略時は `.claude/devkit.json` の `commands.lint` を既定にする
- `--max N`: 上限。省略時 **3**
- `--fix <action>`: `manual` / `auto`（既定） / `skip-known-flaky`
- `--pass-when <condition>`: `exit:0`（既定） / `regex:<pattern>` / `no-regex:<pattern>` / `custom`

## 手順

### 1. 設定と引数の解釈

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
```

`cmd:`/`test:` が省略された場合の既定は `$DEVKIT_CMD_LINT` / `$DEVKIT_CMD_TEST`。どちらも未設定なら、何を回すか AskUserQuestion で確認する（勝手に `npm test` 等を仮定しない）。

### 2. ループ（I = 1..MAX）

#### 2.1 検査実行

- `skill:<name>` → 対応する agent があれば **`Agent(subagent_type="<name>")`** で独立コンテキスト実行（親を検査ログで汚さない）。agent 未定義なら `Skill` ツールで直接呼ぶ
- `cmd:` / `test:` → Bash で実行し stdout / stderr / exit code を捕捉

#### 2.2 合格判定

`--pass-when` に応じて判定する。**「取得に失敗した」と「合格だった」を必ず区別する。**

出力が空・非数値・コマンド自体が起動できなかった場合は「判定不能」として次イテレーションに回す。空文字を「エラー 0 件」と読むと、検査が壊れているのに PASS を返す。

```bash
# 例: 未完了件数を数えて数値比較する（grep -qv 等の否定形は誤判定しやすい）
N=$(... | wc -l | tr -d ' ')
case "$N" in ''|*[!0-9]*) echo "取得失敗 → リトライ"; continue;; esac
[ "$N" -eq 0 ] && break
```

PASS → 手順 3。

#### 2.3 原因要約

```
## Iteration I/MAX FAIL
- 失敗種別: lint / test / review / runtime
- 主要エラー: <最上位の error メッセージ>
- 該当ファイル: <path:line>
- 推定原因: <短い説明>
- 既知の一過性パターンか: yes / no
```

#### 2.4 修正アクション

- `manual` → ループ中断、ユーザーに修正依頼
- `auto` → 失敗ログから自律修正（lint は該当ファイルを Read → Edit、test は該当テストと実装を Read → 原因修正）。外部要因・設計判断が要るものはユーザー確認
- `skip-known-flaky` → `.claude/rules/` に記録済みの一過性パターン（CI runner のリソース競合・ポート競合等）に該当すれば修正せず再実行。該当しなければ `auto` と同じ

#### 2.5 次イテレーションへ

### 3. PASS 報告 / 4. FAIL 報告（上限到達）

```
loop-until-pass PASS（試行 I/MAX）
- 検査: <check>
- 履歴: I=1 FAIL (lint error in foo.ts) → 修正 1 件 / I=2 PASS
```

上限到達時は必ず停止し、残存 FAIL・修正試行履歴・推定原因・次アクション候補を報告してユーザーに判断を仰ぐ。

## 使い方の例

```
/loop-until-pass                                  # devkit.json の lint を回す
/loop-until-pass cmd:"make lint"
/loop-until-pass test:"npm run test:ci" --max 5 --fix skip-known-flaky
/loop-until-pass "skill:audit-changes 5" --max 3
```

## CI 完了待ちに使う場合

`gh pr checks --watch` は polling ごとに GraphQL のレート枠を消費し、**枯渇すると exit 0 で終了する**（「完了通知が来たのに CI は未完」になる）。REST の check-runs を数える形にする:

```bash
SHA=<確定した SHA をリテラルで埋め込む>   # git rev-parse HEAD をループ内で呼ばない
N=$(gh api "repos/$DEVKIT_REPO/commits/$SHA/check-runs" \
      --jq '[.check_runs[] | select(.status != "completed")] | length' 2>/dev/null)
case "$N" in ''|*[!0-9]*) sleep 30; continue;; esac
[ "$N" -eq 0 ] && break
```

**SHA はリテラルで埋め込む。** シェルの作業ディレクトリは呼び出しを跨いで持続するため、`git rev-parse HEAD` をループ内で評価すると別リポの HEAD を掴みうる。存在しない SHA は API が 422 を返し、`--jq` の結果が空文字になって「未完了 0 件 = 完了」と誤判定する。

## 進捗ログ

- 起動時: `▶ /loop-until-pass <check>（max=N）を起動`
- 各イテレーション: `🔁 Iteration I/MAX: <check> 実行`
- 失敗時: `⚠️ FAIL: <主要エラー要約> → <修正方針 or rerun>`
- 完了: `✅ PASS（試行 I/MAX）` or `❌ 上限 MAX 到達`

## Notes

- 上限到達時は必ず停止し報告する（無限ループ抑止）
- 修正を伴うループは `git diff` を都度確認し、意図しない混入を防ぐ
- 外部 API 起因・本番環境の検査は `--fix manual` で安全側に倒す
- 新しく判明した一過性パターンは `/harvest` で `.claude/rules/` に追加する
