---
name: merge-wording-fix
description: 文言修正（typo・ラベル・説明文・ドキュメントの訂正）を実装から PR マージまで一気通貫で自走する。機械ゲートに合格した変更のみマージ可能で、機能追加・変更等の非自明な修正は自動ブロックされる。「文言修正してマージまで」「typo 直してマージ」「この文言だけ直して」「merge-wording-fix」と言われた時に使用してください。
argument-hint: '[修正内容の説明 | issue番号]'
allowed-tools: Bash(bash *), Bash(git *), Bash(gh *), Bash(python3 *), Bash(npx *), Read, Edit, Glob, Grep, AskUserQuestion, Bash(jq *)
---

# merge-wording-fix — 文言修正のマージまで自走

文言修正**程度**の変更に限り、実装 → PR → CI green → マージまで自走する。

🔴 **マージ可否は自己判断ではなく [機械ゲート](../../tools/wording-fix-gate/README.md) が決める。** PreToolUse hook がマージコマンドの実行時に強制適用する（fail-closed）。

## スコープ（先に自己判定）

対象: **UI ラベル・メッセージ・tooltip・エラーメッセージ・コメント・ドキュメントの文言訂正のみ。**

以下の気配が 1 つでもあれば**このスキルを即中断**し、通常フロー（`/implement-issue`。マージはユーザー）へ切り替える:

- 条件分岐・関数シグネチャ・import・型・スタイル指定の変更
- ファイルの追加・削除・rename
- **文言に見えて挙動を持つ文字列**（API パス・キー・環境変数名・SQL・プロンプト）の変更
- ゲートの denylist 領域（CI 設定 / `.claude/` / `tools/` / migrations / インフラ定義 / lock / json / yaml / shell 等）

🔴 **ゲートが NG になったときに、ゲート・skill・rules を編集して通す行為は禁止**（denylist で機械的にも塞がれている）。NG ならユーザー手動マージへ切り替えるだけ。

## 手順

### 1. 事前確認

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
```

- 対象リポと base ブランチを確定する（`$DEVKIT_REPO` / `$DEVKIT_BASE_BRANCH`。兄弟リポなら `siblingRepos` の値）
- Issue を確認する。無ければ起票する（Project 連携があれば Project へ追加し、着手時に Status を `In progress` へ）
- **既存 PR / リモートブランチの重複を確認する**:

```bash
gh pr list --repo "$DEVKIT_REPO" --state all --search "<issue番号>" --json number,state,headRefName
git ls-remote --heads origin | grep "<issue番号>" || true
```

### 2. ブランチ・実装・ローカルゲート

```bash
git fetch origin "$DEVKIT_BASE_BRANCH"
git checkout -b "${DEVKIT_BRANCH_PREFIX}<issue>-<topic>" "origin/${DEVKIT_BASE_BRANCH}"
```

文言のみ編集する。**コミット前に必ずローカルでゲートを通す**:

```bash
git diff | python3 .claude/devkit/wording-fix-gate/gate.py --stdin
```

NG なら**この時点で自動マージ経路を断念する**（PR を作ってから気付くより手戻りが小さい）。理由を報告して通常フローへ。

### 3. lint・コミット・PR

- **変更ファイルに絞って** lint / format をかける（全体にかけると無関係な既存行まで整形されて diff が膨らみ、ゲートの行数上限に掛かる）
- 文言変更で既存テストの期待文言が落ちるなら同 PR で更新する。**ただしテスト更新が入るとゲートの denylist / 構造判定に掛かることがある** — その場合は手動マージへ切り替える
- コミット前に `git branch --show-current` を確認する
- PR 本文に Issue 参照（`Closes owner/repo#N`）+ `## Affected Surfaces` + `## Test Plan` を書く

### 4. CI green 待ち

**REST の check-runs で polling する**（`gh pr checks --watch` は GraphQL 枯渇時に exit 0 で終了しうる）:

```bash
SHA=<push した commit SHA をリテラルで埋め込む>
N=$(gh api "repos/$DEVKIT_REPO/commits/$SHA/check-runs" \
      --jq '[.check_runs[] | select(.status != "completed")] | length' 2>/dev/null)
case "$N" in ''|*[!0-9]*) sleep 30; continue;; esac   # 空・非数値は取得失敗。完了扱いにしない
[ "$N" -eq 0 ] && break
```

完了したら **conclusion が全て success / skipped / neutral** であることまで確認する。failure が 1 つでもあれば自動マージを中止して原因を調べる。

### 5. マージ

**必ず PR 番号 + `--repo` を明示する**（hook が PR を特定できない形式は一律ブロックされる）。形式は `gh pr merge <番号> --repo <owner/repo> --merge`。

- リポによっては `--squash` / `--rebase` が無効なので `--merge` を既定にする
- hook が `[wording-fix-gate] PASS` を出せばそのまま実行される
- **block された場合は回避もリトライもしない。** block 理由とマージコマンドをユーザーに提示して手動実行を依頼する

### 6. マージ後

- ブランチの自動削除設定があれば削除されている（`git ls-remote --heads origin <branch>` で確認）
- **マージ = 完了ではない。** Status 遷移はリリースフローの既存運用に委ねる
- 結果報告: PR URL / ゲート判定の内訳 / CI 結果

## Notes

- ゲートは**このスキルを使っていなくても**効く（Claude のあらゆるマージ呼び出しに適用される）
- 判定基準・既知の限界は [wording-fix-gate/README.md](../../tools/wording-fix-gate/README.md) が SoT
