---
name: schema-sync
description: スキーマ定義の source of truth リポから、それを参照する他リポへスキーマをコピー同期して PR を作る。「スキーマ同期」「schema-sync」「他リポにスキーマを反映」と言われた時に使用してください。
argument-hint: '[issue番号]'
allowed-tools: Bash(bash *), Bash(git *), Bash(gh *), Bash(make *), Bash(npx *), Bash(cp *), Bash(jq *), Read, Edit, Glob, Grep, AskUserQuestion
---

# schema-sync — スキーマの横展開

スキーマの **source of truth は 1 リポ**。それを参照する他リポへコピーして PR を作る。

🔴 **SoT でスキーマを変更したら、同 PR または即後続 PR で同期する。後回し厳禁。** 特に **DROP は DB 本体が先に変わる**ので、同期が遅れるほど「DB に存在しない列を select する」不整合の実害ウィンドウが伸びる。

## 前提

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
jq -r '.database.schemas[]? | [.name, .path] | @tsv' "$DEVKIT_CONFIG"
jq -r '.siblingRepos[]? | [.name, .path, (.baseBranch // "")] | @tsv' "$DEVKIT_CONFIG"
```

**同期先ごとに変換が要ることがある**（生成先の指定・プレビュー機能・言語別クライアントの差異）。変換規則はスクリプト化して**手作業でその都度直さない**（毎回ずれる）。

## Phase 0: 事前確認

1. Issue 番号（PR 本文の参照に使う）
2. SoT リポでのスキーマ差分を確認する:

```bash
git -C "<SoT path>" diff "origin/<base>...HEAD" -- '<schema path>'
```

3. **変更サマリ（追加 / 変更 / 削除の列とテーブル）を提示する。** 🔴 **DROP が含まれるかを明示する**（デプロイ順序が変わるため）

差分が無ければ「同期不要」と報告して終了する。

## Phase 1..N: 同期先ごとに PR

各同期先について:

1. **基底ブランチを最新化してからブランチを切る**（基底はリポごとに違いうるので決め打ちしない）
2. スキーマをコピーし、必要な変換をかける
3. クライアント生成コマンドがあれば実行する
4. **差分を確認する** — 🔴 **スキーマ以外のファイルが差分に混ざっていないか**を `git status --short` で確認する（生成物が意図せず入りやすい）
5. コミット + PR 作成。本文に SoT 側の PR / Issue を参照する

## Phase N+1: 結果報告

```
## スキーマ同期 完了
### 変更内容
- 追加: <...> / 変更: <...> / 削除: <...>
### PR
- <repo>: <URL>
### デプロイ順序
- 追加のみ → SoT を先に反映
- 削除を含む → 同期先を先に反映
```

🔴 **順序を報告に必ず書く。** 順序を誤ると、同期済みでも障害になる（[assist-migration](../assist-migration/SKILL.md) のデプロイ順序表）。

## エラーハンドリング

| 状況 | 対処 |
|---|---|
| 同期先が未 clone | 報告して停止（黙って飛ばさない） |
| 変換スクリプトが失敗 | 停止して報告。**手作業で繕わない**（次回もずれる） |
| 生成コマンドが失敗 | 依存のインストール状態を確認。**生成物なしでコミットしない** |

## Notes

- 🔴 **他リポの schema に古い列が残っていても、そのリポが実際にクエリするモデルでなければ実害は出ない。** 「同期漏れ = 即危険」と決めつけず影響を測る。判定は **(1) そのリポが実クエリするモデルを列挙 → (2) DB に適用済みの SoT schema と列単位で突合**し、**「自リポの schema が宣言するが DB に無い列」が 0 件**であることを見る（逆向きは無害）
- 突合スクリプトは**物理名マッピングを解決し、DB 列を持たないリレーションを除外する**こと
- 🔴 **`git show <commit>:<path>` のパスを間違えると空が返り、`grep -c` が 0 =「安全」と誤判定する。** `git ls-tree -r --name-only <commit>` で実在パスを先に確認する
