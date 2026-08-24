---
name: onboarding
description: プロジェクトに新しくジョインしたメンバー向けのオンボーディング。前提ツールの確認、関連リポジトリの clone、アクセス権の棚卸し、開発ガイドの案内、ローカル環境構築までを対話的に進める。「オンボーディング」「onboarding」「初期セットアップ」「新規参加」と言われた時に使用してください。
allowed-tools: Bash(bash *), Bash(git *), Bash(gh *), Bash(jq *), Bash(ls *), Bash(which *), Read, AskUserQuestion
---

# onboarding — 新規参加メンバーのセットアップ

## 手順

### 1. 設定と前提ツールの確認

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
```

必須:

```bash
git --version
gh --version && gh auth status
jq --version
```

`devkit.json` の `commands` に登録されているコマンドから、**このプロジェクトが必要とするランタイム**を推定して確認する（`npm` があるなら Node、`pytest` があるなら Python、など）。**推定した内容はユーザーに提示して確認を取る** — 決め打ちで「必要」と言い切らない。

不足があれば導入方法を案内し、**先に対応してもらってから次へ進む**。

### 2. 関連リポジトリの clone

`siblingRepos` のうち `repo`（`OWNER/NAME`）を持つものを、`path` が示す場所へ clone する。

```bash
jq -r '.siblingRepos[]? | select(.repo != null) | [.name, .path, .repo] | @tsv' "$DEVKIT_CONFIG" \
| while IFS=$'\t' read -r name path repo; do
    if [ -d "$path/.git" ]; then
      echo "SKIP  $name（clone 済み）"
    else
      echo "CLONE $name <- $repo -> $path"
    fi
  done
```

実行は上の一覧をユーザーに提示してから。**結果（成功 / スキップ / 失敗）をリポジトリごとに報告する。**

`siblingRepos` が空、または `repo` が設定されていない場合は「clone 対象なし」と報告してこの手順を飛ばす。

### 3. アカウント・アクセス権の棚卸し

**プロジェクト固有のアクセス権はこのスキルに列挙しない**（プロジェクトごとに違い、書くと必ず陳腐化する）。次の順で拾う:

1. `CLAUDE.md` / `README.md` に「必要なアクセス権」「前提」の記述があればそれを提示する
2. `.claude/rules/` に認証・インフラ・環境構築に関する記述があれば拾う
3. どちらにも無ければ、**`AskUserQuestion`（multiSelect）で「発行済みか」をユーザーに確認する共通項目**を出す — アカウント / クラウドコンソールへのアクセス / ネットワーク（VPN 等） / 個人用ストレージや検証環境の払い出し

未完了の項目は、**誰に依頼すればよいか**まで含めて案内する（分からなければ「プロジェクト管理者に確認」と明示する）。

### 4. 開発ガイドの案内

`CLAUDE.md` を Read して、以下に相当するセクションの内容を案内する:

- **動作確認環境** — ローカル / 検証環境 / ステージングの URL と用途
- **ブランチ運用** — feature / ベースブランチ / デプロイ用ブランチの役割
- **リリースフロー** — CI/CD の流れ、リリース PR の生成、環境間の反映順序

🔴 **CLAUDE.md の内容をこのスキルにコピーしない。** 二重管理になり、必ず片方だけが更新されて食い違う。**読んで案内する**。

### 5. 開発ハーネスの案内

このリポジトリで使えるスキルを案内する:

- `/implement-issue` — Issue から PR までの統括（自走モードあり）
- `/define-requirements` → `/design-implementation` — 要件と設計を Issue に残す
- `/audit-changes` / `/verify-browser` — セルフレビューと実機検証
- `/harvest` — 会話から得た知見を `.claude/rules/` に永続化する

**`.claude/rules/` は毎セッション自動で読み込まれる**こと、だからこそ肥大化を機械検証していること（`/harvest` の Phase 6）を伝える。

### 6. ローカル開発環境の構築

プロジェクトにローカル環境構築の手順（`README.md` / `Makefile` / 専用スキル）があればそれに従う。無ければ `devkit.json` の `commands` から最小の立ち上げ手順を組み立ててユーザーに提示する。

### 7. 初回動作確認

ローカル環境が立ち上がったら、**チェックリスト形式で**ユーザーに確認してもらう:

1. アプリのトップページが開くか
2. サインインできるか（初回はアカウントの有効化が別途必要なことがある。手順があれば案内する）
3. 主要機能が 1 つ動くか

## 結果サマリ

clone 状況・アクセス権の未完了項目・環境構築の到達点を一覧で報告し、**次に何をすればよいか**を 1 行で示して終わる。
