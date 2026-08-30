---
name: harden-and-verify-issue
description: GitHub Issue の機能に対し「テスト網羅レビュー（漏れ確認）→ 不足テスト実装 → CI green → 手動テスト項目コメント → 検証環境での実機確認 → 結果コメント → 受け入れ OK なら Project Status を前進」までを一気通しで統括する。review-test-coverage / verify-browser を内部で呼び、commit/push/PR/merge/コメント投稿は各ゲートでユーザー承認を取る。「検証環境で受け入れ」「テスト整備して検証まで」「受け入れフロー」「harden-and-verify-issue」と言われた時に使用してください。
argument-hint: '<issue番号> [--repo OWNER/REPO] [--app-pr N] [--env <環境名>] [--from PHASE] [--skip-tests]'
allowed-tools: Skill, Agent, Bash(bash *), Bash(git *), Bash(gh *), Bash(jq *), Bash(date *), Bash(mkdir *), Read, Edit, Write, Glob, Grep, AskUserQuestion
---

# harden-and-verify-issue — テスト整備 → 受け入れ検証の統括

ある Issue の機能に対して、**テストの抜けを潰してから検証環境で実機受け入れし、結果を Issue に記録する**までを統括する。重い工程は既存スキルへ委譲する:

- テスト網羅判定 → [review-test-coverage](../review-test-coverage/SKILL.md)
- 実機検証 → [verify-browser](../verify-browser/SKILL.md)（backend=`cic`）

**このスキル自体は「フェーズ進行・ゲート管理・Issue へのコメント投稿」を担う薄い統括層。**

## 設計意図

- **ルールが SoT** — 判定基準は `.claude/rules/` 側。**観点を二重定義しない**
- **既存スキルを再利用** — review-test-coverage / verify-browser を再実装しない
- 🔴 **不可逆操作は必ずゲート** — commit / push / PR 作成 / merge / Issue コメント投稿は**毎回**承認を取る。**このスキルが承認を内包・省略してはならない**
- 🔴 **共有環境は report-only** — 検証環境・本番を対象にした verify-browser は自律修正ループ無効。FAIL は報告のみ

## 確認完了の定義（Done）

「確認完了 = 次の Status へ進めてよい」は次の 3 つを満たすこと。🔴 **機能の全項目を検証環境で再検証することではない:**

1. **基本担保は単体テスト** — 正しさは UT で固定する（Phase 1-2）。ロジック・分岐・境界・回帰は UT が主担保
2. **E2E は関連 happy path が green** — 網羅ではない
3. **実機確認は「関連箇所にデグレが無いこと」** — 影響範囲（`## Affected Surfaces`）に退行が無いことの確認であって、機能の網羅検証ではない

→ UI が無い / 検証環境で観測できない Issue は、UT + E2E happy path で担保し、実機では**観測可能な関連箇所のデグレだけ**を確認する。**「検証環境でしか確認できない項目を無理に作る」必要はない。**

## エビデンス記録

[エビデンス記録の共通規約](../../docs/evidence.md) に従い、Phase 1-5 の証跡を保存する。**Phase 0 完了時に 1 回準備し、`EVIDENCE_DIR` を export して下位スキルへ継承させる**（verify-browser が同じディレクトリへ追記する）。

| ファイル | Phase | 内容 |
|---|---|---|
| `logs/phase0-target.md` | 0 | Issue 概要 / 関連 PR / 検証面の分類 / 影響範囲 |
| `logs/phase1-coverage.md` | 1 | テスト網羅レビューの findings |
| `logs/phase2-ci.txt` | 2 | lint / test / CI の結果 |
| `logs/phase3-checklist.md` | 3 | 手動テスト項目（投稿した本文） |
| `screenshots/` `logs/console-*` | 4 | 実機検証の証跡（verify-browser が追記） |
| `logs/phase5-result.md` | 5 | 実施記録（投稿した本文） |

## 引数

- `<issue番号>`（必須）
- `--repo OWNER/REPO` — Issue のあるリポ。省略時は `devkit.json` の `repo`
- `--app-pr N` — 機能本体の PR 番号。省略時は Issue 本文 / コメントの参照リンクから自動特定
- `--env <環境名>` — 検証環境。省略時は `verify.baseUrl`
- `--from PHASE` — 指定フェーズから開始
- `--skip-tests` — Phase 1-2 をスキップし、手動テスト項目 + 実機検証だけ回す

## フェーズ全体図

