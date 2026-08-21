# claude-devkit

Issue から PR までを自律ループで回す、**プロジェクト非依存**の Claude Code 開発ハーネス。

要件定義 → 設計 → 実装 → レビュー → PR の各工程を skill として持ち、それぞれを **sub-agent で独立コンテキスト実行**することで、ルール精読・diff・レビュー指摘・ブラウザログといった大量の中間情報が親のコンテキストを食い潰さないようにしてある。

プロジェクト固有の値（リポジトリ名・ベースブランチ・lint/test コマンド・課題管理の ID 群）は **`.claude/devkit.json` の 1 ファイルに外出し**されており、skill 本体にはどこにも直書きされていない。

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

## 構成

```
claude-devkit/
├── .claude-plugin/
│   ├── marketplace.json
│   └── plugin.json
├── skills/
│   ├── devkit-init/              導入・設定生成
│   ├── implement-issue/          Issue → PR の統括（自走モードあり）
│   ├── define-requirements/      要件定義（何を / なぜ）
│   ├── design-implementation/    実装設計（どう実装するか）
│   ├── review-requirements/      要件品質の突合（判定のみ）
│   ├── review-design/            設計の突合（判定のみ）
│   ├── review-test-coverage/     テスト網羅の突合（判定のみ）
│   ├── audit-changes/            N 回レビュー → 一括修正 → 収束ループ
│   ├── fix-pr-review/            PR レビュー対応（reply / resolve まで）
│   ├── verify-browser/           ブラウザ実機検証
│   ├── loop-until-pass/          任意の検査を合格まで回す汎用ループ
│   ├── commit-changes/           Conventional Commit（push はしない）
│   └── harvest/                  会話から知見を抽出して rules へ永続化
├── agents/                       上記 8 skill の独立コンテキスト実行ラッパ
├── templates/
│   ├── devkit.json               設定テンプレ（最小）
│   ├── devkit.full-example.json  設定テンプレ（GitHub Project 連携あり）
│   ├── settings.json             hooks 雛形
│   └── rules/                    rules テンプレ + 運用基準（P1〜P5 / A1〜A4）
└── tools/
    ├── config.sh                 devkit.json を shell 変数として export
    ├── rules-size-check.sh       rules の肥大化と知見の消失を機械検証
    └── validate.sh               devkit 自身の健全性検証（編集したら必ず実行）
```

`config.sh` と `rules-size-check.sh` は `/devkit-init` が対象プロジェクトの `.claude/devkit/` へ**コピー**する（参照ではなくコピーなので、プラグインを更新してもプロジェクト側は動き続ける）。

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

### 3. 知見は rules に貯め、肥大化は機械で止める

`/harvest` が会話から知見を抽出して `.claude/rules/` に追記し、`rules-size-check.sh` が「合計サイズ / 見出しの保全 / 知見エントリの保存則 / リンク解決」を base 比較で検証する。

**「増やす」だけでなく「移す・統合する」までが 1 セット。** 何を常駐させ何を `docs/` へ移すかの判定基準（常駐必須クラス P1〜P5 / アーカイブ対象クラス A1〜A4）は `templates/rules/README.md` が SoT。

### 4. プロジェクト固有値は 1 箇所に集約する

skill 本体にリポ名・Project ID・lint コマンドを直書きしない。差し替え点は `.claude/devkit.json` だけ。

## 課題管理の対応レベル

`tracker.type` で 3 段階。**全部入りを前提にしない。**

| type | できること |
|---|---|
| `github-project` | Status 遷移・Size / 工数の書き込みまで自動化 |
| `issues-only` | Issue へのコメント投稿まで。Status 遷移工程は自動でスキップ |
| `none` | Issue 起点の skill は使えない。`commit-changes` / `loop-until-pass` / `audit-changes` / `harvest` のみ有効 |

## devkit 自体を編集したとき

```bash
bash tools/validate.sh
```

固有語の残留 / JSON / frontmatter / 相対リンク / シェル構文 / 設定読み込みの形 を検証する。**検証を足したら、その検証自身を故意破壊で確かめること**（本物を 1 件だけ壊して FAIL を確認 → 復元して PASS を確認）。

## 前提

- `git`
- `gh`（GitHub 連携を使う場合）。Project への書き込みには `project` scope が必要
- `jq`

## ライセンス / 由来

実運用中のマルチサービス開発ハーネスから、プロジェクト非依存の部分を抽出して汎用化したもの。抽出元の固有情報（組織名・リポジトリ名・ドメイン用語）は含まない。
