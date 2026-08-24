---
name: audit-changes
description: コードレビューを N 回（既定 5）繰り返して指摘を蓄積し、重複検出で優先度を付けてから優先順に一括修正する。修正後は再レビューで収束判定し、Critical=0 になるまで自律ループする。「徹底レビューして直す」「audit-changes」「まとめてレビュー修正」「一括レビュー」「Critical 全部潰して」「レビュー徹底」と言われた時に使用してください。
argument-hint: '[ラウンド数] [--max-converge M] [--no-loop]'
allowed-tools: Skill, Agent, Bash(git *), Bash(gh *), Bash(make *), Bash(npm *), Bash(yarn *), Bash(pnpm *), Bash(npx *), Bash(python *), Bash(pytest *), Bash(bash *), Read, Edit, Write, Glob, Grep, AskUserQuestion
---

# audit-changes — N 回レビュー → 一括修正 → 収束ループ

レビューを N 回回して指摘を蓄積し、優先順で一括修正、修正後に再レビューして合格基準を満たすまで自律ループする。

## 設計意図

- **レビューと修正を分離** — ラウンド中に直すと次のラウンドの視点が変わるので、検出に専念する
- **重複検出で優先度** — 複数ラウンドで同じ指摘が出るほど重要
- **網羅的に集めてから一括修正** — 多角的に集めてから直す
- **収束ループ** — 修正で混入した新規バグも次サイクルで検出される

## エビデンス記録

保存先の準備・命名・秘匿情報の扱い・コメント形式は [エビデンス記録の共通規約](../../docs/evidence.md) に従う。**サイクル開始前に 1 回**準備する。

| ファイル | 内容 |
|---|---|
| `logs/review-cycle<C>-round<R>.md` | 各ラウンドの findings（Critical / Important / Suggestion） |
| `logs/test-coverage-cycle<C>.md` | テスト網羅レビューの出力 |
| `logs/lint-cycle<C>.txt` / `logs/test-cycle<C>.txt` | 修正後の lint / test 出力 |
| `logs/fix-summary-cycle<C>.md` | 適用した修正の要点 + `git diff --stat` |
| `summary.md` | 収束判定・全サイクル通しの Critical / Important 推移 |

**ラウンドごとの findings をファイルに落とす理由は、重複検出（手順 2.3）の根拠がコンテキストの記憶ではなく実データになるから。** 落とさないと「×3」の回数が後から検証できない。

完了時のコメントには**未解決の Critical**（上限到達時）を必ず含める。

## 合格基準

- **Critical（バグ・セキュリティ・テスト欠落）= 0 件**
- **Important が前サイクル比で減少 or 0 件**（多ラウンド前提なので前回比を採る）
- **lint / test が全パス**

## 引数

- 数値（最初の引数）: 1 サイクル内のラウンド数 N。省略時は `devkit.json` の `review.auditRounds`（既定 5）
- `--max-converge M`: 収束サイクル上限。省略時は `review.auditCycles`（既定 3）
- `--no-loop`: 収束ループを無効化（1 サイクルで終了）

## 手順

### 1. 設定読み込みと変更ファイル確認

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"
git diff "origin/${DEVKIT_BASE_BRANCH}...HEAD" --name-only
```

triple-dot（`A...B`）を使う。分岐点との比較になるので、レビュー待ちの間に base が進んでも差分に混入しない。

### 2. 収束サイクル（C = 1..M）

#### 2.1 N ラウンドのレビュー（修正しない・記録のみ）

各ラウンド、コードレビューを実行する。**修正は一切しない。**

ラウンドごとに観点を変えて多角化する（例: 1 = 正当性 / 2 = 境界値と異常系 / 3 = 既存資産の再利用と重複 / 4 = 保守性とコメントの正確性 / 5 = 性能とリソース）。

指摘を記録する:

```
## Cycle C, Round R/N findings
### Critical（バグ、セキュリティ、テスト欠落）
- file:line — 説明
### Important（設計、保守性、コメントの正確性）
- file:line — 説明
### Suggestion（簡素化、スタイル）
- file:line — 説明
```

複数ラウンドで同じ指摘が出たら出現回数を記録する（`×3`）。

> **レビュー用の built-in skill / agent は、環境によっては起動を拒否されることがある**（呼び出し経路の制約による）。この拒否は一時的な失敗ではないので、下記のエラーハンドリング表（3 ラウンド連続失敗で停止）には載せない。**diff を自分で精読し、ラウンドごとに観点を変えた手動レビューへ切り替えて収束ループを継続する。** そのうえで**「skill を起動できなかったので手動レビューで代替した」ことを最終報告に必ず明記する**（明記しないと、呼び出し側が機械的な検査を通ったと誤認する）。

#### 2.2 テスト網羅レビュー（1 サイクル 1 回）

コードレビューとは**別観点**として `review-test-coverage` を 1 回実行し、テストの過不足を取得する。返却された finding を 2.1 と同形式に正規化して同じ表に追加する。

テスト欠落・回帰テスト未追加・skip 残存は **Critical**、`## Test Plan` セクション欠落は **Important**。