```text
Phase 0  対象特定（Issue + 関連 PR + 機能の所在 + 検証面の分類）
Phase 1  テスト網羅レビュー   → review-test-coverage（Critical / Important を抽出）
Phase 2  不足テスト実装 + CI  → 実装 → lint/test → [commit/push 承認] → [PR 承認] → CI 監視 → [merge 承認]
Phase 3  手動テスト項目コメント → 生成 or 既存検出 → [下書き → 承認 → 投稿]
Phase 4  実機確認             → 検証面 A/B/C/D で手段を選ぶ
Phase 5  結果コメント          → 実施記録を [下書き → 承認 → 投稿]
Phase 6  Status 遷移          → 受け入れ条件を満たせば前進
```

各フェーズ完了時に 1 行サマリを出す。承認待ちで止まり、応答後に再開する。

## 手順

### Phase 0: 対象特定

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
gh issue view <N> --repo "$DEVKIT_REPO" --json title,body,comments,state,labels
```

- 本文 + コメントから機能概要・受け入れ条件・既存の手動テスト項目コメントの有無を把握する
- 機能本体 PR を特定する（`--app-pr` 優先 / 参照リンク / PR 検索）。複数候補なら確認する
- 機能がどの画面・経路に出るかを PR の変更ファイルから推定する
- 🔴 **検証面を分類する**（Phase 4 の A/B/C/D）。**ここで Phase 4 の手段が決まる**
- 影響範囲（Affected Surfaces）を洗い出す。**実機確認はここの「デグレ無し」を見る**
- **機能が検証環境にデプロイ済みかは Phase 4 冒頭で実確認する**（ここでは推定のみ）

### Phase 1: テスト網羅レビュー

`review-test-coverage` を呼び、返った **Critical / Important** を「実装する不足テスト」として確定する。

- **Suggestion は原則やらない**（過剰な多層防御を避ける）。やるなら確認を取る
- 「不足ゼロ」なら Phase 2 をスキップして Phase 3 へ

### Phase 2: 不足テスト実装 + CI

`.claude/rules/` のテスト規約に従って実装する。

- 🔴 **CI ゲートの対象範囲に置く。** テストランナーの収集対象から外れた場所に置くと、**書けているのに 0 実行**になりローカルでも CI でも緑に見える。**最初の配置で正しく入れる**
- ルーター / コールバックに埋まったロジックは**純関数へ抽出**して単体化してよい（挙動変更なし・同一 PR）。ただし**高リスクな経路を触る抽出は、編集前に方針をユーザーへ提示する**
- **フォーマッタは変更ファイルだけに当てる**（全体整形は無関係ファイルを巻き込む）

実装後の流れ（各ゲートで承認を取る）:

1. lint / test を実行して green を確認する
2. **feature ブランチを切る**（ベースブランチへ直コミットしない）
3. `## Affected Surfaces` / `## Test Plan` を含む PR 本文を用意する
4. **[ゲート] commit / push 承認** → commit & push
5. **[ゲート] PR 作成承認** → PR 作成（本文は Issue を**解決しない**なら `Refs`）
6. **CI 監視** — REST の check-runs で polling する。既知の一過性パターンは傍証を取って再実行。本 PR 起因の失敗は止めて報告する
7. レビュー指摘があれば `fix-pr-review` 相当で対応する（fix なら 1 指摘 1 コミット + 返信 + resolve、skip なら理由付き返信 + resolve）
8. **[ゲート] merge 承認** → マージ。マージ後 `git fetch` して反映を物理確認する

### Phase 3: 手動テスト項目コメント

実機検証で使うチェックリストを Issue に用意する。

- **既にあれば再利用する**（生成しない）
- 無ければ受け入れ条件 + PR の Test Plan + 受け入れテスト規約を起点に生成する。**E2E が自動で見る項目は「自動（CI）」、外部サービスの実応答 / 環境やテナントを跨ぐ確認 / 永続化の結果は「手動」と分ける**
- **[ゲート] コメント投稿承認** — 下書きを提示 → 承認 → 投稿

### Phase 4: 実機確認（関連箇所のデグレ確認）

目的は**機能の網羅検証ではなく、影響範囲にデグレが無いことの確認**。Phase 0 の分類に応じて手段を選ぶ。🔴 **UI が無いのに無理やりブラウザを開かない:**

