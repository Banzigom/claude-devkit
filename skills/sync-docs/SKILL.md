---
name: sync-docs
description: 実装（コード）を source of truth として、.claude/rules/*.md の記述とのドリフトを検出し、承認後にルールファイルを更新する。「ルールのドリフト確認」「ルールを最新化」「sync-docs」と言われた時に使用してください。
argument-hint: '[ルールファイル名 | --all]'
allowed-tools: Bash(bash *), Bash(git *), Bash(jq *), Bash(grep:*), Bash(ls:*), Read, Edit, Glob, Grep, AskUserQuestion, Bash(make *)
---

# sync-docs — ルールと実装のドリフト検出・修正

**コードが source of truth。** `.claude/rules/*.md` の記述が実装と食い違う箇所を検出し、承認後にルール側を実装へ合わせる（逆ではない）。

ルールに書かれた値は**書いた時点のスナップショット**であり、放置すると誤った手順を誘発する。これはその差分を定期的に拾うためのスキル。

## 前提: source が複数リポに分散しうる

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
cd "$DEVKIT_ROOT"

jq -r --arg d "$DEVKIT_BASE_BRANCH" \
  '.siblingRepos[]? | [.name, .path, (.baseBranch // $d)] | @tsv' "$DEVKIT_CONFIG" \
| while IFS=$'\t' read -r name path base; do
    if [ -d "$path/.git" ]; then
      echo "$name: $(git -C "$path" branch --show-current) (base: $base)"
    else
      echo "$name: 未 clone"
    fi
  done
```

🔴 **参照前に「どのブランチを見ているか」を確認する。** checkout は別作業の feature ブランチに載っていることが常態で、そこで計測した値はベースと乖離する。ベースと違うなら `git worktree add <dir> origin/<base>` した実体で計測する。

🔴 **未 clone のリポを source とするルールは「検証不能」として報告する。黙って飛ばさない**（「ドリフトなし」と誤読される）。

## ルールと source の対応をどう決めるか

**固定の対応表を持たない**（プロジェクトごとに構成が違うため）。優先順に:

1. **各ルールファイル末尾の「関連ファイル」表** — あればこれが一次情報
2. **ルール本文中に出てくる具体的な識別子**（ファイルパス / 関数名 / 環境変数名 / 定数名 / コマンド）— それ自体が検証対象
3. 上のどちらも無いルール（判断基準・Learned 中心のもの）は**コードを source とする事実が薄い**ので、明確なファイル参照がある記述だけを検証する

## 検出の観点

| # | 観点 | 例 |
|---|---|---|
| 1 | **コマンド / スクリプト** | `make` ターゲット・`package.json` の scripts がルール記述と一致するか |
| 2 | **パス / 構造** | ディレクトリ構成・ファイルパス（特に「関連ファイル」表） |
| 3 | **API / 識別子** | 関数名・型名・定数名・環境変数名 |
| 4 | **設定値** | バージョン・上限値・ポート・フラグの既定値 |
| 5 | **行番号** | ルールが `file:line` を挙げている箇所の実位置 |
| 6 | **用語** | ルールの用語がコードの命名と一致するか |
| 7 | **数の主張** | 「N 箇所ある」「M ファイルが対象」といった**件数の記述**。最もドリフトしやすく、最も誤誘導する |

## 手順

### Phase 1: 解析

1. 対象リポの clone 状況とブランチを確認する（上記）
2. 対象ルールファイルを Read し、検証可能な主張（識別子・パス・件数・コマンド）を列挙する
3. 実装側の事実を `grep` / `ls` / Read で抽出する

### Phase 2: 比較・severity 付け

| severity | 内容 |
|---|---|
| **high** | コマンド / 公開 API / 識別子・環境変数名の不一致 — **誤った手順を実行させる** |
| **medium** | 構造・設定値・件数・行番号の不一致 |
| **low** | 用語・文言の不一致 |

### Phase 3: 報告

```markdown
# ルールドリフト報告

## サマリー: high N / medium N / low N
## 検証不能（未 clone 等）: <列挙>

| Severity | ルールファイル | ルールの記述 | 実際の実装 | 根拠 |
|---|---|---|---|---|
| high | <rule>.md | `make lint` | `npm run lint` | package.json:12 |
```

### Phase 4: 更新（承認後）

1. `AskUserQuestion` で確認する（全部 / 一部選択 / 報告のみ）
2. 承認された箇所のみ Edit する
3. 更新サマリーを出力する

## Notes

- **実装が source of truth。** ルール文を実装に合わせる（逆ではない）
- **変更対象外の記述・コメントは保持する**（ついでに整理しない）
- 🔴 **「値が古いから削除」と判断する前に、そのファイルが本スキルの管理対象として意図的に置かれていないかを確認する。** 「陳腐化した差分を拾うのが目的」で置かれているスナップショットを消すと、突合の対象自体が消える。正しい対処は削除でなく**「スナップショットであり SoT ではない」ことの明示と SoT への導線**
- ルール末尾の `## Learned` は会話由来の知見なので、**コードと矛盾しない限り触らない**
- 参照は節番号でなく**節名**で書く（節の統廃合で番号は壊れる）
