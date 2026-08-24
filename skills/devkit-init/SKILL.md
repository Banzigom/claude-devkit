---
name: devkit-init
description: claude-devkit をこのプロジェクトに導入する。対話でリポジトリ・ベースブランチ・lint/test コマンド・課題管理（GitHub Project の有無）を確認して .claude/devkit.json を生成し、rules テンプレ・検証スクリプト・hooks 雛形を配置する。「devkit を入れて」「devkit-init」「開発キット導入」「ハーネス導入」と言われた時に使用してください。
argument-hint: '[--minimal] [--force]'
allowed-tools: Bash(git *), Bash(gh *), Bash(jq *), Bash(mkdir *), Bash(cp *), Bash(ls *), Bash(cat *), Bash(test *), Bash(bash *), Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# devkit-init — プロジェクトへの導入

claude-devkit の skill 群が参照する **プロジェクト固有設定** を作る。これを実行するまで、他の devkit skill は「設定が無い」と言って停止する。

`$ARGUMENTS`:

- `--minimal`: rules テンプレと hooks 雛形を配置せず、`.claude/devkit.json` と検証スクリプトのみ入れる
- `--force`: 既存の `.claude/devkit.json` を上書きする（既定は既存があれば refine に回る）

## 設計意図

- **skill 本体をプロジェクト非依存に保つ**ための単一の差し替え点をここに集約する。skill 側にリポ名・Project ID・lint コマンドを直書きしない
- **推測できる値は推測し、推測できない値だけ聞く**。リポ名は `gh repo view`、lint/test は `package.json` / `Makefile` / `pyproject.toml` から拾える
- **課題管理は任意**。GitHub Project を使わないプロジェクトでも devkit は成立する（`tracker.type = "issues-only"` で Status 遷移だけが無効化される）

## 手順

### 1. 既存設定の確認

```bash
test -f .claude/devkit.json && cat .claude/devkit.json
```

存在し `--force` が無ければ、**新規作成せず既存を refine する**（不足キーの補完のみ提案し、既に入っている値は勝手に変えない）。

### 2. 推測フェーズ（聞く前に埋める）

以下を機械的に取得し、確定値として扱う。

```bash
# リポジトリ（origin から。gh が使えるなら gh を優先）
gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || git remote -v

# 既定ブランチ
gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null

# 既存ブランチの命名慣習（直近 30 本から接頭辞を推定）
git branch -a --format='%(refname:short)' | head -30
```

lint / test / build コマンドは、存在するファイルから拾う（**推測した値は必ず「どこから拾ったか」を添えて提示する**）:

| 手掛かり | 見る場所 |
|---|---|
| `package.json` | `.scripts` の `lint` / `test` / `build` / `typecheck` / `format` / `e2e` |
| `Makefile` | `lint:` / `test:` / `build:` ターゲット |
| `pyproject.toml` / `tox.ini` | `ruff` / `pytest` の設定有無 |
| `.github/workflows/*.yml` | CI が実際に叩いているコマンド（**最も信頼できる**。ローカル向けスクリプトは形骸化していることがある） |

**CI の実行コマンドと `package.json` の scripts が食い違う場合は CI 側を採る。** ローカル用スクリプトは使われないまま古くなりやすく、devkit の lint / test ゲートは「CI と同じものが通ること」を目的とするため。

### 2.5 その他の確定値

- **`commitLanguage`** — コミットメッセージの言語（`ja` / `en`）。**既存のコミット履歴から推測して確認を取る**（`git log --oneline -20`）
- **`verify.baseUrl`** — ローカル開発サーバの URL。`package.json` の dev スクリプトや compose のポート定義から推測する
- **`verify.backend`** — 既定の実機検証バックエンド。**対象が localhost 中心なら `devtools`、認証必須の共有環境中心なら `cic`**（`/verify-browser` は起動ごとに確認するので、ここは既定値にすぎない）

### 3. 課題管理の確認

