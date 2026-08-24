---
name: pull-all
description: 設定に登録した全リポジトリを一括 pull し、stash と未使用ローカルブランチを棚卸しする。「全リポ最新化」「全部 pull」「pull-all」「リポ掃除」と言われた時に使用してください。
allowed-tools: Bash(bash *), Bash(git *), Bash(jq *), AskUserQuestion
---

# pull-all — 全リポジトリの最新化と棚卸し

`devkit.json` の `siblingRepos`（+ 自リポ）を一括で最新化し、残っている stash とローカルブランチを棚卸しする。**削除は必ずユーザー確認を取る。**

## 手順

### 1. 対象の列挙

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"

# name<TAB>path<TAB>repo<TAB>baseBranch（未設定なら自リポの baseBranch）
{ printf '%s\t%s\t%s\t%s\n' "$(basename "$DEVKIT_ROOT")" "$DEVKIT_ROOT" "$DEVKIT_REPO" "$DEVKIT_BASE_BRANCH"
  jq -r --arg d "$DEVKIT_BASE_BRANCH" \
     '.siblingRepos[]? | [.name, .path, (.repo // ""), (.baseBranch // $d)] | @tsv' "$DEVKIT_CONFIG"
}
```

`siblingRepos` が空なら自リポだけを対象にする（その旨を報告する）。

### 2. 各リポで pull --ff-only

```bash
git -C "<path>" pull --ff-only
```

**`--ff-only` を外さない。** マージコミットを勝手に作ると、他セッションの作業中ブランチに影響が出る。

### 3. fast-forward 失敗時の切り分け

| 症状 | 原因 | 対処 |
|---|---|---|
| `Cannot fast-forward to multiple branches` | **`branch.<base>.*` に同名キーが重複登録**されている（エディタ拡張が増殖させることがある） | `git -C <path> config --get-regexp '^branch\.<base>\.'` で確認し、重複キーを `--unset-all` してから再 pull |
| `divergent branches` | ローカルに未 push のコミットがある | **勝手に rebase / merge しない。** そのリポを報告してスキップし、ユーザーに判断を委ねる |
| 認証エラー | 到達できない remote を見ている | `git -C <path> remote -v` を出す。**remote 構成は同じリポでも環境ごとに違う**ので、名前を決め打ちしない |

**同じ症状が複数リポで一斉に出ることがある**ので、1 件直したら他リポも同じ観点で確認する。

### 4. stash とローカルブランチの棚卸し

```bash
git -C "<path>" stash list
git -C "<path>" branch
git -C "<path>" branch --merged "<baseBranch>"
```

### 5. クリーンアップの判断（ユーザー確認必須）

- **stash** — `git stash show -p 'stash@{N}' --stat` で中身を見せてから削除可否を確認する。**不可逆なので勝手に消さない**
- **ローカルブランチ** — base 以外が残っていたら、`--merged` の結果とあわせて削除可否を確認する。**未マージのブランチは既定で残す**

### 6. 結果報告

更新のあったリポ・失敗したリポとその理由・残った stash / ブランチを 1〜2 行で報告する。

## Notes

- **到達できない remote の tracking ref はローカルに残り続ける。** fetch が失敗しているのに `git show <remote>/<branch>:<file>` が無言で古い内容を返すことがあるので、pull の exit code まで見る
- shallow clone だと比較系コマンド（`merge-base` / `rev-list --left-right`）が**エラーを出さずに無意味な値**を返す。`git rev-parse --is-shallow-repository` が true なら `--unshallow` を促す













