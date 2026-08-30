---
name: app-rollback
description: アプリケーション（イメージ）と DB を以前の状態へ切り戻す。範囲確認 → 実行 → 動作確認までをゲート付きで進める。「切り戻し」「ロールバック」「rollback」「戻して」と言われた時に使用してください。
argument-hint: '[--app-only | --with-db]'
allowed-tools: Bash(bash *), Bash(git *), Bash(kubectl get:*), Bash(kubectl logs:*), Bash(kubectl set image:*), Bash(kubectl rollout:*), Bash(curl *), Bash(jq *), Read, AskUserQuestion
---

# app-rollback — アプリ / DB の切り戻し

🔴 **破壊的操作。各ステップで確認を取る。**

## 基本方針

- **切り戻し範囲（アプリのみ / アプリ + DB）をユーザーに確認してから実行する**
- 🔴 **DB リストアは既存データを完全に上書きする。** アプリのみで解決しないか先に検討する
- 認証・クラスタ接続は済んでいる前提。**対話的な認証はユーザーに依頼する**

## 手順

### 1. 状況の確認

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
```

聞くこと:

1. **切り戻し範囲** — アプリのみ / アプリ + DB
2. **戻し先のイメージタグ**（記録済みファイルがあればそのパス）
3. **バックアップ ID**（DB 切り戻しをする場合。未取得なら `/db-backup` を先に案内する）
4. **対象範囲** — 全体 / 特定の環境・サービスのみ

### 2. 現状の記録（戻し先が不明なとき）

🔴 **切り戻す前に「今のイメージタグ」を必ず記録する。** 記録せずに戻すと、**切り戻し自体を取り消せなくなる**。

```bash
kubectl get deploy -n <ns> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

**ReplicaSet の履歴は「いつ・どの image に入れ替わったか」がそのまま残る**ので、戻し先の特定にも使える:

```bash
kubectl get rs -n <ns> -l app=<svc> \
  -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' | sort
```

### 3. アプリの切り戻し（ゲート）

インフラ定義リポにロールバックスクリプトがあればそれを使う。無ければ image tag を明示して差し替える。

🔴 **`rollout restart` はコードを戻さない。** image tag が固定（SHA 等）の構成では、restart は**同じ image を pull し直すだけ**で env のみが更新される。**コードを戻すには image tag を書き換える**。

完了後に Pod の状態を確認する。

### 4. DB の切り戻し（ゲート・再確認）

🔴 **実行前にもう一度確認を取る。** 既存データを完全に上書きする。

- リストアには時間がかかる（数十分規模）。**進行中オペレーションを polling して完了を待つ**
- **リストア中は対象サービスが利用不可**になることを事前に伝える

### 5. 切り戻し後の動作確認

- ヘルスチェック（`infra.healthPath`）
- DB 接続確認
- ログにエラーが出ていないか
- 🔴 **image tag を実測して、意図した版に戻っていることを確認する**（画面が出ることを反映確認の根拠にしない。キャッシュが旧版を返しうる）

### 6. 完了報告

```
切り戻し完了
- 範囲: <アプリのみ / アプリ + DB>
- 対象: <...>
- 戻し先: <image tag / backup id>
- 動作確認: ヘルス <OK/NG> / ログ <エラー N 件>
```

## 注意事項

- **DB リストア完了後にアプリの再起動が必要な場合がある**
- 🔴 **メンテナンスモードは自動解除されない。** 使っていたなら `/maintenance-mode` で明示的に解除する
- **特定環境だけへの先行適用は、次の定期リリースで巻き戻る前提で計画する。** 巻き戻り後に自動で追い付かない処理（過去日を凍結する集計等）があるなら、**再実行までを計画に含める**