#### 2.3 集約と優先度付け

全ラウンドをマージ・重複排除して表にする。検出回数が多いものを優先。

| 優先度 | ファイル | 指摘 | 回数 |
|---|---|---|---|
| Critical | src/foo.ts:42 | ... | ×3 |

#### 2.4 合格判定（修正前）

`Critical == 0` かつ `C >= 2` かつ（`Important == 0` または `Important < 前サイクル`）を満たせば**収束**として手順 3 へ。`C == 1` は必ず修正フェーズへ（初回は基準ライン作成）。

#### 2.5 一括修正

Critical → Important → Suggestion の順に修正する。**修正前に必ず対象ファイルを Read** し、関連する `.claude/rules/` に従う。

**指摘を鵜呑みにしない。** 各指摘を (1) 具体的な欠陥経路が実在するか、(2) 既存コードやランタイムで既に防がれていないか、(3) 修正が開発フローを壊さないか で判断する。設計判断を伴う指摘はユーザーに確認する。

修正後に `$DEVKIT_CMD_LINT` / `$DEVKIT_CMD_TEST` を実行:

- lint 失敗 → 直して再 lint。3 回失敗で停止して報告
- test 失敗 → `.claude/rules/` に記録済みの一過性パターンに該当すれば 1 回だけ再実行。該当しなければ修正、3 回失敗で停止

#### 2.6 次サイクルへ

### 3. 収束サマリー

```
audit-changes 収束完了
- 総サイクル: C / 上限 M
- 推移:
  - Cycle 1: C=5 / I=12 / S=8 → 修正 13 件
  - Cycle 2: C=1 / I=4  / S=6 → 修正 4 件
  - Cycle 3: C=0 / I=3  / S=5 → 収束
- 最終 lint / test: pass
- 未対応（設計判断保留・skip）: N 件
- レビュー実行形態: skill / 手動代替
```

上限 M に達しても Critical が残る場合は**停止してユーザーに報告**する（無限ループ抑止）。

## 進捗ログ

- 起動時: `▶ /audit-changes（N=5, M=3）を起動`
- 各ラウンド: `🔍 Cycle C/M, Round R/N レビュー実行中`
- 集約: `Cycle C/M 集約: Critical=X / Important=Y / Suggestion=Z`
- 修正: `🛠 修正 N 件適用（Critical X / Important Y / Suggestion Z）`
- 完了: `✅ 収束（Cycle C, Critical=0）` or `❌ 上限到達（Critical N 残）`

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| レビュー呼び出しが API エラー等で失敗 | 該当ラウンドを skip し失敗を記録、N-1 ラウンドで継続。3 ラウンド連続失敗で停止して報告 |
| レビュー skill が**起動を拒否された** | 一時的失敗ではないので上記に載せない。手動レビューへ切り替えて継続し、**代替した旨を報告に明記** |
| `review-test-coverage` 失敗 / exit 非 0 | finding 0 件として扱いサイクル継続（フェイルオープン）。サマリに `test-coverage: skipped (exit=N)` を記録 |
| lint / test の修正が 3 回連続失敗 | 停止して報告（無限ループ抑止） |
| 収束サイクル上限到達かつ Critical 残存 | 停止して報告 |

## Notes

- ラウンド中は修正しない（手順 2.1 の制約）
- コミット / push はしない（別途ユーザー確認）
- 収束ループ中のテスト再実行は既知の一過性パターンのみ。原因不明の失敗は止める