| 検証面 | 例 | 手段 |
|---|---|---|
| **A. UI で見える** | 画面描画・操作・トースト・フォーム | `verify-browser`（backend=`cic`）で関連画面のデグレ確認 |
| **B. 実レスポンス / 挙動** | API レスポンス・ストリーミング・フィルタ | ブラウザでトリガー → 応答 / network を読む。画面に出ないものは直接リクエスト / サーバログ |
| **C. データ状態** | 集計・数値・移行結果・定期処理の効果 | DB クエリ / ログ。**end-to-end の判定は「利用者に見える結果に反映されたか」で行う** |
| **D. 原理的に観測不能** | 本番データ依存・実メール受信・実課金確定 | **検証せず「UT/E2E で担保済」or「本番リグレッション送り」と明示する** |

- 🔴 **B / C でアクセス権が要るのに無い場合は止めてユーザーに依頼する**（勝手に本番を覗かない）
- 🔴 **D に該当する項目の検証を捏造しない。** 観測可能な範囲だけを確認し、D は明示して飛ばす
- **最初に機能のデプロイを確認する。** 対象画面に機能が出なければ「未デプロイの可能性」を報告して停止する（Phase 5 へ進めない）
- 🔴 **WAF / bot 検知にブロックされたら停止してユーザーに依頼する。回避は禁止**
- 権限で出し分けられる画面は**事前にロールを確認する**（verify-browser の該当節）
- 自動化が困難な項目（大量入力 / 別デバイス / 障害注入）は、**実機で代替できる範囲をやり、残りは「UT カバー」or「手動送り」と明示する**
- 🔴 **書き込みを伴う検証は、投入したテストデータを検証後にクリーンアップする**（元の状態へ戻す）。**データ削除を伴う操作はこのスキルでは実施しない** — 残置して報告する
- **共有環境は report-only**（自律修正ループ無効）

### Phase 5: 結果コメント

- 実施環境 / 実施日時 / 実施手段 / 対象 PR
- チェックリスト（pass = `[x]` / 自動検証外 = `[ ]` + 理由）
- 結果サマリ（合格 / 自動検証外 / 不合格 の件数）
- **投入したテストデータをクリーンアップした旨**
- **[ゲート] コメント投稿承認** — 下書き提示 → 承認 → 投稿

### Phase 6: Status 遷移

受け入れが通り、上の「確認完了の定義」3 点を満たしたら Project の Status を次段階へ進める。

🔴 **後退ガード**: 現 Status が既に遷移先より先なら**進めない**。現 Status は targeted query（ITEM_ID から `fieldValueByName(name:"Status")`）で確認してから判断する（全件スキャンは使わない）。

満たさない場合（デグレ検出 / 未デプロイ / 検証中断 / 観測可能な確認が一切できない）は **Status を進めず報告する。**

- **Issue が closed でも全フェーズをそのまま実行する**（実装 PR のマージで close されているのが正常）。**closed を理由にコメント投稿・Status 遷移を控えない**
- **要件自体が未達と判断した場合は差し戻し Status（`tracker.reworkStatus`）へ移す**（据え置きにしない）。デグレのみ / 追加改善に留まる場合は差し戻さず報告する。**この判断に open / closed を使わない**

## ゲート一覧（承認必須・省略禁止）

| Phase | 操作 |
|---|---|
| 2 | commit / push |
| 2 | PR 作成 |
| 2 | PR マージ |
| 3 | 手動テスト項目コメントの投稿 |
| 4 | 実機上の書き込み系操作・クリーンアップ |
| 5 | 結果コメントの投稿 |

🔴 **承認は per-action。1 つの「はい」を後続の別操作へ拡張解釈しない。**

## 進捗ログ

- 起動: `▶ /harden-and-verify-issue #<N>（env=<環境>）を起動`
- 各フェーズ: `▶ Phase k: <名前>` / `✅ Phase k 完了（<1 行サマリ>）`
- ゲート: `⛔ <操作> の承認待ち`
- 完了: `🏁 #<N>: テスト整備 + 受け入れ完了（合格 X / 不合格 Y、Status=<遷移先>）`

## Notes

- **統括のみ。** テスト判定は review-test-coverage、ブラウザ操作は verify-browser に委譲し、観点・操作手順を再実装しない
- **不足ゼロなら Phase 2 を飛ばし、手動項目が既存なら Phase 3 を飛ばす**（無駄な往復をしない）
- Issue が管理リポ、機能が別リポという構成に対応する（**コメント投稿先は Issue のリポ、PR は機能のリポ**）
- **このスキルは Issue を close しない**
