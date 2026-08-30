# claude-devkit

Issue から PR までを自律ループで回す、**プロジェクト非依存**の Claude Code 開発ハーネス。

要件定義 → 設計 → 実装 → レビュー → PR の各工程を skill として持ち、それぞれを **sub-agent で独立コンテキスト実行**することで、ルール精読・diff・レビュー指摘・ブラウザログといった大量の中間情報が親のコンテキストを食い潰さないようにしてある。

開発ループに加えて、**リリース運用・課題管理連携・インフラ運用・多段配線の追加/廃止**まで、プロジェクト非依存の部分を抽出して収録している。

プロジェクト固有の値（リポジトリ名・ベースブランチ・lint/test コマンド・課題管理の ID 群・インフラ構成）は **`.claude/devkit.json` の 1 ファイルに外出し**されており、skill 本体にはどこにも直書きされていない。

## 導入

```bash
# 1. marketplace として登録（ローカルパスでも git URL でも可）
/plugin marketplace add /path/to/claude-devkit

# 2. インストール
/plugin install claude-devkit

# 3. 対象プロジェクトで初期化
/devkit-init
```

`/devkit-init` は、リポジトリ名・既定ブランチ・lint/test コマンドを**先に推測してから**（`gh repo view` / `package.json` / `Makefile` / CI ワークフロー）確認を求め、`.claude/devkit.json` を生成する。あわせて検証スクリプトと rules テンプレを配置する。

**全部入りを前提にしない。** 課題管理・インフラ・DB の設定は、使う skill があるときだけ埋めればよい。

プラグインを更新したら `/devkit-update` を実行する。`tools/` は**コピー**で持たせてあるため、プラグイン側の修正は自動では届かない。`.claude/devkit/VERSION` に刻んだ版と差分を突き合わせ、何が変わるかを見せてから取り込む（プロジェクト側の手入れは黙って上書きしない）。

## 収録スキル

### Tier A — 設定がほぼ不要（どのプロジェクトでも動く）

| skill | 役割 |
|---|---|
| `commit-changes` | Conventional Commit（push はしない） |
| `loop-until-pass` | 任意の検査を合格まで回す汎用ループ |
| `audit-changes` | N 回レビュー → 一括修正 → 収束ループ |
| `harvest` | 会話から知見を抽出して rules へ永続化 |
| `genshijin` | 超圧縮コミュニケーションモード（**ハーネスとは独立**。他 skill と依存関係を持たないので、不要なら削除してよい） |

### Tier B — Issue 起点の開発ループ

| skill | 役割 |
|---|---|
| `implement-issue` | Issue → PR の統括（自走モードあり） |
| `create-issue` | テンプレートに沿った Issue 起票 |
| `define-requirements` / `design-implementation` | 要件（何を / なぜ）と設計（どう実装するか） |
| `review-requirements` / `review-design` / `review-test-coverage` | 突合（**判定のみ・修正しない**） |
| `fix-pr-review` | PR レビュー対応（reply / resolve まで） |
| `verify-browser` | ブラウザ実機検証 |
| `harden-and-verify-issue` | テスト整備 → 実機受け入れ → Status 前進の統括 |
| `merge-wording-fix` | 文言修正のみマージまで自走（機械ゲート付き） |

### Tier C — チーム運用 / リリース

| skill | 役割 |
|---|---|
| `sync-release-status` | リリース PR から親 Issue を辿って Status を一括遷移 |
| `release-progress-report` | 現イテレーションの Status 別集計 |
| `daily-schedule` | 担当 Issue から本日のスケジュールを組んでカレンダーへ |
| `sync-docs` | 実装を SoT とした rules のドリフト検出 |
| `security-review` | リリース前のセキュリティ監査（全リポ横断 + データフロー） |
| `pull-all` / `onboarding` | 全リポ最新化 / 新規参加メンバーのセットアップ |

### Tier D — インフラ運用

| skill | 役割 |
|---|---|
| `app-log-monitor` / `error-investigation` | ログ確認 / 障害の切り分け |
| `app-rollback` / `maintenance-mode` | 切り戻し / メンテナンスモード |
| `db-status` / `db-backup` / `kube-debug-db` | DB の状態・バックアップ・クラスタ経由の接続 |
| `registry-cleanup` / `vulnerability-fix` | 未使用イメージ削除 / 検知済み CVE の依存更新 |
| `local-init` / `local-destroy` / `env-sync` | ローカル環境の構築・破棄・環境ファイル同期 |
| `assist-migration` / `schema-sync` | スキーマ変更 / 他リポへの横展開 |

