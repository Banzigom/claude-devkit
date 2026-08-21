# 汎用ルール

言語・ツール・CI を跨いで効く落とし穴。プロジェクト固有の知見はトピック別ファイルへ。

運用基準（何をここに残し、何を docs へ移すか）は [README.md](./README.md) が SoT。

## Learned

以下は claude-devkit 同梱の初期知見（環境・ツールの性質であってプロジェクト固有ではない）。プロジェクト固有の知見は `/harvest` で追記していく。

- **シェルの作業ディレクトリは呼び出しを跨いで持続する。リポを跨ぐコマンドは毎回 `cd <対象> && ...` を明示する** — 複数リポを行き来する作業で `cd 別リポ` を挟むと、次の `git branch --show-current` が**別リポの結果**を返し「ブランチが勝手に切り替わった」「変更が消えた」と誤認する（`git status --short` も空で返る）。「コミット前にブランチを確認する」という手順自体が、cd を伴わないと無意味になる
- **`git rev-parse HEAD` の結果をループやバックグラウンド処理の中で評価しない。SHA は先に確定してリテラルで埋め込む** — cwd が持続する性質と組み合わさると別リポの HEAD を掴み、API が「そんな commit は無い」と返す。その応答を件数として数えていると**空文字を 0 件と読んで「完了」と誤判定**し、exit 0 で静かに抜ける
- **「取得に失敗した」と「0 件だった」を区別できない書き方をしない** — `--jq` や `grep -c` の結果が空文字・非数値になったケースを数値比較の前に弾く。`if ! echo "$OUT" | grep -qv completed` のような否定形は、出力が一時的に空になった瞬間に偽陽性になる。`N=$(... | length)` で数え、`case "$N" in ''|*[!0-9]*) continue;; esac` を挟んでから `[ "$N" -eq 0 ]` で判定する
- **shallow clone だと git の比較系コマンドが無言で嘘の数を返す** — `git merge-base` が空を返し（exit 1）、`git rev-list --left-right --count A...B` は**エラーを出さずに無意味な数**を返す。ref 名は正しく `git log` も動くので出力から異常だと分からない。ブランチの乖離を測る前に `git rev-parse --is-shallow-repository` を確認し、true なら `--unshallow` する
- **到達不能な remote の tracking ref がローカルに残り、`git show <remote>/<branch>:<file>` が無言で数百コミット前の内容を返す** — fetch が落ちる remote でも過去の `refs/remotes/*` は生き続け、`git show` はエラーなく古い内容を返すため **ref 名は正しいのに中身が古い**ことに気付く手掛かりがない。調査前に到達できる remote へ `git fetch` し、`FETCH_HEAD` か明示 SHA を使う。`git remote -v` に出ていても到達できるとは限らないので fetch の exit code まで見る
- **remote 構成は同じリポでも開発者のローカル checkout ごとに違う。remote 名を手順書で決め打ちせず `git remote -v` で実物を見る** — `origin` が SSH alias の環境と HTTPS の環境が併存し、決め打ちすると `does not appear to be a git repository` で落ちる
- **`git stash push <path>`（部分 stash）とブランチ切替を混ぜない** — stash されなかった変更はブランチを跨いで持ち越され、`pop` 後の checkout で「マージ可能」と判定されると警告なく消える。回避は (a) `git stash push -u` の full stash、(b) 別 worktree で完全分離。消えた場合は `pop` 時に出る `Dropped refs/stash@{0} (<SHA>)` から `git diff <SHA>^ <SHA> -- <path>` で復元する（stash commit は 3 parent なので `git show <SHA>` は空）
- **同一 checkout を複数セッションが共有していると、ブランチの奪い合いは「奪う側」にもなる** — 自分が `git checkout -b` した瞬間に他セッションの作業ブランチ（未コミット変更込み）を奪う。着手前の `gh pr list` / `git ls-remote` は**リモートに push 済みのブランチしか見えず検知できない**。検知は `git reflog -3` の直前 checkout 元、予防は「複数リポ・rules を跨ぐ作業は最初から別 worktree」
- **`sed -i ''` はサンドボックス下でエラーも出さず無反応になる** — ファイル書き換えは編集ツールを使う
- **macOS の `/bin/bash` は 3.2 系で連想配列に非対応** — `declare -A` は `invalid option`、`${!arr[@]}` も展開不可。parallel arrays + `awk` lookup に書き換えるのが最も互換性が高い。加えて macOS の既定シェルは zsh なので、bash 固有記法を使うスクリプトは `#!/usr/bin/env bash` を明示する（明示しないと `bad substitution` で即死する）
- **zsh はクォートしていない変数を単語分割しない** — `FILES="a.ts b.ts"; eslint $FILES` は **1 引数**として渡り `No files matching the pattern "a.ts b.ts"` を返す。この文言は「ファイルが存在しない」と読めるためパスの誤りを疑って時間を溶かす。配列（`files=(a.ts b.ts)`）か `${=FILES}` を使う
- **zsh では `"$var:path"` の `:a` 等が history modifier として解釈されパスが壊れる** — `git show "origin/$b:app/foo.ts"` が別物に化ける。変数の直後にコロンが来る箇所は `${b}` のブレース必須。エラーメッセージにパスの断片が混ざるので「ブランチが存在しない」と誤読しやすい
- **GitHub API の REST と GraphQL はレート枠が独立している（各 5000/hr）** — `gh pr create` / `gh pr checks` / `gh project *` の多くは GraphQL を消費し、sub-agent を並行実行した後は枯渇しやすい。枯渇しても REST 側は生きているので、PR / Issue / コメント / マージは `gh api -X POST repos/{owner}/{repo}/...` で継続できる。残数は `gh api rate_limit --jq .resources.graphql`（これ自体は REST）
- **`gh pr checks --watch` で CI 完了を待たない** — polling ごとに GraphQL を消費し、**枯渇すると exit 0 で終了する**（「完了通知が来たのに CI は未完」になる）。REST の `commits/<sha>/check-runs` で未完了件数を数える形にする
- **`gh pr view --json merged` は存在しない**（`Unknown JSON field`）。マージ状態は `state` を `"MERGED"` で比較し、時刻は `mergedAt`。同様に `gh run list --json` に `path` は無く、特定コミットの全ワークフローを path 付きで見るには REST（`actions/runs?head_sha=<sha>`）を使う
- **`gh api -f body="..."` の本文にシェル特殊文字が混じると double-quoted 展開で消える・化ける** — `$_` は bash の最終引数変数なので `$_.file` が `.file` になる等。ファイル経由（`--body-file`）か single-quote で渡す
- **一括リネームは文字列リテラルの中も置換してしまう** — 外部 API のレスポンスフィールド名を参照している `"field" in res` ごと改名され、判定が常に false になる。型チェッカは検出するが**エラーは誤り箇所でなく下流に出る**ため原因に辿り着きにくい。リネーム後は `git diff` を全行読み、`grep '"<新名>' <file>` で文字列リテラルへの混入 0 件を確認する