```bash
gh project list --owner <owner> 2>/dev/null
```

AskUserQuestion で 1 問だけ聞く:

- **GitHub Project で Status 管理している** → 手順 3.1 へ
- **Issue のみ（Project 未使用）** → `tracker.type = "issues-only"`。Status 遷移工程は全 skill でスキップされる
- **GitHub を使っていない** → `tracker.type = "none"`。Issue 起点の skill（define-requirements / design-implementation / implement-issue）は使えない旨を伝え、Tier A（commit-changes / loop-until-pass / audit-changes / harvest）のみ有効にする

#### 3.1 Project の ID 群を取得

**Project の各種 ID は毎回取りに行くと GraphQL のレート枠を食う**（Project の item 数に比例したコストがかかる）。一度取って `devkit.json` に固定値として書き込み、以後は読むだけにする。

```bash
gh project field-list <番号> --owner <owner> --format json \
  | jq '{project: .fields[0].id} , (.fields[] | select(.name=="Status" or .name=="Size" or .name=="Estimate")
        | {field: .name, field_id: .id, options: [.options[]? | {name, id}]})'

gh project list --owner <owner> --format json | jq '.projects[] | {number, id, title}'
```

取得した値を `tracker` に書き込む。Status の option 名はプロジェクトごとに違うので、**`defined` / `ready` / `inProgress` / `done` の 4 つの役割にどの option を割り当てるか**をユーザーに確認する（役割に対応する option が無ければ null のままでよい。その工程だけスキップされる）。

あわせて次の 4 つも確認して書く（運用系 skill が使う）:

| キー | 用途 | 未設定だと |
|---|---|---|
| `workableStatuses` | `/daily-schedule` が「本日やる対象」とみなす Status 名 | 実行時に毎回ユーザーへ確認が入る |
| `releaseStatusOrder` | `/sync-release-status` `/release-progress-report` の前進順 | 一括遷移・集計順が決まらない |
| `statusOptionIds` | Status 表示名 → option ID | 一括遷移が実行できない |
| `reworkStatus` | 差し戻し Status の名前 | 差し戻しを前進フローに混ぜる事故を防げない |

🔴 **`releaseStatusOrder` に差し戻し Status を入れない**（ボード上の並び順が途中でも、意味は前進フローの一段階ではない）。

### 3.2 運用系（層 2 / 層 3）を使う場合の追加設定

使う予定があるものだけ埋める。**空のままでも他の skill は動く。**

| セクション | 使う skill |
|---|---|
| `siblingRepos` | `/pull-all` `/onboarding` `/security-review` `/sync-docs` `/schema-sync` `/vulnerability-fix` |
| `infra` | `/app-log-monitor` `/app-rollback` `/maintenance-mode` `/error-investigation` `/registry-cleanup` `/kube-debug-db` |
| `database` | `/assist-migration` `/schema-sync` |
| `schedule` `report` | `/daily-schedule` `/release-progress-report` |

**推測で埋めない。** 使う段になってユーザーに聞く方が、間違った値で全工程が空振りするより安全。

### 4. `.claude/devkit.json` を書き出す

テンプレートは `templates/devkit.json`（プラグイン同梱）。推測値・確認値を埋めて `.claude/devkit.json` として書く。

**推測した値には必ず出所のコメントを添えて提示してから書く**（`devkit.json` は JSON でコメントを持てないため、提示は会話上で行い、ファイルには値だけ書く）。

### 5. 検証スクリプトの配置

プラグイン同梱の `tools/` をプロジェクト内へコピーする。**プラグインを更新してもプロジェクト側は動き続ける**ようにするため、参照ではなくコピーで持たせる。