### Tier E — 運用パターンの骨格

プロジェクト固有の手順書を書くときの**型**。実際に触るファイルは各プロジェクトの rules が SoT。

| skill | 役割 |
|---|---|
| `multi-surface-change` | 1 つの概念を複数レイヤに跨って追加 / 廃止する |
| `pricing-change` | 単価・料金の改定（反映タイミングと過去分の扱い） |
| `data-subject-operation` | 個別データの削除・エクスポート |
| `tls-certificate-recovery` | TLS 証明書の期限切れ・発行失敗の復旧 |

## 構成

```
claude-devkit/
├── .claude-plugin/            marketplace.json / plugin.json
├── .github/workflows/         validate.sh を回す CI（故意破壊の再実行つき）
├── skills/                    43 skill（上表 + devkit-init / devkit-update）
├── agents/                    独立コンテキスト実行ラッパ（9 件）
├── docs/
│   └── evidence.md            検証・レビューの証跡の残し方（共通規約）
├── templates/
│   ├── devkit.json            設定テンプレ（最小）
│   ├── devkit.full-example.json  設定テンプレ（全部入り）
│   ├── settings.json          hooks 雛形
│   └── rules/                 rules テンプレ + 運用基準（P1〜P5 / A1〜A4）
├── tests/
│   └── wording-fix-gate/      分類器のゴールデン diff（通る / 落ちる / 設定で反転）
└── tools/
    ├── config.sh              devkit.json を shell 変数として export
    ├── rules-size-check.sh    rules の肥大化と知見の消失を機械検証（検証 1〜5）
    ├── project-items-fetch.sh GitHub Project の全 item を安価に取得
    ├── wording-fix-gate/      文言修正マージゲート（分類器 + PreToolUse hook）
    └── validate.sh            devkit 自身の健全性検証（編集したら必ず実行）
```

`tools/` は `/devkit-init` が対象プロジェクトの `.claude/devkit/` へ**コピー**する（参照ではなくコピーなので、プラグインを更新してもプロジェクト側は動き続ける）。裏返しとして**プラグイン側のバグ修正も自動では届かない**ので、版を `.claude/devkit/VERSION` に刻み、`/devkit-update` で明示的に取り込む。

## 設計の柱

### 1. 合格基準を持たせて自律ループする

各工程に**機械判定できる合格基準**と**上限回数**を与える。上限に達したら必ず停止して報告する（無限ループと料金暴走の抑止）。

| 工程 | 合格基準 |
|---|---|
| 要件 / 設計 / テスト網羅のレビュー | **Critical = 0**（Important は集計のみで通過を阻害しない） |
| lint / test | exit 0 |
| ブラウザ検証 | console error = 0 / fetch 4xx5xx = 0 / 期待要素の描画 |
| セルフレビュー（徹底） | Critical = 0 かつ Important が前回比で減少 |

### 2. レビューは「判定」と「修正」を分離する

`review-*` skill は**修正しない**。判定結果を `json findings` 形式で返し、修正は `audit-changes` / `fix-pr-review` が行う。ラウンド中に直すと次のラウンドの視点が変わるため、検出に専念させる。

### 3. 知見は rules に貯め、肥大化はラチェットで止める

`/harvest` が会話から知見を抽出して `.claude/rules/` に追記し、`rules-size-check.sh` が 5 つの検証をかける:

| 検証 | 内容 |
|---|---|
| 1 サイズ | 合計 / ファイル単体の上限 |
| 2 見出し保全 | base にあった見出しが消えていないか（移動は許容） |
| 3 エントリ保存則 | 知見の総数が減っていないか |
| 4 リンク解決 | 相対リンクの実在 |
| **5 釣り合わせ** | **増やした分だけ退避したか（ラチェット）** |

**「増やす」だけでなく「移す・統合する」までが 1 セット。** 検証 5 は、rules を 2 KB 超増やしたのに退避が同量に満たない変更を FAIL にする（本当に出せるものが無いときだけ `--allow-growth` で宣言する）。何を常駐させ何を `docs/` へ移すかの判定基準（P1〜P5 / A1〜A4）は `templates/rules/README.md` が SoT。

### 4. プロジェクト固有値は 1 箇所に集約する

skill 本体にリポ名・Project ID・lint コマンド・クラスタ名を直書きしない。差し替え点は `.claude/devkit.json` だけ。文言修正ゲートの閾値・denylist（`wordingGate`）も同様。

### 4.1 本文の 🔴 は `allowed-tools` にも書く

**「やってはいけない」を本文にだけ書いても機械層は守らない。** `Bash(gcloud *)` は `gcloud sql instances delete` まで無確認で通す。破壊的 CLI（gcloud / aws / az / docker / kubectl / terraform / helm / psql / mysql）は**動詞まで絞る**か、許可リストに載せずに都度承認へ倒す。`validate.sh` の検証 2 が丸ごと許可を FAIL にする。

プロジェクト固有の CLI 許可は、devkit ではなくそのプロジェクトの `.claude/settings.json` に、必要な接頭辞だけ足す。

### 5. 「取得できなかった」と「0 件だった」を区別する

CI の polling・ログ取得・レビュー結果・走査ベースの検証すべてに効く原則。空文字や取得失敗を「問題なし」と読む実装をしない。

## 課題管理の対応レベル

`tracker.type` で 3 段階。**全部入りを前提にしない。**

| type | できること |
|---|---|
| `github-project` | Status 遷移・Size / 工数の書き込み・一括遷移・進捗集計まで自動化 |
| `issues-only` | Issue へのコメント投稿まで。Status 遷移工程は自動でスキップ |
| `none` | Issue 起点の skill は使えない。Tier A のみ有効 |

## devkit 自体を編集したとき

```bash
bash tools/validate.sh
```

JSON とバージョン整合 / frontmatter（agent の `model` 必須・破壊的 CLI の丸ごと許可禁止）/ 相対リンク / **シェル構文とマルチバイト隣接** / **Python 構文と文言ゲートのゴールデンテスト** / 設定読み込みの形（exit code・cwd 非依存）/ **tools 参照の実在** / **設定キー・変数・既定値の整合** の 8 項目を検証する。

CI（`.github/workflows/validate.yml`）が push / PR ごとに同じものを回し、**さらに故意破壊を 1 件仕込んで FAIL することまで確認する**。「編集したら必ず実行する」を人の記憶に預けた結果、下記のバグが残っていた。

**`$VAR` の直後にマルチバイト文字を置かない**（`${VAR}` のブレースを使う）。bash はそれを変数名の一部として読み、`set -u` の下で unbound variable になって**意図した exit code もエラーメッセージも失われる**（実際このバグが 1 件あり、導入シミュレーションで初めて露見した）。

🔴 **検証を足したら、その検証自身を故意破壊で確かめること**（本物を 1 件だけ壊して FAIL を確認 → 復元して PASS を確認）。「PASS しているから正しい」と「そもそも見ていない」は区別が付かない。

🔴 **確かめるのは「❌ が出たか」ではなく exit code。** 検知はできているのに終了ステータスへ伝わらない壊れ方が最も見つかりにくい。実際に 2 件あった:

- `validate.sh` のマルチバイト検査が `sh_ng=1` だけ立てて `FAILED` に伝えず、**❌ を表示しながら `validate: PASS` / exit 0**
- `rules-size-check.sh` のリンク検査が `find ... | while read` でループごとサブシェルに入り、**リンク切れを表示した直後に「✅ 0 件すべて解決」と言って exit 0**

前者は集約変数へ伝える、後者は `while ... done < <(...)` にする。**故意破壊のたびに `echo $?` まで見ること。**

🔴 **故意破壊の復元は `git checkout --` に頼らない。** 対象が untracked（新規ファイル）だと**無言でスキップされ、破壊が残る**。復元後は必ず `git status --short` と実ファイルの末尾を目視する。

## 前提

- `git`
- `gh`（GitHub 連携を使う場合）。Project への書き込みには `project` scope が必要
- `jq`
- `python3`（`validate.sh` / `rules-size-check.sh` / `wording-fix-gate`）

## ライセンス / 由来

MIT License（[LICENSE](./LICENSE)）。

実運用中のマルチサービス開発ハーネスから、プロジェクト非依存の部分を抽出して汎用化したもの。抽出元の固有情報（組織名・リポジトリ名・ドメイン用語・実 ID・個人名）は含まない。

**抽出元から追加で持ち込むときの注意**: 固有語は「リポ名」ではなく **設定のサンプル値**（ディレクトリ名・レジストリ名・命名パターン・Status 表示名）として紛れ込む。今回の抽出でも、リポ名を除いた後にこの形で 3 件残っていた。