```bash
mkdir -p .claude/devkit
cp <plugin>/tools/config.sh              .claude/devkit/config.sh
cp <plugin>/tools/rules-size-check.sh    .claude/devkit/rules-size-check.sh
cp <plugin>/tools/project-items-fetch.sh .claude/devkit/project-items-fetch.sh   # tracker=github-project のみ
cp -r <plugin>/tools/wording-fix-gate    .claude/devkit/wording-fix-gate         # /merge-wording-fix を使う場合のみ
chmod +x .claude/devkit/*.sh
```

**条件付きのものは「使う場合のみ」コピーする。** 使わないスクリプトを置くと、次に読む人が「これは何のために動いているのか」を調べる羽目になる。

配置直後に**必ず動作確認する**（設定の書き間違いはここでしか捕まらない）:

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || echo "設定エラー"
eval "$DEVKIT_ENV"; echo "repo=$DEVKIT_REPO base=$DEVKIT_BASE_BRANCH lint=$DEVKIT_CMD_LINT"
```

### 6. rules テンプレの配置（`--minimal` 以外）

`.claude/rules/` が空なら、プラグイン同梱の `templates/rules/` から配置する。**既存ファイルは上書きしない**。

| ファイル | 役割 |
|---|---|
| `general.md` | 汎用の落とし穴。最初は空の `## Learned` だけ |
| `operations.md` | ブランチ運用・PR 規約・リリースフローの落とし穴 |
| `testing-policy.md` | テスト必須化の方針と除外基準 |
| `README.md` | **何を rules に常駐させ、何を docs へ移すかの判定基準**（P1〜P5 / A1〜A4） |

**`README.md` を落とさないこと。** 判定基準が無いと rules は必ず肥大化し、`harvest` が追記する一方になる。

### 7. hooks 雛形の配置（`--minimal` 以外）

`.claude/settings.json` に SessionStart hook の雛形を提案する。**既存の settings.json がある場合はマージ提案に留め、勝手に上書きしない**。

雛形は `templates/settings.json`。中身は「rules の肥大化チェックをセッション開始時に走らせる」1 本だけ。プロジェクト固有の同期チェック（スキーマ同期・env 配布等）は、必要になってから足す。

`/merge-wording-fix` を使う場合のみ、`PreToolUse` にマージゲートの hook も足す（登録方法は [wording-fix-gate/README.md](../../tools/wording-fix-gate/README.md)）。🔴 **この hook は Claude のあらゆるマージ呼び出しをブロックするので、入れる前にチームへ周知する。**

### 8. 導入結果の報告

```
devkit-init 完了
- 設定: .claude/devkit.json（repo=<...>, base=<...>, tracker=<...>）
- 推測して埋めた値: lint=<...>（出所: .github/workflows/ci.yml）
- 未設定のまま残した値: <キー名>（理由: <...>）
- 配置: .claude/devkit/{config.sh,rules-size-check.sh}
- rules: <新規作成 N ファイル / 既存を尊重して skip>
- 次にできること: /implement-issue <issue番号> または /commit-changes
```

## 合格基準

- `bash .claude/devkit/config.sh` が exit 0 で `DEVKIT_REPO` を出力する
- `tracker.type` が `github-project` なら、`projectId` と `statusFieldId` が両方埋まっている（片方だけだと Status 遷移が実行時に失敗する）
- `bash .claude/devkit/rules-size-check.sh` が exit 0 で終わる（rules を配置した場合）
- `tracker.type` が `github-project` なら `bash .claude/devkit/project-items-fetch.sh /tmp/check.json` が exit 0 で item を取得する（**0 件で成功したら owner / number の設定違いを疑う**）
- 配置したスクリプトが**設定を実際に読めている**（`config.sh` の出力に `DEVKIT_REPO` が入っている）

## Notes

- **推測値をユーザー確認なしに確定しない**。特に lint / test コマンドは、間違っていると以降の全工程のゲートが空振りする
- 既存の `.claude/` 資産（skills / rules / settings.json）は尊重する。devkit は追加であって置換ではない
- `tracker.type = "none"` でも Tier A の skill は動く。全部入りを前提にしない
